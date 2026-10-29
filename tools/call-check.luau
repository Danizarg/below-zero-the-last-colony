--[[
	tools/call-check.luau
	Verifies every cross-service call names a real method, with a plausible
	argument count.

		lune run tools/call-check

	Why this is worth having
	────────────────────────
	Services reach each other through a context registry:

		self.context.InventoryService:addToBag(player, resourceId, amount)

	Nothing checks that. `self.context.InventoryService:addToBagg(...)` is a
	runtime "attempt to call a nil value" that only fires when that exact line
	runs — which, for a path like "a monster died and dropped loot", might be
	minutes into an expedition. Selene cannot see it (the table is dynamic), the
	load check cannot see it (it is inside a function), and it parses fine.

	This loads every service for real and resolves each call site against it.

	Two levels of finding:
	  ERROR   the method does not exist. Always a bug.
	  WARN    the call passes more arguments than the method declares and the
	          method is not variadic. Usually a bug, occasionally a deliberate
	          extra argument, so it does not fail the run on its own.

	Passing FEWER arguments is not reported: optional trailing parameters are
	idiomatic here (`save(player, options)`, `resetFor(player, full)`).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local harness = require("./harness")

-- ─────────────────────────────────────────────────────────────────────────────
-- Load every service against the stub tree
-- ─────────────────────────────────────────────────────────────────────────────

local sharedTree = harness.buildTree("src/shared", "BelowZero", nil)
local serverTree = harness.buildTree("src/server", "BelowZeroServer", nil)

local replicatedStorage = harness.newNode("ReplicatedStorage", "ReplicatedStorage", nil, nil)
replicatedStorage._children["BelowZero"] = sharedTree
sharedTree.Parent = replicatedStorage

local loader = harness.newLoader({ roots = { ReplicatedStorage = replicatedStorage } })

local services = {}
local servicesFolder = serverTree:WaitForChild("Services")

for _, node in ipairs(servicesFolder:GetChildren()) do
	if node:IsA("ModuleScript") then
		local ok, service = pcall(function()
			return loader.require(node)
		end)
		if ok and type(service) == "table" then
			services[node.Name] = service
		else
			print(("[call-check] could not load %s: %s"):format(node.Name, tostring(service)))
		end
	end
end

local count = 0
for _ in pairs(services) do
	count += 1
end
print(("[call-check] loaded %d services"):format(count))

-- ─────────────────────────────────────────────────────────────────────────────
-- Scan call sites
-- ─────────────────────────────────────────────────────────────────────────────

local function stripCommentsAndStrings(source)
	local out = {}
	local index = 1
	local length = #source

	while index <= length do
		local rest = string.sub(source, index)

		local prefix, equals = string.match(rest, "^(%-?%-?)%[(=*)%[")
		if equals and (prefix == "--" or prefix == "") then
			local closing = "]" .. equals .. "]"
			local finish = string.find(source, closing, index, true)
			local stop = finish and (finish + #closing) or (length + 1)
			table.insert(out, (string.gsub(string.sub(source, index, stop - 1), "[^\n]", " ")))
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
			--[[ Replace the string body with a placeholder so it still counts as
			     exactly one argument when args are counted below. ]]
			table.insert(out, (string.gsub(string.sub(source, index, stop - 1), "[^\n]", "s")))
			index = stop
			continue
		end

		table.insert(out, char)
		index += 1
	end

	return table.concat(out)
end

--[[ Count top-level arguments in a call, starting just after the open paren.
     Depth-aware across (), {} and [], so nested calls and inline tables count
     as one argument each. Returns nil if the parens never close (a call split
     across lines in a way this cannot follow), which is treated as unknown
     rather than guessed at. ]]
local function countArguments(text, openIndex)
	local depth = 0
	local args = 0
	local sawContent = false

	for index = openIndex, #text do
		local char = string.sub(text, index, index)

		if char == "(" or char == "{" or char == "[" then
			depth += 1
			if depth == 1 then
				sawContent = false
			end
		elseif char == ")" or char == "}" or char == "]" then
			depth -= 1
			if depth == 0 then
				return (sawContent or args > 0) and (args + 1) or 0
			end
		elseif char == "," and depth == 1 then
			args += 1
		elseif depth == 1 and not string.match(char, "%s") then
			sawContent = true
		end
	end

	return nil
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

local files = collectLuaFiles("src/server")
table.sort(files)

local resolved, errors, warnings = 0, {}, {}

for _, file in ipairs(files) do
	local cleaned = stripCommentsAndStrings(fs.readFile(file))
	local lineNumber = 0

	for line in string.gmatch(cleaned .. "\n", "([^\n]*)\n") do
		lineNumber += 1

		local searchFrom = 1
		while true do
			local startIndex, openIndex, serviceName, methodName =
				string.find(line, "self%.context%.([A-Za-z]+):([A-Za-z_][A-Za-z0-9_]*)%(", searchFrom)
			if not startIndex then
				break
			end
			searchFrom = openIndex + 1

			local service = services[serviceName]
			if service == nil then
				table.insert(errors, {
					file = file,
					line = lineNumber,
					message = ("self.context.%s is not a loadable service"):format(serviceName),
				})
			else
				local method = service[methodName]
				if type(method) ~= "function" then
					table.insert(errors, {
						file = file,
						line = lineNumber,
						message = ("%s:%s does not exist (got %s)"):format(
							serviceName,
							methodName,
							type(method)
						),
					})
				else
					resolved += 1

					--[[ debug.info("a") gives the declared parameter count and
					     whether the function is variadic, which is exactly what
					     is needed to catch an over-long call. ]]
					local okInfo, numParams, isVararg = pcall(debug.info, method, "a")
					if okInfo and numParams and not isVararg then
						local openParen = string.find(line, "(", openIndex - 1, true)
						local passed = openParen and countArguments(line, openParen)
						if passed then
							-- +1 for the implicit self in a colon call.
							local total = passed + 1
							if total > numParams then
								table.insert(warnings, {
									file = file,
									line = lineNumber,
									message = ("%s:%s takes %d parameter(s) including self, called with %d"):format(
										serviceName,
										methodName,
										numParams,
										total
									),
								})
							end
						end
					end
				end
			end
		end
	end
end

print(("[call-check] resolved %d cross-service calls"):format(resolved))

if #warnings > 0 then
	print("")
	print(("[call-check] %d argument-count warning(s):"):format(#warnings))
	for _, entry in ipairs(warnings) do
		print(("  %s:%d  %s"):format(entry.file, entry.line, entry.message))
	end
end

if #errors > 0 then
	print("")
	print(("[call-check] %d ERROR(s):"):format(#errors))
	for _, entry in ipairs(errors) do
		print(("  %s:%d  %s"):format(entry.file, entry.line, entry.message))
	end
	process.exit(1)
end

print("[call-check] OK: every cross-service call names a real method")
process.exit(0)
