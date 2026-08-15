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
    widgets.titlebar_set_maximize(
        thor.top_bar,
        thor_window_is_maximized,
        thor_titlebar_toggle_maximize,
        thor,
    )
    thor.top_bar.min_size = rl.Vector2 {0, 44}

    thor.workspace_row = widgets.stack_create("workspace-row", .Horizontal)
    widgets.stack_set_gap(thor.workspace_row, 0)
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
    widgets.stack_set_gap(thor.editor_column, 0)
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
    widgets.stack_set_gap(thor.console_header, 4)
    widgets.stack_set_padding(thor.console_header, ui.padding_xy(6, 4))
    widgets.stack_set_background(thor.console_header, thor.theme.highlight)
    thor.console_header.min_size = rl.Vector2 {0, 34}

    thor.console_stub_panel = widgets.panel_create("console-stub-panel", thor.theme.buttons)
    thor.console_stub_panel.min_size = rl.Vector2 {0, 38}
    thor.console_stub_stack = widgets.stack_create("console-stub-stack", .Horizontal)
    widgets.stack_set_gap(thor.console_stub_stack, 8)
    widgets.stack_set_padding(thor.console_stub_stack, ui.padding_xy(10, 6))
    widgets.stack_set_background(thor.console_stub_stack, thor.theme.buttons)

    // Docks for plugin panels: one column right of the editor, one row under it.
    // Both stay hidden until a plugin shows a panel in them.
    thor.plugin_dock_right = widgets.panel_create("plugin-dock-right", thor.theme.second_background)
    thor.plugin_dock_right.min_size = rl.Vector2 {260, 0}
    thor.plugin_dock_right.visible = false
    thor.plugin_dock_right_stack = widgets.stack_create("plugin-dock-right-stack", .Vertical)
    widgets.stack_set_gap(thor.plugin_dock_right_stack, 1)
    widgets.stack_set_padding(thor.plugin_dock_right_stack, ui.padding(0))
    widgets.stack_set_background(thor.plugin_dock_right_stack, thor.theme.border)
    ui.widget_set_grow(&thor.plugin_dock_right_stack.widget, 1)

    thor.plugin_dock_bottom = widgets.panel_create("plugin-dock-bottom", thor.theme.second_background)
    thor.plugin_dock_bottom.min_size = rl.Vector2 {0, 180}
    thor.plugin_dock_bottom.visible = false
    thor.plugin_dock_bottom_stack = widgets.stack_create("plugin-dock-bottom-stack", .Horizontal)
    widgets.stack_set_gap(thor.plugin_dock_bottom_stack, 1)
    widgets.stack_set_padding(thor.plugin_dock_bottom_stack, ui.padding(0))
    widgets.stack_set_background(thor.plugin_dock_bottom_stack, thor.theme.border)
    ui.widget_set_grow(&thor.plugin_dock_bottom_stack.widget, 1)

    thor.command_palette = widgets.command_palette_create("command-palette")
    widgets.command_palette_set_colors(
        thor.command_palette,
        thor.theme.second_background,
        thor.theme.accent_color,
        thor.theme.background,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        rl.Color {thor.theme.accent_color.r, thor.theme.accent_color.g, thor.theme.accent_color.b, 40},
        thor.theme.accent_color,
    )
    thor.command_palette.visible = false

    thor.select_dialog = widgets.select_dialog_create("select-dialog")
    widgets.select_dialog_set_colors(
        thor.select_dialog,
        thor.theme.second_background,
        thor.theme.accent_color,
        thor.theme.highlight,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        rl.Color {thor.theme.accent_color.r, thor.theme.accent_color.g, thor.theme.accent_color.b, 40},
        thor.theme.accent_color,
    )
    thor.select_dialog.visible = false

    thor.permission_dialog = widgets.permission_dialog_create("permission-dialog")
    widgets.permission_dialog_set_colors(
        thor.permission_dialog,
        thor.theme.second_background,
        thor.theme.border,
        thor.theme.highlight,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        rl.Color {thor.theme.primary_text_color.r, thor.theme.primary_text_color.g, thor.theme.primary_text_color.b, 10},
        thor.theme.accent_color,
    )
    thor.permission_dialog.visible = false

    thor.settings_view = widgets.settings_view_create("settings-view")
    widgets.settings_view_set_colors(
        thor.settings_view,
        thor.theme.second_background,
        thor.theme.highlight,
        thor.theme.highlight,
        thor.theme.background,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        thor.theme.accent_color,
        rl.Color {thor.theme.accent_color.r, thor.theme.accent_color.g, thor.theme.accent_color.b, 40},
    )
    widgets.settings_view_set_status_colors(
        thor.settings_view,
        thor.theme.success_color,
        thor.theme.warning_color,
        thor.theme.error_color,
    )
    widgets.settings_view_set_callbacks(
        thor.settings_view,
        thor_on_setting_number,
        thor_on_setting_choice,
        thor_on_setting_action,
        thor_on_setting_keybind,
        thor_on_settings_scope_change,
        thor_cmd_init_workspace,
        thor,
    )
    thor.settings_view.visible = false

    thor.theme_editor = widgets.theme_editor_create("theme-editor")
    widgets.theme_editor_set_colors(
        thor.theme_editor,
        thor.theme.second_background,
        thor.theme.highlight,
        thor.theme.highlight,
        thor.theme.background,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        thor.theme.accent_color,
        rl.Color {thor.theme.accent_color.r, thor.theme.accent_color.g, thor.theme.accent_color.b, 40},
    )
    widgets.theme_editor_set_callbacks(
        thor.theme_editor, thor_on_theme_editor_color, thor_on_theme_editor_action, thor,
    )
    thor.theme_editor.visible = false

    thor.color_picker = widgets.color_picker_create("color-picker")
    widgets.color_picker_set_colors(
        thor.color_picker,
        thor.theme.second_background,
        thor.theme.highlight,
        thor.theme.highlight,
        thor.theme.background,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        thor.theme.accent_color,
    )
    thor.color_picker.visible = false

    thor.git_view = widgets.git_view_create("git-view")
    widgets.git_view_set_colors(
        thor.git_view,
        thor.theme.second_background,
        thor.theme.highlight,
        thor.theme.highlight,
        thor.theme.background,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        thor.theme.accent_color,
        rl.Color {thor.theme.accent_color.r, thor.theme.accent_color.g, thor.theme.accent_color.b, 40},
        thor.theme.success_color,
        thor.theme.danger_color,
        thor.theme.warning_color,
        thor.theme.conflict_color,
    )
    widgets.git_view_set_callbacks(
        thor.git_view,
        widgets.Git_View_Callbacks {
            on_view_changed = thor_on_git_view_changed,
            on_stage = thor_on_git_stage,
            on_select_file = thor_on_git_select_file,
            on_commit = thor_on_git_commit,
            on_sync = thor_on_git_sync,
            on_select_commit = thor_on_git_select_commit,
            on_load_more = thor_on_git_load_more,
            on_checkout = thor_on_git_checkout,
            on_stash = thor_on_git_stash,
            on_discard = thor_on_git_discard,
            on_config_set = thor_on_git_config_set,
            on_hosting = thor_on_git_hosting,
            on_lfs = thor_on_git_lfs,
        },
        thor,
    )
    widgets.git_view_set_views(thor.git_view, {.Changes, .History, .Branches, .Settings, .Hosting})
    thor.git_view.visible = false

    thor.find_replace = widgets.find_replace_create("find-replace")
    widgets.find_replace_set_colors(
        thor.find_replace,
        thor.theme.second_background,
        thor.theme.accent_color,
        thor.theme.background,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        thor.theme.buttons,
        thor.theme.accent_color,
    )
    thor.find_replace.visible = false

    thor.menu = widgets.menu_create("context-menu")
    widgets.menu_set_colors(
        thor.menu,
        thor.theme.second_background,
        thor.theme.accent_color,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
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
    thor.menu_git_button = thor_create_menu_button(thor, "menu-git", "Git")
    thor.menu_help_button = thor_create_menu_button(thor, "menu-help", "Help")
    thor.explorer_toggle_button = thor_create_icon_button(thor, "explorer-toggle", "layout-sidebar-left-collapse", thor_toggle_explorer, thor.theme.highlight)
    thor.explorer_restore_button = thor_create_icon_button(thor, "explorer-restore", "layout-sidebar-left-expand", thor_toggle_explorer, thor.theme.buttons)
    thor.console_toggle_button = thor_create_icon_button(thor, "console-toggle", "layout-bottombar-collapse", thor_toggle_console, thor.theme.highlight)
    thor.console_restore_button = thor_create_icon_button(thor, "console-restore", "layout-bottombar-expand", thor_toggle_console, thor.theme.buttons)
    thor.update_button = thor_create_update_button(thor)
    thor.tasks_add_button = thor_create_window_button(thor, "tasks-add", "plus", thor_click_add_task, thor.theme.highlight)
    thor.tasks_select_button = thor_create_task_selector(thor)
    thor.tasks_run_button = thor_create_window_button(thor, "tasks-run", "player-play", thor_click_run_task, thor.theme.highlight)
    thor.tasks_run_button.text_color = thor.theme.success_color
    thor.minimize_button = thor_create_window_button(thor, "window-minimize", "minus", thor_minimize_window, thor.theme.highlight)
    thor.maximize_button = thor_create_window_button(thor, "window-maximize", "square", thor_toggle_maximize, thor.theme.highlight)
    thor.close_button = thor_create_window_button(thor, "window-close", "x", thor_close_window, thor.theme.danger_color)

    // The workspace's tasks were loaded before the titlebar existed, so the
    // selector picks up its label here.
    thor_sync_task_selector(thor)
}

thor_build_content :: proc(thor: ^Thor) {
    top_logo := widgets.logo_create("top-logo")
    thor.top_logo_texture = rl.LoadTexture("assets/branding/hammer.png")
    widgets.logo_set_texture(top_logo, thor.top_logo_texture)
    widgets.logo_set_on_click(top_logo, thor_cmd_open_settings_gui, thor)
    top_logo.min_size = rl.Vector2 {40, 28}
    thor.top_logo = top_logo

    // Empty flexible spacer so the titlebar keeps a draggable area on the
    // right of the menu buttons.
    top_spacer := widgets.label_create("top-spacer", "")
    ui.widget_set_grow(&top_spacer.widget, 1)
    top_spacer.min_size = rl.Vector2 {0, 28}

    explorer_title := widgets.label_create("explorer-title", "Explorer")
    widgets.label_set_text_color(explorer_title, thor.theme.primary_text_color)
    ui.widget_set_grow(&explorer_title.widget, 1)
    explorer_title.min_size = rl.Vector2 {0, 24}
    thor.explorer_title_label = explorer_title

    thor.tree = widgets.tree_create("explorer-tree", thor.workspace_dir)
    widgets.tree_set_colors(
        thor.tree,
        thor.theme.foreground,
        thor.theme.primary_text_color,
        thor.theme.info_color,
        thor.theme.muted_color,
        thor.theme.tree,                  // hover: subtle row tint
        thor.theme.selection_background,  // selected: stronger overlay
        thor.theme.second_background,
        thor.theme.highlight,
    )
    widgets.tree_set_error_color(thor.tree, thor.theme.error_color)
    widgets.tree_set_on_open(thor.tree, thor_tree_open, thor)
    widgets.tree_set_git_colors(
        thor.tree,
        thor.theme.warning_color, // modified / renamed
        thor.theme.success_color,  // added / untracked
        thor.theme.danger_color,    // deleted
        thor.theme.conflict_color, // conflict
        thor.theme.submodule_color, // submodule
    )
    widgets.tree_set_git(thor.tree, thor_tree_git_status, thor)
    ui.widget_set_grow(&thor.tree.widget, 1)
    thor.tree.min_size = rl.Vector2 {0, 120}

    thor.tabbar = widgets.tabbar_create("tabbar")
    widgets.tabbar_set_colors(
        thor.tabbar,
        thor.theme.foreground,
        thor.theme.primary_text_color,
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
        thor.theme.text,
        thor.theme.muted_color,
        thor.theme.background,
        thor.theme.second_background,
        thor.theme.border,
        thor.theme.border,
        thor.theme.accent_color,
    )
    widgets.editor_set_diagnostic_colors(thor.editor, thor.theme.error_color, thor.theme.warning_color)
    widgets.editor_set_on_save(thor.editor, thor_request_save, thor)
    widgets.editor_set_on_goto_definition(thor.editor, thor_editor_goto_definition, thor)
    widgets.editor_set_on_hover(thor.editor, thor_editor_hover, thor)
    widgets.editor_set_on_signature(thor.editor, thor_editor_signature_help, thor)
    widgets.editor_set_on_completion(thor.editor, thor_editor_completion, thor)
    widgets.editor_set_on_type(thor.editor, thor_editor_on_type, thor)
    ui.widget_set_grow(&thor.editor.widget, 1)

    thor.editor2 = widgets.editor_create("editor2")
    widgets.editor_set_colors(
        thor.editor2,
        thor.theme.text,
        thor.theme.muted_color,
        thor.theme.background,
        thor.theme.second_background,
        thor.theme.border,
        thor.theme.border,
        thor.theme.accent_color,
    )
    widgets.editor_set_diagnostic_colors(thor.editor2, thor.theme.error_color, thor.theme.warning_color)
    widgets.editor_set_on_save(thor.editor2, thor_request_save, thor)
    widgets.editor_set_on_goto_definition(thor.editor2, thor_editor_goto_definition, thor)
    widgets.editor_set_on_hover(thor.editor2, thor_editor_hover, thor)
    widgets.editor_set_on_signature(thor.editor2, thor_editor_signature_help, thor)
    widgets.editor_set_on_completion(thor.editor2, thor_editor_completion, thor)
    widgets.editor_set_on_type(thor.editor2, thor_editor_on_type, thor)
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
        thor.theme.primary_text_color,
    )
    ui.widget_set_grow(&thor.image_view.widget, 1)
    thor.image_view.visible = false

    thor.model_view = widgets.model_view_create("model-view")
    widgets.model_view_set_colors(
        thor.model_view,
        thor.theme.background,
        thor.theme.second_background,
        thor.theme.buttons,
        thor.theme.primary_text_color,
        thor.theme.second_background,
        thor.theme.highlight,
        thor.theme.accent_color,
    )
    ui.widget_set_grow(&thor.model_view.widget, 1)
    thor.model_view.visible = false

    // Overlays the editor panel while no workspace is open (thor_update_editor_view).
    thor.welcome_panel = widgets.panel_create("welcome-panel", thor.theme.background)
    thor.welcome_panel.visible = false

    welcome_row := widgets.stack_create("welcome-row", .Horizontal)
    widgets.stack_set_gap(welcome_row, 0)
    widgets.stack_set_padding(welcome_row, ui.padding(0))
    widgets.stack_set_background(welcome_row, rl.Color {0, 0, 0, 0})
    ui.widget_set_grow(&welcome_row.widget, 1)

    welcome_left_spacer := widgets.label_create("welcome-left-spacer", "")
    ui.widget_set_grow(&welcome_left_spacer.widget, 1)
    welcome_left_spacer.min_size = rl.Vector2 {0, 0}

    welcome_right_spacer := widgets.label_create("welcome-right-spacer", "")
    ui.widget_set_grow(&welcome_right_spacer.widget, 1)
    welcome_right_spacer.min_size = rl.Vector2 {0, 0}

    welcome_col := widgets.stack_create("welcome-col", .Vertical)
    widgets.stack_set_gap(welcome_col, 12)
    widgets.stack_set_padding(welcome_col, ui.padding(32))
    widgets.stack_set_background(welcome_col, rl.Color {0, 0, 0, 0})
    welcome_col.min_size = rl.Vector2 {440, 0}

    welcome_top_spacer := widgets.label_create("welcome-top-spacer", "")
    ui.widget_set_grow(&welcome_top_spacer.widget, 1)
    welcome_top_spacer.min_size = rl.Vector2 {0, 0}

    welcome_bottom_spacer := widgets.label_create("welcome-bottom-spacer", "")
    ui.widget_set_grow(&welcome_bottom_spacer.widget, 1)
    welcome_bottom_spacer.min_size = rl.Vector2 {0, 0}

    // The column stretches every child to its full width, so the hero centers
    // itself rather than sitting against the left edge.
    welcome_logo := widgets.logo_create("welcome-logo")
    widgets.logo_set_texture(welcome_logo, thor.top_logo_texture)
    widgets.logo_set_align(welcome_logo, .Center)
    welcome_logo.min_size = rl.Vector2 {96, 96}
    welcome_logo.padding = ui.padding(0)

    welcome_title := widgets.label_create("welcome-title", "Thor")
    widgets.label_set_align(welcome_title, .Center)
    welcome_title.font_size = 28
    welcome_title.min_size = rl.Vector2 {0, 36}
    thor.welcome_title_label = welcome_title

    welcome_subtitle := widgets.label_create("welcome-subtitle", "No workspace open")
    widgets.label_set_align(welcome_subtitle, .Center)
    welcome_subtitle.min_size = rl.Vector2 {0, 28}
    thor.welcome_subtitle_label = welcome_subtitle

    welcome_open_folder := widgets.button_create("welcome-open-folder", "Open Folder")
    widgets.button_set_on_click(welcome_open_folder, thor_welcome_open_folder, thor)
    welcome_open_folder.min_size = rl.Vector2 {0, 40}
    thor.welcome_open_folder_button = welcome_open_folder

    welcome_open_file := widgets.button_create("welcome-open-file", "Open File")
    widgets.button_set_on_click(welcome_open_file, thor_welcome_open_file, thor)
    welcome_open_file.min_size = rl.Vector2 {0, 40}
    thor.welcome_open_file_button = welcome_open_file

    thor.welcome_tip_card = widgets.tip_card_create("welcome-tip")
    widgets.tip_card_set_colors(
        thor.welcome_tip_card,
        thor.theme.second_background,
        thor.theme.border,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        thor.theme.accent_color,
    )
    widgets.tip_card_set_on_step(thor.welcome_tip_card, thor_tip_card_step, thor)
    // A starting height only; the card measures its own text on every layout.
    thor.welcome_tip_card.min_size = rl.Vector2 {0, 150}

    // The same card floating in the corner of the editor area, for the start of
    // a day with a workspace open — the welcome page above is not shown then.
    thor.startup_tip_card = widgets.tip_card_create("startup-tip")
    widgets.tip_card_set_colors(
        thor.startup_tip_card,
        thor.theme.second_background,
        thor.theme.border,
        thor.theme.primary_text_color,
        thor.theme.muted_color,
        thor.theme.accent_color,
    )
    widgets.tip_card_set_float(thor.startup_tip_card, 380)
    widgets.tip_card_set_on_step(thor.startup_tip_card, thor_tip_card_step, thor)
    widgets.tip_card_set_on_close(thor.startup_tip_card, thor_tip_card_close, thor)
    thor.startup_tip_card.visible = false

    // Section heading, so it stays left-aligned but flush with the button edges
    // rather than indented by the default label padding.
    welcome_recent_label := widgets.label_create("welcome-recent-label", "Recent")
    welcome_recent_label.padding = ui.padding_xy(0, 10)
    welcome_recent_label.min_size = rl.Vector2 {0, 24}
    thor.welcome_recent_label = welcome_recent_label

    thor.welcome_recent_stack = widgets.stack_create("welcome-recent-stack", .Vertical)
    widgets.stack_set_gap(thor.welcome_recent_stack, WELCOME_RECENT_GAP)
    widgets.stack_set_padding(thor.welcome_recent_stack, ui.padding(0))
    widgets.stack_set_background(thor.welcome_recent_stack, rl.Color {0, 0, 0, 0})

    widgets.append_child(&welcome_col.widget, &welcome_top_spacer.widget)
    widgets.append_child(&welcome_col.widget, &welcome_logo.widget)
    widgets.append_child(&welcome_col.widget, &welcome_title.widget)
    widgets.append_child(&welcome_col.widget, &welcome_subtitle.widget)
    widgets.append_child(&welcome_col.widget, &thor.welcome_tip_card.widget)
    widgets.append_child(&welcome_col.widget, &welcome_open_folder.widget)
    widgets.append_child(&welcome_col.widget, &welcome_open_file.widget)
    widgets.append_child(&welcome_col.widget, &welcome_recent_label.widget)
    widgets.append_child(&welcome_col.widget, &thor.welcome_recent_stack.widget)
    widgets.append_child(&welcome_col.widget, &welcome_bottom_spacer.widget)

    widgets.append_child(&welcome_row.widget, &welcome_left_spacer.widget)
    widgets.append_child(&welcome_row.widget, &welcome_col.widget)
    widgets.append_child(&welcome_row.widget, &welcome_right_spacer.widget)

    widgets.append_child(&thor.welcome_panel.widget, &welcome_row.widget)
    thor_welcome_refresh_recent(thor)
    thor_theme_welcome(thor)
    thor_refresh_tip_cards(thor)

    thor.markdown_view = widgets.markdown_view_create("markdown-view")
    widgets.markdown_view_set_colors(thor.markdown_view, thor.theme)
    widgets.markdown_view_set_on_link(thor.markdown_view, thor_markdown_open_link, thor)
    thor.markdown_view.visible = false

    // Pane 1's counterpart, shown when the preview takes the second pane instead.
    thor.markdown_view2 = widgets.markdown_view_create("markdown-view2")
    widgets.markdown_view_set_colors(thor.markdown_view2, thor.theme)
    widgets.markdown_view_set_on_link(thor.markdown_view2, thor_markdown_open_link, thor)
    thor.markdown_view2.visible = false

    // One tab per terminal; each terminal adds its own console widget to the
    // console stack when it opens. The strip carries its own add button.
    thor.terminal_tabs = widgets.tabstrip_create("terminal-tabs")
    widgets.tabstrip_set_callbacks(
        thor.terminal_tabs,
        thor_terminal_tab_count,
        thor_terminal_tab_info,
        thor_terminal_tab_active,
        thor_terminal_tab_select,
        thor_terminal_tab_close,
        thor_terminal_tab_add,
        thor,
    )
    thor_theme_terminal_tabs(thor)
    thor.terminal_tabs.min_size = rl.Vector2 {0, 26}
    ui.widget_set_grow(&thor.terminal_tabs.widget, 1)

    thor.statusbar = widgets.statusbar_create("statusbar")
    widgets.statusbar_set_colors(
        thor.statusbar,
        thor.theme.foreground,
        thor.theme.muted_color,
        thor.theme.buttons,
        thor.theme.accent_color,
        thor.theme.error_color,
    )
    widgets.statusbar_bind(thor.statusbar, thor_status_info, thor)
    widgets.statusbar_set_on_line_ending(thor.statusbar, thor_toggle_line_ending, thor)
    thor.statusbar.min_size = rl.Vector2 {0, 28}

    widgets.append_child(&thor.top_bar.widget, &top_logo.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.menu_file_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.menu_edit_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.menu_view_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.menu_git_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.menu_help_button.widget)
    widgets.append_child(&thor.top_bar.widget, &top_spacer.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.update_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.tasks_add_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.tasks_select_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.tasks_run_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.minimize_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.maximize_button.widget)
    widgets.append_child(&thor.top_bar.widget, &thor.close_button.widget)

    widgets.append_child(&thor.explorer_stack.widget, &thor.explorer_header.widget)
    widgets.append_child(&thor.explorer_stack.widget, &thor.tree.widget)
    widgets.append_child(&thor.explorer_header.widget, &explorer_title.widget)
    widgets.append_child(&thor.explorer_header.widget, &thor.explorer_toggle_button.widget)

    widgets.append_child(&thor.editor_panel.widget, &thor.editor_split_row.widget)
    // Each pane's editor sits beside its markdown-preview counterpart; only one
    // of the pair is visible at a time (thor_update_editor_view), so whichever
    // one is showing occupies that pane's slot in the row.
    widgets.append_child(&thor.editor_split_row.widget, &thor.editor.widget)
    widgets.append_child(&thor.editor_split_row.widget, &thor.markdown_view.widget)
    widgets.append_child(&thor.editor_split_row.widget, &thor.editor_split_splitter.widget)
    widgets.append_child(&thor.editor_split_row.widget, &thor.editor2.widget)
    widgets.append_child(&thor.editor_split_row.widget, &thor.markdown_view2.widget)
    // Added after the split row so they overlay both panes when shown.
    widgets.append_child(&thor.editor_panel.widget, &thor.image_view.widget)
    widgets.append_child(&thor.editor_panel.widget, &thor.model_view.widget)
    widgets.append_child(&thor.editor_panel.widget, &thor.welcome_panel.widget)
    // Last, so the floating tip is over the panes and is hit-tested before them.
    widgets.append_child(&thor.editor_panel.widget, &thor.startup_tip_card.widget)

    widgets.append_child(&thor.console_stack.widget, &thor.console_header.widget)
    widgets.append_child(&thor.console_header.widget, &thor.terminal_tabs.widget)
    widgets.append_child(&thor.console_header.widget, &thor.console_toggle_button.widget)

    widgets.append_child(&thor.explorer_stub_stack.widget, &thor.explorer_restore_button.widget)
    widgets.append_child(&thor.console_stub_stack.widget, &thor.console_restore_button.widget)
}

thor_connect_tree :: proc(thor: ^Thor) {
    widgets.append_child(&thor.root_panel.widget, &thor.root_stack.widget)
    // Added last so they overlay everything and are hit-tested first.
    widgets.append_child(&thor.root_panel.widget, &thor.command_palette.widget)
    widgets.append_child(&thor.root_panel.widget, &thor.select_dialog.widget)
    widgets.append_child(&thor.root_panel.widget, &thor.permission_dialog.widget)
    widgets.append_child(&thor.root_panel.widget, &thor.settings_view.widget)
    // After the settings view, and the picker after the theme window: each opens
    // from the one before it and has to sit above it.
    widgets.append_child(&thor.root_panel.widget, &thor.theme_editor.widget)
    widgets.append_child(&thor.root_panel.widget, &thor.color_picker.widget)
    widgets.append_child(&thor.root_panel.widget, &thor.git_view.widget)
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
    widgets.append_child(&thor.workspace_row.widget, &thor.plugin_dock_right.widget)
    widgets.append_child(&thor.plugin_dock_right.widget, &thor.plugin_dock_right_stack.widget)

    widgets.append_child(&thor.explorer_stub_panel.widget, &thor.explorer_stub_stack.widget)
    widgets.append_child(&thor.explorer_panel.widget, &thor.explorer_stack.widget)

    widgets.append_child(&thor.editor_column.widget, &thor.tabbar.widget)
    widgets.append_child(&thor.editor_column.widget, &thor.editor_panel.widget)
    widgets.append_child(&thor.editor_column.widget, &thor.console_splitter.widget)
    widgets.append_child(&thor.editor_column.widget, &thor.console_panel.widget)
    widgets.append_child(&thor.editor_column.widget, &thor.console_stub_panel.widget)
    widgets.append_child(&thor.editor_column.widget, &thor.plugin_dock_bottom.widget)
    widgets.append_child(&thor.plugin_dock_bottom.widget, &thor.plugin_dock_bottom_stack.widget)

    widgets.append_child(&thor.console_panel.widget, &thor.console_stack.widget)
    widgets.append_child(&thor.console_stub_panel.widget, &thor.console_stub_stack.widget)
}

thor_create_menu_button :: proc(thor: ^Thor, id, text: string) -> ^widgets.Button {
    button := widgets.button_create(id, text)
    thor_theme_menu_button(thor, button)
    button.min_size = rl.Vector2 {70, 28}
    return button
}

// Titlebar window controls (minimize/maximize/close): flat, icon-only, and
// only tinted on hover like native captions.
thor_create_window_button :: proc(thor: ^Thor, id, icon: string, on_click: widgets.Button_Click_Proc, hover: rl.Color) -> ^widgets.Button {
    button := widgets.button_create(id, "")
    widgets.button_set_icon(button, icon, 16)
    thor_theme_window_button(thor, button, hover)
    widgets.button_set_on_click(button, on_click, thor)
    button.min_size = rl.Vector2 {40, 28}
    return button
}

// Titlebar task selector: the active task's name plus a dropdown chevron,
// styled like the menu buttons. Its width follows the label, see
// thor_sync_task_selector.
thor_create_task_selector :: proc(thor: ^Thor) -> ^widgets.Button {
    button := widgets.button_create("tasks-select", "No tasks")
    // A solid caret, not the explorer's chevron: this drops a list down, it does
    // not expand a node.
    widgets.button_set_icon(button, "caret-down", TASK_SELECTOR_ICON_SIZE)
    thor_theme_menu_button(thor, button)
    widgets.button_set_on_click(button, thor_open_tasks_menu, thor)
    button.font_size = 16
    button.padding = ui.padding_xy(TASK_SELECTOR_PAD_X, 4)
    button.min_size = rl.Vector2 {TASK_SELECTOR_MIN_WIDTH, 28}
    return button
}

// Titlebar update button: the version a check found, behind a download icon.
// Hidden until there is one, and the only way back to a release the user
// dismissed. Its width follows the label, see thor_sync_update_button.
thor_create_update_button :: proc(thor: ^Thor) -> ^widgets.Button {
    button := widgets.button_create("update-available", "")
    widgets.button_set_icon(button, "download", 16)
    thor_theme_menu_button(thor, button)
    widgets.button_set_on_click(button, thor_click_update, thor)
    button.text_color = thor.theme.success_color
    button.font_size = 16
    button.padding = ui.padding_xy(10, 4)
    button.min_size = rl.Vector2 {40, 28}
    button.visible = false
    return button
}

// Flat icon-only buttons for panel collapse/restore; the background matches
// the container they sit in so only the hover state reads as a button.
thor_create_icon_button :: proc(thor: ^Thor, id, icon: string, on_click: widgets.Button_Click_Proc, background: rl.Color) -> ^widgets.Button {
    button := widgets.button_create(id, "")
    widgets.button_set_icon(button, icon, 18)
    thor_theme_icon_button(thor, button, background)
    widgets.button_set_on_click(button, on_click, thor)
    button.min_size = rl.Vector2 {30, 26}
    return button
}
