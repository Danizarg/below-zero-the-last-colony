--[[
	DataService.lua
	Persistent profiles with session locking, retries and versioned migration.

	Design decisions, and why:

	Session locking. Each profile records the JobId of the server that owns it.
	A second server that finds a live lock waits, retries, and then loads the
	profile READ-ONLY rather than stealing it. Two servers writing one profile is
	how duplication exploits and lost colonies happen, and a read-only session is
	a far better failure than a corrupted save.

	Stale locks. A crashed server never releases its lock, so a lock older than
	LOCK_TIMEOUT is treated as abandoned and may be taken. LOCK_TIMEOUT is
	comfortably longer than the autosave interval that refreshes it.

	UpdateAsync, not SetAsync. Every write is a read-modify-write under the
	DataStore's own transaction, so a concurrent write cannot clobber a newer
	value wholesale.

	Mock mode. When DataStores are unavailable — Studio without API access, or a
	DataStore outage — the service falls back to an in-memory store and says so,
	loudly and once. Gameplay keeps working and nothing pretends to be saved.

	No client ever reads or writes a profile directly. Services mutate the table
	returned by :get(); replication is a separate, explicit snapshot.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local GameConfig = require(Shared.Config.GameConfig)
local Migrations = require(Shared.Data.Migrations)
local ProfileTemplate = require(Shared.Data.ProfileTemplate)
local Logger = require(Shared.Util.Logger)
local Signal = require(Shared.Util.Signal)
local TableUtil = require(Shared.Util.TableUtil)

local log = Logger.new("DataService")

local DataService = {}
DataService.__index = DataService

-- Tuning.
local LOCK_TIMEOUT = 120 -- seconds before another server may take an abandoned lock
local AUTOSAVE_INTERVAL = 45 -- must stay well under LOCK_TIMEOUT
local LOAD_ATTEMPTS = 5
local SAVE_ATTEMPTS = 4
local LOCK_RETRY_DELAY = 3
local LOCK_RETRY_ATTEMPTS = 4
local MAX_RECEIPTS_KEPT = 60

function DataService.new()
	local self = setmetatable({}, DataService)

	self._profiles = {} -- [userId] = { data, readOnly, loaded, dirty, lastSave }
	self._loading = {} -- [userId] = true while a load is in flight
	self._mockStore = {} -- [key] = profile, used when DataStores are unavailable
	self._useMock = not GameConfig.UseDataStore
	self._mockReported = false
	self._jobId = (game.JobId ~= "" and game.JobId) or ("studio-" .. tostring(math.random(1, 1e9)))
	self._shuttingDown = false

	self.profileLoaded = Signal.new("profileLoaded")
	self.profileReleasing = Signal.new("profileReleasing")

	self._store = nil
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Store access
-- ─────────────────────────────────────────────────────────────────────────────

local function keyFor(userId)
	return "player_" .. tostring(userId)
end

function DataService:_getStore()
	if self._useMock then
		return nil
	end
	if self._store then
		return self._store
	end
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(GameConfig.DataStoreName)
	end)
	if not ok or not store then
		self:_fallBackToMock("GetDataStore failed: " .. tostring(store))
		return nil
	end
	self._store = store
	return store
end

function DataService:_fallBackToMock(reason)
	if self._useMock then
		return
	end
	self._useMock = true
	if not self._mockReported then
		self._mockReported = true
		log:warn(
			"falling back to IN-MEMORY profiles; nothing will persist across sessions. Reason: %s",
			tostring(reason)
		)
		if RunService:IsStudio() then
			log:warn(
				"in Studio, enable Game Settings > Security > Enable Studio Access to API Services to test real saving"
			)
		end
	end
end

--[[ Retry wrapper with backoff. Returns ok, result. ]]
function DataService:_attempt(what, attempts, fn)
	local delay = 0.5
	for tryIndex = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		log:warn("%s attempt %d/%d failed: %s", what, tryIndex, attempts, tostring(result))
		if tryIndex < attempts then
			task.wait(delay)
			delay = math.min(delay * 2, 8)
		else
			return false, result
		end
	end
	return false, nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Mock store (in-memory)
-- ─────────────────────────────────────────────────────────────────────────────

function DataService:_mockUpdate(key, transform)
	local current = self._mockStore[key]
	local updated = transform(current and TableUtil.deepCopy(current) or nil)
	if updated ~= nil then
		self._mockStore[key] = TableUtil.deepCopy(updated)
	end
	return updated
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Loading
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Load (or create) a profile and take the session lock.

	@return entry  { data, readOnly, loaded } — never nil; a total failure still
	               yields a playable in-memory profile marked readOnly, so a
	               DataStore outage does not lock players out of the game.
]]
function DataService:load(player)
	local userId = player.UserId
	if self._profiles[userId] then
		return self._profiles[userId]
	end
	if self._loading[userId] then
		-- Another coroutine is already loading this profile; wait for it.
		while self._loading[userId] do
			task.wait(0.1)
		end
		return self._profiles[userId]
	end

	self._loading[userId] = true
	local key = keyFor(userId)
	local now = os.time()

	local entry = {
		data = nil,
		readOnly = false,
		loaded = false,
		dirty = false,
		lastSave = now,
		lockHeld = false,
	}

	local lockedOut = false
	local loadedData

	for lockTry = 1, LOCK_RETRY_ATTEMPTS do
		local store = self:_getStore()

		local transform = function(current)
			if current == nil then
				local fresh = ProfileTemplate.create(now, player.Name)
				fresh.meta.lockJobId = self._jobId
				fresh.meta.lockTimestamp = now
				fresh.meta.sessionCount = 1
				return fresh
			end

			local lockJobId = current.meta and current.meta.lockJobId or ""
			local lockTimestamp = (current.meta and current.meta.lockTimestamp) or 0
			local lockAge = now - lockTimestamp

			if lockJobId ~= "" and lockJobId ~= self._jobId and lockAge < LOCK_TIMEOUT then
				--[[ Someone else owns it. Returning nil aborts this UpdateAsync
				     without writing, so the other server's lock is untouched. ]]
				return nil
			end

			current.meta = current.meta or {}
			current.meta.lockJobId = self._jobId
			current.meta.lockTimestamp = now
			current.meta.sessionCount = (current.meta.sessionCount or 0) + 1
			return current
		end

		local ok, result
		if store then
			ok, result = self:_attempt("profile load", LOAD_ATTEMPTS, function()
				return store:UpdateAsync(key, transform)
			end)
			if not ok then
				self:_fallBackToMock("UpdateAsync failed during load")
				store = nil
			end
		end

		if not store then
			ok, result = true, self:_mockUpdate(key, transform)
		end

		if ok and result ~= nil then
			loadedData = result
			entry.lockHeld = true
			break
		end

		if lockTry < LOCK_RETRY_ATTEMPTS then
			log:info(
				"profile %d is locked by another session; retrying in %ds (%d/%d)",
				userId,
				LOCK_RETRY_DELAY,
				lockTry,
				LOCK_RETRY_ATTEMPTS
			)
			task.wait(LOCK_RETRY_DELAY)
			now = os.time()
		else
			lockedOut = true
		end
	end

	if lockedOut or not loadedData then
		--[[ Could not take the lock. Give the player a playable session from a
		     fresh template, flagged read-only so nothing is ever written back
		     over the profile the other server owns. ]]
		log:warn(
			"could not acquire the profile lock for %s (%d); starting a READ-ONLY session",
			player.Name,
			userId
		)
		entry.data = ProfileTemplate.create(os.time(), player.Name)
		entry.readOnly = true
		entry.loaded = true
		self._profiles[userId] = entry
		self._loading[userId] = nil
		self.profileLoaded:Fire(player, entry)
		return entry
	end

	-- Migrate, then reconcile against the template.
	local migration = Migrations.prepare(loadedData, ProfileTemplate.Template)
	if not migration.ok then
		log:warn(
			"migration refused for %s (%d): %s — session is READ-ONLY to protect the save",
			player.Name,
			userId,
			tostring(migration.reason)
		)
		entry.data = TableUtil.reconcile(loadedData, ProfileTemplate.Template)
		entry.readOnly = true
	else
		entry.data = migration.profile
		if #migration.applied > 0 then
			log:info(
				"migrated %s (%d) from v%d to v%d: %s",
				player.Name,
				userId,
				migration.from,
				migration.to,
				table.concat(migration.applied, "; ")
			)
		end
	end

	entry.data.meta.lastSeenAt = os.time()
	entry.loaded = true

	self._profiles[userId] = entry
	self._loading[userId] = nil

	log:info(
		"loaded profile for %s (%d)%s",
		player.Name,
		userId,
		entry.readOnly and " [read-only]" or ""
	)
	self.profileLoaded:Fire(player, entry)
	return entry
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Access
-- ─────────────────────────────────────────────────────────────────────────────

--[[ The live profile table. Mutate it directly; call :markDirty() afterwards. ]]
function DataService:get(player)
	local entry = self._profiles[player.UserId]
	return entry and entry.loaded and entry.data or nil
end

function DataService:getEntry(player)
	return self._profiles[player.UserId]
end

function DataService:isLoaded(player)
	local entry = self._profiles[player.UserId]
	return entry ~= nil and entry.loaded
end

function DataService:isReadOnly(player)
	local entry = self._profiles[player.UserId]
	return entry == nil or entry.readOnly
end

function DataService:markDirty(player)
	local entry = self._profiles[player.UserId]
	if entry then
		entry.dirty = true
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Saving
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Write a profile back.

	@param options { release = boolean, force = boolean }
	  release  drop the session lock afterwards (on leave / shutdown)
	  force    save even when not dirty
]]
function DataService:save(player, options)
	options = options or {}
	local userId = player.UserId
	local entry = self._profiles[userId]
	if not entry or not entry.loaded then
		return false, "not_loaded"
	end

	if entry.readOnly then
		--[[ Read-only sessions never write. Saying so on release makes the
		     situation visible in logs instead of looking like a silent success. ]]
		if options.release then
			log:info("released read-only session for %s (%d); nothing written", player.Name, userId)
			self._profiles[userId] = nil
		end
		return false, "read_only"
	end

	if not entry.dirty and not options.force and not options.release then
		return true, "clean"
	end

	local data = entry.data
	data.meta.lastSeenAt = os.time()
	self:_trimReceipts(data)

	local key = keyFor(userId)
	local jobId = self._jobId
	local release = options.release == true

	local transform = function(current)
		--[[ Only write if we still hold the lock, or the stored copy is gone.
		     If another server has taken over, abort: their data is newer than
		     ours and overwriting it would roll a player's colony back. ]]
		if current and current.meta and current.meta.lockJobId ~= "" and current.meta.lockJobId ~= jobId then
			local age = os.time() - (current.meta.lockTimestamp or 0)
			if age < LOCK_TIMEOUT then
				return nil
			end
		end

		local outgoing = TableUtil.deepCopy(data)
		outgoing.meta.lockJobId = release and "" or jobId
		outgoing.meta.lockTimestamp = release and 0 or os.time()
		return outgoing
	end

	local store = self:_getStore()
	local ok, result

	if store then
		ok, result = self:_attempt("profile save", SAVE_ATTEMPTS, function()
			return store:UpdateAsync(key, transform)
		end)
		if not ok then
			self:_fallBackToMock("UpdateAsync failed during save")
			store = nil
		end
	end

	if not store then
		ok, result = true, self:_mockUpdate(key, transform)
	end

	if not ok then
		data.diagnostics.saveFailures = (data.diagnostics.saveFailures or 0) + 1
		log:fault("save failed for %s (%d) after %d attempts", player.Name, userId, SAVE_ATTEMPTS)
		return false, "write_failed"
	end

	if result == nil then
		log:warn(
			"save aborted for %s (%d): the profile lock is held by another session",
			player.Name,
			userId
		)
		entry.readOnly = true
		return false, "lock_lost"
	end

	entry.dirty = false
	entry.lastSave = os.time()

	if release then
		entry.lockHeld = false
		self._profiles[userId] = nil
		log:info("saved and released %s (%d)", player.Name, userId)
	end

	return true
end

--[[ Receipt history is unbounded otherwise, and a profile has a size limit.
     Keeping the most recent entries preserves idempotency for any purchase a
     player could plausibly retry. ]]
function DataService:_trimReceipts(data)
	local monetization = data.monetization
	if not monetization then
		return
	end
	monetization.receipts = monetization.receipts or {}
	monetization.receiptOrder = monetization.receiptOrder or {}

	while #monetization.receiptOrder > MAX_RECEIPTS_KEPT do
		local oldest = table.remove(monetization.receiptOrder, 1)
		if oldest then
			monetization.receipts[oldest] = nil
		end
	end
end

--[[ Record a fulfilled receipt. Returns false if it was already recorded, which
     is exactly the idempotency check MonetizationService needs. ]]
function DataService:recordReceipt(player, purchaseId)
	local data = self:get(player)
	if not data then
		return false
	end
	local monetization = data.monetization
	monetization.receipts = monetization.receipts or {}
	monetization.receiptOrder = monetization.receiptOrder or {}

	local key = tostring(purchaseId)
	if monetization.receipts[key] then
		return false
	end
	monetization.receipts[key] = os.time()
	table.insert(monetization.receiptOrder, key)
	self:markDirty(player)
	return true
end

function DataService:hasReceipt(player, purchaseId)
	local data = self:get(player)
	if not data then
		return false
	end
	return (data.monetization.receipts or {})[tostring(purchaseId)] ~= nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function DataService:init(context)
	self.context = context
end

function DataService:start()
	--[[ Loads are DEFERRED, not spawned.

	     profileLoaded is what ColonyService, RoleService and MonetizationService
	     hang their setup off, and they subscribe in their own :start(), which
	     runs after this one. With a real DataStore the UpdateAsync call yields
	     and everything works by luck; in mock mode (Studio without API access)
	     nothing yields, so a task.spawn here would fire profileLoaded before
	     anyone was listening and the player would arrive to an empty colony.
	     task.defer pushes the load past the end of the bootstrap. ]]
	for _, player in ipairs(Players:GetPlayers()) do
		task.defer(function()
			self:load(player)
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		task.defer(function()
			self:load(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.profileReleasing:Fire(player, self._profiles[player.UserId])
		self:save(player, { release = true, force = true })
	end)

	-- Autosave loop, which also refreshes the session lock.
	task.spawn(function()
		while not self._shuttingDown do
			task.wait(AUTOSAVE_INTERVAL)
			if self._shuttingDown then
				break
			end
			for _, player in ipairs(Players:GetPlayers()) do
				local entry = self._profiles[player.UserId]
				if entry and entry.loaded and not entry.readOnly then
					--[[ Force the write even when clean: it refreshes
					     lockTimestamp, which is what stops another server
					     deciding this lock is abandoned. ]]
					self:save(player, { force = true })
				end
			end
		end
	end)

	--[[ BindToClose gets roughly 30 seconds. Save everyone in parallel and wait
	     for the batch rather than serialising, which would run out of time with
	     a full server. ]]
	game:BindToClose(function()
		self._shuttingDown = true
		local pending = 0
		local finished = Instance.new("BindableEvent")

		for _, player in ipairs(Players:GetPlayers()) do
			pending += 1
			task.spawn(function()
				self:save(player, { release = true, force = true })
				pending -= 1
				if pending <= 0 then
					finished:Fire()
				end
			end)
		end

		if pending > 0 then
			task.delay(25, function()
				if pending > 0 then
					log:fault("shutdown save timed out with %d profiles outstanding", pending)
					finished:Fire()
				end
			end)
			finished.Event:Wait()
		end

		log:info("shutdown saves complete")
	end)

	log:info("ready (jobId=%s, store=%s)", self._jobId, self._useMock and "in-memory" or GameConfig.DataStoreName)
end

return DataService.new()
