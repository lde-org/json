-- Third-party comparison: rxi/json.lua, qjson, lua-cjson, and the pure-Lua
-- predecessor of this package (extracted from git), against the same fixtures
-- the main benchmark uses.
--
-- Each library gets the same three measurements the main benchmark reports:
-- a full parse, a parse plus one nested field read, and an encode. Field access
-- after a parse is not a separate row for these libraries because none of them
-- expose a lazy handle — reading a field means the table is already built.

local ansi = require("ansi")
local json = require("json")
local cjson = require("cjson")
local rapidjson = require("rapidjson")
local fixtures = require("benchmarks.fixtures")

-- The native baselines read this too.
fixtures.write()

-- Everything below was placed in the output dir by build.lua.
local function loadFromOutput(name)
	return assert(loadfile("target/benchmarks/" .. name))()
end

-- The C yyjson baseline, when the benchmark package's build could make it.
local yyjsonC = fixtures.readBaseline("yyjson-baseline")

local rxi = loadFromOutput("rxi-json.lua")
local qjson = loadFromOutput("qjson.lua")
local oldjson = assert(loadfile("target/benchmarks/oldjson/init.lua"))()

local now = ansi.now

local function benchNs(fn, iters, reps)
	reps = reps or 5
	for _ = 1, math.max(1, math.floor(iters / 10)) do fn() end
	local samples = {}
	for _ = 1, reps do
		local t0 = now()
		for _ = 1, iters do fn() end
		samples[#samples + 1] = (now() - t0) / iters * 1e9
	end
	table.sort(samples)
	return samples[math.ceil(#samples / 2)]
end

-- ── fixtures ─────────────────────────────────────────────────────────────────

local SMALL, MEDIUM, LARGE = fixtures.SMALL, fixtures.MEDIUM, fixtures.LARGE
local SIZES = fixtures.SIZES
local SOURCES = { small = SMALL, medium = MEDIUM, large = LARGE }
local ITERS = { small = 2000, medium = 500, large = 50 }

-- ── adapters ─────────────────────────────────────────────────────────────────
-- Every entry exposes decode(src) -> something, scrape(decoded, size) -> value,
-- and encode(decoded) -> string, so one loop drives them all.

local libs = {}

libs["json (ours)"] = {
	decode = function(src) return json.decode(src) end,
	scrape = function(doc, size)
		if size == "small" then return doc:get("name"):val() end
		if size == "medium" then return doc:get("users"):get(10):get("name"):val() end
		return doc:get(250):get("tags"):get(2):val()
	end,
	encode = function(doc) return json.encode(doc) end,
}

libs["json (pure Lua, old)"] = {
	decode = function(src) return oldjson.decode(src) end,
	scrape = function(doc, size)
		if size == "small" then return doc.name end
		if size == "medium" then return doc.users[10].name end
		return doc[250].tags[2]
	end,
	encode = function(doc) return oldjson.encode(doc) end,
}

libs["rxi/json.lua"] = {
	decode = function(src) return rxi.decode(src) end,
	scrape = function(doc, size)
		if size == "small" then return doc.name end
		if size == "medium" then return doc.users[10].name end
		return doc[250].tags[2]
	end,
	encode = function(doc) return rxi.encode(doc) end,
}

libs["qjson"] = {
	decode = function(src) return qjson.decode(src) end,
	scrape = function(doc, size)
		if size == "small" then return doc.name end
		if size == "medium" then return doc.users[10].name end
		return doc[250].tags[2]
	end,
	encode = function(doc) return qjson.encode(doc) end,
}

libs["lua-rapidjson"] = {
	decode = function(src) return rapidjson.decode(src) end,
	scrape = function(doc, size)
		if size == "small" then return doc.name end
		if size == "medium" then return doc.users[10].name end
		return doc[250].tags[2]
	end,
	encode = function(doc) return rapidjson.encode(doc) end,
}

libs["lua-cjson"] = {
	decode = function(src) return cjson.decode(src) end,
	scrape = function(doc, size)
		if size == "small" then return doc.name end
		if size == "medium" then return doc.users[10].name end
		return doc[250].tags[2]
	end,
	encode = function(doc) return cjson.encode(doc) end,
}

-- ── run ──────────────────────────────────────────────────────────────────────

local ORDER = {
	"json (ours)",
	"json (pure Lua, old)",
	"rxi/json.lua",
	"qjson",
	"lua-rapidjson",
	"lua-cjson",
}

local function measure(lib, src, size, decoded)
	local decodeNs = benchNs(function() lib.decode(src) end, ITERS[size])
	local readNs = benchNs(function() lib.scrape(lib.decode(src), size) end, ITERS[size])
	local encodeNs = benchNs(function() lib.encode(decoded) end, ITERS[size])
	return decodeNs, readNs, encodeNs
end

for _, size in ipairs(SIZES) do
	local src = SOURCES[size]
	ansi.printf("\n{bold}%s{reset} {gray}(%d bytes){reset}", size, #src)
	ansi.printf("  {gray}%-22s %11s %11s %11s   %s{reset}", "", "decode", "decode+read", "encode", "ratio vs ours")

	local ours, rows = nil, {}

	-- native references first, so the Lua rows read as multiples of them
	if yyjsonC and yyjsonC[size] then
		rows[#rows + 1] = { name = "yyjson (C)", decode = yyjsonC[size].parse,
			read = yyjsonC[size].scrape, encode = yyjsonC[size].encode }
	end
	for _, name in ipairs(ORDER) do
		local lib = libs[name]
		local ok, decoded = pcall(lib.decode, src)
		if not ok then
			rows[#rows + 1] = { name = name, unsupported = true }
		else
			local decodeNs, readNs, encodeNs = measure(lib, src, size, decoded)
			if name == "json (ours)" then ours = { decodeNs, readNs, encodeNs } end
			rows[#rows + 1] = { name = name, decode = decodeNs, read = readNs, encode = encodeNs }
		end
	end

	for _, row in ipairs(rows) do
		if row.unsupported then
			ansi.printf("  {gray}%-22s %11s{reset}", row.name, "unsupported")
		else
			local factor = ansi.format("{gray}baseline{reset}")
			if ours and row.name ~= "json (ours)" then
				-- <1 means the row is faster than ours
				factor = ansi.format("{gray}%.1fx / %.1fx / %.1fx{reset}",
					row.decode / ours[1], row.read / ours[2], row.encode / ours[3])
			end
			ansi.printf("  {gray}%-22s{reset} {bold}%11.1f{reset} %11.1f %11.1f   %s",
				row.name, row.decode, row.read, row.encode, factor)
		end
	end
end

ansi.printf("\n{gray}ns/op, median of 5 runs. Our 'decode' stops at a lazy handle; every other row{reset}")
ansi.printf("{gray}has already built all of its values before you can read one. 'decode+read' is{reset}")
ansi.printf("{gray}therefore parse+read for them and parse+handle-walk for us. Ratios below 1.0{reset}")
ansi.printf("{gray}(the C row) mean that row is faster. lua-rapidjson and lua-cjson are Lua bindings{reset}")
ansi.printf("{gray}to C/C++ parsers, so every row here is reached the same way yours is.{reset}\n")
