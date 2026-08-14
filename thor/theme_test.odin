package thor

import "core:os"
import "core:slice"
import "core:testing"
import rl "vendor:raylib"

import "../ui"

// The picker's rows are cached: a second open reuses the parsed labels, and the
// two slices stay aligned so select_dialog_open can index files by label.
@(test)
test_theme_choices_are_cached_and_aligned :: proc(t: ^testing.T) {
    thor: Thor
    defer thor_free_theme_choices(&thor)

    labels, files := thor_available_theme_choices(&thor)
    testing.expect(t, len(files) > 0, "assets/themes ships at least one theme")
    testing.expect_value(t, len(labels), len(files))
    for label in labels {
        testing.expect(t, label != "", "every theme reports a display name")
    }

    again_labels, again_files := thor_available_theme_choices(&thor)
    testing.expect(t, raw_data(again_labels) == raw_data(labels), "a second open reuses the cache")
    testing.expect(t, raw_data(again_files) == raw_data(files), "a second open reuses the cache")
}

// The two row-id spaces have to stay apart: one Choice handler tells them from
// each other, and from the plugin and language-backend ids, by prefix alone.
@(test)
test_theme_row_ids_roundtrip :: proc(t: ^testing.T) {
    for entry in ui.THEME_COLORS {
        id := thor_theme_color_id(entry.key)
        key, ok := thor_theme_color_key(id)
        testing.expectf(t, ok && key == entry.key, "%q does not survive its id", entry.key)
        _, is_action := thor_theme_action_name(id)
        testing.expectf(t, !is_action, "%q reads as an action id", id)
    }

    action := thor_theme_action_id("generate")
    name, ok := thor_theme_action_name(action)
    testing.expect(t, ok && name == "generate", "an action id round-trips")
    _, is_color := thor_theme_color_key(action)
    testing.expect(t, !is_color, "an action id does not read as a color")

    for id in ([]string {"theme", "plugin:git", "language_backend:odin"}) {
        _, color_ok := thor_theme_color_key(id)
        _, action_ok := thor_theme_action_name(id)
        testing.expectf(t, !color_ok && !action_ok, "%q is not a theme row", id)
    }
}

// A theme name is free-form text going into a file path, so the slug is the guard
// that keeps it inside user/themes.
@(test)
test_theme_slug :: proc(t: ^testing.T) {
    cases := [?][2]string {
        {"My Theme", "my-theme"},
        {"  Deep   Ocean  ", "deep-ocean"},
        {"Solarized_Dark", "solarized-dark"},
        {"../../evil", "evil"},
        {"a/b\\c", "abc"},
        {"...", ""},
    }
    for pair in cases {
        got := thor_theme_slug(pair[0])
        testing.expectf(t, got == pair[1], "%q gave %q, expected %q", pair[0], got, pair[1])
    }
}

// The user layer shadows the shipped one: the same name resolves to the user file
// and lists once, so a copied theme replaces its original instead of doubling it.
@(test)
test_user_theme_shadows_shipped :: proc(t: ^testing.T) {
    path := thor_user_theme_path(DEFAULT_THEME, context.allocator)
    defer delete(path)
    if os.exists(path) {
        testing.fail_now(t, "a user copy of the default theme is already there")
    }
    defer os.remove(path)

    // theme_mjolnir's name is a literal, unlike theme_load's, so this palette is
    // never destroyed.
    palette := ui.theme_mjolnir()
    palette.background = {0x01, 0x02, 0x03, 0xFF}
    testing.expect(t, ui.theme_save(palette, path), "the user copy writes")

    testing.expect(t, thor_theme_path(DEFAULT_THEME) == path, "the user copy wins the lookup")

    names := thor_available_themes(context.temp_allocator)
    count := 0
    for name in names {
        if name == DEFAULT_THEME {
            count += 1
        }
    }
    testing.expectf(t, count == 1, "the shadowed theme is listed %d times", count)
    testing.expect(t, slice.is_sorted(names), "the merged listing is sorted")

    loaded, ok := ui.theme_load(thor_theme_path(DEFAULT_THEME))
    defer ui.theme_destroy(&loaded)
    testing.expect(t, ok && loaded.background == rl.Color {0x01, 0x02, 0x03, 0xFF}, "the user copy is the one loaded")
}
