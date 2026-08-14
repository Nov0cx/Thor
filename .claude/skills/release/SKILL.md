---
name: release
description: Cuts a Thor release — version constant, changelog, tag, and the gh CLI watch of the release workflow until the archives are published. User-invoked only, with /release.
disable-model-invocation: true
argument-hint: "[version, e.g. 2026.08.3]"
---

# Cut a release

**This skill runs only when the user types `/release`.** It is marked
`disable-model-invocation: true`, so it is never picked up on its own. Do not
tag, push a tag, publish, edit or delete a release, or rerun the release
workflow unless this skill was invoked in this turn. Outside of it, a question
about releasing is answered in words.

Everything after the tag is `.github/workflows/release.yml`: it builds
`-release` on Windows, Ubuntu, Arch and macOS, packs each `bin/release` with
`assets/`, `plugins/`, `settings/`, `docs/`, `README.md` and `LICENSE`, writes
`SHA256SUMS` and publishes. **A push of a `v*` tag is the whole trigger.** The
publish job needs every build job, so one broken platform makes no release.

The version is `year.month.patch` (`2026.08.3`), the tag is that with a `v`
(`v2026.08.3`).

## 1. Preflight

```bash
gh auth status
git status --short
git rev-parse --abbrev-ref HEAD
git fetch origin --tags
git log --oneline origin/master..HEAD
```

Stop and report if: `gh` is not authenticated, the tree is dirty, the branch is
not `master`, or `origin/master` has commits this checkout does not.

The previous release must be green — a red one usually repeats:

```bash
gh run list --workflow=release.yml --limit 5
git tag --sort=-v:refname | head -5
```

## 2. Settle the version

Three places have to say the same thing, and CI checks the first two against
each other:

- `VERSION :: "<version>"` in `thor/cli.odin`. The `Version` job compares it to
  the tag and fails the whole run when they differ. The updater compares the
  running `VERSION` against the newest release, so a mismatch would make every
  install of it offer itself forever.
- The top heading of `CHANGELOG.md`. Use the `changelog` skill for the entry —
  it owns that file.
- The tag, `v<version>`.

```bash
grep -n 'VERSION ::' thor/cli.odin
head -3 CHANGELOG.md
git tag -l "v<version>"
```

An existing tag of that version means the version is already used: pick the next
patch, do not move the tag.

If the change is user-facing and the docs are behind, run `update-docs` before
the release commit, not after.

## 3. Verify

Run the `verify` skill. At the minimum:

```bash
odin run build.odin -file -- test
```

CI runs the tests on all four platforms before it packs anything, so a failing
test makes no release — it only wastes the run. Never launch the GUI to check a
release build; `rl.InitWindow` hangs in an agent-spawned process.

## 4. Commit and push

```bash
git add thor/cli.odin CHANGELOG.md
git commit -m "release: <version>"
git push origin master
```

## 5. Tag

The tag is what starts the release. Push it only after `master` is pushed, so
the tag names a commit the remote has.

```bash
git tag -a "v<version>" -m "Thor <version>"
git push origin "v<version>"
```

## 6. Watch the run

```bash
gh run list --workflow=release.yml --limit 3
gh run watch <run-id> --exit-status
```

`gh run watch` returns non-zero on a failed run. The four build jobs run in
parallel and take a while — HarfBuzz, the tree-sitter parsers and the tests are
built from scratch on every runner.

On a failure, read the failed step, fix, and rerun. The archives are
deterministic, so a rerun of a flaky job is fine:

```bash
gh run view <run-id> --log-failed
gh run rerun <run-id> --failed
```

## 7. Confirm the release

```bash
gh release view "v<version>"
gh release view "v<version>" --json isDraft,isPrerelease,assets \
  --jq '{draft:.isDraft, pre:.isPrerelease, assets:[.assets[].name]}'
```

Five assets, and the names matter — the updater asks
`/releases/latest` and looks for the exact name for its platform
(`update/target.odin`), so a renamed archive is an update nobody gets:

- `thor-<version>-windows-x86_64.zip`
- `thor-<version>-linux-x86_64.tar.gz`
- `thor-<version>-arch-x86_64.tar.gz`
- `thor-<version>-macos-arm64.tar.gz`
- `SHA256SUMS`

`isDraft` and `isPrerelease` must both be false: `/releases/latest` skips both,
and the updater refuses a draft a second time itself. An install without a
`SHA256SUMS` line for its archive is refused, so that file is not optional.

Report the release URL, the asset list and the run conclusion. Say plainly if a
step was skipped.

## Fixing a bad release

A published tag is what users update to, so prefer a new patch version over
re-cutting one. Re-cut only when the release is minutes old and clearly broken:

```bash
gh release delete "v<version>" --yes
git push origin ":refs/tags/v<version>"
git tag -d "v<version>"
```

Then start again from step 2. Both deletions need the user's word first.

## Dry run

A manual run builds and packs the same archives on all four platforms and stops
before the publish — the way to test a change to `release.yml` without a tag:

```bash
gh workflow run release.yml --ref master
gh run watch <run-id> --exit-status
gh run download <run-id> --dir dist   # the archives, to unpack and start
```
