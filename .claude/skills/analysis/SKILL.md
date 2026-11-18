---
name: analysis
description: Full-repo audit of Thor — parallel per-package agents scoring bugs, style, performance and missing features against CLAUDE.md, verified and written to ANALYSIS.md. Use when asked for a repo analysis, audit, or health check, or to refresh an existing ANALYSIS.md.
---

# Analysis

A full audit of the Thor repository. The product is `ANALYSIS.md` at the repo root (gitignored) — a
living document, not a one-shot report. **Report only: never edit source during an analysis.** If a
fix is obvious, name it in the finding.

Run the phases in order. Phase 2 is the only one that uses agents.

## Phase 0 — Re-run or first run

`ANALYSIS.md` exists → this is a refresh. Read it first, and copy it to the scratchpad before the
first edit. The document's markers:

- **[DONE]** — the code no longer shows the fault. It is the document's history and is **never
  deleted**; keep the original text after it, with a short note of why (`fixed`, `code removed`,
  `moot`). Code that was removed counts as done.
- **[V]** — the author of the document re-read the cited lines.
- **(new)** — first reported by the latest run.

Carry every item forward and give each still-open item to the agent that owns its file for a
re-check (see the brief template). A refresh edits the document in place so it diffs cleanly:
re-check notes go after the old text (*Re-check: still reproduces (`file:line`)*), new findings
continue each list's numbering under a "New in this run (<date>)" heading, and the old
methodology stays as "Run N" below the new one.

`ANALYSIS.md` is absent → first run. Skip to phase 1.

## Phase 1 — Recon (do this yourself, not in an agent)

Cheap facts that set the document's frame and that agents would each redo:

- `git log --oneline -15`, the current branch and HEAD; on a refresh also the commit count since
  the last run's commit.
- Files, lines, test files and test lines per package directory, from one `find` over non-vendor
  `.odin` files (`bin/`, `build/`, `vendor/`, `.claude/` excluded). The 34 known packages:
  `atomicfile`, `prof`, `lockfree`, `luaconf`, `piecetable`, `textedit`, `input`, `platform`,
  `font`, `theme`, `snippet`, `search`, `markdown`, `editview`, `render`, `syntax`, `treecache`,
  `plugin`, `lang`, `lang/odin`, `lang/odin/syntax`, `lang/odin/syntax/gen`, `lang/odin/sema`,
  `lang/odin/format`, `lang/lsp`, `setting`, `watch`, `shell`, `vt`, `msvc`, `update`, `thor`,
  `main`, `tools/profreport`. A directory the list does not name is a new package: add it here and
  to an agent below.
- The non-test line count of each agent's share (phase 2). An agent that holds more than about
  10,000 non-test lines does not read it in full — split it before launching.
- Repo-wide grep for `TODO|FIXME|XXX|HACK` in non-vendor `.odin` files.
- `.todo.txt`, if present (gitignored).
- `lang/LANGUAGE_INTELLIGENCE.md`'s stated gaps: §10 "Missing" and §11 "Known issues".
- The `packages` list in `run_tests` (`build.odin`) against the packages that hold a `_test.odin`
  — a mismatch means CI silently skips a suite. `VET_PACKAGES` against every repository package.
- The three grammar lists: `GRAMMARS` (`build.odin`), the imports and `h.languages[...]` in
  `syntax/syntax.odin`, and `plugins/<id>/plugin.lua`.
- The plugin count under `plugins/`, the shipped `settings/*.lua` (`settings`, `keybinds`,
  `comments`, `tips`, `lsp`) and `.thor/*.lua` — section 7 compares against them.

## Phase 2 — Parallel package agents

Twenty agents, `subagent_type: general-purpose`, in two waves of ten — twenty at once runs into the
usage limit. Issue each wave's Agent calls in one message, and write nothing until all twenty have
reported. Keep this partition stable across runs — it is what makes two analyses comparable. A
file no group names goes to the group of its nearest seam.

1. `piecetable` + `textedit`
2. `font` + `render` + `theme` + `input` + `platform`
3. `editview` + `snippet` + `search` + `markdown`
4. `plugin` + `syntax` + `treecache` + the Lua under `plugins/`
5. `lang` + `lang/lsp`
6. `lang/odin` requests: `engine`, `check`, `config`, `package_live`, `syntax_check`,
   `telemetry`, `body_check`, `name_check`, `vet_check`, `target`, `definition`,
   `type_definition`, `references`, `completion`, `hover`, `signature`, `semantic`, `inlay`,
   `symbols`, `package_doc`, `builtins`, `path_*`, `memory_*`
7. `lang/odin` edits and caches: `refactor`, `extract`, `move_decl`, `change_signature`,
   `create_decl`, `auto_import`, `edits`, `actions`, `fixes`, `compiler_fixes`, `resolve_action`,
   `hierarchy`, `selection`, `lens`, `formatter`, `ignore`, `file_target`, `body_cache`,
   `tree_cache`, `count_cache`
8. `lang/odin/format` + `lang/odin/syntax` (+ `gen`, `syntax.schema`). The printer's worst fault
   is output that changes or loses code, so the brief lists the constructs to trace (attributes,
   directives, `foreign`, `when`, polymorphic parameters, `x.?`, unary chains, comments in every
   position, Format Range/on-type windows, a file with a parse error) and asks for an input that is
   not idempotent. The parser must terminate on hostile input; `reparse` ownership chains.
9. `lang/odin/sema` front and DB: `db*`, `item_tree`, `when`, `package`, `imports`, `scope`,
   `resolve`, `files`, `source`, `target`, `cycle`, `inputs`, `slot_table`, `tree_codec`, `where`,
   `poly_reach`, `using`, `shape`
10. `lang/odin/sema` types: `types`, `check`, `const`, `expr`, `call`, `builtins_check`, `query`,
    `float_lit`, `layout`, `type_cache`

Wave two:

11. `lang/odin/sema` diagnostics and flow: `diagnose`, `cfg`, `flow`, `liveness`, `escape`,
    `ownership`, `temp_flow`, `nil_deref`, `vet*`, `fmt_verbs`, `naming`, `logic`, `defer_loop`,
    `deprecated`, `ignored`, `nested`, `range_copy`. Asks for false positives as Odin snippets.
12. `thor` core: `thor`, `state`, `files`, `session`, `workspace`, `panes`, `windows*`, `watcher`,
    `settings_watch`, `migrate_lua`, `filemap_*`, `unsaved`, `paths`, `signal`, `logging`,
    `watch_outside`
13. `thor` seams: `lang_host`, `lsp_trust`, `lsp_ui`, `lsp_config`, `plugin_host`, `plugin_trust`,
    `plugin_panel`, `plugin_commands`, `highlight`, `format`, `peek`, `problems`, `diagnostics`,
    `inlays`, `occurrences`, `codeactions`, `undo_history`, `undo_graph`, `permission`
14. `thor` terminal and git: `terminal`, `console_view`, `console`, `shell_integration*`, `git*`,
    `tasks`
15. `thor` input and navigation: `commands`, `actions`, `menus`, `menu`, `palette`, `find`,
    `search_files`, `explorer`, `code_nav`, `select`, `jumplist`
16. `thor` editor and settings views: `view`, `editor_overlay`, `controls`, `tokens`, `tooltips`,
    `settings_view`, `settings_ui`, `theme*`, `color_picker`
17. `thor` other views: `tutorial*`, `tips`, `welcome`, `whats_new`, `markdown_view`, `pdf_view`,
    `model_view`, `hex_view`, `image_view`
18. `thor` platform pairs and tools: `cli*`, `clipboard*`, `dialogs_*`, `reveal_*`, `rename_*`,
    `wm_*`, `update`, `update_swap`, `ext_update`, `latex*`, `docs`, `encoding`, `file_icon`,
    `file_language`, `file_target`
19. `setting` + `watch` + `shell` + `vt` + `msvc` + `update` + `atomicfile` + `lockfree` +
    `luaconf` + `prof` + `main` + `tools/profreport` + `build.odin` + `.github/workflows/`
20. Documentation and shipped configuration, no Odin: `README.md`, `CHANGELOG.md` (each `v*` tag
    has a heading), `docs/` (`generate_html.py` included), `plugins/README.md`, `settings/*.lua`,
    `.thor/*.lua`. Each claim is checked against the code that implements it, and a finding cites
    both sides.

Out of scope: `vendor/` (Loom, the UI library, included), `bin/`, `build/`, `assets/`, `sessions/`,
`user/`, `.claude/`. Lua under `plugins/` counts only for agent 4.

Each agent's brief carries the rules only its files have, taken from CLAUDE.md:
- the Loom and `render.draw` rules, raylib only in `platform` (2, 16, 17);
- the snippet sync at each editor intent, the inlay and zone rules (3);
- the sandbox, the callback allocator, the three grammar lists (4);
- the `lang/lsp` import list, lock order and UTF-16 position conversion (5);
- the snapshot, `request_checker` and `Text_Edit`-only rules (6, 7);
- the sema lock order, refcounts, Checker lifetime and freeze rules (9, 10, 11);
- the run-loop order, `atomicfile` for user data, `thor_lang_notify`, one consumer slot per
  request kind, `thor_apply_edits`, `thor_merge_semantic` (12, 13);
- the `thor_active_console` nil guard, git output parsing (14);
- `thor_note_action` on every route, the deferred plugin and LSP reloads (13, 15, 16);
- `frame_pass == 0`, `push_id` in loops, tokens, `thor_control`, `focus_scope` (15, 16, 17);
- the read-only `settings/` and the settings layers (16, 12);
- the platform pairs, multi-window records, the updater swap (18, 19);
- the pty, watcher, `vt` parser, `luaconf`, `atomicfile` and `lockfree` contracts (19).

When an agent stops at the usage limit, resume it with `SendMessage` once the limit resets — its
work so far is kept. Do not start a new agent for the same share.

### Brief template

Give each agent this, with the bracketed parts filled in:

> Audit [files or packages] of the Thor repo at [repo root]. Read `CLAUDE.md` first — it states
> the architectural contract you are auditing against — then [the sections of
> `lang/LANGUAGE_INTELLIGENCE.md` or `GOOD_UI.md` that apply]. Read every line of these files; do
> not sample: [file list]. [Re-run only] Read `ANALYSIS.md` sections 3–7 for your files and do
> not re-report what is listed there, except as a re-check below.
>
> Report findings in four categories: **bugs**, **style deviations from CLAUDE.md**,
> **performance**, **missing or incomplete features**. List **unnecessary or redundant tests**
> apart from those: a test that repeats another's coverage, asserts nothing or tests a trivial
> thing, with `file:line` and the test it repeats.
>
> [Agents 15, 16, 19 and 20 only] **Keybinds and settings**: compare `settings/keybinds.lua` and
> `settings/settings.lua` against the defaults in Odin (`thor/commands.odin`,
> `editview/keymap.odin`, `setting/setting.odin`), the chords a menu, a tooltip, the welcome page
> and `settings/tips.lua` show, and `docs/`. Report each chord or value that differs between two
> of them, each command or key present on one side only, each chord bound twice in one context,
> and each chord tested directly instead of through the keymap. Cite both sides.
>
> Evidence bar — a finding is only reportable if you read the code yourself and can cite
> `path/file.odin:line`. State the concrete trigger: the input, state or sequence that makes it
> go wrong. No "could be risky", no findings derived from a name or a comment alone. If you
> cannot name the trigger, drop the finding.
>
> Rank bugs High / Medium / Low:
> - **High** — data loss or corruption, a crash, a hang, a broken security or sandbox guarantee,
>   or a documented invariant that does not hold.
> - **Medium** — wrong behaviour on a reachable path, a leak, a race, or an unhandled error that
>   loses information.
> - **Low** — unreachable-today faults, missing guards, inconsistency with a pattern the same
>   file follows elsewhere.
> Say plainly when a fault is not currently reachable and what keeps it unreachable.
>
> Check these Thor-specific rules for your files, and treat a violation as a bug:
> - Dependencies point downward only in the layer list in CLAUDE.md; `editview`, `render` and
>   the leaf packages never import `thor`; the `plugin` package never touches UI; only
>   `platform` imports `vendor:raylib`.
> - Ownership: `// owned` vs borrowed fields; `shutdown` frees exactly the owned ones;
>   `textedit.text` borrows a snapshot that dies at the first read after an edit — anything
>   kept across an edit or handed to a thread needs `text_clone`.
> - Async: a worker pushes its job onto a `lockfree.Stack`; the main thread takes it once per
>   frame. Workers touch no UI state. Per-frame allocations use the temp allocator, and a worker
>   thread that uses the temp allocator frees it itself.
> - Platform split: no shared file imports `core:sys/windows`; `_windows.odin` / `_posix.odin`
>   pairs carry the OS calls behind the contract the shared file comments.
> - Errors are always handled — flag every ignored fallible result (`_ = …`, a discarded `BOOL`
>   or `ok`) outside `_test.odin` fixtures. A write that overwrites user or session data goes
>   through `atomicfile.write`.
> - Untrusted input — repo-supplied `.thor/` files, plugin Lua, terminal output, server replies,
>   files on disk — must not run a program without a trust prompt, hang the UI thread or exhaust
>   memory. Lua's C library calls (string patterns) are not stopped by a count hook.
> - Comments are terse Odin-stdlib style stating *what*, not narrative *why*; no segment
>   comments, none on a trivial procedure; four-space indentation.
> - Windows and POSIX paths are both handled.
>
> [The rules only these files have.]
>
> [Re-run only] Re-check these findings from the previous analysis and say for each whether it
> still reproduces in the current code, quoting the lines, or whether the code was removed:
> [paste the still-open findings for these files].
>
> Return a flat list. Per finding: category, severity, `file:line`, one sentence on the fault,
> one sentence on the trigger. At most 12 bugs, 8 style, 8 performance — rank and cut, do not
> pad. The test and keybind lists have no cap. Close with the files you read in full and the
> ones you skimmed or did not open. Report only; change no files, run no build and no test.

## Phase 3 — Verify before writing

Agent reports are input, not conclusions. Line numbers drift and a plausible-sounding fault often
dissolves on reading.

- Read the cited lines yourself for **every High and Medium finding** and for every performance
  claim that names a hot path. Drop what does not hold; downgrade what is weaker than claimed;
  correct line numbers that moved. Mark what you read **[V]**.
- Confirm each "called from every keystroke"-style claim by grepping the call sites, and say how
  many there are.
- Merge findings two agents raised from opposite sides of a seam into one item; one cause in two
  places (the same hang in two Lua VMs) stays two items that name one fix.
- A re-run item that no longer reproduces gets **[DONE]** — keep the original text so the entry
  still reads as the history of a real fault.
- Any agent that names files it did not read in full: launch a gap agent for them before writing,
  or list them under thin coverage.

Spot-check Low findings only where cheap. Say in the methodology section what you verified and
what you took on an agent's word.

## Phase 4 — Write ANALYSIS.md

First run: write `ANALYSIS.md` at the repo root. Refresh: edit it in place (phase 0). Keep this
structure — a refresh must diff cleanly against the last run:

```
# Thor Repository Analysis
*Generated <date> by parallel subsystem audits (20 agents, 34 packages) plus manual repo recon.*
<two or three sentences: what Thor is, what this document covers, the markers>

## 1. State of the repo      <- the phase 1 table and facts
## 2. Missing / incomplete features   <- split: documented in LANGUAGE_INTELLIGENCE.md / .todo.txt / found by the audit
## 3. Potential bugs, ranked by severity   <- counts (all and open), then ### High / ### Medium / ### Low
## 4. Code style deviations from CLAUDE.md
## 5. Slow / inefficient code    <- lead with the one finding that compounds across layers
## 6. Unnecessary or redundant tests   <- per package, each with the test it repeats
## 7. Keybinds and settings that differ between the shipped files, the code and the docs
## 8. Methodology     <- per run: the partition, what was verified, thin coverage, the commit
```

Every finding carries its `file:line`. Close section 1 by naming the commit the line numbers were
read at. Write the file with UTF-8 and LF; do bulk edits from a Python script written with the
Write tool (a bash heredoc eats backslashes). Do not generate a PDF unless asked.

## Reporting back

The agents' reports are not shown to the user. Summarize in the reply: the count per severity (all
and open), the two or three findings that matter most, anything newly **[DONE]** since the last
run, and any area an agent covered thinly. Point at `ANALYSIS.md` for the rest.
