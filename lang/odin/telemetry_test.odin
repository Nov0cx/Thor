package odin

import "core:testing"

import lang ".."

@(test)
test_disagreements_by_line :: proc(t: ^testing.T) {
    compiler := []lang.Diagnostic{
        {path = "app/a.odin", line = 3, col = 2, severity = .Error, message = "both"},
        {path = "app/a.odin", line = 5, col = 1, severity = .Error, message = "compiler only"},
        {path = "app/a.odin", line = 6, col = 1, severity = .Warning, message = "a warning"},
        {path = "app/b.odin", line = 9, col = 1, severity = .Error, message = "other file"},
    }
    native   := []lang.Diagnostic{
        {path = "app/a.odin", line = 3, col = 4, severity = .Error, message = "both"},
        {path = "app/a.odin", line = 7, col = 1, severity = .Error, message = "native only"},
        {path = "app/a.odin", line = 8, col = 1, severity = .Error, message = "a lint", lint = true},
        {path = "app/a.odin", line = 10, col = 1, severity = .Hint, message = "a hint"},
    }
    got      := find_disagreements(native, compiler, "app/a.odin")
    testing.expect_value(t, len(got), 2)
    if len(got) == 2 {
        testing.expect_value(t, got[0].side, Disagree_Side.Compiler_Only)
        testing.expect_value(t, got[0].diag.line, 5)
        testing.expect_value(t, got[1].side, Disagree_Side.Native_Only)
        testing.expect_value(t, got[1].diag.line, 7)
    }
}

@(test)
test_disagreements_path_separators :: proc(t: ^testing.T) {
    compiler := []lang.Diagnostic{{path = "app/a.odin", line = 1, col = 1, severity = .Error, message = "x"}}
    native   := []lang.Diagnostic{{path = "app/a.odin", line = 1, col = 1, severity = .Error, message = "x"}}
    testing.expect_value(t, len(find_disagreements(native, compiler, "app/a.odin")), 0)
    testing.expect_value(t, len(find_disagreements(nil, compiler, "app/a.odin")), 1)
    testing.expect_value(t, len(find_disagreements(nil, compiler, "app/other.odin")), 0)
}

@(test)
test_config_telemetry_and_package_keys :: proc(t: ^testing.T) {
    root := fixture(t, "cfg_telemetry", {{".thor/odin-analyzer.lua", "return { diagnostics_telemetry = true, package_diagnostics = true }"}})
    off  := fixture(t, "cfg_telemetry_off", {{".thor/odin-analyzer.lua", "return {}"}})
    e    := engine_create()
    defer engine_destroy(e)
    testing.expect(t, config_telemetry(e, root))
    testing.expect(t, config_package_diagnostics(e, root))
    testing.expect(t, !config_telemetry(e, off))
    testing.expect(t, !config_package_diagnostics(e, off))
    testing.expect(t, !config_telemetry(e, ""))
}
