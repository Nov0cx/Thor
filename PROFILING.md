# Profiling Thor

A plan for profiling each part of Thor with the spall profiler (`prof`), and the bottlenecks the
first pass found. Measured on 2026-11-10 on Windows 10, commit `59468b9`, with the repository itself
open as the workspace (1 214 directories, 10 648 files).

## 1. Method

### Builds

| Build | Command | Use |
|---|---|---|
| Zones | `odin run build.odin -file -- -profile` | Real timings. Only the zones in the code record. |
| All procedures | `odin run build.odin -file -- -profile-all` | Call trees. The timings are inflated, and 5 s of run makes a 1.2 GB trace. |

The trace is `bin/profile/user/thor.spall`. Open it in the spall viewer, or summarise it with a script
(see "Tools" below).

### Run

1. Start `bin/profile/thor.exe <workspace> [files]` detached, with the workspace as the working
   directory.
2. Wait for `Startup took` in `bin/profile/user/thor.log`.
3. Press Esc twice. A fresh profile build asks for plugin permissions, then for language-server
   trust, and both prompts take the input.
4. Run the scenario.
5. Close with `WM_CLOSE`, not `Stop-Process`. The main thread writes its buffer only in
   `prof.destroy`, so a kill loses the main-thread trace.

### Scenarios

| System | Scenario | Zones to read |
|---|---|---|
| Startup | Start with a session that has two Odin files open | `init`, the first 3 frames, `[startup]` log laps |
| Frame loop | Stand still for 8 s | `frame`, `poll`, `build`, `draw`, `present` |
| Editor view | 300 wheel steps down and up in `thor/thor.odin` | `build` per frame, `build` passes per frame |
| Typing + language | 100 characters typed in `thor/view.odin`, then 120 × ctrl+z | `thor_update_highlights`, the `lang worker` zones |
| Search | Find in files, workspace symbols (ctrl+q), quick open | `Workspace_Symbols`, the `file search` thread |
| Terminal | `1..20000` in a PowerShell terminal | `thor_process_terminals`, `draw` |
| Shutdown | Close after each scenario, and once with an update check running | `shutdown` |
| Cold start | First run of a new binary, update check due | `init`, `shutdown` |

Run each scenario 3 times and use the median. A frame over 16.7 ms is only a problem when the work
in it (frame minus `present`) is over budget: `present` holds the vsync wait.

### Budgets

| Measure | Budget |
|---|---|
| Frame work (frame − present), steady | < 2 ms |
| Any single frame on the main thread | < 16 ms |
| Startup to first full frame (warm) | < 500 ms |
| Language request per keystroke | < 30 ms |
| Shutdown | < 300 ms |

## 2. Results

### Steady state — fine

| Zone | Mean | p99 / max |
|---|---|---|
| `build` (one pass) | 0.25–0.35 ms | 0.5 ms |
| `draw` | 0.17–0.28 ms | 0.7 ms (one 20 ms spike while typing) |
| `poll` | 0.06 ms | 0.7 ms |
| `lang dispatch` | 0.003 ms | 0.2 ms |
| Incremental `thor_update_highlights` | 0.6 ms | — |
| `Completion` (lang worker) | 0.8 ms | 3.8 ms |

Scrolling makes 1.5 `build` passes per frame and does not change the cost of a pass. The frame loop
is not a bottleneck.

### Bottlenecks, worst first

**B1. Shutdown waits for the update check: 11.8 s.**
On the first run of a new binary, the `shutdown` zone took 11 844 ms, all self time. That run was the
only one that wrote `sessions/update.json`. `thor_drain_io` waits for every in-flight job, and the
check job (`update_check_worker` → `update.check`) has no cancel point: `thor_cancel_update` sets a
flag that only the download reads. The check runs the tool probes (`PROBE_TIMEOUT` 5 s each) and the
API call (`API_TIMEOUT` 20 s), so a quit during a slow check can hang for 20 s or more. With
`last_check` set to 0 on a fast network, shutdown took 459 ms, against 100–250 ms with no check.
*Fix:* do not wait for a check job at shutdown. Detach it, or have it test `cancel` and kill its
child process.

**B2. Workspace symbols, first query: 3 971 ms.**
The first `Workspace_Symbols` request reads and parses the whole workspace through the sema DB.
The next 6 requests took 115 ms on average. The prewarm thread finds only the Odin root and the
package list, so the first ctrl+q pays the full index.
*Fix:* build the workspace item trees in the prewarm thread, at low priority. Stream partial results
for a long first query.

**B3. Cold language requests on the first open: 270–380 ms.**
On the first open of `thor/view.odin` (2 185 lines): `Syntax_Diagnostics` 376 ms, `Semantic_Tokens`
266 ms, `Diagnostics` (`odin check`) 377 ms. While typing, the warm means are 37 ms
(`Syntax_Diagnostics`, which also runs the name checks) and 17 ms (`Semantic_Tokens`, max 266 ms),
across 124 semantic requests for 220 edits. These run off the main thread, so they cost latency, not
frames. The live check is above the 30 ms budget.
*Fix:* make `name_diagnostics` incremental per declaration, or debounce it longer than the
syntax-error part. Find out why a warm `Semantic_Tokens` sometimes takes 266 ms (a lost `Type_State`
cache entry?).

**B4. First highlight of a file stalls the main thread: 95 ms + 20 ms.**
The first frame after `init` takes 125–140 ms. `thor_update_highlights` uses 92–105 ms of self time,
and `treecache.for_source` (the tree-sitter parse) uses 19–22 ms in the same frame. Later calls take
0.6 ms. `syntax.highlighter_query` compiles the highlights query of a language on its first use, on
the main thread. That is the probable cost; a zone around `highlighter_query` will confirm it.
*Fix:* compile the queries of the restored files' languages on a thread during `init`, or the
query of every language after the first frame.

**B5. Shell spawn on the main thread: 20–25 ms frame.**
About 500 ms after start, one frame takes 25–31 ms. `thor_update_files` → `thor_process_io` →
`thor_apply_shell_profiles` → `thor_terminal_open` (`CreatePseudoConsole` + `CreateProcessW`) takes
23 ms.
*Fix:* create the pty and the process on the terminal's reader thread, and show the tab at once.

**B6. Synchronous fsync writes at startup and shutdown: 20–150 ms each.**
Each `atomicfile.write` flushes the file to disk. In the all-procedures trace, 6 calls to
`_flush_internal` took 564 ms (94 ms mean). Real-time costs:
`thor_save_session` 40–60 ms at shutdown, `thor_clipboard_history_save` (wipe + write) the largest
shutdown item, and at startup `thor_record_recent_workspace` and `thor_register_window` (one write
each, both before the first frame).
*Fix:* write the startup records on a worker thread. At shutdown, write the files in parallel, or
flush once for all of them. A recent-workspace list does not need an fsync.

**B7. First frames after startup: `present` 50–80 ms.**
One frame about 530 ms after start spends 50–80 ms in `present`. This is probably the first upload
of the font atlas pages and the first shader use. It shows once per start.
*Fix:* needs a zone split first (see G3) before a fix.

**B8. Idle redraw at 60 fps.**
With no input and no animation, Thor builds and draws the full tree 60 times a second: about
0.5 ms CPU per frame, plus the GPU and the swap. This costs power on a laptop, not frames.
*Fix:* when no input, job result, timer or animation is pending, wait for events
(`rl.EnableEventWaiting`, or a lower target FPS until the next event).

**B9. Settings poll: 18 `stat` calls every 0.4 s.**
`thor_poll_settings` takes 0.6–1.2 ms each time it runs (p99 0.7 ms): `thor_settings_signature`
and `thor_lsp_signature` stat every config layer.
*Fix:* use the async watcher for the config directories, or poll every 2 s.

### Not a bottleneck

- Font bake: 13 jobs, 50–77 ms in total, on the `font load` thread.
- Git status: about 110 ms for each git call, on its own thread.
- Startup (warm): `init` 360–390 ms, of which `InitWindow` is 247 ms. The cold first start of a new
  binary took 1 296 ms.

## 3. Gaps in the instrumentation

**G1. `thread_scope` workers record nothing.** `prof.thread_scope` only names the thread.
`file search`, `file index`, `git status`, `file load`, `file save` and `odin prewarm` therefore have
no zones in a zones build: find in files ran, but its trace is empty. Make `thread_scope` also open a
zone with the thread's name.

**G2. `init` and `shutdown` are mostly self time.** `init` has 315–340 ms of self time and B1 showed
up only as self time. Add zones for `InitWindow`, `thor_restore_session`, `thor_drain_io`,
`thor_terminals_shutdown`, `lang.manager_destroy` and the session writes. The `[startup]` laps in
the log can become zones.

**G3. `present` mixes vsync and GPU work.** Put separate zones on `render.draw`, `rl.EndDrawing` and
the swap, so that a slow GPU frame is not hidden in the vsync wait.

**G4. Language zones have no context.** A `lang worker` zone gives only the request kind. Pass the
path and the revision in spall's `args` field, and add a zone for the time a request waits in the
queue. That wait is the latency the user sees.

**G5. `-profile-all` is too large.** 5 s of run gives 1.2 GB and 3.4 million `prop_is_set` events.
Add a filter (a package list, or a minimum duration that drops short events at exit) so that the
full mode works on a 30 s scenario.

**G6. No summary tool in the repository.** A trace is binary. This pass used a scratch Odin tool that
reads the spall v3 stream and prints self and total time per zone and per thread, and the call tree
under named roots. That tool and the scenario driver could go into `tools/` as a `build.odin --
profile-report` step, with the budgets above as `-strict` checks, as `bench` has.

## 4. Other finding

**The terminal sends its shell's output to Thor's stdout when that stdout is redirected.**
The terminal scenario typed `1..20000` and the pane showed no prompt and no output. All 20 000
lines, and the `PS D:\thor>` prompt, were in the file that Thor's stdout was redirected to.
`shell/pty_windows.odin` calls `CreateProcessW` with `EXTENDED_STARTUPINFO_PRESENT` but without
`STARTF_USESTDHANDLES`, so the child inherits the parent's redirected standard handles in place of
the pseudo-console. This affects any start of Thor with redirected output: a script, a launcher, the
console-subsystem debug and profile builds. *Fix:* set `si.StartupInfo.dwFlags |= STARTF_USESTDHANDLES`
and leave the three handles null.

## 5. Next steps

Done in the second pass; section 6 has the state of each item. Still open: the per-declaration
body cache (B3), an analyzer ignore list for nested worktrees, and a scenario driver that does not
need the desktop (G6).

## 6. Status

Second pass on 2026-11-10, branch `perf/bottlenecks`, with the zones of G1–G4 in place. Measured
with `D:\thor-perf` (a worktree of this repository, no nested worktrees) as the workspace and
`thor/thor.odin` + `thor/view.odin` open. Each item is fixed, not fixable, or not needed.

| Item | Status | Commit | Before → after |
|---|---|---|---|
| B1 Shutdown waits for the update check | Fixed | `30b1cc5` | A cancel kills the probe, API and git commands within 50 ms (`shell.run_status` takes a `cancel` flag). |
| B2 Workspace symbols, first query | Fixed | `5dce252` | The prewarm thread reads the workspace item trees at low priority: first query 482 → 85 ms (release flags). A quit during the walk waits 34 ms. |
| B3 Cold language requests | Partly not needed, partly planned | — | See below. |
| B4 First highlight stalls the main thread | Fixed | `9adf241`, `f842ef8` | Confirmed: the query compile was 110–170 ms on the main thread. It now runs on a `query compile` thread, and the first parse of a buffer of 32 KB or more on a `first parse` thread. The file shows uncolored for those frames. Startup 475 → 340 ms; no main-thread frame over 18 ms remains in the first second except B7. |
| B5 Shell spawn on the main thread | Fixed | `8823339` | The reader thread starts the pseudo-console and the shell. The 20–28 ms frame is gone. |
| B6 fsync writes | Fixed at startup; not needed at shutdown | `c62aeb2` | `atomicfile.write(durable = false)` for the window records, the recent-workspace list and the last-workspace pointer: 50–120 ms less before the first frame. Shutdown is 135–200 ms, under its 300 ms budget, and the session and clipboard files keep their fsync. |
| B7 First `swap` 50–85 ms | Not fixable in Thor | — | G3 shows it is the swap itself (`render.draw` is under 4 ms): the driver's and the compositor's first present after the window shows. It happens once. |
| B8 Idle redraw at 60 fps | Fixed | `8e5de69` | A frame whose draw list hashes the same as the last one skips the draw and the swap. Idle: 669 of 726 frames skipped. The build still runs every frame (~0.3 ms), so input latency does not change. dt now comes from `render.poll_input`'s own clock. |
| B9 Settings poll | Not needed | — | Under 1.2 ms every 0.4 s; never shows above 2 ms in a trace. |
| Pty handles | Fixed | `fa2442b` | `STARTF_USESTDHANDLES` with null handles. |
| G1 `thread_scope` workers record nothing | Fixed | `b985522` | `thread_scope` also opens a zone named after the thread. |
| G2 `init` and `shutdown` are self time | Fixed | `7bc7a13` | Each `[startup]` lap is a zone; the shutdown writes and teardown steps have zones. |
| G3 `present` mixes vsync and GPU work | Fixed | `7bc7a13` | `models`, `draw list` and `swap` zones; an `idle` zone for a skipped frame. |
| G4 Language zones have no context | Fixed | `b985522` | Args: `wait=<ms> rev=<n> <path>`. |
| G5 `-profile-all` is too large | Fixed | `d523dde` | `-profile-min:<µs>` drops leaf calls under the threshold: a 7.6 s run made 88 MB at 5 µs, where 5 s made 1.2 GB before. |
| G6 No summary tool | Fixed in part | `f884cb5` | `tools/profreport` (summary, `-list`, `-min`, `-thread`). The scenario driver and a `-strict` budget step are not in the repository: the driver sends keys to the desktop, which is not safe to run unattended. |

### B3 in detail

- **Cold first requests (270–440 ms).** These are the first check of a package: parse, item trees,
  imports and types. They run on a worker while the file is already shown. The prewarm now covers
  the item trees; the types of a live buffer cannot be frozen (`type_cache.odin`). Not needed.
- **Warm `Semantic_Tokens` of 266 ms.** Not reproduced: 30 edits in `thor/view.odin` gave a median
  of 10 ms and a max of 19.5 ms. The 266 ms in section 2 was the cold first request, which runs
  beside the cold live check.
- **Warm live check (`Syntax_Diagnostics`).** Median 30 ms, p90 36 ms, max 75 ms under edits; the
  analyzer bench budget is 50 ms (`BUDGET_DIAGNOSTICS_MS`), and `build.odin -- bench` gave a p95
  of 56 ms on a loaded machine. It never piles up: the host keeps one live check in flight per
  editor, debounced, and drops a result for an old revision. `body_diagnostics` is about 28 of
  45 ms and `undeclared_names` about 10 ms. The fix is a per-declaration cache, planned in
  `lang/LANGUAGE_INTELLIGENCE.md` section 10 ("Per-declaration body diagnostics").

### Found on the way

- **A Thor run with a nested worktree as its workspace** (`.claude/worktrees/*`) reads and parses
  every checkout in it, which is probably why B2 was 4 s in section 2. A workspace ignore list for
  the analyzer would fix that; it is not built.
- **Idle frames run 16.5–17 ms**, not 16.7, because `time.sleep` on Windows overshoots by up to a
  millisecond. No effect on input.
