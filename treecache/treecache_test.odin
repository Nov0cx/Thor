package treecache

import "core:testing"

import ts "../vendor/odin-tree-sitter"

@(test)
test_source_edit_spans :: proc(t: ^testing.T) {
    expect_edit :: proc(t: ^testing.T, label: string, e: ts.Input_Edit, start, old_end, new_end: u32) {
        testing.expectf(
            t,
            e.start_byte == start && e.old_end_byte == old_end && e.new_end_byte == new_end,
            "%s: got %d..%d -> %d, want %d..%d -> %d",
            label,
            e.start_byte,
            e.old_end_byte,
            e.new_end_byte,
            start,
            old_end,
            new_end,
        )
    }

    // An insertion is a zero-width span in the old text, a deletion in the new.
    expect_edit(t, "insert", source_edit("abcdef", "abcXYZdef"), 3, 3, 6)
    expect_edit(t, "delete", source_edit("abcXYZdef", "abcdef"), 3, 6, 3)
    expect_edit(t, "replace", source_edit("abcXYZdef", "abcQdef"), 3, 6, 4)
    expect_edit(t, "append", source_edit("abc", "abcdef"), 3, 3, 6)
    expect_edit(t, "prepend", source_edit("def", "abcdef"), 0, 0, 3)
    // Nothing in common: the span is the whole buffer.
    expect_edit(t, "swap", source_edit("abc", "xyz"), 0, 3, 3)
    // Editing one byte of a multi-byte rune widens the span to the whole rune,
    // so neither end lands mid-rune.
    expect_edit(t, "utf8", source_edit("aéb", "aèb"), 1, 3, 3)
}

// The points tree-sitter shifts nodes by must track the byte spans, so an edit
// on a later line reports that line, not an offset into the first.
@(test)
test_source_edit_points :: proc(t: ^testing.T) {
    e := source_edit("a\nbc\nd", "a\nbXc\nd")
    testing.expectf(t, e.start_point.row == 1 && e.start_point.col == 1, "start: got %v", e.start_point)
    testing.expectf(t, e.old_end_point.row == 1 && e.old_end_point.col == 1, "old end: got %v", e.old_end_point)
    testing.expectf(t, e.new_end_point.row == 1 && e.new_end_point.col == 2, "new end: got %v", e.new_end_point)
}
