// The theme window: a live preview of the draft beside the list of its color
// roles, and a Generate tab that builds a palette from two seeds. The behaviour
// is in thor/theme_ui.odin.
package thor

import "core:fmt"
import "core:strings"

import "../theme"
import ui "../vendor/loom/loom"

THEME_EDITOR_WIDTH  :: f32(920)
THEME_EDITOR_HEIGHT :: f32(660)
THEME_PREVIEW_WIDTH :: f32(380)

// WCAG contrast a text role needs against the background, and the floor under
// which it is hard to read at all.
@(private = "file")
THEME_CONTRAST_GOOD :: f32(4.5)
@(private = "file")
THEME_CONTRAST_POOR :: f32(3)

Theme_Editor_Tab :: enum {
    Colors,
    Generate,
}

Theme_Editor :: struct {
    tab:             Theme_Editor_Tab,
    file:            string,      // owned; file base of the theme under edit
    saved:           theme.Theme, // owned; the palette on disk, what Revert restores
    generated:       bool,        // the draft came from the generator and has no file
    generated_theme: theme.Theme, // owned; what the generator makes of the seeds
    filter:          [dynamic]u8, // owned; ui.input edits it in place
    focus_filter:    bool,
    filter_id:       ui.Id, // the filter field of the last frame
    selected:        int,   // index into theme.COLORS
    scroll_pending:  bool,
    collapsed:       [theme.Color_Group]bool,
    edit_index:      int,
    edit_original:   ui.Color,
    seed_accent:     bool,
    seed_original:   ui.Color,
    pending:         Theme_Pending,
    note:            string, // owned; the last message, shown in the footer
    note_error:      bool,
    return_focus:    string, // pane key the focus goes back to on close
}

thor_theme_editor_init :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    e.filter = make([dynamic]u8)
    e.collapsed = {.Surfaces = false, .Text = false, .Status = true, .Syntax = false}
}

thor_theme_editor_destroy :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    delete(e.filter)
    delete(e.file)
    delete(e.note)
    theme.destroy(&e.saved)
    theme.destroy(&e.generated_theme)
}

// Whether role `index` matches the filter text, by label, role id or hex.
@(private = "file")
theme_editor_matches :: proc(thor: ^Thor, index: int) -> bool {
    e := &thor.theme_editor
    if len(e.filter) == 0 {
        return true
    }
    query := strings.to_lower(string(e.filter[:]), context.temp_allocator)
    entry := theme.COLORS[index]
    if strings.contains(strings.to_lower(entry.key, context.temp_allocator), query) || strings.contains(entry.role, query) {
        return true
    }
    hex := strings.to_lower(theme.to_hex(theme.color_at(&thor.theme, index)^), context.temp_allocator)
    return strings.contains(hex, query)
}

// The role indices the list shows, in order: a folded group hides its rows
// unless a filter is set.
@(private = "file")
theme_editor_visible :: proc(thor: ^Thor) -> []int {
    e         := &thor.theme_editor
    out       := make([dynamic]int, context.temp_allocator)
    filtering := len(e.filter) > 0
    for entry, i in theme.COLORS {
        if !theme_editor_matches(thor, i) {
            continue
        }
        if !filtering && e.collapsed[entry.group] {
            continue
        }
        append(&out, i)
    }
    return out[:]
}

// Selects role `index` and brings its row into view, unfolding its group and
// clearing a filter that hides it.
@(private = "file")
theme_editor_reveal :: proc(thor: ^Thor, index: int) {
    e := &thor.theme_editor
    if index < 0 || index >= len(theme.COLORS) {
        return
    }
    e.tab = .Colors
    e.selected = index
    e.collapsed[theme.COLORS[index].group] = false
    if !theme_editor_matches(thor, index) {
        clear(&e.filter)
    }
    e.scroll_pending = true
}

// Whether another modal over the window has the keyboard and the pointer.
@(private = "file")
theme_editor_covered :: proc(thor: ^Thor) -> bool {
    return thor.color_picker_open || thor.palette_open || thor.select_open
}

thor_theme_editor_view :: proc(thor: ^Thor) {
    if !thor.theme_editor_open {
        return
    }
    thor_theme_editor_sync(thor)

    backdrop := ui.scope(
        {
            key = "theme-backdrop",
            transition = TK_ENTER,
            enter = {opacity = 0},
            flags = {.Floating, .Clickable},
            props = {
                opacity = 1,
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                z = 440,
                bg = tk_scrim(.Modal),
            },
        },
    )

    theme_editor_box(thor)

    if theme_editor_covered(thor) {
        return
    }
    theme_editor_keys(thor)
    if backdrop.clicked {
        thor_theme_request_close(thor)
    }
}

// The window keys. A bound theme command reaches the window through the
// global keymap first (thor_global_key).
@(private = "file")
theme_editor_keys :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    if ui.take_key(.Escape) {
        if len(e.filter) > 0 {
            clear(&e.filter)
        } else {
            thor_theme_request_close(thor)
        }
        return
    }
    if ui.take_key(.S, {.Ctrl}) {
        thor_cmd_theme_save(thor)
        return
    }
    if ui.take_key(.F, {.Ctrl}) {
        e.tab = .Colors
        e.focus_filter = true
        return
    }
    if e.tab != .Colors {
        return
    }

    visible  := theme_editor_visible(thor)
    position := -1
    for index, i in visible {
        if index == e.selected {
            position = i
        }
    }
    if ui.take_key(.Down) && len(visible) > 0 {
        e.selected = visible[min(position + 1, len(visible) - 1)]
        e.scroll_pending = true
    }
    if ui.take_key(.Up) && len(visible) > 0 {
        e.selected = visible[max(position - 1, 0)]
        e.scroll_pending = true
    }
    if ui.take_key(.Enter) && position >= 0 {
        thor_theme_edit_color(thor, e.selected)
    }
    // The filter field reads its own clipboard keys.
    if filter_focused(thor) {
        return
    }
    if ui.take_key(.C, {.Ctrl}) {
        thor_theme_copy_color(thor, e.selected)
    }
    if ui.take_key(.V, {.Ctrl}) {
        thor_theme_paste_color(thor, e.selected)
    }
    if ui.take_key(.Backspace) || ui.take_key(.Delete) {
        thor_theme_reset_color(thor, e.selected)
    }
}

@(private = "file")
filter_focused :: proc(thor: ^Thor) -> bool {
    n := ui.focused()
    return n != nil && thor.theme_editor.filter_id != 0 && n.id == thor.theme_editor.filter_id
}

@(private = "file")
theme_editor_box :: proc(thor: ^Thor) {
    e := &thor.theme_editor

    ui.scope(
        {
            key = "theme-box",
            transition = TK_ENTER,
            enter = {opacity = 0},
            focus_scope = true,
            flags = {.Clickable},
            props = {
                opacity = 1,
                w = ui.Px(tk(THEME_EDITOR_WIDTH)),
                max_w = ui.viewport().x - 2 * TK_MODAL_MARGIN,
                h = ui.Px(tk(THEME_EDITOR_HEIGHT)),
                max_h = ui.viewport().y - 2 * TK_MODAL_MARGIN,
                dir = .Column,
                bg = thor.theme.background,
                radius = tk_rad(.Modal),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = tk_shadow(thor, .Modal),
            },
        },
    )

    theme_editor_header(thor)
    theme_editor_toolbar(thor)
    {
        ui.scope({key = "body", props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Row}})
        {
            ui.scope(
                {
                    key = "preview-column",
                    flags = {.Clip, .Scroll_Y},
                    props = {
                        position = .Relative,
                        w = ui.Px(tk(THEME_PREVIEW_WIDTH)),
                        min_w = tk(THEME_PREVIEW_WIDTH),
                        h = ui.Grow(1),
                        dir = .Column,
                        gap = tk_gap(.None, .M),
                        pad = tk_pad_all(.L),
                    },
                },
            )
            palette := e.tab == .Generate ? &e.generated_theme : &thor.theme
            ui.label(
                e.tab == .Generate ? "Generated palette" : "Preview — click a part to find its color",
                {key = "preview-title", props = {w = ui.Grow(1), color = thor.theme.muted_color, text_wrap = .Ellipsis}},
            )
            theme_preview(thor, palette)
        }
        ui.leaf({key = "split", props = {w = ui.Px(1), h = ui.Grow(1), bg = thor.theme.border}})
        switch e.tab {
        case .Colors:
            theme_editor_colors(thor)
        case .Generate:
            theme_editor_generate(thor)
        }
    }
    theme_editor_footer(thor)
}

@(private = "file")
theme_editor_header :: proc(thor: ^Thor) {
    e := &thor.theme_editor

    ui.scope(
        {
            key = "header",
            props = {
                w = ui.Grow(1),
                h = ui.FIT,
                dir = .Row,
                align = .Center,
                gap = tk_gap(.M, .None),
                pad = tk_pad(.XL, .M),
                bg = thor.theme.second_background,
                radius = {10, 10, 0, 0},
            },
        },
    )
    thor_icon_label(thor, "palette", thor.theme.accent_color, key = "logo")
    ui.label("Theme", {key = "title", props = {color = thor.theme.foreground, text_wrap = .None}})

    switcher := ui.begin(
        thor_control(
            thor,
            {
                key = "switch",
                flags = {.Clickable},
                props = {
                    w = ui.FIT,
                    h = ui.Px(tk_h(.Control)),
                    dir = .Row,
                    align = .Center,
                    gap = tk_gap(.S, .None),
                    pad = tk_pad(.M, .None),
                    radius = tk_rad(.Popup),
                    bg = thor.theme.buttons,
                    cursor = .Pointer,
                },
                hover = {bg = thor.theme.active},
            },
        ),
    )
    ui.label(thor.theme.name, {key = "name", props = {color = thor.theme.foreground, text_wrap = .None}})
    thor_icon_label(thor, "chevron-down", thor.theme.muted_color, size = 14)
    ui.end()
    thor_tip(thor, switcher.id, "Edit another theme", thor_action_shortcut(thor, "theme_switch"))
    if switcher.clicked {
        thor_cmd_theme_switch(thor)
    }

    state := ""
    if e.generated {
        state = "Generated, not saved"
    } else if !thor.select_open && thor_theme_dirty(thor) {
        state = "Unsaved changes"
    } else if thor_theme_is_user(e.file) && thor_theme_is_shipped(e.file) {
        state = "Changed from shipped"
    } else if thor_theme_is_user(e.file) {
        state = "Your theme"
    } else {
        state = "Shipped"
    }
    dirty := e.generated || (!thor.select_open && thor_theme_dirty(thor))
    if dirty {
        ui.leaf({key = "dot", props = {w = ui.Px(tk(8)), h = ui.Px(tk(8)), radius = tk_rad(.Control), bg = thor.theme.warning_color}})
    }
    ui.label(state, {key = "state", props = {w = ui.Grow(1), color = thor.theme.muted_color, text_wrap = .Ellipsis}})

    close := ui.begin(
        thor_control(
            thor,
            {
                key = "close",
                flags = {.Clickable},
                props = {w = ui.Px(tk(26)), h = ui.Px(tk_h(.Row)), dir = .Row, justify = .Center, align = .Center, radius = tk_rad(.Control), cursor = .Pointer},
                hover = {bg = thor.theme.buttons},
            },
        ),
    )
    thor_icon_label(thor, "x", thor.theme.muted_color)
    ui.end()
    thor_tip(thor, close.id, "Close", "Esc")
    if close.clicked {
        thor_theme_request_close(thor)
    }
}

@(private = "file")
theme_editor_toolbar :: proc(thor: ^Thor) {
    e     := &thor.theme_editor
    dirty := thor_theme_dirty(thor)

    ui.scope(
        {
            key = "toolbar",
            props = {
                w = ui.Grow(1),
                h = ui.FIT,
                dir = .Row,
                align = .Center,
                gap = tk_gap(.S, .None),
                pad = tk_pad(.L, .M),
                border = {width = {b = 1}, color = thor.theme.border},
            },
        },
    )
    if theme_tab(thor, "tab-colors", "Colors", e.tab == .Colors) {
        e.tab = .Colors
    }
    if theme_tab(thor, "tab-generate", "Generate", e.tab == .Generate) {
        e.tab = .Generate
    }
    ui.spacer(ui.Grow(1), {key = "gap"})

    if theme_button(thor, "open", "file-code", "", true, false, "Open the theme file to edit it by hand", "theme_open_file") {
        thor_cmd_theme_open_file(thor)
    }
    if theme_button(thor, "duplicate", "copy", "", true, false, "Duplicate as a new theme", "theme_duplicate") {
        thor_cmd_theme_duplicate(thor)
    }
    user    := thor_theme_is_user(e.file)
    shipped := thor_theme_is_shipped(e.file)
    if user && shipped {
        if theme_button(thor, "reset", "restore", "", !e.generated, false, "Reset to the shipped colors", "theme_reset") {
            thor_theme_reset_shipped(thor)
        }
    } else if user {
        if theme_button(thor, "delete", "trash", "", !e.generated, false, "Delete this theme", "theme_delete") {
            thor_theme_delete(thor)
        }
    }
    if theme_button(thor, "revert", "arrow-back-up", "", dirty, false, "Revert to the saved colors", "theme_revert") {
        thor_theme_revert(thor)
    }
    if theme_button(thor, "save-as", "", "Save As...", true, false, "Save as a new theme", "theme_save_as") {
        thor_cmd_theme_save_as(thor)
    }
    if theme_button(thor, "save", "device-floppy", "Save", dirty, true, "Save to user/themes", "theme_save", "Ctrl+S") {
        thor_cmd_theme_save(thor)
    }
}

// A tab of the toolbar; true when clicked.
@(private = "file")
theme_tab :: proc(thor: ^Thor, key, label: string, active: bool) -> bool {
    it := ui.begin(
        thor_control(
            thor,
            {
                key = key,
                flags = {.Clickable},
                props = {
                    w = ui.FIT,
                    h = ui.Px(tk_h(.Control)),
                    dir = .Row,
                    align = .Center,
                    pad = tk_pad(.L, .None),
                    radius = tk_rad(.Popup),
                    bg = active ? thor.theme.active : {},
                    cursor = .Pointer,
                },
                hover = {bg = active ? thor.theme.active : thor.theme.second_background},
            },
        ),
    )
    ui.label(label, {key = "label", props = {color = active ? thor.theme.foreground : thor.theme.muted_color, text_wrap = .None}})
    ui.end()
    return it.clicked
}

// A toolbar button with an icon, a label or both. `action` names the command,
// so the tooltip shows its chord; `chord` is the window key when it has one.
@(private = "file")
theme_button :: proc(thor: ^Thor, key, icon, label: string, enabled, primary: bool, tip, action: string, chord := "") -> bool {
    bg := primary && enabled ? thor.theme.accent_color : thor.theme.buttons
    fg := primary && enabled ? theme.color_on(thor.theme.accent_color) : thor.theme.foreground
    if !enabled {
        fg = thor.theme.disabled
    }
    it := ui.begin(
        {
            key = key,
            flags = enabled ? {.Clickable} : {},
            props = {
                w = ui.FIT,
                h = ui.Px(tk_h(.Control)),
                dir = .Row,
                align = .Center,
                gap = tk_gap(.S, .None),
                pad = ui.xy(label == "" ? 7 : 12, 0),
                radius = tk_rad(.Popup),
                bg = bg,
                cursor = enabled ? .Pointer : .Default,
            },
            hover = {bg = enabled ? (primary ? thor.theme.accent_color : thor.theme.active) : bg},
        },
    )
    if icon != "" {
        thor_icon_label(thor, icon, fg, size = 15)
    }
    if label != "" {
        ui.label(label, {key = "label", props = {color = fg, text_wrap = .None}})
    }
    ui.end()
    bound := thor_action_shortcut(thor, action)
    thor_tip(thor, it.id, tip, bound != "" ? bound : chord)
    return enabled && it.clicked
}

@(private = "file")
theme_editor_colors :: proc(thor: ^Thor) {
    e := &thor.theme_editor

    ui.scope({key = "colors", props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column}})
    {
        ui.scope(
            {
                key = "filter-row",
                props = {
                    w = ui.Grow(1),
                    h = ui.FIT,
                    dir = .Row,
                    align = .Center,
                    gap = tk_gap(.M, .None),
                    pad = {l = tk_sp(.L), r = tk_sp(.L), t = tk_sp(.M), b = tk_sp(.S)},
                },
            },
        )
        thor_icon_label(thor, "search", thor.theme.muted_color, size = 15)
        it := ui.input(
            &e.filter,
            {
                key = "filter",
                props = {
                    w = ui.Grow(1),
                    bg = thor.theme.contrast,
                    color = thor.theme.foreground,
                    radius = tk_rad(.Popup),
                    border = {width = ui.all(1), color = thor.theme.border},
                },
            },
            "Filter by name, role or hex (Ctrl+F)",
        )
        e.filter_id = it.id
        if e.focus_filter {
            ui.set_focus(it.id)
            e.focus_filter = false
        }
    }

    ui.scope(
        {
            key = "list",
            flags = {.Clip, .Scroll_Y},
            props = {position = .Relative, w = ui.Grow(1), h = ui.Grow(1), dir = .Column, pad = tk_pad(.M, .XS), gap = tk_gap(.None, .XXS)},
        },
    )
    filtering := len(e.filter) > 0
    shown     := 0
    for group in theme.Color_Group {
        count   := 0
        changed := 0
        for entry, i in theme.COLORS {
            if entry.group == group && theme_editor_matches(thor, i) {
                count += 1
                if theme.color_at(&thor.theme, i)^ != theme.color_at(&e.saved, i)^ {
                    changed += 1
                }
            }
        }
        if count == 0 {
            continue
        }
        ui.push_id_int(i64(group))
        theme_group_row(thor, group, count, changed, filtering)
        if filtering || !e.collapsed[group] {
            for entry, i in theme.COLORS {
                if entry.group != group || !theme_editor_matches(thor, i) {
                    continue
                }
                ui.push_id_int(i64(i))
                theme_color_row(thor, i)
                ui.pop_id()
                shown += 1
            }
        }
        ui.pop_id()
    }
    if filtering && shown == 0 {
        ui.label("No role matches the filter", {key = "empty", props = {color = thor.theme.muted_color, pad = tk_pad_all(.L)}})
    }
}

@(private = "file")
theme_group_row :: proc(thor: ^Thor, group: theme.Color_Group, count, changed: int, filtering: bool) {
    e    := &thor.theme_editor
    open := filtering || !e.collapsed[group]
    it   := ui.begin(
        thor_control(
            thor,
            {
                key = "group",
                flags = {.Clickable},
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(tk_h(.Row_Picker)),
                    dir = .Row,
                    align = .Center,
                    gap = tk_gap(.M, .None),
                    pad = tk_pad(.S, .None),
                    margin = {t = tk_sp(.S)},
                    radius = tk_rad(.Popup),
                    cursor = .Pointer,
                },
                hover = {bg = thor.theme.second_background},
            },
        ),
    )
    thor_icon_label(thor, open ? "chevron-down" : "chevron-right", thor.theme.muted_color, size = 14)
    ui.label(theme.GROUP_LABELS[group], {key = "label", props = {color = thor.theme.foreground, text_wrap = .None}})
    detail := fmt.tprintf("%d", count)
    if changed > 0 {
        detail = fmt.tprintf("%d, %d changed", count, changed)
    }
    ui.label(detail, {key = "count", props = {w = ui.Grow(1), color = thor.theme.muted_color, text_wrap = .Ellipsis}})
    ui.end()
    if it.clicked && !filtering {
        e.collapsed[group] = !e.collapsed[group]
    }
}

@(private = "file")
theme_color_row :: proc(thor: ^Thor, index: int) {
    e        := &thor.theme_editor
    entry    := theme.COLORS[index]
    color    := theme.color_at(&thor.theme, index)^
    saved    := theme.color_at(&e.saved, index)^
    changed  := !e.generated && color != saved
    selected := e.selected == index

    it := ui.begin(
        {
            key = "row",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(tk_h(.Row_Form)),
                dir = .Row,
                align = .Center,
                gap = tk_gap(.M, .None),
                pad = {l = tk_h(.Row), r = tk_sp(.M)},
                radius = tk_rad(.Popup),
                bg = selected ? thor.theme.active : {},
                cursor = .Pointer,
            },
            hover = {bg = selected ? thor.theme.active : thor.theme.second_background},
        },
    )
    ui.leaf(
        {
            key = "swatch",
            props = {
                w = ui.Px(tk(30)),
                h = ui.Px(tk_h(.Row_Compact)),
                radius = tk_rad(.Control),
                bg = color,
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
    )
    ui.label(entry.key, {key = "label", props = {color = thor.theme.foreground, text_wrap = .None}})
    ui.label(entry.role, {key = "role", props = {w = ui.Grow(1), color = thor.theme.muted_color, text_wrap = .Ellipsis}})
    if entry.group != .Surfaces {
        theme_contrast_badge(thor, color, thor.theme.background)
    }
    ui.label(theme.to_hex(color), {key = "hex", props = {w = ui.Px(tk(86)), color = thor.theme.muted_color, text_wrap = .None}})
    if changed {
        reset := ui.begin(
            thor_control(
                thor,
                {
                    key = "reset",
                    flags = {.Clickable},
                    props = {
                        w = ui.Px(tk(24)),
                        h = ui.Px(tk_h(.Row)),
                        dir = .Row,
                        justify = .Center,
                        align = .Center,
                        radius = tk_rad(.Control),
                        cursor = .Pointer,
                    },
                    hover = {bg = thor.theme.buttons},
                },
            ),
        )
        thor_icon_label(thor, "arrow-back-up", thor.theme.warning_color, size = 14)
        ui.end()
        thor_tip(
            thor,
            reset.id,
            strings.concatenate({"Reset to the saved color ", theme.to_hex(saved)}, context.temp_allocator),
            thor_action_shortcut(thor, "theme_reset_color"),
        )
        if reset.clicked {
            thor_theme_reset_color(thor, index)
        }
    } else {
        ui.spacer(ui.Px(24), {key = "reset-gap", props = {h = ui.Px(tk_h(.Row))}})
    }
    ui.end()
    thor_tip(thor, it.id, entry.hint)

    if selected && e.scroll_pending && it.rect.h > 0 {
        ui.scroll_to(it.id)
        e.scroll_pending = false
    }
    if it.clicked {
        thor_theme_edit_color(thor, index)
    }
}

// The contrast of `fg` on `bg`: muted when text reads well, the warning color
// under 4.5:1 and the error color under 3:1.
@(private = "file")
theme_contrast_badge :: proc(thor: ^Thor, fg, bg: ui.Color) {
    ratio := theme.color_contrast_ratio(fg, bg)
    color := thor.theme.muted_color
    tip   := "Reads well on the background"
    if ratio < THEME_CONTRAST_POOR {
        color = thor.theme.error_color
        tip = "Hard to read on the background. Text needs 4.5:1"
    } else if ratio < THEME_CONTRAST_GOOD {
        color = thor.theme.warning_color
        tip = "Low contrast on the background. Text needs 4.5:1"
    }
    it := ui.label(
        fmt.tprintf("%.1f:1", ratio),
        {key = "contrast", props = {color = color, text_wrap = .None, pad = tk_pad(.S, .XXS), radius = tk_rad(.Control), bg = thor.theme.second_background}},
    )
    thor_tip(thor, it.id, tip)
}

@(private = "file")
theme_editor_generate :: proc(thor: ^Thor) {
    ui.scope(
        {
            key = "generate",
            flags = {.Clip, .Scroll_Y},
            props = {position = .Relative, w = ui.Grow(1), h = ui.Grow(1), dir = .Column, gap = tk_gap(.None, .L), pad = tk_pad_all(.XL)},
        },
    )
    ui.label(
        "Build a whole palette from a background and an accent color. Text and syntax colors are lifted to a contrast of 4.5:1, so any pair stays readable.",
        {key = "intro", props = {w = ui.Grow(1), color = thor.theme.muted_color, text_wrap = .Words}},
    )

    ui.label("Mode", {key = "mode-title", props = {color = thor.theme.foreground}})
    {
        ui.scope({key = "mode", props = {w = ui.FIT, h = ui.FIT, dir = .Row, gap = tk_gap(.S, .None)}})
        if theme_tab(thor, "dark", "Dark", thor.theme_seed_dark) {
            thor_theme_set_mode(thor, true)
        }
        if theme_tab(thor, "light", "Light", !thor.theme_seed_dark) {
            thor_theme_set_mode(thor, false)
        }
    }

    ui.label("Seeds", {key = "seeds-title", props = {color = thor.theme.foreground}})
    if theme_seed_row(thor, "seed-background", "Background", thor.theme_seed_background) {
        thor_theme_edit_seed(thor, false)
    }
    if theme_seed_row(thor, "seed-accent", "Accent", thor.theme_seed_accent) {
        thor_theme_edit_seed(thor, true)
    }

    {
        ui.scope({key = "actions", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, gap = tk_gap(.M, .None), margin = {t = tk_sp(.M)}}})
        if theme_button(thor, "from-current", "refresh", "Seeds from current theme", true, false, "Take the seeds from the theme on screen", "") {
            thor_reset_theme_seeds(thor)
            thor_theme_generate_refresh(thor)
        }
        if theme_button(thor, "use", "wand", "Use as Draft", true, true, "Edit the generated palette. Save asks for a name", "theme_use_generated") {
            thor_theme_use_generated(thor)
        }
    }
}

// A generator seed: swatch, name and hex. True when clicked.
@(private = "file")
theme_seed_row :: proc(thor: ^Thor, key, label: string, color: ui.Color) -> bool {
    it := ui.begin(
        thor_control(
            thor,
            {
                key = key,
                flags = {.Clickable},
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(tk_h(.Row_Form)),
                    dir = .Row,
                    align = .Center,
                    gap = tk_gap(.M, .None),
                    pad = tk_pad(.M, .None),
                    radius = tk_rad(.Popup),
                    bg = thor.theme.second_background,
                    cursor = .Pointer,
                },
                hover = {bg = thor.theme.active},
            },
        ),
    )
    ui.leaf(
        {
            key = "swatch",
            props = {
                w = ui.Px(tk(30)),
                h = ui.Px(tk_h(.Row_Compact)),
                radius = tk_rad(.Control),
                bg = color,
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
    )
    ui.label(label, {key = "label", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .None}})
    ui.label(theme.to_hex(color), {key = "hex", props = {color = thor.theme.muted_color, text_wrap = .None}})
    ui.end()
    return it.clicked
}

@(private = "file")
theme_editor_footer :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    ui.scope(
        {
            key = "footer",
            props = {
                w = ui.Grow(1),
                h = ui.FIT,
                dir = .Row,
                align = .Center,
                gap = tk_gap(.L, .None),
                pad = tk_pad(.XL, .M),
                bg = thor.theme.second_background,
                radius = {0, 0, 10, 10},
                border = {width = {t = 1}, color = thor.theme.border},
            },
        },
    )
    ui.label(e.note, {key = "note", props = {w = ui.Grow(1), color = e.note_error ? thor.theme.error_color : thor.theme.muted_color, text_wrap = .Ellipsis}})
    hints := e.tab == .Colors ? "Up/Down select · Enter edit · Ctrl+C/V hex · Del reset · Ctrl+S save" : "Ctrl+S save · Esc close"
    ui.label(hints, {key = "hints", props = {color = thor.theme.muted_color, text_wrap = .None}})
}

// One piece of the preview: its text and the role that colors it.
@(private = "file")
Preview_Token :: struct {
    text: string,
    role: string,
}

// The sample code of the preview, one token list per line.
@(private = "file")
PREVIEW_CODE := [?][]Preview_Token{
    {{"// Greets each user in turn.", "comments"}},
    {{"@(private)", "attributes"}},
    {
        {"greet", "functions"},
        {" :: ", "operators"},
        {"proc", "keywords"},
        {"(", "operators"},
        {"name", "parameters"},
        {": ", "operators"},
        {"string", "tags"},
        {") {", "operators"},
    },
    {
        {"    ", "text"},
        {"for", "keywords"},
        {" ", "text"},
        {"i", "variables"},
        {" in ", "keywords"},
        {"0", "numbers"},
        {" ..< ", "operators"},
        {"3", "numbers"},
        {" {", "operators"},
    },
    {
        {"        ", "text"},
        {"fmt", "variables"},
        {".", "operators"},
        {"println", "functions"},
        {"(", "operators"},
        {"\"Hello,\"", "strings"},
        {", ", "operators"},
        {"name", "parameters"},
        {")", "operators"},
    },
    {{"    }", "operators"}},
    {{"}", "operators"}},
}

// The line the preview marks as the current line, and the one with a selection.
@(private = "file")
PREVIEW_CURRENT_LINE :: 3
@(private = "file")
PREVIEW_SELECTED_LINE :: 4

// A small mock of the editor drawn in `p`. Each part names its role, and a
// click on it selects that role's row.
@(private = "file")
theme_preview :: proc(thor: ^Thor, p: ^theme.Theme) {
    ui.scope(
        {
            key = "mock",
            flags = {.Clip},
            props = {w = ui.Grow(1), h = ui.FIT, dir = .Column, radius = tk_rad(.Card), bg = p.background, border = {width = ui.all(1), color = p.border}},
        },
    )

    // Tab strip.
    {
        strip := ui.begin(
            {
                key = "tabs",
                flags = {.Clickable},
                props = {
                    w = ui.Grow(1),
                    h = ui.FIT,
                    dir = .Row,
                    gap = tk_gap(.XXS, .None),
                    pad = {l = tk_sp(.S), t = tk_sp(.S)},
                    bg = p.contrast,
                    radius = {8, 8, 0, 0},
                },
            },
        )
        preview_part(thor, "tab-active", "main.odin", p.foreground, p.background, "background", pad = 12, top_radius = true)
        preview_part(thor, "tab-other", "util.odin", p.muted_color, p.buttons, "buttons", pad = 12, top_radius = true)
        ui.end()
        if strip.clicked {
            theme_editor_reveal(thor, theme.color_index("contrast"))
        }
    }

    // Code.
    {
        code := ui.begin({key = "code", flags = {.Clickable}, props = {w = ui.Grow(1), h = ui.FIT, dir = .Column, pad = tk_pad(.None, .S), bg = p.background}})
        for line, n in PREVIEW_CODE {
            ui.push_id_int(i64(n))
            current := n == PREVIEW_CURRENT_LINE
            row     := ui.begin(
                {
                    key = "line",
                    flags = current ? {.Clickable} : {},
                    props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, pad = {r = tk_sp(.M)}, bg = current ? p.highlight : {}},
                },
            )
            preview_part(thor, "number", fmt.tprintf("%d", n + 1), p.disabled, {}, "disabled", w = 34, align_end = true)
            ui.spacer(ui.Px(12), {key = "gutter", props = {h = ui.Px(1)}})
            for token, k in line {
                ui.push_id_int(i64(k))
                bg := ui.Color{}
                if n == PREVIEW_SELECTED_LINE && token.role == "strings" {
                    bg = p.selection_background
                }
                preview_part(thor, "token", token.text, theme.role_color(p^, token.role), bg, token.role)
                ui.pop_id()
            }
            ui.end()
            if row.clicked {
                theme_editor_reveal(thor, theme.color_index("highlight"))
            }
            ui.pop_id()
        }
        ui.end()
        if code.clicked {
            theme_editor_reveal(thor, theme.color_index("background"))
        }
    }

    // File tree.
    {
        tree := ui.begin(
            {
                key = "tree",
                flags = {.Clickable},
                props = {
                    w = ui.Grow(1),
                    h = ui.FIT,
                    dir = .Column,
                    pad = tk_pad(.M, .XS),
                    gap = {0, 1},
                    bg = p.second_background,
                    border = {width = {t = 1, b = 1}, color = p.border},
                },
            },
        )
        preview_part(thor, "folder", "src", p.foreground, {}, "foreground")
        {
            ui.scope({key = "files", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, gap = tk_gap(.M, .None), pad = {l = tk_sp(.S)}}})
            preview_part(thor, "guide", "", {}, p.tree, "tree", w = 2, grow_h = true)
            {
                ui.scope({key = "names", props = {w = ui.Grow(1), h = ui.FIT, dir = .Column, gap = tk_gap(.None, .XXS)}})
                preview_part(thor, "file", "main.odin", p.primary_text_color, {}, "primary_text")
                preview_part(thor, "changed", "util.odin  M", p.warning_color, {}, "warning")
            }
        }
        {
            ui.scope({key = "more", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, gap = tk_gap(.XL, .None)}})
            preview_part(thor, "submodule", "vendor  S", p.submodule_color, {}, "submodule")
            preview_part(thor, "ignored", "build", p.excluded_files_color, {}, "excluded_files")
        }
        ui.end()
        if tree.clicked {
            theme_editor_reveal(thor, theme.color_index("second_background"))
        }
    }

    // Status chips and text.
    {
        ui.scope(
            {key = "chips", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, gap = tk_gap(.S, .None), pad = {l = tk_sp(.M), r = tk_sp(.M), t = tk_sp(.M)}}},
        )
        preview_chip(thor, "info", "Info", p.info_color, "info")
        preview_chip(thor, "error", "1 error", p.error_color, "error")
        preview_chip(thor, "conflict", "Conflict", p.conflict_color, "conflict")
        preview_chip(thor, "success", "Passed", p.success_color, "success")
    }
    {
        ui.scope({key = "texts", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, gap = tk_gap(.L, .None), pad = tk_pad(.M, .M)}})
        preview_part(thor, "body", "Text", p.text, {}, "text")
        preview_part(thor, "muted", "3 matches", p.muted_color, {}, "muted")
        preview_part(thor, "link", "docs", p.links_color, {}, "links")
        preview_part(thor, "disabled", "Off", p.disabled, {}, "disabled")
        ui.spacer(ui.Grow(1), {key = "gap"})
        preview_part(thor, "toast", "Saved", p.foreground, p.notifications, "notifications", pad = 10)
    }

    // Buttons.
    {
        ui.scope(
            {
                key = "buttons",
                props = {
                    w = ui.Grow(1),
                    h = ui.FIT,
                    dir = .Row,
                    gap = tk_gap(.S, .None),
                    align = .Center,
                    pad = tk_pad(.M, .M),
                    border = {width = {t = 1}, color = p.border},
                },
            },
        )
        preview_part(thor, "cancel", "Cancel", p.foreground, p.buttons, "buttons", pad = 10)
        preview_part(thor, "delete", "Delete", theme.color_on(p.danger_color), p.danger_color, "danger", pad = 10)
        preview_part(thor, "ok", "OK", theme.color_on(p.accent_color), p.accent_color, "accent", pad = 10)
        ui.spacer(ui.Grow(1), {key = "gap"})
        preview_part(thor, "mark", "●", p.accent_secondary_color, {}, "accent_secondary")
    }
}

// A clickable piece of the preview that selects `role`. A `w` fixes its width.
@(private = "file")
preview_part :: proc(
    thor: ^Thor,
    key, text: string,
    fg, bg: ui.Color,
    role: string,
    pad: f32 = 0,
    w: f32 = 0,
    align_end := false,
    grow_h := false,
    top_radius := false,
) -> bool {
    // A label is measured without its trailing spaces, so they are made
    // non-breaking.
    shown, _ := strings.replace_all(text, " ", " ", context.temp_allocator)
    props    := ui.Props{
        color = fg,
        bg = bg,
        text_wrap = .None,
        cursor = .Pointer,
        pad = ui.xy(pad, pad > 0 ? 4 : 0),
        radius = top_radius ? {tk_rad_px(.Popup), tk_rad_px(.Popup), 0, 0} : (bg != {} ? tk_rad(.Control) : {}),
        text_align = align_end ? .End : .Start,
    }
    if w > 0 {
        props.w = ui.Px(w)
    }
    if grow_h {
        props.h = ui.Grow(1)
    }
    it    := ui.label(shown, {key = key, flags = {.Clickable}, props = props})
    index := theme.color_index(role)
    if index >= 0 {
        thor_tip(thor, it.id, theme.COLORS[index].key)
    }
    if it.clicked {
        theme_editor_reveal(thor, index)
    }
    return it.clicked
}

// A status chip: tinted text on a faint fill of its own color.
@(private = "file")
preview_chip :: proc(thor: ^Thor, key, text: string, color: ui.Color, role: string) {
    fill := color
    fill.a = 40
    preview_part(thor, key, text, color, fill, role, pad = 8)
}
