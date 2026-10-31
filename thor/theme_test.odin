package thor

import "core:os"
import "core:slice"
import "core:testing"

import ui "../vendor/loom/loom"
import "../theme"
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

// The draft: an edit marks it dirty, Revert and a per-role reset clean it, and a
// generated palette stays dirty until it is saved under a name.
@(test)
test_theme_draft_lifecycle :: proc(t: ^testing.T) {
    thor: Thor
    thor.theme = theme.clone(theme.mjolnir())
    thor_theme_editor_init(&thor)
    defer {
        thor_theme_editor_destroy(&thor)
        theme.destroy(&thor.theme)
        delete(thor.status_message)
    }

    thor_open_theme_editor(&thor)
    testing.expect(t, thor.theme_editor_open, "the window opens")
    testing.expect_value(t, thor.theme_editor.file, DEFAULT_THEME)
    testing.expect(t, !thor_theme_dirty(&thor), "a fresh draft is clean")

    keywords := theme.color_index("keywords")
    thor_theme_set_color(&thor, keywords, ui.Color {1, 2, 3, 255})
    testing.expect(t, thor_theme_dirty(&thor), "an edit marks the draft dirty")
    thor_theme_reset_color(&thor, keywords)
    testing.expect(t, !thor_theme_dirty(&thor), "a per-role reset cleans it")

    thor_theme_set_color(&thor, keywords, ui.Color {1, 2, 3, 255})
    thor_theme_revert(&thor)
    testing.expect(t, !thor_theme_dirty(&thor), "Revert cleans it")
    testing.expect_value(t, thor.theme.keywords_color, theme.mjolnir().keywords_color)

    thor_theme_use_generated(&thor)
    testing.expect(t, thor.theme_editor.generated && thor_theme_dirty(&thor), "a generated draft is dirty")
    thor_theme_revert(&thor)
    testing.expect(t, !thor.theme_editor.generated && !thor_theme_dirty(&thor), "Revert drops the generated draft")
}

// A pasted color may leave out its "#".
@(test)
test_theme_parse_color :: proc(t: ^testing.T) {
    for text in ([]string {"#112233", "112233", "11223344"}) {
        _, ok := thor_theme_parse_color(text)
        testing.expectf(t, ok, "%q parses", text)
    }
    for text in ([]string {"", "#12", "xyzxyz", "##112233"}) {
        _, ok := thor_theme_parse_color(text)
        testing.expectf(t, !ok, "%q does not parse", text)
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
    palette := theme.mjolnir()
    palette.background = {0x01, 0x02, 0x03, 0xFF}
    testing.expect(t, theme.save(palette, path), "the user copy writes")

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

    loaded, ok := theme.load(thor_theme_path(DEFAULT_THEME))
    defer theme.destroy(&loaded)
    testing.expect(t, ok && loaded.background == ui.Color {0x01, 0x02, 0x03, 0xFF}, "the user copy is the one loaded")
}
