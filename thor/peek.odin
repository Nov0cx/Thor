// Peek definition: the `.Definition` result shown in an editor under the caret's line, in a zone of the pane.
package thor

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "../editview"
import "../font"
import "../lang"
import "../setting"
import "../textedit"
import ui "../vendor/loom/loom"

// The focus key of the peek's editor.
PEEK_KEY :: "peek"

// One place the definition result names.
Peek_Target :: struct {
    path:  string, // owned
    start: int,
    end:   int,
}

// The open peek, or the request for one.
Peek :: struct {
    open:        bool,
    request_id:  u64,
    pane:        int,
    anchor_path: string, // owned; the file the peek was asked in
    anchor_line: int,
    targets:     [dynamic]Peek_Target,
    index:       int,
    editor:      editview.Editor,
    scroll:      ui.Vec2,
    file:        ^Open_File, // borrowed; the target's tab, nil until it is found or opened
    opened_here: bool, // the peek opened the target's tab
    placed:      bool, // the caret is on the target
}

// Asks for the definition under the caret of the active pane, to show in a peek.
thor_peek_definition :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    ext := thor_lang_key(thor, file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Definition) {
        thor_flash_status(thor, "No definition provider for this file", is_error = true)
        return
    }
    thor_peek_close(thor)
    caret := textedit.primary_cursor(&file.state).caret
    id := lang.manager_request(
        &thor.lang_manager,
        .Definition,
        file.path,
        ext,
        textedit.text(&file.state),
        caret,
        file.state.revision,
        thor.workspace_dir,
    )
    if id == 0 {
        return
    }
    thor.peek.request_id = id
    thor.peek.pane = thor.active_pane
    thor.peek.anchor_line = textedit.state_line_index(&file.state, caret)
    delete(thor.peek.anchor_path)
    thor.peek.anchor_path = strings.clone(file.path)
}

// Takes a definition result the peek asked for; false for one it did not.
thor_peek_take_result :: proc(thor: ^Thor, res: ^lang.Result) -> bool {
    peek := &thor.peek
    if peek.request_id == 0 || res.id != peek.request_id {
        return false
    }
    peek.request_id = 0
    outer := thor_peek_outer_file(thor)
    if outer == nil || !thor_same_path(outer.path, peek.anchor_path) {
        return true
    }
    editor := thor_pane_editor(thor, peek.pane)
    if editor.state == nil || textedit.state_line_index(editor.state, textedit.primary_cursor(editor.state).caret) != peek.anchor_line {
        return true
    }
    if !res.ok {
        thor_flash_status(thor, "No definition found", is_error = true)
        return true
    }
    thor_peek_free_targets(peek)
    if len(res.symbols) > 1 {
        for sym in res.symbols {
            append(&peek.targets, Peek_Target{path = strings.clone(sym.path), start = sym.offset, end = sym.offset + len(sym.name)})
        }
    } else {
        append(&peek.targets, Peek_Target{path = strings.clone(res.location.path), start = res.location.start, end = res.location.end})
    }
    rows := setting.peek_height(&thor.config) + 1
    editview.editor_set_zone(editor, peek.anchor_line, rows)
    peek.open = true
    thor_peek_select(thor, 0)
    thor.focus_request = PEEK_KEY
    return true
}

// Shows target `index`, opening its file in a background tab when it is not open.
thor_peek_select :: proc(thor: ^Thor, index: int) {
    peek := &thor.peek
    if index < 0 || index >= len(peek.targets) {
        return
    }
    thor_peek_release_file(thor)
    peek.index = index
    peek.placed = false
    target := peek.targets[index]
    file := thor_open_file_at(thor, thor_abs_path(target.path))
    if file == nil {
        file = thor_open_file_tab(thor, target.path, activate = false)
        peek.opened_here = file != nil
    }
    peek.file = file
    if file == nil {
        thor_peek_close(thor)
    }
}

// Closes the peek and gives the focus back to its pane.
thor_peek_close :: proc(thor: ^Thor) {
    peek := &thor.peek
    if peek.request_id != 0 {
        lang.manager_cancel(&thor.lang_manager, peek.request_id)
        peek.request_id = 0
    }
    if !peek.open {
        return
    }
    peek.open = false
    editview.editor_clear_zone(thor_pane_editor(thor, peek.pane))
    thor_peek_release_file(thor)
    thor_peek_free_targets(peek)
    if thor.focus_owner == PEEK_KEY {
        thor.focus_request = thor_pane_key(peek.pane)
    }
}

// Jumps to the target the peek shows and closes it.
thor_peek_open_target :: proc(thor: ^Thor) {
    peek := &thor.peek
    if !peek.open || peek.index >= len(peek.targets) {
        return
    }
    target := peek.targets[peek.index]
    offset := target.start
    if peek.file != nil && peek.editor.state == &peek.file.state {
        offset = textedit.primary_cursor(&peek.file.state).caret
    }
    path := strings.clone(target.path, context.temp_allocator)
    peek.opened_here = false
    thor_peek_close(thor)
    thor_focus_pane(thor, peek.pane)
    thor_goto_location(thor, path, offset)
}

// Closes the peek when what it hangs on is gone: its pane shows another file, its line was
// deleted, the caret of its pane left the line, or the target's tab closed.
thor_peek_tick :: proc(thor: ^Thor) {
    peek := &thor.peek
    if peek.request_id != 0 && !lang.manager_has_request(&thor.lang_manager, peek.request_id) {
        peek.request_id = 0
    }
    if !peek.open {
        return
    }
    outer := thor_peek_outer_file(thor)
    editor := thor_pane_editor(thor, peek.pane)
    line, has_zone := editview.editor_zone_line(editor)
    if outer == nil || !thor_same_path(outer.path, peek.anchor_path) || !has_zone || peek.pane >= thor_pane_count(thor) {
        thor_peek_close(thor)
        return
    }
    peek.anchor_line = line
    if thor.focus_owner == thor_pane_key(peek.pane) && editor.state != nil &&
       textedit.state_line_index(editor.state, textedit.primary_cursor(editor.state).caret) != line {
        thor_peek_close(thor)
        return
    }
    if peek.file != nil && !thor_peek_file_alive(thor, peek.file) {
        peek.file = nil
        peek.opened_here = false
        thor_peek_close(thor)
        return
    }
    thor_peek_bind(thor)
}

// Binds the peek editor to the target's buffer once it has loaded, and puts the caret on the target.
@(private = "file")
thor_peek_bind :: proc(thor: ^Thor) {
    peek := &thor.peek
    file := peek.file
    if file == nil || !file.loaded {
        return
    }
    if peek.editor.state != &file.state {
        thor_wire_editor(thor, &peek.editor)
        editview.editor_set_on_save(&peek.editor, thor_peek_save, thor)
        thor_bind_editor(thor, &peek.editor, file)
        peek.placed = false
    }
    if !peek.placed && peek.index < len(peek.targets) {
        target := peek.targets[peek.index]
        text := textedit.text(&file.state)
        start := clamp(target.start, 0, len(text))
        end := clamp(target.end, start, len(text))
        textedit.select_range(&file.state, end, start)
        if end == start {
            textedit.set_single_cursor(&file.state, start)
        }
        peek.placed = true
        peek.editor.scroll_y = 0
        editview.editor_center_on_caret(&peek.editor)
    }
}

// Ctrl+S in the peek saves the target's buffer.
@(private = "file")
thor_peek_save :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if file := thor.peek.file; file != nil && thor.peek.open {
        thor_save_explicit(thor, file)
    }
}

// The file the peek's pane shows; nil when it shows none.
@(private = "file")
thor_peek_outer_file :: proc(thor: ^Thor) -> ^Open_File {
    if thor.peek.pane < 0 || thor.peek.pane >= len(thor.pane_file) {
        return nil
    }
    index := thor.pane_file[thor.peek.pane]
    if index < 0 || index >= len(thor.open_files) {
        return nil
    }
    return thor.open_files[index]
}

@(private = "file")
thor_peek_file_alive :: proc(thor: ^Thor, file: ^Open_File) -> bool {
    for open in thor.open_files {
        if open == file && !open.closed {
            return true
        }
    }
    return false
}

// Unbinds the peek editor, and closes the target's tab when the peek opened it and it is clean.
@(private = "file")
thor_peek_release_file :: proc(thor: ^Thor) {
    peek := &thor.peek
    editview.editor_set_state(&peek.editor, nil)
    file := peek.file
    peek.file = nil
    if file == nil || !peek.opened_here {
        return
    }
    peek.opened_here = false
    if file.state.revision != file.saved_revision {
        return
    }
    for open, index in thor.open_files {
        if open == file {
            if !thor_file_shown(thor, index) {
                thor_close_file(thor, index)
            }
            return
        }
    }
}

// Whether a pane shows open file `index`.
@(private = "file")
thor_file_shown :: proc(thor: ^Thor, index: int) -> bool {
    for shown, pane in thor.pane_file {
        if pane < thor_pane_count(thor) && shown == index {
            return true
        }
    }
    return false
}

@(private = "file")
thor_peek_free_targets :: proc(peek: ^Peek) {
    for target in peek.targets {
        delete(target.path)
    }
    clear(&peek.targets)
    peek.index = 0
}

// Frees what the peek owns.
thor_peek_destroy :: proc(thor: ^Thor) {
    peek := &thor.peek
    thor_peek_free_targets(peek)
    delete(peek.targets)
    delete(peek.anchor_path)
    peek.anchor_path = ""
    editview.editor_destroy(&peek.editor)
}

// Declares the peek in the zone of `outer`, the editor of its pane, whose node is at `pane_rect`.
thor_peek_view :: proc(thor: ^Thor, outer: ^editview.Editor, pane_rect: ui.Rect) {
    peek := &thor.peek
    rect, ok := editview.editor_zone_rect(outer)
    if !ok {
        return
    }
    line_h := f32(font.line_height(outer.font_size))
    ui.begin(
        {
            key = "peek_zone",
            props = {
                position = .Absolute,
                inset = {0, rect.y - pane_rect.y, 0, 0},
                w = ui.Px(pane_rect.w),
                h = ui.Px(rect.h),
                bg = thor.theme.second_background,
                border = {color = thor.theme.accent_color, width = {t = 1, b = 1}},
                dir = .Column,
            },
        },
    )
    defer ui.end()

    // The header: where the target is, the candidates, Open and close.
    {
        ui.begin({key = "peek_header", props = {w = ui.Grow(1), h = ui.Px(line_h), dir = .Row, align = .Center, pad = ui.xy(8, 0), gap = {8, 0}}})
        defer ui.end()
        label := "Loading..."
        if peek.index < len(peek.targets) {
            target := peek.targets[peek.index]
            line := 0
            if peek.file != nil && peek.file.loaded {
                line = textedit.state_line_index(&peek.file.state, clamp(target.start, 0, len(textedit.text(&peek.file.state)))) + 1
            }
            label = line > 0 ? fmt.tprintf("%s:%d", filepath.base(target.path), line) : filepath.base(target.path)
        }
        ui.leaf({key = "peek_title", text = label, props = {color = thor.theme.text, font_size = f32(outer.font_size) - 1}})
        if len(peek.targets) > 1 {
            ui.leaf({key = "peek_count", text = fmt.tprintf("%d of %d", peek.index + 1, len(peek.targets)), props = {color = thor.theme.muted_color, font_size = f32(outer.font_size) - 2}})
            if ui.button("<", {key = "peek_prev"}).clicked {
                thor_peek_select(thor, (peek.index + len(peek.targets) - 1) % len(peek.targets))
            }
            if ui.button(">", {key = "peek_next"}).clicked {
                thor_peek_select(thor, (peek.index + 1) % len(peek.targets))
            }
        }
        ui.leaf({key = "peek_fill", props = {w = ui.Grow(1)}})
        if ui.button("Open", {key = "peek_open"}).clicked {
            thor_peek_open_target(thor)
            return
        }
        if ui.button("x", {key = "peek_close"}).clicked {
            thor_peek_close(thor)
            return
        }
    }

    if peek.file == nil || !peek.file.loaded || peek.editor.state == nil {
        return
    }
    peek.editor.font_size = outer.font_size
    ui.begin({key = "peek_body", props = {w = ui.Grow(1), h = ui.Grow(1)}})
    defer ui.end()
    thor_editor_view(thor, &peek.editor, peek.file, &peek.scroll, PEEK_KEY, -1)
}

// Whether Escape belongs to the peek: it is open, its editor or its pane has the focus, and
// that editor shows no popup Escape would close first.
thor_peek_takes_escape :: proc(thor: ^Thor) -> bool {
    peek := &thor.peek
    if !peek.open {
        return false
    }
    if thor.focus_owner == PEEK_KEY {
        return !editview.editor_has_popup(&peek.editor)
    }
    if thor.focus_owner == thor_pane_key(peek.pane) {
        return !editview.editor_has_popup(thor_pane_editor(thor, peek.pane))
    }
    return false
}
