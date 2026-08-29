--!strict
-- Puppet suite, headless. `lune run scripts/headless` from the package root.
--
-- ⚠ The specs require `../src` with require-by-string, the same syntax the Roblox engine now
-- resolves -- so these run the file the game runs, with no shim and no second copy.

local process = require("@lune/process")

local SPECS: { [string]: any } = {
	DeclareSpec = require("../test/DeclareSpec"),
	
	AcceptanceSpec = require("../test/AcceptanceSpec"),
}

local failures: { string } = {}
local cases = 0
local current = "?"

local t = {}

function t.ok(condition: any, message: string)
	cases += 1
	if not condition then
		table.insert(failures, ("%s: %s"):format(current, message))
	end
end

function t.eq(got: any, want: any, message: string)
	cases += 1
	if got ~= want then
		table.insert(failures, ("%s: %s (got %s, want %s)"):format(current, message, tostring(got), tostring(want)))
	end
end

--- ⚠ Asserts the error MATCHES, not merely that one happened -- a refusal for the wrong reason is
--- a passing test that proves nothing.
function t.err(fn: () -> (), pattern: string, message: string)
	cases += 1
	local ok, err = pcall(fn)
	if ok then
		table.insert(failures, ("%s: %s (expected an error, none thrown)"):format(current, message))
	elseif not tostring(err):find(pattern, 1, true) then
		table.insert(failures, ("%s: %s (error did not mention '%s': %s)"):format(current, message, pattern, tostring(err)))
	end
end

local names: { string } = {}
for name in SPECS do
	table.insert(names, name)
end
table.sort(names)

for _, name in names do
	current = name
	local ok, err = pcall(SPECS[name], t)
	if not ok then
		table.insert(failures, ("%s: threw -- %s"):format(name, tostring(err)))
	end
end

if #failures == 0 then
	print(("puppet: %d cases, all green (%d specs)"):format(cases, #names))
else
	print(("puppet: %d cases, %d RED"):format(cases, #failures))
	for _, line in failures do
		print("  " .. line)
	end
	process.exit(1)
end
