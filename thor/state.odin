package thor

import "../ui"
import "../widgets"

thor_apply_layout_state :: proc(thor: ^Thor) {
    explorer_visible := ui.signal_get(&thor.explorer_visible)
    console_visible := ui.signal_get(&thor.console_visible)

    thor.explorer_panel.visible = explorer_visible
    thor.explorer_splitter.visible = explorer_visible
    thor.explorer_stub_panel.visible = !explorer_visible

    thor.console_splitter.visible = console_visible
    thor.console_panel.visible = console_visible
    thor.console_stub_panel.visible = !console_visible

    thor.explorer_panel.min_size[0] = thor.explorer_width
    thor.console_panel.min_size[1] = thor.console_height

    thor_refresh_file_buttons(thor)
}

thor_refresh_file_buttons :: proc(thor: ^Thor) {
    active_file := ui.signal_get(&thor.active_file)
    thor_style_file_button(thor, thor.file_a_button, active_file == 0)
    thor_style_file_button(thor, thor.file_b_button, active_file == 1)
    thor_style_file_button(thor, thor.file_c_button, active_file == 2)
}

thor_style_file_button :: proc(thor: ^Thor, button: ^widgets.Button, active: bool) {
    if active {
        widgets.button_set_colors(button, thor.theme.background, thor.theme.accent_color, thor.theme.cyan_color, thor.theme.blue_color, thor.theme.border)
        return
    }

    widgets.button_set_colors(button, thor.theme.foreground, thor.theme.active, thor.theme.highlight, thor.theme.buttons, thor.theme.active)
}

thor_status_text :: proc(data: rawptr) -> string {
    thor := cast(^Thor) data

    if ui.signal_get(&thor.explorer_visible) && ui.signal_get(&thor.console_visible) {
        return "Editor ready"
    }
    if ui.signal_get(&thor.explorer_visible) {
        return "Explorer open | Console collapsed"
    }
    if ui.signal_get(&thor.console_visible) {
        return "Explorer collapsed | Console open"
    }

    return "Explorer and console collapsed"
}

thor_console_text :: proc(data: rawptr) -> string {
    thor := cast(^Thor) data

    switch ui.signal_get(&thor.active_file) {
    case 0: return "> editor active\n> type text into the main panel\n> active file: main.odin"
    case 1: return "> theme parser active\n> palette: material_deep_ocean\n> active file: ui/theme.odin"
    case 2: return "> dialog widget ready\n> close button enabled\n> active file: widgets/dialog.odin"
    case: return "> idle"
    }
}

thor_set_active_file :: proc(thor: ^Thor, index: int) {
    ui.signal_set(&thor.active_file, index)
    widgets.editor_set_text(thor.editor, thor_file_text(index))
    thor_refresh_file_buttons(thor)
}

thor_file_text :: proc(index: int) -> string {
    switch index {
    case 0:
        return "package main\n\nmain :: proc() {\n    // Type here.\n}\n"
    case 1:
        return "Theme: material_deep_ocean\n\nBackground: #0F111A\nAccent Color: #84ffff\n"
    case 2:
        return "Dialog widget notes:\n- draggable header\n- close button\n- regular child widgets\n"
    case:
        return ""
    }
}
