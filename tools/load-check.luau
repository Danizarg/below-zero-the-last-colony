--[[
	tools/load-check.luau
	Requires every ModuleScript in the project and reports which ones load.

		lune run tools/load-check

	Why this is worth having
	────────────────────────
	Selene proves the code PARSES. It does not prove a module can be loaded: a
	typo in a require path, a nil index while building a config table, a
	service captured at require time that does not exist — all of those parse
	perfectly and then fail the moment Studio touches them. Since the server
	bootstrap requires everything at startup, a single one of these takes the
	whole game down.

	This walks src/shared, src/server and src/client and requires each module
	against the stub tree, reporting pass or fail per module.

	What a failure here means: a real bug. What a PASS here means: the module's
	top-level code runs. It says nothing about whether its functions work —
	that is what the spec suite and the Studio checklist are for.

	Modules that legitimately cannot load headlessly are listed in EXPECTED
	below with the reason, so the output distinguishes "known engine
	dependency" from "broken".
]]

local process = require("@lune/process")
local harness = require("./harness")

local ROOTS = {
	{ dir = "src/shared", name = "BelowZero" },
	{ dir = "src/server", name = "BelowZeroServer" },
	{ dir = "src/client", name = "BelowZeroClient" },
}

--[[ Modules whose top-level code genuinely needs the engine. Each entry is a
     reason, not an excuse — if a module appears here without one of these
     being true, it is a bug being hidden. ]]
local EXPECTED_FAILURES = {
	-- (none yet; entries look like ["BelowZeroClient.Foo"] = "reason")
}

local sharedTree = harness.buildTree("src/shared", "BelowZero", nil)

local replicatedStorage = harness.newNode("ReplicatedStorage", "ReplicatedStorage", nil, nil)
replicatedStorage._children["BelowZero"] = sharedTree
sharedTree.Parent = replicatedStorage

--[[ One loader shared across all three trees, so a module required twice is
     cached exactly as it would be at runtime. ]]
local loader = harness.newLoader({ roots = { ReplicatedStorage = replicatedStorage } })

local trees = { BelowZero = sharedTree }
for _, root in ipairs(ROOTS) do
	if root.name ~= "BelowZero" then
		trees[root.name] = harness.buildTree(root.dir, root.name, nil)
	end
end

local passed, failed, expected = 0, 0, 0
local failures = {}

--[[ Deterministic order: shared first, because the other two depend on it and a
     shared failure would otherwise show up as a cascade of confusing errors. ]]
local ORDER = { "BelowZero", "BelowZeroServer", "BelowZeroClient" }

for _, treeName in ipairs(ORDER) do
	local tree = trees[treeName]
	if not tree then
		continue
	end

	local modules = harness.collectModules(tree)
	print(("\n=== %s (%d modules) ==="):format(treeName, #modules))

	for _, node in ipairs(modules) do
		local fullName = node:GetFullName()
		local ok, err = pcall(function()
			return loader.require(node)
		end)

		if ok then
			passed += 1
			print(("  ok    %s"):format(fullName))
		elseif EXPECTED_FAILURES[fullName] then
			expected += 1
			print(("  skip  %s  (%s)"):format(fullName, EXPECTED_FAILURES[fullName]))
		else
			failed += 1
			local message = tostring(err)
			print(("  FAIL  %s"):format(fullName))
			table.insert(failures, { name = fullName, error = message })
		end
	end
end

print("")
print(("───── %d loaded, %d failed, %d expected-engine ─────"):format(passed, failed, expected))

if failed > 0 then
	print("")
	for _, failure in ipairs(failures) do
		print(("FAILED %s"):format(failure.name))
		for _, line in ipairs(string.split(failure.error, "\n")) do
			if line ~= "" then
				print("    " .. line)
			end
		end
		print("")
	end
	process.exit(1)
end

process.exit(0)
