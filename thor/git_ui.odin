package thor

import "core:fmt"
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
    thor_cmd_open_git_kind(data, .Changes)
}

thor_cmd_open_git_history :: proc(data: rawptr) {
    thor_cmd_open_git_kind(data, .History)
}

thor_cmd_open_git_branches :: proc(data: rawptr) {
    thor_cmd_open_git_kind(data, .Branches)
}

@(private = "file")
thor_cmd_open_git_kind :: proc(data: rawptr, kind: widgets.Git_View_Kind) {
    thor := cast(^Thor) data
    if thor.git_prefix == "" {
        thor_flash_status(thor, "Not a git repository", is_error = true)
        return
    }
    thor_open_git_view(thor, kind)
}

// The history page size, and how much "Load more" adds.
GIT_LOG_PAGE :: 200

thor_open_git_view :: proc(thor: ^Thor, kind: widgets.Git_View_Kind) {
    thor.git_log_count = GIT_LOG_PAGE
    widgets.git_view_open(thor.git_view, &thor.ui_context, kind)
    thor_git_op(thor, .Snapshot)
    thor_git_populate_view(thor, kind)
}

// Fetches what a view shows; called on open and on a sidebar switch. Cheap to
// repeat — every fetch is one async job.
@(private = "file")
thor_git_populate_view :: proc(thor: ^Thor, kind: widgets.Git_View_Kind) {
    #partial switch kind {
    case .History:
        thor_git_request_log(thor)
    case .Branches:
        thor_git_op(thor, .Refs)
    }
}

@(private = "file")
thor_git_request_log :: proc(thor: ^Thor) {
    count := fmt.tprintf("%d", thor.git_log_count)
    thor_git_op(thor, .Log, count)
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
    thor := cast(^Thor) data
    thor_git_populate_view(thor, kind)
}

thor_on_git_select_commit :: proc(data: rawptr, hash: string) {
    thor := cast(^Thor) data
    thor.git_diff_serial += 1 // handled inside thor_git_op, but a Commit_Show may race a Diff_File
    thor_git_op(thor, .Commit_Show, hash)
}

thor_on_git_load_more :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor.git_log_count += GIT_LOG_PAGE
    thor_git_request_log(thor)
}

thor_on_git_checkout :: proc(data: rawptr, kind: widgets.Git_Ref_Kind, name: string) {
    thor := cast(^Thor) data
    // A dirty-tree checkout is left to git: it refuses rather than losing
    // work, and the refusal lands in the status line.
    op := kind == .Remote ? Git_Op.Checkout_Remote : Git_Op.Checkout
    thor_git_start_mutation(thor, op, name)
}

thor_on_git_stash :: proc(data: rawptr, op: widgets.Git_Stash_Op, name: string) {
    thor := cast(^Thor) data
    git_op: Git_Op
    switch op {
    case .Save:  git_op = .Stash_Save
    case .Apply: git_op = .Stash_Apply
    case .Pop:   git_op = .Stash_Pop
    case .Drop:  git_op = .Stash_Drop
    }
    thor_git_start_mutation(thor, git_op, name)
}

// Discard is the one destructive action, so it goes through the palette's
// yes/no confirm; the path and prompt live on Thor until the answer.
thor_on_git_discard :: proc(data: rawptr, path: string) {
    thor := cast(^Thor) data
    delete(thor.git_discard_path)
    thor.git_discard_path = strings.clone(path)
    delete(thor.git_discard_prompt)
    thor.git_discard_prompt = strings.clone(fmt.tprintf("Discard changes in %s?", path))
    widgets.command_palette_confirm(
        thor.command_palette, &thor.ui_context, thor.git_discard_prompt, thor_git_discard_confirmed, thor,
    )
}

@(private = "file")
thor_git_discard_confirmed :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.git_discard_path == "" {
        return
    }
    // Untracked files have nothing in the index to check out; discarding one
    // deletes it.
    abs := git_path(thor, thor.git_discard_path)
    if status, ok := thor.git_status[git_map_key(abs)]; ok && status == .Untracked {
        if remove_err := os.remove(strings.clone(abs, context.temp_allocator)); remove_err != nil {
            widgets.git_view_set_status_line(thor.git_view, "could not delete the file", true)
        }
        thor_refresh_git_status(thor)
        thor_git_op(thor, .Snapshot)
    } else {
        thor_git_start_mutation(thor, .Discard, thor.git_discard_path)
    }
    delete(thor.git_discard_path)
    thor.git_discard_path = ""
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
    // Any new selection supersedes an in-flight diff — also the synchronous
    // untracked preview, which dispatches no job of its own.
    thor.git_diff_serial += 1
    if !staged {
        if status, ok := thor.git_status[git_map_key(git_path(thor, path))]; ok && status == .Untracked {
            thor_git_show_untracked(thor, path)
            return
        }
    }
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
    ahead, behind, upstream_ok := git_parse_upstream_counts(job.aux[2])
    has_upstream := job.aux_codes[2] == 0 && upstream_ok
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

thor_git_push_log :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    view := thor.git_view
    if view == nil || !widgets.git_view_is_open(view) {
        return
    }
    entries := make([dynamic]Git_Log_Entry)
    defer git_log_entries_destroy(&entries)
    git_parse_log(job.output, &entries)

    widgets.git_view_clear_commits(view)
    for entry in entries {
        widgets.git_view_add_commit(view, entry.hash, entry.short, entry.subject, entry.author, entry.date, entry.refs)
    }
    // A full page means the history probably goes on.
    widgets.git_view_set_commits_has_more(view, len(entries) >= thor.git_log_count)
}

thor_git_push_refs :: proc(thor: ^Thor, job: ^Git_Op_Job) {
    view := thor.git_view
    if view == nil || !widgets.git_view_is_open(view) {
        return
    }
    widgets.git_view_clear_refs(view)

    locals := make([dynamic]string)
    defer {
        for name in locals {
            delete(name)
        }
        delete(locals)
    }
    current := git_parse_branch_lines(job.output, &locals)
    for name in locals {
        widgets.git_view_add_ref(view, .Branch, name, "", name == current)
    }

    names := make([dynamic]string)
    defer {
        for name in names {
            delete(name)
        }
        delete(names)
    }
    git_parse_name_lines(job.aux[0], &names)
    for name in names {
        widgets.git_view_add_ref(view, .Remote, name, "", false)
    }
    clear_names(&names)
    git_parse_name_lines(job.aux[1], &names)
    for name in names {
        widgets.git_view_add_ref(view, .Tag, name, "", false)
    }

    ids := make([dynamic]string)
    subjects := make([dynamic]string)
    defer {
        for id in ids {
            delete(id)
        }
        delete(ids)
        for subject in subjects {
            delete(subject)
        }
        delete(subjects)
    }
    git_parse_stash_lines(job.aux[2], &ids, &subjects)
    for id, i in ids {
        widgets.git_view_add_ref(view, .Stash, id, subjects[i], false)
    }
}

@(private = "file")
clear_names :: proc(names: ^[dynamic]string) {
    for name in names {
        delete(name)
    }
    clear(names)
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
    case .Discard:               return "Discarded"
    case .Commit:                return "Committed"
    case .Fetch:                 return "Fetched"
    case .Pull:                  return "Pulled"
    case .Push:                  return "Pushed"
    case .Checkout, .Checkout_Remote: return "Checked out"
    case .Stash_Save:            return "Stashed"
    case .Stash_Apply:           return "Stash applied"
    case .Stash_Pop:             return "Stash popped"
    case .Stash_Drop:            return "Stash dropped"
    case .Snapshot, .Diff_File, .Log, .Commit_Show, .Refs:
        return ""
    }
    return ""
}
