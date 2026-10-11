-- Build yyjson (0.12.0) into a shared library next to this module, plus a
-- small bridge (shim.c) that exports the mutable-editing functions which are
-- `static inline` in yyjson.h and therefore not present in a plain .so build.

local build = require("lde-build")

local isWindows = jit.os == "Windows"
local isMac     = jit.os == "OSX"
local libName   = isWindows and "yyjson.dll" or (isMac and "libyyjson.dylib" or "libyyjson.so")

local srcDir   = "yyjson"
local tarball  = "yyjson-0.12.0.tar.gz"
local yyjsonC  = srcDir .. "/src/yyjson.c"

-- Fetch and extract yyjson once. Idempotent: if the source is already present
-- (from a previous build) nothing is downloaded. Stale leftovers from older
-- builds (e.g. an unpacked `yyjson-0.12.0` directory) are removed first so a
-- rebuild never trips over them.
if not build:exists(yyjsonC) then
	if isWindows then
		build:sh('if exist "yyjson-0.12.0" rmdir /s /q "yyjson-0.12.0"')
		build:sh('if exist "' .. srcDir .. '" rmdir /s /q "' .. srcDir .. '"')
	else
		build:sh("rm -rf yyjson-0.12.0 " .. srcDir)
	end
	local content = build:fetch("https://github.com/ibireme/yyjson/archive/refs/tags/0.12.0.tar.gz")
	build:write(tarball, content)
	build:extract(tarball, ".")
	build:delete(tarball)
	build:move("yyjson-0.12.0", srcDir)
end

-- Bridge that exposes the inline mutable-value API to ffi (lookup, insert,
-- append, remove, upsert). All `yyjson_mut_*` helpers it calls are static
-- inline in yyjson.h, so they would otherwise be unavailable from Lua.
local shim = [==[
#include "yyjson.h"
#include <string.h>

/* yyjson's mutable API is `static inline` in yyjson.h, so none of it is
   exported from a plain yyjson.c build. This shim is the boundary: everything
   the Lua side needs, with Lua-friendly shapes (NULL results, owner-returning
   mutators) so the ffi layer stays thin. */

/* ---- value construction ---- */

yyjson_mut_val *shim_mut_null(yyjson_mut_doc *doc) { return yyjson_mut_null(doc); }
yyjson_mut_val *shim_mut_bool(yyjson_mut_doc *doc, int value) { return yyjson_mut_bool(doc, value != 0); }
yyjson_mut_val *shim_mut_uint(yyjson_mut_doc *doc, uint64_t value) { return yyjson_mut_uint(doc, value); }
yyjson_mut_val *shim_mut_sint(yyjson_mut_doc *doc, int64_t value) { return yyjson_mut_sint(doc, value); }
yyjson_mut_val *shim_mut_real(yyjson_mut_doc *doc, double value) { return yyjson_mut_real(doc, value); }
yyjson_mut_val *shim_mut_array(yyjson_mut_doc *doc) { return yyjson_mut_arr(doc); }
yyjson_mut_val *shim_mut_object(yyjson_mut_doc *doc) { return yyjson_mut_obj(doc); }

yyjson_mut_val *shim_mut_string(yyjson_mut_doc *doc, const char *str, size_t len) {
    return yyjson_mut_strncpy(doc, str, len);
}

/* ---- arrays ---- */

yyjson_mut_val *shim_mut_arr_get(yyjson_mut_val *arr, size_t idx) {
    return yyjson_mut_arr_get(arr, idx);
}

int shim_mut_arr_append(yyjson_mut_val *arr, yyjson_mut_val *val) {
    return yyjson_mut_arr_append(arr, val);
}

int shim_mut_arr_insert(yyjson_mut_val *arr, yyjson_mut_val *val, size_t idx) {
    return yyjson_mut_arr_insert(arr, val, idx);
}

yyjson_mut_val *shim_mut_arr_remove(yyjson_mut_val *arr, size_t idx) {
    return yyjson_mut_arr_remove(arr, idx);
}

/* ---- objects (keys are copied into the document's string pool) ---- */

yyjson_mut_val *shim_mut_obj_get(yyjson_mut_val *obj, const char *key, size_t len) {
    return yyjson_mut_obj_getn(obj, key, len);
}

/* Upsert: yyjson_mut_obj_put replaces an existing key in place and appends a
   missing one, where yyjson_mut_obj_replace would silently do nothing. */
yyjson_mut_val *shim_mut_obj_set(yyjson_mut_doc *doc, yyjson_mut_val *obj,
                                 const char *key, size_t len, yyjson_mut_val *val) {
    yyjson_mut_val *k = yyjson_mut_strncpy(doc, key, len);
    yyjson_mut_obj_put(obj, k, val);
    return val;
}

/* Append a key/value pair, even when the key already exists. */
yyjson_mut_val *shim_mut_obj_add(yyjson_mut_doc *doc, yyjson_mut_val *obj,
                                 const char *key, size_t len, yyjson_mut_val *val) {
    yyjson_mut_val *k = yyjson_mut_strncpy(doc, key, len);
    yyjson_mut_obj_add(obj, k, val);
    return val;
}

yyjson_mut_val *shim_mut_obj_remove(yyjson_mut_val *obj, const char *key, size_t len) {
    return yyjson_mut_obj_remove_keyn(obj, key, len);
}

/* ---- object iteration ----
   Keys form a circular sibling list whose head is uni.ptr. The caller walks it
   by handing the last visited key back each time, so the cursor lives in Lua
   and this needs no iterator state: seed it with the head (NULL when empty),
   then ask for the value after that key. */

yyjson_mut_val *shim_mut_obj_iter_init(yyjson_mut_val *obj) {
    if (obj == NULL || !yyjson_mut_is_obj(obj) || unsafe_yyjson_get_len(obj) == 0) return NULL;
    return (yyjson_mut_val *)obj->uni.ptr;
}

yyjson_mut_val *shim_mut_obj_iter_next(yyjson_mut_val *key) {
    return key ? key->next : NULL;
}

yyjson_mut_val *shim_mut_obj_iter_next_key(yyjson_mut_val *key) {
    return key ? key->next->next : NULL;
}
]==]
build:write(srcDir .. "/shim.c", shim)

-- Compile yyjson + shim into one shared library, in the build output dir.
-- (A plain cmake build would not include the shim, and its inline helpers are
-- exactly the editing API this package needs.)
local args = {
	"-O2",
	"-shared",
	"-I" .. srcDir .. "/src",
	srcDir .. "/src/yyjson.c",
	srcDir .. "/shim.c",
	"-o",
	libName,
}

if not isWindows then
	table.insert(args, 2, "-fPIC")
end

build:cc(args)

if not isWindows then
	local stripFlags = isMac and "-x" or "--strip-unneeded"
	build:sh('strip ' .. stripFlags .. ' "' .. build.outDir .. '/' .. libName .. '"')
end
