# Vendored dependencies

## odin-harfbuzz (git submodule)

Odin bindings for HarfBuzz 12.1.0, used for ligature shaping in `ui/shape.odin`.

The bindings expect the static library at `odin-harfbuzz/libs/harfbuzz.lib`.
That file is a local build artifact (gitignored inside the submodule), so it
must be built once per machine. `odin run build.odin -file -- deps` does it: it
checks the archive against `HARFBUZZ_SHA256` and writes `vendor/harfbuzz.stamp`,
which names the version, the checksum and the meson flags. A library whose stamp
differs is built again. The recipe by hand, which writes no stamp:

```powershell
# Requirements: Visual Studio (MSVC), Python
python -m pip install --user meson ninja

# From a "x64 Native Tools" developer shell (or Enter-VsDevShell):
curl.exe -LO https://github.com/harfbuzz/harfbuzz/releases/download/12.1.0/harfbuzz-12.1.0.tar.xz
python -c "import tarfile; tarfile.open('harfbuzz-12.1.0.tar.xz').extractall(filter='data')"
cd harfbuzz-12.1.0
meson setup build --buildtype=release -Db_vscrt=mt -Db_ndebug=true -Ddefault_library=static `
    -Dtests=disabled -Ddocs=disabled -Dbenchmark=disabled -Dglib=disabled -Dgobject=disabled `
    -Dcairo=disabled -Dicu=disabled -Dfreetype=disabled -Dchafa=disabled -Dutilities=disabled
meson compile -C build
copy build\src\libharfbuzz.a <repo>\vendor\odin-harfbuzz\libs\harfbuzz.lib
```

Notes:

- `-Db_vscrt=mt` is required: Odin links the static CRT, and a `/MD` build of
  HarfBuzz fails to link with unresolved `__imp__wassert` / CRT conflicts.
- `-Db_ndebug=true` strips `assert()` calls, which otherwise also pull in the
  DLL CRT.
- The `libharfbuzz.a` produced by meson is a regular COFF archive; the `.lib`
  extension is just what the binding's `foreign import` expects.

## odin-tree-sitter (git submodule)

Odin bindings for Tree-sitter, used for syntax highlighting in `syntax/`.

The runtime static lib and each language parser are local build artifacts
(gitignored inside the submodule), so they must be built once per machine:

```bash
odin run build.odin -file -- deps
```

`GRAMMARS` in `build.odin` is the one list of grammars, and each row pins its
grammar to a commit. `install-parser` of the submodule takes no revision — it
clones the default branch — so `deps` first fetches the pinned commit into a
bare repository under `bin/deps/grammars/` and gives the tool that path. Each
parser directory gets a `thor.stamp` (URL, commit, subdirectory, submodule
commit); a parser whose stamp differs is built again.

`syntax/syntax.odin` hard-imports every parser of that list, so a fresh checkout
must build all of them before the app will build.

One parser by hand, from a Visual Studio developer shell — this takes the newest
commit, not the pinned one, so `deps` builds it again:

```powershell
cd vendor/odin-tree-sitter
# Runtime -> tree-sitter/libtree-sitter.lib
odin run build -- install
# Grammar -> parsers/odin/parser.lib + generated bindings + queries
odin run build -- install-parser https://github.com/tree-sitter-grammars/tree-sitter-odin -yes
```

Add a language: a `GRAMMARS` row in `build.odin`, then `deps`; register the parser in
`syntax/syntax.odin` (`highlighter_create`, one `h.languages["<id>"]` line), and
add a `plugins/<id>/plugin.lua` that maps the file extensions to that grammar id
and its capture heads to theme color roles. Grammars whose highlights query
inherits another (typescript/tsx build on javascript) prepend the base query in
`highlighter_create`.

Some grammars keep their `grammar.js`/`src` in a subdirectory (php in `php/`,
ocaml in `grammars/ocaml/`) or export a symbol name that is not a clean Odin
identifier (`tree-sitter-c-sharp` -> `c_sharp`); pass `-path=<subdir>` and/or
`-name=<id>` so the generated package, `tree_sitter_<id>` binding and parser
directory all agree. Config/markup formats without a good grammar (JSON, XML,
INI, Markdown, shell, ...) instead ship a pure-Lua lexer in
`plugins/<id>/plugin.lua` with a `highlight` function and no `grammar` field, so
they need no native build.