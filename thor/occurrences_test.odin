package thor

import "core:strings"
import "core:testing"

import "../editview"
import "../lang"

// A caret inside a use or at either end of it is covered; one between uses is not.
@(test)
test_occurrences_cover :: proc(t: ^testing.T) {
    occurrences := []editview.Occurrence{{start = 4, end = 9}, {start = 20, end = 25, write = true}}
    testing.expect(t, thor_occurrences_cover(occurrences, 4))
    testing.expect(t, thor_occurrences_cover(occurrences, 9))
    testing.expect(t, thor_occurrences_cover(occurrences, 22))
    testing.expect(t, !thor_occurrences_cover(occurrences, 12))
    testing.expect(t, !thor_occurrences_cover(nil, 0))
}

// The result the slot waits for is stored for the file it asked about; a superseded or undispatched one is dropped.
@(test)
test_occurrences_take_their_result :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    defer delete(thor.occurrences)
    defer thor_clear_occurrences(thor)

    thor.occurrence_request_id = 7
    thor.occurrence_ask_path = strings.clone("a.odin")
    highlights := make([dynamic]lang.Document_Highlight, context.temp_allocator)
    append(&highlights, lang.Document_Highlight{start = 1, end = 3, kind = .Write}, lang.Document_Highlight{start = 8, end = 10, kind = .Read})

    stale := lang.Result{id = 6, kind = .Document_Highlight, revision = 2, ok = true, highlights = highlights}
    thor_update_occurrences(thor, &stale)
    testing.expect_value(t, len(thor.occurrences), 0)
    testing.expect_value(t, thor.occurrence_request_id, u64(7))

    undispatched := lang.Result{id = 7, kind = .Document_Highlight, undispatched = true}
    thor_update_occurrences(thor, &undispatched)
    testing.expect_value(t, len(thor.occurrences), 0)
    testing.expect_value(t, thor.occurrence_request_id, u64(0))

    thor.occurrence_request_id = 8
    res := lang.Result{id = 8, kind = .Document_Highlight, revision = 3, ok = true, highlights = highlights}
    thor_update_occurrences(thor, &res)
    testing.expect_value(t, thor.occurrence_request_id, u64(0))
    testing.expect_value(t, thor.occurrence_path, "a.odin")
    testing.expect_value(t, thor.occurrence_revision, u64(3))
    testing.expect_value(t, len(thor.occurrences), 2)
    if len(thor.occurrences) == 2 {
        testing.expect_value(t, thor.occurrences[0], editview.Occurrence{start = 1, end = 3, write = true})
        testing.expect_value(t, thor.occurrences[1], editview.Occurrence{start = 8, end = 10})
    }
}

// Carets on uses and selections of whole uses keep the marks; a partial selection does not.
@(test)
test_occurrences_cover_cursors :: proc(t: ^testing.T) {
    occurrences := []editview.Occurrence{{start = 4, end = 9}, {start = 20, end = 25}}
    testing.expect(t, thor_occurrences_cover_cursors(occurrences, {{anchor = 6, caret = 6}}))
    testing.expect(t, thor_occurrences_cover_cursors(occurrences, {{anchor = 4, caret = 9}, {anchor = 25, caret = 20}}))
    testing.expect(t, !thor_occurrences_cover_cursors(occurrences, {{anchor = 4, caret = 7}}))
    testing.expect(t, !thor_occurrences_cover_cursors(occurrences, {{anchor = 4, caret = 9}, {anchor = 12, caret = 12}}))
    testing.expect(t, !thor_occurrences_cover_cursors(occurrences, nil))
}
