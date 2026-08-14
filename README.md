# Thor

<img src="assets/branding/thor.png" alt="Thor icon" width="128" align="right">

[![Windows](https://github.com/Nov0cx/Thor/actions/workflows/windows.yml/badge.svg)](https://github.com/Nov0cx/Thor/actions/workflows/windows.yml)
[![Ubuntu](https://github.com/Nov0cx/Thor/actions/workflows/ubuntu.yml/badge.svg)](https://github.com/Nov0cx/Thor/actions/workflows/ubuntu.yml)
[![macOS](https://github.com/Nov0cx/Thor/actions/workflows/macos.yml/badge.svg)](https://github.com/Nov0cx/Thor/actions/workflows/macos.yml)
[![Arch Linux](https://github.com/Nov0cx/Thor/actions/workflows/arch.yml/badge.svg)](https://github.com/Nov0cx/Thor/actions/workflows/arch.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

A code editor written in [Odin](https://odin-lang.org/) with
[raylib](https://pkg.odin-lang.org/vendor/raylib/v6/). Tree-sitter syntax
highlighting, an in-client Odin language server, LSP support for every other
language, a real terminal, a built-in Git UI, and a sandboxed Lua plugin
system.

> This repo is still in development — everything can break or change at any
> time.

## Contents

- [Quick start](#quick-start)
- [Opening a project](#opening-a-project)
- [Command palette](#command-palette)
- [Documentation](#documentation)
- [License](#license)

## Quick start

Download a build from [Releases](https://github.com/Nov0cx/Thor/releases), or
build from source:

```bash
git clone --recurse-submodules https://github.com/Nov0cx/Thor
cd Thor
odin run build.odin -file -- deps   # once per machine: HarfBuzz + tree-sitter
odin run build.odin -file -- run    # build and start
```

Full dependency and per-platform setup: [`docs/building.md`](docs/building.md).

## Opening a project

```bash
thor                # reopen the last session's folder
thor .              # open the folder Thor was called from
thor src/           # open that folder
thor main.odin      # open the file, with its folder as the workspace
thor a.odin b.odin  # open both as tabs, with b.odin active
```

`File > Open Folder...` / `File > Open File...` do the same from inside the
editor, and so does dropping a folder or files on the window. Each folder
keeps its own session (open tabs, layout). More: [`docs/getting-started.md`](docs/getting-started.md).

## Command panel

Press `ctrl + .` to open the command palette — fuzzy-search and run any
action, including everything bound to a key. Full shortcut list:
[`docs/keybindings.md`](docs/keybindings.md).

## Documentation

The [`docs/`](docs/) folder is the full user manual:

- [Getting Started](docs/getting-started.md)
- [Building from Source](docs/building.md)
- [Configuration](docs/configuration.md) — settings, themes, per-project `.thor/` files
- [Keybindings](docs/keybindings.md)
- [Git](docs/git.md) — changes, history, branches, config, GitHub/GitLab
- [Plugins](docs/plugins.md)

For the codebase itself (architecture, package layout, contributing), see
[`CLAUDE.md`](CLAUDE.md).

## License

[GPL v3](LICENSE).
