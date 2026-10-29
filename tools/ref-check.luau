--[[
	tools/ref-check.luau
	Finds dotted constant references that resolve to nil.

		lune run tools/ref-check

	Why this is worth having
	────────────────────────
	Luau is dynamically typed, so `Routes.Push.ObjectiveSyncc` is not an error —
	it is `nil`. The call that uses it still runs, the packet is sent under a nil
	route name, and the client simply never receives it. Nothing warns. Selene
	cannot see it, the load check cannot see it, and a test only catches it if a
	test happens to exercise that exact line.

	Across a codebase this config-heavy, that is the single most likely class of
	silent bug: a mistyped enum value, a renamed route, a theme token that was
	never defined.

	How it works: the harness loads the REAL modules, so the tables being checked
	against are the actual runtime values. Then every source file is scanned for
	`Table.Key` and `Table.Group.Key` references against the modules below, and
	each one is looked up for real.

	Bracket access (`Enums.DirectionOpposite[dir]`) is skipped — it cannot be
	resolved statically, and that is fine: it is rare and obvious in review.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local harness = require("./harness")

-- ─────────────────────────────────────────────────────────────────────────────
-- Load the real modules
-- ─────────────────────────────────────────────────────────────────────────────

local sharedTree = harness.buildTree("src/shared", "BelowZero", nil)
local replicatedStorage = harness.newNode("ReplicatedStorage", "ReplicatedStorage", nil, nil)
replicatedStorage._children["BelowZero"] = sharedTree
sharedTree.Parent = replicatedStorage

local loader = harness.newLoader({ roots = { ReplicatedStorage = replicatedStorage } })

local function load(path)
	local node = sharedTree
	for _, part in ipairs(string.split(path, ".")) do
		node = node:WaitForChild(part)
	end
	return loader.require(node)
end

--[[ The local alias each module is consistently given across the codebase,
     mapped to the real table. If a file aliases one of these differently the
     check simply will not see its references — a false negative, never a false
     positive. ]]
local TABLES = {
	Enums = load("Enums"),
	Routes = load("Routes"),
	Theme = load("Config.Theme"),
	GameConfig = load("Config.GameConfig"),
	ResourceConfig = load("Config.ResourceConfig"),
	BuildingConfig = load("Config.BuildingConfig"),
	MonsterConfig = load("Config.MonsterConfig"),
	RoomConfig = load("Config.RoomConfig"),
	RoleConfig = load("Config.RoleConfig"),
	JobConfig = load("Config.JobConfig"),
	DifficultyConfig = load("Config.DifficultyConfig"),
	ShopConfig = load("Config.ShopConfig"),
	AudioConfig = load("Config.AudioConfig"),
	RoomRules = load("Lib.RoomRules"),
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Scan
-- ─────────────────────────────────────────────────────────────────────────────

local function stripCommentsAndStrings(source)
	local out = {}
	local index = 1
	local length = #source

	while index <= length do
		local rest = string.sub(source, index)

		-- Long bracket, with or without a leading --
		local prefix, equals = string.match(rest, "^(%-?%-?)%[(=*)%[")
		if equals and (prefix == "--" or prefix == "") then
			local closing = "]" .. equals .. "]"
			local finish = string.find(source, closing, index, true)
			local stop = finish and (finish + #closing) or (length + 1)
			--[[ Preserve newlines so reported line numbers stay correct. ]]
			local chunk = string.sub(source, index, stop - 1)
			table.insert(out, (string.gsub(chunk, "[^\n]", " ")))
			index = stop
			continue
		end

		if string.sub(source, index, index + 1) == "--" then
			local finish = string.find(source, "\n", index, true) or (length + 1)
			table.insert(out, (string.gsub(string.sub(source, index, finish - 1), "[^\n]", " ")))
			index = finish
			continue
		end

		local char = string.sub(source, index, index)
		if char == '"' or char == "'" then
			local cursor = index + 1
			while cursor <= length do
				local c = string.sub(source, cursor, cursor)
				if c == "\\" then
					cursor += 2
					continue
				end
				if c == char or c == "\n" then
					break
				end
				cursor += 1
			end
			local stop = math.min(cursor + 1, length + 1)
			table.insert(out, (string.gsub(string.sub(source, index, stop - 1), "[^\n]", " ")))
			index = stop
			continue
		end

		table.insert(out, char)
		index += 1
	end

	return table.concat(out)
end

local function collectLuaFiles(dir, out)
	out = out or {}
	for _, entry in ipairs(fs.readDir(dir)) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			collectLuaFiles(full, out)
		elseif string.match(entry, "%.lua$") then
			table.insert(out, full)
		end
	end
	return out
end

local files = collectLuaFiles("src")
table.sort(files)

local checked, dangling = 0, {}

for _, file in ipairs(files) do
	local cleaned = stripCommentsAndStrings(fs.readFile(file))
	local lineNumber = 0

	for line in string.gmatch(cleaned .. "\n", "([^\n]*)\n") do
		lineNumber += 1

		for root, rest in string.gmatch(line, "([A-Z][A-Za-z]*)%.([A-Za-z][A-Za-z0-9_%.]*)") do
			local target = TABLES[root]
			if target then
				local parts = string.split(rest, ".")

				--[[ Walk as far as the reference goes, but stop at the first
				     non-table: `Theme.Color.Accent:Lerp` leaves a trailing
				     fragment that is a method, not a key. ]]
				local cursor = target
				local path = root
				local ok = true

				for depth, key in ipairs(parts) do
					if type(cursor) ~= "table" then
						-- Reached a leaf; the rest is method/field access on a value.
						break
					end
					local value = cursor[key]
					path = path .. "." .. key
					if value == nil then
						--[[ Only flag the FIRST two levels. Deeper misses are
						     usually indexing into runtime data that happens to
						     start with a capital, not a constant lookup. ]]
						if depth <= 2 then
							ok = false
						end
						break
					end
					cursor = value
					checked += 1
					if depth >= 2 then
						break
					end
				end

				if not ok then
					table.insert(dangling, {
						file = file,
						line = lineNumber,
						reference = path,
						text = line,
					})
				end
			end
		end
	end
end

print(("[ref-check] scanned %d files, resolved %d constant references"):format(#files, checked))

if #dangling == 0 then
	print("[ref-check] OK: every dotted constant reference resolves")
	process.exit(0)
end

print(("[ref-check] %d reference(s) resolve to nil:"):format(#dangling))
print("")
for _, entry in ipairs(dangling) do
	print(("  %s:%d  %s"):format(entry.file, entry.line, entry.reference))
	local trimmed = string.match(entry.text, "^%s*(.-)%s*$")
	print(("      %s"):format(trimmed))
end
process.exit(1)
