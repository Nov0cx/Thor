# Loom migration

Thor's hand-rolled UI toolkit is being replaced by [Loom](https://github.com/Nov0cx/Loom), an Odin
retained-tree / immediate-call UI library, vendored at `vendor/loom` and imported everywhere as
`ui "../vendor/loom/loom"`.

Work happens on the `loom` branch. This file is the working plan; delete it when the migration lands.

## Status

| | |
|---|---|
| Loom upstream | done — `viewport`, a public `set_scroll`, `set_tooltips_enabled`, `dock_reset`, then the four below |
| Foundation packages | **green** — `editview` `render` `font` `theme` `snippet` `setting` `input` `plugin` `textedit` `lang` `syntax` `piecetable` `shell` `watch` `update` `treecache` |
| `thor/` | **green** — every view written, `odin check thor` clean, 138 tests pass |
| `ui/`, `widgets/` | **deleted** |

`odin check <pkg> -no-entry-point` per package; `odin check thor -no-entry-point -max-error-count:2000`
for the whole remaining list.

## What Loom gained (already upstream, do not re-derive)

Thor needed five things v0.1 did not have. All are in `d00b486`, documented in Loom's README:

- **Keys.** `Key` is a full keyboard. `Input.key_events` is the ordered stream with repeat, release
  and per-event modifiers; `begin_frame` folds it into `keys_down`/`keys_pressed`. Read it with
  `ui.keys()` (a live slice — set `ev.consumed`) or `ui.take_key(k, mods)`. `ui.focus_within(node)`
  gates a widget. There is no routing: **call order is priority**, so the global keymap runs before
  the tree is built.
- **Text.** `Element.spans: []ui.Text_Span` colours byte ranges, so a syntax-highlighted line is one
  node, not one per token. `Props.tab_size` puts tabs on a grid anchored at the line's left edge and
  `Props.tab_origin` is the pen x a piece of that line starts at. `ui.caret_x` / `ui.offset_at` map
  byte ↔ pixel through the backend's `offset_x` / `index_at`.
- **Painting.** `ui.paint_rect` / `paint_line` / `paint_poly` put a shape in the current node's own
  slot of the draw list, in node-local coordinates, under the text or over it. Carets, selection
  bands, squiggles and chevrons are shapes, not props.
- **Long lists.** `ui.virtual(count, row_h)` + `ui.end_virtual()` builds only visible rows while the
  node still measures the whole list. Rows must be one height.
- **Misc.** `Interaction.hover_entered` / `hover_exited` / `click_count`; a bilinear `Gradient` kind
  for the colour picker's saturation/value square.

Four more the manual pass asked for:

- **Vertical text.** `Props.text_align_v` places a node's own text down the node, as `text_align`
  places it across. `justify` / `align` place *children*, so a leaf's text never saw them — which is
  why every fixed-height chrome button sat high and left.
- **Bars from the flag.** `.Scroll_X` / `.Scroll_Y` alone now draws the scrollbars; `scroll()` is
  only the usual props around that. `.No_Bars` keeps the scrolling and drops them (the dock tab
  strip).
- **Scrolled content is not an intrinsic size.** A scrolling node no longer reports its content as
  its own fit on that axis, so a list beside a fixed header stops squeezing it.
- **`.Wheel`.** The flagged node takes the unscaled delta in `Interaction.wheel` and scrolls nothing,
  and reports even when nothing would move — what the editor pane needs for Ctrl + wheel zoom and
  the wheel over a completion popup. Its offset then moves only through `set_scroll`.

If something else is missing, extend Loom rather than working around it — that is the standing
decision for this migration.

## Layering after the migration

Downward only, as ever. `vendor/loom/loom` is a leaf: it imports nothing but `core:`/`base:`.

- `font` — the HarfBuzz + per-size atlas + LRU shaped-line stack lifted out of the old `ui`. Reads as
  `font.measure`, `font.draw`, `font.line_height`, `font.draw_icon`. Owns raylib fonts.
- `theme` — `Theme`'s 36 named roles, the `COLORS` offset table, `role_color` (**public plugin API,
  do not rename**), WCAG contrast helpers, the generator. Colours are `ui.Color`; `theme.to_rl`
  crosses to raylib for the maths and for drawing that has not moved yet.
- `snippet` — the LSP snippet grammar. No UI, no raylib.
- `editview` — the editor's whole state and behaviour with no UI layer: folding, soft-wrap visual
  rows, completion lifecycle, live snippet sessions, relative-line jumps, key handling. 20 tests.
- `render` — the Loom backend. Answers Loom's five callbacks plus the optional `offset_x`/`index_at`
  from `font`, consumes the draw list through rlgl, and `poll_input` carries Thor's AltGr
  suppression, layout remap and repeat/release synthesis into Loom's event stream.
- `thor` — owns `Thor`, declares the whole tree once a frame in `thor/view.odin`, and hosts
  everything else. Only `thor/thor.odin` (window lifecycle) and `thor/files.odin` (image/model
  loading) still touch raylib directly.

## Decisions already made

Each of these cost time to work out; keep them.

- **`Thor` holds no widget pointers.** The tree is declared per frame from plain state. `editor` and
  `editor2` are `editview.Editor` **values** on `Thor`, not pointers.
- **Focus is a node id, so commands cannot assign it.** `thor.focus_request` names the pane the next
  frame should focus; `thor.focus_owner` is what the view saw last frame, which is what a command
  asking "where am I" reads. Pane keys are `"pane0"`, `"pane1"`, `"explorer"`, `"console"`.
- **Modal state is a bool on `Thor`** (`settings_open`, `git_open`, `theme_editor_open`,
  `color_picker_open`, `permission_open`, `select_open`, `find_open`, `palette_open`, `menu_open`),
  not a widget that answers `*_is_open`.
- **Theme is pushed once.** `thor_push_theme` maps Thor's 36 roles onto Loom's 21 slots and calls
  `ui.set_theme`; styling then cascades. The old 400-line re-push pass is deleted — do not bring back
  per-widget colour setters.
- **Tooltips are declared at the node** (`ui.tooltip(text, for_id)`), so `thor/tooltips.odin` holds
  the text and the chord lookup, not a one-pass setter over stored widgets.
- **`Signal` lives in `thor`** — it never needed the toolkit.
- **`setting.Keybind` is `{ui.Key, ui.Mod_Set}`.** `input` is now only the *spelling* of modifiers;
  Loom owns the set, and Loom's `.Super` is spelled "Cmd" on the way out.
- **`editview` intents are the view's seam**: `editor_press`, `editor_drag`, `editor_release`,
  `editor_hover`, `editor_leave`, `editor_wheel`, `editor_text`, `editor_key`. Each syncs the live
  snippet session first — that sync used to happen on every event and dropping it silently broke
  "the caret left the snippet's span". Do not remove it.
- **`text_width` deliberately bypasses Loom's text cache.** Caching it would allocate one entry per
  measured prefix. Positional queries go to `render`'s backend callbacks, where `font`'s shaped-line
  cache already is.
- **`Cmd_Push_Clip.radius` is ignored** by `render` — a raylib scissor is axis-aligned. A rounded
  panel clips to its bounding box.

## Gotchas found the hard way

- `ui.Color` is `distinct [4]u8`, so `.r/.g/.b/.a` still work on it. `rl.Color` is a struct; the two
  are not assignable.
- Loom is **one frame behind** on all interaction geometry. A fresh node has a zero rect and cannot
  be hovered until frame two. Tests must pump 2–3 frames before asserting.
- Loom's wheel convention is **positive = scroll down**.
- A duplicate node id in one frame **panics** under `ODIN_DEBUG`. A loop body needs `ui.push_id_int(i)`
  or an explicit `key`.
- `ui.dockspace` opens *and closes* its own node; `ui.panel` / `ui.end_panel` are the begin/end pair.
- `ui.scope` is `@(deferred_none = end)` — it closes at the end of the enclosing Odin scope, so one
  per proc reads well and nesting works LIFO.
- Loom emits `Cmd_Text.pos.y` as the **baseline**; `font.draw` takes the top. `render` converts with
  `ASCENT_FRACTION`, and `font_metrics` must return a **negative** descent or every row drifts.
- Package names collide with locals: `text` collided with hundreds of `text: string` params (hence
  `font`), and `theme`/`font` each collided once, fixed by renaming the local.

## Remaining work

Everything below is done; what is left is the manual pass, the docs and the changelog.

### Done

- `thor/view.odin` — theme push, shell column, titlebar (menus, plugin buttons, task controls, the
  update button, window buttons), tab strip, editor pane (rows as `spans` text nodes, gutter,
  selections, carets), status bar, the dockspace with the explorer / editor / terminal / plugin
  panels, `thor_frame_shortcuts` over `ui.keys()`, the editor intents, focus request and owner.
- New views, each state on `Thor` plus a `thor_*_view` that declares it:
  `palette.odin` `select.odin` `explorer.odin` `menu.odin` `console_view.odin` `settings_view.odin`
  `theme_editor.odin` `color_picker.odin` `permission.odin` `find.odin` `git_view.odin`
  `plugin_panel.odin` `welcome.odin` `tips.odin`.
- `search` — the find engine (skip table, case folding, whole-word, regex) lifted out of
  `widgets/find_replace.odin`, with its own tests and a place in `run_tests`.
- `editview.editor_destroy` — the pane owned `visual_rows`, its completion rows, the fold maps and
  the snippet variables and nothing freed them.
- `ui/` and `widgets/` deleted, dropped from `build.odin`.

### Found in the manual pass

- The titlebar buttons wrote their text top-left, the editor pane took no wheel, and no panel drew a
  scrollbar. All three were Loom gaps; see "What Loom gained" above. The editor pane now carries
  `.Scroll_Y` for the bar and `.Wheel` for the delta, and states the document height with one in-flow
  sizer leaf, since its rows are absolute and out of flow.
- **`render.draw` culled the tail of every frame.** It turned backface culling off for the draw list
  and back on at the end, but rlgl only uploads the batch when raylib flushes it in `EndDrawing` —
  under the restored state. Everything still pending after the last flush (a scissor change is what
  forces one) was culled, so `fill_poly` drew nothing from the status bar onward: a dropdown was a
  border with the file tree showing through. `rlgl.DrawRenderBatchActive()` before the restore drains
  it first. Any state `draw` sets now has to be drained the same way.
- `thor/tooltips.odin` is back, as the declaration helpers `thor_tip` / `thor_menu_tip` /
  `thor_task_select_tip` the view calls at each node. The dim chord line is an `Element.spans` run,
  which `merge_element` now carries.

### Carried over since

- **The image, model and markdown views.** Each is a tab's content, in the pane its tab owns:
  `Pane_Content` gained `.Image` and `.Model`, and `thor_workspace_view` decides per pane. The two
  texture views are `Cmd_Image` over `render.register_texture`; the model's 3D pass renders to its
  own target in `Thor.run`, before the draw list is replayed, since `render.draw` holds an unflushed
  rlgl batch and a live scissor across the list. The markdown parse got its own leaf package,
  `markdown/`, laid out against two measuring callbacks the host answers.
- **The hex colour swatches.** Loom's `Text_Span` gained `lead`, blank width reserved before a
  span's first byte, threaded through the measure, the runs, the caret and the hit test.
  `thor_row_spans` merges a row's swatch anchors into its highlight spans, splitting a highlight
  that covers one. `ui.span_lead_before` is what a host adds to its own arithmetic.
- **The terminal's dock slot.** A panel toggled off used to lose its place; Loom now parks it, and
  `ui.dock_focus` raises a tab by name so `focus_terminal` can reach one behind another tab.
- **The editor pane's five overlays**, in `thor/editor_overlay.odin`. The three cards — completion,
  signature help, hover — are `.Floating` + `.Pass_Through` nodes at `position = .Fixed`: floating so
  they escape the pane's clip, pass-through because `editview` owns their hit test through the
  *pane's* interaction, and a clickable card would take the press a candidate needs. The completion
  box is `editor_completion_rects` verbatim, so what is drawn is what is clicked. The whitespace
  markers and the Ctrl+hover underline are `ui.paint_*` in the pane's own slot, positioned with
  `thor_row_x` like every other row painter, so a swatch gap moves them with the glyphs. Two rules
  the deleted `editor_draw` owned came back as `editview.editor_overlay_tick`: an edit drops a card
  whose anchor it moved, and losing the keyboard drops the candidate list and the signature.
- **The dock layout.** `Session.dock_layout` carries what `ui.dock_save` writes — the slots, the
  splitter ratios and the home of every panel toggled off — and `thor_seed_dock` loads it instead of
  seeding when the workspace has one. A restore drops the layout before any early return, so a
  folder with no session of its own comes up on the default rather than on the outgoing folder's,
  which the next save would write over its session. Loom gained `dock_reset` for that: `dock_split`
  splits what is there instead of replacing it.
- **A live snippet session's stops.** `thor_row_stops` clips the session's stops to a visual row and
  says which belong to the tabstop the caret is on — mirrors share a number, so every occurrence of
  it is marked — and `thor_paint_row_snippet_stops` boxes each one in the pane's own slot. A stop
  with no placeholder has no width to box and is a tick; a soft wrap makes two rows meet at one
  offset, and the row above keeps the mark.

## Verification

1. `odin run build.odin -file -- check`
2. `odin check main -target:linux_amd64` and `-target:darwin_arm64` — the stb `.a` panic and the
   Darwin HarfBuzz panic are the known expected noise; anything else is real.
3. `odin run build.odin -file -- test`
4. Run it detached and read `bin/debug/user/thor.log` for `Startup took`:
   `$p = Start-Process bin\debug\thor.exe -PassThru -RedirectStandardOutput out.txt`
5. Manual pass — open a folder; tabs; edit and save; multi-cursor, selection, wrap, folding, swatches,
   squiggles; find/replace incl. regex; palette and code actions; settings (every category, keybind
   capture, workspace scope); the git panel (all five views); a terminal (run, Ctrl+C, tabs); a plugin
   panel with a canvas; theme switch; tooltips; drag a dock splitter, restart, confirm the layout
   persisted.
6. The `verify` skill, then `layering-reviewer` and `ownership-reviewer` on the diff.

## Loom in `vendor/loom`

It is a submodule tracking `master` of `Nov0cx/Loom`. Changes there are committed and pushed in that
repo, then the pointer is staged in Thor. Its own suite is `odin run build.odin -file -- -target:tests`
(run from `vendor/loom`), and `-target:demo -backend:raylib -run` gives a windowed sanity check.
