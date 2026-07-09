package thor

import rl "vendor:raylib"

import "../ui"
import "../widgets"

thor_build_ui :: proc(thor: ^Thor) {
    thor.root_panel = widgets.panel_create("root-panel", thor.theme.background)
    thor.root_stack = widgets.stack_create("root-stack", .Vertical)
    widgets.stack_set_gap(thor.root_stack, 1)
    widgets.stack_set_padding(thor.root_stack, ui.padding(0))
    widgets.stack_set_background(thor.root_stack, thor.theme.border)

    thor.top_bar = widgets.titlebar_create("top-bar")
    widgets.titlebar_set_gap(thor.top_bar, 8)
    widgets.titlebar_set_padding(thor.top_bar, ui.padding_xy(12, 8))
    widgets.titlebar_set_background(thor.top_bar, thor.theme.buttons)
    thor.top_bar.min_size = rl.Vector2 {0, 44}

    thor.workspace_row = widgets.stack_create("workspace-row", .Horizontal)
    widgets.stack_set_gap(thor.workspace_row, 1)
    widgets.stack_set_padding(thor.workspace_row, ui.padding(0))
    widgets.stack_set_background(thor.workspace_row, thor.theme.border)
    ui.widget_set_grow(&thor.workspace_row.widget, 1)

    thor.explorer_stub_panel = widgets.panel_create("explorer-stub-panel", thor.theme.buttons)
    thor.explorer_stub_panel.min_size = rl.Vector2 {42, 0}
    thor.explorer_stub_stack = widgets.stack_create("explorer-stub-stack", .Vertical)
    widgets.stack_set_gap(thor.explorer_stub_stack, 8)
    widgets.stack_set_padding(thor.explorer_stub_stack, ui.padding(6))
    widgets.stack_set_background(thor.explorer_stub_stack, thor.theme.buttons)
    ui.widget_set_grow(&thor.explorer_stub_stack.widget, 1)

    thor.explorer_panel = widgets.panel_create("explorer-panel", thor.theme.second_background)
    thor.explorer_panel.min_size = rl.Vector2 {thor.explorer_width, 0}
    thor.explorer_stack = widgets.stack_create("explorer-stack", .Vertical)
    widgets.stack_set_gap(thor.explorer_stack, 1)
    widgets.stack_set_padding(thor.explorer_stack, ui.padding(0))
    widgets.stack_set_background(thor.explorer_stack, thor.theme.border)
    ui.widget_set_grow(&thor.explorer_stack.widget, 1)

    thor.explorer_header = widgets.stack_create("explorer-header", .Horizontal)
    widgets.stack_set_gap(thor.explorer_header, 8)
    widgets.stack_set_padding(thor.explorer_header, ui.padding_xy(10, 8))
    widgets.stack_set_background(thor.explorer_header, thor.theme.highlight)
    thor.explorer_header.min_size = rl.Vector2 {0, 40}

    thor.explorer_splitter = widgets.splitter_create("explorer-splitter", .Vertical)
    widgets.splitter_set_on_drag(thor.explorer_splitter, thor_resize_explorer, thor)
    widgets.splitter_set_colors(thor.explorer_splitter, thor.theme.border, thor.theme.highlight, thor.theme.accent_color)

    thor.editor_column = widgets.stack_create("editor-column", .Vertical)
    widgets.stack_set_gap(thor.editor_column, 1)
    widgets.stack_set_padding(thor.editor_column, ui.padding(0))
    widgets.stack_set_background(thor.editor_column, thor.theme.border)
    ui.widget_set_grow(&thor.editor_column.widget, 1)

    thor.tabs_row = widgets.stack_create("tabs-row", .Horizontal)
    widgets.stack_set_gap(thor.tabs_row, 6)
    widgets.stack_set_padding(thor.tabs_row, ui.padding_xy(10, 8))
    widgets.stack_set_background(thor.tabs_row, thor.theme.active)
    thor.tabs_row.min_size = rl.Vector2 {0, 48}

    thor.editor_panel = widgets.panel_create("editor-panel", thor.theme.background)
    ui.widget_set_grow(&thor.editor_panel.widget, 1)

    thor.console_splitter = widgets.splitter_create("console-splitter", .Horizontal)
    widgets.splitter_set_on_drag(thor.console_splitter, thor_resize_console, thor)
    widgets.splitter_set_colors(thor.console_splitter, thor.theme.border, thor.theme.highlight, thor.theme.accent_color)

    thor.console_panel = widgets.panel_create("console-panel", thor.theme.second_background)
    thor.console_panel.min_size = rl.Vector2 {0, thor.console_height}
    thor.console_stack = widgets.stack_create("console-stack", .Vertical)
    widgets.stack_set_gap(thor.console_stack, 1)
    widgets.stack_set_padding(thor.console_stack, ui.padding(0))
    widgets.stack_set_background(thor.console_stack, thor.theme.border)
    ui.widget_set_grow(&thor.console_stack.widget, 1)

    thor.console_header = widgets.stack_create("console-header", .Horizontal)
    widgets.stack_set_gap(thor.console_header, 8)
    widgets.stack_set_padding(thor.console_header, ui.padding_xy(10, 8))
    widgets.stack_set_background(thor.console_header, thor.theme.highlight)
    thor.console_header.min_size = rl.Vector2 {0, 40}

    thor.console_stub_panel = widgets.panel_create("console-stub-panel", thor.theme.buttons)
    thor.console_stub_panel.min_size = rl.Vector2 {0, 38}
    thor.console_stub_stack = widgets.stack_create("console-stub-stack", .Horizontal)
    widgets.stack_set_gap(thor.console_stub_stack, 8)
    widgets.stack_set_padding(thor.console_stub_stack, ui.padding_xy(10, 6))
    widgets.stack_set_background(thor.console_stub_stack, thor.theme.buttons)

    thor.dialog = widgets.dialog_create("floating-dialog", "Floating Dialog", rl.Vector2 {810, 120}, rl.Vector2 {320, 220})
    widgets.dialog_set_colors(thor.dialog, thor.theme.white_black_color, thor.theme.highlight, thor.theme.notifications, thor.theme.border)
    thor.dialog_stack = widgets.stack_create("dialog-stack", .Vertical)
    widgets.stack_set_gap(thor.dialog_stack, 10)
    widgets.stack_set_padding(thor.dialog_stack, ui.padding(0))
    widgets.stack_set_background(thor.dialog_stack, rl.Color {0, 0, 0, 0})
    ui.widget_set_grow(&thor.dialog_stack.widget, 1)

    thor_build_controls(thor)
    thor_build_content(thor)
    thor_connect_tree(thor)
}

thor_build_controls :: proc(thor: ^Thor) {
    thor.menu_file_button = thor_create_menu_button(thor, "menu-file", "File")
    thor.menu_edit_button = thor_create_menu_button(thor, "menu-edit", "Edit")
    thor.menu_view_button = thor_create_menu_button(thor, "menu-view", "View")
    thor.menu_help_button = thor_create_menu_button(thor, "menu-help", "Help")
    thor.explorer_toggle_button = thor_create_icon_button(thor, "explorer-toggle", "<", thor_toggle_explorer)
    thor.explorer_restore_button = thor_create_icon_button(thor, "explorer-restore", ">", thor_toggle_explorer)
    thor.console_toggle_button = thor_create_icon_button(thor, "console-toggle", "v", thor_toggle_console)
    thor.console_restore_button = thor_create_icon_button(thor, "console-restore", "^", thor_toggle_console)
    thor.file_a_button = thor_create_file_button(thor, "file-a", "main.odin", 0)
    thor.file_b_button = thor_create_file_button(thor, "file-b", "ui/theme.odin", 1)
    thor.file_c_button = thor_create_file_button(thor, "file-c", "widgets/dialog.odin", 2)
}

thor_build_content :: proc(thor: ^Thor) {
    top_title := widgets.label_create("top-title", "Thor")
    widgets.label_set_text_color(top_title, thor.theme.accent_color)
    top_title.min_size = rl.Vector2 {70, 28}

    explorer_title := widgets.label_create("explorer-title", "Explorer")
    widgets.label_set_text_color(explorer_title, thor.theme.white_black_color)
    ui.widget_set_grow(&explorer_title.widget, 1)
    explorer_title.min_size = rl.Vector2 {0, 24}

    explorer_files := widgets.label_create("explorer-files", "src\n  main.odin\n  thor/\n  ui/\n  widgets/\nfonts\n  JetBrainsMono-Regular.ttf")
    widgets.label_set_text_color(explorer_files, thor.theme.foreground)
    widgets.label_set_background(explorer_files, thor.theme.second_background)
    widgets.label_set_top_align(explorer_files, true)
    ui.widget_set_grow(&explorer_files.widget, 1)
    explorer_files.min_size = rl.Vector2 {0, 220}

    thor.editor = widgets.editor_create("editor")
    widgets.editor_set_colors(
        thor.editor,
        thor.theme.white_black_color,
        thor.theme.gray_color,
        thor.theme.background,
        thor.theme.second_background,
        thor.theme.border,
        thor.theme.accent_color,
        thor.theme.accent_color,
    )
    ui.widget_set_grow(&thor.editor.widget, 1)

    console_title := widgets.label_create("console-title", "Console")
    widgets.label_set_text_color(console_title, thor.theme.white_black_color)
    ui.widget_set_grow(&console_title.widget, 1)
    console_title.min_size = rl.Vector2 {0, 24}

    thor.console_label = widgets.label_create("console-label", "")
    widgets.label_set_text_color(thor.console_label, thor.theme.green_color)
    widgets.label_set_background(thor.console_label, thor.theme.second_background)
    widgets.label_set_top_align(thor.console_label, true)
    widgets.label_bind_text(thor.console_label, thor_console_text, thor)
    ui.widget_set_grow(&thor.console_label.widget, 1)
    thor.console_label.min_size = rl.Vector2 {0, 110}

    thor.status_label = widgets.label_create("status-label", "")
    widgets.label_set_text_color(thor.status_label, thor.theme.foreground)
    widgets.label_bind_text(thor.status_label, thor_status_text, thor)
    ui.widget_set_grow(&thor.status_label.widget, 1)
    thor.status_label.min_size = rl.Vector2 {0, 28}

    dialog_text := widgets.label_create("dialog-text", "Drag this dialog by its title bar.\n\nType into the editor, scroll it, and close this dialog with the x button.")
    widgets.label_set_text_color(dialog_text, thor.theme.white_black_color)
    widgets.label_set_top_align(dialog_text, true)
    dialog_text.min_size = rl.Vector2 {0, 110}

    dialog_console_button := widgets.button_create("dialog-console-button", "Toggle Console")
    widgets.button_set_colors(dialog_console_button, thor.theme.white_black_color, thor.theme.blue_color, thor.theme.cyan_color, thor.theme.active, thor.theme.border)
    widgets.button_set_on_click(dialog_console_button, thor_toggle_console, thor)
    dialog_console_button.min_size = rl.Vector2 {0, 36}

    widgets.append_child(&thor.top_bar.widget, &top_title.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.menu_file_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.menu_edit_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.menu_view_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.menu_help_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.status_label.widget)

    widgets.append_child(&thor.explorer_stack.widget, &thor.explorer_header.widget)
    widgets.append_child(&thor.explorer_stack.widget, &explorer_files.widget)
    widgets.append_child(&thor.explorer_header.widget, &explorer_title.widget)
    widgets.append_child(&thor.explorer_header.widget, &thor.explorer_toggle_button.widget)

    widgets.append_child(&thor.tabs_row.widget, &thor.file_a_button.widget)
    widgets.append_child(&thor.tabs_row.widget, &thor.file_b_button.widget)
    widgets.append_child(&thor.tabs_row.widget, &thor.file_c_button.widget)

    widgets.append_child(&thor.editor_panel.widget, &thor.editor.widget)

    widgets.append_child(&thor.console_stack.widget, &thor.console_header.widget)
    widgets.append_child(&thor.console_stack.widget, &thor.console_label.widget)
    widgets.append_child(&thor.console_header.widget, &console_title.widget)
    widgets.append_child(&thor.console_header.widget, &thor.console_toggle_button.widget)

    widgets.append_child(&thor.explorer_stub_stack.widget, &thor.explorer_restore_button.widget)
    widgets.append_child(&thor.console_stub_stack.widget, &thor.console_restore_button.widget)

    widgets.append_child(&thor.dialog_stack.widget, &dialog_text.widget)
    widgets.append_child(&thor.dialog_stack.widget, &dialog_console_button.widget)
}

thor_connect_tree :: proc(thor: ^Thor) {
    widgets.append_child(&thor.root_panel.widget, &thor.root_stack.widget)
    widgets.append_child(&thor.root_panel.widget, &thor.dialog.widget)

    widgets.append_child(&thor.root_stack.widget, &thor.top_bar.widget)
    widgets.append_child(&thor.root_stack.widget, &thor.workspace_row.widget)

    widgets.append_child(&thor.workspace_row.widget, &thor.explorer_stub_panel.widget)
    widgets.append_child(&thor.workspace_row.widget, &thor.explorer_panel.widget)
    widgets.append_child(&thor.workspace_row.widget, &thor.explorer_splitter.widget)
    widgets.append_child(&thor.workspace_row.widget, &thor.editor_column.widget)

    widgets.append_child(&thor.explorer_stub_panel.widget, &thor.explorer_stub_stack.widget)
    widgets.append_child(&thor.explorer_panel.widget, &thor.explorer_stack.widget)

    widgets.append_child(&thor.editor_column.widget, &thor.tabs_row.widget)
    widgets.append_child(&thor.editor_column.widget, &thor.editor_panel.widget)
    widgets.append_child(&thor.editor_column.widget, &thor.console_splitter.widget)
    widgets.append_child(&thor.editor_column.widget, &thor.console_panel.widget)
    widgets.append_child(&thor.editor_column.widget, &thor.console_stub_panel.widget)

    widgets.append_child(&thor.console_panel.widget, &thor.console_stack.widget)
    widgets.append_child(&thor.console_stub_panel.widget, &thor.console_stub_stack.widget)

    widgets.append_child(&thor.dialog.widget, &thor.dialog_stack.widget)
}

thor_create_menu_button :: proc(thor: ^Thor, id, text: string) -> ^widgets.Button {
    button := widgets.button_create(id, text)
    widgets.button_set_colors(button, thor.theme.foreground, thor.theme.buttons, thor.theme.highlight, thor.theme.active, thor.theme.buttons)
    widgets.button_set_border_thickness(button, 0)
    button.min_size = rl.Vector2 {70, 28}
    return button
}

thor_create_icon_button :: proc(thor: ^Thor, id, text: string, on_click: widgets.Button_Click_Proc) -> ^widgets.Button {
    button := widgets.button_create(id, text)
    widgets.button_set_colors(button, thor.theme.white_black_color, thor.theme.highlight, thor.theme.blue_color, thor.theme.active, thor.theme.border)
    widgets.button_set_font_size(button, 18)
    widgets.button_set_border_thickness(button, 0)
    widgets.button_set_on_click(button, on_click, thor)
    button.min_size = rl.Vector2 {28, 24}
    return button
}

thor_create_file_button :: proc(thor: ^Thor, id, text: string, index: int) -> ^widgets.Button {
    button := widgets.button_create(id, text)
    widgets.button_set_font_size(button, 17)
    widgets.button_set_border_thickness(button, 0)

    switch index {
    case 0: widgets.button_set_on_click(button, thor_activate_file_a, thor)
    case 1: widgets.button_set_on_click(button, thor_activate_file_b, thor)
    case 2: widgets.button_set_on_click(button, thor_activate_file_c, thor)
    case: widgets.button_set_on_click(button, thor_activate_file_a, thor)
    }

    button.min_size = rl.Vector2 {180, 32}
    return button
}
