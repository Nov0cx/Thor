# Building from Source

## Get the code

Thor vendors HarfBuzz and tree-sitter bindings as git submodules, so clone with
them:

```bash
git clone --recurse-submodules https://github.com/Nov0cx/Thor
```

(Already cloned without them? `git submodule update --init --recursive`.)

## Dependencies

Thor depends on:

- [HarfBuzz](https://harfbuzz.github.io/) (via the
  [odin-harfbuzz](https://codeberg.org/mgavioli/odin-harfbuzz) bindings) for
  ligature shaping.
- [tree-sitter](https://tree-sitter.github.io/tree-sitter/) (via
  [odin-tree-sitter](https://github.com/laytan/odin-tree-sitter)) for syntax
  highlighting.
- Lua 5.4 (Odin's bundled `vendor:lua`) for the plugin system.

HarfBuzz and the tree-sitter runtime/grammars are local build artifacts, built
once per machine. The one-time setup:

```bash
odin run build.odin -file -- deps
```

This locates the MSVC tools itself on Windows (via `vswhere`), so no developer
shell is needed just to run it. It builds HarfBuzz and every tree-sitter
grammar `build.odin`'s `GRAMMARS` list names. For the manual recipes behind
each step (useful if `deps` fails, or you only want to update one grammar),
see [`vendor/README.md`](../vendor/README.md).

### Windows

Lua links against `lua54.dll`; the build program copies it next to the
executable from Odin's `vendor` directory the first time it is missing.

### Linux

The system HarfBuzz library is used; install it through your package manager
(e.g. `libharfbuzz-dev`). Lua links statically from the vendor package, so no
shared library needs copying.

### macOS

HarfBuzz and Lua 5.4 come from Homebrew (`brew install harfbuzz lua@5.4`); see
[`vendor/README.md`](../vendor/README.md) if the link step complains about a
Lua ABI mismatch — the unversioned `lua` formula is not 5.4.

## Building

`build.odin` drives everything; run it from the repository root. The editor
lands in `bin/debug` (or `bin/release`), together with a fresh copy of
`assets/`, `plugins/` and `settings/` — Thor moves its working directory to
the executable at startup, so it loads those from beside the binary. The
folder it opens still comes from the directory it was started in.

```bash
odin run build.odin -file -- deps           # get and build HarfBuzz + tree-sitter, once
odin run build.odin -file                   # build, debug
odin run build.odin -file -- run            # build and start
odin run build.odin -file -- run -release   # build and start an optimized one
odin run build.odin -file -- check          # type-check, no binary
odin run build.odin -file -- clean
odin run build.odin -file -- -h             # list the flags
```

`run.bat` and `run.sh` are one-line wrappers for `-- run`.

Linking needs MSVC on PATH (Thor links `harfbuzz.lib` and `libtree-sitter.lib`).
`odin run build.odin` finds `VsDevCmd.bat` itself via `vswhere`, so a plain
shell works for it; a bare `odin build main` needs a developer shell.
`odin check` needs neither.

## Testing

```bash
odin run build.odin -file -- test  # every tested package, into bin/test
```

Or one package at a time from a developer shell:

```bash
odin test ui       # font/icon atlas pipeline + ligature shaping + theme loading
odin test thor     # async file load/save round-trip
odin test syntax   # tree-sitter highlighting
odin test plugin   # Lua plugin host
odin test textedit # buffer, cursors, undo/redo
odin test lang     # Odin language intelligence
odin test watch    # file-system watcher
odin test shell    # shell sessions: end markers, prompt trimming
odin test widgets  # console stream handling: control bytes, history, scrolling
```

Tests run with the repository root as the working directory, so they find
`assets/`, `plugins/` and `settings/`.
