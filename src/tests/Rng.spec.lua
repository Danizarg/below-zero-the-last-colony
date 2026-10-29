--[[
	Rng.spec.lua

	The generator is what makes a seed mean something. If it drifts, every
	"reproduce this seed" bug report becomes useless.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Rng = require(Shared.Lib.Rng)

return function(suite)
	suite:test("the same seed produces the same sequence", function(expect)
		local a = Rng.new(12345)
		local b = Rng.new(12345)
		for index = 1, 500 do
			expect.equal(a:nextUInt32(), b:nextUInt32(), ("diverged at draw %d"):format(index))
		end
	end)

	suite:test("different seeds diverge quickly", function(expect)
		local a = Rng.new(1)
		local b = Rng.new(2)
		local same = 0
		for _ = 1, 100 do
			if a:nextUInt32() == b:nextUInt32() then
				same += 1
			end
		end
		expect.atMost(same, 2, "two seeds produced suspiciously similar streams")
	end)

	suite:test("a zero or nil seed is reproducible rather than random", function(expect)
		--[[ xorshift cannot be seeded with zero. Falling back to a fixed seed
		     keeps a missing seed reproducible instead of silently non-deterministic. ]]
		local a = Rng.new(0)
		local b = Rng.new(nil)
		expect.equal(a:nextUInt32(), b:nextUInt32())
	end)

	suite:test("nextNumber stays in [0, 1)", function(expect)
		--[[ Half-open on purpose: `chance(1)` must always fire and `chance(0)`
		     must never, which only holds if 1 is excluded and 0 is included. ]]
		local rng = Rng.new(777)
		local sawLow = false
		for _ = 1, 5000 do
			local value = rng:nextNumber()
			expect.atLeast(value, 0)
			expect.lessThan(value, 1)
			if value < 0.01 then
				sawLow = true
			end
		end
		expect.truthy(sawLow, "never produced a value near zero; the range looks shifted")
	end)

	suite:test("nextInteger stays within its bounds, inclusive", function(expect)
		local rng = Rng.new(999)
		local sawMin, sawMax = false, false
		for _ = 1, 4000 do
			local value = rng:nextInteger(3, 7)
			expect.inRange(value, 3, 7)
			if value == 3 then
				sawMin = true
			end
			if value == 7 then
				sawMax = true
			end
		end
		expect.truthy(sawMin, "never produced the lower bound")
		expect.truthy(sawMax, "never produced the upper bound; the range is exclusive somewhere")
	end)

	suite:test("nextInteger with an inverted or equal range returns the minimum", function(expect)
		local rng = Rng.new(5)
		expect.equal(rng:nextInteger(4, 4), 4)
		expect.equal(rng:nextInteger(9, 2), 9)
	end)

	suite:test("shuffle preserves the exact contents", function(expect)
		local rng = Rng.new(31337)
		local source = {}
		for index = 1, 60 do
			source[index] = index
		end

		local shuffled = rng:shuffled(source)
		expect.equal(#shuffled, 60)

		local seen = {}
		for _, value in ipairs(shuffled) do
			expect.falsy(seen[value], ("value %d appeared twice"):format(value))
			seen[value] = true
		end
		for index = 1, 60 do
			expect.truthy(seen[index], ("value %d went missing"):format(index))
		end

		-- And the original is untouched.
		expect.equal(source[1], 1)
	end)

	suite:test("shuffle actually reorders", function(expect)
		local rng = Rng.new(8)
		local source = {}
		for index = 1, 40 do
			source[index] = index
		end
		local shuffled = rng:shuffled(source)

		local moved = 0
		for index = 1, 40 do
			if shuffled[index] ~= index then
				moved += 1
			end
		end
		expect.atLeast(moved, 25, "the shuffle barely moved anything")
	end)

	suite:test("pickWeighted never returns a zero-weight entry", function(expect)
		local rng = Rng.new(4242)
		local entries = {
			{ id = "never", weight = 0 },
			{ id = "sometimes", weight = 1 },
			{ id = "often", weight = 9 },
		}

		local counts = { never = 0, sometimes = 0, often = 0 }
		for _ = 1, 4000 do
			local picked = rng:pickWeighted(entries)
			counts[picked.id] += 1
		end

		expect.equal(counts.never, 0, "a zero weight must never be chosen")
		expect.atLeast(counts.sometimes, 1)
		--[[ Roughly 9:1. Wide bounds, because this is a sanity check on the
		     weighting, not a statistics exam. ]]
		expect.atLeast(counts.often, counts.sometimes * 4)
	end)

	suite:test("pickWeighted returns nil when everything weighs nothing", function(expect)
		local rng = Rng.new(11)
		local picked = rng:pickWeighted({ { id = "a", weight = 0 }, { id = "b", weight = 0 } })
		expect.equal(picked, nil)
	end)

	suite:test("pickWeighted accepts an external weight function", function(expect)
		local rng = Rng.new(13)
		local entries = { "alpha", "beta" }
		local picked = rng:pickWeighted(entries, function(entry)
			return entry == "beta" and 1 or 0
		end)
		expect.equal(picked, "beta")
	end)

	suite:test("pick handles an empty array", function(expect)
		local rng = Rng.new(17)
		expect.equal(rng:pick({}), nil)
	end)

	suite:test("fork produces an independent stream", function(expect)
		local parent = Rng.new(2024)
		local child = parent:fork(1)
		local other = parent:fork(1)

		--[[ Two forks taken at different points in the parent's stream must
		     differ, or a sub-system would reuse another's numbers. ]]
		expect.notEqual(child:nextUInt32(), other:nextUInt32())
	end)

	suite:test("drawCount tracks how much of the stream was consumed", function(expect)
		local rng = Rng.new(5)
		expect.equal(rng:drawCount(), 0)
		rng:nextNumber()
		rng:nextInteger(1, 10)
		expect.equal(rng:drawCount(), 2)
	end)

	suite:test("chance(0) never fires and chance(1) always does", function(expect)
		local rng = Rng.new(61)
		for _ = 1, 500 do
			expect.falsy(rng:chance(0))
			expect.truthy(rng:chance(1))
		end
	end)
end
