package thor

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"

import "../widgets"

// Async `git status --porcelain`: a worker captures the output, the main thread
// parses it into an absolute-path -> status map. Every ancestor directory of a
// change is marked too, so folders containing changes get tinted.
Git_Status_Job :: struct {
    owner:     ^Thor,
    allocator: runtime.Allocator,
    worker:    ^thread.Thread,
    output:    string, // owned porcelain output, parsed and freed on the main thread
}

// Spawns a status refresh unless one is already running or this is not a repo.
// Cheap to call from anything that might change the working tree.
thor_refresh_git_status :: proc(thor: ^Thor) {
    if thor.git_branch == "" {
        return
    }
    // Coalesce: if one is already running, remember to run again once it lands.
    if thor.git_status_inflight {
        thor.git_status_dirty = true
        return
    }
    thor.git_status_inflight = true

    job := new(Git_Status_Job)
    job.owner = thor
    job.allocator = context.allocator

    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, git_status_worker)
}

@(private = "file")
git_status_worker :: proc(job: ^Git_Status_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    // -z avoids path quoting but complicates rename parsing; the plain porcelain
    // format is enough for highlighting.
    job.output = run_command("git status --porcelain", job.owner.workspace_dir)

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_git, job)
    sync.unlock(&job.owner.io_mutex)
}

// Drains a finished status job (called from thor_process_io): parses the output
// into a fresh map and swaps it in for the old one.
thor_apply_git_status :: proc(thor: ^Thor, job: ^Git_Status_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)

    status := make(map[string]widgets.Git_Status)
    git_parse_status(thor, job.output, &status)

    thor_clear_git_status(thor)
    thor.git_status = status

    delete(job.output)
    free(job)
    thor.git_status_inflight = false
    thor.inflight_jobs -= 1

    // A refresh landed while this one was running: run once more.
    if thor.git_status_dirty {
        thor.git_status_dirty = false
        thor_refresh_git_status(thor)
    }
}

thor_clear_git_status :: proc(thor: ^Thor) {
    for path in thor.git_status {
        delete(path)
    }
    delete(thor.git_status)
    thor.git_status = nil
}

// Tree_Status_Proc: look up a path's status for highlighting.
thor_tree_git_status :: proc(data: rawptr, path: string, _: bool) -> widgets.Git_Status {
    thor := cast(^Thor) data
    if status, ok := thor.git_status[path]; ok {
        return status
    }
    return .None
}

// Parses porcelain lines into absolute-path -> status entries, marking every
// ancestor directory so folders containing changes are tinted.
@(private = "file")
git_parse_status :: proc(thor: ^Thor, output: string, out: ^map[string]widgets.Git_Status) {
    it := output
    for line in strings.split_lines_iterator(&it) {
        // Format is "XY PATH": two status chars, a space, then the path. Guards
        // below reject git error text (e.g. "fatal: ...") that isn't a status.
        if len(line) < 4 || line[2] != ' ' || !git_valid_code(line[:2]) {
            continue
        }
        rel := line[3:]
        // Renames/copies read "orig -> new"; the new path is what exists on disk.
        if arrow := strings.index(rel, " -> "); arrow >= 0 {
            rel = rel[arrow + 4:]
        }
        rel = strings.trim_space(rel)
        if rel == "" {
            continue
        }

        status := git_status_from_code(line[:2])
        // Git prints forward slashes; the tree keys on native (backslash) paths.
        native, _ := strings.replace_all(rel, "/", "\\", context.temp_allocator)
        git_put(out, strings.concatenate({thor.workspace_prefix, native}), status)
        git_mark_ancestors(thor, native, status, out)
    }
}

// Marks each ancestor directory of native_rel (a\b\c -> a\b, a) as containing
// changes. Conflict wins over the generic Modified marker.
@(private = "file")
git_mark_ancestors :: proc(thor: ^Thor, native_rel: string, status: widgets.Git_Status, out: ^map[string]widgets.Git_Status) {
    agg := status == .Conflict ? widgets.Git_Status.Conflict : widgets.Git_Status.Modified
    rel := native_rel
    for {
        slash := strings.last_index_byte(rel, '\\')
        if slash <= 0 {
            break
        }
        rel = rel[:slash]
        git_put(out, strings.concatenate({thor.workspace_prefix, rel}), agg)
    }
}

// Inserts abs -> status, taking ownership of `abs` as the key. If the key is
// already present, frees the duplicate and only upgrades a marker to Conflict.
@(private = "file")
git_put :: proc(out: ^map[string]widgets.Git_Status, abs: string, status: widgets.Git_Status) {
    if existing, ok := out[abs]; ok {
        if status == .Conflict && existing != .Conflict {
            out[abs] = .Conflict
        }
        delete(abs)
        return
    }
    out[abs] = status
}

@(private = "file")
git_valid_code :: proc(code: string) -> bool {
    for c in transmute([]u8) code {
        switch c {
        case ' ', 'M', 'A', 'D', 'R', 'C', 'U', '?', '!':
        case:
            return false
        }
    }
    return true
}

@(private = "file")
git_status_from_code :: proc(code: string) -> widgets.Git_Status {
    // code is the 2-char XY field: X = staged (index), Y = worktree.
    if code == "??" {
        return .Untracked
    }
    if strings.contains_rune(code, 'U') || code == "AA" || code == "DD" {
        return .Conflict
    }
    x, y := code[0], code[1]
    switch {
    case x == 'D' || y == 'D': return .Deleted
    case x == 'R' || y == 'R': return .Renamed
    case x == 'A' || y == 'A': return .Added
    }
    return .Modified
}
