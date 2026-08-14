package widgets

import "core:strings"
import rl "vendor:raylib"

import "../ui"

// A centered modal that edits the active theme: every color role under a foldable
// group, each row a swatch, plus the rows that generate a whole palette from two
// seeds. It carries no theme knowledge — the host fills the rows and answers a
// click by opening the color picker.

// Fired when a color row is clicked; `key` is the theme color key it carries.
Theme_Color_Proc :: #type proc(data: rawptr, key: string)
// Fired when an action row is clicked (the generator's mode, seeds and button).
Theme_Action_Proc :: #type proc(data: rawptr, action: string)

Theme_Row_Kind :: enum {
    Group,  // chevron + label; clicking folds or unfolds the rows under it
    Color,  // label + hex + swatch; clicking opens the color picker
    Action, // label + value; clicking asks the host to act
}

Theme_Row :: struct {
    kind:  Theme_Row_Kind,
    id:    string, // owned; the color key, the action name, or the group id
    label: string, // owned
    value: string, // owned; the display hex, or an action's value text
    group: string, // owned; id of the Group row holding it, "" outside one
    color: rl.Color,
}

@(private = "file")
THEME_EDITOR_ROW_PAD :: f32(22)
@(private = "file")
THEME_EDITOR_INSET :: f32(10)
@(private = "file")
THEME_EDITOR_GROUP_INDENT :: f32(20)
@(private = "file")
THEME_EDITOR_CHECKER :: f32(6)
// Size of a color row's swatch.
@(private = "file")
THEME_EDITOR_SWATCH_WIDTH :: f32(34)
@(private = "file")
THEME_EDITOR_SWATCH_HEIGHT :: f32(18)

Theme_Editor :: struct {
    using widget: ui.Widget,
    title:        string, // owned; the theme's display name
    rows:         [dynamic]Theme_Row,
    // Indices into `rows` currently shown: a folded group hides its rows.
    visible_rows: [dynamic]int,
    current_group: string, // owned; cursor set by begin_group, "" outside one
    // Fold state per group id (keys owned). It outlives theme_editor_clear, so a
    // repopulate after a change keeps the groups the user folded folded.
    collapsed:    map[string]bool,
    // Keyboard-highlighted row (-1 = none), an index into `visible_rows`.
    selected:     int,
    scroll:       f32,
    box:          rl.Rectangle,
    list:         rl.Rectangle,
    width:        f32,
    height:       f32,
    row_height:   f32,
    header_height: f32,
    footer_height: f32,
    on_color:     Theme_Color_Proc,
    on_action:    Theme_Action_Proc,
    data:         rawptr,
    return_focus: ^ui.Widget,
    background_color: rl.Color,
    border_color:     rl.Color,
    header_color:     rl.Color,
    field_color:      rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    accent_color:     rl.Color,
    selected_color:   rl.Color,
}

theme_editor_vtable := ui.Widget_VTable {
    layout = theme_editor_layout,
    handle_event = theme_editor_handle_event,
    draw = theme_editor_draw,
    destroy = theme_editor_destroy,
}

theme_editor_create :: proc(id: string) -> ^Theme_Editor {
    editor := new(Theme_Editor)
    ui.widget_init(&editor.widget, id, theme_editor_vtable)
    editor.visible = false
    editor.rows = make([dynamic]Theme_Row)
    editor.visible_rows = make([dynamic]int)
    editor.collapsed = make(map[string]bool)
    editor.selected = -1
    editor.width = 560
    editor.height = 560
    editor.row_height = 36
    editor.header_height = 56
    editor.footer_height = 34
    editor.background_color = rl.Color {24, 26, 31, 250}
    editor.header_color = rl.Color {31, 34, 51, 255}
    editor.field_color = rl.Color {18, 20, 24, 255}
    editor.border_color = rl.Color {51, 56, 70, 255}
    editor.text_color = rl.Color {238, 255, 255, 255}
    editor.muted_color = rl.Color {120, 128, 160, 255}
    editor.accent_color = rl.Color {132, 255, 255, 255}
    editor.selected_color = rl.Color {132, 255, 255, 40}
    return editor
}

theme_editor_set_colors :: proc(
    editor: ^Theme_Editor,
    background, border, header, field, text, muted, accent, selected: rl.Color,
) -> ^Theme_Editor {
    editor.background_color = background
    editor.border_color = border
    editor.header_color = header
    editor.field_color = field
    editor.text_color = text
    editor.muted_color = muted
    editor.accent_color = accent
    editor.selected_color = selected
    return editor
}

theme_editor_set_callbacks :: proc(
    editor: ^Theme_Editor, on_color: Theme_Color_Proc, on_action: Theme_Action_Proc, data: rawptr,
) {
    editor.on_color = on_color
    editor.on_action = on_action
    editor.data = data
}

// Drops every row, keeping the scroll and the fold state so a live repopulate
// (after a color is committed) does not move the list under the cursor.
theme_editor_clear :: proc(editor: ^Theme_Editor) {
    for row in editor.rows {
        delete(row.id)
        delete(row.label)
        delete(row.value)
        delete(row.group)
    }
    clear(&editor.rows)
    clear(&editor.visible_rows)
    delete(editor.current_group)
    editor.current_group = ""
}

// Names the theme the rows came from; drawn in the header.
theme_editor_set_title :: proc(editor: ^Theme_Editor, title: string) {
    heading := strings.clone(title)
    delete(editor.title)
    editor.title = heading
}

theme_editor_begin_group :: proc(editor: ^Theme_Editor, id, label: string, collapsed := false) {
    if id not_in editor.collapsed {
        editor.collapsed[strings.clone(id)] = collapsed
    }
    append(&editor.rows, Theme_Row {
        kind = .Group,
        id = strings.clone(id),
        label = strings.clone(label),
        value = strings.clone(""),
        group = strings.clone(""),
    })
    delete(editor.current_group)
    editor.current_group = strings.clone(id)
}

theme_editor_end_group :: proc(editor: ^Theme_Editor) {
    delete(editor.current_group)
    editor.current_group = ""
}

// `hex` is the display text; the host formats it, so the widget keeps no
// color-format knowledge.
theme_editor_add_color :: proc(editor: ^Theme_Editor, key, label, hex: string, color: rl.Color) {
    append(&editor.rows, Theme_Row {
        kind = .Color,
        id = strings.clone(key),
        label = strings.clone(label),
        value = strings.clone(hex),
        group = strings.clone(editor.current_group),
        color = color,
    })
}

theme_editor_add_action :: proc(editor: ^Theme_Editor, action, label, value: string) {
    append(&editor.rows, Theme_Row {
        kind = .Action,
        id = strings.clone(action),
        label = strings.clone(label),
        value = strings.clone(value),
        group = strings.clone(editor.current_group),
    })
}

theme_editor_open :: proc(editor: ^Theme_Editor, ctx: ^ui.Context) {
    editor.scroll = 0
    editor.selected = -1
    editor.visible = true
    // A second open while already up must not clobber the real target with the
    // editor's own widget.
    if ctx.focused != &editor.widget {
        editor.return_focus = ctx.focused
    }
    ctx.focused = &editor.widget
    ui.widget_bring_to_front(&editor.widget)
}

theme_editor_is_open :: proc(editor: ^Theme_Editor) -> bool {
    return editor.visible
}

theme_editor_close :: proc(editor: ^Theme_Editor, ctx: ^ui.Context) {
    editor.visible = false
    if ctx.focused == &editor.widget {
        ctx.focused = editor.return_focus
    }
}

@(private = "file")
theme_editor_group_collapsed :: proc(editor: ^Theme_Editor, id: string) -> bool {
    return editor.collapsed[id] or_else false
}

@(private = "file")
theme_editor_toggle_group :: proc(editor: ^Theme_Editor, id: string) {
    if id not_in editor.collapsed {
        return
    }
    editor.collapsed[id] = !editor.collapsed[id]
    editor.scroll = 0
}

theme_editor_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    editor := cast(^Theme_Editor) widget
    // Cover the whole screen so clicks outside the box close the window.
    editor.bounds = bounds

    width := min(editor.width, bounds.width - 60)
    height := min(editor.height, bounds.height - 60)
    editor.box = rl.Rectangle {
        x = bounds.x + (bounds.width - width) * 0.5,
        y = bounds.y + (bounds.height - height) * 0.5,
        width = width,
        height = height,
    }
    editor.list = rl.Rectangle {
        editor.box.x,
        editor.box.y + editor.header_height,
        editor.box.width,
        editor.box.height - editor.header_height - editor.footer_height,
    }

    theme_editor_recompute_visible(editor)
    theme_editor_clamp_scroll(editor)
}

@(private = "file")
theme_editor_recompute_visible :: proc(editor: ^Theme_Editor) {
    clear(&editor.visible_rows)
    for row, i in editor.rows {
        if row.kind != .Group && row.group != "" && theme_editor_group_collapsed(editor, row.group) {
            continue
        }
        append(&editor.visible_rows, i)
    }
    if editor.selected >= len(editor.visible_rows) {
        editor.selected = len(editor.visible_rows) - 1
    }
}

@(private = "file")
theme_editor_max_scroll :: proc(editor: ^Theme_Editor) -> f32 {
    content := cast(f32) len(editor.visible_rows) * editor.row_height
    return max(0, content - editor.list.height)
}

@(private = "file")
theme_editor_clamp_scroll :: proc(editor: ^Theme_Editor) {
    editor.scroll = clamp(editor.scroll, 0, theme_editor_max_scroll(editor))
}

@(private)
theme_editor_row_rect :: proc(editor: ^Theme_Editor, pos: int) -> rl.Rectangle {
    return rl.Rectangle {
        editor.list.x + THEME_EDITOR_INSET,
        editor.list.y + cast(f32) pos * editor.row_height - editor.scroll,
        editor.list.width - THEME_EDITOR_INSET * 2,
        editor.row_height,
    }
}

@(private = "file")
theme_editor_row_at :: proc(editor: ^Theme_Editor, point: rl.Vector2) -> int {
    if !rl.CheckCollisionPointRec(point, editor.list) {
        return -1
    }
    pos := cast(int) ((point.y - editor.list.y + editor.scroll) / editor.row_height)
    if pos < 0 || pos >= len(editor.visible_rows) {
        return -1
    }
    return pos
}

@(private)
theme_editor_close_rect :: proc(editor: ^Theme_Editor) -> rl.Rectangle {
    return rl.Rectangle {editor.box.x + editor.box.width - 36, editor.box.y + 17, 22, 22}
}

theme_editor_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    editor := cast(^Theme_Editor) widget
    if !editor.visible {
        return false
    }

    #partial switch event.kind {
    case .Key_Press:
        #partial switch event.key {
        case .ESCAPE:
            theme_editor_close(editor, ctx)
        case .UP:
            theme_editor_move(editor, -1)
        case .DOWN:
            theme_editor_move(editor, 1)
        case .PAGE_UP:
            theme_editor_move(editor, -8)
        case .PAGE_DOWN:
            theme_editor_move(editor, 8)
        case .ENTER, .KP_ENTER:
            theme_editor_activate(editor, editor.selected)
        }
        return true

    case .Scroll:
        editor.scroll -= event.wheel_delta * editor.row_height * 3
        theme_editor_clamp_scroll(editor)
        return true

    case .Mouse_Down:
        if !rl.CheckCollisionPointRec(event.mouse_position, editor.box) ||
           rl.CheckCollisionPointRec(event.mouse_position, theme_editor_close_rect(editor)) {
            theme_editor_close(editor, ctx)
            return true
        }
        pos := theme_editor_row_at(editor, event.mouse_position)
        if pos >= 0 {
            editor.selected = pos
            theme_editor_activate(editor, pos)
        }
        return true
    }

    return true // block everything else from reaching widgets underneath
}

@(private = "file")
theme_editor_move :: proc(editor: ^Theme_Editor, delta: int) {
    if len(editor.visible_rows) == 0 {
        return
    }
    editor.selected = clamp(editor.selected + delta, 0, len(editor.visible_rows) - 1)
    // Keep the highlighted row on screen.
    top := cast(f32) editor.selected * editor.row_height
    editor.scroll = clamp(editor.scroll, top + editor.row_height - editor.list.height, top)
    theme_editor_clamp_scroll(editor)
}

// May trigger a callback that repopulates the rows, so it reads nothing from the
// row afterward.
@(private = "file")
theme_editor_activate :: proc(editor: ^Theme_Editor, pos: int) {
    if pos < 0 || pos >= len(editor.visible_rows) {
        return
    }
    row := &editor.rows[editor.visible_rows[pos]]
    switch row.kind {
    case .Group:
        theme_editor_toggle_group(editor, row.id)
    case .Color:
        if editor.on_color != nil {
            editor.on_color(editor.data, row.id)
        }
    case .Action:
        if editor.on_action != nil {
            editor.on_action(editor.data, row.id)
        }
    }
}

@(private = "file")
theme_editor_tint :: proc(base: rl.Color, alpha: u8) -> rl.Color {
    return rl.Color {base.r, base.g, base.b, alpha}
}

theme_editor_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    editor := cast(^Theme_Editor) widget
    if !editor.visible {
        return
    }
    mouse := rl.GetMousePosition()

    rl.DrawRectangleRec(editor.bounds, rl.Color {0, 0, 0, 150})
    rl.DrawRectangleRounded(editor.box, SETTINGS_ROUNDNESS, 8, editor.background_color)
    rl.DrawRectangleRoundedLinesEx(editor.box, SETTINGS_ROUNDNESS, 8, 1, editor.border_color)

    header := rl.Rectangle {editor.box.x, editor.box.y, editor.box.width, editor.header_height}
    rl.DrawRectangleRec(header, editor.header_color)
    ui.draw_text(
        "Theme", cast(i32) (editor.box.x + 20), cast(i32) (editor.box.y + 12), 18, editor.text_color,
    )
    ui.draw_text(
        editor.title, cast(i32) (editor.box.x + 20), cast(i32) (editor.box.y + 33), 14, editor.muted_color,
    )
    close := theme_editor_close_rect(editor)
    if rl.CheckCollisionPointRec(mouse, close) {
        rl.DrawRectangleRounded(close, 0.35, 6, theme_editor_tint(editor.muted_color, 40))
    }
    ui.draw_icon("x", cast(i32) (close.x + 3), cast(i32) (close.y + 3), 16, editor.muted_color)

    theme_editor_draw_rows(editor, mouse)
    theme_editor_draw_scrollbar(editor)

    ui.draw_text(
        "Enter opens a color · Esc closes",
        cast(i32) (editor.box.x + 20),
        cast(i32) (editor.box.y + editor.box.height - editor.footer_height + 8),
        14,
        editor.muted_color,
    )
}

@(private = "file")
theme_editor_draw_rows :: proc(editor: ^Theme_Editor, mouse: rl.Vector2) {
    ui.begin_clip(editor.list)
    defer ui.end_clip()

    for pos in 0 ..< len(editor.visible_rows) {
        rect := theme_editor_row_rect(editor, pos)
        if rect.y + rect.height < editor.list.y || rect.y > editor.list.y + editor.list.height {
            continue
        }
        row := &editor.rows[editor.visible_rows[pos]]
        hovered := rl.CheckCollisionPointRec(mouse, rect) && rl.CheckCollisionPointRec(mouse, editor.list)
        if pos == editor.selected || hovered {
            rl.DrawRectangleRounded(rect, 0.3, 6, editor.selected_color)
        }

        label_x := rect.x + 12
        label_y := cast(i32) (rect.y + (rect.height - 16) * 0.5)

        if row.kind == .Group {
            collapsed := theme_editor_group_collapsed(editor, row.id)
            ui.draw_icon(
                collapsed ? "chevron-right" : "chevron-down",
                cast(i32) label_x, cast(i32) (rect.y + (rect.height - 16) * 0.5), 16, editor.accent_color,
            )
            ui.draw_text(row.label, cast(i32) (label_x + 22), label_y, 16, editor.text_color)
            continue
        }

        if row.group != "" {
            label_x += THEME_EDITOR_GROUP_INDENT
        }
        ui.draw_text(row.label, cast(i32) label_x, label_y, 16, editor.text_color)

        if row.kind == .Action {
            icon_x := rect.x + rect.width - THEME_EDITOR_ROW_PAD - 16
            ui.draw_icon(
                "chevron-right", cast(i32) icon_x, cast(i32) (rect.y + (rect.height - 16) * 0.5), 16,
                editor.muted_color,
            )
            tw := ui.measure_text(row.value, 16)
            ui.draw_text(row.value, cast(i32) (icon_x - 8 - cast(f32) tw), label_y, 16, editor.accent_color)
            continue
        }

        swatch := rl.Rectangle {
            rect.x + rect.width - THEME_EDITOR_ROW_PAD - THEME_EDITOR_SWATCH_WIDTH,
            rect.y + (rect.height - THEME_EDITOR_SWATCH_HEIGHT) * 0.5,
            THEME_EDITOR_SWATCH_WIDTH,
            THEME_EDITOR_SWATCH_HEIGHT,
        }
        if row.color.a < 0xFF {
            theme_editor_draw_checker(editor, swatch)
        }
        rl.DrawRectangleRounded(swatch, 0.35, 6, row.color)
        rl.DrawRectangleRoundedLinesEx(swatch, 0.35, 6, 1, theme_editor_tint(editor.muted_color, 90))
        tw := ui.measure_text(row.value, 14)
        ui.draw_text(
            row.value,
            cast(i32) (swatch.x - 10 - cast(f32) tw),
            cast(i32) (rect.y + (rect.height - 14) * 0.5),
            14,
            editor.muted_color,
        )
    }
}

// Tiles the squares a translucent swatch is read against.
@(private = "file")
theme_editor_draw_checker :: proc(editor: ^Theme_Editor, rect: rl.Rectangle) {
    light := theme_editor_tint(editor.muted_color, 120)
    rows := int(rect.height / THEME_EDITOR_CHECKER) + 1
    columns := int(rect.width / THEME_EDITOR_CHECKER) + 1
    for row in 0 ..< rows {
        for column in 0 ..< columns {
            cell := rl.Rectangle {
                rect.x + f32(column) * THEME_EDITOR_CHECKER,
                rect.y + f32(row) * THEME_EDITOR_CHECKER,
                min(THEME_EDITOR_CHECKER, rect.x + rect.width - (rect.x + f32(column) * THEME_EDITOR_CHECKER)),
                min(THEME_EDITOR_CHECKER, rect.y + rect.height - (rect.y + f32(row) * THEME_EDITOR_CHECKER)),
            }
            rl.DrawRectangleRec(cell, (row + column) % 2 == 0 ? editor.field_color : light)
        }
    }
}

@(private = "file")
THEME_EDITOR_SCROLLBAR_STYLE :: ui.Scrollbar_Style {width = 6, min_thumb = 30, inset = 3}

@(private = "file")
theme_editor_draw_scrollbar :: proc(editor: ^Theme_Editor) {
    content := cast(f32) len(editor.visible_rows) * editor.row_height
    track, thumb, ok := ui.scrollbar_rects(editor.list, content, editor.scroll, THEME_EDITOR_SCROLLBAR_STYLE)
    if !ok {
        return
    }
    rl.DrawRectangleRounded(track, 0.8, 4, theme_editor_tint(editor.muted_color, 25))
    rl.DrawRectangleRounded(thumb, 0.8, 4, theme_editor_tint(editor.muted_color, 120))
}

theme_editor_destroy :: proc(widget: ^ui.Widget) {
    editor := cast(^Theme_Editor) widget
    theme_editor_clear(editor)
    for key in editor.collapsed {
        delete(key)
    }
    delete(editor.collapsed)
    delete(editor.rows)
    delete(editor.visible_rows)
    delete(editor.current_group)
    delete(editor.title)
    free(editor)
}
