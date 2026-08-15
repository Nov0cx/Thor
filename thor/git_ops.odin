package thor

import "base:runtime"
import "core:fmt"
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
    Snapshot,        // status -z + branch + upstream counts
    Diff_File,       // unified diff of one path (arg), staged when flag is set
    Log,             // arg = commit count
    Commit_Show,     // arg = hash
    Refs,            // branches + remotes + tags + stashes
    Stage,           // arg = repo-relative path
    Unstage,
    Stage_All,
    Unstage_All,
    Discard,         // arg = repo-relative path
    Commit,          // arg = subject, arg2 = description, flag = amend
    Fetch,
    Pull,
    Push,
    Checkout,        // arg = branch or tag name
    Checkout_Remote, // arg = remote branch ("origin/x"), makes a local "x"
    Stash_Save,      // arg = optional message
    Stash_Apply,     // arg = "stash@{N}"
    Stash_Pop,
    Stash_Drop,
    Config_List,     // local + global tables
    Config_Set,      // arg = key, arg2 = value, flag = global
    Remote_Url,      // origin's URL
    CLI_Probe,       // gh + glab --version
    PR_List,         // flag = use glab
    PR_Create,       // arg = branch, flag = use glab
    Clone,           // arg = url, arg2 = destination directory
    Lfs_Probe,       // git lfs version + ls-files + tracked patterns
    Lfs_Pull,        // fetch + checkout of LFS objects
    Lfs_Track,       // arg = pattern
}

// Cloning fetches a whole repository, so it gets its own generous timeout.
GIT_CLONE_TIMEOUT :: 120 * time.Second

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
    // Secondary command outputs, owned; what each slot holds depends on the
    // op — Snapshot: branch / short head / upstream counts, Refs: remote
    // branches / tags / stash list.
    aux:       [3]string,
    aux_codes: [3]int,
}

// One changed path from `git status --porcelain -z`, assigned to the staged
// (index) or unstaged (worktree) list. A file changed in both places yields
// two entries. Conflicts yield one unstaged entry.
Git_File_Entry :: struct {
    path:   string,  // owned; repo-relative, forward slashes
    status: widgets.Git_Status,
    staged: bool,
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
    // Both fill the diff pane, so both race the same serial.
    if op == .Diff_File || op == .Commit_Show {
        thor.git_diff_serial += 1
        job.serial = thor.git_diff_serial
    }

    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, git_op_worker)
}

git_op_is_mutation :: proc(op: Git_Op) -> bool {
    switch op {
    case .Stage, .Unstage, .Stage_All, .Unstage_All, .Discard, .Commit, .Fetch, .Pull, .Push,
         .Checkout, .Checkout_Remote, .Stash_Save, .Stash_Apply, .Stash_Pop, .Stash_Drop,
         .Config_Set, .PR_Create, .Clone, .Lfs_Pull, .Lfs_Track:
        return true
    case .Snapshot, .Diff_File, .Log, .Commit_Show, .Refs, .Config_List, .Remote_Url, .CLI_Probe, .PR_List, .Lfs_Probe:
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
    case .Refs:
        git_run_refs(job)
    case .Config_List:
        git_run_config_list(job)
    case .CLI_Probe:
        git_run_cli_probe(job)
    case .Lfs_Probe:
        git_run_lfs_probe(job)
    case .Stage, .Unstage, .Stage_All, .Unstage_All, .Discard, .Fetch, .Pull, .Push,
         .Log, .Commit_Show, .Checkout, .Checkout_Remote,
         .Stash_Save, .Stash_Apply, .Stash_Pop, .Stash_Drop,
         .Config_Set, .Remote_Url, .PR_List, .PR_Create, .Clone, .Lfs_Pull, .Lfs_Track:
        git_run_simple(job)
    }

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_git_ops, job)
    sync.unlock(&job.owner.io_mutex)
}

// Snapshot slots: aux[0] = rev-parse --abbrev-ref HEAD, aux[1] = short HEAD
// hash (only when detached), aux[2] = upstream ahead/behind counts.
@(private = "file")
git_run_snapshot :: proc(job: ^Git_Op_Job) {
    job.output, job.code, job.ok = shell.run_status("git status --porcelain -z", job.cwd, GIT_LOCAL_TIMEOUT)
    job.aux[0], job.aux_codes[0], _ = shell.run_status("git rev-parse --abbrev-ref HEAD", job.cwd, GIT_LOCAL_TIMEOUT)
    if strings.trim_space(job.aux[0]) == "HEAD" {
        job.aux[1], job.aux_codes[1], _ = shell.run_status("git rev-parse --short HEAD", job.cwd, GIT_LOCAL_TIMEOUT)
    }
    job.aux[2], job.aux_codes[2], _ = shell.run_status("git rev-list --left-right --count @{upstream}...HEAD", job.cwd, GIT_LOCAL_TIMEOUT)
}

// Refs slots: output = local branches, aux[0] = remote branches, aux[1] =
// tags, aux[2] = stash list.
@(private = "file")
git_run_refs :: proc(job: ^Git_Op_Job) {
    job.output, job.code, job.ok = shell.run_status("git branch --format=%(refname:short)%09%(HEAD)", job.cwd, GIT_LOCAL_TIMEOUT)
    job.aux[0], job.aux_codes[0], _ = shell.run_status("git branch -r --format=%(refname:short)", job.cwd, GIT_LOCAL_TIMEOUT)
    job.aux[1], job.aux_codes[1], _ = shell.run_status("git tag --list", job.cwd, GIT_LOCAL_TIMEOUT)
    job.aux[2], job.aux_codes[2], _ = shell.run_status("git stash list --format=%gd%x09%gs", job.cwd, GIT_LOCAL_TIMEOUT)
}

// Config slots: output = --local -z, aux[0] = --global -z.
@(private = "file")
git_run_config_list :: proc(job: ^Git_Op_Job) {
    job.output, job.code, job.ok = shell.run_status("git config --list --local -z", job.cwd, GIT_LOCAL_TIMEOUT)
    job.aux[0], job.aux_codes[0], _ = shell.run_status("git config --list --global -z", job.cwd, GIT_LOCAL_TIMEOUT)
}

// Probe slots: output = gh --version, aux[0] = glab --version.
@(private = "file")
git_run_cli_probe :: proc(job: ^Git_Op_Job) {
    job.output, job.code, job.ok = shell.run_status("gh --version", job.cwd, GIT_LOCAL_TIMEOUT)
    job.aux[0], job.aux_codes[0], _ = shell.run_status("glab --version", job.cwd, GIT_LOCAL_TIMEOUT)
}

// LFS slots: output = git lfs version, aux[0] = tracked file names, aux[1] =
// tracked patterns. The listings are skipped when the CLI is missing.
@(private = "file")
git_run_lfs_probe :: proc(job: ^Git_Op_Job) {
    job.output, job.code, job.ok = shell.run_status("git lfs version", job.cwd, GIT_LOCAL_TIMEOUT)
    if !job.ok || job.code != 0 {
        return
    }
    job.aux[0], job.aux_codes[0], _ = shell.run_status("git lfs ls-files -n", job.cwd, GIT_LOCAL_TIMEOUT)
    job.aux[1], job.aux_codes[1], _ = shell.run_status("git lfs track", job.cwd, GIT_LOCAL_TIMEOUT)
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
    case .Stage, .Unstage, .Discard:
        quoted, quote_ok := git_quote_path(job.arg)
        if !quote_ok {
            job.output = strings.clone("unsupported character in path")
            job.code = -1
            return
        }
        verb := "git add -- "
        #partial switch job.op {
        case .Unstage: verb = "git reset -q -- "
        case .Discard: verb = "git checkout -- "
        }
        cmd = strings.concatenate({verb, quoted}, context.temp_allocator)
    case .Stage_All:
        cmd = "git add -A"
    case .Unstage_All:
        cmd = "git reset -q"
    case .Log:
        // Control-character field/record separators survive any subject text;
        // %x1f splits fields, %x1e ends a record.
        cmd = strings.concatenate(
            {"git log --date=short -n ", job.arg, " --format=%H%x1f%h%x1f%an%x1f%ad%x1f%D%x1f%s%x1e"},
            context.temp_allocator,
        )
    case .Commit_Show:
        quoted, quote_ok := git_quote_path(job.arg)
        if !quote_ok {
            job.output = strings.clone("unsupported hash")
            job.code = -1
            return
        }
        // --format= drops the header: the list row already carries it, so the
        // output is the pure diff the row parser reads.
        cmd = strings.concatenate({"git show --no-color --format= ", quoted}, context.temp_allocator)
    case .Checkout:
        quoted, quote_ok := git_quote_path(job.arg)
        if !quote_ok {
            job.output = strings.clone("unsupported character in name")
            job.code = -1
            return
        }
        cmd = strings.concatenate({"git checkout ", quoted}, context.temp_allocator)
    case .Checkout_Remote:
        // "origin/feature" -> local "feature" tracking it.
        local := job.arg
        if slash := strings.index_byte(local, '/'); slash >= 0 {
            local = local[slash + 1:]
        }
        remote_quoted, remote_ok := git_quote_path(job.arg)
        local_quoted, local_ok := git_quote_path(local)
        if !remote_ok || !local_ok {
            job.output = strings.clone("unsupported character in name")
            job.code = -1
            return
        }
        cmd = strings.concatenate({"git checkout -b ", local_quoted, " ", remote_quoted}, context.temp_allocator)
    case .Stash_Save:
        cmd = "git stash push"
        if job.arg != "" {
            quoted, quote_ok := git_quote_path(job.arg)
            if !quote_ok {
                job.output = strings.clone("unsupported character in message")
                job.code = -1
                return
            }
            cmd = strings.concatenate({"git stash push -m ", quoted}, context.temp_allocator)
        }
    case .Stash_Apply, .Stash_Pop, .Stash_Drop:
        quoted, quote_ok := git_quote_path(job.arg)
        if !quote_ok {
            job.output = strings.clone("unsupported stash name")
            job.code = -1
            return
        }
        verb := "git stash apply "
        #partial switch job.op {
        case .Stash_Pop:  verb = "git stash pop "
        case .Stash_Drop: verb = "git stash drop "
        }
        cmd = strings.concatenate({verb, quoted}, context.temp_allocator)
    case .Fetch:
        cmd = "git fetch --all --prune"
        timeout = GIT_NETWORK_TIMEOUT
    case .Pull:
        cmd = "git pull --ff-only"
        timeout = GIT_NETWORK_TIMEOUT
    case .Push:
        cmd = "git push"
        timeout = GIT_NETWORK_TIMEOUT
    case .Config_Set:
        key_quoted, key_ok := git_quote_path(job.arg)
        value_quoted, value_ok := git_quote_path(job.arg2)
        if !key_ok || !value_ok {
            job.output = strings.clone("unsupported character in the value")
            job.code = -1
            return
        }
        scope := job.flag ? "--global " : ""
        cmd = strings.concatenate({"git config ", scope, key_quoted, " ", value_quoted}, context.temp_allocator)
    case .Remote_Url:
        cmd = "git remote get-url origin"
    case .PR_List:
        cmd = job.flag ? "glab mr list --output json" : "gh pr list --json number,title,headRefName,url --limit 50"
        timeout = GIT_NETWORK_TIMEOUT
    case .PR_Create:
        if job.flag {
            cmd = "glab mr create --fill --yes"
        } else {
            quoted, quote_ok := git_quote_path(job.arg)
            if !quote_ok {
                job.output = strings.clone("unsupported character in branch")
                job.code = -1
                return
            }
            cmd = strings.concatenate({"gh pr create --fill --head ", quoted}, context.temp_allocator)
        }
        timeout = GIT_NETWORK_TIMEOUT
    case .Clone:
        url_quoted, url_ok := git_quote_path(job.arg)
        dir_quoted, dir_ok := git_quote_path(job.arg2)
        if !url_ok || !dir_ok {
            job.output = strings.clone("unsupported character in the URL or path")
            job.code = -1
            return
        }
        cmd = strings.concatenate({"git clone ", url_quoted, " ", dir_quoted}, context.temp_allocator)
        timeout = GIT_CLONE_TIMEOUT
    case .Lfs_Pull:
        cmd = "git lfs pull"
        timeout = GIT_NETWORK_TIMEOUT
    case .Lfs_Track:
        quoted, quote_ok := git_quote_path(job.arg)
        if !quote_ok {
            job.output = strings.clone("unsupported character in pattern")
            job.code = -1
            return
        }
        cmd = strings.concatenate({"git lfs track ", quoted}, context.temp_allocator)
    case .Snapshot, .Diff_File, .Commit, .Refs, .Config_List, .CLI_Probe, .Lfs_Probe:
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
            thor_git_push_diff(thor, job)
        }
    case .Log:
        if !stale {
            thor_git_push_log(thor, job)
        }
    case .Commit_Show:
        if !stale && job.serial == thor.git_diff_serial {
            thor_git_push_diff(thor, job)
        }
    case .Refs:
        if !stale {
            thor_git_push_refs(thor, job)
        }
    case .Config_List:
        if !stale {
            thor_git_push_config(thor, job)
        }
    case .Remote_Url:
        if !stale {
            thor_git_apply_remote_url(thor, job)
        }
    case .CLI_Probe:
        thor_git_apply_cli_probe(thor, job)
    case .Lfs_Probe:
        if !stale {
            thor_git_apply_lfs_probe(thor, job)
        }
    case .PR_List:
        if !stale {
            thor_git_push_prs(thor, job)
        }
    case .Stage, .Unstage, .Stage_All, .Unstage_All, .Discard, .Commit, .Fetch, .Pull, .Push,
         .Checkout, .Checkout_Remote, .Stash_Save, .Stash_Apply, .Stash_Pop, .Stash_Drop,
         .Config_Set, .PR_Create, .Clone, .Lfs_Pull, .Lfs_Track:
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
    for out in job.aux {
        delete(out)
    }
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

    thor_git_push_snapshot(thor, job)
}

@(private = "file")
thor_git_apply_mutation :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    thor_git_finish_mutation(thor, job)
    if (!job.ok || job.code != 0) && !widgets.git_view_is_open(thor.git_view) {
        line := git_first_line(job.output)
        if line == "" {
            line = "git command failed"
        }
        thor_flash_status(thor, line, is_error = true)
    }
}

// Display branch for a snapshot: the branch name, "detached @ <hash>" on a
// detached HEAD, "" when the branch could not be read (unborn repo).
git_snapshot_branch :: proc(job: ^Git_Op_Job, allocator := context.temp_allocator) -> string {
    if job.aux_codes[0] != 0 {
        return ""
    }
    branch := strings.trim_space(job.aux[0])
    if branch == "HEAD" {
        hash := strings.trim_space(job.aux[1])
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

// Parses a unified diff into display rows (the git view's own row type),
// running the old/new line counters through each hunk. File headers are
// dropped; binary and missing-newline markers become Meta rows.
git_parse_diff_rows :: proc(output: string, out: ^[dynamic]widgets.Git_Diff_Row) {
    old_line, new_line := 0, 0
    in_hunk := false

    it := output
    for raw in strings.split_lines_iterator(&it) {
        line := strings.trim_suffix(raw, "\r")

        if len(out) >= GIT_DIFF_MAX_ROWS {
            append(out, widgets.Git_Diff_Row{.Meta, 0, 0, strings.clone("diff truncated")})
            return
        }

        if strings.has_prefix(line, "@@") {
            old_start, new_start, header_ok := git_parse_hunk_starts(line)
            if !header_ok {
                continue
            }
            old_line, new_line = old_start, new_start
            in_hunk = true
            append(out, widgets.Git_Diff_Row{.Hunk, 0, 0, git_diff_text(line)})
            continue
        }
        if strings.has_prefix(line, "Binary files ") {
            append(out, widgets.Git_Diff_Row{.Meta, 0, 0, git_diff_text(line)})
            continue
        }
        if strings.has_prefix(line, "\\ ") {
            append(out, widgets.Git_Diff_Row{.Meta, 0, 0, git_diff_text(line[2:])})
            continue
        }
        if !in_hunk {
            continue
        }

        switch {
        case strings.has_prefix(line, "+"):
            append(out, widgets.Git_Diff_Row{.Added, 0, new_line, git_diff_text(line[1:])})
            new_line += 1
        case strings.has_prefix(line, "-"):
            append(out, widgets.Git_Diff_Row{.Removed, old_line, 0, git_diff_text(line[1:])})
            old_line += 1
        case strings.has_prefix(line, " "):
            append(out, widgets.Git_Diff_Row{.Context, old_line, new_line, git_diff_text(line[1:])})
            old_line += 1
            new_line += 1
        case line == "":
            // An empty context line loses its leading space to trailing-space
            // stripping in transit; it still counts on both sides.
            append(out, widgets.Git_Diff_Row{.Context, old_line, new_line, strings.clone("")})
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

// One record of the Log format. All owned.
Git_Log_Entry :: struct {
    hash:    string,
    short:   string,
    author:  string,
    date:    string,
    refs:    string,  // decorations ("HEAD -> master, origin/master"), "" for none
    subject: string,
}

// Splits the %x1e-terminated, %x1f-separated log records. The separators are
// control characters no subject can carry, so a multi-line or odd subject
// cannot break a record.
git_parse_log :: proc(output: string, out: ^[dynamic]Git_Log_Entry) {
    rest := output
    for {
        end := strings.index_byte(rest, 0x1e)
        if end < 0 {
            break
        }
        record := strings.trim_space(rest[:end])
        rest = rest[end + 1:]
        parts := strings.split(record, "\x1f", context.temp_allocator)
        if len(parts) != 6 {
            continue
        }
        append(out, Git_Log_Entry {
            hash = strings.clone(parts[0]),
            short = strings.clone(parts[1]),
            author = strings.clone(parts[2]),
            date = strings.clone(parts[3]),
            refs = strings.clone(strings.trim_space(parts[4])),
            subject = strings.clone(parts[5]),
        })
    }
}

git_log_entries_destroy :: proc(entries: ^[dynamic]Git_Log_Entry) {
    for entry in entries {
        delete(entry.hash)
        delete(entry.short)
        delete(entry.author)
        delete(entry.date)
        delete(entry.refs)
        delete(entry.subject)
    }
    delete(entries^)
}

// "name<TAB>*" lines from `git branch --format=%(refname:short)%09%(HEAD)`.
// Cloned names appended to `out`; the current branch's name lands in
// `current`, borrowed from `out`.
git_parse_branch_lines :: proc(output: string, out: ^[dynamic]string) -> (current: string) {
    it := output
    for line in strings.split_lines_iterator(&it) {
        trimmed := strings.trim_right_space(line)
        if trimmed == "" {
            continue
        }
        name := trimmed
        is_current := false
        if tab := strings.index_byte(trimmed, '\t'); tab >= 0 {
            is_current = strings.trim_space(trimmed[tab + 1:]) == "*"
            name = trimmed[:tab]
        }
        if name == "" {
            continue
        }
        append(out, strings.clone(name))
        if is_current {
            current = out[len(out) - 1]
        }
    }
    return
}

// Plain one-name-per-line output (tags, remote branches). Skips the symbolic
// "origin/HEAD" entry a remote listing carries.
git_parse_name_lines :: proc(output: string, out: ^[dynamic]string) {
    it := output
    for line in strings.split_lines_iterator(&it) {
        name := strings.trim_space(line)
        if name == "" || strings.has_suffix(name, "/HEAD") {
            continue
        }
        append(out, strings.clone(name))
    }
}

// One "key\nvalue" entry of `git config --list -z`. Both owned.
Git_Config_Entry :: struct {
    key:   string,
    value: string,
}

// NUL-terminated entries; the first newline splits key from value, and a
// value can carry newlines of its own.
git_parse_config_z :: proc(output: string, out: ^[dynamic]Git_Config_Entry) {
    rest := output
    for len(rest) > 0 {
        nul := strings.index_byte(rest, 0)
        entry := nul >= 0 ? rest[:nul] : rest
        rest = nul >= 0 ? rest[nul + 1:] : ""
        if strings.trim_space(entry) == "" {
            continue
        }
        newline := strings.index_byte(entry, '\n')
        if newline < 0 {
            append(out, Git_Config_Entry{strings.clone(strings.trim_space(entry)), strings.clone("")})
            continue
        }
        append(out, Git_Config_Entry{
            strings.clone(strings.trim_space(entry[:newline])),
            strings.clone(entry[newline + 1:]),
        })
    }
}

git_config_entries_destroy :: proc(entries: ^[dynamic]Git_Config_Entry) {
    for entry in entries {
        delete(entry.key)
        delete(entry.value)
    }
    delete(entries^)
}

// "stash@{N}<TAB>subject" lines from `git stash list --format=%gd%x09%gs`.
git_parse_stash_lines :: proc(output: string, ids, subjects: ^[dynamic]string) {
    it := output
    for line in strings.split_lines_iterator(&it) {
        trimmed := strings.trim_space(line)
        tab := strings.index_byte(trimmed, '\t')
        if tab <= 0 {
            continue
        }
        append(ids, strings.clone(trimmed[:tab]))
        append(subjects, strings.clone(strings.trim_space(trimmed[tab + 1:])))
    }
}

GIT_LFS_POINTER_PREFIX :: "version https://git-lfs.github.com/spec/"

// "    *.png (.gitattributes)" lines from `git lfs track`; the header line
// carries no indent and is dropped.
git_parse_lfs_patterns :: proc(output: string, out: ^[dynamic]string) {
    it := output
    for line in strings.split_lines_iterator(&it) {
        if len(line) == 0 || (line[0] != ' ' && line[0] != '\t') {
            continue
        }
        pattern := strings.trim_space(line)
        if open := strings.last_index(pattern, " ("); open > 0 && strings.has_suffix(pattern, ")") {
            pattern = strings.trim_right_space(pattern[:open])
        }
        if pattern != "" {
            append(out, strings.clone(pattern))
        }
    }
}

// True when every added or removed line of a unified diff is a Git LFS
// pointer field, with a pointer version line among them.
git_diff_is_lfs_pointer :: proc(output: string) -> bool {
    saw_version := false
    saw_change := false
    it := output
    for raw in strings.split_lines_iterator(&it) {
        line := strings.trim_suffix(raw, "\r")
        if len(line) == 0 || (line[0] != '+' && line[0] != '-') {
            continue
        }
        if strings.has_prefix(line, "+++") || strings.has_prefix(line, "---") {
            continue
        }
        body := strings.trim_space(line[1:])
        saw_change = true
        if strings.has_prefix(body, GIT_LFS_POINTER_PREFIX) {
            saw_version = true
            continue
        }
        if body == "" || strings.has_prefix(body, "oid ") || strings.has_prefix(body, "size ") {
            continue
        }
        return false
    }
    return saw_version && saw_change
}

// Collapses an LFS pointer diff into Meta rows naming the objects instead of
// showing the raw pointer text.
git_lfs_pointer_rows :: proc(output: string, out: ^[dynamic]widgets.Git_Diff_Row) {
    new_label := git_lfs_side_label(output, '+')
    old_label := git_lfs_side_label(output, '-')
    if new_label != "" {
        append(out, widgets.Git_Diff_Row{.Meta, 0, 0, strings.concatenate({"LFS object ", new_label})})
    }
    if old_label != "" {
        prefix := new_label == "" ? "LFS object removed: " : "was "
        append(out, widgets.Git_Diff_Row{.Meta, 0, 0, strings.concatenate({prefix, old_label})})
    }
    if len(out) == 0 {
        append(out, widgets.Git_Diff_Row{.Meta, 0, 0, strings.clone("LFS pointer change")})
    }
}

// "sha256:ab12cd34ef56 · 12.3 MB" for one side of a pointer diff, "" when the
// side has no oid.
@(private = "file")
git_lfs_side_label :: proc(output: string, sign: u8, allocator := context.temp_allocator) -> string {
    oid := ""
    size := -1
    it := output
    for raw in strings.split_lines_iterator(&it) {
        line := strings.trim_suffix(raw, "\r")
        if len(line) < 2 || line[0] != sign || line[1] == sign {
            continue
        }
        body := strings.trim_space(line[1:])
        if strings.has_prefix(body, "oid ") {
            oid = strings.trim_space(body[4:])
        } else if strings.has_prefix(body, "size ") {
            size, _ = strconv.parse_int(strings.trim_space(body[5:]))
        }
    }
    if oid == "" {
        return ""
    }
    if colon := strings.index_byte(oid, ':'); colon >= 0 && len(oid) > colon + 13 {
        oid = oid[:colon + 13]
    }
    if size >= 0 {
        return strings.concatenate({oid, " · ", git_size_label(size)}, allocator)
    }
    return strings.clone(oid, allocator)
}

// "12.3 MB" for a byte count.
git_size_label :: proc(bytes: int, allocator := context.temp_allocator) -> string {
    units := [?]string {"KB", "MB", "GB", "TB"}
    value := cast(f64) bytes
    index := -1
    for value >= 1024 && index < len(units) - 1 {
        value /= 1024
        index += 1
    }
    if index < 0 {
        return strings.clone(fmt.tprintf("%d B", bytes), allocator)
    }
    return strings.clone(fmt.tprintf("%.1f %s", value, units[index]), allocator)
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
