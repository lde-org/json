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

## Benchmarks

`benchmarks/` has two suites: `lde run` measures this package against a pure-C
yyjson baseline (compiled from the same yyjson revision), and
`lde run src/compare.lua` measures it against yyjson in C, lua-rapidjson,
lua-cjson, rxi/json.lua, qjson and the pure-Lua predecessor of this package.
Both share one fixture set, so every number is over identical bytes. The C
baseline is best-effort: without a toolchain it is left out of the run.

Overhead against calling yyjson directly from C, on a 33 KB document:

| | ours | C | ratio |
|---|---|---|---|
| decode | 64 µs | 41 µs | 1.57x |
| decode + read a nested field | 68 µs | 41 µs | 1.65x |
| encode a parsed tree | 37 µs | 39 µs | **0.95x** |

On a 39-byte object the same comparison is 220 ns vs 51 ns for decode and
**43 ns vs 47 ns for encode** — the encoder is a single `yyjson_write_opts` call
on both sides, so there is nothing left to lose there.

The parse gap is what the Lua side costs around a native call that C makes
directly. Measured on that 39-byte document:

| step | cost |
|---|---|
| `yyjson_read_opts` + free (native) | 82 ns |
| building the two handles it returns | ~2 ns |
| `:get("name"):val()` | ~75 ns |
| total `json.decode` | 220 ns |

Two things that were worth fixing, both now done: the error and length structs
handed to yyjson are module-level buffers rather than a fresh `ffi.new` per call
(worth ~20 ns a call), and the document no longer retains the source string it
never used. Handle construction turned out to be negligible — LuaJIT allocates
the table and sets the metatable in under 2 ns — so the remaining gap is the
`ffi` call sequence itself plus dispatch on the value methods.

`:unpack()` on the same document costs 800 µs: that is not overhead, that is
where every Lua string and table actually gets built.

Against everything else, on the same document:

| | decode | encode |
|---|---|---|
| yyjson, in C | 39 µs (0.6x) | 37 µs (1.0x) |
| **ours (yyjson through ffi)** | **64 µs** | **37 µs** |
| lua-rapidjson | 364 µs (5.6x) | 218 µs (5.9x) |
| lua-cjson | 486 µs (7.6x) | 625 µs (17x) |
| rxi/json.lua | 1101 µs (17x) | 1335 µs (36x) |
| qjson | 1417 µs (22x) | 282 µs (7.6x) |
| pure-Lua predecessor | 1079 µs (17x) | 601 µs (16x) |

lua-rapidjson is the closest competitor, and it is the useful yardstick: it
wraps a C++ parser the same way this package wraps a C one, so the two are
directly comparable. Ours is 5.6x faster at decoding and 5.9x at encoding here,
which is mostly the parser behind it — yyjson's lazy DOM keeps string data in the
source buffer, while RapidJSON allocates a node per value.

On a 39-byte object the ordering tightens to lua-rapidjson 421 ns, ours 248 ns,
lua-cjson 538 ns, and raw yyjson 52 ns. Reading one field out of a document you
have already decoded in Lua is also slower than a single-pass decoder at that
size, because those have already built the table by then. Our advantage is a
large-document one.
