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
thor            # reopen the last session's folder
thor .          # open the folder Thor was called from
thor src/       # open that folder
thor main.odin  # open the file, with its folder as the workspace
```

Inside the editor, `File > Open Folder...` switches the workspace and
`File > Open File...` opens a file from anywhere; dropping a folder or files on
the window does the same. Each folder keeps its own session (open tabs,
layout), restored when you come back to it.

Opening a second folder while one is already open asks whether to replace the
current window's workspace or launch a new window — configurable via the
`open_folder_in` setting (see [Configuration](configuration.md)).

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

**Help > Tutorial** opens an interactive walkthrough of the shortcuts above,
inside the editor itself. **Help > Documentation** opens this manual in Thor's
Markdown preview, and **Help > Documentation in Browser** opens it outside the
editor.

## Next steps

- [Keybindings](keybindings.md) — the full shortcut reference.
- [Configuration](configuration.md) — themes, fonts, per-project settings.
- [Plugins](plugins.md) — how syntax highlighting and workspace plugins work.
