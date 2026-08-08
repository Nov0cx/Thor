---
name: changelog
description: Records a user-visible change in CHANGELOG.md as short bullet points under the right year.month.patch heading. Use after a change a user of the editor would notice lands, when asked to update the changelog, or when cutting a version.
---

# Update the changelog

`CHANGELOG.md` at the repository root is the user-facing record of what changed
between versions. It is not a commit log and not a design document — internals
belong in `CLAUDE.md`, usage in `docs/`.

This skill owns `CHANGELOG.md` and nothing else. The `update-docs` skill owns
`README.md` and `docs/`. A user-visible change usually needs both: run
`update-docs` for the manual, this one for the changelog. Neither edits the
other's files.

## The format

Newest version first. One `#` heading per version, then short bullet points.
No dates, no `## Added` / `## Fixed` sections, no links:

```markdown
# 2026.08.0

- Terminal tabs keep the shell alive between commands.
- `open_folder_in` setting chooses ask, same window or new window.
- Fixed caret drift after an undo that spans a line ending.
```

Match that shape exactly. Do not import a Keep-a-Changelog template.

## Version numbering

`year.month.patch` — four-digit year, zero-padded two-digit month, patch
counting from `0` inside that month. Today is 2026-08-08, so the current
version is `2026.08.0`.

Decide between appending and starting a heading:

- The top heading is the **current** month and is not released yet (no matching
  `v<version>` git tag) — add bullets under it. This is the normal case.
- The top heading is released (`git tag -l 'v*'` names it) and the month is
  unchanged — start `# 2026.08.1` above it.
- The month rolled over — start `# 2026.09.0` above it, patch back to `0`.

Never edit or reorder bullets under an already released heading.

## Find what changed

Commit subjects here are terse fragments (`visibility attributes`, `swizzles,
#soa and using`), so read the diff, not the subject line.

```bash
git tag -l 'v*'                       # which headings are released
git log --oneline <last-tag>..HEAD    # commits since the last release
git log --oneline -30                 # no tags yet: judge by the top heading
git diff HEAD                         # unreleased work in the tree
git status --short                    # new files the diff misses
```

Cover the working tree too — the change that triggered this skill is often not
committed yet.

## What goes in

The test is: **would a user of the editor notice without reading the source?**

Include:
- new or changed settings, keybindings, commands and menu entries
- new languages, plugins, plugin permissions and plugin API
- behavior changes and bug fixes the user can see
- build or platform changes that affect how the editor is obtained or started

Leave out:
- refactors, renames and file moves with no visible effect
- tests, CI workflow edits, hook and skill changes
- comment and typo fixes, `CLAUDE.md` and `docs/` wording
- performance work with no measurable user effect — a frame-rate win the user
  feels is worth a bullet, an allocation removed is not

When nothing qualifies, add nothing and say so.

## Voice

Short bullet points in Simplified Technical English, matching the house style:

- Present tense, active: "Terminal tabs keep the shell alive", not "Added
  keeping alive of shells".
- One change per bullet, one line where possible.
- No "we", no "you", no marketing adjectives (powerful, seamless, blazing).
- Name the thing the user sees: the setting key, the chord, the menu path.
- Backticks for settings, keys, files and identifiers.

## Checklist

- [ ] heading is the right `year.month.patch`, newest first
- [ ] every bullet is user-visible; internals left out
- [ ] present tense, no "we", no marketing words
- [ ] released headings untouched
- [ ] `update-docs` run too if `README.md` or `docs/` also went stale
