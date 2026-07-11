# Thor

This an editor written in [Odin](https://odin-lang.org/) with [raylib](https://pkg.odin-lang.org/vendor/raylib/v6/).

## Disclaimer

This repo is still in development, everything can break or change at any time.

## Dependencies

Thor uses [HarfBuzz](https://harfbuzz.github.io/) (via the
[odin-harfbuzz](https://codeberg.org/mgavioli/odin-harfbuzz) bindings, included
as a git submodule) for ligature shaping, so clone with submodules:

```bash
git clone --recurse-submodules https://github.com/Nov0cx/Thor
```

### Windows

The HarfBuzz static library is a local build artifact and must be built once
per machine into `vendor/odin-harfbuzz/libs/harfbuzz.lib`. See
[vendor/README.md](vendor/README.md) for the full recipe (MSVC + meson;
`-Db_vscrt=mt` is required so it links against Odin's static CRT).

### Linux

The system HarfBuzz library is used; install it through your package manager
(e.g. `libharfbuzz-dev`), no manual build needed.

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
odin test ui    # font/icon atlas pipeline + ligature shaping
odin test thor  # async file load/save round-trip
```
