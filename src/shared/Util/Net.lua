--[[
	Net.lua
	The single client/server boundary.

	Three remotes carry everything, routed by a string name:

	  ToServer  RemoteEvent     client -> server, fire and forget
	  ToClient  RemoteEvent     server -> client, fire and forget
	  Request   RemoteFunction  client -> server, expects a reply

	Why one router instead of a remote per feature: every inbound message passes
	through exactly one place, so rate limiting, payload sanitising and the
	"never trust the client" rule are properties of the transport rather than
	something each service has to remember.

	Rules enforced here:
	  * Inbound payloads are sanitised for depth, width and string length before
	    a handler ever sees them. A malicious client cannot make the server walk
	    a huge or deeply nested table.
	  * Every route has a token-bucket budget per player. Exceeding it rejects
	    the call; it never throws, so a flooding client gets refusals rather than
	    a server-side error loop.
	  * A handler that errors returns a structured failure to the caller instead
	    of propagating, because an error across a RemoteFunction leaves the
	    client's invoke hanging.
	  * Handlers receive the Player as their first argument, always provided by
	    the engine, never by the payload. Client-claimed identity is ignored.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Enums = require(script.Parent.Parent.Enums)
local Logger = require(script.Parent.Logger)

local log = Logger.new("Net")

local Net = {}

local FOLDER_NAME = "BelowZeroNet"
local IS_SERVER = RunService:IsServer()

-- Payload limits. Generous for real traffic, tight enough to be worthless to abuse.
local MAX_DEPTH = 5
local MAX_KEYS = 64
local MAX_STRING = 256

local folder
local toServer
local toClient
local requestFunction

local handlers = {} -- [route] = { fn = function, burst = n, window = n }
local listeners = {} -- [route] = { fn = function, burst = n, window = n }
local clientHandlers = {} -- [route] = { fn, fn, ... }
local buckets = {} -- [userId] = { [route] = { tokens = n, updated = clock } }
local rejectionStreak = {} -- [userId] = n

-- ─────────────────────────────────────────────────────────────────────────────
-- Remote plumbing
-- ─────────────────────────────────────────────────────────────────────────────

local function buildRemotes()
	folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	toServer = Instance.new("RemoteEvent")
	toServer.Name = "ToServer"
	toServer.Parent = folder

	toClient = Instance.new("RemoteEvent")
	toClient.Name = "ToClient"
	toClient.Parent = folder

	requestFunction = Instance.new("RemoteFunction")
	requestFunction.Name = "Request"
	requestFunction.Parent = folder

	folder.Parent = ReplicatedStorage
end

local function waitForRemotes()
	folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 30)
	if not folder then
		error("[BZ/Net] remote folder never appeared; is the server bootstrap running?", 0)
	end
	toServer = folder:WaitForChild("ToServer", 10)
	toClient = folder:WaitForChild("ToClient", 10)
	requestFunction = folder:WaitForChild("Request", 10)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Payload sanitising
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Accepts nil, booleans, numbers (finite), bounded strings, and tables of those
	within the depth and width limits. Rejects everything else — notably
	functions, userdata and Instances, none of which a gameplay payload needs.

	@return boolean ok, string|nil reason
]]
local function sanitise(value, depth)
	depth = depth or 0
	local valueType = typeof(value)

	if value == nil or valueType == "boolean" then
		return true
	end

	if valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return false, "non-finite number"
		end
		return true
	end

	if valueType == "string" then
		if #value > MAX_STRING then
			return false, "string too long"
		end
		return true
	end

	if valueType == "Vector3" then
		--[[ Vector3 is allowed because placement and interaction requests need a
		     position. It is still only a *claim*; the server re-measures. ]]
		local components = { value.X, value.Y, value.Z }
		for _, component in ipairs(components) do
			if component ~= component or math.abs(component) > 1e6 then
				return false, "bad vector"
			end
		end
		return true
	end

	if valueType == "table" then
		if depth >= MAX_DEPTH then
			return false, "payload too deep"
		end
		local keyCount = 0
		for key, entry in pairs(value) do
			keyCount += 1
			if keyCount > MAX_KEYS then
				return false, "payload too wide"
			end
			local keyType = typeof(key)
			if keyType ~= "string" and keyType ~= "number" then
				return false, "bad key type"
			end
			if keyType == "string" and #key > 64 then
				return false, "key too long"
			end
			local ok, reason = sanitise(entry, depth + 1)
			if not ok then
				return false, reason
			end
		end
		return true
	end

	return false, "unsupported type " .. tostring(valueType)
end

Net.sanitise = sanitise

-- ─────────────────────────────────────────────────────────────────────────────
-- Rate limiting
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Token bucket. Each route holds `burst` tokens, refilled at burst/window per
	second. One call costs one token.
]]
local function consumeToken(player, route, burst, window)
	local userId = player.UserId
	local playerBuckets = buckets[userId]
	if not playerBuckets then
		playerBuckets = {}
		buckets[userId] = playerBuckets
	end

	local bucket = playerBuckets[route]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = burst, updated = now }
		playerBuckets[route] = bucket
	end

	local elapsed = now - bucket.updated
	bucket.updated = now
	bucket.tokens = math.min(burst, bucket.tokens + elapsed * (burst / window))

	if bucket.tokens < 1 then
		local streak = (rejectionStreak[userId] or 0) + 1
		rejectionStreak[userId] = streak
		if streak == GameConfig.Net.SuspicionThreshold then
			--[[ Logged, never auto-punished: a legitimate player on a bad
			     connection can trip a rate limit, and banning on that signal
			     alone would be wrong. ]]
			log:warn(
				"player %s (%d) has hit %d consecutive rate-limited calls; latest route %q",
				player.Name,
				userId,
				streak,
				route
			)
		end
		return false
	end

	bucket.tokens -= 1
	rejectionStreak[userId] = 0
	return true
end

local function budgetFor(entry)
	return entry.burst or GameConfig.Net.DefaultBurst, entry.window or GameConfig.Net.DefaultWindow
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Server API
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Register a request/response route.

	@param route   string
	@param fn      function(player, payload) -> result table
	@param options { burst = n, window = n }

	The handler should return a table. By convention:
	  { ok = true, ... }                    success
	  { ok = false, reason = Enums.Reject }  refusal
	Returning nil is treated as an unspecified success.
]]
function Net.handle(route, fn, options)
	assert(IS_SERVER, "Net.handle is server-only")
	assert(type(route) == "string" and route ~= "", "route must be a non-empty string")
	assert(type(fn) == "function", "handler must be a function")
	if handlers[route] then
		log:warn("route %q registered twice; the later handler wins", route)
	end
	options = options or {}
	handlers[route] = { fn = fn, burst = options.burst, window = options.window }
end

--[[ Register a fire-and-forget route (client -> server). ]]
function Net.listen(route, fn, options)
	assert(IS_SERVER, "Net.listen is server-only")
	assert(type(route) == "string" and route ~= "", "route must be a non-empty string")
	assert(type(fn) == "function", "handler must be a function")
	if listeners[route] then
		log:warn("listener %q registered twice; the later handler wins", route)
	end
	options = options or {}
	listeners[route] = { fn = fn, burst = options.burst, window = options.window }
end

function Net.fire(player, route, payload)
	assert(IS_SERVER, "Net.fire is server-only")
	if not player or not player.Parent then
		return
	end
	toClient:FireClient(player, route, payload)
end

function Net.fireAll(route, payload)
	assert(IS_SERVER, "Net.fireAll is server-only")
	toClient:FireAllClients(route, payload)
end

--[[ Fire to a specific set of players; used for party-scoped messages so an
     expedition's state never leaks to players outside it. ]]
function Net.fireList(playerList, route, payload)
	assert(IS_SERVER, "Net.fireList is server-only")
	for _, player in ipairs(playerList) do
		if player and player.Parent then
			toClient:FireClient(player, route, payload)
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Client API
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Call a server route and wait for the reply.
	Never throws: a server-side failure comes back as { ok = false, reason = ... }.
]]
function Net.request(route, payload)
	assert(not IS_SERVER, "Net.request is client-only")
	local ok, result = pcall(function()
		return requestFunction:InvokeServer(route, payload)
	end)
	if not ok then
		log:warn("request %q failed in transport: %s", route, tostring(result))
		return { ok = false, reason = "transport_error" }
	end
	if type(result) ~= "table" then
		return { ok = false, reason = "bad_response" }
	end
	return result
end

function Net.send(route, payload)
	assert(not IS_SERVER, "Net.send is client-only")
	toServer:FireServer(route, payload)
end

--[[ Subscribe to a server -> client route. Returns a disconnect function. ]]
function Net.on(route, fn)
	assert(not IS_SERVER, "Net.on is client-only")
	local list = clientHandlers[route]
	if not list then
		list = {}
		clientHandlers[route] = list
	end
	table.insert(list, fn)
	return function()
		local index = table.find(list, fn)
		if index then
			table.remove(list, index)
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Dispatch
-- ─────────────────────────────────────────────────────────────────────────────

local function dispatchRequest(player, route, payload)
	if type(route) ~= "string" then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local entry = handlers[route]
	if not entry then
		log:warn("unknown request route %q from %s", route, player.Name)
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local burst, window = budgetFor(entry)
	if not consumeToken(player, route, burst, window) then
		return { ok = false, reason = Enums.Reject.RateLimited }
	end

	local clean, reason = sanitise(payload, 0)
	if not clean then
		log:warn("rejected payload on %q from %s: %s", route, player.Name, tostring(reason))
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local ok, result = pcall(entry.fn, player, payload)
	if not ok then
		log:fault("handler %q errored for %s: %s", route, player.Name, tostring(result))
		return { ok = false, reason = "server_error" }
	end
	if result == nil then
		return { ok = true }
	end
	if type(result) ~= "table" then
		log:fault("handler %q returned a %s, expected a table", route, typeof(result))
		return { ok = false, reason = "server_error" }
	end
	return result
end

local function dispatchEvent(player, route, payload)
	if type(route) ~= "string" then
		return
	end

	local entry = listeners[route]
	if not entry then
		log:warn("unknown event route %q from %s", route, player.Name)
		return
	end

	local burst, window = budgetFor(entry)
	if not consumeToken(player, route, burst, window) then
		return
	end

	local clean, reason = sanitise(payload, 0)
	if not clean then
		log:warn("rejected event payload on %q from %s: %s", route, player.Name, tostring(reason))
		return
	end

	local ok, err = pcall(entry.fn, player, payload)
	if not ok then
		log:fault("listener %q errored for %s: %s", route, player.Name, tostring(err))
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Initialisation
-- ─────────────────────────────────────────────────────────────────────────────

local started = false

--[[ Call once from the server bootstrap, before registering routes, or once
     from the client bootstrap. Safe to call repeatedly. ]]
function Net.start()
	if started then
		return Net
	end
	started = true

	if IS_SERVER then
		buildRemotes()

		requestFunction.OnServerInvoke = function(player, route, payload)
			return dispatchRequest(player, route, payload)
		end

		toServer.OnServerEvent:Connect(function(player, route, payload)
			dispatchEvent(player, route, payload)
		end)

		Players.PlayerRemoving:Connect(function(player)
			buckets[player.UserId] = nil
			rejectionStreak[player.UserId] = nil
		end)

		log:info("server transport ready")
	else
		waitForRemotes()

		toClient.OnClientEvent:Connect(function(route, payload)
			local list = clientHandlers[route]
			if not list then
				return
			end
			for _, fn in ipairs(table.clone(list)) do
				local ok, err = pcall(fn, payload)
				if not ok then
					log:fault("client handler %q errored: %s", tostring(route), tostring(err))
				end
			end
		end)

		log:info("client transport ready")
	end

	return Net
end

--[[ Introspection for the test harness: which routes exist. ]]
function Net.registeredRoutes()
	local routes = { requests = {}, events = {} }
	for route in pairs(handlers) do
		table.insert(routes.requests, route)
	end
	for route in pairs(listeners) do
		table.insert(routes.events, route)
	end
	table.sort(routes.requests)
	table.sort(routes.events)
	return routes
end

return Net
