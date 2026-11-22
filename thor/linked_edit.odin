// Linked editing: an edit inside one span the backend links (an open and a close tag) is copied
// to the others.
package thor

import "core:slice"
import "core:strings"

import "../lang"
import "../textedit"

// The linked spans of one file, valid at `revision`.
Linked_Session :: struct {
    active:     bool,
    path:       string, // owned
    revision:   u64,
    ranges:     [dynamic]lang.Text_Range, // owned; ascending by start
    request_id: u64,
    asked_path: string, // owned; the file of the request
    asked_rev:  u64,
    asked_at:   int, // the caret of the request
}

// Runs once a frame before the documents sync: copies an edit inside one span to the others, ends
// a session the caret left, and asks for the spans at a caret that moved.
thor_linked_tick :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    s    := &thor.linked
    if s.active {
        if file == nil || !lang.path_equal(file.path, s.path) {
            thor_linked_end(thor)
        } else {
            thor_linked_follow(thor, file)
        }
    }
    if file == nil || !file.loaded || thor_big_file(file) || len(file.state.cursors) != 1 {
        return
    }
    cursor := textedit.primary_cursor(&file.state)
    if textedit.has_selection(cursor) || (s.active && thor_linked_index(s.ranges[:], cursor.caret) >= 0) {
        return
    }
    if s.request_id != 0 || (s.asked_rev == file.state.revision && s.asked_at == cursor.caret && lang.path_equal(s.asked_path, file.path)) {
        return
    }
    ext := thor_lang_key(thor, file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Linked_Editing_Range) {
        return
    }
    id := lang.manager_request_debounced(
        &thor.lang_manager,
        .Linked_Editing_Range,
        file.path,
        ext,
        textedit.text(&file.state),
        cursor.caret,
        file.state.revision,
        thor.workspace_dir,
    )
    if id == 0 {
        return
    }
    s.request_id = id
    s.asked_rev = file.state.revision
    s.asked_at = cursor.caret
    delete(s.asked_path)
    s.asked_path = strings.clone(file.path)
}

// Starts a session from a landed Linked_Editing_Range request while its text and caret still hold.
thor_on_linked_ranges :: proc(thor: ^Thor, res: ^lang.Result) {
    s := &thor.linked
    if res.id != s.request_id {
        return
    }
    s.request_id = 0
    file := thor_active_open_file(thor)
    if !res.ok || file == nil || !lang.path_equal(file.path, s.asked_path) || file.state.revision != res.revision {
        return
    }
    text   := textedit.text(&file.state)
    ranges := slice.clone(res.ranges[:], context.temp_allocator)
    slice.sort_by(ranges, proc(a, b: lang.Text_Range) -> bool {
        return a.start < b.start
    })
    for r, i in ranges {
        if r.start < 0 || r.end > len(text) || r.end < r.start || (i > 0 && r.start < ranges[i - 1].end) {
            return
        }
        if text[r.start:r.end] != text[ranges[0].start:ranges[0].end] {
            return
        }
    }
    caret := textedit.primary_cursor(&file.state).caret
    if thor_linked_index(ranges, caret) < 0 {
        return
    }
    thor_linked_end(thor)
    s.active = true
    s.path = strings.clone(file.path)
    s.revision = file.state.revision
    append(&s.ranges, ..ranges)
}

// Follows the edits since the session's revision. An edit inside one span is copied to the
// others; an edit outside every span, or a span that is no longer one word, ends the session.
@(private = "file")
thor_linked_follow :: proc(thor: ^Thor, file: ^Open_File) {
    s := &thor.linked
    if file.state.revision != s.revision {
        change, ok := textedit.changes_since(&file.state, s.revision)
        edited     := -1
        if ok {
            for r, i in s.ranges {
                if change.lo >= r.start && change.old_hi <= r.end {
                    edited = i
                    break
                }
            }
        }
        if edited < 0 {
            thor_linked_end(thor)
            return
        }
        delta := change.new_hi - change.old_hi
        for &r, i in s.ranges {
            if i == edited {
                r.end += delta
            } else if r.start >= change.old_hi {
                r.start += delta
                r.end += delta
            }
        }
        text := textedit.text(&file.state)
        word := strings.clone(text[s.ranges[edited].start:s.ranges[edited].end], context.temp_allocator)
        if !thor_linked_word(word) {
            thor_linked_end(thor)
            return
        }
        edits := make([dynamic]textedit.Replace, context.temp_allocator)
        for r, i in s.ranges {
            if i != edited && text[r.start:r.end] != word {
                append(&edits, textedit.Replace{start = r.start, end = r.end, text = word})
            }
        }
        if len(edits) > 0 && textedit.replace_ranges(&file.state, edits[:], all_or_nothing = true) != len(edits) {
            thor_linked_end(thor)
            return
        }
        // Each span now holds `word`; the spans after a copy moved by what it changed.
        shift := 0
        for &r in s.ranges {
            width := r.end - r.start
            r.start += shift
            r.end = r.start + len(word)
            shift += len(word) - width
        }
        s.revision = file.state.revision
    }
    cursor := textedit.primary_cursor(&file.state)
    if len(file.state.cursors) != 1 || thor_linked_index(s.ranges[:], cursor.caret) < 0 {
        thor_linked_end(thor)
    }
}

// Ends the session.
thor_linked_end :: proc(thor: ^Thor) {
    s := &thor.linked
    s.active = false
    delete(s.path)
    s.path = ""
    clear(&s.ranges)
}

// Frees the session state.
thor_linked_destroy :: proc(thor: ^Thor) {
    thor_linked_end(thor)
    delete(thor.linked.ranges)
    delete(thor.linked.asked_path)
}

// Drops the slot of a request that will never land.
thor_recover_linked_slot :: proc(thor: ^Thor) {
    s := &thor.linked
    if s.request_id != 0 && !lang.manager_has_request(&thor.lang_manager, s.request_id) {
        s.request_id = 0
    }
}

// The span that holds `offset`, ends included, or -1.
@(private = "file")
thor_linked_index :: proc(ranges: []lang.Text_Range, offset: int) -> int {
    for r, i in ranges {
        if offset >= r.start && offset <= r.end {
            return i
        }
    }
    return -1
}

// True for text a linked span may hold: no space and no markup bracket.
@(private = "file")
thor_linked_word :: proc(text: string) -> bool {
    for i in 0 ..< len(text) {
        switch text[i] {
        case ' ', '\t', '\n', '\r', '<', '>', '/', '"', '\'', '=':
            return false
        }
    }
    return true
}
