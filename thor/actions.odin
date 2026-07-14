package thor

import rl "vendor:raylib"

import "../plugin"
import "../setting"
import "../ui"
import "../widgets"

thor_minimize_window :: proc(_: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    rl.MinimizeWindow()
}

thor_toggle_maximize :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    // IsWindowMaximized() can keep reporting false after MaximizeWindow() on an
    // undecorated window, which left the button stuck (never taking the restore
    // branch) once the window was filling the screen. Track the state ourselves
    // so the toggle is always symmetric.
    if thor.window_maximized {
        rl.RestoreWindow()
    } else {
        rl.MaximizeWindow()
    }
    thor.window_maximized = !thor.window_maximized
}

thor_close_window :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    thor.should_close = true
}

thor_toggle_fullscreen :: proc(_: ^Thor) {
    rl.ToggleBorderlessWindowed()
}

// App-level shortcuts, dispatched before widget focus (see
// ui.context_set_global_key): they work no matter what is focused.
thor_global_key :: proc(data: rawptr, event: ^ui.Event) -> bool {
    thor := cast(^Thor) data

    // Let plugins observe every key press (the interactive tutorial advances
    // here). The chord uses the same display format as thor.keybind so a plugin
    // can compare directly; a plugin normally observes without consuming, so the
    // real action below still runs.
    if chord := setting.keybind_to_string(
        setting.Keybind{key = event.key, ctrl = event.ctrl, shift = event.shift, alt = event.alt},
        context.temp_allocator,
    ); chord != "" {
        if plugin.manager_dispatch_key(&thor.plugins, chord, event.ctrl, event.shift, event.alt) {
            return true
        }
    }

    // The command palette toggle works no matter what is focused.
    if setting.keybind_matches(thor.command_palette_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_toggle_command_palette(thor)
        return true
    }
    // Quick-open (file search) works no matter what is focused, and re-triggers
    // into file mode even if the palette is already open on the command list.
    if setting.keybind_matches(thor.quick_open_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_quick_open(thor)
        return true
    }
    // Find / replace open on ctrl+f / ctrl+r (work regardless of focus).
    if setting.keybind_matches(thor.find_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_open_find(thor, false)
        return true
    }
    if setting.keybind_matches(thor.replace_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_open_find(thor, true)
        return true
    }
    // Go to line opens the palette in line mode regardless of focus.
    if setting.keybind_matches(thor.goto_line_key, event.key, event.ctrl, event.shift, event.alt) {
        widgets.command_palette_open_line(thor.command_palette, &thor.ui_context)
        return true
    }
    // Flip to the previously active file (ctrl+e), like vim's Ctrl-^.
    if setting.keybind_matches(thor.last_file_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_flip_last_file(thor)
        return true
    }

    // While an overlay is open it owns the keyboard (dispatched via focus),
    // so app shortcuts below are suppressed.
    if widgets.command_palette_is_open(thor.command_palette) || widgets.find_replace_is_open(thor.find_replace) {
        return false
    }

    // Fullscreen toggle is a bare key (no ctrl), so it is matched before the
    // ctrl-only guard below.
    if setting.keybind_matches(thor.fullscreen_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_toggle_fullscreen(thor)
        return true
    }
    if setting.keybind_matches(thor.console_toggle_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_toggle_console(thor, nil, nil)
        return true
    }

    // Focus shortcuts: open the target panel if it is collapsed, then move
    // keyboard focus to it.
    if setting.keybind_matches(thor.focus_editor_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_focus_editor(thor)
        return true
    }
    if setting.keybind_matches(thor.focus_explorer_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_focus_explorer(thor)
        return true
    }
    if setting.keybind_matches(thor.focus_terminal_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_focus_terminal(thor)
        return true
    }
    if setting.keybind_matches(thor.trim_whitespace_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_cmd_trim_whitespace(thor)
        return true
    }

    if !event.ctrl || event.alt {
        return false
    }

    #partial switch event.key {
    case .W:
        thor_close_file(thor, ui.signal_get(&thor.active_file))
        return true
    case .PAGE_DOWN:
        thor_cycle_tab(thor, 1)
        return true
    case .PAGE_UP:
        thor_cycle_tab(thor, -1)
        return true
    case .B:
        thor_toggle_explorer(thor, nil, nil)
        return true
    }
    return false
}

// Switches to the file that was active before the current one, if it is still
// open. Because thor_set_active_file records the file being left, pressing the
// flip key twice returns to where you started (a two-file toggle).
thor_flip_last_file :: proc(thor: ^Thor) {
    target := thor.last_active_file
    if target == nil {
        return
    }
    for file, index in thor.open_files {
        if file == target {
            thor_set_active_file(thor, index)
            return
        }
    }
    thor.last_active_file = nil
}

thor_cycle_tab :: proc(thor: ^Thor, direction: int) {
    count := len(thor.open_files)
    if count == 0 {
        return
    }
    active := ui.signal_get(&thor.active_file)
    thor_set_active_file(thor, ((active + direction) % count + count) % count)
}

// Moves keyboard focus to the editor. The editor pane is always present, so no
// panel needs opening.
thor_focus_editor :: proc(thor: ^Thor) {
    thor.ui_context.focused = &thor.editor.widget
}

// Reveals the explorer panel if collapsed, then focuses the file tree so it can
// be driven with the arrow keys.
thor_focus_explorer :: proc(thor: ^Thor) {
    if !ui.signal_get(&thor.explorer_visible) {
        ui.signal_set(&thor.explorer_visible, true)
        thor_apply_layout_state(thor)
    }
    widgets.tree_focus(thor.tree)
    thor.ui_context.focused = &thor.tree.widget
}

// Reveals the console panel if collapsed, then focuses it for command input.
thor_focus_terminal :: proc(thor: ^Thor) {
    if !ui.signal_get(&thor.console_visible) {
        ui.signal_set(&thor.console_visible, true)
        thor_apply_layout_state(thor)
    }
    thor.ui_context.focused = &thor.console.widget
}

thor_toggle_explorer :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    ui.signal_set(&thor.explorer_visible, !ui.signal_get(&thor.explorer_visible))
    thor_apply_layout_state(thor)
}

thor_toggle_console :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    ui.signal_set(&thor.console_visible, !ui.signal_get(&thor.console_visible))
    thor_apply_layout_state(thor)
}

thor_resize_explorer :: proc(data: rawptr, delta: f32) {
    thor := cast(^Thor) data
    thor.explorer_width += delta
    if thor.explorer_width < 160 {
        thor.explorer_width = 160
    }
    if thor.explorer_width > 520 {
        thor.explorer_width = 520
    }
    thor_apply_layout_state(thor)
}

thor_resize_console :: proc(data: rawptr, delta: f32) {
    thor := cast(^Thor) data
    thor.console_height -= delta
    if thor.console_height < 120 {
        thor.console_height = 120
    }
    if thor.console_height > 420 {
        thor.console_height = 420
    }
    thor_apply_layout_state(thor)
}
