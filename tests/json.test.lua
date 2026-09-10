local test = require("lde-test")
local json = require("json")

-- encode

test.it("encodes primitives", function()
	test.equal(json.encode(nil), "null")
	test.equal(json.encode(true), "true")
	test.equal(json.encode(42), "42")
	test.equal(json.encode("hi"), '"hi"')
	test.equal(json.encode(json.null), "null")
	test.equal(json.encode({ null = json.null }), '{"null":null}')
end)

test.it("encodes arrays", function()
	test.equal(json.encode({ 1, 2, 3 }), "[1,2,3]")
	test.equal(json.encode({}), "[]")
	test.equal(json.encode({ "a", true, 1.5 }), '["a",true,1.5]')
end)

test.it("encodes objects", function()
	test.equal(json.encode({ nested = { 1, 2 } }), '{"nested":[1,2]}')
	test.truthy(json.encode({ a = 1 }):find('"a":1'))
end)

test.it("encode options", function()
	test.equal(json.encode({ a = 1 }, { indent = 2 }), '{\n  "a": 1\n}')
	test.equal(json.encode({ a = 1 }, { indent = 4 }), '{\n    "a": 1\n}')
	test.equal(json.encode(math.huge), "Infinity")
	test.equal(json.encode(math.huge, { infNan = "null" }), "null")
	test.equal(json.encode(0 / 0), "NaN")
	test.equal(json.encode("x/y", { escapeSlashes = true }), '"x\\/y"')
	-- yyjson emits uppercase hex digits
	test.equal(json.encode("caf\u{e9}", { escapeUnicode = true }), '"caf\\u00E9"')
	test.equal(json.encode({ a = 1 }, { newlineAtEnd = true }):sub(-1), "\n")
end)

test.it("encode accepts nil and refuses non-JSON values", function()
	test.equal(json.encode(nil), "null")
	test.errors(function() json.encode(print --[[@as any]]) end)
end)

-- decode

test.it("decodes scalars", function()
	test.equal(json.decode("42"):val(), 42)
	test.equal(json.decode("-3.14"):val(), -3.14)
	test.equal(json.decode("1e2"):val(), 100)
	test.equal(json.decode("true"):val(), true)
	test.equal(json.decode("false"):val(), false)
	test.equal(json.decode('"hello"'):val(), "hello")
	test.equal(json.decode('"line\\nbreak"'):val(), "line\nbreak")
	test.equal(tostring(json.decode("null"):val()), "null")
end)

test.it("json.decode raises on malformed input", function()
	test.errors(function() json.decode("not json") end)
	test.errors(function() json.decode("{") end)
end)

test.it("decode reports the type of the root", function()
	test.equal(json.decode("null"):type(), "null")
	test.equal(json.decode("true"):type(), "boolean")
	test.equal(json.decode("1"):type(), "number")
	test.equal(json.decode('"s"'):type(), "string")
	test.equal(json.decode("[]"):type(), "array")
	test.equal(json.decode("{}"):type(), "object")
end)

-- lazy access

test.it("get reads fields without materializing", function()
	local doc = json.decode('{"name":"alice","age":30,"tags":["a","b"],"meta":{"x":1}}')
	test.equal(doc:get("name"):val(), "alice")
	test.equal(doc:get("age"):val(), 30)
	test.equal(doc:get("tags"):get(1):val(), "a")
	test.equal(doc:get("tags"):get(2):val(), "b")
	test.equal(doc:get("meta"):get("x"):val(), 1)
	test.equal(doc:get("tags"):size(), 2)
	test.equal(doc:size(), 4)
end)

test.it("get takes a default for missing keys", function()
	local doc = json.decode('{"a":1}')
	test.equal(doc:get("nope", "fallback"), "fallback")
	test.equal(doc:get(9, 0), 0)
	test.errors(function() return doc:get("nope") end)
end)

test.it("is() checks the type of a value", function()
	local arr = json.decode('[null,true,1,"s",[],{}]')
	test.truthy(arr:get(1):is("null"))
	test.truthy(arr:get(2):is("boolean"))
	test.truthy(arr:get(3):is("number"))
	test.truthy(arr:get(4):is("string"))
	test.truthy(arr:get(5):is("array"))
	test.truthy(arr:get(6):is("object"))
	test.falsy(arr:get(1):is("string"))
end)

test.it("children yields (key, value) pairs in document order", function()
	local doc = json.decode('{"z":1,"a":2,"m":3}')
	local seen = {}
	local children = doc:children()
	while true do
		local key, value = children()
		if key == nil or value == nil then break end
		seen[#seen + 1] = key .. "=" .. value:val()
	end
	test.equal(table.concat(seen, ","), "z=1,a=2,m=3")
end)

test.it("children yields (index, value) for arrays", function()
	local arr = json.decode("[10,20,30]")
	local seen = {}
	local children = arr:children()
	while true do
		local index, value = children()
		if index == nil or value == nil then break end
		seen[#seen + 1] = index * value:val()
	end
	test.equal(table.concat(seen, ","), "10,40,90")
end)

test.it("keys and values iterate an object", function()
	local doc = json.decode('{"a":1,"b":2,"c":3}')
	local keys = {}
	local keyIter = doc:keys()
	while true do
		local key = keyIter()
		if key == nil then break end
		keys[#keys + 1] = key
	end
	test.equal(table.concat(keys, ","), "a,b,c")

	local total = 0
	local valueIter = doc:values()
	while true do
		local _, value = valueIter()
		if value == nil then break end
		total = total + value:val()
	end
	test.equal(total, 6)
end)

test.it("keys and values are empty for non-containers", function()
	local scalar = json.decode("42")
	test.equal(scalar:keys()(), nil)
	local _, value = scalar:values()()
	test.equal(value, nil)
	test.equal(scalar:children()(), nil)
end)

test.it("unpack materializes a value into Lua data", function()
	local doc = json.decode('{"a":[1,2],"b":"hi","c":{"d":true},"e":null}')
	local t = doc:unpack()
	test.equal(t.a[1], 1)
	test.equal(t.a[2], 2)
	test.equal(t.b, "hi")
	test.equal(t.c.d, true)
	test.equal(tostring(t.e), "null")
	test.equal(json.decode("[1,2,3]"):get(2):unpack(), 2)
end)

-- encoding handles straight back

test.it("encode writes a decoded handle as-is", function()
	local doc = json.decode('{"a":[1,{"b":2}],"c":"x"}')
	test.equal(json.encode(doc), '{"a":[1,{"b":2}],"c":"x"}')
	test.equal(json.encode(doc:get("a")), '[1,{"b":2}]')
	test.equal(json.encode(doc:get("a"):get(2):get("b")), "2")
	test.truthy(json.encode(doc, { indent = 2 }):find("\n"))
end)

-- json5

test.it("json5: comments, trailing commas, unquoted keys", function()
	test.equal(json.decode('{\n// comment\n"a":1}'):get("a"):val(), 1)
	test.equal(json.decode('{"a": /* comment */ 1}'):get("a"):val(), 1)
	test.equal(json.decode("{foo: 1}"):get("foo"):val(), 1)
	test.equal(json.decode("{'key': 1}"):get("key"):val(), 1)
	test.equal(json.decode("'hello'"):val(), "hello")
	test.equal(json.decode('{"a":1,}'):get("a"):val(), 1)
	test.equal(json.decode("[1,2,3,]"):size(), 3)
	test.equal(json.decode("0xFF"):val(), 255)
end)

test.it("json5: Infinity and NaN", function()
	test.equal(json.decode("Infinity"):val(), math.huge)
	test.equal(json.decode("+Infinity"):val(), math.huge)
	test.equal(json.decode("-Infinity"):val(), -math.huge)
	local nan = json.decode("NaN"):val()
	test.truthy(nan ~= nan)
end)

test.it("json5: extended whitespace outside keys", function()
	-- yyjson accepts JSON5 whitespace everywhere except between a key and its colon
	test.equal(json.decode("\u{00a0}{\"a\":\u{00a0}1}"):get("a"):val(), 1)
end)

test.it("strict mode rejects json5", function()
	test.errors(function() json.decode("{a:1}", { json5 = false }) end)
	test.equal(json.decode('{"a":1}', { json5 = false }):get("a"):val(), 1)
end)

-- documents

test.it("Document.parse exposes the root and stats", function()
	local doc = json.Document.parse('{"a":1}')
	test.equal(doc:root():get("a"):val(), 1)
	test.equal(doc:encode(), '{"a":1}')
	local bytes, values = doc:stats()
	test.equal(bytes, 7)
	test.truthy(values >= 3)
	doc:free()
end)

test.it("decode accepts a Document", function()
	local doc = json.Document.parse("[1,2]")
	test.equal(json.decode(doc):size(), 2)
	doc:free()
end)

test.it("freed documents cannot be used", function()
	local doc = json.Document.parse('{"a":1}')
	local root = doc:root()
	doc:free()
	test.errors(function() return root:val() end)
end)

test.it("json.version looks like a semver", function()
	test.truthy(json.version:match("^%d+%.%d+%.%d+$"))
end)

-- edit

test.it("edit.parse edits object fields in place", function()
	local doc = json.edit.parse('{"a":1,"b":2}')
	local root = doc:root()
	test.equal(root:type(), "object")
	root:set("a", 10)
	root:set("c", true)
	root:remove("b")
	test.equal(doc:encode(), '{"a":10,"c":true}')
	doc:free()
end)

test.it("edit set keeps an existing key in place", function()
	local doc = json.edit.parse('{"a":1,"b":2}')
	doc:root():set("a", 3)
	test.equal(doc:encode(), '{"a":3,"b":2}')
	doc:root():set("c", 4)
	test.equal(doc:encode(), '{"a":3,"b":2,"c":4}')
	doc:free()
end)

test.it("edit add allows a duplicate key", function()
	local doc = json.edit.parse('{"a":1}')
	doc:root():add("a", 2)
	test.equal(doc:encode(), '{"a":1,"a":2}')
	doc:free()
end)

test.it("edit arrays: append, insert, set, remove", function()
	local doc = json.edit.parse("[1,2,3]")
	local root = doc:root()
	root:append(4)
	root:insert(1, 0)
	root:set(2, 99)
	test.equal(doc:encode(), "[0,99,2,3,4]")
	root:remove(1)
	test.equal(doc:encode(), "[99,2,3,4]")
	doc:free()
end)

test.it("edit assigns Lua tables as subtrees", function()
	local doc = json.edit.parse('{"config":{}}')
	doc:root():set("config", { darkMode = true, ports = { 8080, 8443 } })
	local out = json.decode(doc:encode())
	test.equal(out:get("config"):get("darkMode"):val(), true)
	test.equal(out:get("config"):get("ports"):get(1):val(), 8080)
	test.equal(out:get("config"):get("ports"):get(2):val(), 8443)
	doc:free()
end)

test.it("edit navigates nested values and edits through them", function()
	local doc = json.edit.parse('{"users":[{"name":"alice"},{"name":"bob"}]}')
	local root = doc:root()
	test.equal(root:get("users"):get(1):get("name"):val(), "alice")
	root:get("users"):get(2):set("name", "robert")
	test.equal(json.decode(doc:encode()):get("users"):get(2):get("name"):val(), "robert")
	doc:free()
end)

test.it("edit reads a value's children in order", function()
	local doc = json.edit.parse('{"z":1,"a":2,"m":3}')
	local seen = {}
	local children = doc:root():children()
	while true do
		local key, value = children()
		if key == nil or value == nil then break end
		seen[#seen + 1] = key .. "=" .. value:val()
	end
	test.equal(table.concat(seen, ","), "z=1,a=2,m=3")
	doc:free()
end)

test.it("edit missing keys yield an inert handle", function()
	local doc = json.edit.parse('{"a":1}')
	local root = doc:root()
	test.equal(root:get("nope"):type(), "missing")
	test.equal(root:get("nope"):size(), 0)
	test.errors(function() return root:get("nope"):val() end)
	test.errors(function() return root:get("nope"):set("x", 1) end)
	doc:free()
end)

test.it("edit parses json5", function()
	local doc = json.edit.parse("{// comment\nname: 'x',\n}")
	test.equal(doc:root():get("name"):val(), "x")
	doc:root():set("name", "y")
	test.equal(json.decode(doc:encode()):get("name"):val(), "y")
	doc:free()
end)

test.it("edit.unpack materializes the edited tree", function()
	local doc = json.edit.parse('{"a":[1,2],"b":"hi"}')
	local t = doc:root():unpack()
	test.equal(t.a[2], 2)
	test.equal(t.b, "hi")
	test.equal(#t.a, 2)
	doc:free()
end)

test.it("edit documents can be snapshotted as read-only", function()
	local doc = json.edit.parse('{"x":1}')
	doc:root():set("y", 2)
	local plain = doc:toDocument()
	test.equal(plain:root():get("y"):val(), 2)
	test.equal(plain:encode(), '{"x":1,"y":2}')
	plain:free()
	doc:free()
end)

test.it("edit raises after the document is freed", function()
	local doc = json.edit.parse('{"a":1}')
	local root = doc:root()
	doc:free()
	test.errors(function() return root:val() end)
end)

-- files

test.it("decodeFile reads a file lazily", function()
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write('{"file":true,"n":2}')
	file:close()
	local doc = json.decodeFile(path)
	test.equal(doc:get("file"):val(), true)
	test.equal(doc:get("n"):val(), 2)
	os.remove(path)
end)

test.it("edit.open saves back to the same file", function()
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write('{"name":"old","count":1}')
	file:close()

	local doc = json.edit.open(path)
	doc:root():set("name", "new")
	doc:root():set("count", 2)
	doc:save()
	doc:free()

	local reloaded = json.decodeFile(path)
	test.equal(reloaded:get("name"):val(), "new")
	test.equal(reloaded:get("count"):val(), 2)
	os.remove(path)
end)

test.it("edit.save can target another path", function()
	local doc = json.edit.parse('{"a":1}')
	local path = os.tmpname()
	doc:save(path)
	doc:free()
	test.equal(json.decodeFile(path):get("a"):val(), 1)
	os.remove(path)
end)
