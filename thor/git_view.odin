// The git modal: a left sidebar of views, the changes view (unstaged/staged
// lists, the selected file's diff, a commit box), and a fetch/pull/push toolbar
// in the header. It holds display state only — `thor/git_ui.odin` pushes the data
// in through the setters and runs every git command off the actions here.
package thor

import "core:fmt"
import "core:strings"

import ui "../vendor/loom/loom"

GIT_VIEW_WIDTH :: f32(1080)
GIT_VIEW_HEIGHT :: f32(680)
GIT_SIDEBAR_W :: f32(180)
GIT_FILES_W :: f32(340)
GIT_COMMIT_BOX_H :: f32(150)
GIT_ROW_H :: f32(26)
GIT_DIFF_ROW_H :: f32(18)

Git_View_Kind :: enum {
    Changes,
    History,
    Branches,
    Settings,
    Hosting,
}

Git_Sync_Op :: enum {
    Fetch,
    Pull,
    Push,
}

Git_Ref_Kind :: enum {
    Branch,
    Remote,
    Tag,
    Stash,
}

Git_Stash_Op :: enum {
    Save,
    Apply,
    Pop,
    Drop,
}

Git_Hosting_Action :: enum {
    Open_Repo,
    Open_File, // the active editor file
    Open_Commit, // the last commit
    Create_Pr,
    Open_Pr, // arg = the PR's URL
    Clone, // arg = URL, arg2 = destination directory
}

Git_Lfs_Op :: enum {
    Pull,
    Track,
}

@(private = "file")
Git_View_File :: struct {
    path:    string, // owned; repo-relative, the key handed back to the actions
    display: string, // owned
    status:  Git_Status,
    is_lfs:  bool,
}

@(private = "file")
Git_View_Commit :: struct {
    hash:    string, // owned; the key handed back to the actions
    short:   string, // owned
    subject: string, // owned
    author:  string, // owned
    date:    string, // owned
    refs:    string, // owned; decorations, "" for none
}

// A branch, remote branch, tag or stash. For a stash `name` is the stash id
// ("stash@{0}") and `subject` its message; for the rest subject is "".
@(private = "file")
Git_View_Ref :: struct {
    kind:    Git_Ref_Kind,
    name:    string, // owned
    subject: string, // owned
    current: bool,
}

// One git config entry shown in the settings view. An unset curated key draws as
// "not set".
@(private = "file")
Git_View_Config :: struct {
    global: bool,
    key:    string, // owned
    value:  string, // owned
    is_set: bool,
}

@(private = "file")
Git_View_Pr :: struct {
    number: int,
    title:  string, // owned
    branch: string, // owned
    url:    string, // owned
}

Git_View :: struct {
    kind:              Git_View_Kind,
    views:             bit_set[Git_View_Kind],
    // Header state. branch is "" while unknown (not a repo, unborn HEAD).
    branch:            string, // owned
    ahead:             int,
    behind:            int,
    has_upstream:      bool,
    // True while a mutation runs: the toolbar, stage buttons and commit are
    // disabled so one command finishes before the next starts.
    busy:              bool,
    // Last command's report, shown in the footer until the next one.
    status_line:       string, // owned
    status_is_error:   bool,
    // Changes view.
    unstaged:          [dynamic]Git_View_File,
    staged:            [dynamic]Git_View_File,
    // Selected file: which list and the index in it; -1 = none.
    sel_staged:        bool,
    sel_index:         int,
    // Selection to restore across a refresh (see thor_git_view_clear_files).
    restore_path:      string, // owned
    restore_staged:    bool,
    // The selected file's diff. Rows owned (thor_git_view_set_diff takes them).
    diff_rows:         [dynamic]Git_Diff_Row,
    diff_title:        string, // owned
    // Commit box.
    subject:           [dynamic]u8, // owned; ui.input edits it in place
    description:       [dynamic]u8, // owned
    amend:             bool,
    // History view.
    commits:           [dynamic]Git_View_Commit,
    commit_sel:        int, // -1 = none
    commits_has_more:  bool, // draws a "Load more" row after the last commit
    // Branches view.
    refs:              [dynamic]Git_View_Ref,
    ref_collapsed:     [Git_Ref_Kind]bool,
    // Settings view (git config).
    config_rows:       [dynamic]Git_View_Config,
    config_edit_index: int, // config_rows index being edited; -1 = none
    config_edit:       [dynamic]u8, // owned
    config_collapsed:  [2]bool, // [0] local, [1] global
    // Git LFS (settings view). version and patterns owned; lfs_files keys owned,
    // the tracked-file set the changes list marks.
    lfs_available:     bool,
    lfs_version:       string, // owned
    lfs_patterns:      [dynamic]string, // owned
    lfs_files:         map[string]bool, // keys owned
    // Hosting view.
    host_label:        string, // owned; "GitHub — owner/repo", "" while unknown
    host_icon:         string, // owned; a brand icon name
    cli_name:          string, // owned; "gh", "glab" or ""
    host_has_remote:   bool,
    prs:               [dynamic]Git_View_Pr,
    clone_url:         [dynamic]u8, // owned
    clone_dir:         [dynamic]u8, // owned
    // Pane key the focus goes back to when the modal closes.
    return_focus:      string,
}

thor_git_view_init :: proc(thor: ^Thor) {
    v := &thor.git
    v.unstaged = make([dynamic]Git_View_File)
    v.staged = make([dynamic]Git_View_File)
    v.diff_rows = make([dynamic]Git_Diff_Row)
    v.subject = make([dynamic]u8)
    v.description = make([dynamic]u8)
    v.commits = make([dynamic]Git_View_Commit)
    v.refs = make([dynamic]Git_View_Ref)
    v.config_rows = make([dynamic]Git_View_Config)
    v.config_edit = make([dynamic]u8)
    v.lfs_patterns = make([dynamic]string)
    v.lfs_files = make(map[string]bool)
    v.prs = make([dynamic]Git_View_Pr)
    v.clone_url = make([dynamic]u8)
    v.clone_dir = make([dynamic]u8)
    v.views = {.Changes, .History, .Branches, .Settings, .Hosting}
    v.sel_index = -1
    v.commit_sel = -1
    v.config_edit_index = -1
}

thor_git_view_destroy :: proc(thor: ^Thor) {
    v := &thor.git
    thor_git_view_clear_files(v)
    delete(v.unstaged)
    delete(v.staged)
    thor_git_view_clear_commits(v)
    delete(v.commits)
    thor_git_view_clear_refs(v)
    delete(v.refs)
    thor_git_view_clear_config(v)
    delete(v.config_rows)
    thor_git_view_clear_prs(v)
    delete(v.prs)
    git_view_free_diff(v)
    delete(v.lfs_version)
    for pattern in v.lfs_patterns {
        delete(pattern)
    }
    delete(v.lfs_patterns)
    for key in v.lfs_files {
        delete(key)
    }
    delete(v.lfs_files)
    delete(v.branch)
    delete(v.status_line)
    delete(v.restore_path)
    delete(v.host_label)
    delete(v.host_icon)
    delete(v.cli_name)
    delete(v.subject)
    delete(v.description)
    delete(v.config_edit)
    delete(v.clone_url)
    delete(v.clone_dir)
}

thor_git_view_open :: proc(thor: ^Thor, kind := Git_View_Kind.Changes) {
    v := &thor.git
    v.kind = kind in v.views ? kind : .Changes
    if !thor.git_open {
        v.return_focus = thor.focus_owner
    }
    thor.git_open = true
}

thor_git_view_is_open :: proc(thor: ^Thor) -> bool {
    return thor.git_open
}

thor_git_view_close :: proc(thor: ^Thor) {
    if !thor.git_open {
        return
    }
    thor.git_open = false
    if thor.git.return_focus != "" {
        thor.focus_request = thor.git.return_focus
    }
}

thor_git_view_set_views :: proc(v: ^Git_View, views: bit_set[Git_View_Kind]) {
    v.views = views
}

thor_git_view_set_header :: proc(v: ^Git_View, branch: string, ahead, behind: int, has_upstream: bool) {
    name := strings.clone(branch)
    delete(v.branch)
    v.branch = name
    v.ahead = ahead
    v.behind = behind
    v.has_upstream = has_upstream
}

thor_git_view_set_busy :: proc(v: ^Git_View, busy: bool) {
    v.busy = busy
}

thor_git_view_set_status_line :: proc(v: ^Git_View, text: string, is_error: bool) {
    line := strings.clone(text)
    delete(v.status_line)
    v.status_line = line
    v.status_is_error = is_error
}

// Drops both file lists, keeping the selected path so the row comes back
// selected after the refresh that follows.
thor_git_view_clear_files :: proc(v: ^Git_View) {
    delete(v.restore_path)
    v.restore_path = ""
    if path, staged, ok := thor_git_view_selected_file(v); ok {
        v.restore_path = strings.clone(path)
        v.restore_staged = staged
    }
    for file in v.unstaged {
        git_view_file_free(file)
    }
    for file in v.staged {
        git_view_file_free(file)
    }
    clear(&v.unstaged)
    clear(&v.staged)
    v.sel_index = -1
}

thor_git_view_add_file :: proc(v: ^Git_View, path, display: string, status: Git_Status, staged: bool) {
    list := staged ? &v.staged : &v.unstaged
    append(
        list,
        Git_View_File {
            path = strings.clone(path),
            display = strings.clone(display),
            status = status,
            is_lfs = path in v.lfs_files,
        },
    )
    if v.restore_path == path && v.restore_staged == staged && v.sel_index < 0 {
        v.sel_staged = staged
        v.sel_index = len(list) - 1
    }
}

// Replaces the LFS state the settings view shows and re-marks the file lists
// against the tracked-file set; the probe and the snapshot land in any order.
thor_git_view_set_lfs :: proc(
    v: ^Git_View,
    available: bool,
    version: string,
    patterns: []string,
    files: []string,
) {
    v.lfs_available = available
    delete(v.lfs_version)
    v.lfs_version = strings.clone(version)
    for pattern in v.lfs_patterns {
        delete(pattern)
    }
    clear(&v.lfs_patterns)
    for pattern in patterns {
        append(&v.lfs_patterns, strings.clone(pattern))
    }
    for key in v.lfs_files {
        delete(key)
    }
    clear(&v.lfs_files)
    for file in files {
        v.lfs_files[strings.clone(file)] = true
    }
    for &file in v.unstaged {
        file.is_lfs = file.path in v.lfs_files
    }
    for &file in v.staged {
        file.is_lfs = file.path in v.lfs_files
    }
}

thor_git_view_selected_file :: proc(v: ^Git_View) -> (path: string, staged: bool, ok: bool) {
    list := v.sel_staged ? &v.staged : &v.unstaged
    if v.sel_index < 0 || v.sel_index >= len(list) {
        return
    }
    return list[v.sel_index].path, v.sel_staged, true
}

thor_git_view_clear_commits :: proc(v: ^Git_View) {
    for commit in v.commits {
        git_view_commit_free(commit)
    }
    clear(&v.commits)
    v.commit_sel = -1
    v.commits_has_more = false
}

thor_git_view_add_commit :: proc(v: ^Git_View, hash, short, subject, author, date, refs: string) {
    append(
        &v.commits,
        Git_View_Commit {
            hash = strings.clone(hash),
            short = strings.clone(short),
            subject = strings.clone(subject),
            author = strings.clone(author),
            date = strings.clone(date),
            refs = strings.clone(refs),
        },
    )
}

thor_git_view_set_commits_has_more :: proc(v: ^Git_View, has_more: bool) {
    v.commits_has_more = has_more
}

thor_git_view_clear_refs :: proc(v: ^Git_View) {
    for ref in v.refs {
        delete(ref.name)
        delete(ref.subject)
    }
    clear(&v.refs)
}

thor_git_view_add_ref :: proc(v: ^Git_View, kind: Git_Ref_Kind, name, subject: string, current: bool) {
    append(
        &v.refs,
        Git_View_Ref {
            kind = kind,
            name = strings.clone(name),
            subject = strings.clone(subject),
            current = current,
        },
    )
}

thor_git_view_clear_config :: proc(v: ^Git_View) {
    for row in v.config_rows {
        delete(row.key)
        delete(row.value)
    }
    clear(&v.config_rows)
    v.config_edit_index = -1
}

thor_git_view_add_config :: proc(v: ^Git_View, global: bool, key, value: string, is_set: bool) {
    append(
        &v.config_rows,
        Git_View_Config {
            global = global,
            key = strings.clone(key),
            value = strings.clone(value),
            is_set = is_set,
        },
    )
}

// `label` is "" while origin is unknown or absent; `icon` a brand icon name;
// `cli` the CLI the PR actions will use, "" when none is installed.
thor_git_view_set_hosting :: proc(v: ^Git_View, label, icon, cli: string, has_remote: bool) {
    delete(v.host_label)
    v.host_label = strings.clone(label)
    delete(v.host_icon)
    v.host_icon = strings.clone(icon)
    delete(v.cli_name)
    v.cli_name = strings.clone(cli)
    v.host_has_remote = has_remote
}

thor_git_view_clear_prs :: proc(v: ^Git_View) {
    for pr in v.prs {
        delete(pr.title)
        delete(pr.branch)
        delete(pr.url)
    }
    clear(&v.prs)
}

thor_git_view_add_pr :: proc(v: ^Git_View, number: int, title, branch, url: string) {
    append(
        &v.prs,
        Git_View_Pr {
            number = number,
            title = strings.clone(title),
            branch = strings.clone(branch),
            url = strings.clone(url),
        },
    )
}

// Fills the clone destination with the folder beside the workspace, so the
// common case needs no typing.
thor_git_view_set_clone_dir_hint :: proc(v: ^Git_View, dir: string) {
    if len(v.clone_dir) > 0 {
        return
    }
    append(&v.clone_dir, dir)
}

// Takes ownership of `rows` and the strings in them.
thor_git_view_set_diff :: proc(v: ^Git_View, title: string, rows: [dynamic]Git_Diff_Row) {
    git_view_free_diff(v)
    v.diff_rows = rows
    v.diff_title = strings.clone(title)
}

thor_git_view_clear_diff :: proc(v: ^Git_View) {
    git_view_free_diff(v)
    v.diff_rows = make([dynamic]Git_Diff_Row)
}

// Empties the commit box; the host calls it after a commit lands.
thor_git_view_clear_commit :: proc(v: ^Git_View) {
    clear(&v.subject)
    clear(&v.description)
    v.amend = false
}

@(private = "file")
git_view_free_diff :: proc(v: ^Git_View) {
    git_diff_rows_destroy(&v.diff_rows)
    delete(v.diff_title)
    v.diff_title = ""
}

@(private = "file")
git_view_file_free :: proc(file: Git_View_File) {
    delete(file.path)
    delete(file.display)
}

@(private = "file")
git_view_commit_free :: proc(commit: Git_View_Commit) {
    delete(commit.hash)
    delete(commit.short)
    delete(commit.subject)
    delete(commit.author)
    delete(commit.date)
    delete(commit.refs)
}

@(private = "file")
git_view_can_commit :: proc(v: ^Git_View) -> bool {
    if v.busy {
        return false
    }
    if len(v.staged) == 0 && !v.amend {
        return false
    }
    return strings.trim_space(string(v.subject[:])) != ""
}

@(private = "file")
git_view_select_file :: proc(thor: ^Thor, staged: bool, index: int) {
    v := &thor.git
    list := staged ? &v.staged : &v.unstaged
    if index < 0 || index >= len(list) {
        return
    }
    if v.sel_staged == staged && v.sel_index == index {
        return
    }
    v.sel_staged = staged
    v.sel_index = index
    thor_on_git_select_file(thor, list[index].path, staged)
}

@(private = "file")
git_status_label :: proc(status: Git_Status) -> string {
    switch status {
    case .Modified:
        return "M"
    case .Added:
        return "A"
    case .Untracked:
        return "U"
    case .Deleted:
        return "D"
    case .Renamed:
        return "R"
    case .Conflict:
        return "!"
    case .Submodule:
        return "S"
    case .None:
    }
    return " "
}

@(private = "file")
git_status_color :: proc(thor: ^Thor, status: Git_Status) -> ui.Color {
    switch status {
    case .Added, .Untracked:
        return thor.theme.success_color
    case .Deleted:
        return thor.theme.danger_color
    case .Conflict:
        return thor.theme.conflict_color
    case .Submodule:
        return thor.theme.submodule_color
    case .Modified, .Renamed:
        return thor.theme.warning_color
    case .None:
    }
    return thor.theme.muted_color
}

// ---- the view ---------------------------------------------------------------------

thor_git_panel_view :: proc(thor: ^Thor) {
    if !thor.git_open {
        return
    }

    backdrop := ui.scope(
        {
            key = "git-backdrop",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                z = 410,
                bg = ui.Color{0, 0, 0, 140},
            },
        },
    )

    git_view_box(thor)

    if backdrop.clicked || ui.take_key(.Escape) {
        thor_git_view_close(thor)
    }
}

@(private = "file")
git_view_box :: proc(thor: ^Thor) {
    ui.scope(
        {
            key = "git-box",
            flags = {.Clickable},
            props = {
                w = ui.Px(GIT_VIEW_WIDTH),
                max_w = ui.viewport().x - 80,
                h = ui.Px(GIT_VIEW_HEIGHT),
                max_h = ui.viewport().y - 80,
                dir = .Column,
                bg = thor.theme.background,
                radius = ui.rad(10),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 8}, blur = 32, color = thor.theme.contrast},
            },
        },
    )

    git_view_header(thor)
    {
        ui.scope({key = "body", props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Row}})
        git_view_sidebar(thor)
        git_view_content(thor)
    }
    git_view_footer(thor)
}

@(private = "file")
git_view_header :: proc(thor: ^Thor) {
    v := &thor.git

    ui.scope(
        {
            key = "header",
            props = {
                w = ui.Grow(1),
                h = ui.FIT,
                dir = .Row,
                align = .Center,
                gap = {10, 0},
                pad = ui.xy(14, 12),
                bg = thor.theme.second_background,
            },
        },
    )

    thor_icon_label(thor, "git-branch", thor.theme.accent_color)
    ui.label(
        v.branch != "" ? v.branch : "no branch",
        {key = "branch", props = {color = thor.theme.foreground, text_wrap = .None}},
    )
    if v.has_upstream && (v.ahead > 0 || v.behind > 0) {
        track := ui.label(
            fmt.tprintf("%d ahead, %d behind", v.ahead, v.behind),
            {
                key = "track",
                flags = {.Hoverable},
                props = {color = thor.theme.muted_color, text_wrap = .None},
            },
        )
        thor_tip(thor, track.id, "Commits ahead and behind the upstream branch")
    }
    ui.leaf({key = "gap", props = {w = ui.Grow(1)}})

    if git_view_button(thor, "fetch", "Fetch", !v.busy) {
        thor_on_git_sync(thor, .Fetch)
    }
    if git_view_button(thor, "pull", "Pull", !v.busy) {
        thor_on_git_sync(thor, .Pull)
    }
    if git_view_button(thor, "push", "Push", !v.busy) {
        thor_on_git_sync(thor, .Push)
    }

    close := ui.scope(
        {
            key = "close",
            flags = {.Clickable},
            props = {
                w = ui.Px(26),
                h = ui.Px(26),
                dir = .Row,
                justify = .Center,
                align = .Center,
                radius = ui.rad(4),
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.buttons},
        },
    )
    thor_icon_label(thor, "x", thor.theme.muted_color)
    thor_tip(thor, close.id, "Close", thor_action_shortcut(thor, "open_git_gui"))
    if close.clicked {
        thor_git_view_close(thor)
    }
}

@(private = "file")
GIT_VIEW_LABELS := [Git_View_Kind]string {
    .Changes  = "Changes",
    .History  = "History",
    .Branches = "Branches",
    .Settings = "Settings",
    .Hosting  = "Hosting",
}

@(private = "file")
GIT_VIEW_ICONS := [Git_View_Kind]string {
    .Changes  = "git-commit",
    .History  = "history",
    .Branches = "git-branch",
    .Settings = "settings",
    .Hosting  = "cloud",
}

@(private = "file")
git_view_sidebar :: proc(thor: ^Thor) {
    v := &thor.git

    ui.scope(
        {
            key = "sidebar",
            flags = {.Clip, .Scroll_Y},
            props = {
                w = ui.Px(GIT_SIDEBAR_W),
                h = ui.Grow(1),
                dir = .Column,
                pad = {l = 8, r = 8, t = 10, b = 8},
                gap = {0, 2},
                bg = thor.theme.second_background,
            },
        },
    )

    for kind in Git_View_Kind {
        if kind not_in v.views {
            continue
        }
        on := v.kind == kind
        it := ui.scope(
            {
                key = GIT_VIEW_LABELS[kind],
                flags = {.Clickable},
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(32),
                    dir = .Row,
                    align = .Center,
                    gap = {8, 0},
                    pad = ui.xy(8, 0),
                    radius = ui.rad(6),
                    bg = on ? thor.theme.selection_background : nil,
                    cursor = .Pointer,
                },
                hover = {bg = on ? thor.theme.selection_background : thor.theme.buttons},
            },
        )
        thor_icon_label(thor, GIT_VIEW_ICONS[kind], on ? thor.theme.foreground : thor.theme.muted_color)
        ui.label(
            GIT_VIEW_LABELS[kind],
            {
                key = "text",
                props = {
                    w = ui.Grow(1),
                    color = on ? thor.theme.foreground : thor.theme.muted_color,
                    text_wrap = .Ellipsis,
                },
            },
        )
        if it.clicked && !on {
            v.kind = kind
            thor_on_git_view_changed(thor, kind)
            return
        }
    }
}

@(private = "file")
git_view_content :: proc(thor: ^Thor) {
    ui.scope({key = "content", props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Row}})

    switch thor.git.kind {
    case .Changes:
        git_view_changes(thor)
    case .History:
        git_view_history(thor)
    case .Branches:
        git_view_branches(thor)
    case .Settings:
        git_view_settings(thor)
    case .Hosting:
        git_view_hosting(thor)
    }
}

@(private = "file")
git_view_footer :: proc(thor: ^Thor) {
    v := &thor.git

    ui.scope(
        {
            key = "footer",
            props = {
                w = ui.Grow(1),
                h = ui.FIT,
                dir = .Row,
                align = .Center,
                pad = ui.xy(14, 8),
                bg = thor.theme.second_background,
            },
        },
    )
    ui.label(
        v.busy ? "Working..." : v.status_line,
        {
            key = "status",
            props = {
                w = ui.Grow(1),
                color = v.status_is_error ? thor.theme.error_color : thor.theme.muted_color,
                text_wrap = .Ellipsis,
            },
        },
    )
}

// ---- changes ----------------------------------------------------------------------

@(private = "file")
git_view_changes :: proc(thor: ^Thor) {
    {
        ui.scope(
            {
                key = "files",
                props = {
                    w = ui.Px(GIT_FILES_W),
                    h = ui.Grow(1),
                    dir = .Column,
                    border = {width = {r = 1}, color = thor.theme.border},
                },
            },
        )
        git_view_file_section(thor, false)
        git_view_file_section(thor, true)
    }

    ui.scope({key = "right", props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column}})
    git_view_diff(thor)
    git_view_commit_box(thor)
}

@(private = "file")
git_view_file_section :: proc(thor: ^Thor, staged: bool) {
    v := &thor.git
    list := staged ? &v.staged : &v.unstaged

    ui.scope(
        {
            key = staged ? "staged" : "unstaged",
            props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column},
        },
    )

    {
        ui.scope(
            {
                key = "head",
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(GIT_ROW_H),
                    dir = .Row,
                    align = .Center,
                    gap = {8, 0},
                    pad = ui.xy(10, 0),
                    bg = thor.theme.second_background,
                },
            },
        )
        ui.label(
            staged ? "STAGED" : "CHANGES",
            {key = "title", props = {w = ui.Grow(1), color = thor.theme.disabled, text_wrap = .None}},
        )
        if len(list) > 0 &&
           git_view_button(thor, "all", staged ? "Unstage All" : "Stage All", !v.busy) {
            thor_on_git_stage(thor, "", !staged)
            return
        }
    }

    ui.scope(
        {
            key = "list",
            flags = {.Clip, .Scroll_Y},
            props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column},
        },
    )
    if len(list) == 0 {
        ui.label(
            staged ? "Nothing staged" : "No changes",
            {key = "empty", props = {pad = ui.xy(10, 6), color = thor.theme.disabled}},
        )
        return
    }

    first, last := ui.virtual(len(list), GIT_ROW_H)
    defer ui.end_virtual()

    for index in first ..< last {
        ui.push_id_int(i64(index))
        action := git_view_file_row(thor, list[index], staged, index)
        ui.pop_id()
        if action != .None {
            git_view_file_action(thor, list[index].path, staged, action)
            return
        }
    }
}

@(private = "file")
Git_File_Action :: enum {
    None,
    Select,
    Stage,
    Discard,
}

@(private = "file")
git_view_file_action :: proc(thor: ^Thor, path: string, staged: bool, action: Git_File_Action) {
    switch action {
    case .Select:
        // The list may have moved under the click, so the path decides.
        list := staged ? &thor.git.staged : &thor.git.unstaged
        for file, i in list {
            if file.path == path {
                git_view_select_file(thor, staged, i)
                return
            }
        }
    case .Stage:
        thor_on_git_stage(thor, path, !staged)
    case .Discard:
        thor_on_git_discard(thor, path)
    case .None:
    }
}

@(private = "file")
git_view_file_row :: proc(
    thor: ^Thor,
    file: Git_View_File,
    staged: bool,
    index: int,
) -> Git_File_Action {
    v := &thor.git
    on := v.sel_staged == staged && v.sel_index == index

    it := ui.scope(
        {
            key = "row",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(GIT_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = ui.xy(10, 0),
                bg = on ? thor.theme.selection_background : nil,
                cursor = .Pointer,
            },
            hover = {bg = on ? thor.theme.selection_background : thor.theme.buttons},
        },
    )
    ui.label(
        git_status_label(file.status),
        {key = "st", props = {w = ui.Px(12), color = git_status_color(thor, file.status), text_wrap = .None}},
    )
    ui.label(
        file.display,
        {key = "name", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis}},
    )
    if file.is_lfs {
        ui.label("LFS", {key = "lfs", props = {color = thor.theme.disabled, text_wrap = .None}})
    }

    // The chip and the LFS pill are no hit targets of their own - a click on
    // one has to reach the row - so what they mean rides on the row's tip.
    detail := git_status_name(file.status)
    if file.is_lfs {
        detail = detail != "" ? fmt.tprintf("%s, tracked by Git LFS", detail) : "Tracked by Git LFS"
    }
    thor_tip(thor, it.id, file.path, detail)

    action := Git_File_Action.None
    if !v.busy {
        if git_view_button(
            thor,
            "stage",
            staged ? "Unstage" : "Stage",
            true,
            staged ? "Take the file out of the next commit" : "Put the file in the next commit",
        ) {
            action = .Stage
        }
        if !staged &&
           git_view_button(thor, "discard", "Discard", true, "Throw the changes to the file away") {
            action = .Discard
        }
    }
    if action == .None && it.clicked {
        action = .Select
    }
    return action
}

@(private = "file")
git_view_diff :: proc(thor: ^Thor) {
    v := &thor.git

    ui.scope(
        {
            key = "diff",
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                border = {width = {b = 1}, color = thor.theme.border},
            },
        },
    )
    title := ui.label(
        v.diff_title != "" ? v.diff_title : "No file selected",
        {
            key = "title",
            flags = {.Hoverable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(GIT_ROW_H),
                pad = ui.xy(12, 0),
                bg = thor.theme.second_background,
                color = thor.theme.muted_color,
                text_wrap = .Ellipsis,
            },
        },
    )
    thor_tip(thor, title.id, v.diff_title)

    ui.scope(
        {
            key = "rows",
            flags = {.Clip, .Scroll_Y, .Scroll_X},
            props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column},
        },
    )
    if len(v.diff_rows) == 0 {
        return
    }

    first, last := ui.virtual(len(v.diff_rows), GIT_DIFF_ROW_H)
    defer ui.end_virtual()

    for index in first ..< last {
        row := v.diff_rows[index]
        ui.push_id_int(i64(index))
        ui.label(
            row.text,
            {
                key = "line",
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(GIT_DIFF_ROW_H),
                    pad = ui.xy(12, 0),
                    bg = git_diff_row_bg(thor, row.kind),
                    color = git_diff_row_color(thor, row.kind),
                    font = thor.font_mono,
                    text_wrap = .None,
                },
            },
        )
        ui.pop_id()
    }
}

@(private = "file")
git_diff_row_bg :: proc(thor: ^Thor, kind: Git_Diff_Row_Kind) -> ui.Paint {
    #partial switch kind {
    case .Added:
        c := thor.theme.success_color
        return ui.Color{c[0], c[1], c[2], 40}
    case .Removed:
        c := thor.theme.danger_color
        return ui.Color{c[0], c[1], c[2], 40}
    }
    return nil
}

@(private = "file")
git_diff_row_color :: proc(thor: ^Thor, kind: Git_Diff_Row_Kind) -> ui.Color {
    #partial switch kind {
    case .Hunk:
        return thor.theme.info_color
    case .Added:
        return thor.theme.success_color
    case .Removed:
        return thor.theme.danger_color
    case .Meta:
        return thor.theme.disabled
    }
    return thor.theme.foreground
}

@(private = "file")
git_view_commit_box :: proc(thor: ^Thor) {
    v := &thor.git

    ui.scope(
        {
            key = "commit",
            props = {
                w = ui.Grow(1),
                h = ui.Px(GIT_COMMIT_BOX_H),
                dir = .Column,
                gap = {0, 6},
                pad = ui.all(10),
            },
        },
    )

    ui.input(
        &v.subject,
        {
            key = "subject",
            props = {
                w = ui.Grow(1),
                bg = thor.theme.second_background,
                color = thor.theme.foreground,
                radius = ui.rad(4),
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
        "Summary",
    )
    ui.input(
        &v.description,
        {
            key = "description",
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                bg = thor.theme.second_background,
                color = thor.theme.foreground,
                radius = ui.rad(4),
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
        "Description",
    )

    ui.scope(
        {
            key = "actions",
            props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {8, 0}},
        },
    )
    if git_view_toggle(
        thor,
        "amend",
        "Amend",
        v.amend,
        "Rewrite the last commit instead of adding a new one",
    ) {
        v.amend = !v.amend
    }
    ui.leaf({key = "gap", props = {w = ui.Grow(1)}})
    if git_view_button(thor, "do-commit", v.amend ? "Amend Commit" : "Commit", git_view_can_commit(v)) {
        thor_on_git_commit(
            thor,
            strings.trim_space(string(v.subject[:])),
            strings.trim_right_space(string(v.description[:])),
            v.amend,
        )
    }
}

// ---- history ----------------------------------------------------------------------

@(private = "file")
git_view_history :: proc(thor: ^Thor) {
    v := &thor.git

    ui.scope(
        {
            key = "history",
            flags = {.Clip, .Scroll_Y},
            props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column},
        },
    )
    if len(v.commits) == 0 {
        ui.label(
            "No commits",
            {key = "empty", props = {pad = ui.xy(14, 10), color = thor.theme.disabled}},
        )
        return
    }

    for commit, index in v.commits {
        ui.push_id_int(i64(index))
        on := v.commit_sel == index
        it := ui.scope(
            {
                key = "row",
                flags = {.Clickable},
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(GIT_ROW_H + 8),
                    dir = .Row,
                    align = .Center,
                    gap = {10, 0},
                    pad = ui.xy(14, 0),
                    bg = on ? thor.theme.selection_background : nil,
                    cursor = .Pointer,
                },
                hover = {bg = on ? thor.theme.selection_background : thor.theme.buttons},
            },
        )
        ui.label(
            commit.short,
            {key = "hash", props = {color = thor.theme.accent_color, font = thor.font_mono, text_wrap = .None}},
        )
        ui.label(
            commit.subject,
            {key = "subject", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis}},
        )
        if commit.refs != "" {
            ui.label(
                commit.refs,
                {key = "refs", props = {color = thor.theme.info_color, text_wrap = .None}},
            )
        }
        ui.label(
            commit.author,
            {key = "author", props = {color = thor.theme.muted_color, text_wrap = .None}},
        )
        ui.label(commit.date, {key = "date", props = {color = thor.theme.disabled, text_wrap = .None}})
        ui.pop_id()

        if it.clicked {
            v.commit_sel = index
            thor_on_git_select_commit(thor, commit.hash)
            return
        }
    }

    if v.commits_has_more {
        if git_view_row_button(thor, "more", "Load more") {
            thor_on_git_load_more(thor)
        }
    }
}

// ---- branches ---------------------------------------------------------------------

@(private = "file")
GIT_REF_LABELS := [Git_Ref_Kind]string {
    .Branch = "BRANCHES",
    .Remote = "REMOTES",
    .Tag    = "TAGS",
    .Stash  = "STASHES",
}

@(private = "file")
git_view_branches :: proc(thor: ^Thor) {
    v := &thor.git

    ui.scope(
        {
            key = "branches",
            flags = {.Clip, .Scroll_Y},
            props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column},
        },
    )

    for kind in Git_Ref_Kind {
        ui.push_id_int(i64(kind))
        open := !v.ref_collapsed[kind]
        if git_view_fold_header(thor, GIT_REF_LABELS[kind], open) {
            v.ref_collapsed[kind] = open
            ui.pop_id()
            return
        }
        if kind == .Stash && git_view_row_button(thor, "save", "Stash Changes") {
            thor_on_git_stash(thor, .Save, "")
            ui.pop_id()
            return
        }
        if open {
            for ref, index in v.refs {
                if ref.kind != kind {
                    continue
                }
                ui.push_id_int(i64(index))
                acted := git_view_ref_row(thor, ref)
                ui.pop_id()
                if acted {
                    ui.pop_id()
                    return
                }
            }
        }
        ui.pop_id()
    }
}

// One ref row. Reports whether it fired an action, which ends the frame's pass
// over the list.
@(private = "file")
git_view_ref_row :: proc(thor: ^Thor, ref: Git_View_Ref) -> bool {
    it := ui.scope(
        {
            key = "ref",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(GIT_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = {l = 26, r = 14},
                bg = ref.current ? thor.theme.selection_background : nil,
                cursor = .Pointer,
            },
            hover = {bg = ref.current ? thor.theme.selection_background : thor.theme.buttons},
        },
    )
    ui.label(
        ref.name,
        {
            key = "name",
            props = {
                w = ui.Grow(1),
                color = ref.current ? thor.theme.accent_color : thor.theme.foreground,
                text_wrap = .Ellipsis,
            },
        },
    )
    if ref.subject != "" {
        ui.label(
            ref.subject,
            {key = "sub", props = {color = thor.theme.muted_color, text_wrap = .Ellipsis}},
        )
    }

    if ref.kind == .Stash {
        if git_view_button(thor, "apply", "Apply", true, "Restore the stash and keep it") {
            thor_on_git_stash(thor, .Apply, ref.name)
            return true
        }
        if git_view_button(thor, "pop", "Pop", true, "Restore the stash and drop it") {
            thor_on_git_stash(thor, .Pop, ref.name)
            return true
        }
        if git_view_button(thor, "drop", "Drop", true, "Throw the stash away") {
            thor_on_git_stash(thor, .Drop, ref.name)
            return true
        }
        return false
    }
    if it.clicked && !ref.current {
        thor_on_git_checkout(thor, ref.kind, ref.name)
        return true
    }
    return false
}

// ---- settings (git config) --------------------------------------------------------

@(private = "file")
git_view_settings :: proc(thor: ^Thor) {
    v := &thor.git

    ui.scope(
        {
            key = "gitconfig",
            flags = {.Clip, .Scroll_Y},
            props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column},
        },
    )

    for global, slot in ([2]bool{false, true}) {
        ui.push_id_int(i64(slot))
        open := !v.config_collapsed[slot]
        if git_view_fold_header(thor, global ? "GLOBAL" : "LOCAL", open) {
            v.config_collapsed[slot] = open
            ui.pop_id()
            return
        }
        if open {
            for row, index in v.config_rows {
                if row.global != global {
                    continue
                }
                ui.push_id_int(i64(index))
                acted := git_view_config_row(thor, index)
                ui.pop_id()
                if acted {
                    ui.pop_id()
                    return
                }
            }
        }
        ui.pop_id()
    }

    git_view_lfs(thor)
}

@(private = "file")
git_view_config_row :: proc(thor: ^Thor, index: int) -> bool {
    v := &thor.git
    row := v.config_rows[index]
    editing := v.config_edit_index == index

    it := ui.scope(
        {
            key = "cfg",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(GIT_ROW_H + 4),
                dir = .Row,
                align = .Center,
                gap = {10, 0},
                pad = {l = 26, r = 14},
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.buttons},
        },
    )
    ui.label(
        row.key,
        {key = "key", props = {w = ui.Px(240), color = thor.theme.foreground, text_wrap = .Ellipsis}},
    )

    if editing {
        field := ui.input(
            &v.config_edit,
            {
                key = "edit",
                props = {
                    w = ui.Grow(1),
                    bg = thor.theme.second_background,
                    color = thor.theme.foreground,
                    radius = ui.rad(4),
                    border = {width = ui.all(1), color = thor.theme.accent_color},
                },
            },
            row.key,
        )
        if ui.focus_within(field.node) && (ui.take_key(.Enter) || ui.take_key(.Pad_Enter)) {
            v.config_edit_index = -1
            thor_on_git_config_set(thor, row.global, row.key, string(v.config_edit[:]))
            return true
        }
        return false
    }

    ui.label(
        row.is_set ? row.value : "not set",
        {
            key = "value",
            props = {
                w = ui.Grow(1),
                color = row.is_set ? thor.theme.muted_color : thor.theme.disabled,
                text_wrap = .Ellipsis,
            },
        },
    )
    if it.clicked {
        v.config_edit_index = index
        clear(&v.config_edit)
        append(&v.config_edit, row.value)
        return true
    }
    return false
}

@(private = "file")
git_view_lfs :: proc(thor: ^Thor) {
    v := &thor.git

    git_view_section_label(thor, "GIT LFS")
    ui.label(
        v.lfs_available ? v.lfs_version : "not installed",
        {
            key = "lfs-status",
            props = {
                pad = {l = 26, r = 14, t = 4, b = 4},
                color = v.lfs_available ? thor.theme.muted_color : thor.theme.disabled,
                text_wrap = .None,
            },
        },
    )
    if !v.lfs_available {
        return
    }

    for pattern, index in v.lfs_patterns {
        ui.push_id_int(i64(index))
        ui.label(
            pattern,
            {
                key = "pattern",
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(GIT_ROW_H),
                    pad = {l = 26, r = 14},
                    color = thor.theme.foreground,
                    font = thor.font_mono,
                    text_wrap = .Ellipsis,
                },
            },
        )
        ui.pop_id()
    }
    if git_view_row_button(thor, "lfs-pull", "Pull LFS Files") {
        thor_on_git_lfs(thor, .Pull)
        return
    }
    if git_view_row_button(thor, "lfs-track", "Track a Pattern") {
        thor_on_git_lfs(thor, .Track)
    }
}

// ---- hosting ----------------------------------------------------------------------

@(private = "file")
git_view_hosting :: proc(thor: ^Thor) {
    v := &thor.git

    ui.scope(
        {
            key = "hosting",
            flags = {.Clip, .Scroll_Y},
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                gap = {0, 6},
                pad = ui.all(14),
            },
        },
    )

    {
        ui.scope(
            {
                key = "card",
                props = {
                    w = ui.Grow(1),
                    h = ui.FIT,
                    dir = .Row,
                    align = .Center,
                    gap = {10, 0},
                    pad = ui.all(10),
                    radius = ui.rad(6),
                    bg = thor.theme.second_background,
                },
            },
        )
        if v.host_icon != "" {
            thor_icon_label(thor, v.host_icon, thor.theme.foreground)
        }
        ui.label(
            v.host_label != "" ? v.host_label : "No remote",
            {key = "label", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis}},
        )
    }

    if v.host_has_remote {
        if git_view_row_button(thor, "open-repo", "Open Repository") {
            thor_on_git_hosting(thor, .Open_Repo, "", "")
            return
        }
        if git_view_row_button(thor, "open-file", "Open This File") {
            thor_on_git_hosting(thor, .Open_File, "", "")
            return
        }
        if git_view_row_button(thor, "open-commit", "Open Last Commit") {
            thor_on_git_hosting(thor, .Open_Commit, "", "")
            return
        }
        if git_view_row_button(thor, "create-pr", "Create Pull Request") {
            thor_on_git_hosting(thor, .Create_Pr, "", "")
            return
        }

        git_view_section_label(thor, "PULL REQUESTS")
        if v.cli_name == "" {
            ui.label(
                "Install the gh or glab CLI to list pull requests.",
                {key = "cli-hint", props = {pad = ui.xy(4, 4), color = thor.theme.disabled}},
            )
        } else if len(v.prs) == 0 {
            ui.label(
                "None open.",
                {key = "no-prs", props = {pad = ui.xy(4, 4), color = thor.theme.disabled}},
            )
        } else {
            for pr, index in v.prs {
                ui.push_id_int(i64(index))
                acted := git_view_pr_row(thor, pr)
                ui.pop_id()
                if acted {
                    return
                }
            }
        }
    }

    git_view_section_label(thor, "CLONE")
    ui.input(
        &v.clone_url,
        {
            key = "clone-url",
            props = {
                w = ui.Grow(1),
                bg = thor.theme.second_background,
                color = thor.theme.foreground,
                radius = ui.rad(4),
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
        "Repository URL",
    )
    ui.input(
        &v.clone_dir,
        {
            key = "clone-dir",
            props = {
                w = ui.Grow(1),
                bg = thor.theme.second_background,
                color = thor.theme.foreground,
                radius = ui.rad(4),
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
        "Destination folder",
    )
    {
        ui.scope({key = "clone-row", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, justify = .End}})
        if git_view_button(thor, "clone", "Clone", len(v.clone_url) > 0 && !v.busy) {
            thor_on_git_hosting(thor, .Clone, string(v.clone_url[:]), string(v.clone_dir[:]))
        }
    }
}

@(private = "file")
git_view_pr_row :: proc(thor: ^Thor, pr: Git_View_Pr) -> bool {
    it := ui.scope(
        {
            key = "pr",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(GIT_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = ui.xy(4, 0),
                radius = ui.rad(4),
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.buttons},
        },
    )
    ui.label(
        fmt.tprintf("#%d", pr.number),
        {key = "num", props = {color = thor.theme.accent_color, text_wrap = .None}},
    )
    ui.label(
        pr.title,
        {key = "title", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis}},
    )
    ui.label(pr.branch, {key = "branch", props = {color = thor.theme.disabled, text_wrap = .None}})
    if it.clicked {
        thor_on_git_hosting(thor, .Open_Pr, pr.url, "")
        return true
    }
    return false
}

// ---- shared controls --------------------------------------------------------------

@(private = "file")
git_view_section_label :: proc(thor: ^Thor, text: string) {
    ui.label(
        text,
        {
            key = text,
            props = {
                w = ui.Grow(1),
                pad = {l = 4, r = 14, t = 12, b = 4},
                color = thor.theme.disabled,
                text_wrap = .None,
            },
        },
    )
}

// A fold header. Reports whether it was clicked, which flips the caller's state.
@(private = "file")
git_view_fold_header :: proc(thor: ^Thor, label: string, open: bool) -> bool {
    it := ui.scope(
        {
            key = "fold",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(GIT_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = ui.xy(10, 0),
                bg = thor.theme.second_background,
                cursor = .Pointer,
            },
        },
    )
    thor_icon_label(thor, open ? "chevron-down" : "chevron-right", thor.theme.muted_color, 14)
    ui.label(
        label,
        {key = "text", props = {w = ui.Grow(1), color = thor.theme.disabled, text_wrap = .None}},
    )
    return it.clicked
}

@(private = "file")
git_view_row_button :: proc(thor: ^Thor, key, label: string) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(GIT_ROW_H + 4),
                dir = .Row,
                align = .Center,
                pad = ui.xy(14, 0),
                radius = ui.rad(4),
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.buttons},
        },
    )
    ui.label(label, {key = "text", props = {color = thor.theme.accent_color, text_wrap = .None}})
    return it.clicked
}

@(private = "file")
git_view_button :: proc(thor: ^Thor, key, label: string, enabled: bool, tip := "") -> bool {
    it := ui.scope(
        {
            key = key,
            flags = enabled ? {.Clickable} : {},
            props = {
                h = ui.Px(24),
                dir = .Row,
                align = .Center,
                pad = ui.xy(10, 0),
                radius = ui.rad(4),
                bg = thor.theme.buttons,
                cursor = enabled ? .Pointer : .Not_Allowed,
            },
            hover = {bg = enabled ? thor.theme.active : nil},
        },
    )
    ui.label(
        label,
        {
            key = "text",
            props = {
                color = enabled ? thor.theme.foreground : thor.theme.disabled,
                text_wrap = .None,
            },
        },
    )
    // A disabled button is no hit target, so it explains itself only while it
    // can be pressed.
    thor_tip(thor, it.id, tip)
    return enabled && it.clicked
}

@(private = "file")
git_view_toggle :: proc(thor: ^Thor, key, label: string, on: bool, tip := "") -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                h = ui.Px(24),
                dir = .Row,
                align = .Center,
                gap = {6, 0},
                pad = ui.xy(8, 0),
                radius = ui.rad(4),
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.buttons},
        },
    )
    thor_icon_label(thor, on ? "square-check" : "square", thor.theme.muted_color, 14)
    ui.label(
        label,
        {key = "text", props = {color = thor.theme.foreground, text_wrap = .None}},
    )
    thor_tip(thor, it.id, tip)
    return it.clicked
}
