# Getting Started

## Install

Two ways to get Thor:

- **Download a release** — grab the archive for your platform from the
  [Releases](https://github.com/Nov0cx/Thor/releases) page and unpack it
  anywhere. `thor` (or `thor.exe`) is ready to run; `assets/`, `plugins/` and
  `settings/` beside it are loaded at startup, so keep the whole folder
  together. What you change in Settings lands in a `user/` directory beside
  them, which no update replaces.
- **Build from source** — see [Building from Source](building.md). Needed if
  no release matches your platform, or you want a development build.

## Updating

Thor asks GitHub for a newer release shortly after it starts, at most once a
day. When it finds one it offers to install it; **Help > Check for Updates**
asks at any time and ignores the daily limit.

Answering **no** is remembered: that version is never offered again. The update
does not go away, though — a button appears in the title bar showing the new
version, and clicking it brings the offer back whenever you want it. Turn the
background check off entirely with `check_for_updates` in
[Configuration](configuration.md), or from **Settings > Updates**.

Installing downloads the archive for your platform, checks it against the
`SHA256SUMS` the release publishes, replaces the files beside the binary and
restarts into the same folder. Two things are left alone: `user/`, which holds
everything you changed in Settings, and `sessions/`, which holds your open tabs
and layout. An install made before those two directories were split gets its
`settings/` carried over into `user/` on the first update.

Thor updates itself only when it is a release build unpacked from an archive.
A build from source, or one in a directory it cannot write (`/opt`,
`C:\Program Files`), reports the new version and opens the
[Releases](https://github.com/Nov0cx/Thor/releases) page instead. It also needs
`curl` and `tar`, which Windows 10 1803 and later, macOS and most Linux
distributions already ship.

If an update is interrupted part-way, the next start puts the old files back —
they are kept beside the new ones with an `.old` suffix until then. In the one
case it cannot repair, the binary itself is missing and `thor.exe.old` (or
`thor.old`) is beside it: rename it back.

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
