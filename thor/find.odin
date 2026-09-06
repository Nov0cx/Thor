// The find/replace bar over the editor. The scan itself is `search`; this side
// keeps the query, the match list and where in it the selection sits, and edits
// through the editor's textedit state so undo works normally.
package thor

import "core:fmt"

import "../editview"
import "../search"
import "../textedit"
import ui "../vendor/loom/loom"

FIND_WIDTH :: f32(520)
FIND_TOP :: f32(90)

Find_Replace :: struct {
    // The pane the bar searches. Borrowed; re-taken on every open.
    editor:         ^editview.Editor,
    find:           [dynamic]u8, // owned; ui.input edits it in place
    replace:        [dynamic]u8, // owned
    matches:        [dynamic]search.Match, // owned
    current:        int,
    // Buffer the offsets in `matches` were scanned from. `set_text` puts the
    // revision back to 0, so the pointer and the length are part of the identity.
    match_state:    ^textedit.State, // borrowed
    match_rev:      u64,
    match_size:     int,
    // Search modifiers. They survive a close, so the next open keeps them.
    options:        search.Options,
    // The pattern does not compile. Reported in place of the match count.
    regex_bad:      bool,
    // Set by an open, consumed by the view: the query field takes the keyboard
    // on the frame it first appears.
    focus_pending:  bool,
    // Pane key the focus goes back to when the bar closes.
    return_focus:   string,
}

thor_find_init :: proc(thor: ^Thor) {
    f := &thor.find
    f.find = make([dynamic]u8)
    f.replace = make([dynamic]u8)
    f.matches = make([dynamic]search.Match)
}

thor_find_destroy :: proc(thor: ^Thor) {
    f := &thor.find
    delete(f.find)
    delete(f.replace)
    delete(f.matches)
}

thor_find_is_open :: proc(thor: ^Thor) -> bool {
    return thor.find_open
}

// Opens over `editor`, seeding the query from its selection when there is one.
thor_open_find :: proc(thor: ^Thor, show_replace: bool) {
    f := &thor.find
    f.editor = thor_active_editor(thor)
    thor.find_replace_mode = show_replace

    if f.editor != nil && f.editor.state != nil {
        cursor := textedit.primary_cursor(f.editor.state)
        lo, hi := textedit.selection_range(cursor)
        if hi > lo {
            clear(&f.find)
            append(&f.find, textedit.text(f.editor.state)[lo:hi])
        }
    }

    find_recompute(f)
    find_select_current(f)
    if !thor.find_open {
        f.return_focus = thor.focus_owner
    }
    f.focus_pending = true
    thor.find_open = true
}

@(private = "file")
find_close :: proc(thor: ^Thor) {
    thor.find_open = false
    if thor.find.return_focus != "" {
        thor.focus_request = thor.find.return_focus
    }
}

// Recomputes match offsets; points `current` at the first match at or after the
// selection's start, so opening on a selected word lands on that word instead of
// skipping to the one after it.
@(private = "file")
find_recompute :: proc(f: ^Find_Replace) {
    clear(&f.matches)
    f.current = 0
    f.regex_bad = false
    state := f.editor != nil ? f.editor.state : nil
    f.match_state = state
    f.match_rev = state != nil ? state.revision : 0
    f.match_size = state != nil ? textedit.length(state) : 0
    if state == nil || len(f.find) == 0 {
        return
    }

    text := textedit.text(state)
    from, _ := textedit.selection_range(textedit.primary_cursor(state))
    if !search.scan(text, string(f.find[:]), f.options, &f.matches) {
        f.regex_bad = true
        return
    }

    for match, index in f.matches {
        if match.start >= from {
            f.current = index
            break
        }
    }
}

// Re-scans when the buffer moved under the offsets: a reload, an undo, a backend
// edit or a tab switch leaves them pointing at other bytes.
@(private = "file")
find_sync :: proc(f: ^Find_Replace) {
    state := f.editor != nil ? f.editor.state : nil
    if state == nil {
        if f.match_state != nil {
            find_recompute(f)
        }
        return
    }
    if f.match_state != state ||
       f.match_rev != state.revision ||
       f.match_size != textedit.length(state) {
        find_recompute(f)
    }
}

@(private = "file")
find_select_current :: proc(f: ^Find_Replace) {
    if f.editor == nil || f.editor.state == nil || len(f.matches) == 0 {
        return
    }
    match := f.matches[f.current]
    textedit.select_range(f.editor.state, match.start, match.end)
    editview.editor_scroll_to_caret(f.editor)
}

@(private = "file")
find_step :: proc(f: ^Find_Replace, delta: int) {
    find_sync(f)
    if len(f.matches) == 0 {
        return
    }
    n := len(f.matches)
    f.current = ((f.current + delta) % n + n) % n
    find_select_current(f)
}

@(private = "file")
find_do_replace :: proc(f: ^Find_Replace) {
    find_sync(f)
    if f.editor == nil || f.editor.state == nil || len(f.matches) == 0 {
        return
    }
    match := f.matches[f.current]
    textedit.select_range(f.editor.state, match.start, match.end)
    textedit.insert_text(f.editor.state, string(f.replace[:]))
    find_recompute(f)
    find_select_current(f)
}

// Replaces every match at once. The ranges are already in hand, so this goes
// through replace_ranges rather than searching a second time: it lands as one
// undo entry, remaps the cursors, and carries a match length of its own — which
// a literal replace_all cannot do.
@(private = "file")
find_do_replace_all :: proc(f: ^Find_Replace) {
    find_sync(f)
    if f.editor == nil || f.editor.state == nil || len(f.matches) == 0 {
        return
    }
    ranges := make([dynamic]textedit.Replace, 0, len(f.matches), context.temp_allocator)
    for match in f.matches {
        append(
            &ranges,
            textedit.Replace{start = match.start, end = match.end, text = string(f.replace[:])},
        )
    }
    // The sync above scanned this revision, so replace_ranges keeps every range.
    textedit.replace_ranges(f.editor.state, ranges[:])
    find_recompute(f)
    editview.editor_scroll_to_caret(f.editor)
}

// ---- the view ---------------------------------------------------------------------

thor_find_view :: proc(thor: ^Thor) {
    if !thor.find_open {
        return
    }
    f := &thor.find
    find_sync(f)

    ui.scope(
        {
            key = "find",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {t = FIND_TOP},
                w = ui.Px(FIND_WIDTH),
                max_w = ui.viewport().x - 40,
                h = ui.FIT,
                dir = .Column,
                gap = {0, 6},
                pad = ui.all(10),
                z = 350,
                bg = thor.theme.second_background,
                radius = ui.rad(8),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 6}, blur = 24, color = thor.theme.contrast},
            },
        },
    )

    find_query_row(thor)
    if thor.find_replace_mode {
        find_replace_row(thor)
    }

    if ui.take_key(.Escape) {
        find_close(thor)
        return
    }
    if ui.take_key(.Enter) || ui.take_key(.Pad_Enter) {
        find_step(f, 1)
    }
    if ui.take_key(.Enter, {.Shift}) {
        find_step(f, -1)
    }
}

@(private = "file")
find_query_row :: proc(thor: ^Thor) {
    f := &thor.find

    ui.scope(
        {
            key = "query-row",
            props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {6, 0}},
        },
    )

    it := ui.input(
        &f.find,
        {
            key = "query",
            props = {
                w = ui.Grow(1),
                bg = thor.theme.background,
                color = thor.theme.foreground,
                radius = ui.rad(4),
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
        "Find",
    )
    if f.focus_pending {
        ui.set_focus(it.id)
        f.focus_pending = false
    }
    if it.changed {
        find_recompute(f)
        find_select_current(f)
    }

    ui.label(
        find_count_label(f),
        {
            key = "count",
            props = {
                w = ui.Px(96),
                text_align = .Center,
                color = f.regex_bad ? thor.theme.error_color : thor.theme.muted_color,
                text_wrap = .None,
            },
        },
    )

    if find_toggle(thor, "case", "Aa", f.options.case_sensitive) {
        f.options.case_sensitive = !f.options.case_sensitive
        find_recompute(f)
        find_select_current(f)
    }
    if find_toggle(thor, "word", "ab", f.options.whole_word) {
        f.options.whole_word = !f.options.whole_word
        find_recompute(f)
        find_select_current(f)
    }
    if find_toggle(thor, "regex", ".*", f.options.use_regex) {
        f.options.use_regex = !f.options.use_regex
        find_recompute(f)
        find_select_current(f)
    }

    if find_icon_button(thor, "prev", "chevron-up") {
        find_step(f, -1)
    }
    if find_icon_button(thor, "next", "chevron-down") {
        find_step(f, 1)
    }
    if find_icon_button(thor, "close", "x") {
        find_close(thor)
    }
}

@(private = "file")
find_replace_row :: proc(thor: ^Thor) {
    f := &thor.find

    ui.scope(
        {
            key = "replace-row",
            props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {6, 0}},
        },
    )
    ui.input(
        &f.replace,
        {
            key = "replace",
            props = {
                w = ui.Grow(1),
                bg = thor.theme.background,
                color = thor.theme.foreground,
                radius = ui.rad(4),
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
        "Replace",
    )
    if find_text_button(thor, "one", "Replace") {
        find_do_replace(f)
    }
    if find_text_button(thor, "all", "All") {
        find_do_replace_all(f)
    }
}

@(private = "file")
find_count_label :: proc(f: ^Find_Replace) -> string {
    if f.regex_bad {
        return "bad pattern"
    }
    if len(f.matches) == 0 {
        return len(f.find) == 0 ? "" : "no results"
    }
    return fmt.tprintf("%d of %d", f.current + 1, len(f.matches))
}

@(private = "file")
find_toggle :: proc(thor: ^Thor, key, label: string, on: bool) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                w = ui.Px(26),
                h = ui.Px(26),
                dir = .Row,
                justify = .Center,
                align = .Center,
                radius = ui.rad(4),
                bg = on ? thor.theme.selection_background : nil,
                cursor = .Pointer,
            },
            hover = {bg = on ? thor.theme.selection_background : thor.theme.buttons},
        },
    )
    ui.label(
        label,
        {
            key = "text",
            props = {
                color = on ? thor.theme.accent_color : thor.theme.muted_color,
                font = thor.font_mono,
                text_wrap = .None,
            },
        },
    )
    return it.clicked
}

@(private = "file")
find_icon_button :: proc(thor: ^Thor, key, icon: string) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                w = ui.Px(26),
                h = ui.Px(26),
                dir = .Row,
                justify = .Center,
                align = .Center,
                radius = ui.rad(4),
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.buttons},
        },
    )
    thor_icon_label(thor, icon, thor.theme.muted_color, 14)
    return it.clicked
}

@(private = "file")
find_text_button :: proc(thor: ^Thor, key, label: string) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                h = ui.Px(26),
                dir = .Row,
                align = .Center,
                pad = ui.xy(10, 0),
                radius = ui.rad(4),
                bg = thor.theme.buttons,
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.active},
        },
    )
    ui.label(label, {key = "text", props = {color = thor.theme.foreground, text_wrap = .None}})
    return it.clicked
}
