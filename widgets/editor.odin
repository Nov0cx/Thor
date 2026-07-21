package widgets

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../setting"
import "../textedit"
import "../ui"

Editor_Save_Proc :: #type proc(data: rawptr)

// Ctrl+Click / go-to-definition request: carries the buffer the click landed in
// and the byte offset under the cursor, so the owner can resolve the symbol.
Goto_Definition_Proc :: #type proc(data: rawptr, state: ^textedit.State, offset: int)

// Hover request, fired once the cursor has dwelt over a spot. Carries the editor
// so an async result can be routed back to the pane it came from, plus the
// buffer and the byte offset under the cursor. The owner resolves a signature
// and calls editor_show_hover on the same editor.
Hover_Proc :: #type proc(data: rawptr, editor: ^Editor, state: ^textedit.State, offset: int)

// Signature-help request, fired automatically as the caret moves inside a call
// (typing `(`/`,`, editing arguments). Carries the buffer and the caret offset;
// the owner resolves the enclosing call and calls editor_show_signature, or
// editor_clear_signature when the caret is no longer in a call.
Signature_Proc :: #type proc(data: rawptr, editor: ^Editor, state: ^textedit.State, offset: int)

// One on-screen row. A wrapped logical line spans several; `first` carries the
// line number. Rebuilt each layout.
Visual_Row :: struct {
    start: int, // byte offset of the row's first character
    end:   int, // byte offset one past its last character (before any newline)
    line:  int, // logical line index the row belongs to
    first: bool, // true for the first visual row of the logical line
}

// A colored byte range for syntax highlighting; ascending and non-overlapping.
// Owned by the file, borrowed by the editor for drawing.
Highlight_Span :: struct {
    start: int,
    end:   int,
    color: rl.Color,
}

// Diagnostic severity, drives the squiggle and gutter-marker color.
Diagnostic_Severity :: enum {
    Error,
    Warning,
}

// A compiler diagnostic mapped onto the buffer: the byte range to underline and
// its severity. `line` (0-based) and `message` are carried for the owner's own
// use (the status bar looks up the caret line's message); the editor draws only
// start/end/severity. Owned by the file, borrowed by the editor.
Diagnostic :: struct {
    start:    int,
    end:      int,
    line:     int,
    severity: Diagnostic_Severity,
    message:  string,
}

Editor :: struct {
    using widget: ui.Widget,
    // Borrowed from the open file; nil when none open. Held outside the widget
    // so undo history and cursors survive tab switches.
    state:              ^textedit.State,
    on_save:            Editor_Save_Proc,
    save_data:          rawptr,
    placeholder:        string,
    // Line-comment marker; empty disables comment toggling. Set per language.
    comment_prefix:     string,
    // Comment-toggle chord (from keybinds.json), defaults to Ctrl+K.
    comment_keybind:    setting.Keybind,
    font_size:          i32,
    padding:            ui.Padding,
    gutter_width:       f32,
    scroll_y:           f32,
    background_color:   rl.Color,
    gutter_color:       rl.Color,
    border_color:       rl.Color,
    focus_border_color: rl.Color,
    text_color:         rl.Color,
    line_number_color:  rl.Color,
    caret_color:        rl.Color,
    selection_color:    rl.Color,
    // Soft-wrap: overflowing lines continue on the next visual row.
    wrap:               bool,
    visual_rows:        [dynamic]Visual_Row,
    // Revision the rows were last built from; draw re-syncs against it after
    // out-of-band edits (palette, menus, global keybinds) made this frame.
    rows_revision:      u64,
    // Syntax highlight spans for the current buffer; borrowed from the owner.
    highlights:         []Highlight_Span,
    // Compiler diagnostics for the current buffer; borrowed from the owner. Each
    // range gets a colored squiggle and its line a gutter marker.
    diagnostics:            []Diagnostic,
    diagnostic_error_color: rl.Color,
    diagnostic_warn_color:  rl.Color,
    // Code folding. `foldable` maps a fold's start line (0-based) to its end line
    // (both from the owner's syntax analysis, refreshed each edit); `folded` is
    // the subset the user has collapsed. Folding a region hides start+1..end.
    foldable:           map[int]int,
    folded:             map[int]bool,
    // Word-drag: after a double-click the selection extends by whole words;
    // word_lo/word_hi bound that word so drags in either direction keep it.
    select_by_word:     bool,
    word_lo:            int,
    word_hi:            int,
    // A Ctrl+Click (go-to-definition) is in progress; the drag that a physical
    // click emits must not turn into a selection.
    goto_click:         bool,
    // Right-click opens a context menu supplied by the owner.
    on_context_menu:    Context_Menu_Proc,
    context_menu_data:  rawptr,
    // Ctrl+Click resolves the symbol under the cursor via the owner.
    on_goto_definition:   Goto_Definition_Proc,
    goto_definition_data: rawptr,
    // Hover: a mouse-dwell request to the owner and the popup its result fills.
    on_hover:            Hover_Proc,
    hover_data:          rawptr,
    // Signature help: an auto-trigger request to the owner as the caret moves in
    // a call. The owner fills the popup below via editor_show_signature.
    on_signature:        Signature_Proc,
    signature_data:      rawptr,
    // Dwell tracking: the spot the cursor settled on and when. hover_probe_offset
    // is the byte offset a request was fired for (-1 = none), so a still cursor
    // fires exactly once until it moves again.
    hover_probe_pos:     rl.Vector2,
    hover_probe_time:    f64,
    hover_probe_offset:  int,
    // Shown popup: text and the byte range it describes, set by editor_show_hover
    // when a result lands. text is an owned clone.
    hover_active:        bool,
    hover_text:          string,
    hover_start:         int,
    hover_end:           int,
    // Signature-help popup: the enclosing call's signature, shown above the caret
    // on explicit request (not a mouse dwell) and dismissed on Escape, a caret
    // jump, or when focus leaves the pane. Owned text clone.
    signature_active:    bool,
    signature_text:      string,
    signature_anchor:    int,
    // recenter (Ctrl+Shift+J): repeated presses cycle the caret line
    // center/top/bottom. Phase resets when the caret moves.
    recenter_phase:     int,
    recenter_caret:     int,
    // Buffer-word autocompletion popup, shown while typing a word with matches
    // elsewhere. Items are owned clones.
    completion_active:   bool,
    completion_items:    [dynamic]string,
    completion_selected: int,
    completion_prefix:   int, // byte length of the already-typed prefix
}

editor_set_on_context_menu :: proc(editor: ^Editor, on_context_menu: Context_Menu_Proc, data: rawptr) {
    editor.on_context_menu = on_context_menu
    editor.context_menu_data = data
}

editor_set_on_goto_definition :: proc(editor: ^Editor, on_goto_definition: Goto_Definition_Proc, data: rawptr) {
    editor.on_goto_definition = on_goto_definition
    editor.goto_definition_data = data
}

editor_set_on_hover :: proc(editor: ^Editor, on_hover: Hover_Proc, data: rawptr) {
    editor.on_hover = on_hover
    editor.hover_data = data
}

editor_set_on_signature :: proc(editor: ^Editor, on_signature: Signature_Proc, data: rawptr) {
    editor.on_signature = on_signature
    editor.signature_data = data
}

// Asks the owner to (re)resolve signature help at the caret. Fired on the
// characters that open or advance a call and, once a popup is up, on every edit
// or horizontal move so the active argument tracks the caret. A no-op without an
// owner or buffer.
editor_request_signature :: proc(editor: ^Editor) {
    if editor.on_signature == nil || editor.state == nil {
        return
    }
    off := textedit.primary_cursor(editor.state).caret
    editor.on_signature(editor.signature_data, editor, editor.state, off)
}

// Shows the hover popup with `text` describing bytes [start, end). Ignored when
// the cursor has since moved (no request is pending), so a late result can't pop
// up after the mouse left the symbol. Clones `text`.
editor_show_hover :: proc(editor: ^Editor, text: string, start, end: int) {
    if editor.hover_probe_offset < 0 || text == "" {
        return
    }
    delete(editor.hover_text)
    editor.hover_text = strings.clone(text)
    editor.hover_start = start
    editor.hover_end = end
    editor.hover_active = true
}

// Hides the popup and frees its text.
editor_clear_hover :: proc(editor: ^Editor) {
    if !editor.hover_active && editor.hover_text == "" {
        return
    }
    delete(editor.hover_text)
    editor.hover_text = ""
    editor.hover_active = false
}

// Shows the signature-help popup with `text` anchored above byte `anchor` (the
// caret). Unlike hover it is an explicit request, so no mouse-dwell gate applies.
// Clones `text`.
editor_show_signature :: proc(editor: ^Editor, text: string, anchor: int) {
    if text == "" {
        return
    }
    delete(editor.signature_text)
    editor.signature_text = strings.clone(text)
    editor.signature_anchor = anchor
    editor.signature_active = true
}

// Hides the signature popup and frees its text.
editor_clear_signature :: proc(editor: ^Editor) {
    if !editor.signature_active && editor.signature_text == "" {
        return
    }
    delete(editor.signature_text)
    editor.signature_text = ""
    editor.signature_active = false
}

editor_vtable := ui.Widget_VTable {
    layout = editor_layout,
    handle_event = editor_handle_event,
    draw = editor_draw,
    destroy = editor_destroy,
}

editor_create :: proc(id: string) -> ^Editor {
    editor := new(Editor)
    ui.widget_init(&editor.widget, id, editor_vtable)
    editor.state = nil
    editor.placeholder = "No file open"
    editor.comment_prefix = "//"
    editor.comment_keybind = setting.Keybind {key = .K, ctrl = true}
    editor.font_size = 18
    editor.padding = ui.padding_xy(14, 12)
    editor.gutter_width = 58
    editor.background_color = rl.Color {15, 17, 26, 255}
    editor.gutter_color = rl.Color {24, 26, 31, 255}
    editor.border_color = rl.Color {31, 34, 51, 255}
    editor.focus_border_color = rl.Color {132, 255, 255, 255}
    editor.text_color = rl.Color {238, 255, 255, 255}
    editor.line_number_color = rl.Color {113, 124, 180, 255}
    editor.caret_color = rl.Color {132, 255, 255, 255}
    editor.selection_color = rl.Color {132, 255, 255, 50}
    editor.diagnostic_error_color = rl.Color {255, 83, 112, 255}
    editor.diagnostic_warn_color = rl.Color {230, 192, 92, 255}
    editor.wrap = true
    editor.visual_rows = make([dynamic]Visual_Row)
    editor.recenter_caret = -1
    editor.hover_probe_offset = -1
    editor.completion_items = make([dynamic]string)
    editor.foldable = make(map[int]int)
    editor.folded = make(map[int]bool)
    editor.min_size = rl.Vector2 {0, 280}
    return editor
}

editor_set_colors :: proc(editor: ^Editor, text_color, line_number_color, background_color, gutter_color, border_color, focus_border_color, caret_color: rl.Color) -> ^Editor {
    editor.text_color = text_color
    editor.line_number_color = line_number_color
    editor.background_color = background_color
    editor.gutter_color = gutter_color
    editor.border_color = border_color
    editor.focus_border_color = focus_border_color
    editor.caret_color = caret_color
    editor.selection_color = rl.Color {caret_color.r, caret_color.g, caret_color.b, 50}
    return editor
}

editor_set_on_save :: proc(editor: ^Editor, on_save: Editor_Save_Proc, data: rawptr) {
    editor.on_save = on_save
    editor.save_data = data
}

editor_set_comment_prefix :: proc(editor: ^Editor, prefix: string) {
    editor.comment_prefix = prefix
}

editor_set_state :: proc(editor: ^Editor, state: ^textedit.State) {
    editor.state = state
    editor.scroll_y = 0
    editor.highlights = nil
    editor.recenter_caret = -1
    // Rows were built from the previous buffer; drop them so layout/draw rebuild
    // against the new one. A bare revision check can miss the swap when the two
    // buffers happen to share a revision number.
    clear(&editor.visual_rows)
    // Fold regions belong to the previous buffer; drop them (the owner pushes the
    // new file's regions via editor_set_folds right after) and its collapsed set.
    clear(&editor.foldable)
    clear(&editor.folded)
    editor_dismiss_completion(editor)
    editor_clear_hover(editor)
    editor.hover_probe_offset = -1
    editor_clamp_scroll(editor)
}

editor_set_highlights :: proc(editor: ^Editor, highlights: []Highlight_Span) {
    editor.highlights = highlights
}

// Replaces the diagnostics drawn for the current buffer (borrowed, not copied).
// The owner clears them by passing nil once the buffer is edited past the
// revision they were computed from, so squiggles never linger at stale offsets.
editor_set_diagnostics :: proc(editor: ^Editor, diagnostics: []Diagnostic) {
    editor.diagnostics = diagnostics
}

editor_set_diagnostic_colors :: proc(editor: ^Editor, error_color, warn_color: rl.Color) {
    editor.diagnostic_error_color = error_color
    editor.diagnostic_warn_color = warn_color
}

// A foldable line range, in 0-based logical lines: `start_line` stays visible,
// start_line+1 .. end_line hide when collapsed. Matches plugin.Fold_Range so the
// host can hand these over without the widget depending on the syntax layer.
Fold_Range :: struct {
    start_line: int,
    end_line:   int,
}

// Replaces the set of regions that *can* be folded (recomputed by the owner on
// every edit). The user's collapsed set survives: a still-present region keeps
// its folded state, one that vanished simply stops folding until it returns.
editor_set_folds :: proc(editor: ^Editor, folds: []Fold_Range) {
    clear(&editor.foldable)
    for f in folds {
        if f.end_line <= f.start_line {
            continue
        }
        // Nodes can share a start line (a decl and its block); keep the widest.
        if end, has := editor.foldable[f.start_line]; !has || f.end_line > end {
            editor.foldable[f.start_line] = f.end_line
        }
    }
}

// End line of the fold starting at `line` when it is currently collapsed, or -1.
@(private = "file")
editor_folded_end :: proc(editor: ^Editor, line: int) -> int {
    if !editor.folded[line] {
        return -1
    }
    if end, ok := editor.foldable[line]; ok {
        return end
    }
    return -1
}

// True when `line` is inside a collapsed region (hidden). A line is hidden when
// some collapsed fold covers it below its start; nesting needs no special case.
@(private = "file")
editor_line_hidden :: proc(editor: ^Editor, line: int) -> bool {
    for start in editor.folded {
        if end, ok := editor.foldable[start]; ok && line > start && line <= end {
            return true
        }
    }
    return false
}

// The visible line a caret on `line` should snap to: `line` itself when shown,
// otherwise the start of the outermost collapsed region hiding it (that start is
// always visible — a smaller-starting fold would cover it too and win here).
@(private = "file")
editor_visible_line :: proc(editor: ^Editor, line: int) -> int {
    best := line
    covered := false
    for start in editor.folded {
        if end, ok := editor.foldable[start]; ok && line > start && line <= end {
            if !covered || start < best {
                best = start
                covered = true
            }
        }
    }
    return best
}

// Pulls every caret out of a line hidden by a collapse onto the fold's visible
// start line, so a fold never strands the caret out of view.
@(private = "file")
editor_carets_out_of_folds :: proc(editor: ^Editor) {
    text := textedit.text(editor.state)
    moved := false
    for &cursor in editor.state.cursors {
        line := textedit.line_index(text, cursor.caret)
        vis := editor_visible_line(editor, line)
        if vis != line {
            cursor.caret = textedit.line_start_of_index(text, vis)
            cursor.anchor = cursor.caret
            moved = true
        }
    }
    if moved {
        textedit.normalize(editor.state)
    }
}

// Toggles the innermost foldable region containing the primary caret. On the
// start line of a region this folds/unfolds it; inside one, folds the enclosing.
editor_toggle_fold :: proc(editor: ^Editor) {
    if editor.state == nil {
        return
    }
    text := textedit.text(editor.state)
    caret_line := textedit.line_index(text, textedit.primary_cursor(editor.state).caret)
    best := -1
    for start, end in editor.foldable {
        if start <= caret_line && caret_line <= end && start > best {
            best = start
        }
    }
    if best < 0 {
        return
    }
    if editor.folded[best] {
        delete_key(&editor.folded, best)
    } else {
        editor.folded[best] = true
        editor_carets_out_of_folds(editor)
    }
    editor_rebuild_visual_rows(editor)
    editor_scroll_to_caret(editor)
}

// Collapses every foldable region.
editor_fold_all :: proc(editor: ^Editor) {
    if editor.state == nil {
        return
    }
    for start in editor.foldable {
        editor.folded[start] = true
    }
    editor_carets_out_of_folds(editor)
    editor_rebuild_visual_rows(editor)
    editor_scroll_to_caret(editor)
}

// Expands every collapsed region.
editor_unfold_all :: proc(editor: ^Editor) {
    if editor.state == nil || len(editor.folded) == 0 {
        return
    }
    clear(&editor.folded)
    editor_rebuild_visual_rows(editor)
    editor_scroll_to_caret(editor)
}

// Toggles the fold whose start is the logical line at `line`, if any (a gutter
// chevron click). Unlike editor_toggle_fold it acts only on that exact line.
@(private = "file")
editor_toggle_fold_line :: proc(editor: ^Editor, line: int) {
    if _, ok := editor.foldable[line]; !ok {
        return
    }
    if editor.folded[line] {
        delete_key(&editor.folded, line)
    } else {
        editor.folded[line] = true
        editor_carets_out_of_folds(editor)
    }
    editor_rebuild_visual_rows(editor)
    editor_clamp_scroll(editor)
}

editor_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    editor := cast(^Editor) widget
    editor.bounds = bounds
    editor_update_gutter(editor)
    editor_rebuild_visual_rows(editor)
    editor_clamp_scroll(editor)
}

// Space between the pane border and the line numbers, and between the numbers
// and the text column. Kept apart so the numbers clear the border on the left.
GUTTER_PAD_LEFT :: 14
GUTTER_PAD_RIGHT :: 12

// Width of the fold-chevron column on the gutter's inner edge, reserved only
// when the buffer has foldable regions (so plain text keeps a tight gutter).
@(private = "file")
editor_fold_col_width :: proc(editor: ^Editor) -> f32 {
    if len(editor.foldable) == 0 {
        return 0
    }
    return cast(f32) editor.font_size
}

// Sizes the gutter to fit the widest line number plus the fold column.
@(private = "file")
editor_update_gutter :: proc(editor: ^Editor) {
    if editor.state == nil {
        return
    }
    line_count := textedit.line_count(textedit.text(editor.state))
    digits := 1
    for n := line_count; n >= 10; n /= 10 {
        digits += 1
    }
    char_width := cast(f32) ui.measure_text("0", editor.font_size)
    editor.gutter_width = GUTTER_PAD_LEFT + char_width * cast(f32) max(digits, 2) + GUTTER_PAD_RIGHT +
        editor_fold_col_width(editor)
}

// Width available for text (inside the gutter, padding and scrollbar).
@(private = "file")
editor_text_width :: proc(editor: ^Editor) -> f32 {
    return editor.bounds.width - editor.gutter_width - editor.padding.left - editor.padding.right - 10
}

// Rebuilds the visual-row list from the buffer. Wrapping uses the monospace
// advance, so this stays a cheap rune walk (no per-line shaping).
editor_rebuild_visual_rows :: proc(editor: ^Editor) {
    clear(&editor.visual_rows)
    if editor.state == nil {
        return
    }
    editor.rows_revision = editor.state.revision

    text := textedit.text(editor.state)
    cols := max(int)
    if editor.wrap {
        char_width := ui.measure_text("0", editor.font_size)
        if char_width > 0 {
            cols = max(1, cast(int) (editor_text_width(editor) / cast(f32) char_width))
        }
    }

    line_start := 0
    line_index := 0
    hidden_until := -1 // lines <= this are collapsed under a fold above; skip them
    for {
        line_end := textedit.line_end(text, line_start)
        if line_index > hidden_until {
            editor_wrap_line(editor, text, line_start, line_end, cols, line_index)
            // A collapsed fold starting here hides everything down to its end.
            if end := editor_folded_end(editor, line_index); end > hidden_until {
                hidden_until = end
            }
        }
        line_index += 1
        if line_end >= len(text) {
            break
        }
        line_start = line_end + 1
    }
}

// Appends the visual rows for one logical line, breaking at the last fitting
// space (falling back to a hard character break).
@(private = "file")
editor_wrap_line :: proc(editor: ^Editor, text: string, line_start, line_end, cols, line_index: int) {
    if line_start == line_end {
        append(&editor.visual_rows, Visual_Row {line_start, line_end, line_index, true})
        return
    }

    seg_start := line_start
    col := 0
    last_break := -1 // byte offset just after the most recent space in this segment
    first := true
    i := line_start
    for i < line_end {
        r, w := utf8.decode_rune_in_string(text[i:])
        if col >= cols {
            brk := last_break > seg_start ? last_break : i
            append(&editor.visual_rows, Visual_Row {seg_start, brk, line_index, first})
            first = false
            seg_start = brk
            col = 0
            last_break = -1
            i = brk
            continue
        }
        col += 1
        i += w
        if r == ' ' {
            last_break = i
        }
    }
    append(&editor.visual_rows, Visual_Row {seg_start, line_end, line_index, first})
}

// Index of the earliest visual row that owns byte offset `pos`; 0 when empty.
@(private = "file")
editor_visual_row_index :: proc(editor: ^Editor, pos: int) -> int {
    for row, index in editor.visual_rows {
        if pos >= row.start && pos <= row.end {
            return index
        }
    }
    return max(0, len(editor.visual_rows) - 1)
}

// Byte offset of the rune at column `col` within [start, end].
@(private = "file")
editor_byte_at_col :: proc(text: string, start, end, col: int) -> int {
    pos := start
    n := 0
    for pos < end && n < col {
        _, w := utf8.decode_rune_in_string(text[pos:])
        pos += w
        n += 1
    }
    return pos
}

editor_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    editor := cast(^Editor) widget
    if editor.state == nil {
        return false
    }

    #partial switch event.kind {
    case .Mouse_Down:
        if event.mouse_button == .RIGHT {
            if editor.on_context_menu != nil {
                editor.on_context_menu(editor.context_menu_data, event.mouse_position)
            }
            return true
        }
        if event.mouse_button != .LEFT {
            return false
        }
        // A click in the fold column toggles that line's fold instead of moving
        // the caret.
        if fold_col := editor_fold_col_width(editor); fold_col > 0 &&
           event.mouse_position.x >= editor.bounds.x + editor.gutter_width - fold_col &&
           event.mouse_position.x < editor.bounds.x + editor.gutter_width {
            if pos, ok := editor_pos_at(editor, event.mouse_position); ok {
                editor_toggle_fold_line(editor, textedit.line_index(textedit.text(editor.state), pos))
            }
            return true
        }
        // Double-click selects the word under the cursor and arms word-drag.
        if event.click_count == 2 {
            if pos, ok := editor_pos_at(editor, event.mouse_position); ok {
                lo, hi, found := textedit.word_range_at(textedit.text(editor.state), pos)
                if found {
                    textedit.select_range(editor.state, lo, hi)
                    editor.select_by_word = true
                    editor.word_lo = lo
                    editor.word_hi = hi
                    return true
                }
            }
            editor_place_caret_at(editor, event.mouse_position)
            return true
        }
        editor.select_by_word = false
        editor.goto_click = false
        // Ctrl-click resolves the symbol under the cursor (go to definition); the
        // caret moves there first so the owner reads the right offset and a miss
        // leaves the cursor placed. goto_click suppresses the drag a physical
        // click emits, so it can't smear into a selection.
        if event.ctrl && editor.on_goto_definition != nil {
            if pos, ok := editor_pos_at(editor, event.mouse_position); ok {
                editor_place_caret_at(editor, event.mouse_position)
                editor.goto_click = true
                editor.on_goto_definition(editor.goto_definition_data, editor.state, pos)
                return true
            }
        }
        // Shift-click extends the selection; a plain click starts a new one.
        if event.shift {
            editor_select_to(editor, event.mouse_position)
        } else {
            editor_place_caret_at(editor, event.mouse_position)
        }
        return true
    case .Mouse_Move:
        // Only dispatched here while the button is held (drag), so extend. A
        // Ctrl+Click goto is not a drag-select, so leave its caret alone.
        if editor.goto_click {
            return true
        }
        if editor.select_by_word {
            editor_word_select_to(editor, event.mouse_position)
        } else {
            editor_select_to(editor, event.mouse_position)
        }
        return true
    case .Mouse_Hover:
        editor_handle_hover(editor, event.mouse_position)
        return true
    case .Scroll:
        // Scroll events carry no modifier state; poll ctrl for zooming.
        if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) {
            editor_zoom(editor, event.wheel_delta > 0 ? 1 : -1)
            return true
        }
        editor.scroll_y -= event.wheel_delta * cast(f32) ui.text_line_height(editor.font_size) * 2
        editor_clamp_scroll(editor)
        return true
    case .Text_Input:
        // Skip Ctrl chords (AltGr is normalized to no modifiers upstream).
        if event.ctrl && !event.alt {
            return false
        }
        if event.codepoint >= 32 && event.codepoint != 127 {
            editor_type_rune(editor, event.codepoint)
            // Refresh the popup while typing a word; any other character dismisses it.
            if editor_is_word_rune(event.codepoint) {
                editor_update_completion(editor)
            } else {
                editor_dismiss_completion(editor)
            }
            // Open signature help on `(`/`,`, or refresh the active argument of an
            // already-shown popup as the argument text is typed.
            if event.codepoint == '(' || event.codepoint == ',' || editor.signature_active {
                editor_request_signature(editor)
            }
            editor_scroll_to_caret(editor)
            return true
        }
    case .Key_Press:
        return editor_handle_key(editor, event)
    case .Mouse_Up, .Click, .None:
    }

    return false
}

// Inserts a typed character, auto-pairing brackets and quotes.
editor_type_rune :: proc(editor: ^Editor, r: rune) {
    state := editor.state
    // `{` at the end of a line opens a three-line block; elsewhere a plain pair.
    if r == '{' && textedit.brace_block_applies(state) {
        textedit.insert_brace_block(state)
    } else if close, ok := textedit.auto_close_for(r); ok {
        textedit.insert_pair(state, r, close)
    } else if textedit.is_close_bracket(r) {
        textedit.insert_or_step(state, r)
    } else if textedit.is_quote(r) {
        textedit.insert_quote(state, r)
    } else {
        buffer, width := utf8.encode_rune(r)
        textedit.insert_text(state, string(buffer[:width]))
    }
}

editor_handle_key :: proc(editor: ^Editor, event: ^ui.Event) -> bool {
    state := editor.state
    ctrl_only := event.ctrl && !event.alt
    alt_only := event.alt && !event.ctrl

    // A caret jump or Escape dismisses the signature popup; typing arguments
    // (Text_Input, not Key_Press) and Left/Right between them leave it up.
    if editor.signature_active {
        #partial switch event.key {
        case .ESCAPE, .ENTER, .KP_ENTER, .UP, .DOWN, .PAGE_UP, .PAGE_DOWN:
            editor_clear_signature(editor)
        }
    }

    // While the popup is up it owns the plain navigation and accept keys. A
    // modifier chord closes it and runs normally; Backspace/Delete refresh it.
    if editor.completion_active {
        if event.ctrl || event.alt {
            editor_dismiss_completion(editor)
        } else {
            #partial switch event.key {
            case .UP:
                n := len(editor.completion_items)
                editor.completion_selected = (editor.completion_selected - 1 + n) % n
                return true
            case .DOWN:
                n := len(editor.completion_items)
                editor.completion_selected = (editor.completion_selected + 1) % n
                return true
            case .TAB:
                editor_accept_completion(editor)
                return true
            case .ENTER, .KP_ENTER:
                // Shift+Enter accepts the suggestion; a plain Enter dismisses the
                // popup and inserts a newline as usual (handled below).
                if event.shift {
                    editor_accept_completion(editor)
                    return true
                }
                editor_dismiss_completion(editor)
            case .ESCAPE:
                editor_dismiss_completion(editor)
                return true
            case .LEFT, .RIGHT, .HOME, .END, .PAGE_UP, .PAGE_DOWN:
                editor_dismiss_completion(editor) // then handled below
            case .BACKSPACE, .DELETE:
                // refreshed after the edit in the cases below
            case:
            }
        }
    }

    // alt+number: relative line down, alt+shift+number: relative line up.
    if alt_only {
        if digit, is_digit := editor_key_digit(event.key); is_digit {
            textedit.move_vertical(state, event.shift ? -digit : digit, false)
            editor_scroll_to_caret(editor)
            return true
        }
    }

    // The comment-toggle chord is configurable, so match it here rather than
    // as a fixed case in the switch below.
    if editor.comment_prefix != "" &&
       setting.keybind_matches(editor.comment_keybind, event.key, event.ctrl, event.shift, event.alt) {
        textedit.toggle_comment(state, editor.comment_prefix)
        editor_scroll_to_caret(editor)
        return true
    }

    #partial switch event.key {
    case .BACKSPACE:
        if ctrl_only {
            textedit.delete_word_backward(state)
            editor_dismiss_completion(editor)
        } else {
            textedit.delete_backward(state)
            editor_update_completion(editor)
        }
        if editor.signature_active {
            editor_request_signature(editor)
        }
        editor_scroll_to_caret(editor)
        return true
    case .DELETE:
        if ctrl_only {
            textedit.delete_word_forward(state)
        } else {
            textedit.delete_forward(state)
        }
        editor_dismiss_completion(editor)
        if editor.signature_active {
            editor_request_signature(editor)
        }
        editor_scroll_to_caret(editor)
        return true
    case .ENTER, .KP_ENTER:
        if ctrl_only {
            if event.shift {
                textedit.insert_line_above(state)
            } else {
                textedit.insert_line_below(state)
            }
        } else {
            textedit.insert_newline(state)
        }
        editor_scroll_to_caret(editor)
        return true
    case .TAB:
        if event.shift {
            textedit.outdent_lines(state)
        } else if textedit.has_any_selection(state) {
            textedit.indent_lines(state)
        } else {
            textedit.insert_soft_tab(state)
        }
        editor_scroll_to_caret(editor)
        return true
    case .ESCAPE:
        textedit.clear_selections(state)
        return true
    case .LEFT:
        if ctrl_only {
            textedit.move_word(state, -1, event.shift)
        } else if alt_only {
            textedit.move_line_start(state, event.shift)
        } else {
            textedit.move_horizontal(state, -1, event.shift)
        }
        if editor.signature_active {
            editor_request_signature(editor)
        }
        editor_scroll_to_caret(editor)
        return true
    case .RIGHT:
        if ctrl_only {
            textedit.move_word(state, 1, event.shift)
        } else if alt_only {
            textedit.move_line_end(state, event.shift)
        } else {
            textedit.move_horizontal(state, 1, event.shift)
        }
        if editor.signature_active {
            editor_request_signature(editor)
        }
        editor_scroll_to_caret(editor)
        return true
    case .UP:
        if event.ctrl && event.alt {
            textedit.add_cursor_vertical(state, -1)
        } else if ctrl_only {
            textedit.move_document_start(state, event.shift)
        } else if alt_only {
            if event.shift {
                textedit.duplicate_lines(state, -1)
            } else {
                textedit.move_lines(state, -1)
            }
        } else {
            editor_move_visual(editor, -1, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .DOWN:
        if event.ctrl && event.alt {
            textedit.add_cursor_vertical(state, 1)
        } else if ctrl_only {
            textedit.move_document_end(state, event.shift)
        } else if alt_only {
            if event.shift {
                textedit.duplicate_lines(state, 1)
            } else {
                textedit.move_lines(state, 1)
            }
        } else {
            editor_move_visual(editor, 1, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .PAGE_UP:
        editor_move_visual(editor, -8, event.shift)
        editor_scroll_to_caret(editor)
        return true
    case .PAGE_DOWN:
        editor_move_visual(editor, 8, event.shift)
        editor_scroll_to_caret(editor)
        return true
    case .HOME:
        if ctrl_only {
            textedit.move_document_start(state, event.shift)
        } else {
            textedit.move_line_start(state, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .END:
        if ctrl_only {
            textedit.move_document_end(state, event.shift)
        } else {
            textedit.move_line_end(state, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .A:
        if ctrl_only {
            textedit.select_all(state)
            return true
        }
    case .Z:
        if ctrl_only {
            if event.shift {
                textedit.redo(state)
            } else {
                textedit.undo(state)
            }
            editor_scroll_to_caret(editor)
            return true
        }
    case .Y:
        if ctrl_only {
            textedit.redo(state)
            editor_scroll_to_caret(editor)
            return true
        }
    case .S:
        if ctrl_only && editor.on_save != nil {
            editor.on_save(editor.save_data)
            return true
        }
    case .C:
        if ctrl_only {
            editor_copy(editor)
            return true
        } else if alt_only {
            textedit.transform_case(state, .Title)
            editor_scroll_to_caret(editor)
            return true
        }
    case .U:
        if alt_only {
            textedit.transform_case(state, .Upper)
            editor_scroll_to_caret(editor)
            return true
        }
    case .X:
        if ctrl_only {
            editor_cut(editor)
            editor_scroll_to_caret(editor)
            return true
        }
    case .V:
        if ctrl_only {
            editor_paste(editor)
            editor_scroll_to_caret(editor)
            return true
        }
    case .D:
        if ctrl_only {
            textedit.select_word_or_next(state)
            editor_scroll_to_caret(editor)
            return true
        }
    case .L:
        if ctrl_only {
            textedit.select_line(state)
            editor_scroll_to_caret(editor)
            return true
        } else if alt_only {
            textedit.transform_case(state, .Lower)
            editor_scroll_to_caret(editor)
            return true
        }
    case .J:
        // ctrl+j joins the line below; ctrl+shift+j recenters the view.
        if ctrl_only {
            if event.shift {
                editor_recenter(editor)
            } else {
                textedit.join_lines(state)
                editor_scroll_to_caret(editor)
            }
            return true
        }
    case .K:
        // ctrl+shift+k deletes the line; ctrl+k is the comment toggle above.
        if ctrl_only && event.shift {
            textedit.delete_lines(state)
            editor_scroll_to_caret(editor)
            return true
        }
    case .P:
        // ctrl+p jumps to the matching/enclosing bracket; ctrl+shift+p selects
        // between them, excluding the brackets.
        if ctrl_only {
            if event.shift {
                textedit.select_between_brackets(state)
            } else {
                textedit.move_to_matching_bracket(state, false)
            }
            editor_scroll_to_caret(editor)
            return true
        }
    case .BACKSLASH:
        // Physical key right of the home row: \ on US layouts, # on QWERTZ.
        if ctrl_only && event.shift {
            textedit.move_to_matching_bracket(state, true)
            editor_scroll_to_caret(editor)
            return true
        }
    case .KP_ADD:
        if ctrl_only {
            editor_zoom(editor, 1)
            return true
        }
    case .KP_SUBTRACT:
        if ctrl_only {
            editor_zoom(editor, -1)
            return true
        }
    case:
    }

    return false
}

editor_zoom :: proc(editor: ^Editor, delta: i32) {
    editor_set_font_size(editor, editor.font_size + delta)
}

editor_set_font_size :: proc(editor: ^Editor, size: i32) {
    editor.font_size = clamp(size, 10, 32)
    editor_clamp_scroll(editor)
}

editor_toggle_wrap :: proc(editor: ^Editor) {
    editor.wrap = !editor.wrap
    editor_rebuild_visual_rows(editor)
    editor_clamp_scroll(editor)
}

editor_copy :: proc(editor: ^Editor) {
    payload, _ := textedit.copy_payload(editor.state, context.temp_allocator)
    if payload != "" {
        rl.SetClipboardText(strings.clone_to_cstring(payload, context.temp_allocator))
    }
}

editor_cut :: proc(editor: ^Editor) {
    payload, had_selection := textedit.copy_payload(editor.state, context.temp_allocator)
    if payload == "" {
        return
    }
    rl.SetClipboardText(strings.clone_to_cstring(payload, context.temp_allocator))
    if !had_selection {
        textedit.select_line(editor.state)
    }
    textedit.delete_backward(editor.state)
}

editor_paste :: proc(editor: ^Editor) {
    clip := rl.GetClipboardText()
    if clip == nil {
        return
    }
    // The buffer stores \n only; Windows clipboard text arrives as \r\n.
    normalized, _ := strings.replace_all(string(clip), "\r\n", "\n", context.temp_allocator)
    normalized, _ = strings.replace_all(normalized, "\r", "\n", context.temp_allocator)
    if normalized != "" {
        textedit.insert_text(editor.state, normalized)
    }
}

// Scrolls the caret line to center; repeated calls without the caret moving
// cycle center -> top -> bottom.
editor_recenter :: proc(editor: ^Editor) {
    if editor.state == nil {
        return
    }
    editor_rebuild_visual_rows(editor)
    caret := textedit.primary_cursor(editor.state).caret
    if caret != editor.recenter_caret {
        editor.recenter_phase = 0
        editor.recenter_caret = caret
    } else {
        editor.recenter_phase = (editor.recenter_phase + 1) % 3
    }

    line_height := cast(f32) ui.text_line_height(editor.font_size)
    view_height := editor.bounds.height - editor.padding.top - editor.padding.bottom
    caret_top := cast(f32) editor_visual_row_index(editor, caret) * line_height
    switch editor.recenter_phase {
    case 0: editor.scroll_y = caret_top - (view_height - line_height) * 0.5
    case 1: editor.scroll_y = caret_top
    case 2: editor.scroll_y = caret_top - (view_height - line_height)
    }
    editor_clamp_scroll(editor)
}

COMPLETION_MIN_PREFIX :: 2
COMPLETION_MAX_ITEMS :: 50
COMPLETION_MAX_ROWS :: 8

@(private = "file")
editor_is_word_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b >= 0x80
}

@(private = "file")
editor_is_word_rune :: proc(r: rune) -> bool {
    return r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r >= 0x80
}

@(private = "file")
editor_dismiss_completion :: proc(editor: ^Editor) {
    if !editor.completion_active && len(editor.completion_items) == 0 {
        return
    }
    editor.completion_active = false
    for item in editor.completion_items {
        delete(item)
    }
    clear(&editor.completion_items)
    editor.completion_selected = 0
    editor.completion_prefix = 0
}

// Rebuilds the candidate list: distinct words elsewhere in the buffer sharing
// the typed prefix. Single collapsed cursor only; empty results dismiss the popup.
@(private = "file")
editor_update_completion :: proc(editor: ^Editor) {
    if len(editor.state.cursors) != 1 || textedit.has_any_selection(editor.state) {
        editor_dismiss_completion(editor)
        return
    }

    txt := textedit.text(editor.state)
    caret := textedit.primary_cursor(editor.state).caret
    start := caret
    for start > 0 && editor_is_word_byte(txt[start - 1]) {
        start -= 1
    }
    prefix := txt[start:caret]
    // Only complete at the end of a word and once enough has been typed.
    if len(prefix) < COMPLETION_MIN_PREFIX || (caret < len(txt) && editor_is_word_byte(txt[caret])) {
        editor_dismiss_completion(editor)
        return
    }

    for item in editor.completion_items {
        delete(item)
    }
    clear(&editor.completion_items)

    i := 0
    for i < len(txt) {
        if !editor_is_word_byte(txt[i]) {
            i += 1
            continue
        }
        word_start := i
        for i < len(txt) && editor_is_word_byte(txt[i]) {
            i += 1
        }
        if word_start == start {
            continue // the word currently being typed
        }
        word := txt[word_start:i]
        if len(word) <= len(prefix) || !strings.has_prefix(word, prefix) {
            continue
        }
        seen := false
        for existing in editor.completion_items {
            if existing == word {
                seen = true
                break
            }
        }
        if seen {
            continue
        }
        append(&editor.completion_items, strings.clone(word))
        if len(editor.completion_items) >= COMPLETION_MAX_ITEMS {
            break
        }
    }

    if len(editor.completion_items) == 0 {
        editor_dismiss_completion(editor)
        return
    }
    editor.completion_active = true
    editor.completion_prefix = len(prefix)
    editor.completion_selected = 0
}

// Inserts the remainder of the selected candidate beyond the typed prefix.
@(private = "file")
editor_accept_completion :: proc(editor: ^Editor) {
    if !editor.completion_active || len(editor.completion_items) == 0 {
        return
    }
    word := editor.completion_items[editor.completion_selected]
    if len(word) > editor.completion_prefix {
        suffix := strings.clone(word[editor.completion_prefix:], context.temp_allocator)
        textedit.insert_text(editor.state, suffix)
    }
    editor_dismiss_completion(editor)
    editor_scroll_to_caret(editor)
}

editor_key_digit :: proc(key: rl.KeyboardKey) -> (int, bool) {
    #partial switch key {
    case .ZERO, .KP_0: return 0, true
    case .ONE, .KP_1: return 1, true
    case .TWO, .KP_2: return 2, true
    case .THREE, .KP_3: return 3, true
    case .FOUR, .KP_4: return 4, true
    case .FIVE, .KP_5: return 5, true
    case .SIX, .KP_6: return 6, true
    case .SEVEN, .KP_7: return 7, true
    case .EIGHT, .KP_8: return 8, true
    case .NINE, .KP_9: return 9, true
    }
    return 0, false
}

editor_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    editor := cast(^Editor) widget

    rl.DrawRectangleRec(editor.bounds, editor.background_color)

    if editor.state == nil {
        text_width := ui.measure_text(editor.placeholder, editor.font_size)
        text_x := cast(i32) (editor.bounds.x + (editor.bounds.width - cast(f32) text_width) * 0.5)
        text_y := cast(i32) (editor.bounds.y + (editor.bounds.height - cast(f32) editor.font_size) * 0.5)
        ui.draw_text(editor.placeholder, text_x, text_y, editor.font_size, editor.line_number_color)
        return
    }

    // An out-of-band edit this frame can leave the layout-time rows pointing
    // past a now-shorter buffer; re-sync before a row extent is used as an index.
    // Empty rows with a live state means the pane was shown after this frame's
    // layout (e.g. the split just toggled on), so build them before drawing.
    if editor.state.revision != editor.rows_revision || len(editor.visual_rows) == 0 {
        editor_rebuild_visual_rows(editor)
        editor_clamp_scroll(editor)
    }

    gutter_rect := rl.Rectangle {
        x = editor.bounds.x,
        y = editor.bounds.y,
        width = editor.gutter_width,
        height = editor.bounds.height,
    }
    rl.DrawRectangleRec(gutter_rect, editor.gutter_color)

    border_color := editor.border_color
    if ctx.focused == widget {
        border_color = editor.focus_border_color
    }
    rl.DrawRectangleLinesEx(editor.bounds, 1, border_color)

    text := textedit.text(editor.state)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    inner_top := editor.bounds.y + editor.padding.top
    inner_bottom := editor.bounds.y + editor.bounds.height - editor.padding.bottom
    text_x := cast(i32) (editor.bounds.x + editor.gutter_width + editor.padding.left)

    ui.begin_clip(editor.bounds)

    caret_line := textedit.line_index(text, textedit.primary_cursor(editor.state).caret)

    // Fold chevrons live in a column on the gutter's inner edge. Like VS Code,
    // an expanded region's chevron only shows while the gutter is hovered; a
    // collapsed region always shows one, so a fold is never invisible.
    fold_col := editor_fold_col_width(editor)
    fold_col_x := editor.bounds.x + editor.gutter_width - fold_col
    gutter_hovered := ctx.hot == widget && fold_col > 0 &&
        rl.GetMousePosition().x >= editor.bounds.x &&
        rl.GetMousePosition().x < editor.bounds.x + editor.gutter_width

    // Monotonic cursor into the sorted highlight spans as rows advance.
    hl := 0
    for row, index in editor.visual_rows {
        row_y := inner_top - editor.scroll_y + cast(f32) index * line_height
        for hl < len(editor.highlights) && editor.highlights[hl].end <= row.start {
            hl += 1
        }
        if row_y + line_height < inner_top {
            continue
        }
        if row_y > inner_bottom {
            break
        }

        editor_draw_line_selections(editor, text, row.start, row.end, cast(f32) text_x, row_y, line_height)

        // Line number is drawn once per logical line, on its first visual row.
        if row.first {
            displayed_number := row.line == caret_line ? row.line + 1 : abs(row.line - caret_line)
            line_number_text := fmt.tprintf("%d", displayed_number)
            // Right-align the number within the gutter, before the fold column,
            // leaving GUTTER_PAD_RIGHT so the digits clear both edges.
            number_width := ui.measure_text(line_number_text, editor.font_size)
            number_x := cast(i32) (fold_col_x - GUTTER_PAD_RIGHT) - number_width
            ui.draw_text(line_number_text, number_x, cast(i32) row_y, editor.font_size, editor.line_number_color)

            // Fold chevron for a foldable line: down when expanded, right when
            // collapsed. Expanded ones appear only on gutter hover.
            if _, ok := editor.foldable[row.line]; ok {
                is_folded := editor.folded[row.line]
                if is_folded || gutter_hovered {
                    editor_draw_fold_chevron(editor, fold_col_x, fold_col, row_y, line_height, is_folded)
                }
            }

            // Gutter dot for a diagnostic on this line: red for an error, amber
            // for a warning (an error on the line wins).
            if sev, has := editor_line_diagnostic(editor, row.line); has {
                color := sev == .Error ? editor.diagnostic_error_color : editor.diagnostic_warn_color
                cx := editor.bounds.x + GUTTER_PAD_RIGHT + 3
                cy := row_y + line_height * 0.5
                rl.DrawCircleV(rl.Vector2 {cx, cy}, 3, color)
            }
        }
        editor_draw_row_text(editor, text, row, hl, text_x, cast(i32) row_y)
        editor_draw_row_swatches(editor, text, row, text_x, cast(i32) row_y)
        editor_draw_row_diagnostics(editor, text, row, text_x, row_y)

        // Collapsed marker: on the last visual row of a folded start line, an
        // ellipsis pill after the text stands in for the hidden body.
        if editor.folded[row.line] {
            if _, ok := editor.foldable[row.line]; ok {
                last_row := index + 1 >= len(editor.visual_rows) ||
                    editor.visual_rows[index + 1].line != row.line
                if last_row {
                    editor_draw_fold_marker(editor, text, row, text_x, row_y)
                }
            }
        }
    }

    if ctx.focused == widget {
        for cursor in editor.state.cursors {
            row_index := editor_visual_row_index(editor, cursor.caret)
            row := editor.visual_rows[row_index]
            caret_y := inner_top - editor.scroll_y + cast(f32) row_index * line_height
            if caret_y + line_height < inner_top || caret_y > inner_bottom {
                continue
            }
            caret_x := cast(f32) text_x + cast(f32) ui.measure_text(text[row.start:cursor.caret], editor.font_size) +
                editor_swatch_offset(editor, text[row.start:row.end], cursor.caret - row.start)
            // Text is top-aligned: anchor the caret to the line top, sized to
            // the glyph height, not the full line height.
            rl.DrawRectangle(
                cast(i32) caret_x,
                cast(i32) caret_y,
                2,
                editor.font_size,
                editor.caret_color,
            )
        }
    }

    ui.end_clip()

    editor_draw_scrollbar(editor, line_height)

    if ctx.focused == widget {
        editor_draw_completion(editor)
    }

    // Hover peeks without focusing, so it draws whenever the mouse is dwelling
    // over this pane, regardless of which widget holds focus. The cursor leaving
    // the pane stops the hover ticks, so dismiss a lingering popup here.
    if ctx.hot != widget && editor.hover_active {
        editor_clear_hover(editor)
        editor.hover_probe_offset = -1
    }
    editor_draw_hover(editor)

    // Signature help is an explicit request from the focused pane; dismiss it once
    // focus leaves.
    if ctx.focused != widget && editor.signature_active {
        editor_clear_signature(editor)
    }
    editor_draw_signature(editor)
}

// Seconds the cursor must rest before a hover request fires, and the pixel
// drift that counts as "moved" and cancels the dwell.
HOVER_DWELL_SECS :: 0.45
HOVER_MOVE_TOL :: 3

// Per-frame hover tick: tracks dwell and fires one request to the owner once the
// cursor has been still long enough over the text. Movement resets the dwell and
// hides any shown popup.
@(private = "file")
editor_handle_hover :: proc(editor: ^Editor, mouse: rl.Vector2) {
    moved := abs(mouse.x - editor.hover_probe_pos.x) > HOVER_MOVE_TOL ||
             abs(mouse.y - editor.hover_probe_pos.y) > HOVER_MOVE_TOL
    if moved {
        editor.hover_probe_pos = mouse
        editor.hover_probe_time = rl.GetTime()
        editor.hover_probe_offset = -1
        editor_clear_hover(editor)
        return
    }
    if editor.on_hover == nil || editor.completion_active {
        return
    }
    // A shown popup or an in-flight request both wait: fire exactly once per
    // dwell, until the cursor moves again.
    if editor.hover_active || editor.hover_probe_offset >= 0 {
        return
    }
    if rl.GetTime() - editor.hover_probe_time < HOVER_DWELL_SECS {
        return
    }
    // Ignore the gutter and the scrollbar strip; only text hovers resolve.
    if mouse.x < editor.bounds.x + editor.gutter_width {
        return
    }
    if pos, ok := editor_pos_at(editor, mouse); ok {
        editor.hover_probe_offset = pos
        editor.on_hover(editor.hover_data, editor, editor.state, pos)
    }
}

// Draws the hover popup anchored to the resolved symbol, above the line (flipping
// below when there is no room) and nudged to stay inside the editor bounds.
@(private = "file")
editor_draw_hover :: proc(editor: ^Editor) {
    if !editor.hover_active || editor.hover_text == "" {
        return
    }
    x, y, lh, ok := editor_screen_at(editor, editor.hover_start)
    if !ok {
        return
    }

    pad: f32 = 8
    width := cast(f32) ui.measure_text(editor.hover_text, editor.font_size) + pad * 2
    height := lh + pad

    box_x := x
    box_y := y - height - 4
    if box_y < editor.bounds.y {
        box_y = y + lh + 4 // flip below the line
    }
    if box_x + width > editor.bounds.x + editor.bounds.width {
        box_x = editor.bounds.x + editor.bounds.width - width - 4
    }
    if box_x < editor.bounds.x {
        box_x = editor.bounds.x
    }

    box := rl.Rectangle {box_x, box_y, width, height}
    rl.DrawRectangleRec(box, editor.gutter_color)
    rl.DrawRectangleLinesEx(box, 1, editor.focus_border_color)
    text_y := cast(i32) (box_y + (height - cast(f32) editor.font_size) * 0.5)
    ui.draw_text(editor.hover_text, cast(i32) (box_x + pad), text_y, editor.font_size, editor.text_color)
}

// Draws the signature-help popup anchored above the caret, flipping below when
// there is no room and nudged to stay inside the editor bounds. Mirrors the hover
// popup, but keyed to an explicit request rather than a mouse dwell.
@(private = "file")
editor_draw_signature :: proc(editor: ^Editor) {
    if !editor.signature_active || editor.signature_text == "" {
        return
    }
    x, y, lh, ok := editor_screen_at(editor, editor.signature_anchor)
    if !ok {
        return
    }

    pad: f32 = 8
    width := cast(f32) ui.measure_text(editor.signature_text, editor.font_size) + pad * 2
    height := lh + pad

    box_x := x
    box_y := y - height - 4
    if box_y < editor.bounds.y {
        box_y = y + lh + 4 // flip below the line
    }
    if box_x + width > editor.bounds.x + editor.bounds.width {
        box_x = editor.bounds.x + editor.bounds.width - width - 4
    }
    if box_x < editor.bounds.x {
        box_x = editor.bounds.x
    }

    box := rl.Rectangle {box_x, box_y, width, height}
    rl.DrawRectangleRec(box, editor.gutter_color)
    rl.DrawRectangleLinesEx(box, 1, editor.focus_border_color)
    text_y := cast(i32) (box_y + (height - cast(f32) editor.font_size) * 0.5)
    ui.draw_text(editor.signature_text, cast(i32) (box_x + pad), text_y, editor.font_size, editor.text_color)
}

// Screen x, top y, and line height of byte `offset` (clamped to its visual row).
// ok=false when there is nothing to anchor to.
@(private = "file")
editor_screen_at :: proc(editor: ^Editor, offset: int) -> (x, y, line_height: f32, ok: bool) {
    if editor.state == nil || len(editor.visual_rows) == 0 {
        return 0, 0, 0, false
    }
    text := textedit.text(editor.state)
    row_index := editor_visual_row_index(editor, offset)
    row := editor.visual_rows[row_index]
    lh := cast(f32) ui.text_line_height(editor.font_size)
    inner_top := editor.bounds.y + editor.padding.top
    text_x := editor.bounds.x + editor.gutter_width + editor.padding.left
    yy := inner_top - editor.scroll_y + cast(f32) row_index * lh
    col := clamp(offset, row.start, row.end)
    xx := text_x + cast(f32) ui.measure_text(text[row.start:col], editor.font_size) +
        editor_swatch_offset(editor, text[row.start:row.end], col - row.start)
    return xx, yy, lh, true
}

// Screen x, top y, and line height of the primary caret. ok=false when there
// is nothing to anchor to.
@(private = "file")
editor_caret_screen :: proc(editor: ^Editor) -> (x, y, line_height: f32, ok: bool) {
    if editor.state == nil {
        return 0, 0, 0, false
    }
    return editor_screen_at(editor, textedit.primary_cursor(editor.state).caret)
}

// Draws the completion popup under the caret, flipping above when there is no
// room below and nudging left to stay inside the editor bounds.
@(private = "file")
editor_draw_completion :: proc(editor: ^Editor) {
    if !editor.completion_active || len(editor.completion_items) == 0 {
        return
    }
    caret_x, caret_y, lh, ok := editor_caret_screen(editor)
    if !ok {
        return
    }

    visible := min(len(editor.completion_items), COMPLETION_MAX_ROWS)
    width: f32 = 140
    for item in editor.completion_items {
        w := cast(f32) ui.measure_text(item, editor.font_size) + 24
        if w > width {
            width = w
        }
    }
    width = min(width, 420)

    box_x := caret_x
    box_y := caret_y + lh + 2
    box_h := cast(f32) visible * lh + 4
    if box_x + width > editor.bounds.x + editor.bounds.width {
        box_x = editor.bounds.x + editor.bounds.width - width - 4
    }
    if box_x < editor.bounds.x {
        box_x = editor.bounds.x
    }
    if box_y + box_h > editor.bounds.y + editor.bounds.height {
        box_y = caret_y - box_h - 2 // flip above the caret
    }

    box := rl.Rectangle {box_x, box_y, width, box_h}
    rl.DrawRectangleRec(box, editor.gutter_color)
    rl.DrawRectangleLinesEx(box, 1, editor.border_color)

    // Keep the selected item in view when the list is longer than the popup.
    top := 0
    if editor.completion_selected >= visible {
        top = editor.completion_selected - visible + 1
    }
    for i in 0 ..< visible {
        idx := top + i
        if idx >= len(editor.completion_items) {
            break
        }
        row_y := box_y + 2 + cast(f32) i * lh
        if idx == editor.completion_selected {
            rl.DrawRectangleRec(rl.Rectangle {box_x, row_y, width, lh}, editor.selection_color)
        }
        text_y := cast(i32) (row_y + (lh - cast(f32) editor.font_size) * 0.5)
        ui.draw_text(editor.completion_items[idx], cast(i32) (box_x + 8), text_y, editor.font_size, editor.text_color)
    }
}

// Vertical scrollbar on the right edge, shown only when the document overflows
// the view. Thumb size and position track scroll_y.
editor_draw_scrollbar :: proc(editor: ^Editor, line_height: f32) {
    view_height := editor.bounds.height - editor.padding.top - editor.padding.bottom
    content_height := cast(f32) len(editor.visual_rows) * line_height
    if content_height <= view_height {
        return
    }

    width: f32 = 6
    track_x := editor.bounds.x + editor.bounds.width - width - 2
    track_y := editor.bounds.y + editor.padding.top
    rl.DrawRectangleRec(rl.Rectangle {track_x, track_y, width, view_height}, editor.gutter_color)

    thumb_height := max(view_height * view_height / content_height, 28)
    max_scroll := content_height - view_height
    t := max_scroll > 0 ? editor.scroll_y / max_scroll : 0
    thumb_y := track_y + (view_height - thumb_height) * t
    rl.DrawRectangleRec(rl.Rectangle {track_x, thumb_y, width, thumb_height}, editor.line_number_color)
}

// Draws one visual row, coloring byte ranges from the highlight spans and the
// default color for the gaps. `hl_start` is the first span that may touch it.
// A reserved gap is opened just before each hex color literal so its swatch has
// real space to sit in instead of overprinting the text.
editor_draw_row_text :: proc(editor: ^Editor, text: string, row: Visual_Row, hl_start: int, text_x, row_y: i32) {
    swatches: [MAX_ROW_SWATCHES]Row_Swatch
    sw_count := editor_scan_swatches(text[row.start:row.end], swatches[:])
    span := editor_swatch_span(editor)

    pen := cast(f32) text_x
    pos := row.start
    j := hl_start
    si := 0
    for pos < row.end {
        rel := pos - row.start
        // Opening the reserved gap when the pen arrives exactly at an anchor.
        for si < sw_count && swatches[si].anchor < rel {
            si += 1
        }
        if si < sw_count && swatches[si].anchor == rel {
            pen += span
            si += 1
        }

        // Current color and where its run ends.
        for j < len(editor.highlights) && editor.highlights[j].end <= pos {
            j += 1
        }
        color := editor.text_color
        run_end := row.end
        if j < len(editor.highlights) {
            hl := editor.highlights[j]
            if hl.start <= pos {
                color = hl.color
                run_end = min(hl.end, row.end)
            } else {
                run_end = min(hl.start, row.end)
            }
        }
        // Stop before the next anchor so its gap opens on the next pass.
        if si < sw_count {
            next := row.start + swatches[si].anchor
            if next > pos && next < run_end {
                run_end = next
            }
        }

        seg := text[pos:run_end]
        ui.draw_text(seg, cast(i32) pen, row_y, editor.font_size, color)
        pen += cast(f32) ui.measure_text(seg, editor.font_size)
        pos = run_end
    }
}

@(private = "file")
editor_hex_value :: proc(b: u8) -> (u8, bool) {
    switch b {
    case '0' ..= '9': return b - '0', true
    case 'a' ..= 'f': return b - 'a' + 10, true
    case 'A' ..= 'F': return b - 'A' + 10, true
    }
    return 0, false
}

@(private = "file")
editor_is_hex_digit :: proc(b: u8) -> bool {
    _, ok := editor_hex_value(b)
    return ok
}

// Parses the hex digits of a color literal (no leading `#`). Accepts the CSS
// lengths: 3 (RGB), 4 (RGBA), 6 (RRGGBB), 8 (RRGGBBAA); short forms expand each
// nibble to a byte (f -> ff).
@(private = "file")
editor_parse_hex_color :: proc(digits: string) -> (rl.Color, bool) {
    v: [8]u8
    for i in 0 ..< len(digits) {
        d, ok := editor_hex_value(digits[i])
        if !ok {
            return {}, false
        }
        v[i] = d
    }
    switch len(digits) {
    case 3: return rl.Color {v[0] * 17, v[1] * 17, v[2] * 17, 255}, true
    case 4: return rl.Color {v[0] * 17, v[1] * 17, v[2] * 17, v[3] * 17}, true
    case 6: return rl.Color {v[0] * 16 + v[1], v[2] * 16 + v[3], v[4] * 16 + v[5], 255}, true
    case 8: return rl.Color {v[0] * 16 + v[1], v[2] * 16 + v[3], v[4] * 16 + v[5], v[6] * 16 + v[7]}, true
    }
    return {}, false
}

// Padding kept on each side of a swatch inside its reserved gap.
@(private = "file")
SWATCH_PAD :: 3

// Fraction of the character height a swatch fills; the rest is top/bottom
// padding so the square sits centered with air around it, like VS Code.
@(private = "file")
SWATCH_SCALE :: 0.7

// Upper bound on swatches tracked per visual row; extras beyond it are ignored.
@(private = "file")
MAX_ROW_SWATCHES :: 64

// One hex color found in a row, in row-relative bytes. `anchor` is where the
// reserved gap opens (before the literal and any opening quote).
@(private = "file")
Row_Swatch :: struct {
    anchor: int,
    color:  rl.Color,
}

// Width reserved for one swatch: the square plus padding on both sides.
@(private = "file")
editor_swatch_span :: proc(editor: ^Editor) -> f32 {
    return cast(f32) editor.font_size * SWATCH_SCALE + 2 * SWATCH_PAD
}

// Finds every hex color literal in `s` (a row's text), recording its color and
// the byte at which its reserved gap opens. Returns how many were written.
@(private = "file")
editor_scan_swatches :: proc(s: string, out: []Row_Swatch) -> int {
    count := 0
    i := 0
    for i < len(s) && count < len(out) {
        if s[i] != '#' {
            i += 1
            continue
        }
        j := i + 1
        for j < len(s) && editor_is_hex_digit(s[j]) {
            j += 1
        }
        n := j - i - 1
        if n == 3 || n == 4 || n == 6 || n == 8 {
            if color, ok := editor_parse_hex_color(s[i + 1:j]); ok {
                anchor := i
                if anchor > 0 && s[anchor - 1] == '"' {
                    anchor -= 1
                }
                out[count] = Row_Swatch {anchor = anchor, color = color}
                count += 1
            }
        }
        i = max(j, i + 1)
    }
    return count
}

// Horizontal space reserved by swatches at or before row-relative byte `rel`,
// so callers can shift text/caret/selection x-positions to match the gaps
// opened by editor_draw_row_text.
@(private = "file")
editor_swatch_offset :: proc(editor: ^Editor, row_text: string, rel: int) -> f32 {
    swatches: [MAX_ROW_SWATCHES]Row_Swatch
    count := editor_scan_swatches(row_text, swatches[:])
    span := editor_swatch_span(editor)
    total: f32 = 0
    for k in 0 ..< count {
        if swatches[k].anchor <= rel {
            total += span
        }
    }
    return total
}

// Highest-severity diagnostic on logical line `line`, if any. Errors outrank
// warnings so the gutter dot reflects the worst issue on the line.
@(private = "file")
editor_line_diagnostic :: proc(editor: ^Editor, line: int) -> (Diagnostic_Severity, bool) {
    found := false
    worst := Diagnostic_Severity.Warning
    for d in editor.diagnostics {
        if d.line != line {
            continue
        }
        found = true
        if d.severity == .Error {
            return .Error, true
        }
    }
    return worst, found
}

// Draws a colored squiggle under the part of each diagnostic range that falls on
// this visual row. The x for a byte offset matches the caret math (measured text
// plus any hex-swatch gaps before it), so the underline tracks the glyphs.
@(private = "file")
editor_draw_row_diagnostics :: proc(editor: ^Editor, text: string, row: Visual_Row, text_x: i32, row_y: f32) {
    if len(editor.diagnostics) == 0 {
        return
    }
    row_text := text[row.start:row.end]
    base_x := cast(f32) text_x
    // Seated just under the glyph box (text is top-aligned, height font_size).
    y := row_y + cast(f32) editor.font_size - 1
    for d in editor.diagnostics {
        seg_start := max(d.start, row.start)
        seg_end := min(d.end, row.end)
        if seg_start >= seg_end {
            continue
        }
        x0 := base_x + cast(f32) ui.measure_text(text[row.start:seg_start], editor.font_size) +
            editor_swatch_offset(editor, row_text, seg_start - row.start)
        x1 := base_x + cast(f32) ui.measure_text(text[row.start:seg_end], editor.font_size) +
            editor_swatch_offset(editor, row_text, seg_end - row.start)
        color := d.severity == .Error ? editor.diagnostic_error_color : editor.diagnostic_warn_color
        editor_draw_squiggle(x0, x1, y, color)
    }
}

// A small triangle wave from x0 to x1 along baseline y: the underline editors use
// to flag diagnostics.
@(private = "file")
editor_draw_squiggle :: proc(x0, x1, y: f32, color: rl.Color) {
    amp: f32 = 2
    step: f32 = 2
    prev := rl.Vector2 {x0, y}
    x := x0
    up := true
    for x < x1 {
        nx := min(x + step, x1)
        ny := up ? y - amp : y
        rl.DrawLineEx(prev, rl.Vector2 {nx, ny}, 1, color)
        prev = rl.Vector2 {nx, ny}
        x = nx
        up = !up
    }
}

// Draws a filled square previewing each hex color literal in the row, seated in
// the gap editor_draw_row_text reserved just before the literal, so it never
// overprints the value or a trailing comma. Sized a little under the character
// height and centered in the line for even padding on every side, like VS Code.
// A translucent border keeps light swatches legible on the background.
@(private = "file")
editor_draw_row_swatches :: proc(editor: ^Editor, text: string, row: Visual_Row, text_x, row_y: i32) {
    s := text[row.start:row.end]
    swatches: [MAX_ROW_SWATCHES]Row_Swatch
    count := editor_scan_swatches(s, swatches[:])
    if count == 0 {
        return
    }
    size := cast(f32) editor.font_size * SWATCH_SCALE
    span := editor_swatch_span(editor)
    // Text is top-aligned within the glyph box, so center on that (not the full
    // line height) to sit level with the characters.
    y := cast(f32) row_y + (cast(f32) editor.font_size - size) * 0.5
    for k in 0 ..< count {
        // The gap opens at the anchor's measured x, shifted by the gaps of any
        // earlier swatches on this row.
        gap_x := cast(f32) text_x +
            cast(f32) ui.measure_text(s[:swatches[k].anchor], editor.font_size) +
            cast(f32) k * span
        rect := rl.Rectangle {
            x      = gap_x + SWATCH_PAD,
            y      = y,
            width  = size,
            height = size,
        }
        rl.DrawRectangleRec(rect, swatches[k].color)
        rl.DrawRectangleLinesEx(rect, 1, rl.Color {0, 0, 0, 140})
    }
}

// Draws a fold chevron centered in the fold column at [col_x, col_x+col_w] on
// the row starting at `row_y`: a right-pointing triangle when collapsed, a
// down-pointing one when expanded.
@(private = "file")
editor_draw_fold_chevron :: proc(editor: ^Editor, col_x, col_w, row_y, line_height: f32, folded: bool) {
    cx := col_x + col_w * 0.5
    cy := row_y + cast(f32) editor.font_size * 0.5
    s := cast(f32) editor.font_size * 0.3
    color := editor.line_number_color
    if folded {
        // ▸ pointing right toward the hidden body.
        rl.DrawTriangle(
            rl.Vector2 {cx - s * 0.5, cy - s},
            rl.Vector2 {cx - s * 0.5, cy + s},
            rl.Vector2 {cx + s * 0.7, cy},
            color,
        )
    } else {
        // ▾ pointing down over the body it can hide.
        rl.DrawTriangle(
            rl.Vector2 {cx - s, cy - s * 0.5},
            rl.Vector2 {cx, cy + s * 0.7},
            rl.Vector2 {cx + s, cy - s * 0.5},
            color,
        )
    }
}

// Draws the "…" pill that stands in for a collapsed region, just past the end of
// the fold's start-line text.
@(private = "file")
editor_draw_fold_marker :: proc(editor: ^Editor, text: string, row: Visual_Row, text_x: i32, row_y: f32) {
    row_text := text[row.start:row.end]
    x_end := cast(f32) text_x + cast(f32) ui.measure_text(row_text, editor.font_size) +
        editor_swatch_offset(editor, row_text, row.end - row.start)
    r := max(cast(f32) editor.font_size * 0.09, 1.5)
    gap := r * 3
    box_x := x_end + 8
    box := rl.Rectangle {
        x      = box_x - 5,
        y      = row_y + cast(f32) editor.font_size * 0.15,
        width  = gap * 2 + 10,
        height = cast(f32) editor.font_size * 0.7,
    }
    rl.DrawRectangleRounded(box, 0.5, 4, editor.selection_color)
    cy := row_y + cast(f32) editor.font_size * 0.5
    for i in 0 ..< 3 {
        rl.DrawCircleV(rl.Vector2 {box_x + cast(f32) i * gap, cy}, r, editor.line_number_color)
    }
}

editor_draw_line_selections :: proc(editor: ^Editor, text: string, line_start, line_end: int, text_x, line_y, line_height: f32) {
    for cursor in editor.state.cursors {
        lo, hi := textedit.selection_range(cursor)
        if hi <= lo || hi <= line_start || lo > line_end {
            continue
        }

        seg_lo := max(lo, line_start)
        seg_hi := min(hi, line_end)
        row_text := text[line_start:line_end]
        x_start := cast(f32) ui.measure_text(text[line_start:seg_lo], editor.font_size) +
            editor_swatch_offset(editor, row_text, seg_lo - line_start)
        x_end := cast(f32) ui.measure_text(text[line_start:seg_hi], editor.font_size) +
            editor_swatch_offset(editor, row_text, seg_hi - line_start)
        width := x_end - x_start
        if hi > line_end {
            // Selection continues past the newline; show it.
            width += 8
        }
        if width <= 0 {
            continue
        }

        // Text is top-aligned, so size the highlight to the glyph height (like
        // the caret) instead of the full line height; otherwise the extra line
        // spacing hangs below the text and the selection reads as too tall.
        rl.DrawRectangleRec(
            rl.Rectangle {x = text_x + x_start, y = line_y, width = width, height = cast(f32) editor.font_size},
            editor.selection_color,
        )
    }
}

editor_destroy :: proc(widget: ^ui.Widget) {
    // The textedit state is owned by whoever opened the file, not the widget.
    editor := cast(^Editor) widget
    delete(editor.visual_rows)
    delete(editor.hover_text)
    delete(editor.signature_text)
    for item in editor.completion_items {
        delete(item)
    }
    delete(editor.completion_items)
    delete(editor.foldable)
    delete(editor.folded)
    free(editor)
}

// Byte offset of the character nearest the given screen position.
editor_pos_at :: proc(editor: ^Editor, position: rl.Vector2) -> (int, bool) {
    if len(editor.visual_rows) == 0 {
        return 0, false
    }
    text := textedit.text(editor.state)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    inner_top := editor.bounds.y + editor.padding.top
    text_x := editor.bounds.x + editor.gutter_width + editor.padding.left

    target := cast(int) ((position.y - (inner_top - editor.scroll_y)) / line_height)
    target = clamp(target, 0, len(editor.visual_rows) - 1)
    row := editor.visual_rows[target]
    target_x := position.x - text_x

    row_text := text[row.start:row.end]
    pos := row.start
    for pos < row.end {
        _, width := utf8.decode_rune_in_string(text[pos:])
        width_before := cast(f32) ui.measure_text(text[row.start:pos], editor.font_size) +
            editor_swatch_offset(editor, row_text, pos - row.start)
        width_after := cast(f32) ui.measure_text(text[row.start:pos + width], editor.font_size) +
            editor_swatch_offset(editor, row_text, pos + width - row.start)
        if target_x < (width_before + width_after) / 2 {
            break
        }
        pos += width
    }
    return pos, true
}

// Click: places a single caret at the position.
editor_place_caret_at :: proc(editor: ^Editor, position: rl.Vector2) {
    if pos, ok := editor_pos_at(editor, position); ok {
        textedit.set_single_cursor(editor.state, pos)
    }
}

// Drag / shift-click: extends the selection to the position, keeping the anchor.
editor_select_to :: proc(editor: ^Editor, position: rl.Vector2) {
    if pos, ok := editor_pos_at(editor, position); ok {
        anchor := textedit.primary_cursor(editor.state).anchor
        textedit.select_range(editor.state, anchor, pos)
        editor_scroll_to_caret(editor)
    }
}

// Word-drag after a double-click: extends by whole words, always covering the
// double-clicked word (word_lo..word_hi).
editor_word_select_to :: proc(editor: ^Editor, position: rl.Vector2) {
    pos, ok := editor_pos_at(editor, position)
    if !ok {
        return
    }
    txt := textedit.text(editor.state)
    lo, hi, found := textedit.word_range_at(txt, pos)
    if !found {
        lo, hi = pos, pos
    }
    if pos <= editor.word_lo {
        // Dragging left of the anchor word: caret leads, anchor stays right.
        textedit.select_range(editor.state, editor.word_hi, min(lo, editor.word_lo))
    } else {
        textedit.select_range(editor.state, editor.word_lo, max(hi, editor.word_hi))
    }
    editor_scroll_to_caret(editor)
}

editor_scroll_to_caret :: proc(editor: ^Editor) {
    // The buffer may have changed since layout, so refresh the row map first.
    editor_rebuild_visual_rows(editor)
    row_index := editor_visual_row_index(editor, textedit.primary_cursor(editor.state).caret)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    view_height := editor.bounds.height - editor.padding.top - editor.padding.bottom
    caret_top := cast(f32) row_index * line_height

    if caret_top < editor.scroll_y {
        editor.scroll_y = caret_top
    }
    if caret_top + line_height > editor.scroll_y + view_height {
        editor.scroll_y = caret_top + line_height - view_height
    }
    editor_clamp_scroll(editor)
}

// Moves every cursor by `delta` visual rows, keeping its column, so vertical
// motion follows wrapped rows (plain Up/Down and Page).
editor_move_visual :: proc(editor: ^Editor, delta: int, extend: bool) {
    editor_rebuild_visual_rows(editor)
    if len(editor.visual_rows) == 0 {
        return
    }
    text := textedit.text(editor.state)
    for &cursor in editor.state.cursors {
        row_index := editor_visual_row_index(editor, cursor.caret)
        row := editor.visual_rows[row_index]
        col := utf8.rune_count_in_string(text[row.start:cursor.caret])

        target := clamp(row_index + delta, 0, len(editor.visual_rows) - 1)
        trow := editor.visual_rows[target]
        cursor.caret = editor_byte_at_col(text, trow.start, trow.end, col)
        if !extend {
            cursor.anchor = cursor.caret
        }
    }
    textedit.normalize(editor.state)
}

editor_clamp_scroll :: proc(editor: ^Editor) {
    if editor.state == nil {
        editor.scroll_y = 0
        return
    }
    content_height := cast(f32) len(editor.visual_rows) * cast(f32) ui.text_line_height(editor.font_size)
    view_height := editor.bounds.height - editor.padding.top - editor.padding.bottom
    max_scroll := content_height - view_height
    if max_scroll < 0 {
        max_scroll = 0
    }

    if editor.scroll_y < 0 {
        editor.scroll_y = 0
    }
    if editor.scroll_y > max_scroll {
        editor.scroll_y = max_scroll
    }
}
