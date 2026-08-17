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
import "../textedit"
import "../widgets"

// Async `git status --porcelain`: a worker captures the output, the main thread
// parses it into an absolute-path -> status map. Every ancestor directory of a
// change is marked too, so folders containing changes get tinted.
Git_Status_Job :: struct {
    owner:       ^Thor,
    allocator:   runtime.Allocator,
    worker:      ^thread.Thread,
    diff_cmd:    string, // owned, built on the main thread: the worker never reads open_files
    output:      string, // owned porcelain output, parsed and freed on the main thread
    diff_output: string, // owned `git diff HEAD` output, parsed and freed on the main thread
}

// --unified=0 drops context lines, leaving just the changed ranges the gutter
// needs. Fails harmlessly (empty diff) on a repo with no commits yet.
@(private = "file")
GIT_DIFF_BASE :: "git diff HEAD --unified=0 --no-color"

// A command line longer than this is refused by Windows, so the pathspec is
// dropped rather than the diff.
@(private)
GIT_DIFF_CMD_MAX :: 30000

// Spawns a status refresh unless one is already running or this is not a repo.
// Cheap to call from anything that might change the working tree.
thor_refresh_git_status :: proc(thor: ^Thor) {
    if thor.git_prefix == "" {
        return
    }
    // Coalesce: if one is already running, remember to run again once it lands.
    if thor.git_status_inflight {
        thor.git_status_dirty = true
        return
    }
    thor.git_status_inflight = true
    thor.git_status_at = time.tick_now()

    paths := make([dynamic]string, context.temp_allocator)
    for file in thor.open_files {
        if !file.closed && file.path != "" {
            append(&paths, file.path)
        }
    }

    job := new(Git_Status_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.diff_cmd = git_diff_command(paths[:], context.allocator)

    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, git_status_worker)
}

// The diff command for `paths`. git_apply_diff keeps hunks for open files only,
// so a whole-repo diff is work thrown away — but a file opened after the last
// refresh is outside the pathspec, which is why a landed load refreshes again
// (thor_process_io). Falls back to the whole repo when there is nothing open,
// when a path cannot be quoted, or when the command line grows too long.
git_diff_command :: proc(paths: []string, allocator := context.temp_allocator) -> string {
    if len(paths) == 0 {
        return strings.clone(GIT_DIFF_BASE, allocator)
    }

    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, GIT_DIFF_BASE)
    strings.write_string(&b, " --")
    for path in paths {
        quoted, ok := git_quote_path(path, context.temp_allocator)
        if !ok {
            return strings.clone(GIT_DIFF_BASE, allocator)
        }
        strings.write_byte(&b, ' ')
        strings.write_string(&b, quoted)
        if strings.builder_len(b) > GIT_DIFF_CMD_MAX {
            return strings.clone(GIT_DIFF_BASE, allocator)
        }
    }
    return strings.clone(strings.to_string(b), allocator)
}

@(private = "file")
git_status_worker :: proc(job: ^Git_Status_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    // -z complicates rename parsing; the plain porcelain format is enough for
    // highlighting, and git_unquote_path undoes the quoting -z would have avoided.
    job.output = shell.run("git status --porcelain", job.owner.workspace_dir)
    job.diff_output = shell.run(job.diff_cmd, job.owner.workspace_dir)

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
    git_mark_submodules(thor, &status)

    thor_clear_git_status(thor)
    thor.git_status = status

    diff := make(map[string][dynamic]widgets.Diff_Line_Kind)
    git_parse_diff(thor, job.diff_output, &diff)
    git_apply_diff(thor, &status, &diff)

    delete(job.diff_cmd)
    delete(job.output)
    delete(job.diff_output)
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
    if status, ok := thor.git_status[git_map_key(path)]; ok {
        return status
    }
    return .None
}

// Absolute path for a repo-relative path git printed. Git always prints forward
// slashes; the tree and the open files carry native separators. On scratch.
@(private)
git_path :: proc(thor: ^Thor, rel: string) -> string {
    native, _ := strings.replace_all(rel, "/", filepath.SEPARATOR_STRING, context.temp_allocator)
    return strings.concatenate({thor.git_prefix, native}, context.temp_allocator)
}

// Map key for an absolute path. Windows names one file in more than one case —
// git keeps the spelling its index recorded, the filesystem answers its own — so
// the key folds case there. POSIX keeps the path: case is identity. On scratch.
@(private)
git_map_key :: proc(path: string) -> string {
    when ODIN_OS == .Windows {
        return strings.to_lower(path, context.temp_allocator)
    } else {
        return path
    }
}

// Owned map key for a repo-relative path git printed.
@(private)
git_key :: proc(thor: ^Thor, rel: string) -> string {
    return strings.clone(git_map_key(git_path(thor, rel)))
}

// Decodes git's C-style path quoting. With core.quotePath on (the default) a
// path holding non-ASCII or control bytes is printed wrapped in double quotes,
// its bytes as \nnn octal escapes. An unquoted path comes back untouched. On
// scratch.
@(private = "file")
git_unquote_path :: proc(path: string) -> string {
    if len(path) < 2 || path[0] != '"' || path[len(path) - 1] != '"' {
        return path
    }
    inner := path[1:len(path) - 1]
    b := strings.builder_make(context.temp_allocator)
    for i := 0; i < len(inner); {
        if inner[i] != '\\' || i + 1 >= len(inner) {
            strings.write_byte(&b, inner[i])
            i += 1
            continue
        }
        escape := inner[i + 1]
        switch escape {
        case 'a':
            strings.write_byte(&b, '\a')
            i += 2
        case 'b':
            strings.write_byte(&b, '\b')
            i += 2
        case 'f':
            strings.write_byte(&b, '\f')
            i += 2
        case 'n':
            strings.write_byte(&b, '\n')
            i += 2
        case 'r':
            strings.write_byte(&b, '\r')
            i += 2
        case 't':
            strings.write_byte(&b, '\t')
            i += 2
        case 'v':
            strings.write_byte(&b, '\v')
            i += 2
        case '"', '\\':
            strings.write_byte(&b, escape)
            i += 2
        case '0' ..= '7':
            // Three octal digits are one byte, so a UTF-8 name arrives one
            // escape per byte and reassembles here.
            if i + 3 < len(inner) && git_is_octal(inner[i + 2]) && git_is_octal(inner[i + 3]) {
                value := (int(escape - '0') << 6) | (int(inner[i + 2] - '0') << 3) | int(inner[i + 3] - '0')
                strings.write_byte(&b, u8(value))
                i += 4
            } else {
                strings.write_byte(&b, escape)
                i += 2
            }
        case:
            strings.write_byte(&b, escape)
            i += 2
        }
    }
    return strings.to_string(b)
}

@(private = "file")
git_is_octal :: proc(c: u8) -> bool {
    return c >= '0' && c <= '7'
}

// Parses porcelain lines into absolute-path -> status entries, marking every
// ancestor directory so folders containing changes are tinted.
@(private)
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
        rel = git_unquote_path(strings.trim_space(rel))
        if rel == "" {
            continue
        }

        status := git_status_from_code(line[:2])
        git_put(out, git_key(thor, rel), status)
        git_mark_ancestors(thor, rel, status, out)
    }
}

// Tints each submodule's directory with the Submodule status, reading the paths
// from the repo's .gitmodules. Runs after status parsing so a submodule keeps
// its own colour rather than the generic Modified tint a dirty submodule earns.
@(private = "file")
git_mark_submodules :: proc(thor: ^Thor, out: ^map[string]widgets.Git_Status) {
    data, read_err := os.read_entire_file(git_path(thor, ".gitmodules"), context.temp_allocator)
    if read_err != nil {
        return
    }

    it := string(data)
    for line in strings.split_lines_iterator(&it) {
        trimmed := strings.trim_space(line)
        if !strings.has_prefix(trimmed, "path") {
            continue
        }
        // Line is `path = <relative path>`; take everything past the '='.
        eq := strings.index_byte(trimmed, '=')
        if eq < 0 {
            continue
        }
        rel := strings.trim_space(trimmed[eq + 1:])
        if rel == "" {
            continue
        }
        abs := git_key(thor, rel)
        if _, exists := out[abs]; exists {
            out[abs] = .Submodule
            delete(abs)
        } else {
            out[abs] = .Submodule
        }
    }
}

// Marks each ancestor directory of a repo-relative path (a/b/c -> a/b, a) as
// containing changes. Conflict wins over the generic Modified marker.
@(private)
git_mark_ancestors :: proc(thor: ^Thor, repo_rel: string, status: widgets.Git_Status, out: ^map[string]widgets.Git_Status) {
    agg := status == .Conflict ? widgets.Git_Status.Conflict : widgets.Git_Status.Modified
    rel := repo_rel
    for {
        slash := strings.last_index_byte(rel, '/')
        if slash <= 0 {
            break
        }
        rel = rel[:slash]
        git_put(out, git_key(thor, rel), agg)
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

@(private)
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

@(private)
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

// Parses `git diff HEAD --unified=0` into per-file line-kind arrays, keyed by
// absolute path (owned, native separators) to match Open_File.path. A hunk's
// new-side range marks Added (pure insertion) or Modified (replacement) lines;
// a pure deletion has no line of its own in the new file, so it attaches to the
// line right after the removal (or line 0 if the removal was at the top).
@(private)
git_parse_diff :: proc(thor: ^Thor, output: string, out: ^map[string][dynamic]widgets.Diff_Line_Kind) {
    it := output
    current := "" // absolute path the following hunks belong to; empty = skip

    for line in strings.split_lines_iterator(&it) {
        if strings.has_prefix(line, "+++ ") {
            git_drop_unused_key(out, current)
            rel := line[4:]
            if strings.has_prefix(rel, "b/") {
                current = git_key(thor, rel[2:])
            } else {
                current = "" // "+++ /dev/null": the file was deleted
            }
            continue
        }
        if current == "" || !strings.has_prefix(line, "@@ ") {
            continue
        }

        old_count, new_start, new_count, ok := git_parse_hunk_header(line)
        if !ok {
            continue
        }

        arr, has := out[current]
        if !has {
            arr = make([dynamic]widgets.Diff_Line_Kind)
        }
        switch {
        case new_count == 0:
            idx := new_start > 0 ? new_start - 1 : 0
            git_diff_ensure_len(&arr, idx + 1)
            if arr[idx] == .None {
                arr[idx] = .Deleted
            }
        case old_count == 0:
            git_diff_ensure_len(&arr, new_start + new_count - 1)
            for i in new_start ..= new_start + new_count - 1 {
                arr[i - 1] = .Added
            }
        case:
            git_diff_ensure_len(&arr, new_start + new_count - 1)
            for i in new_start ..= new_start + new_count - 1 {
                arr[i - 1] = .Modified
            }
        }
        out[current] = arr
    }
    git_drop_unused_key(out, current)
}

// Frees a key the map never took: a file with no hunk at all (a mode-only or a
// binary change) leaves one behind, and only the map's own keys are freed later.
@(private = "file")
git_drop_unused_key :: proc(out: ^map[string][dynamic]widgets.Diff_Line_Kind, key: string) {
    if key == "" {
        return
    }
    if _, has := out[key]; !has {
        delete(key)
    }
}

// Grows arr with .None entries until it covers index n-1.
@(private = "file")
git_diff_ensure_len :: proc(arr: ^[dynamic]widgets.Diff_Line_Kind, n: int) {
    for len(arr^) < n {
        append(arr, widgets.Diff_Line_Kind.None)
    }
}

// Parses a "@@ -old_start[,old_count] +new_start[,new_count] @@ ..." header.
@(private = "file")
git_parse_hunk_header :: proc(line: string) -> (old_count, new_start, new_count: int, ok: bool) {
    rest := line[3:] // strip leading "@@ "
    close := strings.index(rest, " @@")
    if close < 0 {
        return
    }
    rest = rest[:close]
    parts := strings.split(rest, " ", context.temp_allocator)
    if len(parts) < 2 || len(parts[0]) < 1 || parts[0][0] != '-' || len(parts[1]) < 1 || parts[1][0] != '+' {
        return
    }
    _, old_count = git_parse_range(parts[0][1:]) or_return
    new_start, new_count = git_parse_range(parts[1][1:]) or_return
    ok = true
    return
}

// Parses "N" or "N,M" (a bare N means count 1, git's convention for a hunk
// touching a single line). Rejects negative values, which the callers index with.
@(private)
git_parse_range :: proc(s: string) -> (start, count: int, ok: bool) {
    if comma := strings.index_byte(s, ','); comma >= 0 {
        start = strconv.parse_int(s[:comma]) or_return
        count = strconv.parse_int(s[comma + 1:]) or_return
    } else {
        start = strconv.parse_int(s) or_return
        count = 1
    }
    ok = start >= 0 && count >= 0
    return
}

// Pushes freshly parsed hunks into every open file's diff_lines (copied, not
// moved, so ownership of `diff`'s arrays stays here) and frees the scratch map.
// A file with no HEAD to diff against (freshly created, still untracked or
// newly staged) reads as fully Added instead.
@(private = "file")
git_apply_diff :: proc(thor: ^Thor, status: ^map[string]widgets.Git_Status, diff: ^map[string][dynamic]widgets.Diff_Line_Kind) {
    for file in thor.open_files {
        clear(&file.diff_lines)
        key := git_map_key(file.path)
        if lines, ok := diff[key]; ok {
            append(&file.diff_lines, ..lines[:])
        } else if s, has := status[key]; has && (s == .Untracked || s == .Added) {
            n := textedit.state_line_count(&file.state)
            for _ in 0 ..< n {
                append(&file.diff_lines, widgets.Diff_Line_Kind.Added)
            }
        }
    }

    for path, lines in diff {
        delete(path)
        delete(lines)
    }
    delete(diff^)
}
