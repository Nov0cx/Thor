# 2026.08.0

First release. Thor runs on Windows, Linux and macOS.

- Editing: multiple cursors, editor split, find and replace, undo and redo, auto-indent, bracket and quote pairs, line comment toggle, autosave.
- Tree-sitter syntax highlighting for 45 languages, each one a plugin.
- Odin language intelligence, served in the editor with no language server: hover, go to definition, completion, signature help, code actions, find all references, rename symbol, document and workspace symbols, and compiler diagnostics. The `language_intelligence` setting turns it off per feature.
- Console panel with one live shell per tab. The shell stays alive between commands, so `cd` and environment variables persist. `+` lists the shells found on the machine: pwsh, Windows PowerShell, cmd, the MSVC developer prompt, Git Bash, MSYS2, Cygwin, WSL, nu, and the POSIX shells.
- Command palette (`ctrl + .`) runs every action, and quick open (`ctrl + tab`) finds a file by name.
- Explorer panel with the file tree of the workspace, keyboard driven and watched for changes on disk.
- Each folder keeps its own session: open tabs and layout come back with it. `open_folder_in` chooses whether a second folder replaces this window or opens a new one.
- Lua plugins for languages, commands, panels and key bindings. Each plugin is sandboxed and asks for its permissions before it loads; a workspace can carry its own plugins in `.thor/plugins`.
- Settings view for themes, fonts, icon packs and plugin permissions, over `settings/settings.json`, `settings/keybinds.json` and a workspace `.thor/`.
- Named shell commands in `.thor/tasks.json`, started from the titlebar or the command palette.
- Rendered Markdown preview (`f4`).
- Help menu opens the manual in the editor or the browser, and an interactive tutorial.
- `thor [path]` opens a folder or a file; `--version` and `--help` print and exit.
- Settings view redesigned: a category sidebar replaces the single scrollable list, with a search box and a General/Workspace scope switch that writes to `settings/` or the workspace `.thor/` explicitly.
- Settings has a close button, a keyboard-hint footer, and a button that empties the search box.
- The Settings window keeps one size, so a scope or category switch no longer resizes it under the cursor.
- "LSP Setup" top-bar menu: checks which servers from `settings/lsp.json` are on `PATH` and adds a workspace task that installs a missing one.
- Settings rows light up under the cursor, number steppers are spaced apart, and a keybinding shows its chord as a key cap.
- Clicking the Thor logo at the top left of the titlebar opens Settings.
- A welcome page opens when no folder or file is given and no past session is found: `Open Folder`, `Open File` and a recent-workspaces list. The explorer, tab bar and console panel stay hidden until a workspace opens.
- `File: Close Workspace` returns to the welcome page from an open workspace, from the File menu or the command palette.
- Console panel: click and drag to select scrollback text. `ctrl + shift + c` copies the selection, or the whole scrollback with nothing selected; `ctrl + v` pastes into the input line. The right-click menu gained "Copy" next to "Copy All".
- Language servers answer for every language other than Odin: hover, go to definition, find all references, document symbols, workspace symbols, signature help, completion, diagnostics, semantic colors, rename and code actions. `settings/lsp.json` names the servers, and a workspace `.thor/lsp.json` overlays it by server `id`.
- A language server's errors and warnings are drawn in the editor as the Odin compiler's are, against the unsaved buffer.
- `clangd`, `rust-analyzer`, `gopls`, `basedpyright`, `typescript-language-server`, `lua-language-server` and `zls` are configured out of the box. A server starts the first time a file it claims is opened, and a server that is not installed is skipped.
- Workspace symbols (`ctrl + q`) send the typed text to the language server as you type, instead of only filtering a fixed list.
- Opening a different folder restarts its language servers against the new `settings/lsp.json` / `.thor/lsp.json`, instead of leaving the previous folder's servers running.
- Workspace symbols (`ctrl + q`) on a language-server-backed file shows "Type to search workspace symbols…" instead of a blank list until you type, for servers that only answer a typed query.
- A language server's progress messages ("Indexing…", with a percentage when the server reports one) show in the statusline.
- A language server can apply its own edits (`workspace/applyEdit`) directly in the editor, as one undoable change.
- Code actions (`ctrl + shift + u`) on a language-server-backed file are scoped to the current selection, not only the caret.
- Python's default language server is `basedpyright`, not `pyright` — plain pyright never offered an "add missing import" code action.
- Fixed a language server's code actions silently failing to apply to an unsaved buffer when the server spelled the file's drive letter in a different case than Thor opened it under.
- The "LSP Setup" top-bar menu is now one menu per server — "clangd Setup", "rust-analyzer Setup", "gopls Setup", "basedpyright Setup", "typescript-language-server Setup", "lua-language-server Setup" and "zls Setup" — each still checking its own server against `PATH` and adding a workspace task when it is missing.
- "clangd Setup" gained "Configure compile_commands.json…": detects CMake, Bazel (bzlmod) or Make and adds a workspace task to generate the compilation database clangd needs, writing a `.clangd` file for a CMake project so clangd finds its build directory.
- Settings' Language category gained a "Language Servers" group: every configured server, plus the built-in Odin support, gets its own on/off switch, and each enabled one gets a foldable "Features" group of per-kind toggles. Backed by the new `language_backends` setting, and takes effect immediately, unlike editing `lsp.json`.
