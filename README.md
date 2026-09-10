# json

JSON(5) reading, writing and editing for [lde](https://lde.sh), backed by
[yyjson](https://github.com/ibireme/yyjson).

Built to scrape values out of a JSON file fast, and to edit one in place
without giving up formatting correctness.

## Usage

```
lde add json --git https://github.com/lde-org/json
```

## Reading

`json.decode` parses the document and hands back a lazy handle on its root.
Nothing is copied into Lua unless you ask for it, so pulling a couple of fields
out of a large file stays cheap:

```lua
local json = require("json")

local doc = json.decode('{"name":"alice","tags":["a","b"]}')
doc:type()                    -- "object"
doc:get("name"):val()         -- "alice"
doc:get("tags"):get(2):val()  -- "b"
doc:get("missing", 42)        -- 42  (default instead of an error)

for key, value in doc:children() do ... end   -- (key, value) for objects
for i, value in array:children() do ... end   -- (index, value) for arrays
```

`json.decodeFile(path)` does the same without the file passing through Lua at
all, and `json.Document.parse` / `json.Document.open` expose the document itself
(`:encode`, `:stats`, `:free`).

Call `:unpack()` when you want real Lua tables:

```lua
local t = json.decode(src):unpack()   -- strings, numbers, booleans, json.null
```

`:unpack()` builds ordinary Lua tables and attaches nothing to them: object key
order is not preserved, and `json.encode` writes a Lua table's keys in whatever
order `pairs()` gives. Use `json.edit` when order matters.

A handle can also be written back directly, which skips building any Lua table:

```lua
json.encode(doc)              -- re-serializes the parsed tree
json.encode(doc, { indent = 2 })
json.encode({ a = 1 })        -- and plain Lua tables, as usual
```

## Editing

```lua
local doc = json.edit.open("conf.json")   -- or json.edit.parse(text)

local root = doc:root()
root:get("name"):set("bob")               -- update in place
root:get("tags"):append("c")              -- arrays: append/insert/set/remove
root:add("extra", true)                   -- append a pair, duplicates allowed
root:remove("old")

doc:save()                                -- writes back to conf.json, atomically
```

`set` replaces a key where it sits (or appends it when missing); a missing
lookup yields an inert handle that raises when used, so chains read naturally.
`:encode()`, `:toDocument()` and `:unpack()` read the edited result back out.

## API

| | |
|---|---|
| `json.decode(src[, opts])` | lazy `json.Value` from a string |
| `json.decodeFile(path[, opts])` | lazy `json.Value` from a file |
| `json.encode(value[, opts])` | Lua data or any handle to a JSON string |
| `json.Document.parse/open` | the document behind a value |
| `json.edit.parse/open` | editable `json.edit.Document` |
| `json.null` | the JSON null sentinel |

Value handles: `type`, `is`, `size`, `get`, `val`, `children`, `keys`, `values`,
`unpack` — plus `set`, `add`, `append`, `insert`, `remove` on edit handles.

Read options: `{ json5 = false }` for strict JSON.
Write options: `{ indent, escapeUnicode, escapeSlashes, newlineAtEnd, infNan }`.
