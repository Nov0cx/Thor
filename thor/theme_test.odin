package thor

import "core:testing"

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
