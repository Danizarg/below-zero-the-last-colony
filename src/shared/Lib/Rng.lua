--[[
	Rng.lua
	Deterministic pseudo-random generator, xorshift32.

	Why not Random.new? Two reasons:
	  1. Modules under src/shared/Lib must stay free of Roblox datatypes so the
	     generation logic can be reasoned about and unit tested without a
	     DataModel.
	  2. xorshift32 over bit32 is exact integer arithmetic, so the same seed
	     produces the same cave on every machine and every engine version.

	Not cryptographic. Do not use for anything security relevant.
]]

local Rng = {}
Rng.__index = Rng

local TWO_POW_32 = 4294967296

--[[
	@param seed number|nil  any integer; nil/0 falls back to a fixed seed so a
	                        missing seed is reproducible rather than silent noise
]]
function Rng.new(seed)
	local s = math.floor(tonumber(seed) or 0) % TWO_POW_32
	if s == 0 then
		s = 2463534242 -- xorshift32 cannot be seeded with zero
	end
	return setmetatable({ _state = s, _count = 0 }, Rng)
end

--[[ Raw 32-bit step. ]]
function Rng:nextUInt32()
	local s = self._state
	s = bit32.bxor(s, bit32.lshift(s, 13))
	s = bit32.bxor(s, bit32.rshift(s, 17))
	s = bit32.bxor(s, bit32.lshift(s, 5))
	self._state = s
	self._count += 1
	return s
end

--[[ Uniform float in [0, 1). ]]
function Rng:nextNumber()
	return self:nextUInt32() / TWO_POW_32
end

--[[ Uniform float in [min, max). ]]
function Rng:nextRange(min, max)
	return min + (max - min) * self:nextNumber()
end

--[[ Uniform integer in [min, max] inclusive. ]]
function Rng:nextInteger(min, max)
	min = math.floor(min)
	max = math.floor(max)
	if max <= min then
		return min
	end
	return min + (self:nextUInt32() % (max - min + 1))
end

--[[ True with probability p. ]]
function Rng:chance(p)
	return self:nextNumber() < p
end

--[[ Uniform pick from an array. Returns nil for an empty array. ]]
function Rng:pick(array)
	local n = #array
	if n == 0 then
		return nil
	end
	return array[self:nextInteger(1, n)]
end

--[[ Uniform pick returning both value and index. ]]
function Rng:pickIndex(array)
	local n = #array
	if n == 0 then
		return nil, nil
	end
	local index = self:nextInteger(1, n)
	return array[index], index
end

--[[
	Weighted pick.
	@param entries array of tables
	@param weightOf function(entry) -> number, or nil to read entry.weight
	@return entry, index
]]
function Rng:pickWeighted(entries, weightOf)
	local total = 0
	for _, entry in ipairs(entries) do
		local w = weightOf and weightOf(entry) or entry.weight or 0
		if w > 0 then
			total += w
		end
	end
	if total <= 0 then
		return nil, nil
	end

	local roll = self:nextNumber() * total
	local accumulated = 0
	for index, entry in ipairs(entries) do
		local w = weightOf and weightOf(entry) or entry.weight or 0
		if w > 0 then
			accumulated += w
			if roll < accumulated then
				return entry, index
			end
		end
	end

	-- Floating point slop: fall back to the last positive-weight entry.
	for index = #entries, 1, -1 do
		local w = weightOf and weightOf(entries[index]) or entries[index].weight or 0
		if w > 0 then
			return entries[index], index
		end
	end
	return nil, nil
end

--[[ Fisher-Yates, in place. Returns the same array for chaining. ]]
function Rng:shuffle(array)
	for i = #array, 2, -1 do
		local j = self:nextInteger(1, i)
		array[i], array[j] = array[j], array[i]
	end
	return array
end

--[[ A copy of `array` in random order. ]]
function Rng:shuffled(array)
	local copy = table.create(#array)
	for index, value in ipairs(array) do
		copy[index] = value
	end
	return self:shuffle(copy)
end

--[[ A derived generator, so a sub-system can draw numbers without disturbing
     the parent stream's sequence. ]]
function Rng:fork(salt)
	local mixed = bit32.bxor(self:nextUInt32(), bit32.band(math.floor(tonumber(salt) or 0), 0xFFFFFFFF))
	return Rng.new(mixed)
end

--[[ How many numbers have been drawn. Useful in tests to prove determinism. ]]
function Rng:drawCount()
	return self._count
end

return Rng
