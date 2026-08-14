package thor

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../shell"
import "../widgets"

// Async git commands for the git view: one Git_Op_Job per operation, run on a
// worker thread and drained by thor_process_io. The parsers are pure and take
// command output as a string, so they are tested without a repo.

// Commands with no network access get the short timeout; fetch/pull/push can
// stall on a credential prompt, so they are killed instead of hanging forever.
GIT_LOCAL_TIMEOUT :: 10 * time.Second
GIT_NETWORK_TIMEOUT :: 60 * time.Second

// Rows past this cap are dropped and replaced with one truncation marker.
GIT_DIFF_MAX_ROWS :: 5000

Git_Op :: enum {
    Snapshot,   // status -z + branch + upstream counts
    Diff_File,  // unified diff of one path (arg), staged when flag is set
    Stage,      // arg = repo-relative path
    Unstage,
    Stage_All,
    Unstage_All,
    Commit,     // arg = subject, arg2 = description, flag = amend
    Fetch,
    Pull,
    Push,
}

// One git command run off-thread. cwd/arg/arg2 are cloned at dispatch so the
// worker never reads Thor state; generation and serial let the main thread
// drop results the view no longer wants.
Git_Op_Job :: struct {
    owner:      ^Thor,
    allocator:  runtime.Allocator,
    worker:     ^thread.Thread,
    op:         Git_Op,
    generation: int,
    serial:     int,     // Diff_File: thor.git_diff_serial at dispatch
    cwd:        string,  // owned
    arg:        string,  // owned
    arg2:       string,  // owned
    flag:       bool,
    output:     string,  // owned; main command output
    code:       int,
    ok:         bool,
    // Snapshot only; owned.
    branch_output:   string,  // rev-parse --abbrev-ref HEAD
    branch_code:     int,
    head_output:     string,  // rev-parse --short HEAD, when detached
    upstream_output: string,  // rev-list --left-right --count @{upstream}...HEAD
    upstream_code:   int,
}

// One changed path from `git status --porcelain -z`, assigned to the staged
// (index) or unstaged (worktree) list. A file changed in both places yields
// two entries. Conflicts yield one unstaged entry.
Git_File_Entry :: struct {
    path:   string,  // owned; repo-relative, forward slashes
    status: widgets.Git_Status,
    staged: bool,
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

// Spawns `op` on a worker thread. Mutations are refused while one runs (the
// view disables its buttons; this is the safety net). Snapshot coalesces like
// thor_refresh_git_status does.
thor_git_op :: proc(thor: ^Thor, op: Git_Op, arg := "", arg2 := "", flag := false) {
    if thor.git_prefix == "" {
        return
    }
    if git_op_is_mutation(op) {
        if thor.git_mutation_inflight {
            return
        }
        thor.git_mutation_inflight = true
    }
    if op == .Snapshot {
        if thor.git_ui_snapshot_inflight {
            thor.git_ui_snapshot_dirty = true
            return
        }
        thor.git_ui_snapshot_inflight = true
    }

    job := new(Git_Op_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.op = op
    job.generation = thor.git_ui_generation
    job.cwd = strings.clone(thor.workspace_dir)
    job.arg = strings.clone(arg)
    job.arg2 = strings.clone(arg2)
    job.flag = flag
    if op == .Diff_File {
        thor.git_diff_serial += 1
        job.serial = thor.git_diff_serial
    }

    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, git_op_worker)
}

git_op_is_mutation :: proc(op: Git_Op) -> bool {
    switch op {
    case .Stage, .Unstage, .Stage_All, .Unstage_All, .Commit, .Fetch, .Pull, .Push:
        return true
    case .Snapshot, .Diff_File:
        return false
    }
    return false
}

@(private = "file")
git_op_worker :: proc(job: ^Git_Op_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    switch job.op {
    case .Snapshot:
        git_run_snapshot(job)
    case .Diff_File:
        git_run_diff_file(job)
    case .Commit:
        git_run_commit(job)
    case .Stage, .Unstage, .Stage_All, .Unstage_All, .Fetch, .Pull, .Push:
        git_run_simple(job)
    }

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_git_ops, job)
    sync.unlock(&job.owner.io_mutex)
}

@(private = "file")
git_run_snapshot :: proc(job: ^Git_Op_Job) {
    job.output, job.code, job.ok = shell.run_status("git status --porcelain -z", job.cwd, GIT_LOCAL_TIMEOUT)
    job.branch_output, job.branch_code, _ = shell.run_status("git rev-parse --abbrev-ref HEAD", job.cwd, GIT_LOCAL_TIMEOUT)
    if strings.trim_space(job.branch_output) == "HEAD" {
        job.head_output, _, _ = shell.run_status("git rev-parse --short HEAD", job.cwd, GIT_LOCAL_TIMEOUT)
    }
    job.upstream_output, job.upstream_code, _ = shell.run_status("git rev-list --left-right --count @{upstream}...HEAD", job.cwd, GIT_LOCAL_TIMEOUT)
}

@(private = "file")
git_run_diff_file :: proc(job: ^Git_Op_Job) {
    quoted, quote_ok := git_quote_path(job.arg)
    if !quote_ok {
        job.output = strings.clone("unsupported character in path")
        job.code = -1
        return
    }
    cached := job.flag ? "--cached " : ""
    cmd := strings.concatenate({"git diff ", cached, "--no-color -- ", quoted}, context.temp_allocator)
    job.output, job.code, job.ok = shell.run_status(cmd, job.cwd, GIT_LOCAL_TIMEOUT)
}

// The message goes through a file in the git dir, never through the shell
// line, so its content needs no quoting at all.
@(private = "file")
git_run_commit :: proc(job: ^Git_Op_Job) {
    dir_output, dir_code, dir_ok := shell.run_status("git rev-parse --git-dir", job.cwd, GIT_LOCAL_TIMEOUT)
    defer delete(dir_output)
    if !dir_ok || dir_code != 0 {
        job.output = strings.clone(dir_output)
        job.code = dir_code
        return
    }
    git_dir := strings.trim_space(dir_output)
    if !filepath.is_abs(git_dir) {
        joined, join_err := filepath.join({job.cwd, git_dir}, context.temp_allocator)
        if join_err != nil {
            job.output = strings.clone("could not resolve the git directory")
            job.code = -1
            return
        }
        git_dir = joined
    }
    msg_path, msg_err := filepath.join({git_dir, "THOR_COMMITMSG"}, context.temp_allocator)
    if msg_err != nil {
        job.output = strings.clone("could not resolve the git directory")
        job.code = -1
        return
    }

    message := strings.concatenate({job.arg, "\n\n", job.arg2, "\n"}, context.temp_allocator)
    if job.arg2 == "" {
        message = strings.concatenate({job.arg, "\n"}, context.temp_allocator)
    }
    if err := os.write_entire_file(msg_path, transmute([]byte) message); err != nil {
        job.output = strings.clone("could not write the commit message file")
        job.code = -1
        return
    }
    defer os.remove(msg_path)

    quoted, quote_ok := git_quote_path(msg_path)
    if !quote_ok {
        job.output = strings.clone("unsupported character in the repository path")
        job.code = -1
        return
    }
    amend := job.flag ? " --amend" : ""
    cmd := strings.concatenate({"git commit -F ", quoted, amend}, context.temp_allocator)
    job.output, job.code, job.ok = shell.run_status(cmd, job.cwd, GIT_LOCAL_TIMEOUT)
}

@(private = "file")
git_run_simple :: proc(job: ^Git_Op_Job) {
    cmd: string
    timeout := GIT_LOCAL_TIMEOUT
    switch job.op {
    case .Stage, .Unstage:
        quoted, quote_ok := git_quote_path(job.arg)
        if !quote_ok {
            job.output = strings.clone("unsupported character in path")
            job.code = -1
            return
        }
        verb := job.op == .Stage ? "git add -- " : "git reset -q -- "
        cmd = strings.concatenate({verb, quoted}, context.temp_allocator)
    case .Stage_All:
        cmd = "git add -A"
    case .Unstage_All:
        cmd = "git reset -q"
    case .Fetch:
        cmd = "git fetch --all --prune"
        timeout = GIT_NETWORK_TIMEOUT
    case .Pull:
        cmd = "git pull --ff-only"
        timeout = GIT_NETWORK_TIMEOUT
    case .Push:
        cmd = "git push"
        timeout = GIT_NETWORK_TIMEOUT
    case .Snapshot, .Diff_File, .Commit:
        return
    }
    job.output, job.code, job.ok = shell.run_status(cmd, job.cwd, timeout)
}

// Drains a finished op (called from thor_process_io). Results from a closed
// view or an earlier workspace are freed without being applied; a mutation
// still refreshes the tree tint, since the working tree did change.
thor_apply_git_op :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)
    thor.inflight_jobs -= 1

    stale := job.generation != thor.git_ui_generation
    switch job.op {
    case .Snapshot:
        thor.git_ui_snapshot_inflight = false
        if !stale {
            thor_git_apply_snapshot(thor, job)
        }
        if thor.git_ui_snapshot_dirty {
            thor.git_ui_snapshot_dirty = false
            thor_git_op(thor, .Snapshot)
        }
    case .Diff_File:
        if !stale && job.serial == thor.git_diff_serial {
            thor_git_apply_diff(thor, job)
        }
    case .Stage, .Unstage, .Stage_All, .Unstage_All, .Commit, .Fetch, .Pull, .Push:
        thor.git_mutation_inflight = false
        thor_refresh_git_status(thor)
        if !stale {
            thor_git_apply_mutation(thor, job)
            thor_git_op(thor, .Snapshot)
        }
    }
    git_op_free(job)
}

@(private = "file")
git_op_free :: proc(job: ^Git_Op_Job) {
    delete(job.cwd)
    delete(job.arg)
    delete(job.arg2)
    delete(job.output)
    delete(job.branch_output)
    delete(job.head_output)
    delete(job.upstream_output)
    free(job)
}

// Keeps the statusbar branch in step: checkout and pull can move HEAD, which
// thor_read_git_branch only reads at workspace open. The statusbar reads
// thor.git_branch each frame, so the swap alone is the refresh.
@(private = "file")
thor_git_apply_snapshot :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    branch := git_snapshot_branch(job, context.temp_allocator)
    if branch != "" && branch != thor.git_branch {
        delete(thor.git_branch)
        thor.git_branch = strings.clone(branch)
    }

    // The view push lands here once the git view exists.
}

@(private = "file")
thor_git_apply_diff :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    // The view push lands here once the git view exists.
    _ = thor
    _ = job
}

@(private = "file")
thor_git_apply_mutation :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    if job.ok && job.code == 0 {
        return
    }
    line := git_first_line(job.output)
    if line == "" {
        line = "git command failed"
    }
    thor_flash_status(thor, line, is_error = true)
}

// Display branch for a snapshot: the branch name, "detached @ <hash>" on a
// detached HEAD, "" when the branch could not be read (unborn repo).
git_snapshot_branch :: proc(job: ^Git_Op_Job, allocator := context.temp_allocator) -> string {
    if job.branch_code != 0 {
        return ""
    }
    branch := strings.trim_space(job.branch_output)
    if branch == "HEAD" {
        hash := strings.trim_space(job.head_output)
        if hash == "" {
            return ""
        }
        return strings.concatenate({"detached @ ", hash}, allocator)
    }
    return branch
}

git_first_line :: proc(s: string) -> string {
    it := s
    for line in strings.split_lines_iterator(&it) {
        trimmed := strings.trim_space(line)
        if trimmed != "" {
            return trimmed
        }
    }
    return ""
}

// Parses `git status --porcelain -z` records into per-list entries. -z keeps
// paths verbatim (no C-quoting), so non-ASCII names survive; a rename's origin
// path travels as its own NUL field and is consumed with its record.
git_parse_porcelain_z :: proc(output: string, out: ^[dynamic]Git_File_Entry) {
    rest := output
    for {
        record, record_ok := git_next_field(&rest)
        if !record_ok {
            break
        }
        // "XY path". The guards also drop git error text (e.g. "fatal: ...").
        if len(record) < 4 || record[2] != ' ' || !git_valid_code(record[:2]) {
            continue
        }
        code := record[:2]
        path := record[3:]
        if path == "" || code == "!!" {
            continue
        }
        x, y := code[0], code[1]
        if x == 'R' || x == 'C' || y == 'R' || y == 'C' {
            git_next_field(&rest) or_break
        }

        // A conflict is one unstaged entry: both sides need the same resolve.
        if git_status_from_code(code) == .Conflict {
            append(out, Git_File_Entry{strings.clone(path), .Conflict, false})
            continue
        }
        if x != ' ' && x != '?' {
            append(out, Git_File_Entry{strings.clone(path), git_letter_status(x), true})
        }
        if y != ' ' {
            append(out, Git_File_Entry{strings.clone(path), git_letter_status(y), false})
        }
    }
}

@(private = "file")
git_next_field :: proc(rest: ^string) -> (field: string, ok: bool) {
    if len(rest^) == 0 {
        return
    }
    if nul := strings.index_byte(rest^, 0); nul >= 0 {
        field = rest^[:nul]
        rest^ = rest^[nul + 1:]
    } else {
        field = rest^
        rest^ = ""
    }
    // A trailing newline after the last NUL reads as an empty field.
    ok = field != "" && field != "\n"
    return
}

@(private = "file")
git_letter_status :: proc(c: u8) -> widgets.Git_Status {
    switch c {
    case 'A', 'C': return .Added
    case 'D':      return .Deleted
    case 'R':      return .Renamed
    case '?':      return .Untracked
    }
    return .Modified
}

git_file_entries_destroy :: proc(entries: ^[dynamic]Git_File_Entry) {
    for entry in entries {
        delete(entry.path)
    }
    delete(entries^)
}

// "N\tM" from `rev-list --left-right --count @{upstream}...HEAD`: the left
// side counts commits only upstream has (behind), the right side ours (ahead).
git_parse_upstream_counts :: proc(output: string) -> (ahead, behind: int, ok: bool) {
    trimmed := strings.trim_space(output)
    tab := strings.index_byte(trimmed, '\t')
    if tab < 0 {
        return
    }
    behind = strconv.parse_int(trimmed[:tab]) or_return
    ahead = strconv.parse_int(strings.trim_space(trimmed[tab + 1:])) or_return
    ok = behind >= 0 && ahead >= 0
    return
}

// Parses a unified diff into display rows, running the old/new line counters
// through each hunk. File headers are dropped; binary and missing-newline
// markers become Meta rows.
git_parse_diff_rows :: proc(output: string, out: ^[dynamic]Git_Diff_Row) {
    old_line, new_line := 0, 0
    in_hunk := false

    it := output
    for raw in strings.split_lines_iterator(&it) {
        line := strings.trim_suffix(raw, "\r")

        if len(out) >= GIT_DIFF_MAX_ROWS {
            append(out, Git_Diff_Row{.Meta, 0, 0, strings.clone("diff truncated")})
            return
        }

        if strings.has_prefix(line, "@@") {
            old_start, new_start, header_ok := git_parse_hunk_starts(line)
            if !header_ok {
                continue
            }
            old_line, new_line = old_start, new_start
            in_hunk = true
            append(out, Git_Diff_Row{.Hunk, 0, 0, git_diff_text(line)})
            continue
        }
        if strings.has_prefix(line, "Binary files ") {
            append(out, Git_Diff_Row{.Meta, 0, 0, git_diff_text(line)})
            continue
        }
        if strings.has_prefix(line, "\\ ") {
            append(out, Git_Diff_Row{.Meta, 0, 0, git_diff_text(line[2:])})
            continue
        }
        if !in_hunk {
            continue
        }

        switch {
        case strings.has_prefix(line, "+"):
            append(out, Git_Diff_Row{.Added, 0, new_line, git_diff_text(line[1:])})
            new_line += 1
        case strings.has_prefix(line, "-"):
            append(out, Git_Diff_Row{.Removed, old_line, 0, git_diff_text(line[1:])})
            old_line += 1
        case strings.has_prefix(line, " "):
            append(out, Git_Diff_Row{.Context, old_line, new_line, git_diff_text(line[1:])})
            old_line += 1
            new_line += 1
        case line == "":
            // An empty context line loses its leading space to trailing-space
            // stripping in transit; it still counts on both sides.
            append(out, Git_Diff_Row{.Context, old_line, new_line, strings.clone("")})
            old_line += 1
            new_line += 1
        case:
            // "diff --git" starts the next file: its headers follow.
            in_hunk = false
        }
    }
}

// Owned row text with tabs expanded; the diff panel draws with one font run
// and no tab origin.
@(private = "file")
git_diff_text :: proc(line: string) -> string {
    expanded, was_allocation := strings.replace_all(line, "\t", "    ")
    if !was_allocation {
        return strings.clone(line)
    }
    return expanded
}

// "@@ -old_start[,count] +new_start[,count] @@": both start values.
@(private = "file")
git_parse_hunk_starts :: proc(line: string) -> (old_start, new_start: int, ok: bool) {
    rest := strings.trim_prefix(line, "@@")
    close := strings.index(rest, "@@")
    if close < 0 {
        return
    }
    parts := strings.fields(strings.trim_space(rest[:close]), context.temp_allocator)
    if len(parts) < 2 || len(parts[0]) < 2 || parts[0][0] != '-' || len(parts[1]) < 2 || parts[1][0] != '+' {
        return
    }
    old_start, _ = git_parse_range(parts[0][1:]) or_return
    new_start, _ = git_parse_range(parts[1][1:]) or_return
    ok = true
    return
}

git_diff_rows_destroy :: proc(rows: ^[dynamic]Git_Diff_Row) {
    for row in rows {
        delete(row.text)
    }
    delete(rows^)
}

// Quotes one path for a shell command line. Windows command lines have no
// safe escape for an embedded quote, so such a path is refused.
git_quote_path :: proc(path: string, allocator := context.temp_allocator) -> (quoted: string, ok: bool) {
    when ODIN_OS == .Windows {
        if strings.contains_rune(path, '"') {
            return "", false
        }
        return strings.concatenate({"\"", path, "\""}, allocator), true
    } else {
        // Escape what /bin/sh expands inside double quotes.
        b: strings.Builder
        strings.builder_init(&b, allocator)
        strings.write_byte(&b, '"')
        for c in transmute([]u8) path {
            if c == '"' || c == '$' || c == '`' || c == '\\' {
                strings.write_byte(&b, '\\')
            }
            strings.write_byte(&b, c)
        }
        strings.write_byte(&b, '"')
        return strings.to_string(b), true
    }
}
