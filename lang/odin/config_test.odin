package odin

import "core:os"
import "core:path/filepath"
import "core:testing"

import odinsema "sema"

@(private = "file")
write_config :: proc(t: ^testing.T, name, json: string) -> (root, cfg_path: string, ok: bool) {
    cwd, err := os.get_working_directory(context.temp_allocator)
    if err != nil {
        testing.fail_now(t, "could not read the working directory")
    }
    root, _ = filepath.join({cwd, name}, context.temp_allocator)
    cfg_dir, _ := filepath.join({root, ".thor"}, context.temp_allocator)
    cfg_path, _ = filepath.join({cfg_dir, "odin-analyzer.lua"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(cfg_dir)
    if werr := os.write_entire_file(cfg_path, transmute([]byte)json); werr != nil {
        testing.fail_now(t, "could not write the test config")
    }
    return root, cfg_path, true
}

@(private = "file")
remove_config :: proc(root, cfg_path: string) {
    os.remove(cfg_path)
    if cfg_dir, err := filepath.join({root, ".thor"}, context.temp_allocator); err == nil {
        os.remove(cfg_dir)
    }
    os.remove(root)
}

@(test)
test_config_target_override :: proc(t: ^testing.T) {
    root, cfg_path, ok := write_config(t, "thor_lang_target_ws", `return { target = { os = "linux", arch = "arm64" }, defines = { FAST = true, LEVEL = 3, NAME = "thor", ["bad name"] = 1, LIST = { 1 } } }`)
    if !ok {
        return
    }
    defer remove_config(root, cfg_path)

    e := engine_create()
    defer engine_destroy(e)

    target := config_target(e, root)
    testing.expect_value(t, target.os, odinsema.Target_OS.Linux)
    testing.expect_value(t, target.arch, odinsema.Target_Arch.arm64)
    testing.expect_value(t, len(target.defines), 3)
    fast, has_fast := odinsema.target_define(target, "FAST")
    fast_v, fast_ok := fast.(bool)
    testing.expect(t, has_fast && fast_ok && fast_v)
    level, has_level := odinsema.target_define(target, "LEVEL")
    level_v, level_ok := level.(i64)
    testing.expect(t, has_level && level_ok && level_v == 3)
    name, has_name := odinsema.target_define(target, "NAME")
    name_v, name_ok := name.(string)
    testing.expect(t, has_name && name_ok && name_v == "thor")
    _, has_bad := odinsema.target_define(target, "bad name")
    testing.expect(t, !has_bad)

    host := odinsema.target_host()
    none := config_target(e, "")
    testing.expect_value(t, none.os, host.os)
    testing.expect_value(t, none.arch, host.arch)
}

@(test)
test_config_target_bad_values :: proc(t: ^testing.T) {
    root, cfg_path, ok := write_config(t, "thor_lang_badtarget_ws", `return { target = { os = "plan9", arch = 64 }, defines = 5 }`)
    if !ok {
        return
    }
    defer remove_config(root, cfg_path)

    e := engine_create()
    defer engine_destroy(e)

    target := config_target(e, root)
    host := odinsema.target_host()
    testing.expect_value(t, target.os, host.os)
    testing.expect_value(t, target.arch, host.arch)
    testing.expect_value(t, len(target.defines), 0)
}
