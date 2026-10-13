---
name: analysis
description: Full-repo audit of Thor — parallel per-package agents scoring bugs, style, performance and missing features against CLAUDE.md, verified and written to ANALYSIS.md. Use when asked for a repo analysis, audit, or health check, or to refresh an existing ANALYSIS.md.
---

# Analysis

A full audit of the Thor repository. The product is `ANALYSIS.md` at the repo root — a living
document, not a one-shot report. **Report only: never edit source during an analysis.** If a fix is
obvious, name it in the finding.

Run the phases in order. Phase 2 is the only one that uses agents.

## Phase 0 — Re-run or first run

`ANALYSIS.md` exists → this is a refresh. Read it first. Existing findings carry a `Fixed:` prefix
once the code no longer shows the fault; that prefix is the document's history and is **never
deleted**. Carry every item forward, and give each still-open item to the agent that owns its
package for a re-check (see the brief template).

`ANALYSIS.md` is absent → first run. Skip to phase 1.

## Phase 1 — Recon (do this yourself, not in an agent)

Cheap facts that set the document's frame and that agents would each redo:

- `git log --oneline -15` and the current branch — what the repo is mid-build on.
- LOC and test-file count per package — 25 of them: `piecetable`, `textedit`, `input`, `font`,
  `theme`, `snippet`, `search`, `markdown`, `editview`, `render`, `syntax`, `treecache`, `plugin`,
  `lang` (+ `lang/odin`, `lang/odin/format`, `lang/lsp`), `setting`, `watch`, `shell`, `vt`,
  `msvc`, `update`, `thor`, `main`. A directory the list does not name is a new package: add it
  here and to an agent below.
- Repo-wide grep for `TODO|FIXME|XXX|HACK` in non-vendor `.odin` files.
- `.todo.txt`, if present (gitignored; `done` / open / `~` maybe-later).
- `lang/ROADMAP.md`'s stated gaps: an open `- [ ]` box, a `Missing` sentence inside a ticked
  entry, and the "Known limitations / cleanups" section at the end.
- The `packages` list in `run_tests` (`build.odin`) against the packages that actually hold a
  `_test.odin` — a mismatch means CI silently skips a suite. `snippet` and `main` hold none and
  are rightly absent.
- The plugin count under `plugins/` and the shipped files in `settings/` (`settings.json`,
  `keybinds.json`, `comments.json`, `lsp.json`, `tips.json`) — section 7 compares against them.

## Phase 2 — Parallel package agents

Nine agents, `subagent_type: general-purpose`. **Issue all nine Agent calls in one message** so
they run in parallel, and write nothing until all nine have reported. Keep this partition stable
across runs — it is what makes two analyses comparable.

1. `piecetable` + `textedit`
2. `font` + `render` + `theme` + `input`
3. `editview` + `snippet` + `search` + `markdown`
4. `plugin` + `syntax` + `treecache`
5. `lang` + `lang/odin` + `lang/lsp`
6. `thor`
7. `setting` + `watch` + `shell` + `vt` + `msvc` + `update` + `build.odin` +
   `.github/workflows/` + `main`
8. `lang/odin/format` — the Odin printer. Its worst fault is output that changes or loses code,
   so its brief lists the constructs to trace (attributes, directives, `foreign`, `when`,
   polymorphic parameters, comments in every position, a file with a parse error) and asks for
   an input that is not idempotent.
9. Documentation and shipped configuration, no Odin: `README.md`, `CHANGELOG.md`, `docs/`
   (`generate_html.py` included), `plugins/README.md`, `settings/*.json`, `.thor/*.json`. Each
   claim is checked against the code that implements it, and a finding cites both sides.

Out of scope: `vendor/` (Loom, the UI library, included), `bin/`, `build/`, `assets/`, `sessions/`,
`user/`, `.claude/`. Lua under `plugins/` counts only for agent 4.

Agents 5 and 6 hold about 35,000 and 36,000 lines. Give both a reading order for the non-test
files and ask them to name what they did not read in full; a thin area goes into the methodology
section.

Each agent's brief also carries the rules only its packages have, taken from CLAUDE.md: the Loom
and `render.draw` rules (agents 2 and 6), the snippet sync at each editor intent (3), the sandbox
and the callback allocator (4), the `lang/lsp` import list, lock order and position conversion (5),
the `thor_active_console` nil guard, the deferred plugin and LSP reloads and the read-only
`settings/` (6), the pty, watcher, `vt` parser and updater contracts and the three grammar lists (7).

### Brief template

Give each agent this, with the bracketed parts filled in:

> Audit [packages] of the Thor repo at [repo root]. Read `CLAUDE.md` first — it states the
> architectural contract you are auditing against. Read every `.odin` file in those packages;
> do not sample.
>
> Report findings in four categories: **bugs**, **style deviations from CLAUDE.md**,
> **performance**, **missing or incomplete features**. List **unnecessary or redundant tests**
> apart from those: a test that repeats another's coverage, asserts nothing or tests a trivial
> thing, with `file:line` and the test it repeats.
>
> [Agents 6, 7 and 9 only] **Keybinds and settings**: compare `settings/keybinds.json` and
> `settings/settings.json` against the defaults in Odin, the chords a menu, a tooltip, the welcome
> page and `settings/tips.json` show, and `docs/`. Report each chord or value that differs between
> two of them, each command or key present on one side only, each chord bound twice in one
> context, and each chord tested directly instead of through the keymap. Cite both sides.
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
> Check these Thor-specific rules for your packages, and treat a violation as a bug:
> - Dependencies point downward only in the layer list in CLAUDE.md; `editview`, `render` and
>   the leaf packages never import `thor`; the `plugin` package never touches UI.
> - Ownership: `// owned` vs borrowed fields; `shutdown` frees exactly the owned ones;
>   `textedit.text` borrows a snapshot that dies at the first read after an edit — anything
>   kept across an edit or handed to a thread needs `text_clone`.
> - Async: worker → append job under `io_mutex` → main thread drains once per frame. Workers
>   touch no UI state. Per-frame allocations use the temp allocator.
> - Platform split: no shared file imports `core:sys/windows`; `_windows.odin` / `_posix.odin`
>   pairs carry the OS calls behind the contract the shared file comments.
> - Errors are always handled — flag every ignored fallible result (`_ = …`, a discarded `BOOL`
>   or `ok`) outside `_test.odin` fixtures.
> - Comments are terse Odin-stdlib style stating *what*, not narrative *why*; no segment
>   comments, none on a trivial procedure; four-space indentation.
> - Windows and POSIX paths are both handled.
>
> [The rules only these packages have.]
>
> [Re-run only] Re-check these findings from the previous analysis and say for each whether it
> still reproduces in the current code, quoting the lines: [paste the still-open findings for
> these packages].
>
> Return a flat list. Per finding: category, severity, `file:line`, one sentence on the fault,
> one sentence on the trigger. At most 12 bugs, 8 style, 8 performance — rank and cut, do not
> pad. The test and keybind lists have no cap. Close with the files you read in full and the
> ones you skimmed. Report only; change no files, run no build and no test.

## Phase 3 — Verify before writing

Agent reports are input, not conclusions. Line numbers drift and a plausible-sounding fault often
dissolves on reading.

- Read the cited lines yourself for **every High and Medium finding** and for every performance
  claim that names a hot path. Drop what does not hold; downgrade what is weaker than claimed;
  correct line numbers that moved.
- Confirm each "called from every keystroke"-style claim by grepping the call sites, and say how
  many there are.
- Merge findings two agents raised from opposite sides of a seam into one item.
- A re-run item that no longer reproduces gets the `Fixed:` prefix — keep the original text so
  the entry still reads as the history of a real fault.

Spot-check Low findings only where cheap. Say in the methodology section what you verified and
what you took on an agent's word.

## Phase 4 — Write ANALYSIS.md

Overwrite `ANALYSIS.md` at the repo root. Keep this structure — a refresh must diff cleanly
against the last run:

```
# Thor Repository Analysis
*Generated <date> by parallel subsystem audits (9 agents, 25 packages) plus manual repo recon.*
<two or three sentences: what Thor is, what this document covers>

## 1. State of the repo      <- the phase 1 table and facts
## 2. Missing / incomplete features   <- split: documented in ROADMAP / .todo.txt / found by the audit
## 3. Potential bugs, ranked by severity   <- ### High / ### Medium / ### Low
## 4. Code style deviations from CLAUDE.md
## 5. Slow / inefficient code    <- lead with the one finding that compounds across layers
## 6. Unnecessary or redundant tests   <- per package, each with the test it repeats
## 7. Keybinds and settings that differ between the shipped JSON, the code and the docs
## 8. Methodology     <- the partition, what was verified, and the commit the line numbers match
```

Every finding carries its `file:line`. Close section 1 by naming the commit the line numbers were
read at. Do not generate a PDF unless asked.

## Reporting back

The agents' reports are not shown to the user. Summarize in the reply: the count per severity, the
two or three findings that matter most, anything newly `Fixed:` since the last run, and any package
an agent covered thinly. Point at `ANALYSIS.md` for the rest.
