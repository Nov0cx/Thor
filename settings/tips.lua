-- The tips of the day. user/tips.lua and .thor/tips.lua add to this list.
-- action names a keybinds.lua action; the card shows its current chord.

return {
    tips = {
        {
            title = "The command palette runs everything",
            action = "command_palette",
            body = "Every action in Thor is in the palette, with the chord it is bound to beside it. It is the fastest way to find a command whose name you only half remember.",
        },
        {
            title = "Open a file by its name",
            action = "quick_open",
            body = "Quick open searches the whole workspace by file name. Type a few letters of the path to narrow it further.",
        },
        {
            title = "Edit with more than one caret",
            action = "add_cursor_below",
            body = "The chord below adds a caret on the line under the last, and selecting the next occurrence of a word adds one there. Every caret then types, moves and deletes together.",
        },
        {
            title = "Select the next occurrence",
            action = "select_word",
            body = "The first press selects the word under the caret, each one after that the next occurrence of it, with a caret of its own. Rename a local variable without leaving the keyboard.",
        },
        {
            title = "Two files side by side",
            action = "toggle_split",
            body = "The editor splits into two panes. Each pane keeps its own tab, so a header and its implementation stay on screen together.",
        },
        {
            title = "Name your build commands",
            action = "run_selected_task",
            body = "Put the commands you run often in .thor/tasks.json. Each one gets a name in the title bar selector, and the chord below runs the selected one in the console.",
        },
        {
            title = "One shell per console tab",
            action = "toggle_console",
            body = "The + in the console opens another terminal, from every shell found on the machine. Each shell stays alive between commands, so cd and environment variables persist.",
        },
        {
            title = "Go to the definition",
            action = "goto_definition",
            body = "Jumps to where the symbol under the caret is declared; ctrl and a click does the same. Thor analyzes Odin in the editor itself, and uses a language server for the other languages.",
        },
        {
            title = "Go back where you came from",
            action = "jump_back",
            body = "The jump list remembers each place you jumped from, so a walk through several definitions retraces in the order you made it.",
        },
        {
            title = "Find every use of a symbol",
            action = "find_references",
            body = "Lists everywhere the symbol under the caret is used. Rename Symbol in the palette then changes all of them at once, instead of one search and replace at a time.",
        },
        {
            title = "Let the editor fix it",
            action = "code_actions",
            body = "Offers the code actions for the caret: the import a name needs, the unused declaration to drop, the fix for the error under it.",
        },
        {
            title = "Format the file you are in",
            action = "format_document",
            body = "The Odin formatter is built in, so no external tool is needed. Turn on format_on_save in the settings to run it before every explicit save.",
        },
        {
            title = "Read Markdown as a page",
            action = "toggle_markdown_preview",
            body = "Renders the Markdown file in the pane instead of showing its source. The manual under Help opens the same way.",
        },
        {
            title = "Fold what you are not reading",
            action = "toggle_fold",
            body = "Folds the block at the caret; the arrow beside a line number does the same with the mouse. A folded block stays folded while you work elsewhere in the file.",
        },
        {
            title = "Find the symbol, not the file",
            action = "goto_workspace_symbol",
            body = "Searches every symbol in the workspace by name. Go to Symbol does the same inside the file you are in.",
        },
        {
            title = "Comment out a block",
            action = "toggle_line_comment",
            body = "Comments the selected lines with the marker of their language, and uncomments them when they already carry it.",
        },
        {
            title = "Move a line without cutting it",
            action = "move_line_up",
            body = "Carries the line, or the whole selection, past its neighbour. The duplicate chords leave a copy behind instead.",
        },
        {
            title = "Every folder keeps its own session",
            action = "open_folder",
            body = "Thor remembers the open tabs and the panel layout per folder. Reopen the folder and you are back where you left it.",
        },
        {
            title = "Settings per workspace",
            action = "open_settings_gui",
            body = "A .thor/ folder in the workspace overlays your own settings, keybindings, tasks and language servers. Only the keys it names change, so the rest still comes from your defaults.",
        },
        {
            title = "Languages are plugins",
            action = "",
            body = "Each language is a small Lua plugin under plugins/. A workspace can carry its own in .thor/plugins, and Thor asks before it loads one.",
        },
    },
}
