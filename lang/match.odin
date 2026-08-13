// Name matching for the seam's one filtered request kind, Workspace_Symbols.
// A backend uses it to bound what crosses the seam; the editor's picker still
// ranks and re-filters the rows it gets, so this only has to decide membership,
// never order.
package lang

// Whether `name` matches `query` as a case-insensitive subsequence — the same
// shape the command palette's fuzzy filter accepts, minus the scoring, which
// belongs to whoever is drawing the list. An empty query matches everything.
symbol_matches :: proc(query, name: string) -> bool {
    if query == "" {
        return true
    }
    if len(query) > len(name) {
        return false
    }
    q := 0
    for i := 0; i < len(name) && q < len(query); i += 1 {
        if ascii_lower(name[i]) == ascii_lower(query[q]) {
            q += 1
        }
    }
    return q == len(query)
}

@(private)
ascii_lower :: proc(c: u8) -> u8 {
    if c >= 'A' && c <= 'Z' {
        return c + ('a' - 'A')
    }
    return c
}
