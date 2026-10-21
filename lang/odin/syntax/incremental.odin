package odinsyntax

// The changed range between two texts: [start, old_end) of the old text became [start, new_end) of the new one.
Text_Edit_Span :: struct {
    start, old_end, new_end: u32,
}

// The span between the common prefix and the common suffix of `old` and `new`.
text_diff :: proc "contextless" (old, new: string) -> Text_Edit_Span {
    n := min(len(old), len(new))
    start := 0
    for start < n && old[start] == new[start] {
        start += 1
    }
    tail := 0
    for tail < n - start && old[len(old) - 1 - tail] == new[len(new) - 1 - tail] {
        tail += 1
    }
    return {u32(start), u32(len(old) - tail), u32(len(new) - tail)}
}
