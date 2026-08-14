package widgets

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../ui"

// A centered modal for git, in the settings view's clothes: a left sidebar of
// views, the changes view (unstaged/staged lists, the selected file's diff, a
// commit box), and a fetch/pull/push toolbar in the header. The host (thor)
// pushes data in through the setters and runs every git command itself off the
// callbacks, so the widget holds no git knowledge — only display state.

// Left column holding the two file lists.
@(private)
GIT_FILES_WIDTH :: f32(340)
// One history row: subject over short-hash, author and date.
@(private)
GIT_COMMIT_ROW :: f32(44)
// One row of the branches view.
@(private)
GIT_REF_ROW :: f32(28)
// One file row, and one diff row.
@(private)
GIT_FILE_ROW :: f32(26)
@(private)
GIT_DIFF_ROW :: f32(20)
// A section header ("UNSTAGED (3)  Stage All") over each file list.
@(private)
GIT_SECTION_HEADER :: f32(28)
// The commit box under the diff, and the diff title strip over it.
@(private)
GIT_COMMIT_BOX :: f32(150)
@(private)
GIT_DIFF_TITLE :: f32(26)

Git_View_Kind :: enum {
    Changes,
    History,
    Branches,
    Settings,
    Hosting,
}

// What the keyboard talks to. Tab cycles through the changes-view stations;
// the field stations past Description belong to the settings and hosting
// views and are entered by click.
@(private)
Git_Focus :: enum {
    Files,
    Diff,
    Subject,
    Description,
    Config_Edit,
    Clone_Url,
    Clone_Dir,
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
    Open_File,    // the active editor file
    Open_Commit,  // the last commit
    Create_Pr,
    Open_Pr,      // arg = the PR's URL
    Clone,        // arg = URL, arg2 = destination directory
}

Git_Diff_Row_Kind :: enum u8 {
    Hunk,     // @@ header
    Context,
    Added,
    Removed,
    Meta,     // binary marker, missing-newline marker, truncation marker
}

// One display row of a unified diff. Line numbers are 1-based; 0 means the
// row has no line on that side.
Git_Diff_Row :: struct {
    kind:     Git_Diff_Row_Kind,
    old_line: int,
    new_line: int,
    text:     string,  // owned; tabs expanded
}

@(private)
Git_View_File :: struct {
    path:    string,  // owned; repo-relative, the key handed back to callbacks
    display: string,  // owned
    status:  Git_Status,
}

@(private)
Git_View_Commit :: struct {
    hash:    string,  // owned; the key handed back to callbacks
    short:   string,  // owned
    subject: string,  // owned
    author:  string,  // owned
    date:    string,  // owned
    refs:    string,  // owned; decorations, "" for none
}

// A branch, remote branch, tag or stash. For a stash `name` is the stash id
// ("stash@{0}") and `subject` its message; for the rest subject is "".
@(private)
Git_View_Ref :: struct {
    kind:    Git_Ref_Kind,
    name:    string,  // owned
    subject: string,  // owned
    current: bool,
}

// One display row of the branches view: a fold header for a kind, or a ref.
@(private)
Git_Ref_Row :: struct {
    header: bool,
    kind:   Git_Ref_Kind,
    index:  int,  // into view.refs when !header
}

// One git config entry shown in the settings view. An unset curated key draws
// as "not set".
@(private)
Git_View_Config :: struct {
    global: bool,
    key:    string,  // owned
    value:  string,  // owned
    is_set: bool,
}

// One display row of the settings view: a LOCAL/GLOBAL fold header, or a
// config entry.
@(private)
Git_Config_Row :: struct {
    header: bool,
    global: bool,
    index:  int,  // into view.config_rows when !header
}

@(private)
Git_View_Pr :: struct {
    number: int,
    title:  string,  // owned
    branch: string,  // owned
    url:    string,  // owned
}

Git_View_Changed_Proc :: #type proc(data: rawptr, kind: Git_View_Kind)
// `path` is "" for the whole list ("Stage All" / "Unstage All").
Git_Stage_Proc :: #type proc(data: rawptr, path: string, stage: bool)
Git_Select_File_Proc :: #type proc(data: rawptr, path: string, staged: bool)
Git_Commit_Proc :: #type proc(data: rawptr, subject, description: string, amend: bool)
Git_Sync_Proc :: #type proc(data: rawptr, op: Git_Sync_Op)

Git_Select_Commit_Proc :: #type proc(data: rawptr, hash: string)
Git_Load_More_Proc :: #type proc(data: rawptr)
Git_Checkout_Proc :: #type proc(data: rawptr, kind: Git_Ref_Kind, name: string)
// `name` is "" for .Save.
Git_Stash_Proc :: #type proc(data: rawptr, op: Git_Stash_Op, name: string)
Git_Discard_Proc :: #type proc(data: rawptr, path: string)

Git_Config_Set_Proc :: #type proc(data: rawptr, global: bool, key, value: string)
Git_Hosting_Proc :: #type proc(data: rawptr, action: Git_Hosting_Action, arg, arg2: string)

Git_View_Callbacks :: struct {
    on_view_changed:  Git_View_Changed_Proc,
    on_stage:         Git_Stage_Proc,
    on_select_file:   Git_Select_File_Proc,
    on_commit:        Git_Commit_Proc,
    on_sync:          Git_Sync_Proc,
    on_select_commit: Git_Select_Commit_Proc,
    on_load_more:     Git_Load_More_Proc,
    on_checkout:      Git_Checkout_Proc,
    on_stash:         Git_Stash_Proc,
    on_discard:       Git_Discard_Proc,
    on_config_set:    Git_Config_Set_Proc,
    on_hosting:       Git_Hosting_Proc,
}

// A minimal editable text buffer; caret is a byte offset on a rune boundary.
// Deliberately no selection, wrap or mouse caret placement — the commit box
// needs typing, not an editor.
@(private)
Git_Text_Field :: struct {
    buf:   [dynamic]u8,
    caret: int,
}

Git_View :: struct {
    using widget: ui.Widget,
    kind:    Git_View_Kind,
    views: bit_set[Git_View_Kind],
    focus:   Git_Focus,
    // Header state. branch is "" while unknown (not a repo, unborn HEAD).
    branch:       string,  // owned
    ahead:        int,
    behind:       int,
    has_upstream: bool,
    // True while a mutation runs: the toolbar, stage buttons and commit are
    // disabled so one command finishes before the next starts.
    busy: bool,
    // Last command's report, shown in the footer until the next one.
    status_line:     string,  // owned
    status_is_error: bool,
    // Changes view.
    unstaged: [dynamic]Git_View_File,
    staged:   [dynamic]Git_View_File,
    // Selected file: which list and the index in it; -1 = none.
    sel_staged: bool,
    sel_index:  int,
    // Selection to restore across a refresh (see git_view_clear_files). Owned.
    restore_path:   string,
    restore_staged: bool,
    unstaged_scroll: f32,
    staged_scroll:   f32,
    // The selected file's diff. Rows owned (git_view_set_diff takes them).
    diff_rows:   [dynamic]Git_Diff_Row,
    diff_title:  string,  // owned
    diff_scroll: f32,
    // Commit box.
    subject:     Git_Text_Field,
    description: Git_Text_Field,
    desc_scroll: f32,
    amend:       bool,
    // History view.
    commits:          [dynamic]Git_View_Commit,
    commit_sel:       int,  // -1 = none
    commits_scroll:   f32,
    commits_has_more: bool,  // draws a "Load more" row after the last commit
    // Branches view.
    refs:          [dynamic]Git_View_Ref,
    ref_sel:       int,  // index into the flattened row list; -1 = none
    refs_scroll:   f32,
    ref_collapsed: [Git_Ref_Kind]bool,
    // Settings view (git config).
    config_rows:       [dynamic]Git_View_Config,
    config_sel:        int,  // flattened row index; -1 = none
    config_edit_index: int,  // config_rows index being edited; -1 = none
    config_edit:       Git_Text_Field,
    config_scroll:     f32,
    config_collapsed:  [2]bool,  // [0] local, [1] global
    // Hosting view.
    host_label:      string,  // owned; "GitHub — owner/repo", "" while unknown
    host_icon:       string,  // owned; a brand icon name
    cli_name:        string,  // owned; "gh", "glab" or ""
    host_has_remote: bool,
    prs:             [dynamic]Git_View_Pr,
    clone_url:       Git_Text_Field,
    clone_dir:       Git_Text_Field,
    hosting_scroll:  f32,
    // Geometry, computed in layout.
    box:     rl.Rectangle,
    sidebar: rl.Rectangle,
    content: rl.Rectangle,
    width:   f32,
    height:  f32,
    header_height:   f32,
    category_height: f32,
    footer_height:   f32,
    sidebar_width:   f32,
    cbs:  Git_View_Callbacks,
    data: rawptr,
    return_focus: ^ui.Widget,
    background_color: rl.Color,
    border_color:     rl.Color,
    header_color:     rl.Color,
    field_color:      rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    accent_color:     rl.Color,
    selected_color:   rl.Color,
    added_color:      rl.Color,
    removed_color:    rl.Color,
    warning_color:    rl.Color,
    conflict_color:   rl.Color,
}

git_view_vtable := ui.Widget_VTable {
    layout = git_view_layout,
    handle_event = git_view_handle_event,
    draw = git_view_draw,
    destroy = git_view_destroy,
}

git_view_create :: proc(id: string) -> ^Git_View {
    view := new(Git_View)
    ui.widget_init(&view.widget, id, git_view_vtable)
    view.visible = false
    view.views = {.Changes}
    view.unstaged = make([dynamic]Git_View_File)
    view.staged = make([dynamic]Git_View_File)
    view.diff_rows = make([dynamic]Git_Diff_Row)
    view.subject.buf = make([dynamic]u8)
    view.description.buf = make([dynamic]u8)
    view.commits = make([dynamic]Git_View_Commit)
    view.refs = make([dynamic]Git_View_Ref)
    view.config_rows = make([dynamic]Git_View_Config)
    view.config_edit.buf = make([dynamic]u8)
    view.prs = make([dynamic]Git_View_Pr)
    view.clone_url.buf = make([dynamic]u8)
    view.clone_dir.buf = make([dynamic]u8)
    view.sel_index = -1
    view.commit_sel = -1
    view.ref_sel = -1
    view.config_sel = -1
    view.config_edit_index = -1
    view.width = 1080
    view.height = 680
    view.header_height = 56
    view.category_height = 36
    view.footer_height = 34
    view.sidebar_width = 200
    view.background_color = rl.Color {24, 26, 31, 250}
    view.header_color = rl.Color {31, 34, 51, 255}
    view.field_color = rl.Color {18, 20, 24, 255}
    view.border_color = rl.Color {51, 56, 70, 255}
    view.text_color = rl.Color {238, 255, 255, 255}
    view.muted_color = rl.Color {120, 128, 160, 255}
    view.accent_color = rl.Color {132, 255, 255, 255}
    view.selected_color = rl.Color {132, 255, 255, 40}
    view.added_color = rl.Color {120, 220, 130, 255}
    view.removed_color = rl.Color {235, 110, 110, 255}
    view.warning_color = rl.Color {230, 190, 100, 255}
    view.conflict_color = rl.Color {235, 110, 110, 255}
    return view
}

git_view_set_colors :: proc(
    view: ^Git_View,
    background, border, header, field, text, muted, accent, selected: rl.Color,
    added, removed, warning, conflict: rl.Color,
) -> ^Git_View {
    view.background_color = background
    view.border_color = border
    view.header_color = header
    view.field_color = field
    view.text_color = text
    view.muted_color = muted
    view.accent_color = accent
    view.selected_color = selected
    view.added_color = added
    view.removed_color = removed
    view.warning_color = warning
    view.conflict_color = conflict
    return view
}

git_view_set_callbacks :: proc(view: ^Git_View, cbs: Git_View_Callbacks, data: rawptr) {
    view.cbs = cbs
    view.data = data
}

// Which sidebar views exist; lets the views ship one at a time.
git_view_set_views :: proc(view: ^Git_View, views: bit_set[Git_View_Kind]) {
    view.views = views
}

git_view_open :: proc(view: ^Git_View, ctx: ^ui.Context, kind := Git_View_Kind.Changes) {
    view.kind = kind if kind in view.views else .Changes
    view.focus = .Files
    view.unstaged_scroll = 0
    view.staged_scroll = 0
    view.diff_scroll = 0
    view.desc_scroll = 0
    view.commits_scroll = 0
    view.refs_scroll = 0
    view.amend = false
    git_view_field_clear(&view.subject)
    git_view_field_clear(&view.description)
    git_view_set_status_line(view, "", false)
    view.visible = true
    // A repeat chord while already open must not clobber the real target with
    // the view's own widget.
    if ctx.focused != &view.widget {
        view.return_focus = ctx.focused
    }
    ctx.focused = &view.widget
    ui.widget_bring_to_front(&view.widget)
}

git_view_is_open :: proc(view: ^Git_View) -> bool {
    return view != nil && view.visible
}

// Public, unlike the settings view's: the host force-closes on a workspace
// switch, where the data under the modal is gone.
git_view_close :: proc(view: ^Git_View, ctx: ^ui.Context) {
    view.visible = false
    if ctx != nil && ctx.focused == &view.widget {
        ctx.focused = view.return_focus
    }
}

git_view_set_header :: proc(view: ^Git_View, branch: string, ahead, behind: int, has_upstream: bool) {
    delete(view.branch)
    view.branch = strings.clone(branch)
    view.ahead = ahead
    view.behind = behind
    view.has_upstream = has_upstream
}

git_view_set_busy :: proc(view: ^Git_View, busy: bool) {
    view.busy = busy
}

git_view_set_status_line :: proc(view: ^Git_View, text: string, is_error: bool) {
    delete(view.status_line)
    view.status_line = strings.clone(text)
    view.status_is_error = is_error
}

// Empties both lists for a refresh, remembering the selection so the same
// path selects again as git_view_add_file re-adds it. The host asks
// git_view_selected_file afterward to learn whether it survived.
git_view_clear_files :: proc(view: ^Git_View) {
    delete(view.restore_path)
    view.restore_path = ""
    if path, staged, ok := git_view_selected_file(view); ok {
        view.restore_path = strings.clone(path)
        view.restore_staged = staged
    }
    for file in view.unstaged {
        git_view_file_free(file)
    }
    for file in view.staged {
        git_view_file_free(file)
    }
    clear(&view.unstaged)
    clear(&view.staged)
    view.sel_index = -1
}

git_view_add_file :: proc(view: ^Git_View, path, display: string, status: Git_Status, staged: bool) {
    list := staged ? &view.staged : &view.unstaged
    append(list, Git_View_File {
        path = strings.clone(path),
        display = strings.clone(display),
        status = status,
    })
    if view.restore_path == path && view.restore_staged == staged && view.sel_index < 0 {
        view.sel_staged = staged
        view.sel_index = len(list) - 1
    }
}

git_view_selected_file :: proc(view: ^Git_View) -> (path: string, staged: bool, ok: bool) {
    list := view.sel_staged ? &view.staged : &view.unstaged
    if view.sel_index < 0 || view.sel_index >= len(list) {
        return
    }
    return list[view.sel_index].path, view.sel_staged, true
}

git_view_clear_commits :: proc(view: ^Git_View) {
    for commit in view.commits {
        git_view_commit_free(commit)
    }
    clear(&view.commits)
    view.commit_sel = -1
    view.commits_has_more = false
}

git_view_add_commit :: proc(view: ^Git_View, hash, short, subject, author, date, refs: string) {
    append(&view.commits, Git_View_Commit {
        hash = strings.clone(hash),
        short = strings.clone(short),
        subject = strings.clone(subject),
        author = strings.clone(author),
        date = strings.clone(date),
        refs = strings.clone(refs),
    })
}

git_view_set_commits_has_more :: proc(view: ^Git_View, has_more: bool) {
    view.commits_has_more = has_more
}

git_view_clear_refs :: proc(view: ^Git_View) {
    for ref in view.refs {
        git_view_ref_free(ref)
    }
    clear(&view.refs)
    view.ref_sel = -1
}

git_view_add_ref :: proc(view: ^Git_View, kind: Git_Ref_Kind, name, subject: string, current: bool) {
    append(&view.refs, Git_View_Ref {
        kind = kind,
        name = strings.clone(name),
        subject = strings.clone(subject),
        current = current,
    })
}

git_view_clear_config :: proc(view: ^Git_View) {
    for row in view.config_rows {
        delete(row.key)
        delete(row.value)
    }
    clear(&view.config_rows)
    view.config_sel = -1
    view.config_edit_index = -1
}

git_view_add_config :: proc(view: ^Git_View, global: bool, key, value: string, is_set: bool) {
    append(&view.config_rows, Git_View_Config {
        global = global,
        key = strings.clone(key),
        value = strings.clone(value),
        is_set = is_set,
    })
}

// `label` is "" while origin is unknown or absent; `icon` a brand icon name;
// `cli` the CLI the PR actions will use, "" when none is installed.
git_view_set_hosting :: proc(view: ^Git_View, label, icon, cli: string, has_remote: bool) {
    delete(view.host_label)
    view.host_label = strings.clone(label)
    delete(view.host_icon)
    view.host_icon = strings.clone(icon)
    delete(view.cli_name)
    view.cli_name = strings.clone(cli)
    view.host_has_remote = has_remote
}

git_view_clear_prs :: proc(view: ^Git_View) {
    for pr in view.prs {
        delete(pr.title)
        delete(pr.branch)
        delete(pr.url)
    }
    clear(&view.prs)
}

git_view_add_pr :: proc(view: ^Git_View, number: int, title, branch, url: string) {
    append(&view.prs, Git_View_Pr {
        number = number,
        title = strings.clone(title),
        branch = strings.clone(branch),
        url = strings.clone(url),
    })
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
git_view_ref_free :: proc(ref: Git_View_Ref) {
    delete(ref.name)
    delete(ref.subject)
}

// Takes ownership of `rows` and the strings in them.
git_view_set_diff :: proc(view: ^Git_View, title: string, rows: [dynamic]Git_Diff_Row) {
    git_view_free_diff(view)
    view.diff_rows = rows
    view.diff_title = strings.clone(title)
    view.diff_scroll = 0
}

git_view_clear_diff :: proc(view: ^Git_View) {
    git_view_free_diff(view)
    view.diff_rows = make([dynamic]Git_Diff_Row)
    view.diff_scroll = 0
}

git_view_diff_rows_destroy :: proc(rows: ^[dynamic]Git_Diff_Row) {
    for row in rows {
        delete(row.text)
    }
    delete(rows^)
}

@(private = "file")
git_view_free_diff :: proc(view: ^Git_View) {
    git_view_diff_rows_destroy(&view.diff_rows)
    delete(view.diff_title)
    view.diff_title = ""
}

@(private = "file")
git_view_file_free :: proc(file: Git_View_File) {
    delete(file.path)
    delete(file.display)
}

@(private = "file")
git_view_field_clear :: proc(field: ^Git_Text_Field) {
    clear(&field.buf)
    field.caret = 0
}

// ---- layout ----

git_view_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    view := cast(^Git_View) widget
    // Cover the whole screen so clicks outside the box dismiss the dialog.
    view.bounds = bounds

    width := min(view.width, bounds.width - 80)
    height := min(view.height, max(bounds.height - 80, 240))
    view.box = rl.Rectangle {
        x = bounds.x + (bounds.width - width) * 0.5,
        y = bounds.y + (bounds.height - height) * 0.5,
        width = width,
        height = height,
    }
    view.sidebar = rl.Rectangle {
        view.box.x, view.box.y + view.header_height, view.sidebar_width, view.box.height - view.header_height,
    }
    view.content = rl.Rectangle {
        view.box.x + view.sidebar_width,
        view.box.y + view.header_height,
        view.box.width - view.sidebar_width,
        view.box.height - view.header_height,
    }

    git_view_clamp_scrolls(view)
    git_view_clamp_selection(view)
}

@(private = "file")
git_view_clamp_selection :: proc(view: ^Git_View) {
    list := view.sel_staged ? &view.staged : &view.unstaged
    if view.sel_index >= len(list) {
        view.sel_index = len(list) - 1
    }
}

@(private = "file")
git_view_clamp_scrolls :: proc(view: ^Git_View) {
    _, unstaged_list := git_view_section_rects(view, false)
    _, staged_list := git_view_section_rects(view, true)
    view.unstaged_scroll = clamp(view.unstaged_scroll, 0, git_view_max_scroll(len(view.unstaged), GIT_FILE_ROW, unstaged_list.height))
    view.staged_scroll = clamp(view.staged_scroll, 0, git_view_max_scroll(len(view.staged), GIT_FILE_ROW, staged_list.height))
    diff_list := git_view_diff_list_rect(view)
    view.diff_scroll = clamp(view.diff_scroll, 0, git_view_max_scroll(len(view.diff_rows), GIT_DIFF_ROW, diff_list.height))
    commits := git_view_commits_list_rect(view)
    view.commits_scroll = clamp(view.commits_scroll, 0, git_view_max_scroll(git_view_commit_row_count(view), GIT_COMMIT_ROW, commits.height))
    refs := git_view_refs_list_rect(view)
    view.refs_scroll = clamp(view.refs_scroll, 0, git_view_max_scroll(git_view_ref_row_count(view), GIT_REF_ROW, refs.height))
    view.config_scroll = clamp(view.config_scroll, 0, git_view_max_scroll(git_view_config_row_count(view), GIT_REF_ROW, refs.height))
    view.hosting_scroll = clamp(view.hosting_scroll, 0, max(0, git_view_hosting_content_height(view) - refs.height))
}

@(private)
git_view_max_scroll :: proc(count: int, row: f32, height: f32) -> f32 {
    return max(0, cast(f32) count * row - height)
}

// Content minus the footer: what the current view's body draws into.
@(private)
git_view_body_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    return rl.Rectangle {view.content.x, view.content.y, view.content.width, view.content.height - view.footer_height}
}

@(private)
git_view_footer_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    return rl.Rectangle {
        view.content.x,
        view.content.y + view.content.height - view.footer_height,
        view.content.width,
        view.footer_height,
    }
}

// Header and list of one file section. The two sections split the left column
// evenly, headers included.
@(private)
git_view_section_rects :: proc(view: ^Git_View, staged: bool) -> (header, list: rl.Rectangle) {
    body := git_view_body_rect(view)
    half := body.height * 0.5
    top := staged ? body.y + half : body.y
    header = rl.Rectangle {body.x, top, GIT_FILES_WIDTH, GIT_SECTION_HEADER}
    list = rl.Rectangle {body.x, top + GIT_SECTION_HEADER, GIT_FILES_WIDTH, half - GIT_SECTION_HEADER}
    return
}

// The "Stage All" / "Unstage All" action at a section header's right edge.
@(private)
git_view_section_action_rect :: proc(view: ^Git_View, header: rl.Rectangle, label: string) -> rl.Rectangle {
    tw := cast(f32) ui.measure_text(label, 12)
    w := tw + 16
    return rl.Rectangle {header.x + header.width - SETTINGS_ROW_PAD - w, header.y + (header.height - 20) * 0.5, w, 20}
}

@(private)
git_view_file_row_rect :: proc(view: ^Git_View, staged: bool, index: int) -> rl.Rectangle {
    _, list := git_view_section_rects(view, staged)
    scroll := staged ? view.staged_scroll : view.unstaged_scroll
    return rl.Rectangle {list.x, list.y + cast(f32) index * GIT_FILE_ROW - scroll, list.width, GIT_FILE_ROW}
}

// Index in a section's list under `point`, or -1.
@(private = "file")
git_view_file_row_at :: proc(view: ^Git_View, staged: bool, point: rl.Vector2) -> int {
    _, list := git_view_section_rects(view, staged)
    if !rl.CheckCollisionPointRec(point, list) {
        return -1
    }
    scroll := staged ? view.staged_scroll : view.unstaged_scroll
    index := cast(int) ((point.y - list.y + scroll) / GIT_FILE_ROW)
    count := staged ? len(view.staged) : len(view.unstaged)
    if index < 0 || index >= count {
        return -1
    }
    return index
}

// The stage/unstage icon box at a file row's right edge.
@(private)
git_view_file_action_rect :: proc(row: rl.Rectangle) -> rl.Rectangle {
    size: f32 = 20
    return rl.Rectangle {row.x + row.width - SETTINGS_ROW_PAD - size, row.y + (row.height - size) * 0.5, size, size}
}

// The discard icon box left of the stage box; unstaged rows only.
@(private)
git_view_file_discard_rect :: proc(row: rl.Rectangle) -> rl.Rectangle {
    action := git_view_file_action_rect(row)
    return rl.Rectangle {action.x - 4 - action.width, action.y, action.width, action.height}
}

// The right column: diff over the commit box, right of the file lists.
@(private)
git_view_right_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    body := git_view_body_rect(view)
    return rl.Rectangle {body.x + GIT_FILES_WIDTH, body.y, body.width - GIT_FILES_WIDTH, body.height}
}

// The commit box exists only in the changes view; history gives the diff the
// full column.
@(private)
git_view_diff_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    right := git_view_right_rect(view)
    if view.kind == .Changes {
        right.height -= GIT_COMMIT_BOX
    }
    return right
}

// ---- history geometry ----

@(private)
git_view_commits_list_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    body := git_view_body_rect(view)
    return rl.Rectangle {body.x, body.y, GIT_FILES_WIDTH, body.height}
}

// Rows shown in the commit list: the commits, plus the "Load more" row.
@(private)
git_view_commit_row_count :: proc(view: ^Git_View) -> int {
    count := len(view.commits)
    if view.commits_has_more {
        count += 1
    }
    return count
}

@(private)
git_view_commit_row_rect :: proc(view: ^Git_View, index: int) -> rl.Rectangle {
    list := git_view_commits_list_rect(view)
    return rl.Rectangle {list.x, list.y + cast(f32) index * GIT_COMMIT_ROW - view.commits_scroll, list.width, GIT_COMMIT_ROW}
}

@(private = "file")
git_view_commit_row_at :: proc(view: ^Git_View, point: rl.Vector2) -> int {
    list := git_view_commits_list_rect(view)
    if !rl.CheckCollisionPointRec(point, list) {
        return -1
    }
    index := cast(int) ((point.y - list.y + view.commits_scroll) / GIT_COMMIT_ROW)
    if index < 0 || index >= git_view_commit_row_count(view) {
        return -1
    }
    return index
}

// ---- branches geometry ----

@(private)
git_view_refs_list_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    return git_view_body_rect(view)
}

// Flattens the refs into display rows: a fold header per kind, then its refs
// while unfolded.
@(private)
git_view_ref_rows :: proc(view: ^Git_View, out: ^[dynamic]Git_Ref_Row) {
    for kind in Git_Ref_Kind {
        append(out, Git_Ref_Row {header = true, kind = kind})
        if view.ref_collapsed[kind] {
            continue
        }
        for ref, i in view.refs {
            if ref.kind == kind {
                append(out, Git_Ref_Row {kind = kind, index = i})
            }
        }
    }
}

@(private)
git_view_ref_row_count :: proc(view: ^Git_View) -> int {
    count := len(Git_Ref_Kind)
    for kind in Git_Ref_Kind {
        if view.ref_collapsed[kind] {
            continue
        }
        for ref in view.refs {
            if ref.kind == kind {
                count += 1
            }
        }
    }
    return count
}

@(private)
git_view_ref_row_rect :: proc(view: ^Git_View, index: int) -> rl.Rectangle {
    list := git_view_refs_list_rect(view)
    return rl.Rectangle {list.x, list.y + cast(f32) index * GIT_REF_ROW - view.refs_scroll, list.width, GIT_REF_ROW}
}

@(private = "file")
git_view_ref_row_at :: proc(view: ^Git_View, point: rl.Vector2) -> int {
    list := git_view_refs_list_rect(view)
    if !rl.CheckCollisionPointRec(point, list) {
        return -1
    }
    index := cast(int) ((point.y - list.y + view.refs_scroll) / GIT_REF_ROW)
    if index < 0 || index >= git_view_ref_row_count(view) {
        return -1
    }
    return index
}

// ---- settings (git config) geometry ----

// Flattens the config entries into display rows: a LOCAL and a GLOBAL fold
// header, each followed by its entries while unfolded.
@(private)
git_view_config_rows :: proc(view: ^Git_View, out: ^[dynamic]Git_Config_Row) {
    for global in ([2]bool {false, true}) {
        append(out, Git_Config_Row {header = true, global = global})
        if view.config_collapsed[global ? 1 : 0] {
            continue
        }
        for row, i in view.config_rows {
            if row.global == global {
                append(out, Git_Config_Row {global = global, index = i})
            }
        }
    }
}

@(private)
git_view_config_row_count :: proc(view: ^Git_View) -> int {
    count := 2
    for row in view.config_rows {
        if !view.config_collapsed[row.global ? 1 : 0] {
            count += 1
        }
    }
    return count
}

// The settings rows reuse the branches view's full-body list geometry and
// row height, with config_scroll in place of refs_scroll.
@(private)
git_view_config_row_rect :: proc(view: ^Git_View, index: int) -> rl.Rectangle {
    list := git_view_refs_list_rect(view)
    return rl.Rectangle {list.x, list.y + cast(f32) index * GIT_REF_ROW - view.config_scroll, list.width, GIT_REF_ROW}
}

@(private = "file")
git_view_config_row_at :: proc(view: ^Git_View, point: rl.Vector2) -> int {
    list := git_view_refs_list_rect(view)
    if !rl.CheckCollisionPointRec(point, list) {
        return -1
    }
    index := cast(int) ((point.y - list.y + view.config_scroll) / GIT_REF_ROW)
    if index < 0 || index >= git_view_config_row_count(view) {
        return -1
    }
    return index
}

// ---- hosting geometry ----

@(private)
Git_Hosting_Item_Kind :: enum {
    Card,
    Action_Repo,
    Action_File,
    Action_Commit,
    Action_Pr,
    Pr_Header,
    Pr,        // index into view.prs
    Cli_Hint,
    Clone_Header,
    Clone_Url_Field,
    Clone_Dir_Field,
    Clone_Button,
}

@(private)
Git_Hosting_Item :: struct {
    kind:  Git_Hosting_Item_Kind,
    rect:  rl.Rectangle,
    index: int,
}

// Lays the hosting view out top to bottom; draw and hit-test read the same
// list, so they cannot drift apart.
@(private)
git_view_hosting_items :: proc(view: ^Git_View, out: ^[dynamic]Git_Hosting_Item) {
    body := git_view_refs_list_rect(view)
    x := body.x + SETTINGS_ITEM_INSET + 12
    w := body.width - (SETTINGS_ITEM_INSET + 12) * 2
    y := body.y + 10 - view.hosting_scroll

    push :: proc(out: ^[dynamic]Git_Hosting_Item, kind: Git_Hosting_Item_Kind, x, y, w, h: f32, index := 0) -> f32 {
        append(out, Git_Hosting_Item {kind = kind, rect = rl.Rectangle {x, y, w, h}, index = index})
        return y + h
    }

    y = push(out, .Card, x, y, w, 40)
    y += 10
    if view.host_has_remote {
        y = push(out, .Action_Repo, x, y, w, 30)
        y = push(out, .Action_File, x, y, w, 30)
        y = push(out, .Action_Commit, x, y, w, 30)
        y = push(out, .Action_Pr, x, y, w, 30)
        y += 10
        y = push(out, .Pr_Header, x, y, w, 28)
        if view.cli_name == "" {
            y = push(out, .Cli_Hint, x, y, w, 26)
        } else {
            for i in 0 ..< len(view.prs) {
                y = push(out, .Pr, x, y, w, 26, i)
            }
            if len(view.prs) == 0 {
                y = push(out, .Cli_Hint, x, y, w, 26)
            }
        }
        y += 10
    }
    y = push(out, .Clone_Header, x, y, w, 28)
    y = push(out, .Clone_Url_Field, x, y + 4, w, 30) + 8
    y = push(out, .Clone_Dir_Field, x, y, w, 30) + 8
    push(out, .Clone_Button, x + w - 96, y, 96, 28)
}

@(private)
git_view_hosting_content_height :: proc(view: ^Git_View) -> f32 {
    items := make([dynamic]Git_Hosting_Item, context.temp_allocator)
    git_view_hosting_items(view, &items)
    if len(items) == 0 {
        return 0
    }
    last := items[len(items) - 1].rect
    body := git_view_refs_list_rect(view)
    return last.y + last.height + view.hosting_scroll - body.y + 12
}

// The three hover actions on a stash row: apply, pop, drop.
@(private)
git_view_stash_action_rects :: proc(row: rl.Rectangle) -> (apply, pop, drop: rl.Rectangle) {
    size: f32 = 20
    gap: f32 = 4
    y := row.y + (row.height - size) * 0.5
    drop = rl.Rectangle {row.x + row.width - SETTINGS_ROW_PAD - size, y, size, size}
    pop = rl.Rectangle {drop.x - gap - size, y, size, size}
    apply = rl.Rectangle {pop.x - gap - size, y, size, size}
    return
}

@(private)
git_view_diff_list_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    diff := git_view_diff_rect(view)
    return rl.Rectangle {diff.x, diff.y + GIT_DIFF_TITLE, diff.width, diff.height - GIT_DIFF_TITLE}
}

@(private)
git_view_commit_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    right := git_view_right_rect(view)
    return rl.Rectangle {right.x, right.y + right.height - GIT_COMMIT_BOX, right.width, GIT_COMMIT_BOX}
}

@(private)
git_view_subject_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    box := git_view_commit_rect(view)
    return rl.Rectangle {box.x + 12, box.y + 10, box.width - 24, 30}
}

@(private)
git_view_description_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    subject := git_view_subject_rect(view)
    return rl.Rectangle {subject.x, subject.y + subject.height + 8, subject.width, 56}
}

@(private)
git_view_amend_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    desc := git_view_description_rect(view)
    label_w := cast(f32) ui.measure_text("Amend", 14)
    return rl.Rectangle {desc.x, desc.y + desc.height + 9, 16 + 6 + label_w, 18}
}

@(private)
git_view_commit_button_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    box := git_view_commit_rect(view)
    w: f32 = 96
    h: f32 = 28
    return rl.Rectangle {box.x + box.width - 12 - w, box.y + box.height - 8 - h, w, h}
}

@(private)
git_view_close_rect :: proc(view: ^Git_View) -> rl.Rectangle {
    size: f32 = 28
    return rl.Rectangle {
        view.box.x + view.box.width - 14 - size,
        view.box.y + (view.header_height - size) * 0.5,
        size, size,
    }
}

// The fetch/pull/push boxes, left of the close box.
@(private)
git_view_sync_rects :: proc(view: ^Git_View) -> (fetch, pull, push: rl.Rectangle) {
    size: f32 = 28
    gap: f32 = 6
    y := view.box.y + (view.header_height - size) * 0.5
    push = rl.Rectangle {git_view_close_rect(view).x - 16 - size, y, size, size}
    pull = rl.Rectangle {push.x - gap - size, y, size, size}
    fetch = rl.Rectangle {pull.x - gap - size, y, size, size}
    return
}

@(private)
git_view_category_rect :: proc(view: ^Git_View, index: int) -> rl.Rectangle {
    return rl.Rectangle {
        view.sidebar.x + SETTINGS_ITEM_INSET,
        view.sidebar.y + SETTINGS_SIDEBAR_PAD_TOP + cast(f32) index * view.category_height,
        view.sidebar.width - SETTINGS_ITEM_INSET * 2,
        view.category_height,
    }
}

// The enabled views, in sidebar order.
@(private)
git_view_categories :: proc(view: ^Git_View, out: ^[dynamic]Git_View_Kind) {
    for kind in Git_View_Kind {
        if kind in view.views {
            append(out, kind)
        }
    }
}

// ---- events ----

git_view_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    view := cast(^Git_View) widget
    if !view.visible {
        return false
    }

    #partial switch event.kind {
    case .Key_Press:
        git_view_key(view, ctx, event)
        return true
    case .Text_Input:
        git_view_text_input(view, event)
        return true
    case .Scroll:
        git_view_scroll(view, event)
        return true
    case .Mouse_Down:
        git_view_mouse_down(view, ctx, event.mouse_position)
        return true
    }

    return true // block everything underneath while open
}

@(private = "file")
git_view_key :: proc(view: ^Git_View, ctx: ^ui.Context, event: ^ui.Event) {
    // Ctrl+Enter commits from anywhere in the changes view.
    if view.kind == .Changes && (.Ctrl in event.mods) && (event.key == .ENTER || event.key == .KP_ENTER) {
        git_view_submit_commit(view)
        return
    }

    #partial switch event.key {
    case .ESCAPE:
        if field, _ := git_view_focused_field(view); field != nil {
            view.config_edit_index = -1
            view.focus = .Files
        } else {
            git_view_close(view, ctx)
        }
        return
    case .TAB:
        // Tab cycles the changes view's stations only.
        if view.kind == .Changes {
            #partial switch view.focus {
            case .Files:       view.focus = .Diff
            case .Diff:        view.focus = .Subject
            case .Subject:     view.focus = .Description
            case .Description: view.focus = .Files
            case:              view.focus = .Files
            }
        }
        return
    }

    if field, _ := git_view_focused_field(view); field != nil {
        git_view_field_key(view, event)
        return
    }

    if view.focus == .Diff {
        git_view_diff_key(view, event)
        return
    }
    switch view.kind {
    case .Changes:
        git_view_files_key(view, event)
    case .History:
        git_view_history_key(view, event)
    case .Branches:
        git_view_branches_key(view, event)
    case .Settings:
        git_view_settings_key(view, event)
    case .Hosting:
    }
}

// The editable field the focus names, or nil.
@(private = "file")
git_view_focused_field :: proc(view: ^Git_View) -> (field: ^Git_Text_Field, multiline: bool) {
    #partial switch view.focus {
    case .Subject:     return &view.subject, false
    case .Description: return &view.description, true
    case .Config_Edit: return &view.config_edit, false
    case .Clone_Url:   return &view.clone_url, false
    case .Clone_Dir:   return &view.clone_dir, false
    }
    return nil, false
}

@(private = "file")
git_view_settings_key :: proc(view: ^Git_View, event: ^ui.Event) {
    count := git_view_config_row_count(view)
    #partial switch event.key {
    case .UP:
        view.config_sel = count == 0 ? -1 : clamp(view.config_sel - 1, 0, count - 1)
        git_view_scroll_config_into_view(view)
    case .DOWN:
        view.config_sel = count == 0 ? -1 : clamp(view.config_sel + 1, 0, count - 1)
        git_view_scroll_config_into_view(view)
    case .ENTER, .KP_ENTER:
        git_view_activate_config(view, view.config_sel)
    }
}

@(private = "file")
git_view_scroll_config_into_view :: proc(view: ^Git_View) {
    if view.config_sel < 0 {
        return
    }
    list := git_view_refs_list_rect(view)
    top := cast(f32) view.config_sel * GIT_REF_ROW
    if top < view.config_scroll {
        view.config_scroll = top
    } else if top + GIT_REF_ROW > view.config_scroll + list.height {
        view.config_scroll = top + GIT_REF_ROW - list.height
    }
}

// Enter or click on a settings row: folds a header, or starts editing the
// entry's value.
@(private = "file")
git_view_activate_config :: proc(view: ^Git_View, index: int) {
    rows := make([dynamic]Git_Config_Row, context.temp_allocator)
    git_view_config_rows(view, &rows)
    if index < 0 || index >= len(rows) {
        return
    }
    row := rows[index]
    if row.header {
        scope := row.global ? 1 : 0
        view.config_collapsed[scope] = !view.config_collapsed[scope]
        return
    }
    entry := view.config_rows[row.index]
    view.config_edit_index = row.index
    git_view_field_clear(&view.config_edit)
    if entry.is_set {
        git_view_field_insert(&view.config_edit, entry.value, false)
    }
    view.focus = .Config_Edit
}

// Commits the value being edited.
@(private = "file")
git_view_submit_config :: proc(view: ^Git_View) {
    index := view.config_edit_index
    view.config_edit_index = -1
    view.focus = .Files
    if index < 0 || index >= len(view.config_rows) || view.cbs.on_config_set == nil {
        return
    }
    entry := view.config_rows[index]
    view.cbs.on_config_set(view.data, entry.global, entry.key, strings.trim_space(string(view.config_edit.buf[:])))
}

@(private = "file")
git_view_submit_clone :: proc(view: ^Git_View) {
    url := strings.trim_space(string(view.clone_url.buf[:]))
    dir := strings.trim_space(string(view.clone_dir.buf[:]))
    if url == "" || dir == "" || view.busy || view.cbs.on_hosting == nil {
        return
    }
    view.cbs.on_hosting(view.data, .Clone, url, dir)
}

@(private = "file")
git_view_history_key :: proc(view: ^Git_View, event: ^ui.Event) {
    #partial switch event.key {
    case .UP:
        git_view_select_commit(view, view.commit_sel - 1)
    case .DOWN:
        git_view_select_commit(view, view.commit_sel + 1)
    case .ENTER, .KP_ENTER:
        view.focus = .Diff
    }
}

@(private)
git_view_select_commit :: proc(view: ^Git_View, index: int) {
    if len(view.commits) == 0 {
        return
    }
    next := clamp(index, 0, len(view.commits) - 1)
    if next == view.commit_sel {
        return
    }
    view.commit_sel = next

    list := git_view_commits_list_rect(view)
    top := cast(f32) next * GIT_COMMIT_ROW
    if top < view.commits_scroll {
        view.commits_scroll = top
    } else if top + GIT_COMMIT_ROW > view.commits_scroll + list.height {
        view.commits_scroll = top + GIT_COMMIT_ROW - list.height
    }

    if view.cbs.on_select_commit != nil {
        view.cbs.on_select_commit(view.data, view.commits[next].hash)
    }
}

@(private = "file")
git_view_branches_key :: proc(view: ^Git_View, event: ^ui.Event) {
    count := git_view_ref_row_count(view)
    #partial switch event.key {
    case .UP:
        view.ref_sel = count == 0 ? -1 : clamp(view.ref_sel - 1, 0, count - 1)
        git_view_scroll_ref_into_view(view)
    case .DOWN:
        view.ref_sel = count == 0 ? -1 : clamp(view.ref_sel + 1, 0, count - 1)
        git_view_scroll_ref_into_view(view)
    case .ENTER, .KP_ENTER:
        git_view_activate_ref(view, view.ref_sel)
    }
}

@(private = "file")
git_view_scroll_ref_into_view :: proc(view: ^Git_View) {
    if view.ref_sel < 0 {
        return
    }
    list := git_view_refs_list_rect(view)
    top := cast(f32) view.ref_sel * GIT_REF_ROW
    if top < view.refs_scroll {
        view.refs_scroll = top
    } else if top + GIT_REF_ROW > view.refs_scroll + list.height {
        view.refs_scroll = top + GIT_REF_ROW - list.height
    }
}

// Enter or click on a branches row: folds a header, checks out a branch, tag
// or remote branch, applies a stash.
@(private = "file")
git_view_activate_ref :: proc(view: ^Git_View, index: int) {
    rows := make([dynamic]Git_Ref_Row, context.temp_allocator)
    git_view_ref_rows(view, &rows)
    if index < 0 || index >= len(rows) {
        return
    }
    row := rows[index]
    if row.header {
        view.ref_collapsed[row.kind] = !view.ref_collapsed[row.kind]
        return
    }
    if view.busy {
        return
    }
    ref := view.refs[row.index]
    if ref.kind == .Stash {
        if view.cbs.on_stash != nil {
            view.cbs.on_stash(view.data, .Apply, ref.name)
        }
        return
    }
    if !ref.current && view.cbs.on_checkout != nil {
        view.cbs.on_checkout(view.data, ref.kind, ref.name)
    }
}

@(private = "file")
git_view_files_key :: proc(view: ^Git_View, event: ^ui.Event) {
    #partial switch event.key {
    case .UP:
        git_view_move_file_selection(view, -1)
    case .DOWN:
        git_view_move_file_selection(view, 1)
    case .SPACE:
        if path, staged, ok := git_view_selected_file(view); ok && !view.busy && view.cbs.on_stage != nil {
            view.cbs.on_stage(view.data, path, !staged)
        }
    case .ENTER, .KP_ENTER:
        view.focus = .Diff
    }
}

@(private = "file")
git_view_diff_key :: proc(view: ^Git_View, event: ^ui.Event) {
    list := git_view_diff_list_rect(view)
    #partial switch event.key {
    case .UP:
        view.diff_scroll -= GIT_DIFF_ROW
    case .DOWN:
        view.diff_scroll += GIT_DIFF_ROW
    case .PAGE_UP:
        view.diff_scroll -= list.height
    case .PAGE_DOWN:
        view.diff_scroll += list.height
    }
    view.diff_scroll = clamp(view.diff_scroll, 0, git_view_max_scroll(len(view.diff_rows), GIT_DIFF_ROW, list.height))
}

// Moves the combined selection: the unstaged list flows into the staged one.
@(private)
git_view_move_file_selection :: proc(view: ^Git_View, dir: int) {
    total := len(view.unstaged) + len(view.staged)
    if total == 0 {
        return
    }
    flat := view.sel_index
    if flat < 0 {
        flat = 0
    } else if view.sel_staged {
        flat += len(view.unstaged)
    }
    if view.sel_index >= 0 {
        flat = clamp(flat + dir, 0, total - 1)
    }
    git_view_select_flat(view, flat)
}

@(private = "file")
git_view_select_flat :: proc(view: ^Git_View, flat: int) {
    staged := flat >= len(view.unstaged)
    index := staged ? flat - len(view.unstaged) : flat
    git_view_select_file(view, staged, index)
}

// Selects (staged, index), scrolls it into view, and tells the host so it can
// fetch the diff.
@(private)
git_view_select_file :: proc(view: ^Git_View, staged: bool, index: int) {
    if view.sel_staged == staged && view.sel_index == index {
        return
    }
    view.sel_staged = staged
    view.sel_index = index

    _, list := git_view_section_rects(view, staged)
    scroll := staged ? &view.staged_scroll : &view.unstaged_scroll
    top := cast(f32) index * GIT_FILE_ROW
    if top < scroll^ {
        scroll^ = top
    } else if top + GIT_FILE_ROW > scroll^ + list.height {
        scroll^ = top + GIT_FILE_ROW - list.height
    }
    count := staged ? len(view.staged) : len(view.unstaged)
    scroll^ = clamp(scroll^, 0, git_view_max_scroll(count, GIT_FILE_ROW, list.height))

    if path, sel_staged, ok := git_view_selected_file(view); ok && view.cbs.on_select_file != nil {
        view.cbs.on_select_file(view.data, path, sel_staged)
    }
}

@(private = "file")
git_view_field_key :: proc(view: ^Git_View, event: ^ui.Event) {
    field, multiline := git_view_focused_field(view)
    if field == nil {
        return
    }
    text := string(field.buf[:])

    // Paste, filtered like typed input: no \r ever, no \n in a single line.
    if (.Ctrl in event.mods) && event.key == .V {
        clip := rl.GetClipboardText()
        if clip != nil {
            git_view_field_insert(field, string(clip), multiline)
        }
        return
    }

    #partial switch event.key {
    case .BACKSPACE:
        if start := input_prev_rune(text, field.caret); start < field.caret {
            remove_range(&field.buf, start, field.caret)
            field.caret = start
        }
    case .DELETE:
        if end := input_next_rune(text, field.caret); end > field.caret {
            remove_range(&field.buf, field.caret, end)
        }
    case .LEFT:
        field.caret = input_prev_rune(text, field.caret)
    case .RIGHT:
        field.caret = input_next_rune(text, field.caret)
    case .HOME:
        field.caret = git_view_line_start(text, field.caret)
    case .END:
        field.caret = git_view_line_end(text, field.caret)
    case .UP:
        if view.focus == .Description {
            field.caret = git_view_caret_vertical(text, field.caret, -1)
        }
    case .DOWN:
        if view.focus == .Description {
            field.caret = git_view_caret_vertical(text, field.caret, 1)
        }
    case .ENTER, .KP_ENTER:
        #partial switch view.focus {
        case .Subject:
            view.focus = .Description
        case .Description:
            git_view_field_insert(field, "\n", true)
        case .Config_Edit:
            git_view_submit_config(view)
        case .Clone_Url:
            view.focus = .Clone_Dir
        case .Clone_Dir:
            git_view_submit_clone(view)
        }
    }
}

// Inserts `text` at the caret, dropping \r and, in a single-line field,
// everything from the first \n on.
@(private)
git_view_field_insert :: proc(field: ^Git_Text_Field, text: string, multiline: bool) {
    for c in text {
        if c == '\r' {
            continue
        }
        if c == '\n' && !multiline {
            break
        }
        buffer, width := utf8.encode_rune(c)
        inject_at(&field.buf, field.caret, ..buffer[:width])
        field.caret += width
    }
}

@(private)
git_view_line_start :: proc(text: string, caret: int) -> int {
    start := strings.last_index_byte(text[:caret], '\n')
    return start + 1
}

@(private)
git_view_line_end :: proc(text: string, caret: int) -> int {
    if end := strings.index_byte(text[caret:], '\n'); end >= 0 {
        return caret + end
    }
    return len(text)
}

// Moves the caret one line up or down, keeping the rune column when the target
// line is long enough.
@(private)
git_view_caret_vertical :: proc(text: string, caret: int, dir: int) -> int {
    line_start := git_view_line_start(text, caret)
    column := utf8.rune_count_in_string(text[line_start:caret])

    target_start: int
    if dir < 0 {
        if line_start == 0 {
            return caret
        }
        target_start = git_view_line_start(text, line_start - 1)
    } else {
        line_end := git_view_line_end(text, caret)
        if line_end >= len(text) {
            return caret
        }
        target_start = line_end + 1
    }

    pos := target_start
    for _ in 0 ..< column {
        if pos >= len(text) || text[pos] == '\n' {
            break
        }
        pos = input_next_rune(text, pos)
    }
    return pos
}

@(private = "file")
git_view_text_input :: proc(view: ^Git_View, event: ^ui.Event) {
    field, _ := git_view_focused_field(view)
    if field == nil {
        return
    }
    if (.Ctrl in event.mods) && !(.Alt in event.mods) {
        return
    }
    if event.codepoint < 32 || event.codepoint == 127 {
        return
    }
    buffer, width := utf8.encode_rune(event.codepoint)
    inject_at(&field.buf, field.caret, ..buffer[:width])
    field.caret += width
}

// Wheel scrolls whatever list the mouse is over, focus apart.
@(private = "file")
git_view_scroll :: proc(view: ^Git_View, event: ^ui.Event) {
    point := event.mouse_position
    delta := event.wheel_delta

    switch view.kind {
    case .Changes:
        _, unstaged_list := git_view_section_rects(view, false)
        _, staged_list := git_view_section_rects(view, true)
        diff_list := git_view_diff_list_rect(view)
        switch {
        case rl.CheckCollisionPointRec(point, unstaged_list):
            view.unstaged_scroll -= delta * GIT_FILE_ROW
        case rl.CheckCollisionPointRec(point, staged_list):
            view.staged_scroll -= delta * GIT_FILE_ROW
        case rl.CheckCollisionPointRec(point, diff_list):
            view.diff_scroll -= delta * GIT_DIFF_ROW * 3
        }
    case .History:
        switch {
        case rl.CheckCollisionPointRec(point, git_view_commits_list_rect(view)):
            view.commits_scroll -= delta * GIT_COMMIT_ROW
        case rl.CheckCollisionPointRec(point, git_view_diff_list_rect(view)):
            view.diff_scroll -= delta * GIT_DIFF_ROW * 3
        }
    case .Branches:
        if rl.CheckCollisionPointRec(point, git_view_refs_list_rect(view)) {
            view.refs_scroll -= delta * GIT_REF_ROW
        }
    case .Settings:
        if rl.CheckCollisionPointRec(point, git_view_refs_list_rect(view)) {
            view.config_scroll -= delta * GIT_REF_ROW
        }
    case .Hosting:
        if rl.CheckCollisionPointRec(point, git_view_refs_list_rect(view)) {
            view.hosting_scroll -= delta * GIT_REF_ROW
        }
    }
    git_view_clamp_scrolls(view)
}

@(private = "file")
git_view_mouse_down :: proc(view: ^Git_View, ctx: ^ui.Context, point: rl.Vector2) {
    if !rl.CheckCollisionPointRec(point, view.box) {
        git_view_close(view, ctx)
        return
    }
    if rl.CheckCollisionPointRec(point, git_view_close_rect(view)) {
        git_view_close(view, ctx)
        return
    }
    if git_view_click_sync(view, point) {
        return
    }
    if git_view_click_sidebar(view, point) {
        return
    }
    switch view.kind {
    case .Changes:
        git_view_click_changes(view, point)
    case .History:
        git_view_click_history(view, point)
    case .Branches:
        git_view_click_branches(view, point)
    case .Settings:
        git_view_click_settings(view, point)
    case .Hosting:
        git_view_click_hosting(view, point)
    }
}

@(private = "file")
git_view_click_settings :: proc(view: ^Git_View, point: rl.Vector2) {
    index := git_view_config_row_at(view, point)
    if index < 0 {
        view.config_edit_index = -1
        view.focus = .Files
        return
    }
    view.config_sel = index
    git_view_activate_config(view, index)
}

@(private = "file")
git_view_click_hosting :: proc(view: ^Git_View, point: rl.Vector2) {
    items := make([dynamic]Git_Hosting_Item, context.temp_allocator)
    git_view_hosting_items(view, &items)
    for item in items {
        if !rl.CheckCollisionPointRec(point, item.rect) {
            continue
        }
        switch item.kind {
        case .Action_Repo:
            git_view_fire_hosting(view, .Open_Repo, "", "")
        case .Action_File:
            git_view_fire_hosting(view, .Open_File, "", "")
        case .Action_Commit:
            git_view_fire_hosting(view, .Open_Commit, "", "")
        case .Action_Pr:
            git_view_fire_hosting(view, .Create_Pr, "", "")
        case .Pr:
            if item.index >= 0 && item.index < len(view.prs) {
                git_view_fire_hosting(view, .Open_Pr, view.prs[item.index].url, "")
            }
        case .Clone_Url_Field:
            view.focus = .Clone_Url
            view.clone_url.caret = len(view.clone_url.buf)
        case .Clone_Dir_Field:
            view.focus = .Clone_Dir
            view.clone_dir.caret = len(view.clone_dir.buf)
        case .Clone_Button:
            git_view_submit_clone(view)
        case .Card, .Pr_Header, .Cli_Hint, .Clone_Header:
        }
        return
    }
    view.focus = .Files
}

@(private = "file")
git_view_fire_hosting :: proc(view: ^Git_View, action: Git_Hosting_Action, arg, arg2: string) {
    if view.busy || view.cbs.on_hosting == nil {
        return
    }
    view.cbs.on_hosting(view.data, action, arg, arg2)
}

// Seeds the clone destination once, so a typed path is not overwritten.
git_view_set_clone_dir_hint :: proc(view: ^Git_View, dir: string) {
    if len(view.clone_dir.buf) > 0 {
        return
    }
    git_view_field_insert(&view.clone_dir, dir, false)
}

@(private = "file")
git_view_click_history :: proc(view: ^Git_View, point: rl.Vector2) {
    index := git_view_commit_row_at(view, point)
    if index < 0 {
        if rl.CheckCollisionPointRec(point, git_view_diff_list_rect(view)) {
            view.focus = .Diff
        }
        return
    }
    view.focus = .Files
    if index >= len(view.commits) {
        if view.cbs.on_load_more != nil {
            view.cbs.on_load_more(view.data)
        }
        return
    }
    git_view_select_commit(view, index)
}

@(private = "file")
git_view_click_branches :: proc(view: ^Git_View, point: rl.Vector2) {
    index := git_view_ref_row_at(view, point)
    if index < 0 {
        return
    }
    view.focus = .Files
    view.ref_sel = index

    rows := make([dynamic]Git_Ref_Row, context.temp_allocator)
    git_view_ref_rows(view, &rows)
    row := rows[index]

    // The stashes header carries a "Stash changes" action.
    if row.header && row.kind == .Stash && !view.busy && view.cbs.on_stash != nil {
        header := git_view_ref_row_rect(view, index)
        if rl.CheckCollisionPointRec(point, git_view_section_action_rect(view, header, "Stash changes")) {
            view.cbs.on_stash(view.data, .Save, "")
            return
        }
    }

    // A stash row's hover actions take the click before the row does.
    if !row.header && view.refs[row.index].kind == .Stash && !view.busy && view.cbs.on_stash != nil {
        apply, pop, drop := git_view_stash_action_rects(git_view_ref_row_rect(view, index))
        name := view.refs[row.index].name
        switch {
        case rl.CheckCollisionPointRec(point, apply):
            view.cbs.on_stash(view.data, .Apply, name)
            return
        case rl.CheckCollisionPointRec(point, pop):
            view.cbs.on_stash(view.data, .Pop, name)
            return
        case rl.CheckCollisionPointRec(point, drop):
            view.cbs.on_stash(view.data, .Drop, name)
            return
        }
        return // a plain click on a stash row only selects
    }
    git_view_activate_ref(view, index)
}

@(private = "file")
git_view_click_sync :: proc(view: ^Git_View, point: rl.Vector2) -> bool {
    fetch, pull, push := git_view_sync_rects(view)
    op: Git_Sync_Op
    switch {
    case rl.CheckCollisionPointRec(point, fetch):
        op = .Fetch
    case rl.CheckCollisionPointRec(point, pull):
        op = .Pull
    case rl.CheckCollisionPointRec(point, push):
        op = .Push
    case:
        return false
    }
    if !view.busy && view.cbs.on_sync != nil {
        view.cbs.on_sync(view.data, op)
    }
    return true
}

@(private = "file")
git_view_click_sidebar :: proc(view: ^Git_View, point: rl.Vector2) -> bool {
    if !rl.CheckCollisionPointRec(point, view.sidebar) {
        return false
    }
    kinds := make([dynamic]Git_View_Kind, context.temp_allocator)
    git_view_categories(view, &kinds)
    for kind, i in kinds {
        if !rl.CheckCollisionPointRec(point, git_view_category_rect(view, i)) {
            continue
        }
        if view.kind != kind {
            view.kind = kind
            view.focus = .Files
            if view.cbs.on_view_changed != nil {
                view.cbs.on_view_changed(view.data, kind)
            }
        }
        break
    }
    return true
}

// Routes a click inside the changes view. A stage callback refreshes the
// lists, so nothing is read from a row after one fires.
@(private = "file")
git_view_click_changes :: proc(view: ^Git_View, point: rl.Vector2) {
    // Section header actions.
    unstaged_header, _ := git_view_section_rects(view, false)
    staged_header, _ := git_view_section_rects(view, true)
    if !view.busy && view.cbs.on_stage != nil {
        if len(view.unstaged) > 0 && rl.CheckCollisionPointRec(point, git_view_section_action_rect(view, unstaged_header, "Stage All")) {
            view.cbs.on_stage(view.data, "", true)
            return
        }
        if len(view.staged) > 0 && rl.CheckCollisionPointRec(point, git_view_section_action_rect(view, staged_header, "Unstage All")) {
            view.cbs.on_stage(view.data, "", false)
            return
        }
    }

    // File rows: the action boxes stage/unstage or discard, the rest selects.
    for staged in ([2]bool {false, true}) {
        index := git_view_file_row_at(view, staged, point)
        if index < 0 {
            continue
        }
        view.focus = .Files
        row := git_view_file_row_rect(view, staged, index)
        if rl.CheckCollisionPointRec(point, git_view_file_action_rect(row)) && !view.busy && view.cbs.on_stage != nil {
            list := staged ? &view.staged : &view.unstaged
            view.cbs.on_stage(view.data, list[index].path, !staged)
            return
        }
        if !staged && rl.CheckCollisionPointRec(point, git_view_file_discard_rect(row)) && !view.busy && view.cbs.on_discard != nil {
            view.cbs.on_discard(view.data, view.unstaged[index].path)
            return
        }
        git_view_select_file(view, staged, index)
        return
    }

    // Commit box.
    if rl.CheckCollisionPointRec(point, git_view_subject_rect(view)) {
        view.focus = .Subject
        view.subject.caret = len(view.subject.buf)
        return
    }
    if rl.CheckCollisionPointRec(point, git_view_description_rect(view)) {
        view.focus = .Description
        view.description.caret = len(view.description.buf)
        return
    }
    if rl.CheckCollisionPointRec(point, git_view_amend_rect(view)) {
        view.amend = !view.amend
        return
    }
    if rl.CheckCollisionPointRec(point, git_view_commit_button_rect(view)) {
        git_view_submit_commit(view)
        return
    }
    if rl.CheckCollisionPointRec(point, git_view_diff_list_rect(view)) {
        view.focus = .Diff
    }
}

// A commit needs something to commit and a subject line; git would refuse an
// empty message anyway, so the button stays off instead.
@(private)
git_view_can_commit :: proc(view: ^Git_View) -> bool {
    if view.busy {
        return false
    }
    if len(view.staged) == 0 && !view.amend {
        return false
    }
    return strings.trim_space(string(view.subject.buf[:])) != ""
}

@(private = "file")
git_view_submit_commit :: proc(view: ^Git_View) {
    if !git_view_can_commit(view) || view.cbs.on_commit == nil {
        return
    }
    view.cbs.on_commit(
        view.data,
        strings.trim_space(string(view.subject.buf[:])),
        strings.trim_right_space(string(view.description.buf[:])),
        view.amend,
    )
}

// Empties the commit box; the host calls it after a commit lands.
git_view_clear_commit :: proc(view: ^Git_View) {
    git_view_field_clear(&view.subject)
    git_view_field_clear(&view.description)
    view.amend = false
}

git_view_destroy :: proc(widget: ^ui.Widget) {
    view := cast(^Git_View) widget
    for file in view.unstaged {
        git_view_file_free(file)
    }
    for file in view.staged {
        git_view_file_free(file)
    }
    delete(view.unstaged)
    delete(view.staged)
    git_view_clear_commits(view)
    delete(view.commits)
    git_view_clear_refs(view)
    delete(view.refs)
    git_view_clear_config(view)
    delete(view.config_rows)
    git_view_clear_prs(view)
    delete(view.prs)
    git_view_free_diff(view)
    delete(view.branch)
    delete(view.status_line)
    delete(view.restore_path)
    delete(view.host_label)
    delete(view.host_icon)
    delete(view.cli_name)
    delete(view.subject.buf)
    delete(view.description.buf)
    delete(view.config_edit.buf)
    delete(view.clone_url.buf)
    delete(view.clone_dir.buf)
    free(view)
}
