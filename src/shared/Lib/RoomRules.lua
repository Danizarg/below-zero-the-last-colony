--[[
	RoomRules.lua

	Authoritative generation rules for cave rooms, kept free of Roblox datatypes
	so CaveLayout can be reasoned about and tested on its own.

	RoomConfig holds the visual side (colours, materials, props) and imports these
	rules, so there is exactly one place that defines how many doors a room kind
	may have.

	doorRule fields:
	  exact     required door count
	  min, max  inclusive bounds on door count
	  straight  the two doors must be on opposite edges
	  corner    the two doors must be on adjacent edges
]]

local Enums = require(script.Parent.Parent.Enums)
local K = Enums.RoomKind

local RoomRules = {}

RoomRules.Rules = {
	[K.Entrance] = { doorRule = { min = 1, max = 3 }, weight = 0, shiftProtected = true, isExtraction = true },
	[K.CorridorStraight] = { doorRule = { exact = 2, straight = true }, weight = 24 },
	[K.CorridorCurve] = { doorRule = { exact = 2, corner = true }, weight = 20 },
	[K.Junction] = { doorRule = { min = 3, max = 4 }, weight = 14 },
	[K.DeadEnd] = { doorRule = { exact = 1 }, weight = 10 },
	[K.MiningChamber] = { doorRule = { min = 1, max = 4 }, weight = 12 },
	[K.ResourceChamber] = { doorRule = { min = 1, max = 4 }, weight = 12 },
	[K.MonsterNest] = { doorRule = { min = 1, max = 3 }, weight = 8 },
	[K.PuzzleRoom] = { doorRule = { min = 1, max = 3 }, weight = 0 },
	[K.AncientVault] = { doorRule = { min = 1, max = 2 }, weight = 0, shiftProtected = true },
	[K.ExtractionChamber] = {
		doorRule = { min = 1, max = 2 },
		weight = 0,
		shiftProtected = true,
		isExtraction = true,
	},
}

--[[ Kinds the generator may choose as filler, in a fixed order. Order matters:
     a weighted pick over an unstable order would break seed reproducibility. ]]
RoomRules.FillerOrder = {
	K.CorridorStraight,
	K.CorridorCurve,
	K.Junction,
	K.DeadEnd,
	K.MiningChamber,
	K.ResourceChamber,
	K.MonsterNest,
}

--[[ Chambers the generator guarantees a minimum of, when room count allows. ]]
RoomRules.Guarantees = {
	{ kind = K.MiningChamber, min = 2 },
	{ kind = K.ResourceChamber, min = 2 },
	{ kind = K.MonsterNest, min = 1 },
}

function RoomRules.get(kind)
	return RoomRules.Rules[kind]
end

function RoomRules.isShiftProtected(kind)
	local rule = RoomRules.Rules[kind]
	return rule ~= nil and rule.shiftProtected == true
end

function RoomRules.isExtraction(kind)
	local rule = RoomRules.Rules[kind]
	return rule ~= nil and rule.isExtraction == true
end

--[[
	Does a door set satisfy a kind's rule?
	@param kind  string room kind
	@param doors { N=bool, E=bool, S=bool, W=bool }
	@return boolean
]]
function RoomRules.doorsSatisfy(kind, doors)
	local rule = RoomRules.Rules[kind]
	if not rule then
		return false
	end
	local doorRule = rule.doorRule

	local count = 0
	for _, dir in ipairs(Enums.DirectionList) do
		if doors[dir] then
			count += 1
		end
	end

	if doorRule.exact and count ~= doorRule.exact then
		return false
	end
	if doorRule.min and count < doorRule.min then
		return false
	end
	if doorRule.max and count > doorRule.max then
		return false
	end

	if doorRule.straight then
		-- Exactly the two doors, and they face each other.
		if count ~= 2 then
			return false
		end
		if not ((doors.N and doors.S) or (doors.E and doors.W)) then
			return false
		end
	end

	if doorRule.corner then
		if count ~= 2 then
			return false
		end
		if (doors.N and doors.S) or (doors.E and doors.W) then
			return false
		end
	end

	return true
end

--[[
	Best-fitting kind for a given door set, used when the generator has no
	special role for a cell. Returns nil if nothing fits, which callers treat as
	a generation bug rather than papering over it.
]]
function RoomRules.kindsFor(doors)
	local out = {}
	for _, kind in ipairs(RoomRules.FillerOrder) do
		if RoomRules.doorsSatisfy(kind, doors) then
			table.insert(out, kind)
		end
	end
	return out
end

function RoomRules.doorCount(doors)
	local count = 0
	for _, dir in ipairs(Enums.DirectionList) do
		if doors[dir] then
			count += 1
		end
	end
	return count
end

return RoomRules
