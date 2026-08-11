package setting

import "core:encoding/json"
import "core:os"
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

// A backend id the config never mentions is enabled by default, whatever ids
// are already in the map.
@(test)
test_backend_enabled_defaults_to_true :: proc(t: ^testing.T) {
    s: Settings
    testing.expect(t, backend_enabled(&s, "clangd"), "an unmentioned backend must default to enabled")
}

// Only the ids present in the object overlay the map; an id from an earlier
// layer that a later one doesn't mention keeps its state — same layering
// read_language already gives the per-feature keys.
@(test)
test_read_backend_toggles_layers :: proc(t: ^testing.T) {
    s: Settings
    s.general.language_backends = make(map[string]Backend_Setting)
    defer {
        for key in s.general.language_backends {
            delete(key)
        }
        delete(s.general.language_backends)
    }

    value, err := json.parse(transmute([]u8) string(`{"language_backends": {"clangd": false, "odin": true}}`), allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
    root, ok := value.(json.Object)
    testing.expect(t, ok)
    read_backend_toggles(&s, root)

    testing.expect(t, !backend_enabled(&s, "clangd"), "clangd was explicitly turned off")
    testing.expect(t, backend_enabled(&s, "odin"))
    testing.expect(t, backend_enabled(&s, "rust-analyzer"), "an id never mentioned must stay enabled")

    // A later layer (the workspace overlay) restating only one id must not
    // reset the other.
    value2, err2 := json.parse(transmute([]u8) string(`{"language_backends": {"odin": false}}`), allocator = context.temp_allocator)
    testing.expect_value(t, err2, json.Error.None)
    root2, ok2 := value2.(json.Object)
    testing.expect(t, ok2)
    read_backend_toggles(&s, root2)

    testing.expect(t, !backend_enabled(&s, "clangd"), "an id the overlay doesn't mention must keep its state")
    testing.expect(t, !backend_enabled(&s, "odin"), "the overlay must still apply the id it does mention")
}

// A toggle persisted with persist_nested_bool must read back through
// backend_enabled exactly as it was written.
@(test)
test_backend_toggle_persist_round_trip :: proc(t: ^testing.T) {
    path := "thor_lang_backends_test.json"
    defer os.remove(path)

    testing.expect(t, persist_nested_bool(path, LANGUAGE_BACKENDS_SETTING, "clangd", false))

    s := load_from_dir_for_test(path)
    defer destroy(&s)
    testing.expect(t, !backend_enabled(&s, "clangd"))
    testing.expect(t, backend_enabled(&s, "rust-analyzer"), "an untouched id must still default to enabled")
}

// Reads settings.json at an arbitrary path the way load_general does, for a
// test that persists to a bare file rather than a dir/settings.json layout.
@(private = "file")
load_from_dir_for_test :: proc(path: string) -> Settings {
    s: Settings
    s.comments = make(map[string]string)
    s.keybinds = make(map[string]Keybind)
    s.general.language_backends = make(map[string]Backend_Setting)
    load_general(&s, path)
    return s
}

// An id absent from the map allows every feature; the object form (mirroring
// language_intelligence's own shape) gates one feature at a time and leaves the
// ones it does not name where they were.
@(test)
test_backend_features_object_form :: proc(t: ^testing.T) {
    s: Settings
    s.general.language_backends = make(map[string]Backend_Setting)
    defer {
        for key in s.general.language_backends {
            delete(key)
        }
        delete(s.general.language_backends)
    }

    testing.expect_value(t, backend_features(&s, "clangd"), lang.FEATURES_ALL)
    testing.expect(t, backend_feature_enabled(&s, "clangd", .Hover), "an unmentioned backend must allow every feature")

    value, err := json.parse(
        transmute([]u8) string(`{"language_backends": {"clangd": {"hover": false, "rename": false}}}`),
        allocator = context.temp_allocator,
    )
    testing.expect_value(t, err, json.Error.None)
    root, ok := value.(json.Object)
    testing.expect(t, ok)
    read_backend_toggles(&s, root)

    testing.expect(t, backend_enabled(&s, "clangd"), "an object without \"enabled\" leaves the backend's own switch on")
    testing.expect(t, !backend_feature_enabled(&s, "clangd", .Hover))
    testing.expect(t, !backend_feature_enabled(&s, "clangd", .Rename))
    testing.expect(t, backend_feature_enabled(&s, "clangd", .Completion), "an unnamed feature must stay on")
    testing.expect(t, backend_feature_enabled(&s, "rust-analyzer", .Hover), "another backend's gate must be untouched")

    // A second layer turns one feature back on and leaves the other where the
    // first layer put it — same overlay behavior read_language gives the
    // top-level entry.
    value2, err2 := json.parse(
        transmute([]u8) string(`{"language_backends": {"clangd": {"hover": true}}}`),
        allocator = context.temp_allocator,
    )
    testing.expect_value(t, err2, json.Error.None)
    root2, ok2 := value2.(json.Object)
    testing.expect(t, ok2)
    read_backend_toggles(&s, root2)

    testing.expect(t, backend_feature_enabled(&s, "clangd", .Hover), "the overlay should turn hover back on")
    testing.expect(t, !backend_feature_enabled(&s, "clangd", .Rename), "the overlay must not reset a feature it doesn't name")
}

// A per-backend feature persisted with persist_double_nested_bool must read
// back through backend_feature_enabled exactly as it was written, without
// disturbing that backend's own enabled switch or another backend's gate.
@(test)
test_backend_feature_persist_round_trip :: proc(t: ^testing.T) {
    path := "thor_lang_backend_features_test.json"
    defer os.remove(path)

    testing.expect(t, persist_double_nested_bool(path, LANGUAGE_BACKENDS_SETTING, "clangd", "hover", false))
    testing.expect(t, persist_double_nested_bool(path, LANGUAGE_BACKENDS_SETTING, "clangd", LANGUAGE_ENABLED_KEY, true))

    s := load_from_dir_for_test(path)
    defer destroy(&s)
    testing.expect(t, backend_enabled(&s, "clangd"))
    testing.expect(t, !backend_feature_enabled(&s, "clangd", .Hover))
    testing.expect(t, backend_feature_enabled(&s, "clangd", .Completion), "an untouched feature must still default to on")
    testing.expect(t, backend_feature_enabled(&s, "rust-analyzer", .Hover), "another backend must be untouched")
}
