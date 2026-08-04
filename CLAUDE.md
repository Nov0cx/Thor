# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Thor is a code editor written in Odin on top of raylib. `README.md` covers user-facing usage and
first-time setup; this file covers what is needed to change the code.

## Commands

`build.odin` is the build driver — run it from the repository root:

```bash
odin run build.odin -file -- deps          # fetch submodules, build HarfBuzz + tree-sitter (once per machine)
odin run build.odin -file                  # build into bin/debug
odin run build.odin -file -- run           # build and start
odin run build.odin -file -- run -release  # optimized, into bin/release
odin run build.odin -file -- check         # type-check only (main reaches every package)
odin run build.odin -file -- test          # every package with tests, into bin/test
odin run build.odin -file -- clean
odin run build.odin -file -- -h -verbose   # flags; -verbose echoes each command
```

Per-package and single tests:

```bash
odin test lang/odin                                            # one package (package name is `odin`)
odin test thor -define:ODIN_TEST_NAMES=thor.test_overlay_exact_and_adjacent # one test: <package>.<proc>
odin check thor -no-entry-point                                # type-check one package, no linking
```

Tests run with the repository root as the working directory, so they find `assets/`, `plugins/` and
`settings/`. When a package gets its first `_test.odin`, add it to the `packages` list in
`run_tests` (`build.odin`) or CI-equivalent runs will skip it.

A push of a `v*` tag runs `.github/workflows/release.yml`: it builds `-release` on all four CI
platforms, packs `bin/release` (binary + `assets/`, `plugins/`, `settings/`) into a zip or tarball,
and publishes them. The publish job needs every build job, so one broken platform makes no release.
A manual run builds the same archives and stops before the publish.

Linking needs MSVC on PATH (Thor links `harfbuzz.lib` and `libtree-sitter.lib`). `build.odin` locates
`VsDevCmd.bat` itself via `vswhere`, so a plain shell works for `odin run build.odin`; a bare
`odin build main` / `odin test <pkg>` requires a developer shell. `odin check` needs neither.

Launching the GUI from an agent-spawned process hangs in `rl.InitWindow` — verify changes with
`odin check` / `odin build` / the test suites, not by running the app.

## Layout and dependency direction

Packages only ever depend downward in this list; keeping that direction is what lets the lower layers
be tested headlessly.

- `piecetable` — the buffer representation. Pure data structure.
- `textedit` — UI-independent editing core: cursors, selection, movement, edits, undo/redo with
  coalescing. Bumps `State.revision` on every content change; everything downstream compares against
  a stored revision to decide what is stale.
- `ui` — raylib layer: `Widget` tree (intrusive linked children + a vtable of
  layout/handle_event/draw/destroy), `Context` (hit testing, focus, event queue, global key hook),
  the font/icon atlas + HarfBuzz shaping (`text.odin`, `shape.odin`), theme loading.
- `widgets` — concrete widgets built on `ui.Widget`. `editor.odin` is the big one: it *borrows* a
  `textedit.State` and never owns document data. Widgets talk to the app through `#type proc`
  callbacks (`Goto_Definition_Proc`, `Hover_Proc`, `Completion_Proc`, …), never by importing `thor`.
- `syntax` / `treecache` — tree-sitter parsing and resident per-buffer trees (incremental re-parse).
  `syntax` yields capture-name-tagged spans and knows nothing about themes or colors.
- `plugin` — the Lua 5.4 VM, the language registry plugins fill at load, and the mapping from
  tree-sitter captures to theme *roles*.
- `lang` + `lang/odin` — language intelligence (see below).
- `setting`, `watch`, `shell` — JSON settings/keybinds, the async recursive file-system watcher,
  process execution.
- `thor` — the application: owns `Thor` (all state), builds the widget tree (`build.odin`), and
  hosts everything else. `main` only sets up the debug tracking allocator and calls
  `thor.init/run/shutdown`.

`Thor.run` is a plain per-frame loop: poll (dropped files, watcher, settings, IO) → reap async
results → plugin ticks (`plugin.manager_dispatch_tick`, throttled to `TICK_INTERVAL`) →
`ui.context_update` → draw → `free_all(context.temp_allocator)`. Anything allocated for one
frame goes in the temp allocator.

## Platform split

Windows, Linux and macOS all build (one workflow each). No shared file may import
`core:sys/windows`: OS calls live in a `<name>_windows.odin` / `<name>_posix.odin` pair tagged
`#+build windows` / `#+build !windows`, with the platform-free part in `<name>.odin`. Odin has no
forward declarations, so the shared file states the contract — the types and procedures both
platform files must supply — as a comment. The pairs are `shell/shell_*`, `watch/watch_*`,
`thor/windows_*` (multi-window records), `thor/dialogs_*` (file pickers), `thor/filemap_*` (the
load worker's read-only mapping) and `thor/reveal_*`. `watch/scan.odin` is deliberately
platform-free so the POSIX watcher's diff is testable on Windows.

Only Windows can be run here, so a POSIX change is verified by cross type-check:
`odin check main -target:linux_amd64` and `-target:darwin_arm64`. Both need libraries the Windows
Odin distribution does not ship — Linux misses `vendor/stb/lib/*.a` (the CI workflows build them),
and macOS misses a Darwin branch in the vendored HarfBuzz binding (`macos.yml` injects one) — so
the panics those two raise are expected noise; any other error is real.

## Multi-window

raylib owns one window per process (the GL context, the input state and `ui`'s font atlas are all
process-global), so **a second window is a second process**, launched with the workspace as its path
argument — exactly what a shell launch passes. `thor/windows.odin` holds the whole mechanism:
`shell.spawn` starts the process, and each window records the folder it owns in
`sessions/windows/<path-key>.json` (pid + HWND) so a folder already open somewhere is raised instead
of opened twice — two processes on one folder would fight over its session file. A record is trusted
only while `IsWindow` holds and the window still belongs to the recorded pid; a crashed window leaves
a record the next reader prunes. user32 cannot be linked (its `CloseWindow`/`ShowCursor` collide with
raylib's), so those calls are resolved from `user32.dll` at runtime. POSIX has no portable way to
raise another process's window, so `windows_posix.odin` proves the pid with `kill(pid, 0)` and
`thor_focus_window` does nothing: the folder still reads as taken, it is just not brought forward.

Folder opens the user drives go through `thor_open_folder_request`, which settles the no-choice cases
and then obeys the `open_folder_in` setting (`ask` / `same` / `new`). `thor_open_folder` itself still
replaces the workspace outright — call it only when the window is already decided.

## Terminals

The console panel holds one terminal per tab, each on a live shell process. `shell/profile_*.odin`
detects the shells installed on the machine (pwsh, Windows PowerShell, cmd, the MSVC developer
prompt, Git Bash, MSYS2, Cygwin, WSL, nu — bash/zsh/fish and friends on POSIX) as `Profile` records:
the executable, its arguments, quiet `init` commands and a `Profile_Kind` that picks the syntax of
the end marker. `shell/session_*.odin` is the process pair: the shell starts **once** with piped
stdin/stdout (stderr shares the stdout pipe, so output stays interleaved) and stays alive, which is
what makes `cd`, environment variables and the loaded MSVC environment persist between commands.

There is no PTY: full-screen TUI programs and ANSI colors are out of scope, and the console strips
escape sequences instead of rendering them. Command completion is found with an **end marker** —
after every submitted command the terminal writes a shell-specific `end_command` that prints
`<token><exit-code>`; its arrival ends the command and carries the status. The reader thread hands
raw bytes over `io_mutex` and `thor_terminal_consume` scans them, so the scan must survive a marker
split across two reads: `carry` holds the tail, `partial_marker_len` releases only what cannot grow
into the token, and a whole token without its newline is held back entirely.

Killing a shell has to take its children with it: Windows puts the process in a Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (started suspended, assigned, then resumed), POSIX calls
`setpgid(0, 0)` in the forked child so `killpg` reaches the whole group. That process group is also
why `session_interrupt` (ctrl + c) works on POSIX and returns false on Windows, where the caller
restarts the shell instead. Teardown is two-phase: `session_terminate` is safe to call while the
reader blocks in `read`, then the thread is joined, then `session_destroy` frees.

`thor/terminal.odin` is the editor side: a `Terminal` owns its `widgets.Console` (a child of the
console stack, only the active one visible), its session and its reader thread, and `Thor.console`
points at the active one — **it is nil when the last terminal is closed**, so every user of it needs
a nil guard. `thor_terminals_shutdown` nils the lists it frees, since draining the I/O queue after it
still pumps terminals.

## Async work

There is one pattern for all off-thread work and it is worth matching exactly: a worker thread does
its job, then appends the job struct to a `[dynamic]^Job` on `Thor` under `io_mutex`; the main thread
drains that queue once per frame and applies the result. File loads/saves (`thor/files.odin`),
terminal output, git status and the whole `lang` seam all use it. Workers never touch widgets and
never allocate from the main allocator without care.

Debug builds run under `mem.Tracking_Allocator`, so leaks and bad frees are reported at exit. Struct
fields are commented `// owned` vs borrowed; respect that — `shutdown` frees exactly the owned ones.

## Language intelligence (`lang`)

Thor's LSP alternative: LSP-shaped features served **in-client** by native analyzers, with a
subprocess LSP client left as an optional backend behind the same seam.

- `lang/lang.odin` is the seam: a `Backend` vtable (`handles`/`resolve`/`destroy`), a `Manager` that
  routes a `Request` by file extension onto a worker pool and reaps `Result`s on the main thread.
  **Byte offsets are the position currency** everywhere (the piece table works in bytes), counted
  over source with CRLF collapsed to LF — read files with `source_read`, not `os.read_entire_file`,
  or offsets into a CRLF file miss by one byte per line; an LSP
  backend would convert UTF-16 at its own edge. A backend that wants the buffer changed answers with
  `Text_Edit`s — it never writes files itself.
- Dispatch discipline: each request kind has exactly one consumer slot (`*_request_id`) on `Thor`, so
  every dispatch goes through `manager_request_latest` (immediate, cancels the older same-kind
  request) or `manager_request_debounced` (for triggers that fire while typing). A cancelled result
  is freed without reaching the handler, so `ok == false` always means "found nothing".
- `lang/odin` is the in-client Odin analyzer, split by concern: `engine.odin` (lifetime + seam),
  `resolve.odin` (entry point every request funnels through, lexical scope), `index.odin` (resident
  stat-invalidated symbol index), `infer.odin`/`typeref.odin`/`decl.odin` (type inference),
  `completion.odin`, `signature.odin`, `symbols.odin` (outline/references/rename), `semantic.odin`,
  `check.odin` (compiler diagnostics), `actions.odin`, `packagedoc.odin`, `builtins.odin` (the
  implicit scope, read off the toolchain), `config.odin`.
- `thor/lang_host.odin` is the editor side: dispatches requests, routes results back to the pane that
  asked, drops superseded ones.
- **`lang/ROADMAP.md` is the living source of truth** for what works and what is missing. Read it
  before adding a feature here, and update it after.

Grammar shapes are the usual source of bugs — tree-sitter-odin's node names often do not match
intuition (`x := v` is `assignment_statement`, `p: Point` is `var_declaration`, a container literal
drops its `[]` from the named children). The repo's technique for settling such a question: drop a
throwaway `z*_test.odin` that recursively prints `ts.node_type` / `node_is_named` / `node_text` for
**all** children (not `ts.node_string`, which hides the anonymous tokens that matter), run it with
`-define:ODIN_TEST_NAMES=`, then delete it.

## Syntax highlighting and plugins

Every language is a Lua plugin at `plugins/<id>/plugin.lua`, backed either by a tree-sitter grammar
(`grammar = "<name>"`, capture names mapped to theme roles) or by a pure-Lua `highlight` function
returning `{start, end, role}` spans for formats where a grammar is overkill. Extensionless names
(`Makefile`, `Dockerfile`) work because `thor_highlight_key` falls back from extension to basename.

Colors resolve grammar capture → theme role (plugin) → `rl.Color` (`ui.theme_role_color`); the
analyzer's semantic tokens are layered over the grammar spans in `thor/highlight.odin`
(`thor_merge_semantic` must emit ascending, non-overlapping spans — the editor walks them with one
forward-only cursor).

Adding a tree-sitter grammar means keeping **three lists in sync**, or the build breaks for everyone:
the `GRAMMARS` table in `build.odin`, the hard imports + `h.languages[...]` registrations in
`syntax/syntax.odin`, and the four per-platform `.github/workflows/*.yml` (`release.yml` needs no
edit — it calls `build.odin -- deps`, which reads `GRAMMARS`). Then add the `plugins/<id>/plugin.lua`.
Grammars are compiled in; *queries* are data — a plugin's `highlights = "highlights.scm"` (or an
inline query) replaces the built-in one via `syntax.set_highlights`, and a query that fails to
compile is reported with its offset instead of silently uncoloring the language.

Each plugin runs sandboxed (`plugin/sandbox.odin`): its own `_ENV`, a trimmed standard library (no
io/package/debug/`load`), path-confined file access, a two-second wall-clock budget per call, and a
`thor` table holding only what `plugins/<id>/plugin.json` grants (`exec`/`read`/`write`/`ui`/`keys`).
A plugin that wants a permission stays unloaded until the user allows it: `thor_load_plugins`
(`thor/plugin_trust.odin`) scans first, runs the permission-free plugins at once, and holds the rest
for one batched prompt whose answer lands in `sessions/plugin-grants.json`. Settings shows the same
state as a "PLUGIN PERMISSIONS" section (`thor/settings_ui.odin`): allowing there loads the plugin on
the spot, blocking a running one waits for a restart.
Two rules keep the layering: a Lua C callback runs under `runtime.default_context()`, so anything
allocating host-owned data must first set `context.allocator = m.allocator`; and the `plugin` package
never touches UI — `thor.panel` describes widgets as `View_Node` data (`plugin/view.odin`) that
`thor/plugin_panel.odin` turns into widgets, and `thor.ts` (`plugin/api_ts.odin`) hands out tree and
node userdata over the same seam. `plugins/README.md` is the plugin-author-facing reference.

## Runtime resources and configuration

Thor moves its working directory to the executable at startup, so `assets/`, `plugins/` and
`settings/` are loaded *beside the binary*; the build stages fresh copies there on every build. The
folder Thor opens still comes from the directory it was launched in.

Configuration is layered: global `settings/*.json` (settings, keybinds, comment prefixes) overlaid by
a workspace's `.thor/` directory. `.thor/` also holds `tasks.json` (named shell commands surfaced in
the titlebar) and `odin-analyzer.json` (per-workspace analyzer collections and feature toggles —
deliberately Thor's own file, not `ols.json`). This repo has its own `.thor/`, so those files serve
as working examples.

## Code style

Comments are terse Odin-standard-library style: a short `//` line above the declaration stating
*what* something is, not a paragraph justifying why. Keep it short. Keep genuinely load-bearing gotchas, compressed
to one line. Field comments stay short (`// owned`, `// NOREF when unset`). Use ASD-STE100 Simplified Technical English (STE).
Dont do segment comments. Dont write comments like a story, only describe feature.

Indentation is four spaces, not tabs — which is why `-strict-style` is deliberately absent from the
build flags (`-vet` is available via `build.odin -- -vet`).

Handle always errors.

Do if (cheap && expensive) and if (likelytofail && unlikelytofail).

## Other missing features

look at .todo.txt
