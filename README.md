# Thor

[![Windows](https://github.com/Nov0cx/Thor/actions/workflows/windows.yml/badge.svg)](https://github.com/Nov0cx/Thor/actions/workflows/windows.yml)
[![Ubuntu](https://github.com/Nov0cx/Thor/actions/workflows/ubuntu.yml/badge.svg)](https://github.com/Nov0cx/Thor/actions/workflows/ubuntu.yml)
[![macOS](https://github.com/Nov0cx/Thor/actions/workflows/macos.yml/badge.svg)](https://github.com/Nov0cx/Thor/actions/workflows/macos.yml)
[![Arch Linux](https://github.com/Nov0cx/Thor/actions/workflows/arch.yml/badge.svg)](https://github.com/Nov0cx/Thor/actions/workflows/arch.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Language: Odin](https://img.shields.io/badge/language-Odin-1E4C8A)

This an editor written in [Odin](https://odin-lang.org/) with [raylib](https://pkg.odin-lang.org/vendor/raylib/v6/).

## Disclaimer

This repo is still in development, everything can break or change at any time.

## Dependencies

Thor depends on:

- [HarfBuzz](https://harfbuzz.github.io/) (via the
  [odin-harfbuzz](https://codeberg.org/mgavioli/odin-harfbuzz) bindings) for ligature shaping.
- [tree-sitter](https://tree-sitter.github.io/tree-sitter/) (via
  [odin-tree-sitter](https://github.com/laytan/odin-tree-sitter))
  for syntax highlighting.
- Lua 5.4 (Odin's bundled `vendor:lua`) for the plugin system.

### Syntax highlighting

Each language is a plugin under `plugins/<id>/plugin.lua`. Two backends:

- **tree-sitter grammars** for full languages — Odin, Lua, C, C++, Go, Jai,
  JavaScript/JSX, TypeScript, TSX, Rust, Python, Ruby, Java, Kotlin, Zig, C#,
  PHP, Haskell and OCaml. Their parsers are local build artifacts installed via
  `odin run build -- install-parser` (see [vendor/README.md](vendor/README.md));
  `syntax/syntax.odin` hard-imports each, so every grammar the source references
  must be installed before the app builds (CI installs the full list).
- **pure-Lua lexers** for config/markup formats where a grammar is overkill —
  JSON, Markdown, shell, batch and similar. These need no native build; a plugin
  just returns spans from a `highlight` function.

Both submodules are needed, so clone with them:

```bash
git clone --recurse-submodules https://github.com/Nov0cx/Thor
```

### Windows

Two native libraries are local build artifacts, each built once per machine.
See [vendor/README.md](vendor/README.md) for both recipes:

- **HarfBuzz** into `vendor/odin-harfbuzz/libs/harfbuzz.lib` (MSVC + meson;
  `-Db_vscrt=mt` is required so it links against Odin's static CRT).
- **tree-sitter** runtime and at least one grammar into
  `vendor/odin-tree-sitter/` via the bundled `odin run build` tool.

Lua links against `lua54.dll`; `build.bat` copies it next to the
executable from Odin's `vendor` directory the first time it is missing.

### Linux

The system HarfBuzz library is used; install it through your package manager
(e.g. `libharfbuzz-dev`). The tree-sitter runtime and grammars are still built
through the bundled `odin run build` tool. Lua links statically from the vendor
package, so no shared library needs copying.

## Building Windows
```bash
./build.bat
```

## Building Unix
```bash
./build.sh
```

## Testing
```bash
# from the repository root
odin test ui       # font/icon atlas pipeline + ligature shaping + theme loading
odin test thor     # async file load/save round-trip
odin test syntax   # tree-sitter highlighting
odin test plugins  # Lua plugin host
odin test textedit # buffer, cursors, undo/redo
```
