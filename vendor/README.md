# Vendored dependencies

## odin-harfbuzz (git submodule)

Odin bindings for HarfBuzz 12.1.0, used for ligature shaping in `ui/shape.odin`.

The bindings expect the static library at `odin-harfbuzz/libs/harfbuzz.lib`.
That file is a local build artifact (gitignored inside the submodule), so it
must be built once per machine:

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
(gitignored inside the submodule), so they must be built once per machine from a
Visual Studio developer shell (`Enter-VsDevShell`):

```powershell
cd vendor/odin-tree-sitter
# Runtime -> tree-sitter/libtree-sitter.lib
odin run build -- install
# Grammar -> parsers/odin/parser.lib + generated bindings + queries
odin run build -- install-parser https://github.com/tree-sitter-grammars/tree-sitter-odin -yes
odin run build -- install-parser https://github.com/tree-sitter-grammars/tree-sitter-lua -yes
odin run build -- install-parser https://github.com/tree-sitter/tree-sitter-c -yes
odin run build -- install-parser https://github.com/tree-sitter/tree-sitter-cpp -yes
odin run build -- install-parser https://github.com/tree-sitter/tree-sitter-go -yes
odin run build -- install-parser https://github.com/tree-sitter/tree-sitter-javascript -yes
odin run build -- install-parser https://github.com/tree-sitter/tree-sitter-typescript "-path=typescript" "-name=typescript" -yes
odin run build -- install-parser https://github.com/tree-sitter/tree-sitter-typescript "-path=tsx" "-name=tsx" -yes
odin run build -- install-parser https://github.com/constantitus/tree-sitter-jai -yes
```

`syntax/syntax.odin` hard-imports every parser above, so a fresh checkout must
install all of them (the exact list mirrors the CI workflows) before the app
will build.

Add a language: `install-parser <grammar-git-url>`, register the parser in
`syntax/syntax.odin` (`highlighter_create`, one `h.languages["<id>"]` line), and
add a `plugins/<id>/plugin.lua` that maps the file extensions to that grammar id
and its capture heads to theme color roles. Grammars whose highlights query
inherits another (typescript/tsx build on javascript) prepend the base query in
`highlighter_create`.