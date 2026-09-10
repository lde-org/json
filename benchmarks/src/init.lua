local ffi = require("ffi")
local ansi = require("ansi")
local json = require("json")
local cjson = require("cjson")

-- ── timer ─────────────────────────────────────────────────────────────────────

-- os.clock() reports CPU time, which is enough to compare these single-threaded
-- paths against each other and against cjson. (clock_gettime cannot be declared
-- here: lde's own runtime already declares it with a different struct type, and
-- an ffi.cdef conflict is an error.)
local clock = os.clock
local function now() return clock() * 1e9 end

-- ── bench helper ──────────────────────────────────────────────────────────────

local function bench(label, fn, iters)
	iters = iters or 1000
	for _ = 1, math.max(1, math.floor(iters / 10)) do fn() end
	local t0 = now()
	for _ = 1, iters do fn() end
	local ns = (now() - t0) / iters
	ansi.printf("  {gray}%-40s{reset} {bold}%8.2f ns/op{reset}  {gray}(%d iters){reset}",
		label, ns, iters)
end

-- ── fixtures ──────────────────────────────────────────────────────────────────

local SMALL = '{"name":"Alice","age":30,"active":true}'

local MEDIUM = json.encode({
	users = (function()
		local t = {}
		for i = 1, 20 do
			t[i] = { id = i, name = "user" .. i, score = i * 1.5, active = i % 2 == 0 }
		end
		return t
	end)(),
})

local LARGE = json.encode((function()
	local t = {}
	for i = 1, 500 do
		t[i] = { id = i, name = "item" .. i, value = i * 3.14, tags = { "a", "b", "c" } }
	end
	return t
end)())

local JSON5_SRC = [[{
	// application config
	name: 'myapp',
	version: '1.0.0',
	/* feature flags */
	features: {
		darkMode: true,
		beta: false,
	},
	ports: [8080, 8443,],
}]]

local SMALL_T  = json.decode(SMALL):unpack()
local MEDIUM_T = json.decode(MEDIUM):unpack()
local LARGE_T  = json.decode(LARGE):unpack()

-- ── run ───────────────────────────────────────────────────────────────────────

ansi.printf("\n{bold}json.decode{reset}")
bench("small object (~40 B)", function() json.decode(SMALL) end, 20000)
bench("medium array (~20 objs)", function() json.decode(MEDIUM) end, 2000)
bench("large array (~500 objs)", function() json.decode(LARGE) end, 100)
bench("json5 with comments", function() json.decode(JSON5_SRC) end, 5000)

ansi.printf("\n{bold}json.decode + scrape one field (lazy){reset}")
bench("small: root:get('name')", function() json.decode(SMALL):get("name"):val() end, 20000)
bench("medium: users[10].name", function()
	json.decode(MEDIUM):get("users"):get(10):get("name"):val()
end, 2000)
bench("large: [250].tags[2]", function()
	json.decode(LARGE):get(250):get("tags"):get(2):val()
end, 100)

ansi.printf("\n{bold}json.decode:unpack{reset}")
bench("small object", function() json.decode(SMALL):unpack() end, 5000)
bench("medium array", function() json.decode(MEDIUM):unpack() end, 500)
bench("large array", function() json.decode(LARGE):unpack() end, 20)

ansi.printf("\n{bold}json.encode (Lua tables){reset}")
bench("small object", function() json.encode(SMALL_T) end, 5000)
bench("medium array", function() json.encode(MEDIUM_T) end, 500)
bench("large array", function() json.encode(LARGE_T) end, 20)

ansi.printf("\n{bold}json.encode (parsed handle, no Lua tables){reset}")
local smallDoc, mediumDoc, largeDoc = json.decode(SMALL), json.decode(MEDIUM), json.decode(LARGE)
bench("small object", function() json.encode(smallDoc) end, 20000)
bench("medium array", function() json.encode(mediumDoc) end, 2000)
bench("large array", function() json.encode(largeDoc) end, 100)

ansi.printf("\n{bold}json.edit{reset}")
bench("parse + set + encode (small)", function()
	local doc = json.edit.parse(SMALL)
	doc:root():set("age", 31)
	return doc:encode()
end, 5000)
bench("parse + navigate + encode (large)", function()
	local doc = json.edit.parse(LARGE)
	doc:root():get(250):set("name", "renamed")
	return doc:encode()
end, 100)

ansi.printf("\n{bold}cjson decode{reset}")
bench("small object (~40 B)", function() cjson.decode(SMALL) end, 5000)
bench("medium array (~20 objs)", function() cjson.decode(MEDIUM) end, 500)
bench("large array (~500 objs)", function() cjson.decode(LARGE) end, 20)

ansi.printf("\n{bold}cjson encode{reset}")
bench("small object", function() cjson.encode(cjson.decode(SMALL)) end, 5000)
bench("medium array", function() cjson.encode(cjson.decode(MEDIUM)) end, 500)
bench("large array", function() cjson.encode(cjson.decode(LARGE)) end, 20)
