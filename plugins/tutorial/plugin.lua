-- Interactive, gamified tutorial rendered into editor tabs: a shortcut drill,
-- and a deliberately broken Odin file the reader repairs with Thor's own tools.
-- Both documents are built from the live keybinds and the live buffer.

-- Relative to the open folder, so the tutorial lands in the workspace's .thor/.
local DOC_PATH = ".thor/tutorial/tutorial.md"
local LAB_PATH = ".thor/tutorial/playground.odin"

-- The chord bound to `action`, or `fallback` when it has none (or has no
-- configurable binding at all).
local function key(action, fallback)
    if action ~= nil and action ~= "" then
        local k = thor.keybind(action)
        if k ~= nil and k ~= "" then
            return k
        end
    end
    if fallback ~= nil and fallback ~= "" then
        return fallback
    end
    return "unbound"
end

-- The full action catalogue, grouped like settings/keybinds.json. `action` is
-- looked up live so the shown chord matches whatever you have bound; `fallback`
-- is shown when an action has no binding (or has no configurable one at all).
local reference = {
    {
        title = "Files & app",
        entries = {
            { action = "command_palette", desc = "Open the command palette to search and run any action" },
            { action = "quick_open", desc = "Quick-open: jump straight to fuzzy file search" },
            { action = "open_file", desc = "Open a file with the system dialog" },
            { action = "open_folder", desc = "Open a folder as the workspace" },
            { action = "open_folder_new_window", desc = "Open a folder in a second window (a second process)" },
            { action = "new_file", desc = "Create a file beside the selection" },
            { action = "new_folder", desc = "Create a folder beside the selection" },
            { action = "save", desc = "Save the current file (autosave also runs shortly after edits)" },
            { action = "save_all", desc = "Save every modified file" },
            { action = "rename_file", desc = "Rename the current file" },
            { action = "close_tab", fallback = "Ctrl+W", desc = "Close the current tab" },
            { action = "close_all_tabs", desc = "Close every tab" },
            { action = "next_tab", desc = "Switch to the next tab" },
            { action = "previous_tab", desc = "Switch to the previous tab" },
            { action = "last_file", desc = "Flip to the previously active file (press again to flip back)" },
            { action = "copy_path", desc = "Copy the current file's path to the clipboard" },
            { action = "reveal_in_explorer", desc = "Show the current file in the system file manager" },
            { action = "line_endings_lf", desc = "Write this file with LF line endings" },
            { action = "line_endings_crlf", desc = "Write this file with CRLF line endings" },
            { action = "goto_line", desc = "Go to line (opens the palette in line-number mode)" },
            { action = "toggle_explorer", fallback = "Ctrl+B", desc = "Show or hide the file explorer panel" },
            { action = "toggle_console", desc = "Show or hide the console panel" },
            { action = "focus_editor", desc = "Move keyboard focus to the editor" },
            { action = "focus_explorer", desc = "Focus the explorer (opens it if collapsed)" },
            { action = "focus_terminal", desc = "Focus the console (opens it if collapsed)" },
        },
    },
    {
        title = "Code intelligence",
        intro = "Served in-client by Thor's own analyzer, not by a language server.",
        entries = {
            { action = "goto_definition", desc = "Go to the definition of the symbol at the caret (Ctrl+Click does the same)" },
            { action = "jump_back", desc = "Go back to where the last jump started" },
            { action = "jump_forward", desc = "Go forward again after jumping back" },
            { action = "find_references", desc = "List every use of the symbol at the caret" },
            { action = "signature_help", desc = "Show the signature of the call the caret sits in" },
            { action = "code_actions", desc = "Offer the fixes that apply at the caret (missing import, unused import, declare a name, fill switch cases)" },
            { action = "replace", desc = "Rename the symbol under the caret, or find and replace when there is none" },
            { action = "goto_symbol", desc = "Jump to a symbol declared in this file" },
            { action = "goto_workspace_symbol", desc = "Jump to a symbol declared anywhere in the workspace" },
            { action = "package_doc", desc = "Show the documentation of the package at the caret" },
        },
    },
    {
        title = "Search",
        entries = {
            { action = "find", desc = "Find text in the current file" },
            { action = "replace", desc = "Rename the symbol under the caret, or find and replace when there is none" },
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
            { action = "trim_trailing_whitespace", desc = "Trim trailing whitespace on every line" },
            { action = "align_at_char", desc = "Align the selected lines on a character you pick (`:`, `=`, ...)" },
            { action = "uppercase", fallback = "Alt+U", desc = "Uppercase the selection (or the word under the caret)" },
            { action = "lowercase", fallback = "Alt+L", desc = "Lowercase the selection (or the word under the caret)" },
            { action = "capitalize", fallback = "Alt+C", desc = "Capitalize the selection (or the word under the caret)" },
        },
    },
    {
        title = "Folding",
        entries = {
            { action = "toggle_fold", desc = "Fold or unfold the block at the caret" },
            { action = "fold_all", desc = "Fold every foldable block" },
            { action = "unfold_all", desc = "Unfold everything" },
        },
    },
    {
        title = "View",
        entries = {
            { action = "zoom_in", fallback = "Ctrl+Numpad +", desc = "Zoom the editor font in" },
            { action = "zoom_out", fallback = "Ctrl+Numpad -", desc = "Zoom the editor font out" },
            { action = "reset_zoom", desc = "Reset the zoom" },
            { fallback = "Ctrl+Scroll", desc = "Zoom the editor font with the scroll wheel" },
            { action = "toggle_split", desc = "Split the editor in two panes (and back)" },
            { action = "toggle_word_wrap", desc = "Wrap long lines instead of scrolling sideways" },
            { action = "toggle_markdown_preview", desc = "Render the active Markdown file instead of its source" },
            { action = "recenter", desc = "Recenter the view on the caret (repeat cycles center / top / bottom)" },
            { action = "toggle_maximize", desc = "Maximize or restore the window" },
            { action = "toggle_fullscreen", desc = "Toggle borderless fullscreen" },
        },
    },
    {
        title = "Tasks",
        intro = "Named shell commands from the workspace's `.thor/tasks.json`, run in the console.",
        entries = {
            { action = "run_selected_task", desc = "Run the task picked in the titlebar" },
            { action = "run_task", desc = "Pick a task and run it" },
            { action = "add_task", desc = "Add a task" },
            { action = "remove_task", desc = "Remove a task" },
            { action = "edit_tasks", desc = "Edit `.thor/tasks.json` directly" },
        },
    },
    {
        title = "Settings & preferences",
        entries = {
            { action = "open_settings_gui", desc = "Open the settings window" },
            { action = "open_settings", desc = "Edit `settings/settings.json` as text" },
            { action = "open_keybinds", desc = "Edit `settings/keybinds.json` as text" },
            { action = "open_comments", desc = "Edit `settings/comments.json` (the comment marker per language)" },
            { action = "reload_settings", desc = "Reload every settings file from disk" },
            { action = "change_theme", desc = "Switch to another theme" },
            { action = "new_theme", desc = "Create a theme to edit" },
            { action = "change_font", desc = "Switch the editor font" },
            { action = "add_font", desc = "Register a font file with Thor" },
            { action = "change_icon_pack", desc = "Switch the UI icon pack" },
            { action = "change_file_icon_pack", desc = "Switch the file-type icon pack" },
            { action = "init_workspace", desc = "Create a `.thor/` directory in the workspace" },
            { action = "tutorial", desc = "Reopen this tutorial (also Help -> Tutorial)" },
        },
    },
}

-- The chord to display for a reference entry.
local function chord_for(e)
    return key(e.action, e.fallback)
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

-- The broken playground, line by line. `\32` spells a trailing space, so an
-- editor that trims whitespace cannot quietly clear that task for the reader.
local LAB_SOURCE = table.concat({
    "package tutorial",
    "",
    "// Thor's tutorial playground. Every defect in this file is deliberate: it",
    "// does not parse, it does not compile, and it was indented in the dark.",
    "// The checklist in tutorial.md explains them one at a time and names the",
    "// key that fixes each one.",
    "",
    "import \"core:strings\"",
    "",
    "MAX_ITEMS :: 32",
    "DEFAULT_LABEL :: \"item\"\32\32",
    "RETRY_LIMIT   :: 3",
    "",
    "Shape :: enum {",
    "    Circle,",
    "    Square,",
    "    Triangle,",
    "}",
    "",
    "Item :: struct {",
    "    name:  string,",
    "    count: int,\32",
    "    shape: Shape,",
    "}",
    "",
    "// The number of sides a shape has.",
    "sides :: proc(shape: Shape) -> int {",
    "    switch shape {",
    "    case .Circle:",
    "        return 0",
    "    }",
    "    return -1",
    "}",
    "",
    "// Prints one line per item, then the total.",
    "report :: proc(items: []Item) {",
    "    total = 0",
    "    for it in items {",
    "    total += it.count",
    "    fmt.printfln(\"%s x%d\", it.name, it.count",
    "    }",
    "        fmt.printfln(\"%s: %d items, %d total\", DEFAULT_LABEL, len(items), total)\32\32\32",
    "}",
    "",
}, "\n")

-- The enum the lab's switch runs over, in declaration order.
local SHAPES = {"Circle", "Square", "Triangle"}

-- Lines of `src`, without their newline. Buffers hold LF, but a file read off
-- disk on Windows can still carry the CR.
local function split_lines(src)
    local out = {}
    for line in string.gmatch(src .. "\n", "([^\n]*)\n") do
        out[#out + 1] = (string.gsub(line, "\r$", ""))
    end
    return out
end

-- The number of the first line matching `pattern`, or nil.
local function line_at(st, pattern)
    for i, line in ipairs(st.lines) do
        if string.find(line, pattern) then
            return i
        end
    end
    return nil
end

-- The width of a line's leading whitespace.
local function indent_of(line)
    return #string.match(line, "^[ \t]*")
end

-- Where tree-sitter gives up on `src`: the first node it marks as an error or
-- as missing. nil when the file parses.
local function parse_error(src)
    if thor.ts == nil or not thor.ts.supports("odin") then
        return nil
    end
    local tree, err = thor.ts.parse(src, "odin")
    if tree == nil then
        return { line = 1, reason = err or "the parser failed" }
    end
    local root = tree:root()
    if not root.has_error and not root.missing then
        return nil
    end
    local found = root
    local function visit(node)
        for _, child in ipairs(node:children()) do
            if child.missing or child:type() == "ERROR" then
                found = child
                return true
            end
            if child.has_error and visit(child) then
                return true
            end
        end
        return false
    end
    visit(root)
    local reason = "the parser cannot make a statement of this"
    if found.missing then
        reason = "a `" .. found:type() .. "` is missing here"
    end
    return { line = found.start_row + 1, reason = reason }
end

-- Lines whose last character is a space or a tab.
local function trailing_lines(st)
    local out = {}
    for i, line in ipairs(st.lines) do
        if string.find(line, "[ \t]+$") then
            out[#out + 1] = i
        end
    end
    return out
end

-- The lab's three constants and the column their `::` sits in, in file order.
local function const_columns(st)
    local out = {}
    for _, name in ipairs({"MAX_ITEMS", "DEFAULT_LABEL", "RETRY_LIMIT"}) do
        local i = line_at(st, "^" .. name .. "[ \t]")
        if i == nil then
            return nil
        end
        out[#out + 1] = { name = name, line = i, col = string.find(st.lines[i], ":") }
    end
    return out
end

-- The lines `report` indents wrongly, each with the column it sits in and the
-- one it belongs in.
local INDENT_RULES = {
    { pattern = "^[ \t]*total%s*%+=%s*it%.count", want = 8, label = "`total += it.count`" },
    { pattern = '^[ \t]*fmt%.printfln%("%%s x%%d"', want = 8, label = "the per-item `fmt.printfln`" },
    { pattern = '^[ \t]*fmt%.printfln%("%%s: %%d items', want = 4, label = "the closing `fmt.printfln`" },
}

local function misindented(st)
    local out = {}
    for _, rule in ipairs(INDENT_RULES) do
        local i = line_at(st, rule.pattern)
        if i ~= nil then
            local have = indent_of(st.lines[i])
            if have ~= rule.want then
                out[#out + 1] = { line = i, have = have, want = rule.want, label = rule.label }
            end
        end
    end
    return out
end

-- Human list: "12, 24 and 30".
local function list_of(items)
    if #items == 0 then
        return ""
    end
    if #items == 1 then
        return tostring(items[1])
    end
    local head = {}
    for i = 1, #items - 1 do
        head[#head + 1] = tostring(items[i])
    end
    return table.concat(head, ", ") .. " and " .. tostring(items[#items])
end

-- One task of the repair: `check` reads the live file, `detail` explains what is
-- still wrong in it and which key fixes that.
local lab_tasks = {
    {
        title = "Close the call, so the file parses at all",
        check = function(st)
            return st.parse == nil
        end,
        detail = function(st)
            local at = st.parse.line
            local text = st.lines[at] or ""
            local cause = line_at(st, '^[ \t]*fmt%.printfln%("%%s x%%d"')
            local lines = {
                "tree-sitter gives up at line " .. at .. " -- " .. st.parse.reason .. ":",
                "```odin\n" .. text .. "\n```",
            }
            if cause ~= nil then
                local where = cause == at and "The cause is on that line" or ("The cause is line " .. cause)
                lines[#lines + 1] =
                    where .. ": the `(` after `printfln` is never closed, so every line after it " ..
                    "is swallowed by an expression that never ends."
            end
            lines[#lines + 1] =
                "Nothing else works until this is fixed. The analyzer reads the same tree the " ..
                "highlighter does, so hover, go-to-definition and code actions all stay silent " ..
                "on a file that does not parse -- and `odin check` reports only the syntax error."
            lines[#lines + 1] =
                "Type the missing `)`. Thor closes a bracket for you as you type the opening one, " ..
                "and `" .. key("matching_bracket") .. "` jumps between a pair when you want to see " ..
                "which one is unbalanced."
            return lines
        end,
    },
    {
        title = "Import the package `fmt` comes from",
        check = function(st)
            return string.find(st.src, 'import%s+"core:fmt"') ~= nil
        end,
        detail = function(st)
            local at = line_at(st, "fmt%.printfln") or 1
            return {
                "Line " .. at .. " calls `fmt.printfln`, but the file imports no package of that " ..
                "name, so the compiler answers `Undeclared name: fmt`. Odin reaches nothing " ..
                "outside its own package without an import.",
                "Put the caret on `fmt` and press `" .. key("code_actions") .. "` (code actions). " ..
                "Thor offers `Import \"core:fmt\"` -- it searched the toolchain's collections for a " ..
                "package with that name -- and Enter inserts the import beside the existing one.",
                "Code actions are worth pressing anywhere: the list holds what fits the caret and " ..
                "nothing else.",
            }
        end,
    },
    {
        title = "Remove the import nothing uses",
        check = function(st)
            if string.find(st.src, 'import%s+"core:strings"') == nil then
                return true
            end
            return string.find(st.src, "strings%.[%a_]") ~= nil
        end,
        detail = function(st)
            local at = line_at(st, '^import%s+"core:strings"') or 1
            return {
                "Line " .. at .. " imports `core:strings` and nothing in the file names it. The " ..
                "compiler only calls that an error under `-vet-unused-imports`, which Thor's " ..
                "check does not pass, so this one is on you: a dead import claims a dependency " ..
                "the package does not have.",
                "Caret on that line, `" .. key("code_actions") .. "` -> " ..
                "`Remove unused import \"core:strings\"`. With several dead imports the same " ..
                "action offers to drop them all at once.",
            }
        end,
    },
    {
        title = "Declare `total` before assigning to it",
        check = function(st)
            return string.find(st.src, "total%s*:=") ~= nil or string.find(st.src, "total%s*:%s*int") ~= nil
        end,
        detail = function(st)
            local at = line_at(st, "^[ \t]*total%s*=%s*0") or 1
            return {
                "Line " .. at .. " assigns to `total`, and nothing declares it. Odin has no " ..
                "implicit declaration: `=` writes to a name that exists, `:=` introduces one. " ..
                "The compiler reports `Undeclared name: total` here and at every later use.",
                "Caret on `total`, `" .. key("code_actions") .. "` -> `Declare \"total\" with :=`. " ..
                "The fix rewrites the `=` into `:=`, which declares and initialises in one step, " ..
                "and `" .. key("undo") .. "` takes the whole thing back as one undo entry.",
            }
        end,
    },
    {
        title = "Handle every `Shape` in the switch",
        check = function(st)
            for _, name in ipairs(SHAPES) do
                if string.find(st.src, "case%s+%." .. name) == nil then
                    return false
                end
            end
            return true
        end,
        detail = function(st)
            local at = line_at(st, "switch%s+shape") or 1
            local missing = {}
            for _, name in ipairs(SHAPES) do
                if string.find(st.src, "case%s+%." .. name) == nil then
                    missing[#missing + 1] = "`." .. name .. "`"
                end
            end
            return {
                "The switch on line " .. at .. " does not name " .. list_of(missing) .. ". An Odin " ..
                "switch over an enum must cover every member unless it is written " ..
                "`#partial switch`, so the compiler answers `Unhandled switch cases`.",
                "Put the caret inside the switch and press `" .. key("code_actions") .. "`: " ..
                "Thor read the enum, knows which members are missing and offers to add exactly " ..
                "those arms, indented like the ones already there. They arrive empty -- give " ..
                "them their `return`.",
                "`" .. key("goto_definition") .. "` on `Shape` opens the enum declaration, and " ..
                "`" .. key("jump_back") .. "` comes back to where you were.",
            }
        end,
    },
    {
        title = "Put the body of `report` at the right depth",
        check = function(st)
            return #misindented(st) == 0
        end,
        detail = function(st)
            local wrong = misindented(st)
            local shallow, deep = {}, {}
            local rows = {}
            for _, w in ipairs(wrong) do
                rows[#rows + 1] = "| " .. w.line .. " | " .. w.label .. " | " .. w.have .. " | " .. w.want .. " |"
                if w.have < w.want then
                    shallow[#shallow + 1] = w.line
                else
                    deep[#deep + 1] = w.line
                end
            end
            local lines = {
                "`report` compiles at any depth -- Odin does not care -- and is unreadable at this " ..
                "one. These lines sit at the wrong column:",
                "| Line | What | Now | Should be |\n| --- | --- | --- | --- |\n" .. table.concat(rows, "\n"),
            }
            if #shallow > 0 then
                lines[#lines + 1] =
                    "Select " .. (#shallow > 1 and "lines " or "line ") .. list_of(shallow) ..
                    " and press `" .. key("indent", "Tab") .. "` to push " ..
                    (#shallow > 1 and "them" or "it") .. " in one level."
            end
            if #deep > 0 then
                lines[#lines + 1] =
                    "Select " .. (#deep > 1 and "lines " or "line ") .. list_of(deep) ..
                    " and press `" .. key("outdent", "Shift+Tab") .. "` to pull " ..
                    (#deep > 1 and "them" or "it") .. " back out."
            end
            lines[#lines + 1] =
                "Both keys move whole lines by one level, and Thor's levels are spaces: it never " ..
                "writes a tab, whatever the file already holds."
            return lines
        end,
    },
    {
        title = "Strip the trailing whitespace",
        check = function(st)
            return #trailing_lines(st) == 0
        end,
        detail = function(st)
            local at = trailing_lines(st)
            return {
                (#at > 1 and "Lines " or "Line ") .. list_of(at) .. " end in whitespace you cannot " ..
                "see. Nothing breaks -- it just turns up in every diff that touches those lines.",
                "`" .. key("trim_trailing_whitespace") .. "` trims every line of the file in one " ..
                "undo step. No selection needed.",
            }
        end,
    },
    {
        title = "Line the three constants up",
        check = function(st)
            local cols = const_columns(st)
            if cols == nil then
                return false
            end
            for _, c in ipairs(cols) do
                if c.col == nil or c.col ~= cols[1].col or c.col < 2 then
                    return false
                end
            end
            return true
        end,
        detail = function(st)
            local cols = const_columns(st)
            if cols == nil then
                return {"The three constants are gone from the file -- run Help -> Tutorial again to restore it."}
            end
            return {
                "The constants on lines " .. cols[1].line .. " to " .. cols[#cols].line ..
                " each declare with `::`, and each `::` starts in a different column, so the " ..
                "values do not read as a column of values.",
                "Select the three lines, press `" .. key("align_at_char") .. "` (align at " ..
                "character), type `:` and press Enter. Every first `:` of the selection moves " ..
                "into one column, and the padding before it is normalised on the way.",
                "The same key aligns `=` in a block of assignments, or `//` in a run of trailing " ..
                "comments.",
            }
        end,
    },
}

local running = false
-- Lab state of the last render, kept so an unchanged buffer costs no re-parse.
local last_state = nil

-- Everything the lab tasks read: the live buffer (unsaved edits included), its
-- lines, and where the parser stopped. Recomputed only when the text moved.
local function lab_state()
    if thor.read == nil then
        return nil
    end
    local src = thor.read(LAB_PATH)
    if src == nil or src == "" then
        return nil
    end
    if last_state ~= nil and last_state.src == src then
        return last_state
    end
    local st = { src = src }
    st.lines = split_lines(src)
    st.parse = parse_error(src)
    last_state = st
    return st
end

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

-- Which lab tasks the file currently passes, and the first one it does not.
local function lab_progress(st)
    local done, current = 0, nil
    local flags = {}
    for i, task in ipairs(lab_tasks) do
        local ok = st ~= nil and task.check(st)
        flags[i] = ok
        if ok then
            done = done + 1
        elseif current == nil then
            current = i
        end
    end
    return done, current, flags
end

local function bar(done, total)
    return "[" .. string.rep("#", done) .. string.rep(".", total - done) .. "]"
end

-- Renders the whole tutorial document as Markdown from the current progress,
-- the live keybinds and the live playground buffer.
local function render(st)
    local out = {}
    local function w(s) out[#out + 1] = s end

    local done = cleared_count()
    local total = #challenges
    local lab_done, lab_current, lab_flags = lab_progress(st)

    w("# Thor - Interactive Tutorial\n\n")
    w("Two parts, both live. **Part 1** drills the shortcuts you have bound, read\n")
    w("straight from `settings/keybinds.json`. **Part 2** repairs a broken Odin file\n")
    w("in the tab next door. This page rewrites itself while you work, so put it\n")
    w("beside the playground (`" .. key("toggle_split") .. "` splits the editor) and\n")
    w("watch the boxes tick.\n\n")

    if total > 0 then
        w(string.format("## Part 1 - Shortcuts  %s  %d/%d\n\n", bar(done, total), done, total))
        w("Press the chord. The document notices and moves to the next one - the key\n")
        w("still does its real job while it does.\n\n")
        local cur = current_index()
        for idx, c in ipairs(challenges) do
            local want = thor.keybind(c.action) or "unbound"
            if c.done then
                w(string.format("- [x] %s  (`%s`)\n", c.text, want))
            elseif idx == cur and running then
                w(string.format("- [ ] **>> %s -- press `%s` now**\n", c.text, want))
            else
                w(string.format("- [ ] %s  (`%s`)\n", c.text, want))
            end
        end
        w("\n")
        if done == total then
            w("*** Part 1 complete! You performed all " .. total .. " shortcuts. ***\n\n")
        end
    end

    w(string.format("## Part 2 - Repair `playground.odin`  %s  %d/%d\n\n",
        bar(lab_done, #lab_tasks), lab_done, #lab_tasks))

    if st == nil then
        w("`" .. LAB_PATH .. "` is not there. Run **Help -> Tutorial** again to write a\n")
        w("fresh copy of it.\n\n")
    else
        w("The other tab holds a small Odin file that does not parse, does not compile\n")
        w("and was indented in the dark. Every defect below is one editor action away.\n")
        w("The list re-reads the buffer several times a second, so a fix ticks off as\n")
        w("you make it - no save needed, and the explanation below moves on.\n\n")
        w("Saving the file runs `odin check` over its package: errors come back as a\n")
        w("red underline and a dot in the gutter, and hovering one shows what the\n")
        w("compiler said.\n\n")

        for i, task in ipairs(lab_tasks) do
            local mark = lab_flags[i] and "[x]" or "[ ]"
            if i == lab_current then
                w(string.format("%d. %s **%s**  <- you are here\n", i, mark, task.title))
            else
                w(string.format("%d. %s %s\n", i, mark, task.title))
            end
        end
        w("\n")

        if lab_current ~= nil then
            w("### Now: " .. lab_tasks[lab_current].title .. "\n\n")
            for _, para in ipairs(lab_tasks[lab_current].detail(st)) do
                w(para .. "\n\n")
            end
        else
            w("*** Part 2 complete! The file parses, compiles and reads like Odin. ***\n\n")
            w("Save it once more: `odin check` runs, finds nothing, and every squiggle\n")
            w("goes away. Then try the rest of the analyzer on it - `" ..
                key("find_references") .. "` on `total`, `" .. key("goto_symbol") ..
                "` for the file's outline, `" .. key("package_doc") .. "` on `fmt`.\n\n")
        end
    end

    w("## Every action explained\n\n")
    w("Rebind anything in `settings/keybinds.json` (or in the settings window), then\n")
    w("reopen this tutorial from **Help -> Tutorial** to see the shortcuts update.\n")
    w("Anything listed as `unbound` has no chord yet and is still reachable by name\n")
    w("from the command palette.\n\n")

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

-- The document as it was last written, so a refresh that would change nothing
-- leaves the buffer (and the reader's scroll position) alone.
local last_doc = nil

-- Rewrites the document from the current state of everything, and retires the
-- handlers once both parts are cleared.
local function refresh(focus)
    local st = lab_state()
    local text = render(st)
    if text ~= last_doc or focus then
        last_doc = text
        thor.doc(DOC_PATH, text, focus)
    end
    local lab_done = lab_progress(st)
    if current_index() == nil and lab_done == #lab_tasks then
        running = false
    end
end

-- Help -> Tutorial: reveal both documents and start the drill over. A playground
-- that has been edited is kept until the reader confirms the reset, so reopening
-- the tutorial never eats their repair.
thor.on_command("tutorial", function()
    for _, c in ipairs(challenges) do
        c.done = false
    end
    running = true
    last_state = nil
    last_doc = nil

    local current = thor.read ~= nil and thor.read(LAB_PATH) or ""
    -- Writing what is already there opens the tab without touching the content.
    thor.doc(LAB_PATH, current ~= "" and current or LAB_SOURCE, false)
    refresh(true)

    if current ~= "" and current ~= LAB_SOURCE and thor.confirm ~= nil then
        thor.confirm("Reset playground.odin to the broken original?", function()
            thor.doc(LAB_PATH, LAB_SOURCE, false)
            last_state = nil
            refresh(false)
        end)
    end
end)

-- Part 1: the pressed chord clears the current challenge. Refreshed in place (no
-- focus change) so the tick appears while the real action still runs -- this
-- handler never returns true, so it consumes nothing.
thor.on_key(function(ev)
    if not running then
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
        refresh(false)
    end
end)

-- Part 2: the playground is repaired by editing, by a code action, or by a menu
-- click, none of which the key handler sees. The tick reads the buffer instead,
-- and only renders when the text moved.
thor.on_tick(function()
    if not running then
        return
    end
    local before = last_state
    if lab_state() ~= before then
        refresh(false)
    end
end)
