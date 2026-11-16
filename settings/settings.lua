-- Shipped settings. A build and an update replace this file:
-- set a key in user/settings.lua instead. A workspace's .thor/settings.lua
-- applies only the project keys (indentation, formatting, language).
-- A config file is Lua: it returns a table, and thor.os, thor.arch and
-- thor.env(name) are there to branch on.

return {
    autosave_delay_ms = 1500,
    check_for_plugin_updates = true,
    check_for_updates = true,
    clipboard_history_save = true,
    default_shell = "",
    detect_indentation = true,
    font_size = 18,
    format_on_save = false,
    format_on_type = false,
    indent_guides = true,
    insert_spaces = true,
    language_intelligence = true,
    latex_build_command = "",
    latex_build_on_save = true,
    latex_pdf_renderer = "auto",
    ligatures = true,
    open_folder_in = "ask",
    pane_layout = "remember",
    peek_height = 12,
    reduce_motion = false,
    relative_line_numbers = true,
    right_alt = "auto",
    tab_width = 4,
    terminal_clipboard = true,
    tip_of_the_day = true,
    tooltips = true,
}
