--[[
	PartyService.lua
	Solo, private and public parties, readiness, and the leader's limited powers.

	What a leader can do
	────────────────────
	Set the difficulty, mark a location on the party map, and start the
	expedition. That is the complete list.

	What a leader cannot do
	───────────────────────
	Touch another player's storage, colony, inventory, bag, role or progression.
	This is not enforced by checking "is leader" in those systems — it is
	enforced by those systems only ever reading the ACTING player's own profile.
	There is no code path that takes a target userId for a resource operation, so
	leadership cannot be escalated into theft.

	Loot
	────
	There is no shared loot pool. Harvests and drops go straight into the
	harvester's or killer's own bag, so there is nothing to race for and nothing
	to steal. Rewards are allocated per player at extraction.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local DifficultyConfig = require(Shared.Config.DifficultyConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local RoleConfig = require(Shared.Config.RoleConfig)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("PartyService")

local PartyService = {}
PartyService.__index = PartyService

local CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" -- no look-alikes
local CODE_LENGTH = 4

function PartyService.new()
	local self = setmetatable({}, PartyService)
	self._parties = {} -- [partyId] = party
	self._byUser = {} -- [userId] = partyId
	self._byCode = {} -- [code] = partyId
	self._nextId = 1

	self.partyChanged = Signal.new("partyChanged")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lookup
-- ─────────────────────────────────────────────────────────────────────────────

function PartyService:partyOf(player)
	local partyId = self._byUser[player.UserId]
	return partyId and self._parties[partyId] or nil
end

function PartyService:membersOf(party)
	local out = {}
	for userId in pairs(party.members) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			table.insert(out, player)
		end
	end
	table.sort(out, function(a, b)
		return a.UserId < b.UserId
	end)
	return out
end

function PartyService:isLeader(player)
	local party = self:partyOf(player)
	return party ~= nil and party.leaderUserId == player.UserId
end

function PartyService:size(party)
	local n = 0
	for _ in pairs(party.members) do
		n += 1
	end
	return n
end

function PartyService:maxSize()
	return GameConfig.Party.MvpMaxSize
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Creation
-- ─────────────────────────────────────────────────────────────────────────────

function PartyService:_generateCode()
	for _ = 1, 50 do
		local code = ""
		for _ = 1, CODE_LENGTH do
			local index = math.random(1, #CODE_ALPHABET)
			code ..= string.sub(CODE_ALPHABET, index, index)
		end
		if not self._byCode[code] then
			return code
		end
	end
	--[[ Astronomically unlikely with a 32^4 space and a handful of parties, but
	     a nil code would break joining, so fall back to the party id. ]]
	return "P" .. tostring(self._nextId)
end

--[[
	@param visibility "private" | "public"
]]
function PartyService:create(player, visibility, difficultyId)
	if self.context.ExpeditionService:sessionOf(player) then
		return { ok = false, reason = Enums.Reject.WrongZone, detail = "in_expedition" }
	end

	local existing = self:partyOf(player)
	if existing then
		self:leave(player)
	end

	local partyId = self._nextId
	self._nextId += 1

	local code = self:_generateCode()
	local party = {
		id = partyId,
		code = code,
		leaderUserId = player.UserId,
		visibility = (visibility == "public") and "public" or "private",
		difficultyId = DifficultyConfig.isValid(difficultyId) and difficultyId or DifficultyConfig.Default,
		members = {},
		marks = {},
		createdAt = os.clock(),
	}

	party.members[player.UserId] = { ready = false, joinedAt = os.clock() }
	self._parties[partyId] = party
	self._byUser[player.UserId] = partyId
	self._byCode[code] = partyId

	self:push(party)
	log:info("%s created %s party %s", player.Name, party.visibility, code)
	return { ok = true, party = self:snapshot(party, player) }
end

--[[ Solo play is a party of one, so every downstream system has exactly one
     shape to handle. There is no separate solo code path. ]]
function PartyService:ensureParty(player)
	local party = self:partyOf(player)
	if party then
		return party
	end
	self:create(player, "private", nil)
	return self:partyOf(player)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Joining and leaving
-- ─────────────────────────────────────────────────────────────────────────────

function PartyService:join(player, code)
	if type(code) ~= "string" then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	code = string.upper(string.gsub(code, "%s", ""))

	local partyId = self._byCode[code]
	local party = partyId and self._parties[partyId]
	if not party then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "no_such_party" }
	end
	if party.expeditionStarted then
		return { ok = false, reason = Enums.Reject.Busy, detail = "already_started" }
	end
	if self:size(party) >= self:maxSize() then
		return { ok = false, reason = Enums.Reject.LimitReached, detail = "party_full" }
	end
	if self.context.ExpeditionService:sessionOf(player) then
		return { ok = false, reason = Enums.Reject.WrongZone, detail = "in_expedition" }
	end

	local current = self:partyOf(player)
	if current then
		if current.id == party.id then
			return { ok = true, party = self:snapshot(party, player) }
		end
		self:leave(player)
	end

	party.members[player.UserId] = { ready = false, joinedAt = os.clock() }
	self._byUser[player.UserId] = party.id

	self:push(party)
	self:notify(party, {
		kind = "info",
		title = ("%s joined"):format(player.DisplayName),
		body = ("%d of %d."):format(self:size(party), self:maxSize()),
	})
	return { ok = true, party = self:snapshot(party, player) }
end

function PartyService:leave(player)
	local party = self:partyOf(player)
	if not party then
		return { ok = true }
	end

	party.members[player.UserId] = nil
	self._byUser[player.UserId] = nil

	if self:size(party) == 0 then
		self._byCode[party.code] = nil
		self._parties[party.id] = nil
		return { ok = true, disbanded = true }
	end

	--[[ Leadership passes to the longest-standing remaining member, so a party
	     is never left without someone able to start it. ]]
	if party.leaderUserId == player.UserId then
		local bestUserId, bestJoinedAt
		for userId, entry in pairs(party.members) do
			if not bestJoinedAt or entry.joinedAt < bestJoinedAt then
				bestUserId, bestJoinedAt = userId, entry.joinedAt
			end
		end
		party.leaderUserId = bestUserId
		local newLeader = bestUserId and Players:GetPlayerByUserId(bestUserId)
		self:notify(party, {
			kind = "info",
			title = "New expedition leader",
			body = newLeader and newLeader.DisplayName or "Unknown",
		})
	end

	self:push(party)
	return { ok = true }
end

function PartyService:setReady(player, ready)
	local party = self:partyOf(player)
	if not party then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	local entry = party.members[player.UserId]
	if not entry then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	entry.ready = ready == true
	self:push(party)
	return { ok = true, ready = entry.ready }
end

function PartyService:allReady(party)
	for userId, entry in pairs(party.members) do
		if userId ~= party.leaderUserId and not entry.ready then
			return false
		end
	end
	return true
end

function PartyService:setDifficulty(player, difficultyId)
	local party = self:partyOf(player)
	if not party then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	if party.leaderUserId ~= player.UserId then
		return { ok = false, reason = Enums.Reject.NoPermission }
	end
	if not DifficultyConfig.isValid(difficultyId) then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	party.difficultyId = difficultyId
	--[[ Changing the difficulty clears readiness: everyone agreed to the old
	     one, not this one. ]]
	for _, entry in pairs(party.members) do
		entry.ready = false
	end
	self:push(party)
	return { ok = true, difficultyId = difficultyId }
end

--[[ A direct invite, which is just a notification carrying the code. The
     recipient still has to accept, so an invite cannot drag anyone anywhere. ]]
function PartyService:invite(player, targetUserId)
	local party = self:partyOf(player)
	if not party then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "not_present" }
	end
	if self:size(party) >= self:maxSize() then
		return { ok = false, reason = Enums.Reject.LimitReached }
	end

	Net.fire(target, Routes.Push.Notify, {
		kind = "invite",
		title = ("%s invited you"):format(player.DisplayName),
		body = ("Party code %s"):format(party.code),
		code = party.code,
		expiresIn = GameConfig.Party.InviteTimeout,
	})
	return { ok = true }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Map marks
-- ─────────────────────────────────────────────────────────────────────────────

--[[ The leader may mark a point of interest. Marks are capped and expire, so
     they cannot be used to spam the party's screen. ]]
function PartyService:mark(player, position, label)
	local party = self:partyOf(player)
	if not party then
		return
	end
	if party.leaderUserId ~= player.UserId then
		return
	end
	if typeof(position) ~= "Vector3" then
		return
	end

	table.insert(party.marks, {
		position = position,
		label = (type(label) == "string" and string.sub(label, 1, 24)) or "Objective",
		at = os.clock(),
		byName = player.DisplayName,
	})
	while #party.marks > 4 do
		table.remove(party.marks, 1)
	end

	Net.fireList(self:membersOf(party), Routes.Push.PartySync, { marks = party.marks })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public listing
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Public parties still forming, for the matchmaking list. Private parties are
     never listed; they are code-only. ]]
function PartyService:publicListing()
	local out = {}
	for _, party in pairs(self._parties) do
		if party.visibility == "public" and not party.expeditionStarted and self:size(party) < self:maxSize() then
			local leader = Players:GetPlayerByUserId(party.leaderUserId)
			table.insert(out, {
				code = party.code,
				leader = leader and leader.DisplayName or "Unknown",
				size = self:size(party),
				maxSize = self:maxSize(),
				difficultyId = party.difficultyId,
			})
		end
	end
	table.sort(out, function(a, b)
		return a.code < b.code
	end)
	return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Replication
-- ─────────────────────────────────────────────────────────────────────────────

function PartyService:snapshot(party, viewer)
	local members = {}
	for userId, entry in pairs(party.members) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			local roleId = self.context.RoleService:roleOf(player)
			local role = RoleConfig.get(roleId)
			table.insert(members, {
				userId = userId,
				name = player.DisplayName,
				ready = entry.ready,
				isLeader = party.leaderUserId == userId,
				roleId = roleId,
				roleName = role and role.name or roleId,
				roleIcon = role and role.icon or "?",
				roleAccent = role and role.accent or nil,
			})
		end
	end
	table.sort(members, function(a, b)
		return a.userId < b.userId
	end)

	return {
		code = party.code,
		visibility = party.visibility,
		difficultyId = party.difficultyId,
		leaderUserId = party.leaderUserId,
		isLeader = viewer ~= nil and party.leaderUserId == viewer.UserId,
		members = members,
		size = #members,
		maxSize = self:maxSize(),
		allReady = self:allReady(party),
		marks = party.marks,
		started = party.expeditionStarted == true,
		publicParties = self:publicListing(),
	}
end

function PartyService:push(party)
	for _, player in ipairs(self:membersOf(party)) do
		Net.fire(player, Routes.Push.PartySync, self:snapshot(party, player))
	end
	self.partyChanged:Fire(party)
end

function PartyService:notify(party, payload)
	Net.fireList(self:membersOf(party), Routes.Push.Notify, payload)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function PartyService:init(context)
	self.context = context
end

function PartyService:start()
	Net.handle(Routes.Request.CreateParty, function(player, payload)
		payload = type(payload) == "table" and payload or {}
		return self:create(player, payload.visibility, payload.difficultyId)
	end)

	Net.handle(Routes.Request.JoinParty, function(player, payload)
		if type(payload) ~= "table" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:join(player, payload.code)
	end)

	Net.handle(Routes.Request.LeaveParty, function(player)
		return self:leave(player)
	end)

	Net.handle(Routes.Request.SetReady, function(player, payload)
		payload = type(payload) == "table" and payload or {}
		if payload.difficultyId then
			local result = self:setDifficulty(player, payload.difficultyId)
			if not result.ok then
				return result
			end
		end
		return self:setReady(player, payload.ready)
	end)

	Net.handle(Routes.Request.InviteToParty, function(player, payload)
		if type(payload) ~= "table" or type(payload.userId) ~= "number" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:invite(player, math.floor(payload.userId))
	end)

	Net.listen(Routes.Event.MarkLocation, function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		self:mark(player, payload.position, payload.label)
	end, Routes.limitsFor(Routes.Event.MarkLocation))

	Players.PlayerRemoving:Connect(function(player)
		self:leave(player)
	end)

	log:info("ready (party cap %d, design target %d)", self:maxSize(), GameConfig.Party.DesignMaxSize)
end

return PartyService.new()
