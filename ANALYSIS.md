# Thor Repository Analysis

*Generated 2026-08-12 by parallel subsystem audits (7 agents, 12 packages) plus manual repo recon.*

Thor is a code editor written in Odin on raylib, with an in-client language-intelligence engine and
a Lua plugin system. This document is the full-repo audit: repo state, missing features, bugs
ranked by severity, style deviations from CLAUDE.md, performance findings, test redundancy, and
keybind drift. Line numbers were read at commit `5c0837d`.

## 1. State of the repo

Branch `master` at `5c0837d` ("LSP Formatter"). Recent work: the native Odin formatter and its LSP
counterpart, quick-open caching, image decode off the frame thread, watcher and LSP polling
optimizations.

| Package | LOC | Test files |
|---|---|---|
| piecetable | 527 | 1 |
| textedit | 3,581 | 2 |
| ui | 3,447 | 5 |
| widgets | 12,590 | 7 |
| syntax | 1,182 | 1 |
| treecache | 306 | 1 |
| plugin | 5,340 | 11 |
| lang | 2,439 | 2 |
| lang/odin | 18,860 | 22 |
| lang/lsp | 10,512 | 11 |
| setting | 1,123 | 1 |
| watch | 1,191 | 2 |
| shell | 2,321 | 3 |
| msvc | 44 | 0 |
| thor | 16,523 | 15 |
| main | 44 | 0 |
| build.odin | 492 | — |

- No `TODO`/`FIXME`/`XXX`/`HACK` markers in non-vendor `.odin` code (all 16 hits are in
  `vendor/odin-harfbuzz`).
- The `packages` list in `run_tests` (`build.odin:131-147`) matches the 15 packages that hold a
  `_test.odin` — CI skips nothing.
- The four platform workflows' grammar installs match `GRAMMARS` in `build.odin` (25/25).
- `.todo.txt` open items: 18 debugger, 24 improved git plugin, 27 vim-like mode, 29 ultrareview
  before release, 32 Linux file-explorer reveal. Items 5 (lsp) and 16 (lsp alternative) are marked
  `~` though both have since landed.
- `lang/ROADMAP.md` has no unchecked boxes; its remaining gaps are in prose (see section 2).

## 2. Missing / incomplete features

### Documented in ROADMAP / .todo.txt

- Debugger (`.todo.txt` 18), improved git plugin (24), vim-like mode (27), Linux file-manager
  reveal fallback (32).
- Formatter: line-width-aware wrapping of long argument lists and alignment across comment-split
  runs (`lang/ROADMAP.md:1188-1190`).
- Symbol index Phase 3 — dropping the per-request readdir (`lang/ROADMAP.md:1200`, see section 5).
- macOS/BSD watcher is the 1-second poller; FSEvents/kqueue named as intended replacements
  (`watch/watch_posix.odin:8-10`).

### Found by the audit

**UI layer**
- Scroll events never carry modifier state; `widgets/editor.odin:1073` polls raylib directly to
  work around it (`ui/context.odin:227-235`).
- No hover-leave event (`ui/context.odin:297-310`) and no `Key_Release` kind (`ui/event.odin:5-18`).
- Keyboard-layout remap covers only A-Z on Windows and nothing on POSIX — QWERTZ Linux users get
  swapped Z/Y shortcuts (`ui/keymap_windows.odin:36-39`, `keymap_generic.odin:6-8`).
- Key repeat is whitelisted for Z/Y only — holding Ctrl+V pastes once (`ui/context.odin:254-259`).
- A font size outside `preload_sizes` silently loses ligatures and RTL itemization
  (`ui/text.odin:358-387`, `shape.odin:245-251`).

**Infrastructure**
- POSIX timed `shell.run` kills only `/bin/sh`, not the process group — a plugin `exec`'s children
  survive the 2 s budget (`shell/shell_posix.odin:13-14,85-91`).
- A failed `inotify_add_watch` on a subdirectory (watch cap) silently unwatches it with no report
  and no poller fallback (`watch/watch_linux.odin:13-16,179-193`).
- `parse_keybind` has no `cmd`/`super` token, so the Command key cannot be bound on macOS
  (`setting/setting.odin:580-595`).
- VsDevCmd is hardcoded `-arch=amd64` — no Windows-on-ARM detection
  (`shell/profile_windows.odin:84`, `build.odin:420`).
- `thor_focus_window` is a POSIX no-op: a taken folder reads as taken but its window is never
  raised (`thor/windows_posix.odin:35`).

## 3. Potential bugs, ranked by severity

All High and Medium findings below were re-verified by direct reads of the cited lines.

### High

### Medium

**ui / widgets**
5. `ui/context.odin:315-344` — `ctx.active` has no per-button tracking (RIGHT/MIDDLE also queue
   Mouse_Down/Up, `context.odin:142-214`): a second button pressed mid-drag overwrites `active`,
   its release nils it, and the drag widget never gets its Mouse_Up/Click.
6. `widgets/command_palette.odin:530-535` — `on_query_changed` is set by
   `command_palette_pick_rich_loading` but never cleared by `pick`/`pick_rich`, so the stale
   workspace-symbols hook fires from later pickers and replaces their rows.
7. `widgets/console.odin:358` — `console_append` forces `autoscroll = true` on every chunk,
   yanking the view to the bottom while the user reads scrollback during streaming output.
8. `widgets/tree.odin:504-517` — `tree_load_children` sets `loaded = true` then swallows
   `os.open`/`read_dir` errors: an unreadable directory reads permanently empty, no signal, no
   retry on re-expand.

**thor**
9. `thor/git.odin:134,166,184-190,251` — paths are converted `/`→`\\` unconditionally and
   ancestors split on `\\` only, so on the POSIX builds git status/diff keys never match tree or
   buffer paths — explorer tinting and the gutter diff never appear.
10. `thor/thor.odin:578-595` + `thor/git.odin:29-31` — `thor_read_git_branch` reads
    `.git/HEAD` directly; a `git worktree`/submodule checkout (`.git` is a `gitdir:` pointer file)
    reads as "no git" and every git feature disables.
11. `thor/menus.odin:170-172` — context-menu Cut/Copy/Paste always act on pane 0 though the menu
    serves both panes; `thor_open_find` (`commands.odin:305`) and Go to Line (`commands.odin:945`)
    hardwire pane 0 the same way.
12. `thor/files.odin:1375-1389` with `972-991` — confirming an explorer delete neither waits for
    nor cancels an in-flight save of that file; `save_worker` writes unconditionally and can
    recreate the deleted file.

### Low

**textedit / piecetable**
1. `piecetable/piecetable.odin:57-60` — `piecetable_set_text` frees the snapshot before cloning
   `text`, so passing the table's own borrowed view clones freed memory. Unreachable today: every
   caller passes externally owned text.
2. `textedit/ops.odin:816-824` — `indent_lines` pads blank lines with trailing whitespace, unlike
   `toggle_comment` and `trim_trailing_whitespace`, which skip blanks.

**ui**
3. `ui/context.odin` `pack_glyph_atlas` (`ui/text.odin:88-105`) — a glyph taller than
   `size + 8` overlaps the next atlas row; unreachable with shipped fonts.
4. `ui/theme.odin:243` — `parse_hex_color` accepts `_` and a leading `+` (via `parse_uint`), so a
   malformed theme color is silently accepted instead of warned.
5. `ui/fonts.odin:259` — an invalid-UTF-8 icon glyph silently registers U+FFFD (discarded decode
   result).
6. `ui/fonts.odin:379` + `text.odin:302-305` — a failed `arena_init_growing` leaves a zero
   `font_allocator`; the first unknown-icon warn would then crash. OOM-only.
7. `ui/text.odin:69,71,170,187,208,227` — every `rl.MemAlloc` result used unchecked.
8. `ui/widget.odin:95-106` — `widget_insert_after` with a parentless anchor creates an
   unremovable orphan chain; the only caller passes an anchored widget.

**widgets**
9. `widgets/editor.odin:478-495` — `editor_set_state` leaves the signature popup; only a
   revision-compare guards it, so coinciding revision counters draw a stale popup after a tab
   switch.
10. `widgets/select_dialog.odin:135-136` — missing the `ctx.focused != &widget` return-focus
    guard all sibling modals apply.
11. `widgets/editor.odin:1509,1516,1528` — `editor_copy/cut/paste` have no `state == nil` guard;
    kept safe only by thor's menu `has_file` gating.
12. `widgets/settings_view.odin:225-245,787-791` — a capturing keybind row surviving a live
    repopulate commits the chord against whatever row now holds that index.
13. `widgets/menu.odin:144-149` — `menu_layout` clamps against width/height instead of
    x+width/y+height; safe only because the menu's bounds start at (0,0).

**thor**
14. `thor/welcome.odin:58` — `thor_close_workspace` calls `thor_reload_plugins` directly inside an
    event callback, against the `plugin_reload_pending` invariant; not currently a crash because
    no plugin API can trigger Close Workspace.
15. `thor/lang_host.odin:1287-1298` — hover dispatch stores the request id without the
    `id == 0` guard every other site uses.
16. `thor/lang_host.odin:1091` — the doc-file write error is swallowed with a bare `return` (F3
    silently does nothing).
17. `thor/menus.odin:283-296` — New File accepts an empty name; the directory itself then opens
    as a failed tab.
18. `thor/session.odin:244` — the session records pane 0's file as active regardless of focus.
19. `thor/plugin_host.odin:143`, `thor/lang_host.odin:1104` — open-tab lookup compares paths
    byte-for-byte instead of `thor_same_path`; a case-different spelling opens a duplicate tab.

**lang**
20. `lang/lsp/server.odin:32` — `import "../../treecache"` violates the documented "lang/lsp may
    import only core:*, base:runtime, lang and shell" contract (no cycle; the contract is false).
21. `lang/lang.odin:756-767,964-995` — a debounce slot flushed after its backend stops claiming
    the kind returns 0, but the caller already stored the reserved id — the host's request slot
    goes stale silently.
22. `lang/odin/actions.odin:127-137` — multi-file import action edits are not sorted by
    (path, start) as the contract requires; harmless while each file carries one edit.
23. `lang/source.odin:14-23` — CRLF input leaks the original read for persistent allocators; all
    current callers pass temp.
24. `lang/odin/engine.odin:57-61` — a LOCALS query compile failure is swallowed; every request
    then silently answers nothing.

**plugin / shell / watch**
25. `plugin/highlight.odin:169-183` — pure-Lua lexer spans are not sorted/de-overlapped though the
    renderer walks them forward-only; mis-render only (renderer clamps).
26. `plugin/highlight.odin:65` vs `:177` — `Span.role` is borrowed on the grammar path but cloned
    on the lexer path; a uniform caller double-frees or leaks.
27. `plugins/git/plugin.lua:100-111` — porcelain parsing mishandles renames (`R old -> new`) and
    C-quoted paths; staging such a file feeds `git add` a nonexistent path.
28. `shell/shell_posix.odin:112-133` — `spawn` reports success even when the grandchild's `execv`
    fails (no errno pipe, unlike `child_posix.odin:55`).
29. `shell/shell_windows.odin:105-106` — a negative `remaining` converts to a huge DWORD wait — a
    hang in a narrow descheduling window on a timed-out command.
30. `shell/session_windows.odin:96-98` vs `session_posix.odin:93-98` — `session_write` after
    terminate returns true on Windows, false on POSIX.
31. `shell/session.odin:53` — the end-marker exit status `parse_int` ok is discarded; a
    non-numeric status reads as exit 0. No shipped profile emits one.
32. `watch/watch.odin:74` — unchecked `thread.create_and_start_with_poly_data`; a nil return
    would later `thread.join(nil)`.

## 4. Code style deviations from CLAUDE.md

*Resolved 2026-08-13. Every item below was fixed; three of the original claims were wrong and are
corrected here.*

## 5. Slow / inefficient code

**The compounding finding: a keystroke in a large file is O(document) several times over, across
independent layers.** Each layer's cost is individually defensible; together they stack on the
same keypress:

- `finish_edit` calls `text(state)` on every edit (`textedit/textedit.odin:852`), forcing
  `piecetable_view` to rebuild the whole snapshot — a full-document copy per keystroke
  (`piecetable/piecetable.odin:256-267`).
- `piecetable_insert` bumps `pt.length` *before* `piecetable_split_at`
  (`piecetable/piecetable.odin:161` vs `:164`), so an end-of-buffer insert — the commonest
  keystroke — never hits the `pos >= pt.length` fast path (`:75`), scans the whole piece list and
  resets the hint (`:104`). Moving the increment after the split is a one-line fix.
- Buffer-word completion rescans the entire buffer per keystroke with an O(items) dedup per
  candidate (`widgets/editor.odin:1646-1677`).
- Grammar-free languages relex the whole source in Lua per keystroke, after a full
  `clone_to_cstring` copy (`plugin/highlight.odin:147-157`).
- Every cross-file lang request — including each completion keystroke — re-walks the workspace
  with `os.read_dir` under the index mutex (`lang/odin/index.odin:68-103`; ROADMAP Phase 3 is the
  acknowledged fix).

Other verified hot-path findings, roughly by impact:

1. `lang/odin/infer.odin:498-499` — `binding_type_ref` runs `collect_bindings` over the whole
   parse tree per identifier; Semantic_Tokens does up to 512 of these per request
   (`semantic.odin:32`), so one keystroke's semantic pass can cost 512 whole-tree walks.
2. `thor/git.odin:66-79` — the whole `git status` + full-repo `git diff HEAD` parse runs on the
   main thread in one frame; `:54-57` — every watcher burst/save/command spawns the two-subprocess
   pair, near-continuous during builds.
3. `thor/lang_host.odin:131-136` — `thor_reload_lang` busy-waits on the frame thread until every
   in-flight lang request drains; a folder switch mid-scan freezes the UI for the scan's
   remainder.
4. `lang/lsp/jsonrpc.odin:150-173` — 25 ms `POLL_SLICE` semaphore polling adds up to 25 ms to
   every LSP round trip, dominating fast servers on the per-keystroke path (same pattern at
   `server.odin:206-219`).
5. `widgets/image_view.odin:163-178` — the checkerboard is generated over the whole destination
   rect, not the visible intersection: tens of millions of scissored-away `DrawRectangleRec` calls
   per frame at high zoom.
6. `widgets/editor.odin:2524-2528` — `editor_swatch_offset` rescans a row's swatches on every
   call; one visible row can call it ~8 times per frame (selections, diagnostics, hover, fold
   marker, caret).
7. `ui/shape_cache.odin:61,77-91` — at 4096 entries every miss runs a full linear LRU scan;
   fast-scrolling unseen lines pays it per new line per frame.
8. `ui/text.odin:163-167` — ligature probing re-creates a HarfBuzz face and shapes ~140 probes per
   (family, size) though glyph ids are size-independent — 4x repeated work per family at startup.
9. `widgets/tree.odin:282-301` — `tree_truncate_name` does log(n) string builds + measures per
   visible row per frame; `widgets/markdown_view.odin:127-135` — a full-document compare per
   frame on a static buffer.
10. `thor/files.odin:1319-1328` — `thor_same_path` does two `filepath.abs` syscalls per compare
    and sits inside per-file loops; `watcher.odin:74-77` documents and works around this exact
    cost, the other loops do not.
11. `thor/commands.odin:772-779` — quick-open before the cache warms walks up to 4000 files
    synchronously on the UI thread; `thor/theme.odin:59-69` — the theme picker fully parses every
    theme JSON just for display names, every open.
12. `watch/watch.odin:103-105` — `watcher_poll` drains with `remove_range(0, count)` under the
    mutex — quadratic in burst size by construction.
13. `build.odin:151-164` — `run_tests` builds/links all 15 test packages strictly serially; it
    dominates CI wall time and nothing depends on order.
14. `plugins/*-setup/plugin.lua` (e.g. `gopls-setup:27`) — `detect_os()` runs a synchronous
    `thor.exec` at load; with all setup plugins granted, startup blocks on up to ~7 shell spawns.
15. `lang/diff.odin:17,125` — a diff just under `DIFF_LINE_CAP` allocates a ~18 MB DP table per
    Format request.

## 6. Unnecessary or redundant tests

The test suites are lean; no test was found asserting the same behavior as another at the same
layer (`thor/console_test.odin` vs `widgets/console_test.odin` and the two workspace tests cover
different layers of the same names).

The one redundancy-shaped finding: the six LSP setup-plugin suites (`gopls_setup_test.odin`,
`zls_setup_test.odin`, `rust_analyzer_setup_test.odin`, `basedpyright_setup_test.odin`,
`typescript_setup_test.odin`, `lua_language_server_setup_test.odin`, ~70 lines each) are one
template instantiated six times — same two test procs, same flow, differing only in OS/paths and
the install command. They are *currently* justified because each setup plugin carries its own copy
of the tasks.json read/merge/write Lua (`plugins/gopls-setup/plugin.lua:60-100` and siblings); if
that Lua were deduplicated into a shared helper, five of the six `*_install_preserves_existing_tasks`
tests would collapse into one. The duplication to fix is in the plugins, not the tests.
(`clangd_setup_test.odin` is a genuinely distinct, larger suite — 26 procs covering build-system
detection.)

Line numbers in this document were read at commit `5c0837d`.

## 7. Keybinds not matching default and default in code

- **`toggle_split`** — the one real mismatch: `settings/keybinds.json:121` ships `"f1"`, but the
  code fallback when the entry is absent is *unbound* (`thor/commands.odin:150`,
  `setting.Keybind {}`). Every other named fallback in `thor_apply_settings`
  (`thor/commands.odin:22-170`) matches the shipped JSON exactly, including
  `toggle_line_comment` (widget default Ctrl+K at `widgets/editor.odin:428` matches the JSON).
- **Not configurable despite being listed**: the `editing`, `movement`, `selection` and
  `clipboard` sections of `keybinds.json` (undo, redo, delete_line, select_word, matching_bracket,
  copy/paste, …) are consumed by *no* dispatch path except `toggle_line_comment` — their chords
  are hardcoded in `widgets/editor.odin`'s key switch (`:1228-1484`). The shipped JSON values all
  match the hardcoded chords, so nothing misbehaves out of the box, but editing one of those
  entries changes only the command-palette label (`thor/commands.odin:420`), not the binding.
- App-level commands whose JSON entry ships empty (`new_file`, `save_all`, `reveal_in_explorer`,
  the `terminal` section, …) default to unbound by design (`thor/commands.odin:173-181`) — not a
  mismatch.

## 8. Methodology

- **Partition (7 agents, stable across runs):** (1) `piecetable`+`textedit`, (2) `ui`,
  (3) `widgets`, (4) `plugin`+`syntax`+`treecache`+`plugins/` Lua, (5) `lang`+`lang/odin`+
  `lang/odin/format`+`lang/lsp`, (6) `thor`, (7) `setting`+`watch`+`shell`+`msvc`+`build.odin`+
  `.github/workflows/`+`main`. Out of scope: `vendor/`, `bin/`, `assets/`.
- **Verification:** every High and Medium finding in section 3 was re-verified by reading the
  cited lines directly (the fold-panic fallback, the per-button `ctx.active` gap, the
  `decode_workspace_edit` sort absence, the `diff_split_lines` newline loss, the
  `piecetable_insert` fast-path miss and the release.yml notes-file mismatch were each traced
  through their call sites). Hot-path performance claims 1-4 and the compounding keystroke chain
  were verified against source; the rest of section 5 and the Low findings were spot-checked or
  taken from the agent reports, which cited exact lines. Section 7 was compiled by hand from
  `thor/commands.odin`, `widgets/editor.odin` and `settings/keybinds.json`.
- Three agents were interrupted by a session usage limit mid-read and resumed from their
  transcripts; their final reports state full file coverage of their packages.
- Recon facts (section 1) were gathered directly: `git log`, per-package LOC/test counts, the
  marker grep, and the `run_tests`-vs-glob comparison.
- All line numbers match commit `5c0837d` (branch `master`).
