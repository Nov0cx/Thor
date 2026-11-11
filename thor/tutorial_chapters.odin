package thor

// The tutorial chapters. Static data: the engine in tutorial.odin runs them.

@(private = "file")
has_workspace :: proc(thor: ^Thor) -> bool {
    return thor.workspace_dir != ""
}

@(private = "file")
preview_on :: proc(thor: ^Thor) -> bool {
    return thor.markdown_preview
}

@(private = "file")
git_open :: proc(thor: ^Thor) -> bool {
    return thor.git_open
}

@(private = "file")
settings_open :: proc(thor: ^Thor) -> bool {
    return thor.settings_open
}

@(private = "file")
BASICS := [?]Tutorial_Step{
    {
        title = "Open a folder",
        body = "Thor edits a folder: its files show in the explorer, and its session (open tabs, " +
            "layout) is kept for the next start.\n\nPress {key:open_folder}, or use **Open Folder** " +
            "on the welcome page.",
        check = Check_Proc(has_workspace),
    },
    {
        title = "The command palette",
        body = "Every command in Thor is in the command palette, by name. Press {key:command_palette}, " +
            "type a part of a name and press Enter. Esc closes it.\n\n" +
            "When you do not know a key, look in the palette: it shows the key beside each command.",
        region = .Titlebar,
        check = Check_Action{{"command_palette"}},
    },
    {
        title = "Open a file by name",
        body = "Press {key:quick_open} and type a part of a file name. The list matches the letters " + "in order, so `edvw` finds `editview`.",
        check = Check_Action{{"quick_open"}},
    },
    {
        title = "The explorer",
        body = "Press {key:toggle_explorer} to hide the explorer and again to show it. " +
            "{key:focus_explorer} moves the keyboard to it: the arrow keys move, Enter opens.",
        region = .Explorer,
        check = Check_Action{{"toggle_explorer", "focus_explorer"}},
    },
    {
        title = "Tabs",
        body = "Open a second file, then press {key:next_tab} or {key:previous_tab} to move between " +
            "the tabs. {key:last_file} goes back to the file you were in last.",
        region = .Tabbar,
        check = Check_Action{{"next_tab", "previous_tab", "last_file"}},
    },
    {
        title = "Save",
        body = "Press {key:save}. Thor also saves by itself a short time after you stop typing, " + "when `autosave` is on in the settings.",
        region = .Editor,
        check = Check_Action{{"save", "save_all"}},
    },
}

@(private = "file")
EDITING := [?]Tutorial_Step{
    {
        title = "Move a line",
        body = "Put the caret on a line and press {key:move_line_down} or {key:move_line_up}. " + "A selection moves all its lines.",
        region = .Editor,
        check = Check_Action{{"move_line_up", "move_line_down"}},
    },
    {
        title = "Duplicate a line",
        body = "Press {key:duplicate_line_down} to copy the line below itself, or " + "{key:duplicate_line_up} to copy it above.",
        region = .Editor,
        check = Check_Action{{"duplicate_line_up", "duplicate_line_down"}},
    },
    {
        title = "Comment a line",
        body = "Press {key:toggle_line_comment}. Thor uses the comment marker of the language, and " + "the same key removes it.",
        region = .Editor,
        check = Check_Action{{"toggle_line_comment"}},
    },
    {
        title = "Undo",
        body = "Press {key:undo}. Typing in one go is one undo step, not one step per character.",
        region = .Editor,
        check = Check_Action{{"undo"}},
    },
    {title = "Redo", body = "Press {key:redo} to do again what you undid.", region = .Editor, check = Check_Action{{"redo", "redo_alt"}}},
    {
        title = "Delete a word",
        body = "Press {key:delete_word_left} to delete the word before the caret, or " + "{key:delete_word_right} for the word after it.",
        region = .Editor,
        check = Check_Action{{"delete_word_left", "delete_word_right"}},
    },
}

@(private = "file")
MULTI_CURSOR := [?]Tutorial_Step{
    {title = "Select a word", body = "Put the caret in a word and press {key:select_word}.", region = .Editor, check = Check_Action{{"select_word"}}},
    {
        title = "Select the next one too",
        body = "Press {key:select_word} again. Thor adds a cursor at the next place the same word is. " + "What you type now goes to every cursor.",
        region = .Editor,
        check = Check_Action{{"select_word"}},
    },
    {
        title = "A cursor on the next line",
        body = "Press {key:add_cursor_below} or {key:add_cursor_above} to add a cursor in the same " + "column of the next line.",
        region = .Editor,
        check = Check_Action{{"add_cursor_below", "add_cursor_above"}},
    },
    {
        title = "Back to one cursor",
        body = "Press {key:collapse_cursors}. Only the first cursor stays.",
        region = .Editor,
        check = Check_Action{{"collapse_cursors"}},
    },
}

@(private = "file")
NAVIGATION := [?]Tutorial_Step{
    {title = "Go to a line", body = "Press {key:goto_line}, type a line number and press Enter.", check = Check_Action{{"goto_line"}}},
    {
        title = "The matching bracket",
        body = "Put the caret on a bracket and press {key:matching_bracket}. The caret goes to its " +
            "partner. {key:select_between_brackets} selects what is between them.",
        region = .Editor,
        check = Check_Action{{"matching_bracket", "select_between_brackets", "select_to_matching_bracket"}},
    },
    {
        title = "Go to a symbol",
        body = "Press {key:goto_symbol} for a list of the declarations in this file. " +
            "{key:goto_workspace_symbol} lists the declarations of the whole folder.",
        check = Check_Action{{"goto_symbol", "goto_workspace_symbol"}},
    },
    {
        title = "Go to the definition",
        body = "Put the caret on a name and press {key:goto_definition}, or hold Ctrl and click it. " +
            "{key:peek_definition} shows the definition below the line, in place.",
        region = .Editor,
        check = Check_Action{{"goto_definition", "peek_definition"}},
    },
    {
        title = "Jump back",
        body = "Press {key:jump_back} to go back to where the jump started, and {key:jump_forward} " + "to go forward again.",
        region = .Editor,
        check = Check_Action{{"jump_back", "jump_forward"}},
    },
}

@(private = "file")
SEARCH := [?]Tutorial_Step{
    {
        title = "Find",
        body = "Press {key:find} and type. Enter goes to the next match. The buttons in the find bar " +
            "turn on case matching, whole words and regular expressions.",
        check = Check_Action{{"find"}},
    },
    {
        title = "Replace",
        body = "Press {key:replace}. On a name the language knows, this renames the symbol everywhere. " + "In other text, it opens find and replace.",
        check = Check_Action{{"replace"}},
    },
    {title = "Find in files", body = "{key:find_in_files} searches every file of the folder.", check = Check_Action{{"find_in_files"}}},
}

@(private = "file")
PANES := [?]Tutorial_Step{
    {
        title = "Split the editor",
        body = "Use {key:toggle_split} to show two files side by side. **View: Pane Layout...** in " + "the palette has more layouts, up to six panes.",
        region = .Editor,
        check = Check_Action{{"toggle_split", "pick_layout", "next_layout"}},
    },
    {
        title = "Word wrap",
        body = "Use {key:toggle_word_wrap} to wrap long lines at the edge of the pane.",
        region = .Editor,
        check = Check_Action{{"toggle_word_wrap"}},
    },
    {
        title = "Zoom",
        body = "Press {key:zoom_in} or {key:zoom_out}, or hold Ctrl and turn the mouse wheel. " + "{key:reset_zoom} goes back to the font size of the settings.",
        region = .Editor,
        check = Check_Action{{"zoom_in", "zoom_out", "reset_zoom"}},
    },
    {
        title = "Markdown preview",
        body = "Open a `.md` file and use {key:toggle_markdown_preview}. The other pane shows the " + "page as it renders, and it changes while you type.",
        check = Check_Proc(preview_on),
    },
}

@(private = "file")
TERMINAL := [?]Tutorial_Step{
    {
        title = "The terminal",
        body = "Press {key:toggle_console} to show the terminal panel, or {key:focus_terminal} to " +
            "move the keyboard to it. It is a real shell: `cd` and environment variables stay.",
        region = .Console,
        check = Check_Action{{"toggle_console", "focus_terminal"}},
    },
    {
        title = "A second terminal",
        body = "Use {key:new_terminal}, or the `+` at the end of the terminal tabs. " + "{key:select_shell} starts a different shell.",
        region = .Console,
        check = Check_Action{{"new_terminal", "select_shell"}},
    },
    {
        title = "Tasks",
        body = "A task is a named shell command of the folder, kept in `.thor/tasks.lua`. " +
            "{key:add_task} adds one, and the play button in the titlebar runs the selected task.",
        region = .Titlebar,
        check = Check_Action{{"run_selected_task", "run_task", "add_task"}},
    },
}

@(private = "file")
GIT := [?]Tutorial_Step{
    {
        title = "The git window",
        body = "Use {key:open_git_gui}, or **Git > Changes** in the menu. It needs a folder that " + "is a git repository.",
        region = .Menu_Bar,
        check = Check_Proc(git_open),
    },
    {
        title = "Stage and commit",
        body = "Click a file to see its diff. The `+` beside a file stages it, and the box at the " + "bottom takes the commit message. Esc closes the window.",
        check = Check_Next{},
    },
    {
        title = "History and branches",
        body = "{key:open_git_history} shows the commits, and {key:open_git_branches} the branches.",
        check = Check_Action{{"open_git_history", "open_git_branches"}},
    },
}

@(private = "file")
SETTINGS := [?]Tutorial_Step{
    {
        title = "The settings window",
        body = "Use {key:open_settings_gui}, or click the hammer in the titlebar. A change applies at " + "once and is written to `user/settings.lua`.",
        region = .Titlebar,
        check = Check_Proc(settings_open),
    },
    {title = "A theme", body = "Use {key:change_theme}. The list previews each theme while you move through it.", check = Check_Action{{"change_theme"}}},
    {
        title = "Keys",
        body = "Every key can change. The settings window has a keybinding list, and " + "{key:open_keybinds} opens `user/keybinds.lua` as text.",
        check = Check_Action{{"open_keybinds", "open_settings_gui"}},
    },
}

@(private = "file")
PLUGINS := [?]Tutorial_Step{
    {
        title = "Plugins",
        body = "Each language and many tools are Lua plugins in `plugins/` beside the binary. " + "A folder can have its own plugins in `.thor/plugins`.",
        check = Check_Next{},
    },
    {
        title = "Permissions",
        body = "A plugin that wants to run programs, write files or show a panel asks first. " +
            "Your answer is kept, and the settings window shows it under **PLUGIN PERMISSIONS**.",
        check = Check_Next{},
    },
    {
        title = "Write one",
        body = "`plugins/README.md` is the reference for plugin authors. **Help: Documentation** in " + "the palette opens the manual.",
        check = Check_Next{},
    },
}

@(private = "file")
LAB := [?]Tutorial_Step{
    {
        title = "The lab",
        body = "The new tab holds a small Odin file that does not parse, does not compile and is " +
            "badly indented. Each next step is one defect, and one Thor tool fixes it.\n\n" +
            "The steps read the buffer while you type, so a fix counts before you save. When you " +
            "save, `odin check` runs, and its errors show as underlines.",
        region = .Editor,
        check = Check_Next{},
    },
    {title = "Close the call", region = .Editor, check = Check_Lab(0)},
    {title = "Import fmt", region = .Editor, check = Check_Lab(1)},
    {title = "Remove the unused import", region = .Editor, check = Check_Lab(2)},
    {title = "Declare total", region = .Editor, check = Check_Lab(3)},
    {title = "Complete the switch", region = .Editor, check = Check_Lab(4)},
    {title = "Indent report", region = .Editor, check = Check_Lab(5)},
    {title = "Trailing whitespace", region = .Editor, check = Check_Lab(6)},
    {title = "Align the constants", region = .Editor, check = Check_Lab(7)},
}

TUTORIAL_CHAPTERS := [?]Tutorial_Chapter{
    {id = "basics", title = "Basics", steps = BASICS[:]},
    {id = "editing", title = "Editing", steps = EDITING[:]},
    {id = "multi_cursor", title = "Multiple cursors", steps = MULTI_CURSOR[:]},
    {id = "navigation", title = "Navigation", steps = NAVIGATION[:]},
    {id = "search", title = "Search", steps = SEARCH[:]},
    {id = "panes", title = "Panes and view", steps = PANES[:]},
    {id = "terminal", title = "Terminal and tasks", steps = TERMINAL[:]},
    {id = "git", title = "Git", steps = GIT[:]},
    {id = "settings", title = "Settings and look", steps = SETTINGS[:]},
    {id = "plugins", title = "Plugins", steps = PLUGINS[:]},
    {id = "lab", title = "Code intelligence lab", steps = LAB[:], on_start = thor_lab_start},
}
