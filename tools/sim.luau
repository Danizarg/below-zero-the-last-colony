--[[
	tools/sim.luau
	A simulated Roblox server, enough to boot all 16 services and drive a whole
	expedition without the engine.

	Why not Lune's Instances
	────────────────────────
	`@lune/roblox` models the DOM for FILE manipulation, not for runtime. Two
	limits make it unusable here:

	  * No signals at all. Even `Instance.new("BindableEvent")` has no `.Event`
	    and no `:Fire`. This project needs `Humanoid.HealthChanged`,
	    `Player.CharacterAdded`, `RunService.Heartbeat` — and one of the bugs
	    being regression-tested is specifically about HealthChanged ordering.
	  * `Position` cannot be derived from `CFrame`. It is a native property with
	    no default, `implementProperty` will not shadow it, and setting `CFrame`
	    does not update it. Server code sets `root.CFrame` and then reads
	    `root.Position`, which would silently read stale data.

	So Instances are modelled here, in Lua, with a permissive property bag. The
	DATATYPES still come from Lune (Vector3, CFrame, Color3, Enum) — those are
	exact.

	What this proves, and what it does not
	──────────────────────────────────────
	It proves SERVICE LOGIC AND ORCHESTRATION: that starting an expedition
	settles rewards exactly once, that keys reach escape.keys, that the clock
	advances phases in order, that a disconnect banks the right fraction, that
	the DataStore locking protocol behaves. That is where the semantic bugs
	were.

	It does NOT prove engine fidelity: real physics, real rendering, real
	pathfinding, real DataStore semantics. A pass here is not a substitute for
	the Studio checklist in SETUP.md §5 — it is a floor under it.

	Time is virtual. Nothing sleeps; `sim:advance(60)` moves the simulation
	sixty seconds in microseconds, firing every scheduled callback in order.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local sim = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Signals
-- ─────────────────────────────────────────────────────────────────────────────

local function newSignal(name)
	local handlers = {}
	local signal

	signal = {
		_name = name,
		Connect = function(_, fn)
			local connection = { fn = fn, connected = true }
			table.insert(handlers, connection)
			return {
				Disconnect = function()
					connection.connected = false
					local index = table.find(handlers, connection)
					if index then
						table.remove(handlers, index)
					end
				end,
				Connected = true,
			}
		end,
		Once = function(self, fn)
			local connection
			connection = self:Connect(function(...)
				connection:Disconnect()
				fn(...)
			end)
			return connection
		end,
		Fire = function(_, ...)
			for _, connection in ipairs(table.clone(handlers)) do
				if connection.connected then
					local ok, err = pcall(connection.fn, ...)
					if not ok then
						sim._onError(("signal %s handler: %s"):format(tostring(name), tostring(err)))
					end
				end
			end
		end,
		Wait = function()
			--[[ Only DataService's BindToClose waits on a signal, and the sim
			     drives shutdown explicitly, so a no-op is correct here. A real
			     yield would deadlock the single-threaded simulation. ]]
			return nil
		end,
		handlerCount = function()
			return #handlers
		end,
	}

	return signal
end

sim.newSignal = newSignal

-- ─────────────────────────────────────────────────────────────────────────────
-- Instance DOM
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Class ancestry, only as deep as this project's :IsA() calls need. ]]
local ANCESTRY = {
	Part = { "BasePart", "PVInstance", "Instance" },
	WedgePart = { "BasePart", "PVInstance", "Instance" },
	SpawnLocation = { "Part", "BasePart", "PVInstance", "Instance" },
	Model = { "PVInstance", "Instance" },
	Folder = { "Instance" },
	Humanoid = { "Instance" },
	ProximityPrompt = { "Instance" },
	BillboardGui = { "Instance" },
	TextLabel = { "GuiObject", "Instance" },
	PointLight = { "Light", "Instance" },
	SpotLight = { "Light", "Instance" },
	WeldConstraint = { "Instance" },
	Weld = { "JointInstance", "Instance" },
	ParticleEmitter = { "Instance" },
	Attachment = { "Instance" },
	Beam = { "Instance" },
	Highlight = { "Instance" },
	ModuleScript = { "LuaSourceContainer", "Instance" },
	Script = { "LuaSourceContainer", "Instance" },
	BindableEvent = { "Instance" },
}

local InstanceClass = {}

local function newInstance(className)
	local self
	local children = {}
	local props = {}
	local attributes = {}
	local signals = {}

	local methods = {}

	function methods.IsA(_, query)
		if query == className then
			return true
		end
		for _, ancestor in ipairs(ANCESTRY[className] or { "Instance" }) do
			if ancestor == query then
				return true
			end
		end
		return false
	end

	function methods.GetChildren()
		return table.clone(children)
	end

	function methods.GetDescendants()
		local out = {}
		for _, child in ipairs(children) do
			table.insert(out, child)
			for _, descendant in ipairs(child:GetDescendants()) do
				table.insert(out, descendant)
			end
		end
		return out
	end

	function methods.FindFirstChild(_, name)
		for _, child in ipairs(children) do
			if child.Name == name then
				return child
			end
		end
		return nil
	end

	--[[ Nothing in the simulation is created asynchronously, so a child is
	     either there or it is a bug worth surfacing immediately rather than a
	     timeout to wait out. ]]
	function methods.WaitForChild(instance, name)
		local child = methods.FindFirstChild(instance, name)
		if not child then
			error(
				("[sim] WaitForChild(%q) on %s: no such child"):format(
					tostring(name),
					methods.GetFullName(instance)
				),
				2
			)
		end
		return child
	end

	function methods.FindFirstChildOfClass(_, query)
		for _, child in ipairs(children) do
			if child.ClassName == query then
				return child
			end
		end
		return nil
	end

	function methods.FindFirstChildWhichIsA(_, query)
		for _, child in ipairs(children) do
			if child:IsA(query) then
				return child
			end
		end
		return nil
	end

	function methods.FindFirstAncestorOfClass(_, query)
		local cursor = props.Parent
		while cursor do
			if cursor.ClassName == query then
				return cursor
			end
			cursor = cursor.Parent
		end
		return nil
	end

	function methods.ClearAllChildren()
		for _, child in ipairs(table.clone(children)) do
			child:Destroy()
		end
	end

	function methods.Destroy(instance)
		local parent = props.Parent
		if parent then
			local index = table.find(parent._children, instance)
			if index then
				table.remove(parent._children, index)
			end
		end
		props.Parent = nil
		props.__destroyed = true
		for _, child in ipairs(table.clone(children)) do
			child:Destroy()
		end
	end

	function methods.SetAttribute(_, name, value)
		attributes[name] = value
	end

	function methods.GetAttribute(_, name)
		return attributes[name]
	end

	function methods.GetFullName(instance)
		local parts = { instance.Name }
		local cursor = props.Parent
		while cursor do
			table.insert(parts, 1, cursor.Name)
			cursor = cursor.Parent
		end
		return table.concat(parts, ".")
	end

	--[[ Model pivot. CFrame-only parts are why this DOM exists: PivotTo moves
	     every descendant part so later Position reads stay truthful. ]]
	function methods.PivotTo(instance, target)
		local primary = props.PrimaryPart
		local origin = primary and primary.CFrame or props.__pivot or roblox.CFrame.new()
		props.__pivot = target

		local delta = target * origin:Inverse()
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant.CFrame then
				descendant.CFrame = delta * descendant.CFrame
			end
		end
	end

	function methods.GetPivot()
		local primary = props.PrimaryPart
		if primary and primary.CFrame then
			return primary.CFrame
		end
		return props.__pivot or roblox.CFrame.new()
	end

	-- Humanoid behaviour.
	function methods.TakeDamage(instance, amount)
		instance.Health = math.max(0, (props.Health or 0) - (amount or 0))
	end

	function methods.MoveTo(_, target)
		props.__moveTarget = target
	end

	function methods.GetState()
		return props.__state or roblox.Enum.HumanoidStateType.Running
	end

	function methods.ChangeState(_, state)
		props.__state = state
	end

	function methods.Fire(_, ...)
		local signal = signals.Event
		if signal then
			signal:Fire(...)
		end
	end

	--[[ Signals are created lazily, so any `instance.SomeEvent:Connect(...)`
	     works without the DOM having to enumerate every event name. ]]
	local function signalFor(name)
		if not signals[name] then
			signals[name] = newSignal(className .. "." .. name)
		end
		return signals[name]
	end

	local SIGNAL_NAMES = {
		HealthChanged = true,
		Died = true,
		Changed = true,
		Event = true,
		Touched = true,
		Triggered = true,
		AncestryChanged = true,
		ChildAdded = true,
		ChildRemoved = true,
		Destroying = true,
	}

	self = setmetatable({
		ClassName = className,
		_children = children,
		_props = props,
		_signals = signals,
	}, {
		__index = function(_, key)
			if key == "Name" then
				return props.Name or className
			end
			if key == "Parent" then
				return props.Parent
			end
			if methods[key] then
				return methods[key]
			end
			if SIGNAL_NAMES[key] then
				return signalFor(key)
			end
			--[[ Position is DERIVED from CFrame when it was never set directly.
			     This is the single most important thing the DOM fixes: server
			     code sets root.CFrame and later reads root.Position. ]]
			if key == "Position" then
				if props.Position then
					return props.Position
				end
				if props.CFrame then
					return props.CFrame.Position
				end
				return roblox.Vector3.new()
			end

			if props[key] ~= nil then
				return props[key]
			end

			--[[ Children are reachable as fields, which is how every module in
			     this project navigates its tree:
			     `script.Parent.Parent.Config.GameConfig`. Properties win over
			     children, as in the engine. ]]
			for _, child in ipairs(children) do
				if child.Name == key then
					return child
				end
			end

			return nil
		end,

		__newindex = function(instance, key, value)
			--[[ ClassName lives in the base table, so a plain assignment would
			     be shadowed by it on read. Rojo turns a folder containing an
			     init file into a script, so this has to be reassignable. ]]
			if key == "ClassName" then
				rawset(instance, "ClassName", value)
				return
			end

			if key == "Parent" then
				local previous = props.Parent
				if previous then
					local index = table.find(previous._children, instance)
					if index then
						table.remove(previous._children, index)
					end
				end
				props.Parent = value
				if value then
					table.insert(value._children, instance)
				end
				return
			end

			--[[ Keep CFrame and Position in lockstep in BOTH directions, which
			     the real engine does and Lune's Instances do not. ]]
			if key == "CFrame" then
				props.CFrame = value
				props.Position = value.Position
				return
			end
			if key == "Position" then
				props.Position = value
				props.CFrame = roblox.CFrame.new(value)
				return
			end

			if key == "Health" then
				local previous = props.Health
				props.Health = value
				if previous ~= value then
					--[[ Fires synchronously on assignment, exactly like the
					     engine. The `_die` regression depends on this. ]]
					signalFor("HealthChanged"):Fire(value)
					if value <= 0 and (previous == nil or previous > 0) then
						signalFor("Died"):Fire()
					end
				end
				return
			end

			props[key] = value
		end,

		__tostring = function()
			return props.Name or className
		end,
	})

	props.Name = className
	if methods.IsA(self, "BasePart") then
		props.CFrame = roblox.CFrame.new()
		props.Position = roblox.Vector3.new()
		props.Size = roblox.Vector3.new(1, 1, 1)
	end
	if className == "Humanoid" then
		props.MaxHealth = 100
		props.Health = 100
		props.WalkSpeed = 16
	end

	return self
end

InstanceClass.new = newInstance
sim.newInstance = newInstance

-- ─────────────────────────────────────────────────────────────────────────────
-- Virtual clock and scheduler
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Virtual time does NOT start at zero.

     Several services compare `os.clock()` against a "last done at" field that
     defaults to 0 — a swing cooldown, a rate limit, a respawn timer. On a real
     server os.clock() is already well past any of those gaps by the time a
     player can act, so those comparisons pass. Starting the simulation at zero
     would make the first swing of every test look like it was on cooldown,
     which is an artefact of the harness rather than anything about the game.
     Starting at a plausible uptime removes that whole class of false failure. ]]
local SIM_START_CLOCK = 1000

local function newScheduler()
	local scheduler = {
		now = SIM_START_CLOCK,
		epoch = 1700000000,
		timers = {},
		deferred = {},
		seq = 0,
	}

	function scheduler.clock()
		return scheduler.now
	end

	function scheduler.time()
		return scheduler.epoch + math.floor(scheduler.now)
	end

	local function schedule(at, thread)
		scheduler.seq += 1
		table.insert(scheduler.timers, { at = at, thread = thread, seq = scheduler.seq })
	end

	function scheduler.spawn(fn, ...)
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			sim._onError("task.spawn: " .. tostring(err))
		end
		return thread
	end

	function scheduler.defer(fn, ...)
		local args = table.pack(...)
		table.insert(scheduler.deferred, function()
			local thread = coroutine.create(fn)
			local ok, err = coroutine.resume(thread, table.unpack(args, 1, args.n))
			if not ok then
				sim._onError("task.defer: " .. tostring(err))
			end
		end)
	end

	function scheduler.delay(seconds, fn, ...)
		local args = table.pack(...)
		local thread = coroutine.create(function()
			fn(table.unpack(args, 1, args.n))
		end)
		schedule(scheduler.now + (seconds or 0), thread)
		return thread
	end

	function scheduler.wait(seconds)
		local thread = coroutine.running()
		schedule(scheduler.now + (seconds or 0), thread)
		coroutine.yield()
		return seconds or 0
	end

	function scheduler.cancel(thread)
		for index = #scheduler.timers, 1, -1 do
			if scheduler.timers[index].thread == thread then
				table.remove(scheduler.timers, index)
			end
		end
	end

	function scheduler.drainDeferred()
		local guard = 0
		while #scheduler.deferred > 0 do
			guard += 1
			if guard > 10000 then
				sim._onError("deferred queue did not drain")
				break
			end
			local batch = scheduler.deferred
			scheduler.deferred = {}
			for _, fn in ipairs(batch) do
				fn()
			end
		end
	end

	--[[ Advance virtual time to `target`, firing every timer due on the way in
	     chronological order. Ties break by insertion order, which keeps the
	     simulation deterministic. ]]
	function scheduler.advanceTo(target)
		scheduler.drainDeferred()

		local guard = 0
		while true do
			guard += 1
			if guard > 100000 then
				sim._onError("scheduler did not settle")
				return
			end

			local best, bestIndex
			for index, timer in ipairs(scheduler.timers) do
				if timer.at <= target then
					if not best or timer.at < best.at or (timer.at == best.at and timer.seq < best.seq) then
						best, bestIndex = timer, index
					end
				end
			end

			if not best then
				break
			end

			table.remove(scheduler.timers, bestIndex)
			scheduler.now = math.max(scheduler.now, best.at)

			if coroutine.status(best.thread) == "suspended" then
				local ok, err = coroutine.resume(best.thread)
				if not ok then
					sim._onError("timer: " .. tostring(err))
				end
			end

			scheduler.drainDeferred()
		end

		scheduler.now = target
		scheduler.drainDeferred()
	end

	return scheduler
end

-- ─────────────────────────────────────────────────────────────────────────────
-- The simulated server
-- ─────────────────────────────────────────────────────────────────────────────

local SHARED_DIR = "src/shared"
local SERVER_DIR = "src/server"

--[[ Same order as src/server/init.server.lua, deliberately duplicated rather
     than parsed: if the bootstrap's order changes, this should be updated and
     re-read, not silently follow. ]]
local LOAD_ORDER = {
	"DataService",
	"InventoryService",
	"ColonyService",
	"BuildingService",
	"NPCService",
	"RoleService",
	"PartyService",
	"SurvivalService",
	"CombatService",
	"NodeService",
	"MonsterService",
	"ObjectiveService",
	"CaveService",
	"RewardService",
	"ExpeditionService",
	"MonetizationService",
}

local function classifyFile(fileName)
	if string.match(fileName, "%.server%.lua$") then
		return string.gsub(fileName, "%.server%.lua$", ""), "Script"
	elseif string.match(fileName, "%.client%.lua$") then
		return string.gsub(fileName, "%.client%.lua$", ""), "LocalScript"
	elseif string.match(fileName, "%.lua$") then
		return string.gsub(fileName, "%.lua$", ""), "ModuleScript"
	end
	return nil, nil
end

local function buildTree(dirPath, nodeName, parent)
	local folder = newInstance("Folder")
	folder.Name = nodeName
	folder.Parent = parent
	folder._filePath = nil

	for _, entryName in ipairs(fs.readDir(dirPath)) do
		local entryPath = dirPath .. "/" .. entryName
		if fs.isDir(entryPath) then
			buildTree(entryPath, entryName, folder)
		else
			local name, className = classifyFile(entryName)
			if name then
				if name == "init" then
					folder.ClassName = className
					folder._filePath = entryPath
				else
					local node = newInstance(className)
					node.Name = name
					node._filePath = entryPath
					node.Parent = folder
				end
			end
		end
	end

	return folder
end

--[[
	Create a fresh simulated server.

	@param options { verbose = boolean, seed = number }
	@return instance with:
		services        the booted service table, by name
		addPlayer(name) -> fake player
		invoke(player, route, payload) -> result     (a Request route)
		send(player, route, payload)                 (an Event route)
		pushes(player, route) -> { payload, ... }     (what the server pushed)
		lastPush(player, route) -> payload
		clearPushes()
		step(dt)        advance time by dt and fire one Heartbeat
		advance(seconds, dt)  repeated steps
		disconnect(player)
		shutdown()
		errors          { string, ... } anything a handler threw
]]
function sim.new(options)
	options = options or {}

	local errors = {}
	sim._onError = function(message)
		table.insert(errors, message)
		if options.verbose then
			print("[sim:error] " .. message)
		end
	end

	local scheduler = newScheduler()
	local server = { errors = errors, scheduler = scheduler, options = options }

	-- ── Services ───────────────────────────────────────────────────────────

	local heartbeat = newSignal("Heartbeat")
	local renderStepped = newSignal("RenderStepped")
	local playerAdded = newSignal("PlayerAdded")
	local playerRemoving = newSignal("PlayerRemoving")

	local players = {}

	local playersService = {
		CharacterAutoLoads = true,
		RespawnTime = 3,
		PlayerAdded = playerAdded,
		PlayerRemoving = playerRemoving,
		GetPlayers = function()
			return table.clone(players)
		end,
		GetPlayerByUserId = function(_, userId)
			for _, player in ipairs(players) do
				if player.UserId == userId then
					return player
				end
			end
			return nil
		end,
		GetPlayerFromCharacter = function(_, character)
			for _, player in ipairs(players) do
				if player.Character == character then
					return player
				end
			end
			return nil
		end,
	}

	local runService = {
		Heartbeat = heartbeat,
		RenderStepped = renderStepped,
		Stepped = newSignal("Stepped"),
		IsServer = function()
			return true
		end,
		IsClient = function()
			return false
		end,
		IsStudio = function()
			return false
		end,
		IsRunning = function()
			return true
		end,
	}

	--[[ A real in-memory DataStore, with genuine UpdateAsync read-modify-write
	     semantics. This matters: the session-locking protocol is where several
	     of the fixed bugs live, so it has to be exercised rather than stubbed. ]]
	local dataStores = {}
	local dataStoreService = {
		GetDataStore = function(_, name)
			if server.dataStoreBroken then
				error("simulated DataStore outage", 0)
			end
			if not dataStores[name] then
				dataStores[name] = { data = {}, calls = 0 }
			end
			local store = dataStores[name]
			return {
				UpdateAsync = function(_, key, transform)
					if server.dataStoreBroken then
						error("simulated DataStore outage", 0)
					end
					store.calls += 1
					local current = store.data[key]
					local updated = transform(current)
					if updated ~= nil then
						store.data[key] = updated
					end
					return updated
				end,
				GetAsync = function(_, key)
					if server.dataStoreBroken then
						error("simulated DataStore outage", 0)
					end
					return store.data[key]
				end,
			}
		end,
	}
	server.dataStores = dataStores
	server.dataStoreBroken = false

	local workspaceInstance = newInstance("Folder")
	workspaceInstance.Name = "Workspace"
	workspaceInstance.Raycast = function()
		--[[ Always clear line of sight. The sim does not model geometry, so
		     combat and monster sight checks always succeed; tests that care
		     about occlusion belong in Studio. ]]
		return nil
	end

	local marketplaceService = {
		PromptProductPurchase = function() end,
		PromptGamePassPurchase = function() end,
		UserOwnsGamePassAsync = function()
			return false
		end,
	}

	local pathfindingService = {
		CreatePath = function()
			return {
				ComputeAsync = function() end,
				Status = roblox.Enum.PathStatus.NoPath,
				GetWaypoints = function()
					return {}
				end,
			}
		end,
	}

	local services = {
		Players = playersService,
		RunService = runService,
		DataStoreService = dataStoreService,
		MarketplaceService = marketplaceService,
		PathfindingService = pathfindingService,
		ProximityPromptService = { PromptTriggered = newSignal("PromptTriggered") },
		TweenService = {
			Create = function()
				return { Play = function() end, Cancel = function() end }
			end,
		},
		SoundService = newInstance("Folder"),
		Lighting = newInstance("Folder"),
		CollectionService = {
			AddTag = function() end,
			GetTagged = function()
				return {}
			end,
		},
	}

	-- ── The fake network layer ─────────────────────────────────────────────

	--[[ Replaces Util/Net entirely. The real one needs RemoteEvents, which this
	     DOM has no transport for — and a direct dispatcher is what an
	     integration test wants anyway: call a route, get the result.

	     Rate limiting is deliberately NOT modelled. These tests assert
	     gameplay invariants; the budgets are covered by ConfigIntegrity. ]]
	local requestHandlers = {}
	local eventHandlers = {}
	local pushed = {} -- [userId] = { [route] = { payload, ... } }

	--[[ Forward-declared: `local x = { f = function() x.g() end }` captures an
	     OUTER x, because the local is only in scope after the assignment. ]]
	local fakeNet
	fakeNet = {
		start = function()
			return fakeNet
		end,
		handle = function(route, fn)
			requestHandlers[route] = fn
		end,
		listen = function(route, fn)
			eventHandlers[route] = fn
		end,
		fire = function(player, route, payload)
			if not player then
				return
			end
			local byUser = pushed[player.UserId]
			if not byUser then
				byUser = {}
				pushed[player.UserId] = byUser
			end
			if not byUser[route] then
				byUser[route] = {}
			end
			table.insert(byUser[route], payload)
		end,
		fireAll = function(route, payload)
			for _, player in ipairs(players) do
				fakeNet.fire(player, route, payload)
			end
		end,
		fireList = function(list, route, payload)
			for _, player in ipairs(list or {}) do
				fakeNet.fire(player, route, payload)
			end
		end,
		request = function()
			error("[sim] Net.request is client-only", 2)
		end,
		send = function()
			error("[sim] Net.send is client-only", 2)
		end,
		on = function()
			return function() end
		end,
		registeredRoutes = function()
			local out = { requests = {}, events = {} }
			for route in pairs(requestHandlers) do
				table.insert(out.requests, route)
			end
			for route in pairs(eventHandlers) do
				table.insert(out.events, route)
			end
			table.sort(out.requests)
			table.sort(out.events)
			return out
		end,
		sanitise = function()
			return true
		end,
	}

	-- ── Module loading ─────────────────────────────────────────────────────

	local sharedTree = buildTree(SHARED_DIR, "BelowZero", nil)
	local serverTree = buildTree(SERVER_DIR, "BelowZeroServer", nil)

	local replicatedStorage = newInstance("Folder")
	replicatedStorage.Name = "ReplicatedStorage"
	sharedTree.Parent = replicatedStorage
	services.ReplicatedStorage = replicatedStorage
	services.ServerScriptService = serverTree

	local cache = {}
	local overrides = {}

	local gameShim = {
		JobId = options.jobId or "sim-job-1",
		PlaceId = 0,
		GetService = function(_, name)
			local service = services[name]
			if not service then
				error(("[sim] GetService(%q) is not provided"):format(name), 2)
			end
			return service
		end,
		BindToClose = function(_, fn)
			server._bindToClose = fn
		end,
	}

	local requireNode

	local quietPrint = function() end

	local function buildEnvironment(node)
		return {
			script = node,
			game = gameShim,
			workspace = workspaceInstance,
			Workspace = workspaceInstance,

			print = options.verbose and print or quietPrint,
			warn = options.verbose and warn or quietPrint,

			Vector3 = roblox.Vector3,
			Vector2 = roblox.Vector2,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			ColorSequence = roblox.ColorSequence,
			ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
			NumberSequence = roblox.NumberSequence,
			NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
			NumberRange = roblox.NumberRange,
			UDim = roblox.UDim,
			UDim2 = roblox.UDim2,
			Rect = roblox.Rect,
			Enum = roblox.Enum,
			PhysicalProperties = roblox.PhysicalProperties,
			BrickColor = roblox.BrickColor,
			Instance = InstanceClass,
			RaycastParams = {
				new = function()
					return { FilterType = nil, FilterDescendantsInstances = {}, IgnoreWater = false }
				end,
			},
			TweenInfo = {
				new = function(time)
					return { Time = time or 1 }
				end,
			},

			--[[ Virtual time. os.clock and os.time are what the services use
			     for every deadline, so overriding them is what makes the whole
			     simulation steppable. ]]
			os = setmetatable({
				clock = scheduler.clock,
				time = scheduler.time,
			}, { __index = os }),

			task = {
				spawn = scheduler.spawn,
				defer = scheduler.defer,
				delay = scheduler.delay,
				wait = scheduler.wait,
				cancel = scheduler.cancel,
			},

			require = function(target)
				return requireNode(target)
			end,
		}
	end

	function requireNode(target)
		if overrides[target] ~= nil then
			return overrides[target]
		end
		if type(target) ~= "table" or not target._filePath then
			error(("[sim] require() needs a module node, got %s"):format(tostring(target)), 2)
		end
		if cache[target] ~= nil then
			return cache[target]
		end

		local source = fs.readFile(target._filePath)
		local chunk = luau.load(source, {
			debugName = target._filePath,
			environment = buildEnvironment(target),
			injectGlobals = true,
		})
		local result = chunk()
		cache[target] = result == nil and false or result
		return result
	end

	--[[ Swap out Util.Net before anything requires it. ]]
	overrides[sharedTree:FindFirstChild("Util"):FindFirstChild("Net")] = fakeNet

	server.shared = sharedTree
	server.serverTree = serverTree
	server.net = fakeNet
	server.require = requireNode
	server.workspace = workspaceInstance

	-- ── Boot ───────────────────────────────────────────────────────────────

	local servicesFolder = serverTree:FindFirstChild("Services")
	local booted = {}
	local context = { shared = sharedTree, services = {} }

	for _, name in ipairs(LOAD_ORDER) do
		local node = servicesFolder:FindFirstChild(name)
		if not node then
			sim._onError("missing service " .. name)
		else
			local service = requireNode(node)
			context[name] = service
			context.services[name] = service
			table.insert(booted, { name = name, service = service })
		end
	end

	for _, entry in ipairs(booted) do
		if type(entry.service.init) == "function" then
			local ok, err = pcall(entry.service.init, entry.service, context)
			if not ok then
				sim._onError(entry.name .. ":init " .. tostring(err))
			end
		end
	end

	for _, entry in ipairs(booted) do
		if type(entry.service.start) == "function" then
			local ok, err = pcall(entry.service.start, entry.service)
			if not ok then
				sim._onError(entry.name .. ":start " .. tostring(err))
			end
		end
	end

	server.services = context
	scheduler.drainDeferred()

	-- ── Players ────────────────────────────────────────────────────────────

	local nextUserId = 1000

	--[[ A duck-typed player. The services only ever use these fields, and a
	     plain table keeps the character swap (death, rescue) fully controllable. ]]
	local function makeCharacter(player)
		local character = newInstance("Model")
		character.Name = player.Name

		local root = newInstance("Part")
		root.Name = "HumanoidRootPart"
		root.Parent = character
		character.PrimaryPart = root

		local humanoid = newInstance("Humanoid")
		humanoid.Parent = character

		--[[ Parented to workspace, as the engine does. This matters: code that
		     guards on `character.Parent` before acting — `_die`'s delayed
		     corpse destroy, for one — would silently never run against an
		     unparented character, and the test would pass for the wrong
		     reason. ]]
		character.Parent = workspaceInstance

		return character
	end

	function server.addPlayer(name)
		nextUserId += 1
		local player
		player = {
			Name = name or ("Player" .. nextUserId),
			DisplayName = name or ("Player" .. nextUserId),
			UserId = nextUserId,
			Parent = playersService,
			Character = nil,
			RespawnLocation = nil,
			CharacterAdded = newSignal("CharacterAdded"),
			CharacterRemoving = newSignal("CharacterRemoving"),
			LoadCharacter = function(self)
				if self.Character then
					self.Character:Destroy()
				end
				self.Character = makeCharacter(self)
				self.CharacterAdded:Fire(self.Character)
			end,
			Kick = function() end,
			IsA = function(_, query)
				return query == "Player" or query == "Instance"
			end,
		}

		table.insert(players, player)
		playerAdded:Fire(player)
		scheduler.drainDeferred()
		return player
	end

	function server.disconnect(player)
		local index = table.find(players, player)
		if index then
			table.remove(players, index)
		end
		--[[ Matches the engine: Parent is cleared before PlayerRemoving fires,
		     which DataService's mid-load release check depends on. ]]
		player.Parent = nil
		playerRemoving:Fire(player)
		scheduler.drainDeferred()
	end

	-- ── Driving ────────────────────────────────────────────────────────────

	--[[
		Run a handler to completion, even if it yields.

		Several handlers call task.wait — ExpeditionService reloads a character
		on rescue and then waits a tick for the CharacterAdded handlers. Calling
		those directly from the main thread would throw "attempt to yield from
		outside a coroutine", so the handler runs INSIDE a coroutine and virtual
		time is pumped until it finishes.

		Time therefore advances a little during an invoke, which is also what
		happens in the real game.
	]]
	local function runToCompletion(label, handler, player, payload)
		local result
		local finished = false
		local failure

		local thread = coroutine.create(function()
			result = handler(player, payload)
			finished = true
		end)

		local ok, err = coroutine.resume(thread)
		if not ok then
			failure = err
			finished = true
		end

		local guard = 0
		while not finished do
			guard += 1
			if guard > 2000 then
				failure = "handler never completed; it is waiting on something the simulation never supplies"
				break
			end
			scheduler.advanceTo(scheduler.now + 0.05)
			if coroutine.status(thread) == "dead" and not finished then
				--[[ The coroutine died without setting `finished`, which means
				     it errored after its first yield. ]]
				failure = failure or "handler died after yielding"
				break
			end
		end

		scheduler.drainDeferred()

		if failure then
			sim._onError(("%s: %s"):format(label, tostring(failure)))
			return nil, failure
		end

		return result, nil
	end

	function server.invoke(player, route, payload)
		local handler = requestHandlers[route]
		if not handler then
			error(("[sim] no handler registered for request route %q"):format(tostring(route)), 2)
		end

		local result, failure = runToCompletion("invoke " .. tostring(route), handler, player, payload)
		if failure then
			--[[ A distinctive reason, so a test asserting a SPECIFIC refusal
			     cannot be satisfied by a crash. assertNoErrors catches it too. ]]
			return { ok = false, reason = "sim_error", error = tostring(failure) }
		end
		return result == nil and { ok = true } or result
	end

	function server.send(player, route, payload)
		local handler = eventHandlers[route]
		if not handler then
			error(("[sim] no handler registered for event route %q"):format(tostring(route)), 2)
		end
		runToCompletion("send " .. tostring(route), handler, player, payload)
	end

	function server.hasRoute(route)
		return requestHandlers[route] ~= nil or eventHandlers[route] ~= nil
	end

	function server.pushes(player, route)
		local byUser = pushed[player.UserId]
		if not byUser then
			return {}
		end
		return byUser[route] or {}
	end

	function server.lastPush(player, route)
		local list = server.pushes(player, route)
		return list[#list]
	end

	function server.pushCount(player, route)
		return #server.pushes(player, route)
	end

	function server.clearPushes()
		pushed = {}
	end

	--[[ One simulation step: move virtual time forward and fire a Heartbeat,
	     which is what drives every service loop. ]]
	function server.step(dt)
		dt = dt or 1 / 30
		scheduler.advanceTo(scheduler.now + dt)
		heartbeat:Fire(dt)
		scheduler.drainDeferred()
	end

	--[[ Advance `seconds` of simulated time in `dt` slices. The slice size
	     matters: services accumulate Heartbeat deltas and act on thresholds, so
	     too coarse a slice would skip their work. ]]
	function server.advance(seconds, dt)
		dt = dt or 0.25
		local steps = math.max(1, math.ceil(seconds / dt))
		for _ = 1, steps do
			server.step(dt)
		end
	end

	function server.shutdown()
		if server._bindToClose then
			local ok, err = pcall(server._bindToClose)
			if not ok then
				sim._onError("BindToClose: " .. tostring(err))
			end
			scheduler.drainDeferred()
		end
	end

	function server.now()
		return scheduler.now
	end

	--[[ Fail a test loudly if the server logged an internal error. A green
	     assertion over a server that threw ten pcall'd faults is not a pass. ]]
	function server.assertNoErrors(expect, context_)
		if #errors > 0 then
			expect.fail(
				("%s: the simulated server reported %d error(s):\n  %s"):format(
					context_ or "sim",
					#errors,
					table.concat(errors, "\n  ")
				)
			)
		end
	end

	return server
end

return sim
