---
name: verify
description: Runs Thor's verification sweep — per-package type-check, the Linux and macOS cross-checks with their expected noise filtered, and the test suite. Use after changing Odin code and before reporting work as done.
---

# Verify

Thor's verification sweep. Type-checks and the test suites are the signal here:
they need no display and they are what CI gates on. The GUI does start from an
agent-spawned process when a change really needs the running app — launch it
detached and read `user/thor.log` beside the binary, which records what every
startup phase cost.

Run the steps in order and stop at the first real failure.

## 1. Type-check the touched packages

`odin check` needs neither MSVC nor a display, so it always works.

```bash
odin check <package-dir> -no-entry-point
```

Package directories: `piecetable`, `textedit`, `ui`, `widgets`, `syntax`,
`treecache`, `plugin`, `lang`, `lang/odin`, `setting`, `watch`, `shell`, `thor`.
For the entry package use `odin check main` (no `-no-entry-point`). For
`build.odin` use `odin check build.odin -file`.

The PostToolUse hook already checks the package of each edited file, so this
step is usually confirmation. Run it anyway for packages that only changed
indirectly.

## 2. Cross type-check Linux and macOS

Only Windows runs here, so a POSIX change is verified by cross type-check.

```bash
odin check main -target:linux_amd64
odin check main -target:darwin_arm64
```

**Both always report errors. Those errors are expected noise, not regressions.**
The Windows Odin distribution misses libraries these targets need:

- **linux_amd64** — `vendor/stb/lib/*.a` is absent, so `vendor:stb/truetype`
  and `vendor:stb/rect_pack` raise `Compile time panic: Could not find the
  compiled STB libraries`. The CI workflows build them with
  `sh "$(odin root)vendor/stb/src/build_stb.sh" unix`.
- **darwin_arm64** — the vendored HarfBuzz binding has no Darwin branch, so
  `vendor/odin-harfbuzz/harfbuzz/*.odin` raises `Undeclared name: hb` at every
  `foreign hb` block. `macos.yml` injects that branch.

Filter those two signatures out. **Any other error is real** — in particular any
error whose path is under `thor/`, `lang/`, `shell/`, `watch/`, `ui/`,
`widgets/`, `plugin/`, `syntax/`, `treecache/`, `textedit/` or `piecetable/`.

Do not read the exit code through a pipe — it reports the pipe's status, not
odin's. Judge by the error text.

Caveat: a compile-time panic stops the check early, so the cross-check is a
partial signal. It catches OS-call and build-tag mistakes, which is what it is
for; it does not prove the whole tree compiles for that target.

## 3. Run the tests

Linking needs MSVC on PATH (Thor links `harfbuzz.lib` and `libtree-sitter.lib`),
so a bare `odin test <pkg>` needs a developer shell. `build.odin` finds
`VsDevCmd.bat` itself via `vswhere`, so prefer the driver:

```bash
odin run build.odin -file -- test
```

It runs every package even after one fails, then names the failed ones together.
For a single package or a single test from a developer shell:

```bash
odin test lang/odin
odin test thor -define:ODIN_TEST_NAMES=thor.test_overlay_exact_and_adjacent
```

Tests run with the repository root as the working directory, so they find
`assets/`, `plugins/` and `settings/`.

## 4. Check the test-package list

`odin check` skips `_test.odin` files entirely, so a new test file is invisible
to steps 1 and 2. When a package gets its **first** `_test.odin`, add it to the
`packages` list in `run_tests` (`build.odin`) — otherwise CI skips the package
silently and the tests never gate a merge.

Confirm the package appears there whenever the change adds a test file.

## 5. Update the roadmap

`lang/ROADMAP.md` is the living source of truth for what the language
intelligence does and does not do. If the change added, finished or removed a
feature there, update it.

## Reporting

Say what ran and what it produced. If a step was skipped — no developer shell
for the tests, for instance — say so plainly rather than implying it passed.
