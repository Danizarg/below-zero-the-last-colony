--[[
	tools/run-tests.luau
	Runs the spec suite headlessly under Lune, with no Roblox Studio.

		lune run tools/run-tests

	Exits non-zero on any failure, so it can gate a commit or a CI job.

	What it covers: the pure logic in src/shared — the cave generator, the maze
	shift, inventory arithmetic, the RNG, plot geometry, and every cross-config
	reference. That is both the riskiest code in the project and the code a
	human is worst at checking by playing.

	What it does NOT cover: anything that touches the engine — the server
	services, the client UI, world building, monster AI. Those need Studio, and
	SETUP.md §5 has the manual checklist. `lune run tools/load-check` at least
	proves those modules load.
]]

local process = require("@lune/process")
local harness = require("./harness")

local SHARED_DIR = "src/shared"
local TESTS_DIR = "src/tests"

print("[harness] building a fake instance tree over " .. SHARED_DIR .. " and " .. TESTS_DIR)

local sharedTree = harness.buildTree(SHARED_DIR, "BelowZero", nil)
local testsTree = harness.buildTree(TESTS_DIR, "BelowZeroTests", nil)

--[[ The specs reach the game's modules the same way the real code does, via
     ReplicatedStorage.BelowZero, so the tree has to be reachable under a
     service of that name. ]]
local replicatedStorage = harness.newNode("ReplicatedStorage", "ReplicatedStorage", nil, nil)
replicatedStorage._children["BelowZero"] = sharedTree
sharedTree.Parent = replicatedStorage

local loader = harness.newLoader({ roots = { ReplicatedStorage = replicatedStorage } })

print(
	("[harness] %d source files in the tree"):format(
		harness.countModules(sharedTree) + harness.countModules(testsTree)
	)
)

local TestRunner = loader.require(testsTree:WaitForChild("TestRunner"))

local loaded = TestRunner.loadSpecs(testsTree)
print(("[harness] loaded %d spec files"):format(loaded))

if loaded == 0 then
	print("[harness] no specs found — nothing to run")
	process.exit(1)
end

local summary = TestRunner.runAll({ verbose = true })

print("")
if summary.failed > 0 then
	print(("[harness] FAILED: %d of %d tests"):format(summary.failed, summary.passed + summary.failed))
	process.exit(1)
end

print(("[harness] OK: %d tests passed in %.2fs"):format(summary.passed, summary.duration))
process.exit(0)
