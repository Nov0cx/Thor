-- Interactive, gamified tutorial rendered into an editor tab.

local DOC_PATH = "tutorial/tutorial.md"

-- The full action catalogue, grouped like settings/keybinds.json. `action` is
-- looked up live so the shown chord matches whatever you have bound; `fallback`
-- is shown when an action has no binding (or has no configurable one at all).
local reference = {
    {
        title = "Files & app",
        entries = {
            { action = "command_palette", desc = "Open the command palette to search and run any action" },
            { action = "quick_open", desc = "Quick-open: jump straight to fuzzy file search" },
            { action = "save", desc = "Save the current file (autosave also runs shortly after edits)" },
            { action = "close_tab", fallback = "Ctrl+W", desc = "Close the current tab" },
            { action = "next_tab", desc = "Switch to the next tab" },
            { action = "previous_tab", desc = "Switch to the previous tab" },
            { action = "last_file", desc = "Flip to the previously active file (press again to flip back)" },
            { action = "goto_line", desc = "Go to line (opens the palette in line-number mode)" },
            { action = "toggle_explorer", fallback = "Ctrl+B", desc = "Show or hide the file explorer panel" },
            { action = "toggle_console", desc = "Show or hide the console panel" },
            { action = "focus_editor", desc = "Move keyboard focus to the editor" },
            { action = "focus_explorer", desc = "Focus the explorer (opens it if collapsed)" },
            { action = "focus_terminal", desc = "Focus the console (opens it if collapsed)" },
        },
    },
    {
        title = "Search",
        entries = {
            { action = "find", desc = "Find text in the current file" },
            { action = "replace", desc = "Find and replace text in the current file" },
        },
    },
    {
        title = "Explorer",
        intro = "When the explorer has focus it can be driven from the keyboard.",
        entries = {
            { fallback = "Up / Down", desc = "Move the selection" },
            { fallback = "Right", desc = "Expand a folder, or step into its first child" },
            { fallback = "Left", desc = "Collapse a folder, or step out to its parent" },
            { fallback = "Enter", desc = "Open the selected file / toggle the selected folder" },
            { fallback = "Del", desc = "Delete the selected file (after a confirmation dialog)" },
        },
    },
    {
        title = "Clipboard",
        entries = {
            { action = "copy", fallback = "Ctrl+C", desc = "Copy the selection (no selection: copy the whole line)" },
            { action = "cut", fallback = "Ctrl+X", desc = "Cut the selection (no selection: cut the whole line)" },
            { action = "paste", fallback = "Ctrl+V", desc = "Paste from the clipboard" },
        },
    },
    {
        title = "Movement",
        intro = "Add Shift to any movement to extend the selection.",
        entries = {
            { action = "word_left", fallback = "Ctrl+Left", desc = "Jump one word left" },
            { action = "word_right", fallback = "Ctrl+Right", desc = "Jump one word right" },
            { action = "line_start", fallback = "Alt+Left", desc = "Go to the start of the line" },
            { action = "line_end", fallback = "Alt+Right", desc = "Go to the end of the line" },
            { action = "line_start_home", fallback = "Home", desc = "Go to the start of the line" },
            { action = "line_end_home", fallback = "End", desc = "Go to the end of the line" },
            { action = "file_start", fallback = "Ctrl+Home", desc = "Go to the start of the file" },
            { action = "file_end", fallback = "Ctrl+End", desc = "Go to the end of the file" },
            { action = "file_start_up", fallback = "Ctrl+Up", desc = "Go to the start of the file" },
            { action = "file_end_down", fallback = "Ctrl+Down", desc = "Go to the end of the file" },
            { action = "page_up", fallback = "PgUp", desc = "Move up one page" },
            { action = "page_down", fallback = "PgDn", desc = "Move down one page" },
            { action = "matching_bracket", fallback = "Ctrl+P", desc = "Jump to the matching / enclosing bracket or quote" },
            { action = "select_between_brackets", fallback = "Ctrl+Shift+P", desc = "Select everything between the brackets / quotes (excludes them)" },
            { action = "select_to_matching_bracket", fallback = "Ctrl+Shift+\\", desc = "Select to the matching bracket / quote (includes them)" },
        },
    },
    {
        title = "Selection & multi-cursor",
        entries = {
            { action = "select_all", fallback = "Ctrl+A", desc = "Select the whole file" },
            { action = "select_word", fallback = "Ctrl+D", desc = "Select the word; press again to add a cursor at the next occurrence" },
            { action = "select_line", fallback = "Ctrl+L", desc = "Select the line; press again to extend by a line" },
            { action = "add_cursor_above", desc = "Add a cursor on the line above" },
            { action = "add_cursor_below", desc = "Add a cursor on the line below" },
            { action = "collapse_cursors", fallback = "Esc", desc = "Collapse to a single cursor and clear the selection" },
        },
    },
    {
        title = "Editing",
        entries = {
            { action = "undo", fallback = "Ctrl+Z", desc = "Undo the last change" },
            { action = "redo", fallback = "Ctrl+Shift+Z", desc = "Redo the last undone change" },
            { action = "redo_alt", fallback = "Ctrl+Y", desc = "Redo the last undone change" },
            { action = "delete_word_left", fallback = "Ctrl+Backspace", desc = "Delete the word to the left" },
            { action = "delete_word_right", fallback = "Ctrl+Del", desc = "Delete the word to the right" },
            { action = "delete_line", desc = "Delete the current line" },
            { action = "move_line_up", fallback = "Alt+Up", desc = "Move the current line up" },
            { action = "move_line_down", fallback = "Alt+Down", desc = "Move the current line down" },
            { action = "duplicate_line_up", fallback = "Shift+Alt+Up", desc = "Duplicate the current line upward" },
            { action = "duplicate_line_down", fallback = "Shift+Alt+Down", desc = "Duplicate the current line downward" },
            { action = "insert_line_below", fallback = "Ctrl+Enter", desc = "Insert a new line below" },
            { action = "insert_line_above", fallback = "Ctrl+Shift+Enter", desc = "Insert a new line above" },
            { action = "join_lines", desc = "Join the line below onto the current one" },
            { action = "indent", fallback = "Tab", desc = "Indent the selected lines" },
            { action = "outdent", fallback = "Shift+Tab", desc = "Outdent the selected lines" },
            { action = "toggle_line_comment", desc = "Toggle a line comment (uses the language's marker)" },
            { action = "trim_trailing_whitespace", desc = "Trim trailing whitespace" },
            { action = "uppercase", fallback = "Alt+U", desc = "Uppercase the selection (or the word under the caret)" },
            { action = "lowercase", fallback = "Alt+L", desc = "Lowercase the selection (or the word under the caret)" },
            { action = "capitalize", fallback = "Alt+C", desc = "Capitalize the selection (or the word under the caret)" },
        },
    },
    {
        title = "View",
        entries = {
            { action = "zoom_in", fallback = "Ctrl+Numpad +", desc = "Zoom the editor font in" },
            { action = "zoom_out", fallback = "Ctrl+Numpad -", desc = "Zoom the editor font out" },
            { fallback = "Ctrl+Scroll", desc = "Zoom the editor font with the scroll wheel" },
            { action = "recenter", desc = "Recenter the view on the caret (repeat cycles center / top / bottom)" },
            { action = "toggle_fullscreen", desc = "Toggle borderless fullscreen" },
        },
    },
}

-- The chord to display for a reference entry: the live binding if it has one,
-- else the documented fallback, else "unbound".
local function chord_for(e)
    if e.action and e.action ~= "" then
        local k = thor.keybind(e.action)
        if k ~= nil then
            return k
        end
    end
    if e.fallback and e.fallback ~= "" then
        return e.fallback
    end
    return "unbound"
end

-- Hands-on challenges: a curated, self-contained subset you can clear right
-- inside this document. Only those with a real binding are kept, so a player is
-- never stuck on a step they cannot perform.
local challenge_defs = {
    { action = "command_palette", text = "Open the command palette" },
    { action = "quick_open", text = "Quick-open the file finder" },
    { action = "save", text = "Save the current file" },
    { action = "toggle_explorer", text = "Toggle the file explorer" },
    { action = "find", text = "Open find" },
    { action = "select_all", text = "Select the whole file" },
    { action = "select_word", text = "Select the word under the caret" },
    { action = "duplicate_line_down", text = "Duplicate the current line" },
    { action = "move_line_down", text = "Move the current line down" },
    { action = "toggle_line_comment", text = "Toggle a line comment" },
}

local challenges = {}
for _, d in ipairs(challenge_defs) do
    if thor.keybind(d.action) ~= nil then
        challenges[#challenges + 1] = { action = d.action, text = d.text, done = false }
    end
end

local active = false

local function cleared_count()
    local n = 0
    for _, c in ipairs(challenges) do
        if c.done then
            n = n + 1
        end
    end
    return n
end

local function current_index()
    for idx, c in ipairs(challenges) do
        if not c.done then
            return idx
        end
    end
    return nil
end

local function bar(done, total)
    return "[" .. string.rep("#", done) .. string.rep(".", total - done) .. "]"
end

-- Renders the whole tutorial document as Markdown from the current progress and
-- the live keybinds.
local function render()
    local out = {}
    local function w(s) out[#out + 1] = s end

    local done = cleared_count()
    local total = #challenges

    w("# Thor - Interactive Tutorial\n\n")
    w("Learn Thor by doing. Each challenge below asks you to press one of your\n")
    w("real shortcuts (read live from `settings/keybinds.json`). Do it and this\n")
    w("document ticks the challenge off and moves to the next - you can perform\n")
    w("the editor actions right here in this file. Below the challenges is a full\n")
    w("reference explaining every action.\n\n")

    if total > 0 then
        w(string.format("## Challenges  %s  %d/%d\n\n", bar(done, total), done, total))
        local cur = current_index()
        for idx, c in ipairs(challenges) do
            local want = thor.keybind(c.action) or "unbound"
            if c.done then
                w(string.format("- [x] %s  (`%s`)\n", c.text, want))
            elseif idx == cur and active then
                w(string.format("- [ ] **>> %s -- press `%s` now**\n", c.text, want))
            else
                w(string.format("- [ ] %s  (`%s`)\n", c.text, want))
            end
        end
        w("\n")
        if total > 0 and done == total then
            w("*** Complete! You performed all " .. total .. " shortcuts. Well done! ***\n\n")
        end
    end

    w("## Every action explained\n\n")
    w("Rebind anything in `settings/keybinds.json`, then reopen this tutorial\n")
    w("from **Help -> Tutorial** to see the shortcuts update.\n\n")

    for _, section in ipairs(reference) do
        w("### " .. section.title .. "\n\n")
        if section.intro then
            w(section.intro .. "\n\n")
        end
        w("| Shortcut | Action |\n| --- | --- |\n")
        for _, e in ipairs(section.entries) do
            w(string.format("| `%s` | %s |\n", chord_for(e), e.desc))
        end
        w("\n")
    end

    w("---\n\n")
    w("Typing an opening bracket or quote auto-inserts its closing pair; selecting\n")
    w("text and typing a bracket wraps the selection. Two or more word characters\n")
    w("pop up an autocompletion list (Up/Down to choose, Tab or Enter to accept,\n")
    w("Esc to dismiss). Comment markers live in `settings/comments.json`; tab\n")
    w("width, font size and autosave delay in `settings/settings.json`.\n")

    return table.concat(out)
end

-- Help -> Tutorial: (re)start from a clean slate and reveal the document.
thor.on_command("tutorial", function()
    for _, c in ipairs(challenges) do
        c.done = false
    end
    active = true
    thor.doc(DOC_PATH, render(), true)
end)

thor.on_key(function(ev)
    if not active then
        return
    end
    local idx = current_index()
    if idx == nil then
        return
    end
    local c = challenges[idx]
    local want = thor.keybind(c.action)
    if want ~= nil and ev.chord == want then
        c.done = true
        if current_index() == nil then
            active = false
        end
        -- Refresh in place (no focus change) so the tick appears while the real
        -- action still runs -- this handler never returns true.
        thor.doc(DOC_PATH, render(), false)
    end
end)
