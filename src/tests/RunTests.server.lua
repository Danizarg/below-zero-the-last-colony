--[[
	RunTests.server.lua
	Runs the test suite in Studio.

	Gated to Studio and to GameConfig.Debug, so a published server never spends
	startup time on it. The sweeping cave tests take a second or two, which is
	fine for a Play Solo session and not fine for a live server.

	To run the tests without launching the game, open the Command Bar in Studio
	after a Play Solo session has started and enter:

		require(game.ServerScriptService.BelowZeroTests.TestRunner).runAll()

	(The specs are already loaded by this script, so they do not need loading
	again.)
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local GameConfig = require(Shared.Config.GameConfig)

if not RunService:IsStudio() then
	return
end

if not GameConfig.Debug then
	print("[BZ/Test] skipped: GameConfig.Debug is false")
	return
end

--[[ Deferred so the tests run after the game's own services have started. A
     failing test should be read against a running game, not a half-built one,
     and the output is easier to find at the end of the startup log. ]]
task.defer(function()
	local TestRunner = require(script.Parent.TestRunner)

	local loaded = TestRunner.loadSpecs(script.Parent)
	if loaded == 0 then
		warn("[BZ/Test] no spec files found next to RunTests")
		return
	end

	print(("[BZ/Test] running %d spec files"):format(loaded))
	local summary = TestRunner.runAll({ verbose = true })

	if summary.failed > 0 then
		--[[ Loud and unambiguous. A silent failure in a test harness is worse
		     than no harness at all. ]]
		warn(
			("[BZ/Test] ✗ %d TEST%s FAILED. The build is not in a shippable state."):format(
				summary.failed,
				summary.failed == 1 and "" or "S"
			)
		)
	else
		print("[BZ/Test] ✓ all tests passed")
	end
end)
