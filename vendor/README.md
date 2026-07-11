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
