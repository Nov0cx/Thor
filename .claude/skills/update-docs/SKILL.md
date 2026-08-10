---
name: update-docs
description: Brings README.md and docs/ back in step with the code after a user-facing change — settings, keybindings, plugin permissions, build steps — and regenerates docs/html/. Use after changing anything a user of the editor (not just its code) would notice.
---

# Update docs

`README.md` is a short quick-start. The user manual is `docs/`: one Markdown
page per topic, `docs/generate_html.py` renders it to `docs/html/` (gitignored
output, not committed). Nothing here documents internals — that is
`CLAUDE.md`'s job.

`CHANGELOG.md` is not this skill's file — the `changelog` skill owns it, and a
user-visible change usually needs both.

## 1. Find what actually changed

Compare each doc claim against its source of truth, not against what the doc
already says:

| Doc | Source of truth |
| --- | --- |
| `docs/keybindings.md` | `settings/keybinds.json` (default chords) and the command palette's action list |
| `docs/configuration.md` | `setting/setting.odin`'s `General` struct (fields + comments), `settings/settings.json`, `settings/lsp.json`, `.thor/tasks.json`, `.thor/odin-analyzer.json`, `.thor/lsp.json` |
| `docs/building.md` | `build.odin`'s flags (`-- run`, `-- deps`, `-- test`, `-- check`, `-- clean`, `-h`) and `vendor/README.md` |
| `docs/plugins.md` | `plugins/README.md` (permission table, sandbox rules) |
| `docs/getting-started.md` | first-run behavior: opening a project, `open_folder_in`, the tutorial |
| `README.md` | all of the above, but only the quick-start slice — not the full detail each `docs/` page carries |

A new `General` field, a new `build.odin` flag, a renamed setting, a changed
default chord, or a new plugin permission each mean the matching page (and
maybe `README.md`) is now wrong or incomplete.

## 2. Edit the Markdown, not generated HTML

Never hand-edit anything under `docs/html/` — it is regenerated wholesale.
Edit the `.md` source.

Keep the tone terse and factual, matching the existing pages: state what is
true, not why it was built. No marketing language.

## 3. Keep the page lists in sync

`docs/index.md`'s page list and `README.md`'s Documentation section both list
every page under `docs/`. Adding, removing or renaming a page needs both
updated, plus any cross-links from other pages that pointed at it.

## 4. Regenerate the HTML

```bash
pip install -r docs/requirements.txt   # once
python docs/generate_html.py
```

Confirm it runs without error — a broken internal link or heading is easy to
introduce and the script does not currently catch either, so also skim the
"wrote docs\html\*.html" output list against the pages you touched.

## 5. Check the release archive list

`.github/workflows/release.yml` has four `Pack` steps (Windows, Ubuntu, Arch,
macOS) that each copy `README.md`, `LICENSE` and `docs/` into the release
archive. A new top-level file meant to ship with the editor (not just live in
the repo) needs adding there too — rare, but worth a glance if the change adds
a new user-facing file outside `docs/`.

## Reporting

Say which doc pages changed and why, and confirm the HTML regenerated cleanly.
If nothing needed updating, say so plainly instead of editing for its own
sake.
