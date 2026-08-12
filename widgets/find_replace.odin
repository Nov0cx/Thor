package widgets

import "core:fmt"
import "core:text/regex"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../textedit"
import "../ui"

// One match as a byte range. The length is not len(fr.find): a regular
// expression matches spans of its own size.
@(private = "file")
Fr_Match :: struct {
    start: int,
    end:   int,
}

// Centered find/replace overlay. Shows the current match as a selection and
// edits through the editor's textedit state, so undo works normally.
Find_Replace :: struct {
    using widget: ui.Widget,
    editor:        ^Editor,
    find:          [dynamic]u8,
    replace:       [dynamic]u8,
    // Byte offset of each field's own caret, kept while focus moves between them.
    find_caret:    int,
    replace_caret: int,
    replace_field: bool, // which input has focus: false = find, true = replace
    show_replace:  bool, // replace row + buttons visible
    matches:       [dynamic]Fr_Match,
    current:       int,
    // Search modifiers. They survive a close, so the next open keeps them, and
    // reset when Thor restarts.
    case_sensitive: bool,
    whole_word:     bool,
    use_regex:      bool,
    // The pattern does not compile. Reported in place of the match count.
    regex_bad:      bool,
    return_focus:  ^ui.Widget,
    // Drag state: once moved, the box keeps `position` instead of recentering.
    positioned:    bool,
    position:      rl.Vector2,
    dragging:      bool,
    drag_offset:   rl.Vector2,
    // Layout, computed each frame.
    box:           rl.Rectangle,
    find_rect:     rl.Rectangle,
    replace_rect:  rl.Rectangle,
    btn_next:      rl.Rectangle,
    btn_prev:      rl.Rectangle,
    btn_replace:   rl.Rectangle,
    btn_all:       rl.Rectangle,
    btn_case:      rl.Rectangle,
    btn_word:      rl.Rectangle,
    btn_regex:     rl.Rectangle,
    width:         f32,
    row_height:    f32,
    top_offset:    f32,
    backdrop_color:   rl.Color,
    background_color: rl.Color,
    border_color:     rl.Color,
    input_color:      rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    button_color:     rl.Color,
    accent_color:     rl.Color,
}

find_replace_vtable := ui.Widget_VTable {
    layout = find_replace_layout,
    handle_event = find_replace_handle_event,
    draw = find_replace_draw,
    destroy = find_replace_destroy,
}

find_replace_create :: proc(id: string) -> ^Find_Replace {
    fr := new(Find_Replace)
    ui.widget_init(&fr.widget, id, find_replace_vtable)
    fr.visible = false
    fr.find = make([dynamic]u8)
    fr.replace = make([dynamic]u8)
    fr.matches = make([dynamic]Fr_Match)
    fr.width = 460
    fr.row_height = 34
    fr.top_offset = 90
    fr.backdrop_color = rl.Color {0, 0, 0, 110}
    fr.background_color = rl.Color {24, 26, 31, 250}
    fr.border_color = rl.Color {132, 255, 255, 255}
    fr.input_color = rl.Color {15, 17, 26, 255}
    fr.text_color = rl.Color {238, 255, 255, 255}
    fr.muted_color = rl.Color {120, 128, 160, 255}
    fr.button_color = rl.Color {40, 44, 60, 255}
    fr.accent_color = rl.Color {132, 255, 255, 255}
    return fr
}

find_replace_set_colors :: proc(fr: ^Find_Replace, background, border, input, text, muted, button, accent: rl.Color) -> ^Find_Replace {
    fr.background_color = background
    fr.border_color = border
    fr.input_color = input
    fr.text_color = text
    fr.muted_color = muted
    fr.button_color = button
    fr.accent_color = accent
    return fr
}

find_replace_open :: proc(fr: ^Find_Replace, ctx: ^ui.Context, editor: ^Editor, show_replace: bool) {
    fr.editor = editor
    fr.show_replace = show_replace
    fr.replace_field = false
    fr.visible = true
    fr.positioned = false // recenter each time it opens
    fr.dragging = false

    // Seed the find field from the current selection, if any.
    if editor.state != nil {
        cursor := textedit.primary_cursor(editor.state)
        lo, hi := textedit.selection_range(cursor)
        if hi > lo {
            clear(&fr.find)
            append(&fr.find, ..transmute([]u8) textedit.text(editor.state)[lo:hi])
        }
    }
    fr.find_caret = len(fr.find)
    fr.replace_caret = len(fr.replace)

    find_replace_recompute(fr)
    find_replace_select_current(fr)
    // A repeat chord while already open must not clobber the real target
    // with the box's own widget.
    if ctx.focused != &fr.widget {
        fr.return_focus = ctx.focused
    }
    ctx.focused = &fr.widget
    ui.widget_bring_to_front(&fr.widget)
}

find_replace_close :: proc(fr: ^Find_Replace, ctx: ^ui.Context) {
    fr.visible = false
    if ctx.focused == &fr.widget {
        ctx.focused = fr.return_focus
    }
}

find_replace_is_open :: proc(fr: ^Find_Replace) -> bool {
    return fr.visible
}

@(private = "file")
fr_fold :: #force_inline proc(c: u8, sensitive: bool) -> u8 {
    return !sensitive && c >= 'A' && c <= 'Z' ? c + 32 : c
}

@(private = "file")
fr_is_word_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b >= 0x80
}

// True when [start, end) is not glued to an identifier character on either side.
@(private = "file")
fr_word_bounded :: proc(text: string, start, end: int) -> bool {
    if start > 0 && fr_is_word_byte(text[start - 1]) {
        return false
    }
    if end < len(text) && fr_is_word_byte(text[end]) {
        return false
    }
    return true
}

@(private = "file")
fr_match_at :: proc(text: string, pos: int, query: string, sensitive: bool) -> bool {
    if pos + len(query) > len(text) {
        return false
    }
    for i in 0 ..< len(query) {
        if fr_fold(text[pos + i], sensitive) != fr_fold(query[i], sensitive) {
            return false
        }
    }
    return true
}

// Boyer-Moore-Horspool bad-character table: how far a mismatch at the window's
// last byte lets the search jump ahead, instead of retrying every intervening
// start byte. Absent from the query, a byte carries the full jump of len(query).
// Built over the same folding the compare uses, or the jump could skip a match.
@(private = "file")
fr_skip_table :: proc(query: string, sensitive: bool) -> (table: [256]int) {
    n := len(query)
    for i in 0 ..< 256 {
        table[i] = n
    }
    for i in 0 ..< n - 1 {
        table[fr_fold(query[i], sensitive)] = n - 1 - i
    }
    return table
}

// Recomputes match offsets; points `current` at the first match at/after the
// selection's start, so opening on a selected word lands on that word instead
// of skipping to the one after it.
@(private = "file")
find_replace_recompute :: proc(fr: ^Find_Replace) {
    clear(&fr.matches)
    fr.current = 0
    fr.regex_bad = false
    if fr.editor == nil || fr.editor.state == nil {
        return
    }
    query := string(fr.find[:])
    n := len(query)
    if n == 0 {
        return
    }

    text := textedit.text(fr.editor.state)
    from, _ := textedit.selection_range(textedit.primary_cursor(fr.editor.state))

    if fr.use_regex {
        find_replace_scan_regex(fr, text, query)
    } else {
        find_replace_scan_literal(fr, text, query)
    }

    for match, index in fr.matches {
        if match.start >= from {
            fr.current = index
            break
        }
    }
}

// Collects regular-expression matches over the whole document. A zero-width
// match is dropped: it selects nothing, and replacing over one would splice
// forever. The replacement stays literal in this mode -- no capture references.
@(private = "file")
find_replace_scan_regex :: proc(fr: ^Find_Replace, text, pattern: string) {
    flags: regex.Flags = {.Unicode}
    if !fr.case_sensitive {
        flags += {.Case_Insensitive}
    }
    it, err := regex.create_iterator(text, pattern, flags)
    if err != nil {
        fr.regex_bad = true
        return
    }
    defer regex.destroy(it)

    for {
        capture, _, ok := regex.match_iterator(&it)
        if !ok {
            break
        }
        if len(capture.pos) == 0 {
            break
        }
        start, end := capture.pos[0][0], capture.pos[0][1]
        if end <= start {
            continue
        }
        if fr.whole_word && !fr_word_bounded(text, start, end) {
            continue
        }
        append(&fr.matches, Fr_Match {start, end})
    }
}

// Collects literal matches over the whole document. Re-run once per query change
// rather than per byte: the skip table lets a mismatch jump the window ahead
// instead of retrying every start byte, so a keystroke's rescan stays close to
// O(document length) instead of O(document length x query length).
@(private = "file")
find_replace_scan_literal :: proc(fr: ^Find_Replace, text, query: string) {
    n := len(query)
    skip := fr_skip_table(query, fr.case_sensitive)
    i := 0
    for i + n <= len(text) {
        if fr_match_at(text, i, query, fr.case_sensitive) {
            if !fr.whole_word || fr_word_bounded(text, i, i + n) {
                append(&fr.matches, Fr_Match {i, i + n})
                i += n
                continue
            }
        }
        i += skip[fr_fold(text[i + n - 1], fr.case_sensitive)]
    }
}

@(private = "file")
find_replace_select_current :: proc(fr: ^Find_Replace) {
    if fr.editor == nil || fr.editor.state == nil || len(fr.matches) == 0 {
        return
    }
    match := fr.matches[fr.current]
    textedit.select_range(fr.editor.state, match.start, match.end)
    editor_scroll_to_caret(fr.editor)
}

@(private = "file")
find_replace_step :: proc(fr: ^Find_Replace, delta: int) {
    if len(fr.matches) == 0 {
        return
    }
    n := len(fr.matches)
    fr.current = ((fr.current + delta) % n + n) % n
    find_replace_select_current(fr)
}

@(private = "file")
find_replace_do_replace :: proc(fr: ^Find_Replace) {
    if fr.editor == nil || fr.editor.state == nil || len(fr.matches) == 0 {
        return
    }
    match := fr.matches[fr.current]
    textedit.select_range(fr.editor.state, match.start, match.end)
    textedit.insert_text(fr.editor.state, string(fr.replace[:]))
    find_replace_recompute(fr)
    find_replace_select_current(fr)
}

// Replaces every match at once. The ranges are already in hand, so this goes
// through replace_ranges rather than searching a second time: it lands as one
// undo entry, remaps the cursors, and carries a match length of its own -- which
// a literal replace_all cannot do.
@(private = "file")
find_replace_do_replace_all :: proc(fr: ^Find_Replace) {
    if fr.editor == nil || fr.editor.state == nil || len(fr.matches) == 0 {
        return
    }
    ranges := make([dynamic]textedit.Replace, 0, len(fr.matches), context.temp_allocator)
    for match in fr.matches {
        append(&ranges, textedit.Replace {start = match.start, end = match.end, text = string(fr.replace[:])})
    }
    textedit.replace_ranges(fr.editor.state, ranges[:])
    find_replace_recompute(fr)
    editor_scroll_to_caret(fr.editor)
}

// The focused field's text and its caret.
@(private = "file")
find_replace_active :: proc(fr: ^Find_Replace) -> (buf: ^[dynamic]u8, caret: ^int) {
    if fr.replace_field && fr.show_replace {
        return &fr.replace, &fr.replace_caret
    }
    return &fr.find, &fr.find_caret
}

// Re-runs the search after the find text changed; a no-op for the replace field.
@(private = "file")
find_replace_requery :: proc(fr: ^Find_Replace) {
    if fr.replace_field && fr.show_replace {
        return
    }
    find_replace_requery_now(fr)
}

// Re-runs the search whichever field has focus, for a change to how the query is
// matched rather than to the query itself.
@(private = "file")
find_replace_requery_now :: proc(fr: ^Find_Replace) {
    find_replace_recompute(fr)
    find_replace_select_current(fr)
}

find_replace_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    fr := cast(^Find_Replace) widget
    fr.bounds = bounds

    width := min(fr.width, bounds.width - 80)
    rows := fr.show_replace ? 3 : 2 // find, [replace], buttons
    pad: f32 = 8
    height := pad * 2 + cast(f32) rows * fr.row_height

    if !fr.positioned {
        fr.position = rl.Vector2 {bounds.x + (bounds.width - width) * 0.5, bounds.y + fr.top_offset}
    }
    fr.box = rl.Rectangle {fr.position.x, fr.position.y, width, height}

    inner_x := fr.box.x + pad
    inner_w := fr.box.width - pad * 2
    y := fr.box.y + pad
    fr.find_rect = rl.Rectangle {inner_x, y, inner_w, fr.row_height - 6}
    y += fr.row_height
    if fr.show_replace {
        fr.replace_rect = rl.Rectangle {inner_x, y, inner_w, fr.row_height - 6}
        y += fr.row_height
    }

    // Buttons row.
    bw: f32 = 66
    bh := fr.row_height - 6
    bx := inner_x
    fr.btn_next = rl.Rectangle {bx, y, bw, bh}
    bx += bw + 6
    fr.btn_prev = rl.Rectangle {bx, y, bw, bh}
    bx += bw + 6
    if fr.show_replace {
        fr.btn_replace = rl.Rectangle {bx, y, bw, bh}
        bx += bw + 6
        fr.btn_all = rl.Rectangle {bx, y, bw, bh}
    }

    // Toggles right-aligned on the same row. They cannot go on the find row: the
    // match counter owns its right end.
    tw: f32 = 34
    tx := inner_x + inner_w - tw
    fr.btn_regex = rl.Rectangle {tx, y, tw, bh}
    tx -= tw + 6
    fr.btn_word = rl.Rectangle {tx, y, tw, bh}
    tx -= tw + 6
    fr.btn_case = rl.Rectangle {tx, y, tw, bh}
}

find_replace_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    fr := cast(^Find_Replace) widget
    if !fr.visible {
        return false
    }

    #partial switch event.kind {
    case .Text_Input:
        // Any modifier chord is a command here, never text: the box has no AltGr
        // path of its own, and Alt+C would otherwise toggle and type a `c`.
        if event.ctrl || event.alt {
            return true
        }
        if event.codepoint >= 32 && event.codepoint != 127 {
            buffer, w := utf8.encode_rune(event.codepoint)
            buf, caret := find_replace_active(fr)
            caret^ = clamp(caret^, 0, len(buf))
            inject_at(buf, caret^, ..buffer[:w])
            caret^ += w
            find_replace_requery(fr)
        }
        return true

    case .Key_Press:
        // Alt chords toggle how the query matches, whichever field has focus.
        if event.alt && !event.ctrl {
            #partial switch event.key {
            case .C:
                fr.case_sensitive = !fr.case_sensitive
            case .W:
                fr.whole_word = !fr.whole_word
            case .R:
                fr.use_regex = !fr.use_regex
            case:
                return true
            }
            find_replace_requery_now(fr)
            return true
        }
        buf, caret := find_replace_active(fr)
        caret^ = clamp(caret^, 0, len(buf))
        text := string(buf[:])
        #partial switch event.key {
        case .ESCAPE:
            find_replace_close(fr, ctx)
        case .ENTER, .KP_ENTER:
            find_replace_step(fr, event.shift ? -1 : 1)
        case .TAB:
            if fr.show_replace {
                fr.replace_field = !fr.replace_field
            }
        case .LEFT:
            caret^ = input_prev_rune(text, caret^)
        case .RIGHT:
            caret^ = input_next_rune(text, caret^)
        case .HOME:
            caret^ = 0
        case .END:
            caret^ = len(text)
        case .BACKSPACE:
            if start := input_prev_rune(text, caret^); start < caret^ {
                remove_range(buf, start, caret^)
                caret^ = start
                find_replace_requery(fr)
            }
        case .DELETE:
            if end := input_next_rune(text, caret^); end > caret^ {
                remove_range(buf, caret^, end)
                find_replace_requery(fr)
            }
        }
        return true

    case .Mouse_Down:
        if !rl.CheckCollisionPointRec(event.mouse_position, fr.box) {
            find_replace_close(fr, ctx)
            return true
        }
        if rl.CheckCollisionPointRec(event.mouse_position, fr.find_rect) {
            fr.replace_field = false
            fr.find_caret = input_caret_at_x(string(fr.find[:]), fr.find_rect.x + 8, event.mouse_position.x, 15)
        } else if fr.show_replace && rl.CheckCollisionPointRec(event.mouse_position, fr.replace_rect) {
            fr.replace_field = true
            fr.replace_caret = input_caret_at_x(string(fr.replace[:]), fr.replace_rect.x + 8, event.mouse_position.x, 15)
        } else if rl.CheckCollisionPointRec(event.mouse_position, fr.btn_next) {
            find_replace_step(fr, 1)
        } else if rl.CheckCollisionPointRec(event.mouse_position, fr.btn_prev) {
            find_replace_step(fr, -1)
        } else if fr.show_replace && rl.CheckCollisionPointRec(event.mouse_position, fr.btn_replace) {
            find_replace_do_replace(fr)
        } else if fr.show_replace && rl.CheckCollisionPointRec(event.mouse_position, fr.btn_all) {
            find_replace_do_replace_all(fr)
        } else if rl.CheckCollisionPointRec(event.mouse_position, fr.btn_case) {
            fr.case_sensitive = !fr.case_sensitive
            find_replace_requery_now(fr)
        } else if rl.CheckCollisionPointRec(event.mouse_position, fr.btn_word) {
            fr.whole_word = !fr.whole_word
            find_replace_requery_now(fr)
        } else if rl.CheckCollisionPointRec(event.mouse_position, fr.btn_regex) {
            fr.use_regex = !fr.use_regex
            find_replace_requery_now(fr)
        } else {
            // Empty area of the box: start dragging.
            fr.dragging = true
            fr.drag_offset = rl.Vector2 {event.mouse_position.x - fr.box.x, event.mouse_position.y - fr.box.y}
        }
        return true

    case .Mouse_Move:
        if fr.dragging {
            fr.positioned = true
            fr.position = rl.Vector2 {event.mouse_position.x - fr.drag_offset.x, event.mouse_position.y - fr.drag_offset.y}
        }
        return true

    case .Mouse_Up:
        fr.dragging = false
        return true

    case .Scroll:
        return true
    }
    return true
}

find_replace_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    fr := cast(^Find_Replace) widget
    if !fr.visible {
        return
    }

    rl.DrawRectangleRec(fr.bounds, fr.backdrop_color)
    rl.DrawRectangleRec(fr.box, fr.background_color)
    rl.DrawRectangleLinesEx(fr.box, 1, fr.border_color)

    find_replace_draw_input(fr, fr.find_rect, "Find", string(fr.find[:]), !fr.replace_field, fr.find_caret)

    // Match count on the right of the find row, which is also where a pattern
    // that does not compile reports itself.
    count_text := ""
    switch {
    case fr.regex_bad:
        count_text = "Invalid pattern"
    case len(fr.find) == 0:
    case len(fr.matches) == 0:
        count_text = "No results"
    case:
        count_text = fmt.tprintf("%d / %d", fr.current + 1, len(fr.matches))
    }
    if count_text != "" {
        cw := ui.measure_text(count_text, 15)
        ui.draw_text(count_text, cast(i32) (fr.find_rect.x + fr.find_rect.width) - cw - 8, cast(i32) (fr.find_rect.y + 4), 15, fr.muted_color)
    }

    find_replace_draw_button(fr, fr.btn_next, "Next")
    find_replace_draw_button(fr, fr.btn_prev, "Prev")
    if fr.show_replace {
        find_replace_draw_input(fr, fr.replace_rect, "Replace", string(fr.replace[:]), fr.replace_field, fr.replace_caret)
        find_replace_draw_button(fr, fr.btn_replace, "Replace")
        find_replace_draw_button(fr, fr.btn_all, "All")
    }

    // Aa = match case (alt + c), W = whole word (alt + w), .* = regular
    // expression (alt + r).
    find_replace_draw_button(fr, fr.btn_case, "Aa", fr.case_sensitive)
    find_replace_draw_button(fr, fr.btn_word, "W", fr.whole_word)
    find_replace_draw_button(fr, fr.btn_regex, ".*", fr.use_regex)
}

@(private = "file")
find_replace_draw_input :: proc(fr: ^Find_Replace, rect: rl.Rectangle, label, text: string, focused: bool, caret: int) {
    rl.DrawRectangleRec(rect, fr.input_color)
    if focused {
        rl.DrawRectangleLinesEx(rect, 1, fr.accent_color)
    }
    text_y := cast(i32) (rect.y + 4)
    x := cast(i32) rect.x + 8
    if len(text) == 0 {
        ui.draw_text(label, x, text_y, 15, fr.muted_color)
    } else {
        ui.draw_text(text, x, text_y, 15, fr.text_color)
        if focused {
            prefix := text[:clamp(caret, 0, len(text))]
            caret_x := x + (len(prefix) == 0 ? 0 : ui.measure_text(prefix, 15)) + 1
            rl.DrawRectangle(caret_x, text_y, 2, 16, fr.accent_color)
        }
    }
}

// `active` lights a toggle the way a hover does, so an enabled one reads as
// pressed.
@(private = "file")
find_replace_draw_button :: proc(fr: ^Find_Replace, rect: rl.Rectangle, label: string, active := false) {
    lit := active || rl.CheckCollisionPointRec(rl.GetMousePosition(), rect)
    rl.DrawRectangleRec(rect, lit ? fr.accent_color : fr.button_color)
    color := lit ? fr.input_color : fr.text_color
    lw := ui.measure_text(label, 15)
    ui.draw_text(label, cast(i32) (rect.x + (rect.width - cast(f32) lw) * 0.5), cast(i32) (rect.y + 4), 15, color)
}

find_replace_destroy :: proc(widget: ^ui.Widget) {
    fr := cast(^Find_Replace) widget
    delete(fr.find)
    delete(fr.replace)
    delete(fr.matches)
    free(fr)
}
