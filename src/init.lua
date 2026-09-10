-- json: JSON(5) reading, writing and editing for lde, backed by yyjson.
--
--   json.decode(text) / json.decodeFile(path) -> json.Value
--       Lazy handles on the yyjson tree. Nothing is copied into Lua unless you
--       ask for it with :unpack(), so scraping a few fields out of a large
--       document stays cheap.
--
--   json.encode(value) -> string
--       Accepts plain Lua data or any handle from json.decode / json.edit.
--       Lua tables carry no order of their own, so an object's keys are written
--       in whatever order pairs() yields; json.edit preserves document order.
--
--   json.edit.parse(text) / json.edit.open(path) -> json.edit.Document
--       An editable document: set/add/remove fields in place, then encode() or
--       save() it back.
--
-- yyjson's mutable helpers are `static inline` in yyjson.h, so build.lua
-- compiles a C shim into the shared library loaded next to this module.

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
  typedef uint32_t yyjson_read_flag;
  typedef uint32_t yyjson_write_flag;

  typedef struct yyjson_alc {
    void *(*malloc)(void *ctx, size_t size);
    void *(*realloc)(void *ctx, void *ptr, size_t old_size, size_t size);
    void (*free)(void *ctx, void *ptr);
    void *ctx;
  } yyjson_alc;

  typedef union yyjson_val_uni {
    uint64_t    u64;
    int64_t     i64;
    double      f64;
    const char *str;
    void       *ptr;
    size_t      ofs;
  } yyjson_val_uni;

  typedef struct yyjson_val {
    uint64_t      tag;
    yyjson_val_uni uni;
  } yyjson_val;

  typedef struct yyjson_doc {
    yyjson_val *root;
    yyjson_alc  alc;
    size_t      dat_read;
    size_t      val_read;
    char       *str_pool;
  } yyjson_doc;

  typedef struct yyjson_mut_val {
    uint64_t      tag;
    yyjson_val_uni uni;
    struct yyjson_mut_val *next;
  } yyjson_mut_val;

  typedef struct yyjson_mut_doc {
    yyjson_mut_val *root;
  } yyjson_mut_doc;

  typedef struct yyjson_read_err  { uint32_t code; const char *msg; size_t pos; } yyjson_read_err;
  typedef struct yyjson_write_err { uint32_t code; const char *msg; } yyjson_write_err;

  void free(void *ptr);
  int memcmp(const void *s1, const void *s2, size_t n);

  uint32_t yyjson_version(void);
  yyjson_doc *yyjson_read_opts(const char *dat, size_t len, yyjson_read_flag flg, const yyjson_alc *alc, yyjson_read_err *err);
  yyjson_doc *yyjson_read_file(const char *path, yyjson_read_flag flg, const yyjson_alc *alc, yyjson_read_err *err);
  char *yyjson_write_opts(const yyjson_doc *doc, yyjson_write_flag flg, const yyjson_alc *alc, size_t *len, yyjson_write_err *err);
  char *yyjson_val_write_opts(const yyjson_val *val, yyjson_write_flag flg, const yyjson_alc *alc, size_t *len, yyjson_write_err *err);

  yyjson_mut_doc *yyjson_doc_mut_copy(const yyjson_doc *doc, const yyjson_alc *alc);
  yyjson_doc *yyjson_mut_doc_imut_copy(const yyjson_mut_doc *doc, const yyjson_alc *alc);
  void yyjson_mut_doc_free(yyjson_mut_doc *doc);
  char *yyjson_mut_write_opts(const yyjson_mut_doc *doc, yyjson_write_flag flg, const yyjson_alc *alc, size_t *len, yyjson_write_err *err);
  char *yyjson_mut_val_write_opts(const yyjson_mut_val *val, yyjson_write_flag flg, const yyjson_alc *alc, size_t *len, yyjson_write_err *err);

  yyjson_mut_val *shim_mut_null(yyjson_mut_doc *doc);
  yyjson_mut_val *shim_mut_bool(yyjson_mut_doc *doc, int value);
  yyjson_mut_val *shim_mut_uint(yyjson_mut_doc *doc, uint64_t value);
  yyjson_mut_val *shim_mut_sint(yyjson_mut_doc *doc, int64_t value);
  yyjson_mut_val *shim_mut_real(yyjson_mut_doc *doc, double value);
  yyjson_mut_val *shim_mut_string(yyjson_mut_doc *doc, const char *str, size_t len);
  yyjson_mut_val *shim_mut_array(yyjson_mut_doc *doc);
  yyjson_mut_val *shim_mut_object(yyjson_mut_doc *doc);

  yyjson_mut_val *shim_mut_arr_get(yyjson_mut_val *arr, size_t idx);
  int shim_mut_arr_append(yyjson_mut_val *arr, yyjson_mut_val *val);
  int shim_mut_arr_insert(yyjson_mut_val *arr, yyjson_mut_val *val, size_t idx);
  yyjson_mut_val *shim_mut_arr_remove(yyjson_mut_val *arr, size_t idx);

  yyjson_mut_val *shim_mut_obj_get(yyjson_mut_val *obj, const char *key, size_t len);
  yyjson_mut_val *shim_mut_obj_set(yyjson_mut_doc *doc, yyjson_mut_val *obj, const char *key, size_t len, yyjson_mut_val *val);
  yyjson_mut_val *shim_mut_obj_add(yyjson_mut_doc *doc, yyjson_mut_val *obj, const char *key, size_t len, yyjson_mut_val *val);
  yyjson_mut_val *shim_mut_obj_remove(yyjson_mut_val *obj, const char *key, size_t len);
  yyjson_mut_val *shim_mut_obj_iter_init(yyjson_mut_val *obj);
  yyjson_mut_val *shim_mut_obj_iter_next(yyjson_mut_val *key);
  yyjson_mut_val *shim_mut_obj_iter_next_key(yyjson_mut_val *key);
]]

local here = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or ""
local sep  = string.sub(package.config, 1, 1)
local libName = sep == "\\" and "yyjson.dll" or (jit.os == "OSX" and "libyyjson.dylib" or "libyyjson.so")
local lib = ffi.load(here .. libName)

local cast       = ffi.cast
local valPtr     = ffi.typeof("yyjson_val*")
local u8Ptr      = ffi.typeof("const uint8_t*")
local readErrCT  = ffi.typeof("yyjson_read_err")
local writeErrCT = ffi.typeof("yyjson_write_err")

-- ── value layout ──────────────────────────────────────────────────────────────
-- yyjson_val and yyjson_mut_val both begin with { uint64_t tag; union {...}; }:
-- tag % 8 is the type, tag & 0x18 the subtype, tag / 256 the payload size, so
-- one reader serves both. Reaching a container's children differs:
--   immutable  children follow the container, and `ofs` holds the byte distance
--              to the value just past its subtree (unsafe_yyjson_get_next)
--   mutable    `ptr` is the LAST child, linked through a circular list where
--              object even links are keys and odd links are values

local TY_RAW, TY_NULL, TY_BOOL, TY_NUM, TY_STR, TY_ARR, TY_OBJ = 1, 2, 3, 4, 5, 6, 7
local SUB_TRUE, SUB_SINT, SUB_REAL = 8, 8, 16
local VAL_SIZE = 16

local function tagLow(v) return tonumber(v.tag % 256) end
local function getType(v) return tagLow(v) % 8 end
local function getSub(v) return bit.band(tagLow(v), 0x18) end
local function getLen(v) return tonumber(v.tag / 256) end

local function isContainer(v)
	local t = getType(v)
	return t == TY_ARR or t == TY_OBJ
end

local function stepChild(v)
	if isContainer(v) then
		return cast(valPtr, cast(u8Ptr, v) + tonumber(v.uni.ofs))
	end
	return v + 1
end

---@param v any
---@return string
local function readString(v)
	local t = getType(v)
	if t ~= TY_STR and t ~= TY_RAW then return "" end
	return ffi.string(v.uni.str, getLen(v))
end

---@param v any
---@return boolean
local function readBool(v) return getSub(v) == SUB_TRUE end

---@param v any
---@return number
local function readNumber(v)
	local sub = getSub(v)
	if sub == SUB_REAL then return v.uni.f64 end
	-- cdata integers convert to Lua numbers, so the annotation holds
	return sub == SUB_SINT and tonumber(v.uni.i64) or tonumber(v.uni.u64) or 0
end

local TYPE_NAME = { "raw", "null", "boolean", "number", "string", "array", "object" }

---@param v any
---@return string
local function typeName(v) return TYPE_NAME[getType(v)] or "unknown" end

-- ── options ───────────────────────────────────────────────────────────────────

local READ_ALLOW_TRAILING_COMMAS   = 4
local READ_ALLOW_COMMENTS          = 8
local READ_ALLOW_INF_AND_NAN       = 16
local READ_BIGNUM_AS_RAW           = 128
local READ_ALLOW_EXT_NUMBER        = 512
local READ_ALLOW_EXT_ESCAPE        = 1024
local READ_ALLOW_EXT_WHITESPACE    = 2048
local READ_ALLOW_SINGLE_QUOTED_STR = 4096
local READ_ALLOW_UNQUOTED_KEY      = 8192

-- Everything JSON5 allows that yyjson can represent.
local READ_JSON5 = READ_ALLOW_TRAILING_COMMAS + READ_ALLOW_COMMENTS
	+ READ_ALLOW_INF_AND_NAN + READ_ALLOW_EXT_NUMBER + READ_ALLOW_EXT_ESCAPE
	+ READ_ALLOW_EXT_WHITESPACE + READ_ALLOW_SINGLE_QUOTED_STR + READ_ALLOW_UNQUOTED_KEY

local WRITE_PRETTY                = 1
local WRITE_ESCAPE_UNICODE        = 2
local WRITE_ESCAPE_SLASHES        = 4
local WRITE_ALLOW_INF_AND_NAN     = 8
local WRITE_INF_AND_NAN_AS_NULL   = 16
local WRITE_PRETTY_TWO_SPACES     = 64
local WRITE_NEWLINE_AT_END        = 128

-- ── types ─────────────────────────────────────────────────────────────────────

---@alias json.Type "raw"|"null"|"boolean"|"number"|"string"|"array"|"object"
---@alias json.Scalar string|number|boolean|json.null
---@alias json.Array json.Scalar[]|table[]
---@alias json.Object table<string, json.Data>
---@alias json.Data json.Scalar|nil|json.Array|json.Object|json.Value|json.edit.Value

---@class json.null

-- A handle on one value inside a parsed document. It borrows the document's
-- memory, so it stops working once that document is freed.

---@class json.DecodeOptions
---@field json5? boolean Accept JSON5 comments, trailing commas and unquoted keys (default true)

---@class json.EncodeOptions
---@field indent? integer|false Pretty-print with this indent width (default: compact)
---@field escapeUnicode? boolean Escape non-ASCII as \uXXXX
---@field escapeSlashes? boolean Escape '/' as '\/'
---@field newlineAtEnd? boolean Append a trailing newline
---@field infNan? "value"|"null" Write NaN/Infinity as literals (default) or null
---@field flags? integer Raw yyjson write flag bitmask (overrides the fields above)

-- ── value handles ─────────────────────────────────────────────────────────────

local json = { null = setmetatable({}, {
	__tostring = function() return "null" end,
	__name = "json.null",
}) }

-- Returned by a json.edit lookup that found nothing: it flows through further
-- navigation and raises the moment a real value is needed.
local MISSING = setmetatable({
	__tostring = function() return "missing" end,
	__name = "json.missing",
}, {
	-- Navigating or reading a missing value is a mistake, but the handle around
	-- it stays inert so chains still read naturally; __json points back at the
	-- sentinel so the accessors can report it precisely.
	__index = function(_, key) error("json: no value at that key", 2) end,
})
MISSING.__json = MISSING

local Value, Document, EditValue, EditDocument

---@param value json.Value|json.edit.Value|json.Document
---@return any
local function handleJson(value)
	local node = rawget(value, "__json")
	-- Values borrow the document's memory, so a freed document frees them too.
	local doc = rawget(value, "__doc")
	if node == nil or (doc ~= nil and rawget(doc, "__json") == nil) then
		error("json: this handle was freed", 3)
	end
	if node == MISSING then error("json: no value at that key", 3) end
	return node
end

---@param node any
---@param doc json.Document
---@return json.Value
local function newValue(node, doc)
	return setmetatable({ __json = node, __doc = doc }, Value)
end

---@param node any
---@param edit json.edit.Document
---@return json.edit.Value
local function newEditValue(node, edit)
	-- A NULL yyjson_mut_val* is truthy cdata, so `node or MISSING` would keep it.
	if node == nil then node = MISSING end
	return setmetatable({ __json = node, edit = edit }, EditValue)
end

---@param value json.edit.Value|json.edit.Document
---@return any
local function mutNode(value)
	local node = rawget(value, "__json")
	local edit = rawget(value, "edit")
	if node == nil or (edit ~= nil and rawget(edit, "__json") == nil) then
		error("json: this handle was freed", 3)
	end
	if node == MISSING then error("json: no value at that key", 3) end
	return node
end

---@param node any
---@return boolean
local function isMissing(node) return node == MISSING or node == nil end

---@param opts? json.DecodeOptions
---@return integer
local function readFlags(opts)
	if opts and opts.json5 == false then return READ_ALLOW_INF_AND_NAN + READ_BIGNUM_AS_RAW end
	return READ_JSON5
end

---@param opts? json.EncodeOptions
---@return integer
local function writeFlags(opts)
	if opts and opts.flags ~= nil then return opts.flags end
	local flags = WRITE_ALLOW_INF_AND_NAN
	opts = opts or {}
	local indent = opts.indent
	if type(indent) == "number" then
		flags = flags + (indent <= 2 and WRITE_PRETTY_TWO_SPACES or WRITE_PRETTY)
	end
	if opts.escapeUnicode then flags = flags + WRITE_ESCAPE_UNICODE end
	if opts.escapeSlashes then flags = flags + WRITE_ESCAPE_SLASHES end
	if opts.newlineAtEnd then flags = flags + WRITE_NEWLINE_AT_END end
	if opts.infNan == "null" then flags = flags + WRITE_INF_AND_NAN_AS_NULL end
	return flags
end

---@param err any
local function writeError(err)
	error("json: " .. (err.msg and ffi.string(err.msg) or "unknown write error"), 3)
end

---@param err any
---@param withPos boolean
---@return string
local function readError(err, withPos)
	local msg = err.msg and ffi.string(err.msg) or "unknown error"
	if withPos and tonumber(err.pos) > 0 then
		return ("json: %s at byte %d"):format(msg, tonumber(err.pos))
	end
	return "json: " .. msg
end

---@param fn function
---@param arg any
---@param opts? json.EncodeOptions
---@return string
local function writeCString(fn, arg, opts)
	local len = ffi.new("size_t[1]")
	local err = ffi.new(writeErrCT) ---@type any
	local out = fn(arg, writeFlags(opts), nil, len, err)
	if out == nil then writeError(err) end
	local result = ffi.string(out, tonumber(len[0]))
	ffi.C.free(out)
	return result
end

-- ── plain Lua data -> json ────────────────────────────────────────────────────
-- The tree is laid out as a flat array of immutable yyjson_val carrying the
-- sibling offsets the writer follows, then handed to yyjson_val_write_opts,
-- which only ever reads the root. Strings the buffer points at stay in `held`
-- so the GC cannot collect them mid-write.

-- A table is an array when its keys are exactly the dense sequence 1..n.
---@param t any
---@return boolean
local function isArray(t)
	if type(t) ~= "table" then return false end
	local count = 0
	for key in pairs(t) do
		count = count + 1
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			for _ in pairs(t) do count = count + 1 end
			return count == 0
		end
	end
	return count == 0 or t[1] ~= nil
end

--- Key order of a Lua table is unspecified; json.encode writes object keys in
--- the order pairs() happens to give.
---@param t table
---@return string[]
local function objectKeys(t)
	local keys = {}
	for key in pairs(t) do
		if type(key) == "string" then keys[#keys + 1] = key end
	end
	return keys
end

---@param t table
---@param array boolean
---@return fun(): integer|string|nil, any
local function tableEntries(t, array)
	local keys, count
	if array then
		count = #t
	else
		keys = objectKeys(t)
		count = #keys
	end
	local i = 0
	return function()
		i = i + 1
		if i > count then return nil end
		if array then return i, t[i] end
		local key = keys[i]
		return key, t[key]
	end
end

---@param slot any
---@param value string|number|boolean
local function setLeaf(slot, value)
	local t = type(value)
	if t == "string" then
		slot.tag = #value * 256 + TY_STR
		slot.uni.str = value
	elseif t == "boolean" then
		slot.tag = value and (TY_BOOL + SUB_TRUE) or TY_BOOL
	elseif value ~= value or value == math.huge or value == -math.huge then
		slot.tag = TY_NUM + SUB_REAL
		slot.uni.f64 = value
	elseif value % 1 ~= 0 then
		slot.tag = TY_NUM + SUB_REAL
		slot.uni.f64 = value
	elseif value >= 0 and value < 18446744073709551616.0 then
		slot.tag = TY_NUM
		slot.uni.u64 = value
	elseif value >= -9223372036854775808.0 and value < 0 then
		slot.tag = TY_NUM + SUB_SINT
		slot.uni.i64 = value
	else
		slot.tag = TY_NUM + SUB_REAL
		slot.uni.f64 = value
	end
end

local countNodes

---@param value any
---@param array boolean
---@return integer
local function countChildren(value, array)
	local total, it = 0, tableEntries(value, array)
	while true do
		local key, child = it()
		if key == nil then break end
		total = total + (array and 1 or 1 + countNodes(key)) + countNodes(child)
	end
	return total
end

---@param value any
---@return integer
function countNodes(value)
	if value == nil or value == json.null or type(value) ~= "table" then return 1 end
	return 1 + countChildren(value, isArray(value))
end

---@param value any
---@param opts? json.EncodeOptions
---@return string
local function encodeTable(value, opts)
	if value == nil or value == json.null then return "null" end
	local buf = ffi.new("yyjson_val[?]", countNodes(value) + 1)
	local held = {}
	local index = 0

	local function put(value)
		index = index + 1
		local at = index
		-- json.null is a table, so it has to be recognised before the container
		-- branch below would walk it as an empty object.
		if value == nil or value == json.null then
			held[#held + 1] = value
			buf[at].tag = TY_NULL
			return
		end
		if type(value) ~= "table" then
			held[#held + 1] = value
			setLeaf(buf[at], value)
			return
		end
		local array = isArray(value)
		local children, it = 0, tableEntries(value, array)
		while true do
			local key, child = it()
			if key == nil then break end
			children = children + 1
			if not array then
				index = index + 1
				held[#held + 1] = key
				setLeaf(buf[index], key)
			end
			put(child)
		end
		-- Index into buf again: the recursion above wrote the following slots,
		-- and a slot captured before the loop aliases the last of them.
		buf[at].tag = children * 256 + (array and TY_ARR or TY_OBJ)
		-- Immutable containers carry the byte distance to the value just past
		-- their subtree.
		buf[at].uni.ofs = (index - at + 1) * VAL_SIZE
	end

	put(value)
	-- Slot 0 stays empty so the root occupies a real slot and `index` stays the
	-- count of written slots.
	return writeCString(lib.yyjson_val_write_opts, buf + 1, opts)
end

local function toMut(value, doc)
	if getmetatable(value) == EditValue then return rawget(value, "__json") end
	if value == nil or value == json.null then return lib.shim_mut_null(doc) end
	local t = type(value)
	if t == "string" then return lib.shim_mut_string(doc, value, #value) end
	if t == "boolean" then return lib.shim_mut_bool(doc, value and 1 or 0) end
	if t == "number" then
		if value % 1 == 0 and value >= 0 and value < 18446744073709551616.0 then
			return lib.shim_mut_uint(doc, value)
		end
		if value % 1 == 0 and value >= -9223372036854775808.0 and value < 0 then
			return lib.shim_mut_sint(doc, value)
		end
		return lib.shim_mut_real(doc, value)
	end
	if t ~= "table" then error("json: cannot encode a " .. t, 3) end

	local array = isArray(value)
	local it = tableEntries(value, array)
	if array then
		local root = lib.shim_mut_array(doc)
		while true do
			local key, child = it()
			if key == nil then break end
			lib.shim_mut_arr_append(root, toMut(child, doc))
		end
		return root
	end
	local root = lib.shim_mut_object(doc)
	while true do
		local key, child = it()
		if key == nil then break end
		lib.shim_mut_obj_add(doc, root, key, #key, toMut(child, doc))
	end
	return root
end

-- ── read path ─────────────────────────────────────────────────────────────────

---@param node any
---@return any
local function unpackNode(node)
	local t = getType(node)
	if t == TY_NULL then return json.null end
	if t == TY_BOOL then return readBool(node) end
	if t == TY_NUM then return readNumber(node) end
	if t == TY_STR or t == TY_RAW then return readString(node) end
	if t == TY_ARR then
		local out = {}
		local child = node + 1
		for i = 1, getLen(node) do
			out[i] = unpackNode(child)
			child = stepChild(child)
		end
		return out
	end
	local out = {}
	local key = node + 1
	for _ = 1, getLen(node) do
		out[readString(key)] = unpackNode(stepChild(key))
		key = stepChild(stepChild(key))
	end
	return out
end

---@param node any
---@param key string|integer
---@return any|nil
local function nodeGet(node, key)
	local t = getType(node)
	if t == TY_ARR then
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > getLen(node) then return nil end
		local child = node + 1
		for _ = 2, key do child = stepChild(child) end
		return child
	end
	if t ~= TY_OBJ or type(key) ~= "string" then return nil end
	local len = #key
	local pair = node + 1
	for _ = 1, getLen(node) do
		if getLen(pair) == len and ffi.C.memcmp(pair.uni.str, key, len) == 0 then return pair + 1 end
		pair = stepChild(stepChild(pair))
	end
	return nil
end

---@alias json.edit.Value json.EditValue
---@alias json.edit.Document json.EditDocument

--- A handle on one value inside a parsed document. It borrows the document's
--- memory, so it stops working once that document is freed.
---@class json.Value
---@field __json any yyjson_val*
---@field __doc json.Document
Value = {}
Value.__index = Value

--- "null", "boolean", "number", "string", "array" or "object".
---@return json.Type
function Value:type() return typeName(handleJson(self)) end

---@param kind json.Type
---@return boolean
function Value:is(kind) return typeName(handleJson(self)) == kind end

--- Elements for arrays and objects, bytes for strings, 0 otherwise.
---@return integer
function Value:size()
	local node = handleJson(self)
	if isContainer(node) or getType(node) == TY_STR or getType(node) == TY_RAW then
		return getLen(node)
	end
	return 0
end

--- Fetch a child by array index or object key; raises when it is missing unless
--- a default is given.
---@param key string|integer
---@param default? any
---@return json.Value|any
function Value:get(key, default)
	local child = nodeGet(handleJson(self), key)
	if child == nil then
		if default ~= nil then return default end
		error(("json: no %s %s"):format(type(key) == "number" and "index" or "key", tostring(key)), 2)
	end
	return newValue(child, self.__doc)
end

--- The scalar this value holds, or the value itself for arrays and objects.
---@return json.Scalar|json.Value
function Value:val()
	local node = handleJson(self)
	local t = getType(node)
	if t == TY_NULL then return json.null end
	if t == TY_BOOL then return readBool(node) end
	if t == TY_NUM then return readNumber(node) end
	if t == TY_STR or t == TY_RAW then return readString(node) end
	return self
end

--- Iterate children: arrays yield (index, value), objects (key, value). The key
--- is never nil, which is what a generic for needs to keep going.
---@return fun(): integer|string|nil, json.Value|nil
function Value:children()
	local node = handleJson(self)
	if not isContainer(node) then return function() return nil, nil end end
	local doc, remaining = self.__doc, getLen(node)
	local child, key, index = node + 1, node + 1, 0
	local obj = getType(node) == TY_OBJ
	return function()
		if remaining <= 0 then return nil end
		remaining = remaining - 1
		if not obj then
			index = index + 1
			local item = child
			child = stepChild(item)
			return index, newValue(item, doc)
		end
		local name = readString(key)
		local item = stepChild(key)
		key = stepChild(item)
		return name, newValue(item, doc)
	end
end

---@return fun(): string|nil
function Value:keys()
	if not self:is("object") then return function() return nil end end
	local children = self:children()
	local function nextKey() ---@return string|nil
		return children()
	end
	return nextKey
end

--- Yields (_, value); the constant first value keeps a generic for from
--- stopping on a value that happens to be falsey.
---@return fun(): boolean, json.Value|nil
function Value:values()
	local kind = self:type()
	if kind ~= "array" and kind ~= "object" then return function() return false, nil end end
	local children = self:children()
	---@return boolean, json.Value|nil
	return function()
		local _, value = children()
		if value == nil then return false, nil end
		return true, value
	end
end

--- Copy this value (and everything under it) into Lua tables. Array indices and
--- json.null arrive as-is; the key order of objects is kept for json.encode.
---@return any
function Value:unpack() return unpackNode(handleJson(self)) end

-- ── read documents ────────────────────────────────────────────────────────────

---@class json.Document
---@field __json any yyjson_doc* or nil once freed
---@field __source string the JSON text or file path it came from
Document = {}
Document.__index = Document

---@param source string
---@param opts? json.DecodeOptions
---@return json.Document
function Document.parse(source, opts)
	local err = ffi.new(readErrCT) ---@type any
	local ptr = lib.yyjson_read_opts(source, #source, readFlags(opts), nil, err)
	if ptr == nil then error(readError(err, true), 2) end
	return setmetatable({ __json = ptr, __source = source }, Document)
end

--- yyjson reads the file itself, so its contents never pass through Lua.
---@param path string
---@param opts? json.DecodeOptions
---@return json.Document
function Document.open(path, opts)
	local err = ffi.new(readErrCT) ---@type any
	local ptr = lib.yyjson_read_file(path, readFlags(opts), nil, err)
	if ptr == nil then error(readError(err, false), 2) end
	return setmetatable({ __json = ptr, __source = path }, Document)
end

---@return json.Value
function Document:root() return newValue(handleJson(self).root, self) end

---@param opts? json.EncodeOptions
---@return string
function Document:encode(opts) return writeCString(lib.yyjson_write_opts, handleJson(self), opts) end

--- Bytes read from the source, and how many values it contains.
---@return integer bytes
---@return integer values
function Document:stats()
	local doc = handleJson(self)
	return tonumber(doc.dat_read) or 0, tonumber(doc.val_read) or 0
end

function Document:free()
	local ptr = rawget(self, "__json")
	if ptr == nil then return end
	rawset(self, "__json", nil)
	-- yyjson_doc_free is inline: the allocator and the string pool are ours.
	local alc = ptr.alc
	if ptr.str_pool ~= nil then alc.free(alc.ctx, ptr.str_pool) end
	alc.free(alc.ctx, ptr)
end

Document.__gc = Document.free

-- ── edit path ─────────────────────────────────────────────────────────────────

--- A handle on one value inside an editable document.
---@class json.EditValue
---@field __json any yyjson_mut_val*
---@field edit json.edit.Document
EditValue = {}
EditValue.__index = EditValue

--- "null", "boolean", "number", "string", "array", "object" or "missing".
---@return json.Type|"missing"
function EditValue:type()
	if isMissing(rawget(self, "__json")) then return "missing" end
	return typeName(mutNode(self))
end

---@param kind json.Type
---@return boolean
function EditValue:is(kind) return self:type() == kind end

--- Elements for arrays and objects, bytes for strings, 0 otherwise.
---@return integer
function EditValue:size()
	local node = rawget(self, "__json")
	if isMissing(node) or not (isContainer(node) or getType(node) == TY_STR) then return 0 end
	return getLen(node)
end

--- Fetch a child by array index or object key. A missing key yields a handle
--- that raises when used, so lookups can be chained.
---@param key string|integer
---@return json.edit.Value
function EditValue:get(key)
	local node = mutNode(self)
	local edit = self.edit
	local t = getType(node)
	if t == TY_ARR then
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > getLen(node) then
			return newEditValue(nil, edit)
		end
		return newEditValue(lib.shim_mut_arr_get(node, key - 1), edit)
	end
	if t == TY_OBJ and type(key) == "string" then
		return newEditValue(lib.shim_mut_obj_get(node, key, #key), edit)
	end
	return newEditValue(nil, edit)
end

--- The scalar this value holds, or the value itself for arrays and objects.
---@return json.Scalar|json.edit.Value
function EditValue:val()
	local node = mutNode(self)
	local t = getType(node)
	if t == TY_NULL then return json.null end
	if t == TY_BOOL then return readBool(node) end
	if t == TY_NUM then return readNumber(node) end
	if t == TY_STR then return readString(node) end
	return self
end

--- Iterate children in document order: arrays yield (index, value), objects
--- (key, value).
---@return fun(): integer|string|nil, json.edit.Value|nil
function EditValue:children()
	local node = rawget(self, "__json")
	if isMissing(node) or not isContainer(node) then return function() return nil end end
	local edit = self.edit
	if getType(node) == TY_ARR then
		local remaining, index = getLen(node), 0
		return function()
			if remaining <= 0 then return nil end
			remaining = remaining - 1
			index = index + 1
			return index, newEditValue(lib.shim_mut_arr_get(node, index - 1), edit)
		end
	end
	-- Keys form a circular sibling list. Counting the steps is more robust than
	-- comparing pointers: after n steps the cursor is back at the head.
	local remaining = getLen(node)
	local cursor = lib.shim_mut_obj_iter_init(node)
	return function()
		if remaining <= 0 or cursor == nil then return nil end
		remaining = remaining - 1
		local key = lib.shim_mut_obj_iter_next_key(cursor)
		local value = lib.shim_mut_obj_iter_next(key)
		cursor = key
		return readString(key), newEditValue(value, edit)
	end
end

---@return fun(): string|nil
function EditValue:keys()
	if not self:is("object") then return function() return nil end end
	local children = self:children()
	---@return string|nil
	return function()
		local key = children()
		---@cast key string|nil
		return key
	end
end

--- Yields (_, value); the constant first value keeps a generic for from
--- stopping on a value that happens to be falsey.
---@return fun(): boolean, json.edit.Value|nil
function EditValue:values()
	local kind = self:type()
	if kind ~= "array" and kind ~= "object" then return function() return false, nil end end
	local children = self:children()
	return function()
		local _, value = children()
		if value == nil then return false, nil end
		return true, value
	end
end

--- Copy this value (and everything under it) into Lua tables.
---@return any
function EditValue:unpack()
	local node = mutNode(self)
	local t = getType(node)
	if t == TY_NULL then return json.null end
	if t == TY_BOOL then return readBool(node) end
	if t == TY_NUM then return readNumber(node) end
	if t == TY_STR then return readString(node) end
	local out = {}
	local children = self:children()
	while true do
		local key, value = children()
		if key == nil or value == nil then break end
		out[key] = value:unpack()
	end
	return out
end

--- Set a child, appending it when it does not exist yet: a key for objects, a
--- 1-based index for arrays. Object keys keep their position when replaced.
---@param key string|integer
---@param value json.Data
---@return json.edit.Value
function EditValue:set(key, value)
	local node = mutNode(self)
	local edit = self.edit
	local doc = edit:docPtr()
	local t = getType(node)
	if t == TY_ARR then
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			error("json: array index must be a positive integer", 2)
		end
		local mut = toMut(value, doc)
		if key > getLen(node) then
			lib.shim_mut_arr_append(node, mut)
			return newEditValue(mut, edit)
		end
		lib.shim_mut_arr_remove(node, key - 1)
		lib.shim_mut_arr_insert(node, mut, key - 1)
		return newEditValue(mut, edit)
	end
	if t ~= TY_OBJ then error("json: cannot set a child on a " .. self:type(), 2) end
	if type(key) ~= "string" then error("json: object keys must be strings", 2) end
	return newEditValue(lib.shim_mut_obj_set(doc, node, key, #key, toMut(value, doc)), edit)
end

-- Append a key/value pair to an object, even when the key already exists.
---@param key string
---@param value json.Data
---@return json.edit.Value
function EditValue:add(key, value)
	local node = mutNode(self)
	if getType(node) ~= TY_OBJ then error("json: add needs an object", 2) end
	if type(key) ~= "string" then error("json: object keys must be strings", 2) end
	local edit = self.edit
	return newEditValue(lib.shim_mut_obj_add(edit:docPtr(), node, key, #key, toMut(value, edit:docPtr())), edit)
end

--- Append a value to an array.
---@param value json.Data
---@return json.edit.Value
function EditValue:append(value)
	local node = mutNode(self)
	if getType(node) ~= TY_ARR then error("json: append needs an array", 2) end
	local edit = self.edit
	local mut = toMut(value, edit:docPtr())
	lib.shim_mut_arr_append(node, mut)
	return newEditValue(mut, edit)
end

--- Insert a value into an array at a 1-based index, moving the rest along.
---@param index integer
---@param value json.Data
---@return json.edit.Value
function EditValue:insert(index, value)
	local node = mutNode(self)
	if getType(node) ~= TY_ARR then error("json: insert needs an array", 2) end
	if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
		error("json: array index must be a positive integer", 2)
	end
	local edit = self.edit
	local mut = toMut(value, edit:docPtr())
	lib.shim_mut_arr_insert(node, mut, index - 1)
	return newEditValue(mut, edit)
end

--- Remove a child and hand back what was removed.
---@param key string|integer
---@return json.edit.Value
function EditValue:remove(key)
	local node = mutNode(self)
	local t = getType(node)
	if t == TY_OBJ then
		if type(key) ~= "string" then error("json: object keys must be strings", 2) end
		return newEditValue(lib.shim_mut_obj_remove(node, key, #key), self.edit)
	end
	if t == TY_ARR then
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			error("json: array index must be a positive integer", 2)
		end
		return newEditValue(lib.shim_mut_arr_remove(node, key - 1), self.edit)
	end
	return newEditValue(nil, self.edit)
end

---@class json.EditDocument
---@field __json any yyjson_mut_doc* or nil once freed
---@field path string? set by json.edit.open, used by save()
EditDocument = {}
EditDocument.__index = EditDocument

--- Parse JSON (or JSON5) text into an editable document.
---@param text string
---@param opts? json.DecodeOptions
---@return json.edit.Document
function EditDocument.parse(text, opts)
	local doc = Document.parse(text, opts)
	return EditDocument.import(doc)
end

---@param doc json.Document
---@return json.edit.Document
function EditDocument.import(doc)
	local mutable = lib.yyjson_doc_mut_copy(handleJson(doc), nil)
	doc:free()
	if mutable == nil then error("json: failed to make an editable copy", 2) end
	return setmetatable({ __json = mutable }, EditDocument)
end

--- Open a JSON (or JSON5) file for editing; the document remembers the path so
--- save() can write it back.
---@param path string
---@param opts? json.DecodeOptions
---@return json.edit.Document
function EditDocument.open(path, opts)
	local edit = EditDocument.import(Document.open(path, opts))
	edit.path = path
	return edit
end

---@return any
function EditDocument:docPtr()
	local ptr = rawget(self, "__json")
	if ptr == nil then error("json: this document has been freed", 2) end
	return ptr
end

---@return json.edit.Value
function EditDocument:root()
	local doc = self:docPtr()
	if doc.root == nil then
		-- yyjson needs a root before it can write anything.
		doc.root = lib.shim_mut_object(doc)
	end
	return newEditValue(doc.root, self)
end

--- Snapshot the document as a read-only json.Document.
---@return json.Document
function EditDocument:toDocument()
	local ptr = lib.yyjson_mut_doc_imut_copy(self:docPtr(), nil)
	if ptr == nil then error("json: failed to copy the document", 2) end
	return setmetatable({ __json = ptr }, Document)
end

---@param opts? json.EncodeOptions
---@return string
function EditDocument:encode(opts)
	return writeCString(lib.yyjson_mut_write_opts, self:docPtr(), opts)
end

--- Write the document back to its file through a temp file, so a crash mid-write
--- cannot truncate the original.
---@param path? string Defaults to the path given to json.edit.open.
---@param opts? json.EncodeOptions
function EditDocument:save(path, opts)
	path = path or self.path
	if path == nil then error("json: no path to save to", 2) end
	local tmp = path .. ".lde-json-tmp"
	local file = io.open(tmp, "wb")
	if file == nil then error("json: cannot write " .. tmp, 2) end
	file:write(self:encode(opts))
	file:close()
	if not os.rename(tmp, path) then
		os.remove(tmp)
		error("json: cannot replace " .. path, 2)
	end
	self.path = path
end

function EditDocument:free()
	local doc = rawget(self, "__json")
	if doc == nil then return end
	rawset(self, "__json", nil)
	lib.yyjson_mut_doc_free(doc)
end

EditDocument.__gc = EditDocument.free

-- ── public api ────────────────────────────────────────────────────────────────

--- Parse JSON (or JSON5) text and hand back a lazy handle on its root value.
---@param source string|json.Document
---@param opts? json.DecodeOptions
---@return json.Value
function json.decode(source, opts)
	if getmetatable(source) == Document then return source --[[@as json.Document]]:root() end
	return Document.parse(source --[[@as string]], opts):root()
end

--- Read and parse a JSON file, returning a lazy handle on its root value.
---@param path string
---@param opts? json.DecodeOptions
---@return json.Value
function json.decodeFile(path, opts) return Document.open(path, opts):root() end

--- Serialize plain Lua data, or any handle from json.decode / json.edit.
---@param value json.Data|json.edit.Value
---@param opts? json.EncodeOptions
---@return string
function json.encode(value, opts)
	local mt = getmetatable(value)
	if mt == Value then
		return writeCString(lib.yyjson_val_write_opts, handleJson(value --[[@as json.Value]]), opts)
	end
	if mt == EditValue then
		return writeCString(lib.yyjson_mut_val_write_opts, mutNode(value --[[@as json.edit.Value]]), opts)
	end
	return encodeTable(value, opts)
end

json.version = ("%d.%d.%d"):format(
	bit.rshift(lib.yyjson_version(), 16),
	bit.band(bit.rshift(lib.yyjson_version(), 8), 0xFF),
	bit.band(lib.yyjson_version(), 0xFF))

json.Value = Value
json.Document = Document

---@class json.edit
---@field Value json.EditValue
---@field Document json.EditDocument
---@field open fun(path: string, opts?: json.DecodeOptions): json.EditDocument
---@field parse fun(text: string, opts?: json.DecodeOptions): json.EditDocument
json.edit = {
	Document = EditDocument,
	Value = EditValue,
	open = EditDocument.open,
	parse = EditDocument.parse,
}

return json
