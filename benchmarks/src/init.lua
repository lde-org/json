local ansi = require("ansi")
local json = require("json")
local fixtures = require("benchmarks.fixtures")

local now = ansi.now

-- ── helpers ───────────────────────────────────────────────────────────────────

local function bench(label, fn, iters)
	iters = iters or 1000
	for _ = 1, math.max(1, math.floor(iters / 10)) do fn() end
	local t0 = now()
	for _ = 1, iters do fn() end
	ansi.printf("  {gray}%-30s{reset} {bold}%10.1f ns/op{reset}  {gray}(%d iters){reset}",
		label, (now() - t0) / iters * 1e9, iters)
end

-- Median of `reps` runs, so a GC pause or a scheduler hiccup cannot define a row.
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

local function vsC(luaNs, cNs)
	if not cNs or cNs == 0 then return "" end
	return ansi.format("  {gray}x%.2f vs C{reset}", luaNs / cNs)
end

-- ── run ───────────────────────────────────────────────────────────────────────

fixtures.write()
local baseline = fixtures.readBaseline()

local small, medium, large = fixtures.SMALL, fixtures.MEDIUM, fixtures.LARGE
local decoded = {
	small = json.decode(small),
	medium = json.decode(medium),
	large = json.decode(large),
}

ansi.printf("\n{bold}yyjson through the ffi wrapper{reset}")

ansi.printf("\n{gray}decode: parse the document, build no Lua data{reset}")
for _, size in ipairs(fixtures.SIZES) do
	local src = fixtures.source(size)
	local ns = benchNs(function() json.decode(src) end, fixtures.ITERS[size])
	ansi.printf("  {gray}%-30s{reset} {bold}%10.1f ns/op{reset}%s", size, ns,
		baseline and vsC(ns, baseline[size] and baseline[size].parse) or "")
end
bench("json5 with comments", function() json.decode(fixtures.JSON5_SRC) end, 5000)

ansi.printf("\n{gray}decode + read one nested field{reset}")
local reads = {
	{ "small.name", "small", function() return json.decode(small):get("name"):val() end },
	{ "medium.users[10].name", "medium", function() return json.decode(medium):get("users"):get(10):get("name"):val() end },
	{ "large.[250].tags[2]", "large", function() return json.decode(large):get(250):get("tags"):get(2):val() end },
}
for _, case in ipairs(reads) do
	local ns = benchNs(case[3], fixtures.ITERS[case[2]])
	ansi.printf("  {gray}%-30s{reset} {bold}%10.1f ns/op{reset}%s", case[1], ns,
		baseline and vsC(ns, baseline[case[2]] and baseline[case[2]].scrape) or "")
end

ansi.printf("\n{gray}decode + unpack: copy everything into Lua tables{reset}")
for _, size in ipairs(fixtures.SIZES) do
	local src = fixtures.source(size)
	bench(size, function() json.decode(src):unpack() end, fixtures.ITERS[size] / 4)
end

ansi.printf("\n{gray}encode: parsed handle back to text{reset}")
for _, size in ipairs(fixtures.SIZES) do
	local ns = benchNs(function() json.encode(decoded[size]) end, fixtures.ITERS[size])
	ansi.printf("  {gray}%-30s{reset} {bold}%10.1f ns/op{reset}%s", size, ns,
		baseline and vsC(ns, baseline[size] and baseline[size].encode) or "")
end

ansi.printf("\n{gray}encode: unpacked Lua tables{reset}")
-- unpacked up front, so the row measures the encoder and not the unpack
local plain = {
	small = decoded.small:unpack(),
	medium = decoded.medium:unpack(),
	large = decoded.large:unpack(),
}
bench("small object", function() json.encode(plain.small) end, 5000)
bench("medium array", function() json.encode(plain.medium) end, 500)
bench("large array", function() json.encode(plain.large) end, 20)

ansi.printf("\n{gray}json.edit: parse, change one field, encode{reset}")
bench("small", function()
	local doc = json.edit.parse(small)
	doc:root():set("age", 31)
	return doc:encode()
end, 5000)
bench("large", function()
	local doc = json.edit.parse(large)
	doc:root():get(250):set("name", "renamed")
	return doc:encode()
end, 100)

if not baseline then
	ansi.printf("\n{yellow}note{reset}: no C baseline found; the package build compiles it\n")
end
