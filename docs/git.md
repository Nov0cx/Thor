# Git

Thor has a built-in Git UI: a centered modal opened from the **Git** menu in
the top bar, or from the palette — "Git: Open Git UI" (bindable as
`open_git_gui`), "Git: History", "Git: Branches". It needs the workspace to be
inside a git repository. Every git command runs in the background, so the
editor never freezes on a slow fetch; the footer reports what the last command
did, or why it failed, and the status bar branch stays current after a
checkout or pull.

The modal has five views in its sidebar.

## Changes

The working tree, Fork-style: an **Unstaged** and a **Staged** list on the
left, the selected file's diff on the right, and the commit box under it.

- Click a file to see its diff — colored added/removed lines with old/new
  line numbers, hunk headers, binary and truncation markers. An untracked
  file previews as fully added.
- Hovering a row shows its actions: stage (`+`) or unstage (`−`), and for
  unstaged files discard (trash icon, asks for confirmation; discarding an
  untracked file deletes it). Each section header has a Stage All / Unstage
  All action.
- The commit box takes a subject line and an optional multi-line description;
  **Amend** rewrites the last commit instead. The Commit button needs
  something staged (or Amend) and a non-empty subject.
- The header holds fetch, pull (`--ff-only`) and push buttons, the current
  branch, and how far ahead/behind the upstream it is.

Keys: `tab` cycles files → diff → subject → description, `up`/`down` move the
file selection across both lists, `space` stages or unstages the selected
file, `ctrl + enter` commits from anywhere, `esc` leaves a text field and then
closes the modal. The wheel scrolls whichever list it is over.

## History

The commit log (subject, short hash, author, date, branch/tag decorations)
with the selected commit's full diff on the right. "Load more..." at the end
of the list fetches further back.

## Branches

Local branches, remote branches, tags and stashes in fold groups. Clicking a
branch or tag checks it out (a remote branch gets a local tracking branch); a
dirty working tree makes git refuse rather than lose work, and the refusal
shows in the footer. Stash rows offer apply, pop and drop on hover, and the
STASHES header has a "Stash changes" action for the current working tree.

## Settings

Git configuration, split into LOCAL (this repository) and GLOBAL. The common
keys — `user.name`, `user.email`, `pull.rebase`, `fetch.prune`,
`push.autoSetupRemote`, `core.autocrlf`, `commit.gpgsign`,
`init.defaultBranch` — are always listed, "not set" when absent; the rest of
the configuration follows. Click a row to edit its value, `enter` saves,
`esc` cancels.

## Hosting

What `origin` points at, and actions for it:

- The card names the detected service — GitHub, GitLab (self-hosted
  included), or the bare host for anything else.
- **Open repository / current file / last commit in browser** open the
  matching pages of the hosting service.
- **Create pull request** uses the `gh` (GitHub) or `glab` (GitLab) CLI when
  installed — the created request opens in the browser — and falls back to
  the service's compare page otherwise. With a CLI present the open pull
  requests are listed too; clicking one opens it.
- **Clone repository** takes a URL and a destination folder and opens the
  clone as a workspace when it finishes (respecting the `open_folder_in`
  setting).

## Git LFS

The bundled `git` plugin contributes a **Git LFS** top-bar dropdown (status,
pull, track) — it only appears when `git lfs` is installed. See
[Plugins](plugins.md).
