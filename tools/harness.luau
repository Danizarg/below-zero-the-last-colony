--[[
	tools/harness.luau
	A fake Roblox instance tree over the real source files, for Lune.

	Lune is a standalone Luau runtime that provides the Roblox DATATYPES
	(Vector3, Color3, Enum, Instance, ...) without the engine. That is enough to
	load and run any module that does not actually touch a live DataModel —
	which, by design, is everything under src/shared.

	This module builds a tree that mirrors what Rojo would sync, hands each
	module a `script` and a `require` that resolve against it, and stubs the
	services that modules capture at require time.

	Used by:
		tools/run-tests.luau    runs the spec suite
		tools/load-check.luau   requires every module to prove it loads

	Deliberate limits: the service stubs are inert. They exist so that
	`local Players = game:GetService("Players")` at the top of a module
	succeeds; calling into them does nothing useful. Anything that needs real
	engine behaviour belongs in the Studio checklist in SETUP.md §5.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local luneTask = require("@lune/task")

local harness = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Datatypes Lune does not ship
-- ─────────────────────────────────────────────────────────────────────────────

--[[ @lune/roblox covers the value types (Vector3, Color3, Enum, ...) but not
     the few engine-coupled ones below. They are stubbed rather than skipped so
     that modules constructing them at require time still load — which is the
     whole point of the load check. Behaviour is inert: a test that depends on
     a real raycast or a real tween belongs in Studio. ]]

local RaycastParamsStub = {}
RaycastParamsStub.new = function()
	return {
		FilterType = nil,
		FilterDescendantsInstances = {},
		IgnoreWater = false,
		CollisionGroup = "Default",
		RespectCanCollide = false,
	}
end

local TweenInfoStub = {}
TweenInfoStub.new = function(time, easingStyle, easingDirection, repeatCount, reverses, delayTime)
	return {
		Time = time or 1,
		EasingStyle = easingStyle,
		EasingDirection = easingDirection,
		RepeatCount = repeatCount or 0,
		Reverses = reverses or false,
		DelayTime = delayTime or 0,
	}
end

local OverlapParamsStub = {}
OverlapParamsStub.new = function()
	return { FilterType = nil, FilterDescendantsInstances = {}, MaxParts = 0 }
end

--[[ `task` is a Roblox global, not a Luau one, so it has to be supplied. These
     map onto Lune's own scheduler, which means code under test that spawns or
     waits actually behaves rather than silently doing nothing. ]]
local taskStub = {
	spawn = luneTask.spawn,
	defer = luneTask.defer,
	delay = luneTask.delay,
	wait = luneTask.wait,
	cancel = luneTask.cancel,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Nodes
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Mirrors Rojo's naming so `script.Parent.Foo` resolves to the same thing it
     would after a sync: the .lua suffix is dropped, and .server/.client mark
     the class. ]]
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

local function newNode(name, className, filePath, parent)
	local node = {
		Name = name,
		ClassName = className,
		_filePath = filePath,
		_children = {},
		Parent = parent,
	}

	function node:GetChildren()
		--[[ Sorted, so spec discovery is deterministic across platforms rather
		     than following filesystem order. ]]
		local names = {}
		for childName in pairs(self._children) do
			table.insert(names, childName)
		end
		table.sort(names)

		local out = {}
		for _, childName in ipairs(names) do
			table.insert(out, self._children[childName])
		end
		return out
	end

	function node:GetDescendants()
		local out = {}
		for _, child in ipairs(self:GetChildren()) do
			table.insert(out, child)
			for _, descendant in ipairs(child:GetDescendants()) do
				table.insert(out, descendant)
			end
		end
		return out
	end

	function node:FindFirstChild(childName)
		return self._children[childName]
	end

	function node:WaitForChild(childName)
		local child = self._children[childName]
		if not child then
			error(
				("[harness] %s has no child %q — the fake tree does not mirror the real one"):format(
					self:GetFullName(),
					tostring(childName)
				),
				2
			)
		end
		return child
	end

	function node:IsA(className)
		if self.ClassName == className then
			return true
		end
		-- Enough of the class hierarchy for what this project actually asks.
		if className == "LuaSourceContainer" then
			return self.ClassName == "ModuleScript"
				or self.ClassName == "Script"
				or self.ClassName == "LocalScript"
		end
		return false
	end

	function node:GetFullName()
		local parts = { self.Name }
		local cursor = self.Parent
		while cursor do
			table.insert(parts, 1, cursor.Name)
			cursor = cursor.Parent
		end
		return table.concat(parts, ".")
	end

	function node:GetAttribute()
		return nil
	end

	function node:SetAttribute() end

	--[[ Children are reachable as fields, which is how every module in this
	     project navigates: `script.Parent.Parent.Config.GameConfig`. ]]
	return setmetatable(node, {
		__index = function(self, key)
			return rawget(self, "_children")[key]
		end,
		__tostring = function(self)
			return rawget(self, "Name")
		end,
	})
end

harness.newNode = newNode

function harness.buildTree(dirPath, nodeName, parent)
	local folder = newNode(nodeName, "Folder", nil, parent)

	for _, entryName in ipairs(fs.readDir(dirPath)) do
		local entryPath = dirPath .. "/" .. entryName

		if fs.isDir(entryPath) then
			folder._children[entryName] = harness.buildTree(entryPath, entryName, folder)
		else
			local name, className = classifyFile(entryName)
			if name then
				--[[ An init file turns its folder into a script, exactly as Rojo
				     does — which is how src/server and src/client are shaped. ]]
				if name == "init" then
					folder.ClassName = className
					folder._filePath = entryPath
				else
					folder._children[name] = newNode(name, className, entryPath, folder)
				end
			end
		end
	end

	return folder
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Service stubs
-- ─────────────────────────────────────────────────────────────────────────────

local function inertSignal()
	return {
		Connect = function()
			return { Disconnect = function() end, Connected = false }
		end,
		Once = function()
			return { Disconnect = function() end, Connected = false }
		end,
		Wait = function() end,
	}
end

harness.inertSignal = inertSignal

--[[ Services modules capture at require time. They only need to EXIST; the
     project calls into them inside functions, which these tools never run. ]]
local function buildServiceStubs()
	local stubs = {}

	stubs.RunService = {
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
		Heartbeat = inertSignal(),
		RenderStepped = inertSignal(),
		Stepped = inertSignal(),
	}

	stubs.Players = {
		LocalPlayer = nil,
		CharacterAutoLoads = true,
		RespawnTime = 3,
		GetPlayers = function()
			return {}
		end,
		GetPlayerByUserId = function()
			return nil
		end,
		GetPlayerFromCharacter = function()
			return nil
		end,
		PlayerAdded = inertSignal(),
		PlayerRemoving = inertSignal(),
	}

	stubs.DataStoreService = {
		GetDataStore = function()
			error("[harness] DataStores need the engine", 2)
		end,
	}

	stubs.MarketplaceService = {
		PromptProductPurchase = function() end,
		PromptGamePassPurchase = function() end,
		UserOwnsGamePassAsync = function()
			return false
		end,
	}

	stubs.TeleportService = {}
	stubs.PathfindingService = {
		CreatePath = function()
			error("[harness] pathfinding needs the engine", 2)
		end,
	}
	stubs.ProximityPromptService = { PromptTriggered = inertSignal() }
	stubs.ContextActionService = { BindAction = function() end, UnbindAction = function() end }
	stubs.UserInputService = {
		TouchEnabled = false,
		KeyboardEnabled = true,
		MouseEnabled = true,
		GetMouseLocation = function()
			return roblox.Vector2.new()
		end,
		InputBegan = inertSignal(),
		InputEnded = inertSignal(),
	}
	stubs.TweenService = {
		Create = function()
			return { Play = function() end, Cancel = function() end }
		end,
	}
	stubs.SoundService = {}
	stubs.Lighting = newNode("Lighting", "Lighting", nil, nil)
	stubs.GuiService = {
		GetGuiInset = function()
			return roblox.Vector2.new()
		end,
	}

	return stubs
end

-- ─────────────────────────────────────────────────────────────────────────────
-- The loader
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	@param options {
		roots = { [serviceName] = node }   extra service stubs (e.g. ReplicatedStorage)
		onMissingService = function(name)   called instead of erroring, optional
	}
	@return loader { require(node), serviceStubs, cache }
]]
function harness.newLoader(options)
	options = options or {}

	local cache = {}
	local loading = {}
	local stubs = buildServiceStubs()
	for name, service in pairs(options.roots or {}) do
		stubs[name] = service
	end

	local loader = { serviceStubs = stubs, cache = cache }

	local gameShim = {
		JobId = "lune-harness",
		PlaceId = 0,
		GetService = function(_, serviceName)
			local service = stubs[serviceName]
			if not service then
				if options.onMissingService then
					return options.onMissingService(serviceName)
				end
				--[[ Loud rather than silent. If a module's dependency closure
				     grows to need a real service, say exactly which one instead
				     of failing somewhere confusing later. ]]
				error(("[harness] GetService(%q) is not stubbed"):format(serviceName), 2)
			end
			return service
		end,
		BindToClose = function() end,
	}

	local workspaceStub = newNode("Workspace", "Workspace", nil, nil)

	local function buildEnvironment(node)
		return {
			script = node,
			game = gameShim,
			workspace = workspaceStub,

			-- Roblox datatypes, which is the whole reason Lune can run this.
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
			Region3 = roblox.Region3,
			Ray = roblox.Ray,
			Enum = roblox.Enum,
			Instance = roblox.Instance,
			PhysicalProperties = roblox.PhysicalProperties,
			BrickColor = roblox.BrickColor,
			Font = roblox.Font,

			-- Supplied by this harness; see the note at the top of the file.
			RaycastParams = RaycastParamsStub,
			OverlapParams = OverlapParamsStub,
			TweenInfo = TweenInfoStub,
			task = taskStub,

			require = function(target)
				return loader.require(target)
			end,
		}
	end

	function loader.require(target)
		if type(target) == "string" then
			error(("[harness] string require(%q) is not used by project code"):format(target), 2)
		end
		if type(target) ~= "table" or not rawget(target, "_filePath") then
			error(("[harness] require() needs a module node; got %s"):format(tostring(target)), 2)
		end

		if cache[target] ~= nil then
			return cache[target]
		end
		if loading[target] then
			error(("[harness] cyclic require of %s"):format(target:GetFullName()), 2)
		end
		loading[target] = true

		local source = fs.readFile(rawget(target, "_filePath"))
		local chunk = luau.load(source, {
			debugName = rawget(target, "_filePath"),
			environment = buildEnvironment(target),
			injectGlobals = true,
		})

		local ok, result = pcall(chunk)
		loading[target] = nil
		if not ok then
			error(result, 0)
		end

		cache[target] = result == nil and false or result
		return result
	end

	return loader
end

--[[ Count the source files in a tree, for a sanity line in the output. ]]
function harness.countModules(node)
	local count = 0
	for _, child in ipairs(node:GetChildren()) do
		if rawget(child, "_filePath") then
			count += 1
		end
		count += harness.countModules(child)
	end
	return count
end

--[[ Every module node under `node`, depth first, with its full dotted name. ]]
function harness.collectModules(node, out)
	out = out or {}
	if rawget(node, "_filePath") and node:IsA("ModuleScript") then
		table.insert(out, node)
	end
	for _, child in ipairs(node:GetChildren()) do
		harness.collectModules(child, out)
	end
	return out
end

return harness
