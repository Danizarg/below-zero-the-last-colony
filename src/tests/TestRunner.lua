--[[
	TestRunner.lua
	A small, self-contained test harness.

	Deliberately has no dependencies. Bringing in TestEZ would mean the project
	cannot run its own tests from a bare Rojo sync, and the whole point of these
	tests is that someone can clone the repo, press Play in Studio and see
	whether the cave generator still holds its invariants.

	Usage:

		local suite = TestRunner.suite("CaveLayout")
		suite:test("does the thing", function(expect)
			expect.equal(2 + 2, 4)
		end)
		TestRunner.runAll()

	A spec file returns a function that receives the suite.
]]

local TestRunner = {}

local suites = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Assertions
-- ─────────────────────────────────────────────────────────────────────────────

local expect = {}

local function fail(message)
	--[[ level 3 so the reported line is the caller's, not this file's. ]]
	error(message, 3)
end

function expect.truthy(value, message)
	if not value then
		fail(message or ("expected a truthy value, got %s"):format(tostring(value)))
	end
end

function expect.falsy(value, message)
	if value then
		fail(message or ("expected a falsy value, got %s"):format(tostring(value)))
	end
end

function expect.equal(actual, expected, message)
	if actual ~= expected then
		fail(message or ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
	end
end

function expect.notEqual(actual, unexpected, message)
	if actual == unexpected then
		fail(message or ("expected something other than %s"):format(tostring(unexpected)))
	end
end

function expect.near(actual, expected, tolerance, message)
	tolerance = tolerance or 1e-6
	if math.abs(actual - expected) > tolerance then
		fail(
			message
				or ("expected %s within %s of %s"):format(
					tostring(actual),
					tostring(tolerance),
					tostring(expected)
				)
		)
	end
end

function expect.atLeast(actual, minimum, message)
	if actual < minimum then
		fail(message or ("expected at least %s, got %s"):format(tostring(minimum), tostring(actual)))
	end
end

function expect.atMost(actual, maximum, message)
	if actual > maximum then
		fail(message or ("expected at most %s, got %s"):format(tostring(maximum), tostring(actual)))
	end
end

function expect.lessThan(actual, bound, message)
	if not (actual < bound) then
		fail(message or ("expected %s to be less than %s"):format(tostring(actual), tostring(bound)))
	end
end

function expect.greaterThan(actual, bound, message)
	if not (actual > bound) then
		fail(message or ("expected %s to be greater than %s"):format(tostring(actual), tostring(bound)))
	end
end

function expect.inRange(actual, minimum, maximum, message)
	if actual < minimum or actual > maximum then
		fail(
			message
				or ("expected %s to be between %s and %s"):format(
					tostring(actual),
					tostring(minimum),
					tostring(maximum)
				)
		)
	end
end

function expect.contains(array, value, message)
	for _, entry in ipairs(array) do
		if entry == value then
			return
		end
	end
	fail(message or ("expected the list to contain %s"):format(tostring(value)))
end

function expect.isType(value, expectedType, message)
	if typeof(value) ~= expectedType then
		fail(message or ("expected a %s, got %s"):format(expectedType, typeof(value)))
	end
end

--[[ Explicit failure, for "this branch should be unreachable" cases. ]]
function expect.fail(message)
	fail(message or "explicit failure")
end

TestRunner.expect = expect

-- ─────────────────────────────────────────────────────────────────────────────
-- Suites
-- ─────────────────────────────────────────────────────────────────────────────

local Suite = {}
Suite.__index = Suite

function Suite:test(label, fn)
	table.insert(self.tests, { label = label, fn = fn })
end

--[[ Mark a test as a known gap rather than deleting it, so the gap stays
     visible in the output instead of being forgotten. ]]
function Suite:skip(label, reason)
	table.insert(self.tests, { label = label, skipped = reason or "skipped" })
end

function TestRunner.suite(name)
	local suite = setmetatable({ name = name, tests = {} }, Suite)
	table.insert(suites, suite)
	return suite
end

function TestRunner.reset()
	suites = {}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Running
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	@return summary { passed, failed, skipped, failures = { {suite, test, error} } }
]]
function TestRunner.runAll(options)
	options = options or {}
	local verbose = options.verbose ~= false

	local summary = { passed = 0, failed = 0, skipped = 0, failures = {}, duration = 0 }
	local startedAt = os.clock()

	for _, suite in ipairs(suites) do
		local suitePassed, suiteFailed, suiteSkipped = 0, 0, 0

		for _, entry in ipairs(suite.tests) do
			if entry.skipped then
				suiteSkipped += 1
				summary.skipped += 1
			else
				local ok, err = pcall(entry.fn, expect)
				if ok then
					suitePassed += 1
					summary.passed += 1
				else
					suiteFailed += 1
					summary.failed += 1
					table.insert(summary.failures, {
						suite = suite.name,
						test = entry.label,
						error = tostring(err),
					})
				end
			end
		end

		if verbose then
			local status = suiteFailed == 0 and "PASS" or "FAIL"
			print(
				("[BZ/Test] %s  %-22s %d passed, %d failed, %d skipped"):format(
					status,
					suite.name,
					suitePassed,
					suiteFailed,
					suiteSkipped
				)
			)
		end
	end

	summary.duration = os.clock() - startedAt

	if verbose then
		for _, failure in ipairs(summary.failures) do
			warn(
				("[BZ/Test] FAILED %s › %s\n           %s"):format(
					failure.suite,
					failure.test,
					failure.error
				)
			)
		end

		print(
			("[BZ/Test] ───── %d passed, %d failed, %d skipped in %.2fs ─────"):format(
				summary.passed,
				summary.failed,
				summary.skipped,
				summary.duration
			)
		)
	end

	return summary
end

--[[ Load every ModuleScript whose name ends in `.spec` under `container` and
     hand each one a suite named after it. ]]
function TestRunner.loadSpecs(container)
	local loaded = 0
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("ModuleScript") and string.match(child.Name, "%.spec$") then
			local name = string.gsub(child.Name, "%.spec$", "")
			local ok, factory = pcall(require, child)
			if not ok then
				warn(("[BZ/Test] could not load %s: %s"):format(child.Name, tostring(factory)))
			elseif type(factory) ~= "function" then
				warn(("[BZ/Test] %s should return a function(suite)"):format(child.Name))
			else
				local suite = TestRunner.suite(name)
				local built, err = pcall(factory, suite)
				if not built then
					warn(("[BZ/Test] %s failed while defining tests: %s"):format(child.Name, tostring(err)))
				else
					loaded += 1
				end
			end
		end
	end
	return loaded
end

return TestRunner
