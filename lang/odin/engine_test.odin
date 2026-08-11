package odin

import "core:testing"

import lang ".."

// Run from the repository root: odin test lang/odin

// The settings-driven admin gate: on by default, and handles claims nothing
// once it's turned off — the same "found nothing" contract lang.Manager
// enforces for a declined kind.
@(test)
test_engine_admin_gate :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    testing.expect(t, handles(e, ".odin"), "an enabled engine must claim .odin")
    testing.expect(t, !handles(e, ".txt"))

    engine_set_enabled(e, false)
    testing.expect(t, !handles(e, ".odin"), "a disabled engine must claim nothing")

    engine_set_enabled(e, true)
    testing.expect(t, handles(e, ".odin"), "re-enabling must let the engine claim .odin again")
}

// The settings-driven per-kind gate: every kind is on by default, and turning
// one off answers false for that kind alone.
@(test)
test_engine_feature_gate :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    testing.expect(t, supports(e, ".odin", .Hover))
    testing.expect(t, supports(e, ".odin", .Rename))

    engine_set_features(e, lang.FEATURES_ALL - {.Hover})
    testing.expect(t, !supports(e, ".odin", .Hover), "the declined kind must answer false")
    testing.expect(t, supports(e, ".odin", .Rename), "an untouched kind must still be answered")

    engine_set_features(e, lang.FEATURES_ALL)
    testing.expect(t, supports(e, ".odin", .Hover), "restoring the gate must let the kind through again")
}
