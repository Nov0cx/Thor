package thor

import "core:os"
import "core:strings"

import "../widgets"

// Wires and drives the git modal (widgets.Git_View). The widget draws the
// lists and the commit box; this file owns the git knowledge: it dispatches
// every command through thor_git_op and routes the results back in.

// Untracked files are shown as an all-added synthesized diff; past this size
// the preview is skipped instead of read whole.
GIT_UNTRACKED_PREVIEW_MAX :: 512 * 1024

thor_cmd_open_git_view :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.git_prefix == "" {
        thor_flash_status(thor, "Not a git repository", is_error = true)
        return
    }
    thor_open_git_view(thor, .Changes)
}

thor_open_git_view :: proc(thor: ^Thor, kind: widgets.Git_View_Kind) {
    widgets.git_view_open(thor.git_view, &thor.ui_context, kind)
    thor_git_op(thor, .Snapshot)
}

// Force-closes the modal and orphans every in-flight op; called on a
// workspace switch, where the data under the modal is gone.
thor_git_view_reset :: proc(thor: ^Thor) {
    thor.git_ui_generation += 1
    thor.git_ui_snapshot_inflight = false
    thor.git_ui_snapshot_dirty = false
    thor.git_mutation_inflight = false
    if thor.git_view != nil && widgets.git_view_is_open(thor.git_view) {
        widgets.git_view_close(thor.git_view, &thor.ui_context)
    }
}

// ---- widget callbacks ----

thor_on_git_view_changed :: proc(data: rawptr, kind: widgets.Git_View_Kind) {
    // Only Changes exists so far; later views populate lazily from here.
    _ = data
    _ = kind
}

thor_on_git_stage :: proc(data: rawptr, path: string, stage: bool) {
    thor := cast(^Thor) data
    op: Git_Op
    if path == "" {
        op = stage ? Git_Op.Stage_All : Git_Op.Unstage_All
    } else {
        op = stage ? Git_Op.Stage : Git_Op.Unstage
    }
    thor_git_start_mutation(thor, op, path)
}

thor_on_git_select_file :: proc(data: rawptr, path: string, staged: bool) {
    thor := cast(^Thor) data
    thor_git_request_diff(thor, path, staged)
}

thor_on_git_commit :: proc(data: rawptr, subject, description: string, amend: bool) {
    thor := cast(^Thor) data
    thor_git_start_mutation(thor, .Commit, subject, description, amend)
}

thor_on_git_sync :: proc(data: rawptr, op: widgets.Git_Sync_Op) {
    thor := cast(^Thor) data
    git_op: Git_Op
    switch op {
    case .Fetch: git_op = .Fetch
    case .Pull:  git_op = .Pull
    case .Push:  git_op = .Push
    }
    thor_git_start_mutation(thor, git_op)
}

@(private = "file")
thor_git_start_mutation :: proc(thor: ^Thor, op: Git_Op, arg := "", arg2 := "", flag := false) {
    if thor.git_mutation_inflight {
        return
    }
    thor_git_op(thor, op, arg, arg2, flag)
    widgets.git_view_set_busy(thor.git_view, true)
    widgets.git_view_set_status_line(thor.git_view, "", false)
}

// Fetches the diff for a selected file: a tracked file asks git, an untracked
// one is read off disk and shown as fully added.
@(private = "file")
thor_git_request_diff :: proc(thor: ^Thor, path: string, staged: bool) {
    if !staged {
        if status, ok := thor.git_status[git_map_key(git_path(thor, path))]; ok && status == .Untracked {
            thor_git_show_untracked(thor, path)
            return
        }
    }
    thor.git_diff_serial += 1 // supersede a pending result even without a new job
    thor_git_op(thor, .Diff_File, path, flag = staged)
}

@(private = "file")
thor_git_show_untracked :: proc(thor: ^Thor, path: string) {
    view := thor.git_view
    abs := git_path(thor, path)
    data, read_err := os.read_entire_file(abs, context.temp_allocator)
    if read_err != nil || len(data) > GIT_UNTRACKED_PREVIEW_MAX {
        widgets.git_view_set_diff(view, path, make([dynamic]widgets.Git_Diff_Row))
        return
    }

    rows := make([dynamic]widgets.Git_Diff_Row)
    line_number := 1
    it := string(data)
    for raw in strings.split_lines_iterator(&it) {
        if len(rows) >= GIT_DIFF_MAX_ROWS {
            append(&rows, widgets.Git_Diff_Row{.Meta, 0, 0, strings.clone("diff truncated")})
            break
        }
        line := strings.trim_suffix(raw, "\r")
        expanded, was_allocation := strings.replace_all(line, "\t", "    ")
        if !was_allocation {
            expanded = strings.clone(line)
        }
        append(&rows, widgets.Git_Diff_Row{.Added, 0, line_number, expanded})
        line_number += 1
    }
    widgets.git_view_set_diff(view, path, rows)
}

// ---- result routing (called from thor_apply_git_op) ----

// Pushes a snapshot into the open view: header, both lists, and a refreshed
// diff for the file that stayed selected.
thor_git_push_snapshot :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    view := thor.git_view
    if view == nil || !widgets.git_view_is_open(view) {
        return
    }

    branch := git_snapshot_branch(job, context.temp_allocator)
    display := branch
    if display == "" {
        display = "(no commits yet)"
    }
    ahead, behind, upstream_ok := git_parse_upstream_counts(job.upstream_output)
    has_upstream := job.upstream_code == 0 && upstream_ok
    widgets.git_view_set_header(view, display, ahead, behind, has_upstream)

    entries := make([dynamic]Git_File_Entry)
    defer git_file_entries_destroy(&entries)
    git_parse_porcelain_z(job.output, &entries)

    widgets.git_view_clear_files(view)
    for entry in entries {
        widgets.git_view_add_file(view, entry.path, entry.path, entry.status, entry.staged)
    }

    if path, staged, ok := widgets.git_view_selected_file(view); ok {
        thor_git_request_diff(thor, path, staged)
    } else {
        widgets.git_view_clear_diff(view)
        widgets.git_view_set_diff(view, "", make([dynamic]widgets.Git_Diff_Row))
    }
}

thor_git_push_diff :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    view := thor.git_view
    if view == nil || !widgets.git_view_is_open(view) {
        return
    }
    rows := make([dynamic]widgets.Git_Diff_Row)
    git_parse_diff_rows(job.output, &rows)
    widgets.git_view_set_diff(view, job.arg, rows)
}

// Ends a mutation on the view: reports the failure or clears the commit box,
// and re-snapshots so the lists match the new state.
thor_git_finish_mutation :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    view := thor.git_view
    if view == nil || !widgets.git_view_is_open(view) {
        return
    }
    widgets.git_view_set_busy(view, false)

    if !job.ok || job.code != 0 {
        line := git_first_line(job.output)
        if line == "" {
            line = "git command failed"
        }
        widgets.git_view_set_status_line(view, line, true)
        return
    }

    if job.op == .Commit {
        widgets.git_view_clear_commit(view)
    }
    widgets.git_view_set_status_line(view, git_op_done_label(job.op), false)
}

@(private = "file")
git_op_done_label :: proc(op: Git_Op) -> string {
    switch op {
    case .Stage, .Stage_All:     return "Staged"
    case .Unstage, .Unstage_All: return "Unstaged"
    case .Commit:                return "Committed"
    case .Fetch:                 return "Fetched"
    case .Pull:                  return "Pulled"
    case .Push:                  return "Pushed"
    case .Snapshot, .Diff_File:  return ""
    }
    return ""
}
