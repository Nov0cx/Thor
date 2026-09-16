// The whole UI, declared once a frame. Nothing here is retained: Loom keeps the
// nodes, this file only says what they are from the state on `Thor`.
package thor

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../editview"
import "../font"
import "../render"
import "../textedit"
import ui "../vendor/loom/loom"

TITLEBAR_HEIGHT :: 44
STATUSBAR_HEIGHT :: 28
TAB_HEIGHT :: 38
GUTTER_PAD :: 10

// What the status bar shows. A field left zero hides its segment.
Status_Info :: struct {
    branch:        string,
    file_name:     string,
    file_path:     string,
    language:      string,
    line:          int,
    column:        int,
    indent_width:  int,
    indent_spaces: bool,
    zoom:          int,
    line_ending:   string,
    file_open:     bool,
    modified:      bool,
    saving:        bool,
    busy:          bool,
    busy_message:  string,
    message:       string,
    is_error:      bool,
    diagnostic:    string,
    jump_count:    int,
    jump_up:       bool,
    jump_active:   bool,
}

// One editor tab.
Tab_Info :: struct {
    name:     string,
    tooltip:  string,
    modified: bool,
    loading:  bool,
}

// Thor's palette drives Loom's, so a themed control needs no colour of its own.
thor_push_theme :: proc(thor: ^Thor) {
    t := thor.theme
    ui.set_theme(
        ui.Theme {
            name = t.name,
            dark = true,
            bg = t.background,
            surface = t.second_background,
            raised = t.buttons,
            overlay = t.second_background,
            border = t.border,
            divider = t.border,
            text = t.foreground,
            text_muted = t.muted_color,
            text_faint = t.disabled,
            accent = t.accent_color,
            accent_hover = t.accent_secondary_color,
            accent_text = t.background,
            selection = t.selection_background,
            success = t.success_color,
            warning = t.warning_color,
            danger = t.danger_color,
            info = t.info_color,
            scrollbar = t.disabled,
            scrollbar_hover = t.muted_color,
            shadow = t.contrast,
        },
    )
}

thor_frame :: proc(thor: ^Thor) {
    thor_push_theme(thor)
    // Before the tree: a global chord must win over whatever holds the focus.
    thor_frame_shortcuts(thor)

    ui.scope(
        {
            key = "shell",
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                bg = thor.theme.background,
                font = thor.font_ui,
                font_size = f32(thor.config.general.font_size),
                color = thor.theme.foreground,
            },
        },
    )

    thor_titlebar(thor)
    thor_workspace(thor)
    thor_statusbar(thor)
    thor_overlays(thor)

    // A request the frame did not reach (a pane that is not on screen) would
    // otherwise sit and steal the next frame's focus.
    thor.focus_request = ""
}

// Every modal and floating view, in the order they stack. Each returns at once
// when its own state says it is closed.
@(private = "file")
thor_overlays :: proc(thor: ^Thor) {
    thor_git_panel_view(thor)
    thor_settings_view(thor)
    thor_theme_editor_view(thor)
    thor_color_picker_view(thor)
    thor_permission_view(thor)
    thor_select_view(thor)
    thor_find_view(thor)
    thor_palette_view(thor)
    thor_menu_view(thor)
    thor_tip_card_view(thor)
}

// ---- icons -------------------------------------------------------------------

// An icon is a glyph of an icon family, so it draws as ordinary text and needs
// no escape out of the declarative pass. The glyph goes in the temp allocator:
// the node holds the string until the draw, and the frame frees it after.
thor_icon :: proc(name: string) -> (text: string, family: string) {
    owner, code, ok := font.icon_glyph(name)
    if !ok {
        return "", ""
    }
    buffer, width := utf8.encode_rune(code)
    return strings.clone(string(buffer[:width]), context.temp_allocator), owner
}

// Font handle for an icon family. The active pack decides the family per name,
// so the primary handle cannot serve them all; register_family de-duplicates,
// so a repeat call costs a scan over the few families in play.
thor_icon_font :: proc(thor: ^Thor, family: string) -> ui.Font {
    if family == "" || family == font.ICON_FAMILY {
        return thor.font_icons
    }
    return render.register_family(&thor.backend, family)
}

// `key` only matters where two icons are siblings under one node; the default
// keeps every other call site to one word.
thor_icon_label :: proc(
    thor: ^Thor,
    name: string,
    color: ui.Color,
    size: f32 = 16,
    key := "icon",
) {
    text, family := thor_icon(name)
    ui.label(
        text,
        {
            key = key,
            props = {
                color = color,
                font = thor_icon_font(thor, family),
                font_size = size,
                text_wrap = .None,
            },
        },
    )
}

// ---- titlebar ----------------------------------------------------------------

@(private = "file")
MENU_LABELS := [?]string{"File", "Edit", "View", "Git", "Help"}

@(private = "file")
thor_titlebar :: proc(thor: ^Thor) {
    ui.scope(
        {
            key = "titlebar",
            props = {
                w = ui.Grow(1),
                h = ui.Px(TITLEBAR_HEIGHT),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = ui.xy(12, 8),
                bg = thor.theme.second_background,
            },
        },
    )

    for label, i in MENU_LABELS {
        ui.push_id_int(i64(i))
        it := thor_text_button(thor, label, {key = "menu", props = {w = ui.Px(70)}})
        thor_menu_tip(thor, it.id, i)
        ui.pop_id()
        if it.clicked {
            thor.menu_anchor = {it.rect.x, it.rect.y + it.rect.h}
            thor_open_titlebar_menu(thor, i)
        }
    }

    thor_plugin_buttons(thor)
    ui.spacer()
    thor_task_controls(thor)
    thor_update_button(thor)

    if thor_titlebar_button(thor, "minus", "min", tip = "Minimize") {
        thor_minimize_window()
    }
    if thor_titlebar_button(thor, "square", "max", tip = "Maximize or restore") {
        thor_toggle_maximize(thor)
    }
    if thor_titlebar_button(thor, "x", "close", danger = true, tip = "Close the window") {
        thor.should_close = true
    }
}

// The five built-in dropdowns, in MENU_LABELS order.
@(private = "file")
thor_open_titlebar_menu :: proc(thor: ^Thor, index: int) {
    switch index {
    case 0:
        thor_open_file_menu(thor)
    case 1:
        thor_open_edit_menu(thor)
    case 2:
        thor_open_view_menu(thor)
    case 3:
        thor_open_git_menu(thor)
    case 4:
        thor_open_help_menu(thor)
    }
}

// Buttons plugins added, in registration order, just after Help.
@(private = "file")
thor_plugin_buttons :: proc(thor: ^Thor) {
    for pb, index in thor.plugin_buttons {
        ui.push_id_int(i64(index))
        it := thor_text_button(thor, pb.label, {key = "plugin-button"})
        ui.pop_id()
        if it.clicked {
            thor.menu_anchor = {it.rect.x, it.rect.y + it.rect.h}
            if len(pb.entries) > 0 {
                thor_plugin_menu_open(pb)
            } else {
                thor_plugin_button_click(pb)
            }
            return
        }
    }
}

// The task selector, its dropdown and the run button.
@(private = "file")
thor_task_controls :: proc(thor: ^Thor) {
    if thor.workspace_dir == "" {
        return
    }

    if add := thor_text_button(
        thor,
        "+",
        {key = "task-add", props = {w = ui.Px(28), pad = {}}},
    ); add.clicked {
        thor_cmd_add_task(thor)
        return
    } else {
        thor_tip(thor, add.id, "Add a task to the workspace", thor_action_shortcut(thor, "add_task"))
    }

    sel := thor_text_button(
        thor,
        thor_task_selector_label(thor),
        {
            key = "task-select",
            props = {max_w = 220, bg = thor.theme.buttons, text_wrap = .Ellipsis},
            hover = {bg = thor.theme.active},
        },
    )
    thor_task_select_tip(thor, sel.id)
    if sel.clicked {
        thor.menu_anchor = {sel.rect.x, sel.rect.y + sel.rect.h}
        thor_open_tasks_menu(thor)
        return
    }

    run := ui.begin(
        {
            key = "task-run",
            flags = {.Clickable},
            props = {w = ui.Px(28), h = ui.Px(28), justify = .Center, align = .Center, radius = ui.rad(4)},
            hover = {bg = thor.theme.buttons},
        },
    )
    thor_icon_label(thor, "player-play", thor.theme.success_color, 14)
    ui.end()
    thor_tip(thor, run.id, "Run the selected task", thor_action_shortcut(thor, "run_selected_task"))
    if run.clicked {
        thor_click_run_task(thor)
    }
}

// Shown only while an update is found or installing.
@(private = "file")
thor_update_button :: proc(thor: ^Thor) {
    label, icon, shown := thor_update_button_state(thor)
    if !shown {
        return
    }
    it := ui.begin(
        {
            key = "update",
            flags = {.Clickable},
            props = {
                h = ui.Px(28),
                dir = .Row,
                align = .Center,
                gap = {6, 0},
                pad = ui.xy(10, 0),
                radius = ui.rad(4),
                bg = thor.theme.buttons,
            },
            hover = {bg = thor.theme.active},
        },
    )
    thor_icon_label(thor, icon, thor.theme.accent_color, 14)
    ui.label(label, {key = "text", props = {color = thor.theme.foreground, text_wrap = .None}})
    ui.end()
    thor_tip(thor, it.id, "A new version is available. Click to install it")
    if it.clicked {
        thor_click_update(thor)
    }
}

// A flat chrome button. Loom's button fills with the accent and writes its text
// in accent_text, which suits a dialog's confirm and not the titlebar, so the
// fill, the border and the text colour are stated here instead of inherited.
// text_align/text_align_v place the node's own text; justify/align place
// children, which a leaf has none of.
@(private = "file")
thor_text_button :: proc(
    thor: ^Thor,
    label: string,
    el: ui.Element = {},
    loc := #caller_location,
) -> ui.Interaction {
    e := ui.Element {
        text = label,
        flags = {.Clickable},
        props = {
            w = ui.FIT,
            h = ui.Px(28),
            pad = ui.xy(10, 0),
            text_align = .Center,
            text_align_v = .Center,
            radius = ui.rad(4),
            color = thor.theme.foreground,
            cursor = .Pointer,
            text_wrap = .None,
        },
        hover = {bg = thor.theme.buttons},
    }
    ui.merge_element(&e, el, loc)
    return ui.leaf(e, loc)
}

@(private = "file")
thor_titlebar_button :: proc(
    thor: ^Thor,
    icon, key: string,
    danger := false,
    tip := "",
) -> bool {
    hover := danger ? thor.theme.danger_color : thor.theme.buttons
    it := ui.begin(
        {
            key = key,
            flags = {.Clickable},
            props = {
                w = ui.Px(40),
                h = ui.Px(28),
                justify = .Center,
                align = .Center,
                radius = ui.rad(4),
            },
            hover = {bg = hover},
        },
    )
    thor_icon_label(thor, icon, thor.theme.foreground, 14)
    ui.end()
    thor_tip(thor, it.id, tip)
    return it.clicked
}

// ---- workspace ---------------------------------------------------------------

@(private = "file")
thor_workspace :: proc(thor: ^Thor) {
    // No workspace, no panels: the welcome page takes the whole area.
    if thor.workspace_dir == "" {
        thor_welcome_view(thor)
        return
    }

    dock := ui.dockspace("main", {mode = .In_Window}, {props = {w = ui.Grow(1), h = ui.Grow(1)}})
    thor_seed_dock(thor, dock)

    explorer := signal_get(&thor.explorer_visible)
    console := signal_get(&thor.console_visible)

    if ui.panel(dock, EXPLORER_PANEL, &explorer) {
        thor_explorer_view(thor)
        ui.end_panel()
    }
    // The editor holds its place: no dock tab above its own tab strip, and no
    // drag out of the middle of the layout.
    if ui.panel(dock, EDITOR_PANEL, flags = {.No_Tab, .Fixed}) {
        thor_editor_column(thor)
        ui.end_panel()
    }
    if ui.panel(dock, CONSOLE_PANEL, &console) {
        thor_console_panel(thor)
        ui.end_panel()
    }
    if thor_plugin_dock_visible(thor, .Right) && ui.panel(dock, PLUGIN_RIGHT_PANEL) {
        thor_plugin_dock_view(thor, .Right)
        ui.end_panel()
    }
    if thor_plugin_dock_visible(thor, .Bottom) && ui.panel(dock, PLUGIN_BOTTOM_PANEL) {
        thor_plugin_dock_view(thor, .Bottom)
        ui.end_panel()
    }

    // A panel the user closed from its own tab puts the signal back, so the
    // View menu and the keybind agree with what is on screen.
    signal_set(&thor.explorer_visible, explorer)
    signal_set(&thor.console_visible, console)
}

EXPLORER_PANEL :: "Explorer"
EDITOR_PANEL :: "Editor"
CONSOLE_PANEL :: "Terminal"
PLUGIN_RIGHT_PANEL :: "Panels"
PLUGIN_BOTTOM_PANEL :: "Output"

// The starting arrangement. Only once: after this the dock keeps whatever the
// user dragged it into.
@(private = "file")
thor_seed_dock :: proc(thor: ^Thor, dock: ui.Dock_Id) {
    if thor.dock_seeded {
        return
    }
    thor.dock_seeded = true

    left, rest := ui.dock_split(dock, "", .Left, thor.explorer_width / max(ui.viewport().x, 1))
    ui.dock_panel(dock, EXPLORER_PANEL, left)
    ui.dock_panel(dock, EDITOR_PANEL, rest, {.No_Tab, .Fixed})

    _, bottom := ui.dock_split(dock, EDITOR_PANEL, .Bottom, 1 - thor.console_height / max(ui.viewport().y, 1))
    ui.dock_panel(dock, CONSOLE_PANEL, bottom)
}

// The active terminal, or the line that says there is none yet.
@(private = "file")
thor_console_panel :: proc(thor: ^Thor) {
    console := thor_active_console(thor)
    if console == nil {
        ui.label(
            "No terminal",
            {key = "no-terminal", props = {pad = ui.xy(12, 8), color = thor.theme.disabled}},
        )
        return
    }
    thor_console_view(thor, console)
}

@(private = "file")
thor_editor_column :: proc(thor: ^Thor) {
    column := ui.scope({key = "editors", props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column}})
    // A drag released here opens the dropped rows as tabs; thor_tree_drag_out
    // reads the rect after the frame that saw the release.
    thor.editor_rect = column.rect
    thor_tabbar(thor)

    ui.scope({key = "panes", props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Row, gap = {1, 0}}})
    thor_editor_pane(thor, &thor.editor, 0, "pane0")
    if thor.split_visible {
        thor_editor_pane(thor, &thor.editor2, 1, "pane1")
    }
}

// ---- tabs --------------------------------------------------------------------

@(private = "file")
thor_tabbar :: proc(thor: ^Thor) {
    ui.scope(
        {
            key = "tabbar",
            flags = {.Clip},
            props = {
                w = ui.Grow(1),
                h = ui.Px(TAB_HEIGHT),
                dir = .Row,
                align = .Stretch,
                bg = thor.theme.second_background,
            },
        },
    )

    active := signal_get(&thor.active_file)
    select_index := -1
    close_index := -1

    for i in 0 ..< len(thor.open_files) {
        info := thor_tab_info(thor, i)
        on := i == active

        ui.push_id_int(i64(i))
        it := ui.begin(
            {
                key = "tab",
                flags = {.Clickable, .Group},
                props = {
                    h = ui.Grow(1),
                    dir = .Row,
                    align = .Center,
                    gap = {6, 0},
                    pad = ui.xy(12, 0),
                    bg = on ? thor.theme.background : thor.theme.second_background,
                    border = {width = {0, 0, 0, on ? 2 : 0}, color = thor.theme.accent_color},
                },
                hover = {bg = thor.theme.buttons},
            },
        )
        ui.label(
            info.name,
            {
                props = {
                    color = on ? thor.theme.foreground : thor.theme.muted_color,
                    text_wrap = .None,
                },
            },
        )
        if info.modified {
            ui.leaf(
                {
                    key = "dot",
                    props = {
                        w = ui.Px(6),
                        h = ui.Px(6),
                        radius = ui.rad(3),
                        bg = thor.theme.accent_color,
                    },
                },
            )
        }
        close := ui.begin(
            {
                key = "close",
                flags = {.Clickable},
                props = {
                    w = ui.Px(18),
                    h = ui.Px(18),
                    justify = .Center,
                    align = .Center,
                    radius = ui.rad(3),
                },
                hover = {bg = thor.theme.danger_color},
            },
        )
        thor_icon_label(thor, "x", thor.theme.muted_color, 12)
        ui.end()
        ui.end()
        // The close button sits inside the tab, so the tab's own tip would come
        // up over it as well. The inner one wins.
        thor_tip(thor, close.id, "Close Tab")
        if !close.hovered {
            thor_tip(thor, it.id, info.tooltip)
        }
        ui.pop_id()

        // The list is rebuilt below, so a close waits until the loop is done.
        if close.clicked || it.middle_clicked {
            close_index = i
        } else if it.clicked {
            select_index = i
        }
    }

    if close_index >= 0 {
        thor_close_file(thor, close_index)
    } else if select_index >= 0 {
        thor_set_active_file(thor, select_index)
    }
}

// ---- the editor pane ----------------------------------------------------------

@(private = "file")
thor_editor_pane :: proc(thor: ^Thor, editor: ^editview.Editor, pane: int, key: string) {
    // .Scroll_Y is for the scrollbar alone. .Wheel gives the pane the raw delta
    // and moves no offset itself: editview owns scroll_y, and it needs the wheel
    // even at the end of the file, for zoom and for the completion popup.
    it := ui.begin(
        {
            key = key,
            flags = {.Clip, .Clickable, .Focusable, .Draggable, .Scroll_Y, .Wheel},
            // Relative, so it is the containing block of the rows: Loom resolves
            // an absolute inset against the nearest positioned ancestor, which
            // would otherwise be the dock panel above the tab strip.
            props = {
                position = .Relative,
                w = ui.Grow(1),
                h = ui.Grow(1),
                bg = thor.theme.background,
            },
        },
    )
    defer ui.end()

    // A scroll the pane did not push is a drag of the thumb or a click on the
    // track; the editor adopts it before it reads scroll_y again.
    if it.node.scroll.y != editor.scroll_y {
        editor.scroll_y = it.node.scroll.y
    }
    defer ui.set_scroll(it.node, .Y, editor.scroll_y)

    editor.view = it.rect
    editor.focused = it.focused
    editview.editor_sync(editor)

    if it.focused {
        thor.focus_owner = key
    }
    if thor.focus_request == key {
        ui.set_focus(it.id)
        thor.focus_request = ""
    }
    thor_editor_intents(thor, editor, it)

    if editor.state == nil {
        return
    }
    editview.editor_ensure_visual_rows(editor)
    // Here, not in thor_update_files: the rows this frame's keystrokes rebuilt
    // are what the window is scoped to, and the spans are read a few lines below.
    thor_highlight_pane_file(thor, pane)

    line_h := f32(font.line_height(editor.font_size))
    if line_h <= 0 || len(editor.visual_rows) == 0 {
        return
    }

    text := textedit.text(editor.state)
    rows := editor.visual_rows[:]

    // The rows are absolute and out of flow, so this states the document height
    // for Loom: it is what the scrollbar and the scroll clamp are sized from.
    // Zero-width: the pane does not scroll sideways.
    ui.leaf({key = "content", props = {w = ui.Px(0), h = ui.Px(f32(len(rows)) * line_h)}})

    first := clamp(int(editor.scroll_y / line_h), 0, len(rows) - 1)
    last := clamp(first + int(it.rect.h / line_h) + 2, first, len(rows))
    text_x := editor.gutter_width

    thor_paint_gutter(thor, editor, it, rows, first, last, line_h)
    thor_paint_selections(thor, editor, text, rows, first, last, line_h, text_x)
    thor_paint_diagnostics(thor, editor, text, rows, first, last, line_h, text_x)

    for index in first ..< last {
        row := rows[index]
        if row.end > len(text) || row.start > row.end {
            break
        }
        ui.push_id_int(i64(index))
        ui.leaf(
            {
                key = "row",
                text = text[row.start:row.end],
                spans = thor_row_spans(editor, row.start, row.end),
                props = {
                    position = .Absolute,
                    inset = {text_x, f32(index) * line_h - editor.scroll_y, 0, 0},
                    w = ui.FIT,
                    h = ui.Px(line_h),
                    color = thor.theme.foreground,
                    font = thor.font_mono,
                    font_size = f32(editor.font_size),
                    text_wrap = .None,
                    tab_size = thor_tab_px(thor, editor),
                },
            },
        )
        ui.pop_id()

        // On the last visual row of a collapsed start line, a pill stands in for
        // the hidden body.
        if editor.folded[row.line] {
            if _, foldable := editor.foldable[row.line]; foldable {
                tail := index + 1 >= len(rows) || rows[index + 1].line != row.line
                if tail {
                    x := text_x + thor_row_x(editor, text, row.start, row.end)
                    thor_paint_fold_marker(thor, editor, x, f32(index) * line_h - editor.scroll_y)
                }
            }
        }
    }

    thor_paint_carets(thor, editor, text, rows, first, last, line_h, text_x)
}

// The "…" pill that stands in for a collapsed region, just past the end of the
// fold's start-line text.
@(private = "file")
thor_paint_fold_marker :: proc(thor: ^Thor, editor: ^editview.Editor, x, row_y: f32) {
    size := f32(editor.font_size)
    radius := max(size * 0.09, 1.5)
    gap := radius * 3
    box_x := x + 8
    ui.paint_rect(
        {box_x - 5, row_y + size * 0.15, gap * 2 + 10, size * 0.7},
        thor.theme.selection_background,
        ui.rad(size * 0.35),
        true,
    )
    cy := row_y + size * 0.5
    for i in 0 ..< 3 {
        ui.paint_rect(
            {box_x + f32(i) * gap - radius, cy - radius, radius * 2, radius * 2},
            thor.theme.disabled,
            ui.rad(radius),
            true,
        )
    }
}

// Turns one pane's frame interaction into editview intents. Positions are in
// screen space, which is what the editor works in.
@(private = "file")
thor_editor_intents :: proc(thor: ^Thor, editor: ^editview.Editor, it: ui.Interaction) {
    now := rl.GetTime()

    if it.hover_exited {
        editview.editor_leave(editor)
    } else if it.hovered {
        editview.editor_hover(editor, ui.mouse_pos(), ui.mods(), now)
    }
    if it.wheel.y != 0 {
        // Loom counts a wheel down as positive; the editor scrolls by lines.
        editview.editor_wheel(editor, ui.mouse_pos(), -it.wheel.y, ui.mods(), now)
    }
    if it.pressed {
        editview.editor_press(editor, ui.mouse_pos(), .Left, ui.mods(), max(it.click_count, 1))
    }
    if it.right_clicked {
        editview.editor_press(editor, ui.mouse_pos(), .Right, ui.mods(), 1)
    }
    if it.dragging {
        editview.editor_drag(editor, ui.mouse_pos())
    }
    if it.released {
        editview.editor_release(editor)
    }

    if !it.focused {
        return
    }
    for &event in ui.keys() {
        if event.consumed {
            continue
        }
        if editview.editor_key(editor, event) {
            event.consumed = true
        }
    }
    for r in ui.typed_text() {
        editview.editor_text(editor, r, ui.mods())
    }
}

// The syntax spans that fall inside one row, rebased to the row's first byte.
@(private = "file")
thor_row_spans :: proc(editor: ^editview.Editor, start, end: int) -> []ui.Text_Span {
    if len(editor.highlights) == 0 || end <= start {
        return nil
    }
    out := make([dynamic]ui.Text_Span, 0, 16, context.temp_allocator)
    for h in editor.highlights {
        if h.end <= start {
            continue
        }
        if h.start >= end {
            break
        }
        append(
            &out,
            ui.Text_Span {
                start = max(h.start, start) - start,
                end = min(h.end, end) - start,
                color = h.color,
            },
        )
    }
    return out[:]
}

@(private = "file")
thor_tab_px :: proc(thor: ^Thor, editor: ^editview.Editor) -> f32 {
    width := thor.config.general.tab_width
    if width <= 0 {
        width = 4
    }
    return f32(font.measure(" ", editor.font_size, "") * i32(width))
}

@(private = "file")
thor_paint_gutter :: proc(
    thor: ^Thor,
    editor: ^editview.Editor,
    pane: ui.Interaction,
    rows: []editview.Visual_Row,
    first, last: int,
    line_h: f32,
) {
    ui.paint_rect({0, 0, editor.gutter_width, pane.rect.h}, thor.theme.second_background)

    caret_line := textedit.state_line_index(
        editor.state,
        textedit.primary_cursor(editor.state).caret,
    )

    // An expanded region shows its chevron only while the gutter is hovered; a
    // collapsed one always shows one, so a fold is never invisible.
    fold_col := editview.editor_fold_col_width(editor)
    fold_x := editor.gutter_width - fold_col
    mouse := ui.mouse_pos()
    gutter_hovered := pane.hovered && fold_col > 0 &&
        mouse.x >= pane.rect.x && mouse.x - pane.rect.x < editor.gutter_width

    for index in first ..< last {
        row := rows[index]
        y := f32(index) * line_h - editor.scroll_y

        // Diff bar at the outer edge: full height for an added or a modified
        // line, a short strip at the top edge for a deletion, which owns no line.
        if row.line >= 0 && row.line < len(editor.diff_lines) {
            switch editor.diff_lines[row.line] {
            case .Added:
                ui.paint_rect({0, y, 3, line_h}, thor.theme.success_color)
            case .Modified:
                ui.paint_rect({0, y, 3, line_h}, thor.theme.info_color)
            case .Deleted:
                ui.paint_rect({0, y, 6, 4}, thor.theme.danger_color)
            case .None:
            }
        }

        if !row.first {
            continue
        }

        if _, foldable := editor.foldable[row.line]; foldable && fold_col > 0 {
            folded := editor.folded[row.line]
            if folded || gutter_hovered {
                thor_paint_fold_chevron(thor, editor, fold_x, fold_col, y, folded)
            }
        }

        if severity, has := editview.editor_line_diagnostic(editor, row.line); has {
            color := severity == .Error ? thor.theme.error_color : thor.theme.warning_color
            ui.paint_rect({3, y + line_h * 0.5 - 3, 6, 6}, color, ui.rad(3), true)
        }

        on := row.line == caret_line
        // Relative numbering, with the caret's own line showing where it is.
        shown := on ? row.line + 1 : abs(row.line - caret_line)
        label := fmt.tprintf("%d", shown)
        width := f32(font.measure(label, editor.font_size, ""))

        ui.push_id_int(i64(index))
        ui.leaf(
            {
                key = "ln",
                text = label,
                props = {
                    position = .Absolute,
                    // Right-aligned before the fold column, so the digits never
                    // run under a chevron.
                    inset = {fold_x - GUTTER_PAD - width, y, 0, 0},
                    w = ui.FIT,
                    h = ui.Px(line_h),
                    color = on ? thor.theme.foreground : thor.theme.disabled,
                    font = thor.font_mono,
                    font_size = f32(editor.font_size),
                    text_wrap = .None,
                },
            },
        )
        ui.pop_id()
    }
}

// A triangle centred in the fold column: pointing right at the hidden body when
// the region is collapsed, down over the body it can hide when it is expanded.
@(private = "file")
thor_paint_fold_chevron :: proc(
    thor: ^Thor,
    editor: ^editview.Editor,
    col_x, col_w, row_y: f32,
    folded: bool,
) {
    cx := col_x + col_w * 0.5
    cy := row_y + f32(editor.font_size) * 0.5
    s := f32(editor.font_size) * 0.3
    points: [3]ui.Vec2
    if folded {
        points = {{cx - s * 0.5, cy - s}, {cx - s * 0.5, cy + s}, {cx + s * 0.7, cy}}
    } else {
        points = {{cx - s, cy - s * 0.5}, {cx, cy + s * 0.7}, {cx + s, cy - s * 0.5}}
    }
    ui.paint_poly(points[:], thor.theme.disabled)
}

// A squiggle under the part of every diagnostic range that falls on a visible
// row. The x of a byte matches the caret maths, so it tracks the glyphs.
@(private = "file")
thor_paint_diagnostics :: proc(
    thor: ^Thor,
    editor: ^editview.Editor,
    text: string,
    rows: []editview.Visual_Row,
    first, last: int,
    line_h, text_x: f32,
) {
    if len(editor.diagnostics) == 0 {
        return
    }
    for index in first ..< last {
        row := rows[index]
        // Seated just under the glyph box; the row text is top-aligned.
        y := f32(index) * line_h - editor.scroll_y + f32(editor.font_size) - 1
        for d in editor.diagnostics {
            lo := max(d.start, row.start)
            hi := min(d.end, row.end)
            if lo >= hi {
                continue
            }
            x0 := text_x + thor_row_x(editor, text, row.start, lo)
            x1 := text_x + thor_row_x(editor, text, row.start, hi)
            color := d.severity == .Error ? thor.theme.error_color : thor.theme.warning_color
            thor_paint_squiggle(x0, x1, y, color)
        }
    }
}

// A triangle wave from x0 to x1 along `y`.
@(private = "file")
thor_paint_squiggle :: proc(x0, x1, y: f32, color: ui.Color) {
    AMPLITUDE :: f32(2)
    STEP :: f32(2)
    previous := ui.Vec2{x0, y}
    x := x0
    up := true
    for x < x1 {
        next_x := min(x + STEP, x1)
        next_y := up ? y - AMPLITUDE : y
        ui.paint_line(previous, {next_x, next_y}, 1, color)
        previous = {next_x, next_y}
        x = next_x
        up = !up
    }
}

@(private = "file")
thor_paint_selections :: proc(
    thor: ^Thor,
    editor: ^editview.Editor,
    text: string,
    rows: []editview.Visual_Row,
    first, last: int,
    line_h, text_x: f32,
) {
    for cursor in editor.state.cursors {
        lo, hi := cursor.anchor, cursor.caret
        if lo > hi {
            lo, hi = hi, lo
        }
        if lo == hi {
            continue
        }
        for index in first ..< last {
            row := rows[index]
            a := max(lo, row.start)
            b := min(hi, row.end)
            if b <= a {
                continue
            }
            x0 := thor_row_x(editor, text, row.start, a)
            x1 := thor_row_x(editor, text, row.start, b)
            ui.paint_rect(
                {
                    text_x + x0,
                    f32(index) * line_h - editor.scroll_y,
                    max(x1 - x0, 2),
                    f32(editor.font_size),
                },
                thor.theme.selection_background,
            )
        }
    }
}

@(private = "file")
thor_paint_carets :: proc(
    thor: ^Thor,
    editor: ^editview.Editor,
    text: string,
    rows: []editview.Visual_Row,
    first, last: int,
    line_h, text_x: f32,
) {
    if !editor.focused {
        return
    }
    for cursor in editor.state.cursors {
        for index in first ..< last {
            row := rows[index]
            if cursor.caret < row.start || cursor.caret > row.end {
                continue
            }
            x := thor_row_x(editor, text, row.start, cursor.caret)
            ui.paint_rect(
                {
                    text_x + x,
                    f32(index) * line_h - editor.scroll_y,
                    2,
                    f32(editor.font_size),
                },
                thor.theme.accent_color,
                {},
                true,
            )
            break
        }
    }
}

// Pen x of byte `at` inside the row that starts at `row_start`.
@(private = "file")
thor_row_x :: proc(editor: ^editview.Editor, text: string, row_start, at: int) -> f32 {
    if at <= row_start || row_start >= len(text) || at > len(text) {
        return 0
    }
    return f32(font.measure(text[row_start:at], editor.font_size, ""))
}

// ---- status bar --------------------------------------------------------------

// Radians per second of the busy segment's alpha pulse.
@(private = "file")
BUSY_PULSE_RATE :: 4.0

// One status segment: an optional icon, a label, and the hover explanation the
// terse label needs. A clickable segment lights up under the pointer to say so.
@(private = "file")
thor_status_segment :: proc(
    thor: ^Thor,
    key, icon, text: string,
    color: ui.Color,
    tip := "",
    clickable := false,
) -> ui.Interaction {
    // Hoverable, not clickable: a segment that only explains itself still has
    // to be hit-tested, or the tip never comes up.
    e := ui.Element {
        key = key,
        flags = {.Hoverable},
        props = {
            h = ui.Grow(1),
            dir = .Row,
            align = .Center,
            gap = {4, 0},
            color = color,
        },
    }
    if clickable {
        e.flags = {.Clickable}
        e.props.cursor = .Pointer
        e.hover = {color = thor.theme.accent_color}
    }

    it := ui.begin(e)
    if icon != "" {
        thor_icon_label(thor, icon, color, 16)
    }
    if text != "" {
        ui.label(text, {key = "text", props = {text_wrap = .None}})
    }
    ui.end()
    thor_tip(thor, it.id, tip)
    return it
}

@(private = "file")
thor_statusbar :: proc(thor: ^Thor) {
    info := thor_status_info(thor)
    text := thor.theme.foreground
    dim := thor.theme.muted_color

    ui.scope(
        {
            key = "statusbar",
            flags = {.Clip},
            props = {
                w = ui.Grow(1),
                h = ui.Px(STATUSBAR_HEIGHT),
                dir = .Row,
                align = .Stretch,
                gap = {18, 0},
                pad = ui.xy(12, 0),
                bg = thor.theme.second_background,
                color = dim,
            },
        },
    )

    if info.branch != "" {
        thor_status_segment(thor, "branch", "git-branch", info.branch, text, "Git branch of the workspace")
    }
    if info.file_open {
        path := info.file_path != "" ? info.file_path : info.file_name
        thor_status_segment(thor, "file", "file", info.file_name, text, path)

        switch {
        case info.saving:
            thor_status_segment(thor, "save", "device-floppy", "Saving...", dim, "The file is being written to disk")
        case info.modified:
            thor_status_segment(thor, "save", "point", "Unsaved", dim, "The file has changes that are not saved")
        case:
            thor_status_segment(thor, "save", "circle-check", "Saved", dim, "The file agrees with the copy on disk")
        }
    }

    // Analyzer work in flight. The icon pulses, so it reads as ongoing without
    // a rotating spinner.
    if info.busy {
        pulse := 0.5 + 0.5 * math.sin(f32(rl.GetTime()) * BUSY_PULSE_RATE)
        color := dim
        color[3] = u8(140 + 115 * pulse)
        thor_status_segment(thor, "busy", "loader-2", info.busy_message, color, "Language intelligence is working on this file")
    }

    // The relative-line jump being typed, so the count reads back before it runs.
    if info.jump_active {
        jump := fmt.tprintf("Jump %d %s", info.jump_count, info.jump_up ? "up" : "down")
        thor_status_segment(thor, "jump", "", jump, thor.theme.accent_color, "The relative jump you are typing. Enter runs it")
    }

    // Transient notice; errors in red, everything else accented, so it stands
    // out against the segments.
    if info.message != "" {
        color := info.is_error ? thor.theme.danger_color : thor.theme.accent_color
        thor_status_segment(thor, "message", "", info.message, color)
    }

    ui.spacer()

    if !info.file_open {
        return
    }

    thor_status_segment(
        thor,
        "caret",
        "",
        fmt.tprintf("Ln %d, Col %d", info.line, info.column),
        text,
        "Line and column of the caret",
    )
    if info.zoom > 0 {
        thor_status_segment(
            thor,
            "zoom",
            "",
            fmt.tprintf("%d%%", info.zoom),
            dim,
            "Editor zoom, against the font size in the settings",
        )
    }
    if info.line_ending != "" {
        eol := thor_status_segment(
            thor,
            "eol",
            "",
            info.line_ending,
            dim,
            "Line endings on disk. Click to change them",
            clickable = true,
        )
        if eol.clicked {
            thor_toggle_line_ending(thor)
        }
    }
    thor_status_segment(thor, "encoding", "", "UTF-8", dim, "Text encoding of the file")
    if info.indent_width > 0 {
        label := info.indent_spaces ? "Spaces" : "Tab Size"
        thor_status_segment(
            thor,
            "indent",
            "",
            fmt.tprintf("%s: %d", label, info.indent_width),
            dim,
            "Indentation the file is written with",
        )
    }
    if info.language != "" {
        thor_status_segment(
            thor,
            "lang",
            "",
            info.language,
            text,
            "Language of the file, and the syntax it colors with",
        )
    }
}

// ---- shortcuts ---------------------------------------------------------------

// Runs the global key hook over the frame's key stream, before the tree, so a
// chord wins over whatever holds the focus. A taken event is consumed, which
// hides it from the pane and every widget below.
@(private = "file")
thor_frame_shortcuts :: proc(thor: ^Thor) {
    for &event in ui.keys() {
        if event.consumed {
            continue
        }
        if thor_global_key(thor, event) {
            event.consumed = true
        }
    }
}
