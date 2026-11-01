// Resolve_Action: the edits of a refactoring once the user gave the value it asked for.
package odin

import "core:strings"

import lang ".."
import odinsema "sema"

@(private)
ACTION_EXTRACT_VARIABLE :: "odin.extract_variable"
@(private)
ACTION_EXTRACT_PROCEDURE :: "odin.extract_procedure"
@(private)
ACTION_CHANGE_SIGNATURE :: "odin.change_signature"
@(private)
ACTION_MOVE_DECLARATION :: "odin.move_declaration"

// Appends an action that asks for a value before Resolve_Action computes its edits.
@(private)
push_prompt_action :: proc(res: ^lang.Result, title, command, prompt, default: string) {
    action, ok := make_action("refactor", title, nil)
    if !ok {
        return
    }
    c, e1 := strings.clone(command)
    p, e2 := strings.clone(prompt)
    d, e3 := strings.clone(default)
    action.command, action.prompt, action.prompt_default = c, p, d
    if e1 != nil || e2 != nil || e3 != nil {
        free_action(action)
        return
    }
    if _, err := append(&res.actions, action); err != nil {
        free_action(action)
    }
}

// Answers a Resolve_Action request: the edits of `req.command` with `req.new_name` as the answer.
@(private)
resolve_action :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    if req.path == "" {
        return
    }
    rc: Request_Context
    opened := request_open(e, req, &rc)
    defer request_close(&rc)
    if !opened || lang.request_cancelled(req) {
        return
    }
    if len(rc.parsed.errors) > 0 {
        resolve_fail(res, "the file has syntax errors")
        return
    }
    if !rc.live.in_build {
        resolve_fail(res, "the file is not in the build")
        return
    }
    m, err := odinsema.scope_map(rc.parsed, context.temp_allocator)
    if err != nil {
        resolve_fail(res, "out of memory")
        return
    }
    defer odinsema.scope_map_destroy(m, context.temp_allocator)
    src := req.source
    lo := clamp(req.offset, 0, len(src))
    hi := req.end < 0 ? lo : clamp(req.end, lo, len(src))
    name := strings.trim_space(req.new_name)
    edits: []File_Edit
    ops: []lang.Resource_Op
    reason := "unknown action"
    switch req.command {
    case ACTION_EXTRACT_VARIABLE:
        lo, hi = trimmed_selection(src, lo, hi)
        edits, reason = extract_variable_edits(&rc, m, lo, hi, name)
    case ACTION_EXTRACT_PROCEDURE:
        lo, hi = trimmed_selection(src, lo, hi)
        edits, reason = extract_procedure_edits(&rc, m, lo, hi, name)
    case ACTION_CHANGE_SIGNATURE, ACTION_MOVE_DECLARATION:
        reason = "not available"
    }
    if reason != "" {
        resolve_fail(res, reason)
        return
    }
    resolve_done(res, edits, ops)
}

// Ends a Resolve_Action with no edits and `reason` for the user.
@(private)
resolve_fail :: proc(res: ^lang.Result, reason: string) {
    res.ok = false
    delete(res.message.text)
    res.message.text = strings.clone(reason)
}

// Ends a Resolve_Action with the edits of `specs` and `ops`.
@(private)
resolve_done :: proc(res: ^lang.Result, specs: []File_Edit, ops: []lang.Resource_Op = nil) {
    sorted_edits := make([dynamic]lang.Text_Edit)
    if !append_edits(&sorted_edits, sort_file_edits(specs)) || !append_ops(&res.resource_ops, ops) {
        for edit in sorted_edits {
            free_edit(edit)
        }
        delete(sorted_edits)
        resolve_fail(res, "out of memory")
        return
    }
    res.edits = sorted_edits
    res.ok = true
}
