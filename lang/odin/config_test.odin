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
    _ = os.remove(cfg_path)
    if cfg_dir, err := filepath.join({root, ".thor"}, context.temp_allocator); err == nil {
        _ = os.remove(cfg_dir)
    }
    _ = os.remove(root)
}

@(test)
test_config_target_override :: proc(t: ^testing.T) {
    root, cfg_path, ok := write_config(
        t,
        "thor_lang_target_ws",
        `return { target = { os = "linux", arch = "arm64" }, defines = { FAST = true, LEVEL = 3, NAME = "thor", ["bad name"] = 1, LIST = { 1 } } }`,
    )
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
    fast, has_fast  := odinsema.target_define(target, "FAST")
    fast_v, fast_ok := fast.(bool)
    testing.expect(t, has_fast && fast_ok && fast_v)
    level, has_level  := odinsema.target_define(target, "LEVEL")
    level_v, level_ok := level.(i64)
    testing.expect(t, has_level && level_ok && level_v == 3)
    name, has_name  := odinsema.target_define(target, "NAME")
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
    host   := odinsema.target_host()
    testing.expect_value(t, target.os, host.os)
    testing.expect_value(t, target.arch, host.arch)
    testing.expect_value(t, len(target.defines), 0)
}

@(test)
test_target_flags :: proc(t: ^testing.T) {
    root, cfg_path, ok := write_config(
        t,
        "thor_lang_flags_ws",
        `return { target = { os = "linux", arch = "arm64" }, defines = { FAST = true, LEVEL = 3, NAME = "thor", ODIN_DEBUG = true } }`,
    )
    if !ok {
        return
    }
    defer remove_config(root, cfg_path)

    e := engine_create()
    defer engine_destroy(e)

    args := make([dynamic]string, context.temp_allocator)
    target_flags(e, root, &args)
    seen_target, seen_fast, seen_level, seen_name: bool
    for a in args {
        seen_target ||= a == "-target:linux_arm64"
        seen_fast ||= a == "-define:FAST=true"
        seen_level ||= a == "-define:LEVEL=3"
        seen_name ||= a == "-define:NAME=thor"
        testing.expect(t, a != "-define:ODIN_DEBUG=true")
    }
    testing.expect(t, seen_target && seen_fast && seen_level && seen_name)

    none := make([dynamic]string, context.temp_allocator)
    target_flags(e, "", &none)
    testing.expect_value(t, len(none), 0)
}

@(test)
test_target_flags_invalid_pair :: proc(t: ^testing.T) {
    root, cfg_path, ok := write_config(t, "thor_lang_flagsbad_ws", `return { target = { os = "darwin", arch = "i386" } }`)
    if !ok {
        return
    }
    defer remove_config(root, cfg_path)

    e := engine_create()
    defer engine_destroy(e)

    args := make([dynamic]string, context.temp_allocator)
    target_flags(e, root, &args)
    testing.expect_value(t, len(args), 0)
    testing.expect_value(t, target_triple(.Windows, .amd64), "windows_amd64")
    testing.expect_value(t, target_triple(.Darwin, .i386), "")
}

// A per-file target overrides the os and arch of the workspace config for that file alone, keeps its
// defines, and an empty triple clears it.
@(test)
test_file_target_override :: proc(t: ^testing.T) {
    root, cfg_path, ok := write_config(t, "thor_lang_filetarget_ws", `return { target = { os = "darwin", arch = "arm64" }, defines = { FAST = true } }`)
    if !ok {
        return
    }
    defer remove_config(root, cfg_path)

    e := engine_create()
    defer engine_destroy(e)

    file, _  := filepath.join({root, "a.odin"}, context.temp_allocator)
    other, _ := filepath.join({root, "b.odin"}, context.temp_allocator)
    testing.expect(t, engine_set_target(e, file, "linux_amd64"))

    target := config_target(e, root, file)
    testing.expect_value(t, target.os, odinsema.Target_OS.Linux)
    testing.expect_value(t, target.arch, odinsema.Target_Arch.amd64)
    _, has_fast := odinsema.target_define(target, "FAST")
    testing.expect(t, has_fast)

    sibling := config_target(e, root, other)
    testing.expect_value(t, sibling.os, odinsema.Target_OS.Darwin)
    testing.expect_value(t, sibling.arch, odinsema.Target_Arch.arm64)

    triple, own := engine_target_label(e, root, file)
    testing.expect_value(t, triple, "linux_amd64")
    testing.expect(t, own)
    triple, own = engine_target_label(e, root, other)
    testing.expect_value(t, triple, "darwin_arm64")
    testing.expect(t, !own)

    testing.expect(t, engine_set_target(e, file, ""))
    cleared := config_target(e, root, file)
    testing.expect_value(t, cleared.os, odinsema.Target_OS.Darwin)

    // A buffer outside any workspace still takes its own target.
    testing.expect(t, engine_set_target(e, other, "windows_i386"))
    loose := config_target(e, "", other)
    testing.expect_value(t, loose.os, odinsema.Target_OS.Windows)
    testing.expect_value(t, loose.arch, odinsema.Target_Arch.i386)
    engine_clear_targets(e)
    host := odinsema.target_host()
    testing.expect_value(t, config_target(e, "", other).arch, host.arch)
}

// A triple the compiler does not know is refused and the old choice stays.
@(test)
test_file_target_invalid :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    testing.expect(t, engine_set_target(e, "x.odin", "LINUX_ARM64"))
    testing.expect(t, !engine_set_target(e, "x.odin", "plan9_amd64"))
    testing.expect(t, !engine_set_target(e, "x.odin", "darwin_i386"))
    testing.expect(t, !engine_set_target(e, "", "linux_amd64"))
    target := config_target(e, "", "x.odin")
    testing.expect_value(t, target.os, odinsema.Target_OS.Linux)
    testing.expect_value(t, target.arch, odinsema.Target_Arch.arm64)

    names := target_names()
    testing.expect(t, len(names) > 10)
    for name in names {
        target_os, arch, ok := target_from_triple(name)
        testing.expect(t, ok)
        testing.expect_value(t, target_triple(target_os, arch), name)
    }
    _, _, bad := target_from_triple("")
    testing.expect(t, !bad)
}

// `odin check` takes the per-file target, and the workspace defines with it.
@(test)
test_target_flags_file_target :: proc(t: ^testing.T) {
    root, cfg_path, ok := write_config(t, "thor_lang_flagsfile_ws", `return { target = { os = "darwin", arch = "arm64" }, defines = { FAST = true } }`)
    if !ok {
        return
    }
    defer remove_config(root, cfg_path)

    e := engine_create()
    defer engine_destroy(e)

    file, _ := filepath.join({root, "a.odin"}, context.temp_allocator)
    testing.expect(t, engine_set_target(e, file, "linux_amd64"))
    args := make([dynamic]string, context.temp_allocator)
    target_flags(e, root, &args, file)
    targets   := 0
    seen_fast := false
    for a in args {
        if len(a) > 8 && a[:8] == "-target:" {
            targets += 1
            testing.expect_value(t, a, "-target:linux_amd64")
        }
        seen_fast ||= a == "-define:FAST=true"
    }
    testing.expect_value(t, targets, 1)
    testing.expect(t, seen_fast)

    loose := make([dynamic]string, context.temp_allocator)
    target_flags(e, "", &loose, file)
    testing.expect_value(t, len(loose), 1)
    if len(loose) == 1 {
        testing.expect_value(t, loose[0], "-target:linux_amd64")
    }
}
