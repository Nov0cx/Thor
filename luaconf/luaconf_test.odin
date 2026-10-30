package luaconf

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
eval_ok :: proc(t: ^testing.T, text: string) -> json.Value {
    value, status, message := eval_text(text, "test.lua")
    testing.expectf(t, status == .Ok, "eval failed: %s", message)
    return value
}

@(private = "file")
eval_fails :: proc(t: ^testing.T, text, part: string) {
    _, status, message := eval_text(text, "test.lua")
    testing.expect_value(t, status, Status.Failed)
    testing.expectf(t, strings.contains(message, part), "message %q lacks %q", message, part)
}

@(test)
test_eval_values :: proc(t: ^testing.T) {
    v := eval_ok(t, `
-- a comment
local width = 2 * 2
return {
    tab_width = width,
    ratio = 1.5,
    name = "x\ty",
    on = true,
    list = { "a", "b" },
    nested = { ["key with space"] = 1 },
    empty = {},
}`)
    obj := v.(json.Object)
    testing.expect_value(t, obj["tab_width"].(json.Integer), 4)
    testing.expect_value(t, obj["ratio"].(json.Float), 1.5)
    testing.expect_value(t, obj["name"].(json.String), "x\ty")
    testing.expect_value(t, obj["on"].(json.Boolean), true)
    testing.expect_value(t, len(obj["list"].(json.Array)), 2)
    testing.expect_value(t, obj["nested"].(json.Object)["key with space"].(json.Integer), 1)
    _, empty_is_obj := obj["empty"].(json.Object)
    testing.expect(t, empty_is_obj)
}

@(test)
test_eval_thor_table :: proc(t: ^testing.T) {
    v := eval_ok(t, `return { os = thor.os, arch = thor.arch, unset = thor.env("THOR_SURELY_UNSET_VAR") == nil }`)
    obj := v.(json.Object)
    testing.expect_value(t, obj["os"].(json.String), OS_NAME)
    testing.expect_value(t, obj["unset"].(json.Boolean), true)
}

@(test)
test_eval_sandbox :: proc(t: ^testing.T) {
    v := eval_ok(t, `return { io = io == nil, os = os == nil, load = load == nil, req = require == nil,
        dofile = dofile == nil, pcall = pcall == nil, debug = debug == nil, package = package == nil }`)
    for key, value in v.(json.Object) {
        testing.expectf(t, value.(json.Boolean), "%s is reachable", key)
    }
}

@(test)
test_eval_budget :: proc(t: ^testing.T) {
    eval_fails(t, `while true do end`, "time budget")
}

@(test)
test_eval_memory_cap :: proc(t: ^testing.T) {
    _, status, _ := eval_text(`local s = string.rep("x", 1024 * 1024) local t = {} for i = 1, 200 do t[i] = s .. i end return t`, "test.lua")
    testing.expect_value(t, status, Status.Failed)
}

@(test)
test_eval_bad_shapes :: proc(t: ^testing.T) {
    eval_fails(t, `return 4`, "must return a table")
    eval_fails(t, `return { f = function() end }`, "f is a function")
    eval_fails(t, `return { servers = { { 1, x = 2 } } }`, "servers[1] mixes")
    eval_fails(t, `local t = {} t.t = t return t`, "nested too deeply")
    eval_fails(t, `return {`, "test.lua:1")
    eval_fails(t, `error("boom")`, "boom")
}

@(test)
test_patch_replace_keeps_comments :: proc(t: ^testing.T) {
    src := `-- my settings
return {
    -- width
    tab_width = 4, -- trailing
    font_size = 18,
}
`
    out, err := patch_text(src, {"tab_width"}, json.Integer(8))
    testing.expect_value(t, err, Patch_Error.None)
    testing.expect(t, strings.contains(out, "-- my settings"))
    testing.expect(t, strings.contains(out, "tab_width = 8, -- trailing"))
    testing.expect(t, strings.contains(out, "font_size = 18"))
}

@(test)
test_patch_insert :: proc(t: ^testing.T) {
    out, err := patch_text("return {\n    a = 1\n}\n", {"b"}, json.String("x"))
    testing.expect_value(t, err, Patch_Error.None)
    testing.expect_value(t, out, "return {\n    a = 1,\n    b = \"x\",\n}\n")

    out, err = patch_text(EMPTY_FILE, {"theme"}, json.String("mjolnir"))
    testing.expect_value(t, err, Patch_Error.None)
    testing.expect_value(t, out, "return {\n    theme = \"mjolnir\",\n}\n")

    out, err = patch_text("return {}", {"a"}, json.Boolean(true))
    testing.expect_value(t, err, Patch_Error.None)
    testing.expect_value(t, out, "return {\n    a = true,\n}")

    out, err = patch_text("return { a = 1 }", {"b"}, json.Integer(2))
    testing.expect_value(t, err, Patch_Error.None)
    testing.expect_value(t, out, "return { a = 1, b = 2 }")
}

@(test)
test_patch_nested :: proc(t: ^testing.T) {
    src := "return {\n    language_intelligence = {\n        hover = true,\n    },\n}\n"
    out, err := patch_text(src, {"language_intelligence", "hover"}, json.Boolean(false))
    testing.expect_value(t, err, Patch_Error.None)
    testing.expect(t, strings.contains(out, "hover = false"))

    out, err = patch_text(src, {"language_backends", "clangd", "enabled"}, json.Boolean(false))
    testing.expect_value(t, err, Patch_Error.None)
    v := eval_ok(t, out)
    got := lookup(v, {"language_backends", "clangd", "enabled"})
    testing.expect(t, values_equal(got, json.Boolean(false)))
    testing.expect(t, values_equal(lookup(v, {"language_intelligence", "hover"}), json.Boolean(true)))
}

@(test)
test_patch_bracket_keys_and_code :: proc(t: ^testing.T) {
    src := `local base = 3
return {
    ["tab_width"] = base + 1,
    f = (function() local a, b = 1, 2 return a + b end)(),
    custom = { save = "ctrl+s" },
}`
    out, err := patch_text(src, {"tab_width"}, json.Integer(2))
    testing.expect_value(t, err, Patch_Error.None)
    testing.expect(t, strings.contains(out, `["tab_width"] = 2,`))
    testing.expect(t, strings.contains(out, "local a, b = 1, 2"))

    out, err = patch_text(src, {"custom", "open"}, json.String("ctrl+o"))
    testing.expect_value(t, err, Patch_Error.None)
    testing.expect(t, values_equal(lookup(eval_ok(t, out), {"custom", "open"}), json.String("ctrl+o")))
}

@(test)
test_patch_refuses_computed :: proc(t: ^testing.T) {
    _, err := patch_text("local t = { a = 1 }\nreturn t\n", {"a"}, json.Integer(2))
    testing.expect_value(t, err, Patch_Error.Computed)

    _, err = patch_text("return { nested = make() }", {"nested", "x"}, json.Integer(2))
    testing.expect_value(t, err, Patch_Error.Invalid)

    _, err = patch_text("local n = {} return { nested = n }", {"nested", "x"}, json.Integer(2))
    testing.expect_value(t, err, Patch_Error.Computed)

    _, err = patch_text("return { a = ", {"a"}, json.Integer(2))
    testing.expect_value(t, err, Patch_Error.Invalid)
}

@(test)
test_append :: proc(t: ^testing.T) {
    src := "return {\n    servers = {\n        { id = \"a\" },\n    },\n}\n"
    entry := make(json.Object, 1, context.temp_allocator)
    entry["id"] = json.String("b")
    out, err := append_text(src, {"servers"}, entry)
    testing.expect_value(t, err, Patch_Error.None)
    servers := lookup(eval_ok(t, out), {"servers"}).(json.Array)
    testing.expect_value(t, len(servers), 2)

    out, err = append_text(EMPTY_FILE, {"servers"}, entry)
    testing.expect_value(t, err, Patch_Error.None)
    servers = lookup(eval_ok(t, out), {"servers"}).(json.Array)
    testing.expect_value(t, len(servers), 1)
}

@(test)
test_encode_round_trip :: proc(t: ^testing.T) {
    text := `{"servers": [{"id": "clangd", "command": ["clangd", "--log=error"], "features": {"hover": false},
        "install": {"windows": "winget install \"LLVM\""}, "weight": 1.0, "n": 3}], "end": "for"}`
    value, err := json.parse(transmute([]byte) string(text), allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
    lua_text := encode(value)
    back := eval_ok(t, lua_text)
    testing.expect(t, values_equal(value, back))
    testing.expect(t, strings.contains(lua_text, `["end"] = "for"`))
    testing.expect(t, strings.contains(lua_text, "weight = 1.0"))
}

@(test)
test_convert_json :: proc(t: ^testing.T) {
    dir :: "bin/test/luaconf_convert"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    json_path :: dir + "/settings.json"
    lua_path :: dir + "/settings.lua"
    testing.expect(t, os.write_entire_file(json_path, `{"tab_width": 2, "theme": "jogo"}`) == nil)
    testing.expect(t, convert_json(json_path, lua_path))
    testing.expect(t, !os.exists(json_path))
    testing.expect(t, os.exists(json_path + ".bak"))
    v, status, _ := eval_file(lua_path)
    testing.expect_value(t, status, Status.Ok)
    testing.expect(t, values_equal(lookup(v, {"theme"}), json.String("jogo")))
    _, is_int := lookup(v, {"tab_width"}).(json.Integer)
    testing.expect(t, is_int)

    // An existing Lua file is never written over.
    testing.expect(t, os.write_entire_file(json_path, `{"tab_width": 9}`) == nil)
    testing.expect(t, !convert_json(json_path, lua_path))
    testing.expect(t, os.exists(json_path))
}

@(test)
test_patch_keeps_crlf :: proc(t: ^testing.T) {
    out, err := patch_text("return {\r\n    a = 1,\r\n}\r\n", {"b"}, json.Integer(2))
    testing.expect_value(t, err, Patch_Error.None)
    testing.expect_value(t, out, "return {\r\n    a = 1,\r\n    b = 2,\r\n}\r\n")
}
