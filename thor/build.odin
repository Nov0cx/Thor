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
    thor.dialog.visible = false
    thor.dialog_stack = widgets.stack_create("dialog-stack", .Vertical)
    widgets.stack_set_gap(thor.dialog_stack, 10)
    widgets.stack_set_padding(thor.dialog_stack, ui.padding(0))
    widgets.stack_set_background(thor.dialog_stack, rl.Color {0, 0, 0, 0})
    ui.widget_set_grow(&thor.dialog_stack.widget, 1)

    thor.command_palette = widgets.command_palette_create("command-palette")
    widgets.command_palette_set_colors(
        thor.command_palette,
        thor.theme.second_background,
        thor.theme.accent_color,
        thor.theme.background,
        thor.theme.white_black_color,
        thor.theme.gray_color,
        rl.Color {thor.theme.accent_color.r, thor.theme.accent_color.g, thor.theme.accent_color.b, 40},
        thor.theme.accent_color,
    )
    thor.command_palette.visible = false

    thor.find_replace = widgets.find_replace_create("find-replace")
    widgets.find_replace_set_colors(
        thor.find_replace,
        thor.theme.second_background,
        thor.theme.accent_color,
        thor.theme.background,
        thor.theme.white_black_color,
        thor.theme.gray_color,
        thor.theme.buttons,
        thor.theme.accent_color,
    )
    thor.find_replace.visible = false

    thor.menu = widgets.menu_create("context-menu")
    widgets.menu_set_colors(
        thor.menu,
        thor.theme.second_background,
        thor.theme.accent_color,
        thor.theme.white_black_color,
        thor.theme.gray_color,
        rl.Color {thor.theme.accent_color.r, thor.theme.accent_color.g, thor.theme.accent_color.b, 40},
        thor.theme.border,
    )
    thor.menu.visible = false

    thor_build_controls(thor)
    thor_build_content(thor)
    thor_connect_tree(thor)
}

thor_build_controls :: proc(thor: ^Thor) {
    thor.menu_file_button = thor_create_menu_button(thor, "menu-file", "File")
    thor.menu_edit_button = thor_create_menu_button(thor, "menu-edit", "Edit")
    thor.menu_view_button = thor_create_menu_button(thor, "menu-view", "View")
    thor.menu_help_button = thor_create_menu_button(thor, "menu-help", "Help")
    thor.explorer_toggle_button = thor_create_icon_button(thor, "explorer-toggle", "layout-sidebar-left-collapse", thor_toggle_explorer, thor.theme.highlight)
    thor.explorer_restore_button = thor_create_icon_button(thor, "explorer-restore", "layout-sidebar-left-expand", thor_toggle_explorer, thor.theme.buttons)
    thor.console_toggle_button = thor_create_icon_button(thor, "console-toggle", "layout-bottombar-collapse", thor_toggle_console, thor.theme.highlight)
    thor.console_restore_button = thor_create_icon_button(thor, "console-restore", "layout-bottombar-expand", thor_toggle_console, thor.theme.buttons)
    thor.minimize_button = thor_create_window_button(thor, "window-minimize", "minus", thor_minimize_window, thor.theme.highlight)
    thor.maximize_button = thor_create_window_button(thor, "window-maximize", "square", thor_toggle_maximize, thor.theme.highlight)
    thor.close_button = thor_create_window_button(thor, "window-close", "x", thor_close_window, thor.theme.red_color)
}

thor_build_content :: proc(thor: ^Thor) {
    top_title := widgets.label_create("top-title", "Thor")
    widgets.label_set_text_color(top_title, thor.theme.accent_color)
    top_title.min_size = rl.Vector2 {70, 28}

    // Empty flexible spacer so the titlebar keeps a draggable area on the
    // right of the menu buttons.
    top_spacer := widgets.label_create("top-spacer", "")
    ui.widget_set_grow(&top_spacer.widget, 1)
    top_spacer.min_size = rl.Vector2 {0, 28}

    explorer_title := widgets.label_create("explorer-title", "Explorer")
    widgets.label_set_text_color(explorer_title, thor.theme.white_black_color)
    ui.widget_set_grow(&explorer_title.widget, 1)
    explorer_title.min_size = rl.Vector2 {0, 24}

    thor.tree = widgets.tree_create("explorer-tree", thor.workspace_dir)
    widgets.tree_set_colors(
        thor.tree,
        thor.theme.foreground,
        thor.theme.white_black_color,
        thor.theme.blue_color,
        thor.theme.gray_color,
        thor.theme.tree,                  // hover: subtle row tint
        thor.theme.selection_background,  // selected: stronger overlay
        thor.theme.second_background,
    )
    widgets.tree_set_on_open(thor.tree, thor_tree_open, thor)
    widgets.tree_set_git_colors(
        thor.tree,
        thor.theme.yellow_color, // modified / renamed
        thor.theme.green_color,  // added / untracked
        thor.theme.red_color,    // deleted
        thor.theme.orange_color, // conflict
    )
    widgets.tree_set_git(thor.tree, thor_tree_git_status, thor)
    ui.widget_set_grow(&thor.tree.widget, 1)
    thor.tree.min_size = rl.Vector2 {0, 120}

    thor.tabbar = widgets.tabbar_create("tabbar")
    widgets.tabbar_set_colors(
        thor.tabbar,
        thor.theme.foreground,
        thor.theme.white_black_color,
        thor.theme.active,
        thor.theme.buttons,
        thor.theme.background,
        thor.theme.tree, // hover: subtle row tint
        thor.theme.accent_color,
    )
    widgets.tabbar_set_callbacks(
        thor.tabbar,
        thor_tab_count,
        thor_tab_info,
        thor_tab_active,
        thor_tab_select,
        thor_tab_close,
        thor,
    )
    thor.tabbar.min_size = rl.Vector2 {0, 38}

    thor.editor = widgets.editor_create("editor")
    widgets.editor_set_colors(
        thor.editor,
        thor.theme.white_black_color,
        thor.theme.gray_color,
        thor.theme.background,
        thor.theme.second_background,
        thor.theme.border,
        thor.theme.border,
        thor.theme.accent_color,
    )
    widgets.editor_set_on_save(thor.editor, thor_request_save, thor)
    ui.widget_set_grow(&thor.editor.widget, 1)

    thor.editor2 = widgets.editor_create("editor2")
    widgets.editor_set_colors(
        thor.editor2,
        thor.theme.white_black_color,
        thor.theme.gray_color,
        thor.theme.background,
        thor.theme.second_background,
        thor.theme.border,
        thor.theme.border,
        thor.theme.accent_color,
    )
    widgets.editor_set_on_save(thor.editor2, thor_request_save, thor)
    ui.widget_set_grow(&thor.editor2.widget, 1)
    thor.editor2.visible = false

    // Holds the two editor panes side by side; the splitter between them (only
    // shown while split) drags the divide. Gap 0 so the splitter is the seam.
    thor.editor_split_row = widgets.stack_create("editor-split-row", .Horizontal)
    widgets.stack_set_gap(thor.editor_split_row, 0)
    widgets.stack_set_padding(thor.editor_split_row, ui.padding(0))
    widgets.stack_set_background(thor.editor_split_row, thor.theme.border)
    ui.widget_set_grow(&thor.editor_split_row.widget, 1)

    thor.editor_split_splitter = widgets.splitter_create("editor-split-splitter", .Vertical)
    widgets.splitter_set_on_drag(thor.editor_split_splitter, thor_resize_split, thor)
    widgets.splitter_set_colors(thor.editor_split_splitter, thor.theme.border, thor.theme.highlight, thor.theme.accent_color)
    thor.editor_split_splitter.visible = false

    thor.image_view = widgets.image_view_create("image-view")
    widgets.image_view_set_colors(
        thor.image_view,
        thor.theme.background,
        thor.theme.second_background,
        thor.theme.buttons,
        thor.theme.white_black_color,
    )
    ui.widget_set_grow(&thor.image_view.widget, 1)
    thor.image_view.visible = false

    console_title := widgets.label_create("console-title", "Console")
    widgets.label_set_text_color(console_title, thor.theme.white_black_color)
    ui.widget_set_grow(&console_title.widget, 1)
    console_title.min_size = rl.Vector2 {0, 24}

    thor.console = widgets.console_create("console")
    widgets.console_set_colors(
        thor.console,
        thor.theme.foreground,
        thor.theme.accent_color,
        thor.theme.second_background,
        thor.theme.accent_color,
    )
    ui.widget_set_grow(&thor.console.widget, 1)
    thor.console.min_size = rl.Vector2 {0, 110}

    thor.statusbar = widgets.statusbar_create("statusbar")
    widgets.statusbar_set_colors(
        thor.statusbar,
        thor.theme.foreground,
        thor.theme.gray_color,
        thor.theme.buttons,
        thor.theme.accent_color,
    )
    widgets.statusbar_bind(thor.statusbar, thor_status_info, thor)
    thor.statusbar.min_size = rl.Vector2 {0, 28}

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
    widgets.append_child(&thor.top_bar.widget, &top_spacer.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.minimize_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.maximize_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.close_button.widget)

    widgets.append_child(&thor.explorer_stack.widget, &thor.explorer_header.widget)
    widgets.append_child(&thor.explorer_stack.widget, &thor.tree.widget)
    widgets.append_child(&thor.explorer_header.widget, &explorer_title.widget)
    widgets.append_child(&thor.explorer_header.widget, &thor.explorer_toggle_button.widget)

    widgets.append_child(&thor.editor_panel.widget, &thor.editor_split_row.widget)
    widgets.append_child(&thor.editor_split_row.widget, &thor.editor.widget)
    widgets.append_child(&thor.editor_split_row.widget, &thor.editor_split_splitter.widget)
    widgets.append_child(&thor.editor_split_row.widget, &thor.editor2.widget)
    // Added after the split row so it overlays the editor panes when shown.
    widgets.append_child(&thor.editor_panel.widget, &thor.image_view.widget)

    widgets.append_child(&thor.console_stack.widget, &thor.console_header.widget)
    widgets.append_child(&thor.console_stack.widget, &thor.console.widget)
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
    // Added last so they overlay everything and are hit-tested first.
    widgets.append_child(&thor.root_panel.widget, &thor.command_palette.widget)
    widgets.append_child(&thor.root_panel.widget, &thor.find_replace.widget)
    // The menu is added after the palette so it sits above it (bring_to_front
    // on open keeps whichever overlay opened last on top anyway).
    widgets.append_child(&thor.root_panel.widget, &thor.menu.widget)

    widgets.append_child(&thor.root_stack.widget, &thor.top_bar.widget)
    widgets.append_child(&thor.root_stack.widget, &thor.workspace_row.widget)
    widgets.append_child(&thor.root_stack.widget, &thor.statusbar.widget)

    widgets.append_child(&thor.workspace_row.widget, &thor.explorer_stub_panel.widget)
    widgets.append_child(&thor.workspace_row.widget, &thor.explorer_panel.widget)
    widgets.append_child(&thor.workspace_row.widget, &thor.explorer_splitter.widget)
    widgets.append_child(&thor.workspace_row.widget, &thor.editor_column.widget)

    widgets.append_child(&thor.explorer_stub_panel.widget, &thor.explorer_stub_stack.widget)
    widgets.append_child(&thor.explorer_panel.widget, &thor.explorer_stack.widget)

    widgets.append_child(&thor.editor_column.widget, &thor.tabbar.widget)
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

// Titlebar window controls (minimize/maximize/close): flat, icon-only, and
// only tinted on hover like native captions.
thor_create_window_button :: proc(thor: ^Thor, id, icon: string, on_click: widgets.Button_Click_Proc, hover: rl.Color) -> ^widgets.Button {
    button := widgets.button_create(id, "")
    widgets.button_set_icon(button, icon, 16)
    widgets.button_set_colors(button, thor.theme.foreground, thor.theme.buttons, hover, thor.theme.active, thor.theme.buttons)
    widgets.button_set_border_thickness(button, 0)
    widgets.button_set_on_click(button, on_click, thor)
    button.min_size = rl.Vector2 {40, 28}
    return button
}

// Flat icon-only buttons for panel collapse/restore; the background matches
// the container they sit in so only the hover state reads as a button.
thor_create_icon_button :: proc(thor: ^Thor, id, icon: string, on_click: widgets.Button_Click_Proc, background: rl.Color) -> ^widgets.Button {
    button := widgets.button_create(id, "")
    widgets.button_set_icon(button, icon, 18)
    widgets.button_set_colors(button, thor.theme.foreground, background, thor.theme.active, thor.theme.border, background)
    widgets.button_set_border_thickness(button, 0)
    widgets.button_set_on_click(button, on_click, thor)
    button.min_size = rl.Vector2 {30, 26}
    return button
}
