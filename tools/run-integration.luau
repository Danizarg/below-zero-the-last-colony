--[[
	tools/run-integration.luau
	Boots the whole server in simulation and drives real gameplay flows.

		lune run tools/run-integration

	Exits non-zero on failure, so it can gate a commit or a CI job.

	How this differs from `run-tests`
	─────────────────────────────────
	`run-tests` covers PURE logic: the cave generator, inventory arithmetic, the
	RNG, config references. It never constructs a service.

	This boots all sixteen services against a simulated DataModel — a modelled
	Instance tree, a virtual clock, a real in-memory DataStore with genuine
	UpdateAsync semantics — and then plays the game: join, build, start an
	expedition, harvest, take a key, die, get rescued, extract, settle.

	That is the layer where the thirteen semantic bugs lived, and nothing was
	testing it.

	Each spec receives a `newServer` factory and builds a FRESH server per test,
	so no test can be affected by another's state.

	Honest scope: this proves service logic and orchestration, not engine
	fidelity. See the header of tools/sim.luau. The Studio checklist in
	SETUP.md §5 still covers rendering, physics, real pathfinding and real
	DataStores.
]]

local process = require("@lune/process")
local harness = require("./harness")
local sim = require("./sim")

local SHARED_DIR = "src/shared"
local TESTS_DIR = "src/tests"
local INTEGRATION_DIR = "src/tests/integration"

--[[ The TestRunner itself is a project module, so it is loaded through the
     plain harness rather than the simulator: it needs no DataModel. ]]
local sharedTree = harness.buildTree(SHARED_DIR, "BelowZero", nil)
local replicatedStorage = harness.newNode("ReplicatedStorage", "ReplicatedStorage", nil, nil)
replicatedStorage._children["BelowZero"] = sharedTree
sharedTree.Parent = replicatedStorage

local loader = harness.newLoader({ roots = { ReplicatedStorage = replicatedStorage } })
local testsTree = harness.buildTree(TESTS_DIR, "BelowZeroTests", nil)
local TestRunner = loader.require(testsTree:WaitForChild("TestRunner"))

local integrationTree = harness.buildTree(INTEGRATION_DIR, "Integration", nil)

--[[ What each spec receives. `newServer` is the important one: a fresh,
     fully-booted simulated server, isolated per test. ]]
local context = {
	newServer = function(options)
		local server = sim.new(options)
		if #server.errors > 0 then
			error(
				("[integration] the server failed to boot:\n  %s"):format(table.concat(server.errors, "\n  ")),
				2
			)
		end
		return server
	end,
	sim = sim,
	roblox = require("@lune/roblox"),
}

print("[integration] booting a simulated server per test")

local loaded = TestRunner.loadSpecs(integrationTree, context)
print(("[integration] loaded %d spec file(s)"):format(loaded))

if loaded == 0 then
	print("[integration] no specs found under " .. INTEGRATION_DIR)
	process.exit(1)
end

local summary = TestRunner.runAll({ verbose = true })

print("")
if summary.failed > 0 then
	print(("[integration] FAILED: %d of %d"):format(summary.failed, summary.passed + summary.failed))
	process.exit(1)
end

print(("[integration] OK: %d tests passed in %.2fs"):format(summary.passed, summary.duration))
process.exit(0)
