# Tasks

Open work on Thor, found in the `loom` branch manual pass (`LOOM_MIGRATION.md` step 5) on
2026-09-27. A box is ticked only when the fix is in and verified. `.todo.txt` keeps the older
feature list; this file keeps the defects.

## P0 — crashes

- [x] Settings panics on open. `ctrl + ,` gives
      `loom: push_id/pop_id imbalance inside node id ... key "cat", -1 entries left over`
      (`vendor/loom/loom/tree.odin:128`), from `thor/settings_view.odin:663-703`. Language
      Servers, Plugins, Appearance, Keybindings and the workspace scope are all behind it.
- [x] The git panel's History view panics. Same message, key `"row"`, from
      `thor/git_view.odin:1208-1254`.
- [x] The welcome page panics when there is one recent folder or more, from
      `thor/welcome.odin:200-242`, key `"row"`.
- [x] Thor cannot start after File > Close Workspace. The close crashes on the way to the welcome
      page, the session records no folder, and every later launch panics in the first frame.
      `thor.exe <folder>` is the only way back in.

`ui.scope` is `@(deferred_none = end)`, so its node closes at the end of the enclosing Odin block.
All three loops call `ui.pop_id()` before that point, and the deferred `end()` then reads an id
stack one entry short. The fix is a nested block that closes before the pop. Every other push/pop
site in `thor/` and `editview/` is balanced.

## P1 — Loom migration, not carried over

- [x] Every modal sits at the top left with no dim backdrop: command palette, quick open, the
      select dialog, the git panel, settings, the theme editor, the colour picker and the
      permission prompt. Each declares `.Floating` + `position = .Fixed` + `inset = {0,0,0,0}` +
      `w/h = ui.Grow(1)` + `justify/align = .Center` + a translucent `bg`, and the node collapses
      to its child instead of the viewport. A one-sided inset works (`thor/tips.odin:244`,
      `thor/find.odin:207`), so the four-sided stretch is what fails. Fixed in Loom: out of flow,
      a grow or a stretch now fills the containing block. It also gives the backdrops their real
      rect back, so click-outside closes a menu, the git panel, settings, the theme editor and the
      colour picker again.
- [ ] The completion popup does not render. `editview` fills `completion_rows`; no node reads it.
- [ ] The signature-help card does not render.
- [ ] The hover card does not render.
- [ ] The ctrl + hover underline for go-to-definition is gone.
- [ ] Whitespace markers are gone. "View: Toggle Whitespace" still runs and shows nothing.
- [ ] Hex colour swatches are gone. A swatch needs a width-carrying `Text_Span` in Loom first.
- [ ] The markdown preview is gone. `f4` is still bound and does nothing.
- [ ] The image preview is gone. `Workspace_View` still reports `image`.
- [ ] The 3D model preview is gone. `thor_load_model` still runs with no viewer.
- [ ] `ctrl + t` off and on again re-docks Terminal beside Explorer in the left sidebar instead of
      its own slot, draws at a smaller cell size, and leaves the shell dead: a typed line echoes,
      nothing runs, and there is no prompt and no cursor.
- [ ] `focus_terminal` (`ctrl + shift + t`) does not raise the Terminal dock tab, so the chord
      looks dead when Terminal is behind Explorer.

## P2 — defects and polish

- [ ] A directory can open as an editor tab. A restored session opened the `sessions` folder,
      logged `Failed to load` (`thor/files.odin:1264`) and left a blank tab that survives a
      restart. Refuse a directory at open and drop one from a restored session.
- [ ] Help > Tutorial writes `.thor/tutorial/tutorial.md`, which git tracks, so the tutorial always
      makes the repository dirty. Its live copy belongs in `user/`.
- [ ] A titlebar tooltip draws inside the tab strip and an open menu covers it.
- [ ] The palette and quick open do not mark the matched characters, so a weak match reads like a
      strong one.
- [ ] Quick open prints one dim relative path per row: no name-first split, no file icon.
- [ ] Tabs carry no file-type icon. The explorer does.
- [ ] Menu items show no chord. The palette shows one for the same command.
- [ ] The find bar opens at the window's left edge, over the explorer, not over the editor pane it
      searches (`thor/find.odin:209` sets only `inset = {t = FIND_TOP}`).
- [ ] The editor has no indent guides and the explorer has no tree guides.
- [ ] The gutter's relative line numbers have no setting. They feed the `alt + <digit>` jump, but
      there is no way to ask for absolute numbers.
- [ ] Loom's own test suite does not link. `odin run build.odin -file -- -target:tests` from
      `vendor/loom` ends in `LNK2019: unresolved external symbol "user" in
      tests::test_hoverable_is_a_target_without_clicks`. It predates the layout fix — the same
      failure is there at `da84f19` with no local change — so a Loom change can only be verified
      by `odin check` and by the running editor until it is repaired.

## Verified, not a defect

- Relative line numbers are deliberate (`editview/editor.odin:1141`).
- Diagnostics work: a red gutter dot and the compiler message in the status bar.
- Startup is 543 ms warm, of which `InitWindow` is 251 ms.
