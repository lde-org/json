-- The benchmark inputs, shared by every bench entry point so both sides of a
-- comparison always measure identical bytes.
--
-- The C baseline reads these same strings from the fixtures file this module
-- writes, so a Lua-vs-C ratio compares like with like.

local json = require("json")

local fixtures = {}

fixtures.SMALL = '{"name":"Alice","age":30,"active":true}'

fixtures.MEDIUM = json.encode({
	users = (function()
		local users = {}
		for i = 1, 20 do
			users[i] = { id = i, name = "user" .. i, score = i * 1.5, active = i % 2 == 0 }
		end
		return users
	end)(),
})

fixtures.LARGE = json.encode((function()
	local items = {}
	for i = 1, 500 do
		items[i] = { id = i, name = "item" .. i, value = i * 3.14, tags = { "a", "b", "c" } }
	end
	return items
end)())

fixtures.JSON5_SRC = [[{
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

fixtures.OUTPUT_DIR = "target/benchmarks"
fixtures.SIZES = { "small", "medium", "large" }
fixtures.ITERS = { small = 20000, medium = 2000, large = 100 }

---@param size string
---@return string
function fixtures.source(size)
	return fixtures[size:upper()]
end

-- Writes the sources as one JSON document for the C baseline to read back.
function fixtures.write()
	os.execute("mkdir -p " .. fixtures.OUTPUT_DIR)
	local file = assert(io.open(fixtures.OUTPUT_DIR .. "/fixtures.json", "w"))
	file:write(json.encode({
		small = fixtures.SMALL,
		medium = fixtures.MEDIUM,
		large = fixtures.LARGE,
	}))
	file:close()
end

-- Runs a compiled C/C++ baseline and parses the JSON it prints. `name` is the
-- binary's basename in the output dir; returns nil when it was not built.
---@param name string
---@return table<string, { parse: number, scrape: number, encode: number }>?
function fixtures.readBaseline(name)
	name = name or "yyjson-baseline"
	local path = fixtures.OUTPUT_DIR .. "/" .. name
	local probe = io.open(path, "rb")
	if not probe then return nil end
	probe:close()

	local out = os.tmpname()
	if os.execute(("%s %s/fixtures.json > %s"):format(path, fixtures.OUTPUT_DIR, out)) ~= 0 then return nil end
	local file = io.open(out, "rb")
	if not file then return nil end
	local text = file:read("a")
	file:close()
	os.remove(out)
	if text == "" then return nil end

	local records = {}
	for name, parse, scrape, encode in text:gmatch(
		'"name"%s*:%s*"([^"]+)".-"parse"%s*:%s*([%d%.]+).-"scrape"%s*:%s*([%d%.]+).-"encode"%s*:%s*([%d%.]+)') do
		records[name] = { parse = tonumber(parse), scrape = tonumber(scrape), encode = tonumber(encode) }
	end
	return records
end

return fixtures
