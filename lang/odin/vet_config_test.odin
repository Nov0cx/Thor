package odin

import "core:testing"

import odinsema "sema"

// A build flag names a check outside the `-vet` set, with or without the `-vet-` prefix.
@(test)
test_vet_option_flags :: proc(t: ^testing.T) {
    Case :: struct {
        word: string,
        want: odinsema.Vet_Flags,
        ok:   bool,
    }
    cases := [?]Case{
        {"-vet", odinsema.VET_DEFAULT, true},
        {"-vet-style", {.Style}, true},
        {"-vet-unused-procedures", {.Unused_Procedures}, true},
        {"-vet-unused", {.Unused_Variables, .Unused_Imports}, true},
        {"-vet-cast", {.Cast}, true},
        {"tabs", {.Tabs}, true},
        {"semicolon", {.Semicolon}, true},
        {"-vet-bogus", {}, false},
        {"", {}, false},
        {"-o:speed", {}, false},
    }
    for c in cases {
        got, ok := odinsema.vet_option_flags(c.word)
        testing.expectf(t, ok == c.ok && got == c.want, "%q: got %v %v, want %v %v", c.word, got, ok, c.want, c.ok)
    }
}

// `"vet"` in the analyzer config adds checks to the `-vet` set; a diagnostic id set to off still removes one.
@(test)
test_workspace_vet_flags_from_config :: proc(t: ^testing.T) {
    root  := fixture(
        t,
        "vet_config_flags",
        {{".thor/odin-analyzer.lua", `return { vet = { "-vet-style", "unused-procedures", "-vet-bogus", 7 }, diagnostics = { ["vet/cast"] = "off" } }`}},
    )
    plain := fixture(t, "vet_config_plain", {{".thor/odin-analyzer.lua", `return {}`}})
    e     := engine_create()
    defer engine_destroy(e)

    got  := workspace_vet_flags(e, root)
    want := (odinsema.VET_DEFAULT - {.Cast}) + {.Style, .Unused_Procedures}
    testing.expectf(t, got == want, "got %v, want %v", got, want)
    testing.expect_value(t, workspace_vet_flags(e, plain), odinsema.VET_DEFAULT)

    // `"-vet"` alone is the default set.
    bare := fixture(t, "vet_config_bare", {{".thor/odin-analyzer.lua", `return { vet = { "-vet" } }`}})
    testing.expect_value(t, workspace_vet_flags(e, bare), odinsema.VET_DEFAULT)

    // A value that is not a list is dropped.
    bad := fixture(t, "vet_config_bad", {{".thor/odin-analyzer.lua", `return { vet = "style" }`}})
    testing.expect_value(t, workspace_vet_flags(e, bad), odinsema.VET_DEFAULT)
}
