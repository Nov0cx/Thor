package setting

import "core:encoding/json"
import "core:testing"

import "../lang"

// Run from the repository root: odin test setting

// Only the two explicit spellings pick a window; everything else — unset, a
// typo, a stale value — must prompt rather than silently choose one.
@(test)
test_parse_open_folder_in :: proc(t: ^testing.T) {
    testing.expect_value(t, parse_open_folder_in("same"), Open_Folder_In.Same)
    testing.expect_value(t, parse_open_folder_in("new"), Open_Folder_In.New)
    testing.expect_value(t, parse_open_folder_in("ask"), Open_Folder_In.Ask)
    testing.expect_value(t, parse_open_folder_in(""), Open_Folder_In.Ask)
    testing.expect_value(t, parse_open_folder_in("Same"), Open_Folder_In.Ask)
    testing.expect_value(t, parse_open_folder_in("window"), Open_Folder_In.Ask)
}

// Every choice must survive a write/read cycle, so a persisted "don't ask again"
// comes back as the same choice.
@(test)
test_open_folder_in_round_trip :: proc(t: ^testing.T) {
    for choice in Open_Folder_In {
        testing.expect_value(t, parse_open_folder_in(open_folder_in_value(choice)), choice)
    }
}

// An absent open_folder_in leaves the default in place: a settings file written
// before this key existed must still load as Ask.
@(test)
test_open_folder_in_defaults_to_ask :: proc(t: ^testing.T) {
    s: Settings
    testing.expect_value(t, open_folder_in(&s), Open_Folder_In.Ask)
}

// Settings with the language gate at its defaults: everything on, as a file that
// never mentions it loads.
@(private = "file")
language_defaults :: proc() -> Settings {
    s: Settings
    s.general.language_enabled = true
    s.general.language_features = lang.FEATURES_ALL
    return s
}

// Layers one settings.json body's language entry onto `s`.
@(private = "file")
apply_language_json :: proc(t: ^testing.T, s: ^Settings, body: string) {
    value, err := json.parse(transmute([]u8) body, allocator = context.temp_allocator)
    if !testing.expectf(t, err == .None, "test JSON did not parse: %v", err) {
        return
    }
    root, ok := value.(json.Object)
    if !testing.expect(t, ok, "test JSON is not an object") {
        return
    }
    read_language(s, root)
}

// The shipped defaults run every feature, so an editor whose config predates the
// setting behaves exactly as before.
@(test)
test_language_defaults_on :: proc(t: ^testing.T) {
    s := load("settings")
    defer destroy(&s)

    testing.expect(t, language_enabled(&s), "language intelligence must default to on")
    testing.expect_value(t, language_features(&s), lang.FEATURES_ALL)
    for kind in lang.Request_Kind {
        testing.expectf(t, language_feature_enabled(&s, kind), "%v must default to on", kind)
    }
}

// The boolean shorthand is the master switch on its own: it turns everything off
// without touching the per-feature gate underneath.
@(test)
test_language_boolean_shorthand :: proc(t: ^testing.T) {
    s := language_defaults()
    apply_language_json(t, &s, `{"language_intelligence": false}`)

    testing.expect(t, !language_enabled(&s), "the shorthand must turn the master switch off")
    testing.expect_value(t, language_features(&s), lang.FEATURES_ALL)
    for kind in lang.Request_Kind {
        testing.expectf(t, !language_feature_enabled(&s, kind), "%v must be off under the master switch", kind)
    }
}

// The object form gates one feature at a time; the ones it does not name keep
// their state, so a workspace file can turn one off without restating the rest.
@(test)
test_language_feature_keys :: proc(t: ^testing.T) {
    s := language_defaults()
    apply_language_json(t, &s, `{"language_intelligence": {"hover": false, "diagnostics": false}}`)

    testing.expect(t, language_enabled(&s), "an object without \"enabled\" leaves the master switch on")
    testing.expect(t, !language_feature_enabled(&s, .Hover), "hover should be off")
    testing.expect(t, !language_feature_enabled(&s, .Diagnostics), "diagnostics should be off")
    testing.expect(t, language_feature_enabled(&s, .Completion), "an unnamed feature should stay on")

    // A second layer (the workspace overlay) turns one back on and leaves the
    // other where the first put it.
    apply_language_json(t, &s, `{"language_intelligence": {"hover": true, "unknown_feature": false}}`)
    testing.expect(t, language_feature_enabled(&s, .Hover), "the overlay should turn hover back on")
    testing.expect(t, !language_feature_enabled(&s, .Diagnostics), "the overlay must not reset an unnamed feature")
}

// "enabled" inside the object is the same master switch as the shorthand.
@(test)
test_language_object_enabled_key :: proc(t: ^testing.T) {
    s := language_defaults()
    apply_language_json(t, &s, `{"language_intelligence": {"enabled": false, "hover": false}}`)

    testing.expect(t, !language_enabled(&s), "\"enabled\" must gate the whole seam")
    testing.expect(t, !(.Hover in language_features(&s)), "the per-feature key must still be read")
    testing.expect(t, .Completion in language_features(&s), "the gate under the master switch is kept")
}
