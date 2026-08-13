# Getting Started

## Install

Two ways to get Thor:

- **Download a release** — grab the archive for your platform from the
  [Releases](https://github.com/Nov0cx/Thor/releases) page and unpack it
  anywhere. `thor` (or `thor.exe`) is ready to run; `assets/`, `plugins/` and
  `settings/` beside it are loaded at startup, so keep the whole folder
  together.
- **Build from source** — see [Building from Source](building.md). Needed if
  no release matches your platform, or you want a development build.

## Opening a project

```bash
thor                    # reopen the last session's folder, or the welcome page if there is none
thor .                  # open the folder Thor was called from
thor src/               # open that folder
thor main.odin          # open the file, with its folder as the workspace
thor a.odin b.odin      # open both as tabs, with b.odin active
thor src/ main.odin     # open the folder as the workspace and the file as a tab
```

Several files open as several tabs, in the order given, and the last one is
active. The first folder becomes the workspace; a second folder argument is
ignored, because one window holds one workspace. Use `File > Open Folder...`
with `open_folder_in` set to `new` to get a second folder in its own window.

A bare `thor` with no past session opens a welcome page instead: `Open
Folder`, `Open File` and a list of recently opened workspaces. `File > Close
Workspace` returns to it from an open workspace, and a later bare launch comes
back to the welcome page too.

Inside the editor, `File > Open Folder...` switches the workspace and
`File > Open File...` opens a file from anywhere; dropping a folder or files on
the window does the same. Each folder keeps its own session (open tabs,
layout), restored when you come back to it.

Opening a second folder while one is already open asks whether to replace the
current window's workspace or launch a new window — configurable via the
`open_folder_in` setting (see [Configuration](configuration.md)).

A folder that is already open in another window is never opened twice; that
window is brought to the front instead. On Linux and macOS this needs a desktop
helper — `xdotool` or `wmctrl` on X11, `osascript` on macOS — and the status bar
says so when none is available (Wayland has no equivalent).

## A first tour

- **Explorer** (`ctrl + b` to toggle) — the file tree for the open folder.
- **Editor** — tabs across the top; `ctrl + tab` for fuzzy file search,
  `ctrl + w` to close a tab.
- **Console** (`ctrl + t` to toggle) — a real shell, one per tab; **+** on its
  tab strip lists the shells found on the machine.
- **Command palette** (`ctrl + .`) — fuzzy-search and run any action Thor
  exposes; every keybinding below is also a command here.

For Odin, hover a symbol with `ctrl` held to see its declaration, `alt + enter`
(or `ctrl + click`) to jump to its definition, and `ctrl + shift + u` for the
code actions available at the caret.

Every other language gets the same features from a language server: install one
(`clangd`, `rust-analyzer`, `gopls`, `basedpyright`, `typescript-language-server`,
`lua-language-server` and `zls` are configured out of the box) and reopen the
folder or open a file it claims — Thor starts the server the first time it is
needed. See [Configuration](configuration.md) for the server table and how to
add one of your own. A language server also scopes `ctrl + shift + u` to the
current selection instead of only the caret, and can apply its own edits
directly in the editor.

**Help > Tutorial** opens an interactive walkthrough of the shortcuts above,
inside the editor itself. **Help > Documentation** opens this manual in Thor's
Markdown preview, and **Help > Documentation in Browser** opens it outside the
editor.

## Next steps

- [Keybindings](keybindings.md) — the full shortcut reference.
- [Configuration](configuration.md) — themes, fonts, per-project settings.
- [Plugins](plugins.md) — how syntax highlighting and workspace plugins work.
