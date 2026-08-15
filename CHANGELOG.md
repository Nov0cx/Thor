# 2026.08.6

- Settings (`ctrl + ,`) has a "Language Servers" category, also under Help > Language Servers and on the `open_language_servers` action. Each server lists its status, the program it runs, where that program was found on PATH, the project root, the file types it claims, why it last failed, and an on/off switch.
- A server row installs the server with its own install command in the console, opens its documentation, and for clangd sets the open project up with a `compile_commands.json`.
- Restart Language Servers, Add a Server... and Look for Installed Servers Again sit above the list. Add a Server... writes a skeleton entry and opens it.
- A language server that is not installed, crashes or fails its handshake says so in the status bar, and the page keeps the reason with the server's own error output. A release build reported none of it before.
- Language server activity is written to `user/thor.log`, rewritten at each start.
- An `lsp.json` that is not valid JSON, misses its `servers` array, names an unknown key or a key of the wrong type, or holds an entry with no command, is reported under "Configuration Problems" on the page and in the log. Such an entry used to be dropped silently.
- `init_options` is accepted beside `initialization_options`. The documentation named the first, the parser read the second.
- Editing `settings/lsp.json`, `user/lsp.json` or `<workspace>/.thor/lsp.json` restarts the servers where they stand and re-sends the open files to them. The folder had to be reopened before.
- "Language: Restart Servers" (`restart_language_servers`) restarts the servers on demand.
- 22 more servers ship, all switched off: slangd, pyright, ruff, jdtls, kotlin-language-server, csharp-ls, haskell-language-server, nil, ocamllsp, ruby-lsp, intelephense, and servers for JSON, YAML, HTML, CSS, TOML, Markdown, Bash, CMake, Terraform, XML and Nim. Each carries its install command and is one switch away in Settings.
- `lsp.json` takes `name`, `install`, `docs_url` and `setup_command`, and expands `${workspace}`, `${userHome}` and `${env:NAME}` in `command`, `cwd` and `env`, which points an entry at a server inside a virtual environment or a project directory.
- The "LSP Setup" top bar dropdown and the seven `*-setup` plugins behind it are gone. The Language Servers page does their work, and clangd's `compile_commands.json` helper stays as the `compile-commands` plugin, run from that page.
- Turning a server's Diagnostics feature off in Settings stops the diagnostics the server pushes on its own.
- Two servers that claim one language: the second still does not start, and the page names the server that took the language.
- The window follows the cursor when the titlebar is dragged on Linux. The window moved in steps and fell behind the cursor.
- A double click on the titlebar maximizes the window, and restores it.
- A drag on a maximized window restores it and keeps the grabbed point under the cursor.
- Only the left mouse button drags the window. A right or middle click on the titlebar also moved it.
- The window stops following the cursor when the button is released outside the window.

# 2026.08.5

- The Windows release binary opens without a console window beside the editor. `thor --version` and `thor --help` still print in the shell that started them.
- The auto-updater installs again. The checksum read took the end of the archive for an error, so every download reported "The download does not match its checksum".
- An archive the updater cannot read reports "The downloaded archive could not be read" instead of a false checksum mismatch.

# 2026.08.4

- Settings > Appearance > Theme Colors opens a theme window: every color of the active theme under a foldable group, each row a swatch that opens a color picker with a saturation/value square, a hue strip, an alpha strip and a hex field. The change previews on the editor before it is kept.
- The theme window generates a whole theme from a background color, an accent color and a Dark/Light mode, holding the text and syntax colors to a readable contrast against the background. Save Generated Theme writes it under a given name and switches to it.
- An edited theme is written to `user/themes/`, which a build and an update leave alone. Editing a shipped theme copies it there first.
- `Preferences: New Theme` writes a copy of the active theme instead of a file of empty values, which reported 37 invalid colors on the file it had just made.
- A signature popup closes with the file it belongs to. It could stay on the new tab after a switch.
- Edit > Cut, Copy and Paste with no file open do nothing instead of closing the editor.
- A keybinding capture binds the action you picked. A settings reload while the chord was awaited could bind another one.
- Escape from a modal returns to the editor. Opening the modal a second time while it was up trapped the focus in it.
- A documentation page that cannot be written says so, instead of `F3` doing nothing.
- New File and New Folder refuse a name like `.`, `..` or one that holds a path separator.
- A documentation or plugin page opens in the tab it is already in, whatever the case of its path. A second tab of the same file could open.
- A split keeps the focused pane over a restart.
- A hover explanation is no longer lost when a request lands right after a refused one.
- A Settings picker shows its title again. The header of a language server feature picker, such as `gopls — Hover`, was blank or held stray characters.
- A Settings picker opens centered in the Settings window. It used to sit above it, over the editor.
- The Meadow Dew theme reads clearly: syntax, status and interface text stay legible on the editor, the panels, a selection and a hovered row. Panel and menu text was almost white on a light surface.
- Meadow Dew separates its surfaces more: stronger borders, and a distinct step between the editor, the panels, the title bar and an active control.
- `tab` over a selection leaves blank lines alone. It used to fill them with trailing whitespace.
- A theme color with an invalid digit, such as `#ff_f00`, is reported and skipped. It used to be accepted and give a wrong color.
- Mjolnir, Jogo, Ember Night and Verdant Shade read clearly. Comments, gutter line numbers and status colors stay legible on the editor, the panels, a selection and a hovered row.
- Panel and window edges are visible in every theme. A border was almost the color of the background behind it, and in Material Deep Ocean it was the same color.
- The `Text` theme color sets the editor text. Nothing read it before; the editor took its color from `Primary Text Color`, which still colors the panels, the menus and the tabs.

# 2026.08.3

- A control explains itself when the cursor rests on it: the title bar buttons, the explorer and console toggles, a tab and its close box, a status bar segment, and an explorer row with its path and git state. The chord the control is bound to is under the text, read from the keybindings in force.
- `tooltips` setting, and a Settings row under Appearance, turns the hover explanations off.
- The welcome page carries a tip of the day, with the chord it is about resolved from your own keybindings. The arrows on the card step through the rest.
- With a folder open, where there is no welcome page, the same card floats in the corner of the editor on the first start of each day. Its close box shuts it, and the line under it turns tips off for good.
- `tip_of_the_day` setting, and a Settings row under Appearance, turns the tip of the day off.
- `settings/tips.json` holds the tips. `user/tips.json` and a workspace `.thor/tips.json` add their own to the shipped set instead of replacing it.
- A built-in Git UI, a centered window in the settings style, opens from the new "Git" top-bar menu or the command palette: "Git: Open Git UI" (`open_git_gui`), "Git: History" (`open_git_history`) and "Git: Branches" (`open_git_branches`), each bindable.
- Changes view: stage and unstage files one by one or all at once, discard a file after a confirmation, and read a colored diff with line numbers. The commit box takes a subject and a description, can amend, and `ctrl + enter` commits. Fetch, pull and push sit in the header with the ahead/behind counts.
- History view: the commit log, loaded further on demand, with the diff of each commit.
- Branches view: branches, remotes, tags and stashes. A click checks a branch out, and the status bar branch follows; stashes save, apply, pop and drop.
- Settings view: the local and global git config, read and edited in place. Keys like `user.name` and `user.email` are always listed.
- Hosting view: recognizes GitHub and GitLab from `origin`, opens the repository, a file or a commit in the browser, lists and creates pull requests through `gh` or `glab` when installed (the browser otherwise), and clones from a URL.
- Every git command runs in the background, so the editor does not freeze on a slow repository.
- The bundled git plugin shrinks to a "Git LFS" dropdown, shown only when `git-lfs` is installed. Its old Git dropdown is replaced by the native menu.
- The plugin permission prompt is a proper window: one row per plugin with its id and what it asks for, scrolling when there are more than fit, answered with **Allow** or **Not now**. The list used to run off the edge of the screen on the first start.
- The welcome page centers its logo, title and subtitle, and lines the "Recent" heading up with the buttons below it.
- The "Open Folder" button takes its label and its hover and pressed colors from the theme accent, so the text reads on every theme and the button keeps its own color when the cursor is on it.
- The welcome page follows a theme change instead of keeping the colors of the theme it was built with.

# 2026.08.2

- Settings changed in the editor are kept in `user/*.json` beside the binary. A build and an update replace `settings/*.json`, which lost every change made in the Settings view; `user/` is left alone. An older install carries its `settings/` over on the first update.
- Every language server and its features are switched from Settings and stay switched after a restart. This was written to a file the next update replaced.
- A language server that `lsp.json` turns off is still listed in Settings and can be turned back on there.
- A language server turned off no longer holds on to its file types, so another entry for the same language starts instead.
- A settings change that cannot be written reports "Could not save settings" instead of showing a value that is not stored.
- "Open Settings (JSON)", "Open Keybinds (JSON)" and "Open Comments (JSON)" open the file a change from the editor writes to, and create it when it is absent.
- `thor.exe` carries the Thor icon, and names its publisher, description and version in the file properties.
- An update installed on Windows starts with no SmartScreen warning. The mark of the web comes off the files it unpacks.

# 2026.08.1

- The Linux, Arch Linux and macOS archives are published next to the Windows one. Only the Windows archive was built for `2026.08.0`.

# 2026.08.0

This is the first release of Thor. Read the README.md for more information.

- `ctrl + alt + l` / "Edit: Format Document" formats the active Odin file with a native in-editor formatter — no external tool required.
- `format_on_save` setting formats an Odin file before an explicit save (off by default; never runs on autosave).
- `.thor/odin-formatter.json` sets per-workspace formatter options: brace style, tabs vs. spaces, alignment, import sorting, and more.
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
- Thor asks GitHub for a newer release shortly after start, at most once a day. `check_for_updates` turns the background check off, and **Help > Check for Updates** asks at any time.
- An update installs itself: the archive for the platform is checked against the release `SHA256SUMS`, the files beside the binary are replaced, and Thor restarts into the same folder. `settings/` files that were edited and `sessions/` are kept as they are.
- Dismissing an update is remembered for that version. The title bar keeps a button with the new version that brings the offer back.
- A build from source, or one in a directory Thor cannot write, reports the new version and opens the Releases page instead of installing.
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
- Dragging a splitter next to an open 3D model view no longer stutters.
- Opening a large image, or reloading an open image tab after an external edit, no longer freezes the editor while it decodes.
- Fixed an image or 3D model tab's loading spinner spinning forever instead of clearing once it finished loading.
- The editor placeholder under a loading image tab now reads "Loading image..." instead of jumping straight to "Image".
- Quick open (`ctrl + tab`) and the command palette's file list are now instant on a large workspace, warmed in the background instead of walked on every open.
- `ctrl + alt + l` / "Edit: Format Document" now formats any file whose configured language server advertises formatting support (clangd, gopls, rust-analyzer, basedpyright, etc.), not only `.odin` files.
- New `ctrl + alt + shift + l` / "Edit: Format Selection" formats the selected lines through the language server; with nothing selected it formats the whole document.
- New `format_on_type` setting reformats a line as you type a trigger character the language server asks for, such as `}` or a newline. Off by default, next to the existing `format_on_save`.
- `format_on_save` now also formats non-Odin files served by a formatting-capable language server, not only Odin.
- Settings > Language > a server's Features group gained "Format Selection" and "Format On Type" toggles next to "Format Document".
- The completion popup takes the mouse: a click accepts a candidate, hovering one highlights it, and the wheel over the popup walks the list instead of scrolling the text.
- The console prompt is a full input line: `left`/`right`/`home`/`end`/`delete` move and edit the caret, a click places it, and `ctrl + v` pastes at the caret.
- Links in the Markdown preview are clickable. A URL opens in the browser; a path relative to the document opens as a tab, so the manual's own pages link to each other.
- Find and replace gained three toggles: `Aa` / `alt + c` matches case, `W` / `alt + w` matches whole words, and `.*` / `alt + r` reads the query as a regular expression. Each stays set until Thor restarts.
- Replace All is one undo step, and with `.*` on it rewrites matches of different lengths in one sweep. A pattern that does not compile reads "Invalid pattern" where the match count sits.
- The explorer has a scrollbar; drag the thumb to move through a long file tree.
- The status bar reports the indentation the file actually uses, tabs included, instead of always claiming spaces.
- The status bar names any language a plugin registers, including extensionless ones such as `Dockerfile` and `Makefile`, instead of falling back to "Plain Text".
- Undo and Redo sit at the top of the Edit menu and the editor's right-click menu, greyed out when there is nothing to move, and answer to "Edit: Undo" / "Edit: Redo" in the command palette.
- `ctrl + shift + z` and `ctrl + y` put back a rename or code action that changed several files, across all of them, matching the undo that already took the whole set back.
- `thor a.odin b.odin` opens every path given, in order, with the last one active. The first folder becomes the workspace and a later one is ignored. A `--help` or `--version` flag now wins wherever it stands.
- Tree-sitter highlight rules guarded by `#match?`, `#lua-match?` or `#has-parent?` apply instead of being dropped: Odin constants, macros and type names, C constants, and the same rules across the other grammars that ship them.
- JSON, YAML, INI, Makefile, Dockerfile, batch, `.env` and `.gitignore` files highlight only the lines the pane shows, so a large one keeps up with typing.
- A file colored by a pure-Lua lexer is no longer re-read whole every time the view scrolls.
- Plugin API: `line_based = true` in `thor.register_language` marks a lexer that reads each line on its own, and `thor.ts.parse` reuses the tree the plugin parsed last, so re-parsing an edited buffer costs the edit.
- The Odin formatter wraps a call, a procedure parameter list or a composite literal that crosses `character_width`, one item per line with a trailing comma. A list holding an argument that spans lines, such as a procedure literal, still hugs its call.
- `sort_imports` sorts each run of `import` declarations, `base:`, `core:` and `vendor:` paths first. A run with a comment in it keeps the order it was written.
- `align_struct_fields` lines up a struct's field types, and `align_struct_values` the `=` of enum members and multi-line composite literals and a bit field's `|`. Both are on by default. A blank line or an own-line comment starts a new column.
- `align_constant_definitions` and `align_struct_declarations` line up the `::` of consecutive declarations. Both off by default.
- `space_single_line_blocks` keeps a one-statement block the source wrote on one line as `{ stmt }`.
- `ctrl + alt + shift + l` / "Edit: Format Selection" works on Odin files instead of reporting that formatting is unavailable. It reformats only the lines selected.
- `format_on_type` reindents the current line of an Odin file when `}` is typed.
- Formatting an Odin file with no folder open uses the shipped defaults instead of no indent at all.
- Hover and completion work on a by-reference loop variable: `p.` inside `for &p in points` offers the element's fields.
- The workspace symbol picker (`ctrl + q`) filters as you type in the analyzer instead of sending every symbol in the workspace on each keystroke.
- A code action a language server runs itself, rather than answering with edits, is offered and runs. Its row reads "runs on the server", and the server's changes arrive as it applies them.
- Fixed a crash when a plugin calls `tree:language()` or `tree:source()` on a tree that was already collected.
- On Linux and macOS, two paths that differ only in case are no longer taken for the same file.
- A first run no longer warns about the settings files it has not created yet.
- Typing an opening bracket or quote no longer rebuilds the whole document, so auto-pairs stay fast in a large file.
- A tab is drawn at a real tab stop, `tab_width` columns wide, instead of one space. The caret column, soft tabs, "Edit: Align at Character", soft wrap and the status bar all count it the same way.
- Upper/lower/capitalize (`alt + u`, `alt + l`, `alt + c`) work in every script, not only ASCII: `straße` uppercases to `STRAẞE`, and Greek, Cyrillic and accented Latin change case.
- Case-insensitive find matches across case mappings that change a word's length, so `straße` finds `STRAẞE`.
- The caret, backspace and delete move by one character as it is displayed: an emoji, a flag, a Hangul syllable or a letter with a combining accent is no longer split in half. This covers the editor, the console and the find and command-palette input lines.
- `ctrl + d` matches whole words, so `foo` no longer selects the `foo` inside `food`. `ctrl + shift + d` keeps the old substring behavior.
- Repeated `ctrl + d` reaches every occurrence in the file. It used to stop once it wrapped to the first one.
- Copy with several carets and nothing selected copies every caret's line, matching what cut already deleted.
- On Linux and macOS, the Git menu no longer writes a stray `nul` file into the workspace.
- On Windows, the explorer keeps up with the disk after a watch failure: the workspace is rescanned on an interval instead of updates stopping until restart.
- The file tree, not only the git status, is refreshed when the watcher reports that it lost events.
- On Linux, changes under a folder renamed inside the workspace are reported at its new path.
- On Linux and macOS, a plugin command that passes its time budget is stopped whole: a child it left in the background no longer keeps running after it.
- On Linux and macOS, a command run by a plugin or the Git menu ends at a closed pipe again once a terminal or a language server has started.
- On Linux, a workspace larger than the system watch limit is rescanned on an interval instead of losing changes in the part of the tree that was left unwatched.
- On Linux, `node_modules` and git's object store are no longer watched, matching macOS. Changes inside them are not reported; the directories themselves still are.
- A key chord can name the Command key: `cmd` (also `command`, `super`, `meta` or `win`) in `settings/keybinds.json`, so macOS bindings such as `cmd+s` are possible. `option` is accepted as a second spelling of `alt`.
- Plugin API: the table `thor.on_key` receives carries a `cmd` field next to `ctrl`, `shift` and `alt`.
- On Windows on ARM, the "Developer Command Prompt" shell and the dependency build load the ARM64 MSVC tools instead of the x64 ones, and an installation carrying only the ARM64 toolset is found.
- On Linux and macOS, opening a folder that is already open brings that window to the front, through `xdotool`, `wmctrl` or `osascript`. When none of them can, the status bar says the window could not be raised instead of only naming it.
- On Linux and the BSDs, "File: Reveal in File Explorer" selects the file in the file manager instead of only opening its folder, as it already did on Windows and macOS. Nautilus, Dolphin, Nemo, Thunar, PCManFM-Qt and Caja answer; a file manager that does not still gets the folder opened.
- On Linux and macOS, key chords follow the keyboard layout, as they already did on Windows: on QWERTZ, `ctrl + z` undoes on the key labeled Z. Digit and punctuation chords follow the layout too, on every platform.
- A held key repeats, so holding `ctrl + v` pastes more than once. The shortcuts that open or toggle something still act once per press.
- Ligatures and right-to-left text are drawn at every font size. Zooming to a size the font manifest does not name no longer turned them off, and the tab strip and status bar get them as well.
- `AltGr` with the mouse wheel scrolls the editor instead of zooming it.
- The hover popup closes when the pointer leaves the editor, instead of staying up over the text it no longer points at.
- Plugin API: `thor.on_key_up(fn)` (permission `keys`) reports key releases, with the table `thor.on_key` receives.
- A relative line jump takes a count of more than one digit: the digits typed while `alt` is held make one number, so a gutter distance of 10 or more is reachable. The jump runs when `alt` is released, and the status bar shows the count while it is typed.
- A drag holds its target when a second mouse button is pressed during it: a splitter, scrollbar, tab or file being dragged no longer sticks to the cursor after the right button is clicked mid-drag.
- The console keeps its scroll position while a command writes output and when it ends, so scrollback stays where it is put instead of jumping to the last line. Submitting a command returns to the bottom.
- A picker opened after workspace symbols (`ctrl + q`) keeps its own rows: code actions and "Go to symbol" are no longer replaced by symbol results as you type.
- A folder the explorer cannot read is named in the error color instead of reading as empty, and the next open reads it again.
- On Linux and macOS, the explorer git colors and the gutter diff bar appear, as they already did on Windows.
- On Windows, a file git spells in a different case than the filesystem does still gets its explorer color and gutter diff.
- A `git worktree` checkout, a submodule and a subfolder of a repository opened as the workspace are read as git repositories: the branch name, the explorer colors and the gutter diff work in all three instead of reading as no repository.
- The editor's right-click menu acts on the pane that was clicked, not always the first one. Find and replace (`ctrl + f`) and Go to Line search and scroll the focused pane too.
- Deleting a file no longer races an autosave of it: the save is stopped first, so the file cannot come back after the delete. Deleting a folder closes the tabs of the files inside it.
