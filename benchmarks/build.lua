-- Builds the comparison bench dependencies:
--   * a pure-C yyjson baseline, compiled against the same yyjson revision the
--     Lua module loads from src/libyyjson.so
--   * rxi/json.lua and qjson, fetched rather than vendored
--   * the pure-Lua predecessor of this package, out of this repo's own history
--
-- Every compiler step is best effort: a missing toolchain or a failed fetch
-- leaves that baseline out of the run rather than failing the installation.

local build = require("lde-build")

local out = build.outDir
local jsonDir = out .. "/../json"

local function include(path)
	return "-I" .. path
end

-- build:cc returns (stdout, stderr) and either can come back nil. Warnings are
-- normal here, so look for a real diagnostic and for the artifact, rather than
-- for the word "error" anywhere in the output.
local function compile(args, artifact)
	local _, stderr = build:cc(args)
	if stderr and stderr:find(": error", 1, true) then return false end
	return artifact == nil or build:exists(artifact)
end

-- build:delete errors on a missing path, so only remove what is there.
local function remove(name)
	if build:exists(name) then build:delete(name) end
end

-- Third-party files, fetched rather than vendored.
local downloads = {
	["rxi-json.lua"] = "https://raw.githubusercontent.com/rxi/json.lua/master/json.lua"
}

for name, url in pairs(downloads) do
	if not build:exists(name) then
		pcall(function() build:write(name, build:fetch(url)) end)
	end
end

-- The pure-Lua predecessor of this package, out of this repo's local git history
-- (commit 3d170b5, the last pure-Lua release).
if not build:exists("oldjson/init.lua") then
	build:sh("mkdir -p " .. out .. "/oldjson")
	local ok = pcall(function()
		build:sh("git -C " .. out .. "/../.. show 3d170b5:src/init.lua > " .. out .. "/oldjson/init.lua")
	end)
	if not ok then remove("oldjson/init.lua"); remove("oldjson") end
end

-- yyjson: the same sources the Lua module compiles into libyyjson.so.
if build:exists("../json/yyjson") then
	build:write("yyjson-baseline.c", build:read("yyjson-baseline.c"))
	compile({
		"-O2",
		include(jsonDir .. "/yyjson/src"),
		out .. "/yyjson-baseline.c",
		jsonDir .. "/yyjson/src/yyjson.c",
		"-o", "yyjson-baseline",
		"-lm",
	})
else
	remove("yyjson-baseline")
end
