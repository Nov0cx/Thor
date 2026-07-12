package thor

import rl "vendor:raylib"

import "../setting"
import "../ui"
import "../widgets"

thor_minimize_window :: proc(_: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    rl.MinimizeWindow()
}

thor_toggle_maximize :: proc(_: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    if rl.IsWindowMaximized() {
        rl.RestoreWindow()
    } else {
        rl.MaximizeWindow()
    }
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

    // The command palette toggle works no matter what is focused.
    if setting.keybind_matches(thor.command_palette_key, event.key, event.ctrl, event.shift, event.alt) {
        thor_toggle_command_palette(thor)
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

thor_cycle_tab :: proc(thor: ^Thor, direction: int) {
    count := len(thor.open_files)
    if count == 0 {
        return
    }
    active := ui.signal_get(&thor.active_file)
    thor_set_active_file(thor, ((active + direction) % count + count) % count)
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
