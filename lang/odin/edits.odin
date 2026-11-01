// Edits of code actions and refactorings, and the line helpers they share.
package odin

import "core:slice"
import "core:strings"

import lang ".."

// One replacement of [start, end) of the request's buffer.
@(private)
Edit_Spec :: struct {
    start: int,
    end:   int,
    text:  string,
}

// One replacement of [start, end) of `source`, the text of the file at `path`.
@(private)
File_Edit :: struct {
    path:   string,
    source: string,
    start:  int,
    end:    int,
    text:   string,
}

// The caret or selection of a request, widened to whole lines.
@(private)
Caret :: struct {
    offset:     int, // the caret, clamped to the buffer
    sel_end:    int, // the end of the selection; offset when none
    line_start: int,
    line_end:   int, // the newline of the last line, or the end of the buffer
    first:      int, // 1-based line of line_start
    last:       int, // 1-based line of line_end
}

@(private)
request_caret :: proc(rc: ^Request_Context) -> Caret {
    src := rc.req.source
    lo := clamp(rc.req.offset, 0, len(src))
    hi := rc.req.end < 0 ? lo : clamp(rc.req.end, lo, len(src))
    c := Caret{offset = lo, sel_end = hi, line_start = line_start(src, lo), line_end = line_end(src, hi)}
    c.first, _ = offset_line_col(rc.live.lines, c.line_start)
    c.last, _ = offset_line_col(rc.live.lines, c.line_end)
    return c
}

// True when [start, end] touches a line of the caret.
@(private)
caret_hits :: proc(c: Caret, start, end: int) -> bool {
    return start <= c.line_end && end >= c.line_start
}

@(private)
line_start :: proc(src: string, offset: int) -> int {
    return strings.last_index_byte(src[:offset], '\n') + 1
}

@(private)
line_end :: proc(src: string, offset: int) -> int {
    if nl := strings.index_byte(src[offset:], '\n'); nl >= 0 {
        return offset + nl
    }
    return len(src)
}

// The leading spaces and tabs of the line that holds `offset`.
@(private)
line_indent :: proc(src: string, offset: int) -> string {
    ls := line_start(src, offset)
    i := ls
    for i < len(src) && (src[i] == ' ' || src[i] == '\t') {
        i += 1
    }
    return src[ls:i]
}

// One level of indent: the request's, else the smallest indent of the buffer, else a tab.
@(private)
indent_unit :: proc(req: ^lang.Request) -> string {
    if req.tab_size > 0 {
        return "\t" if req.use_tabs else strings.repeat(" ", req.tab_size, context.temp_allocator)
    }
    src := req.source
    least := 0
    for i := 0; i < len(src); {
        if src[i] == '\t' {
            return "\t"
        }
        n := 0
        for i + n < len(src) && src[i + n] == ' ' {
            n += 1
        }
        if n > 0 && i + n < len(src) && src[i + n] != '\n' && (least == 0 || n < least) {
            least = n
        }
        nl := strings.index_byte(src[i:], '\n')
        if nl < 0 {
            break
        }
        i += nl + 1
    }
    if least == 0 {
        return "\t"
    }
    return strings.repeat(" ", least, context.temp_allocator)
}

// Deletes [start, end) with its whole line when nothing else is on the line.
@(private)
line_deletion :: proc(src: string, start, end: int) -> Edit_Spec {
    ls, le := line_start(src, start), line_end(src, end)
    if strings.trim_space(src[ls:start]) != "" || strings.trim_space(src[end:le]) != "" {
        return {start, end, ""}
    }
    return {ls, min(le + 1, len(src)), ""}
}

// Appends a quick fix whose edits replace ranges of the request's buffer.
@(private)
push_action :: proc(res: ^lang.Result, req: ^lang.Request, title: string, specs: ..Edit_Spec) {
    push_kind_action(res, req, "quickfix", title, ..specs)
}

// Appends an action of `kind` whose edits replace ranges of the request's buffer.
@(private)
push_kind_action :: proc(res: ^lang.Result, req: ^lang.Request, kind, title: string, specs: ..Edit_Spec) {
    edits := make([]File_Edit, len(specs), context.temp_allocator)
    for s, i in specs {
        edits[i] = {req.path, req.source, s.start, s.end, s.text}
    }
    push_file_action(res, kind, title, edits)
}

// Appends an action of `kind` with edits of any file. Drops it when it cannot allocate.
@(private)
push_file_action :: proc(res: ^lang.Result, kind, title: string, specs: []File_Edit, ops: []lang.Resource_Op = nil) {
    action, ok := make_action(kind, title, specs, ops)
    if !ok {
        return
    }
    if _, err := append(&res.actions, action); err != nil {
        free_action(action)
    }
}

// An owned action with the edits sorted by path and start.
@(private)
make_action :: proc(kind, title: string, specs: []File_Edit, ops: []lang.Resource_Op = nil) -> (action: lang.Code_Action, ok: bool) {
    sorted := sort_file_edits(specs)
    t, e1 := strings.clone(title)
    k, e2 := strings.clone(kind)
    edits, e3 := make([dynamic]lang.Text_Edit, 0, len(sorted))
    action = lang.Code_Action{title = t, kind = k, edits = edits}
    if e1 != nil || e2 != nil || e3 != nil {
        free_action(action)
        return {}, false
    }
    if !append_edits(&action.edits, sorted) || !append_ops(&action.resource_ops, ops) {
        free_action(action)
        return {}, false
    }
    return action, true
}

// A copy of `specs` in the temp allocator, sorted by path and start.
@(private)
sort_file_edits :: proc(specs: []File_Edit) -> []File_Edit {
    sorted := slice.clone(specs, context.temp_allocator)
    slice.sort_by(sorted, proc(a, b: File_Edit) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.start < b.start
    })
    return sorted
}

// Appends owned copies of `specs` to `out`.
@(private)
append_edits :: proc(out: ^[dynamic]lang.Text_Edit, specs: []File_Edit) -> bool {
    for s in specs {
        path, p1 := strings.clone(s.path)
        old, p2 := strings.clone(s.source[s.start:s.end])
        text, p3 := strings.clone(s.text)
        edit := lang.Text_Edit{path = path, start = s.start, end = s.end, old_text = old, new_text = text}
        if p1 != nil || p2 != nil || p3 != nil {
            free_edit(edit)
            return false
        }
        if _, err := append(out, edit); err != nil {
            free_edit(edit)
            return false
        }
    }
    return true
}

// Appends owned copies of `ops` to `out`.
@(private)
append_ops :: proc(out: ^[dynamic]lang.Resource_Op, ops: []lang.Resource_Op) -> bool {
    for op in ops {
        path, p1 := strings.clone(op.path)
        new_path, p2 := strings.clone(op.new_path)
        o := op
        o.path, o.new_path = path, new_path
        if p1 != nil || p2 != nil {
            delete(path)
            delete(new_path)
            return false
        }
        if _, err := append(out, o); err != nil {
            delete(path)
            delete(new_path)
            return false
        }
    }
    return true
}

@(private)
free_action :: proc(action: lang.Code_Action) {
    for edit in action.edits {
        free_edit(edit)
    }
    delete(action.edits)
    for op in action.resource_ops {
        delete(op.path)
        delete(op.new_path)
    }
    delete(action.resource_ops)
    delete(action.title)
    delete(action.kind)
    delete(action.command)
    delete(action.arguments)
    delete(action.prompt)
    delete(action.prompt_default)
}

@(private)
free_edit :: proc(edit: lang.Text_Edit) {
    delete(edit.path)
    delete(edit.old_text)
    delete(edit.new_text)
}
