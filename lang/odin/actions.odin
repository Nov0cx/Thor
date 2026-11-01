// Code actions: the quick fixes that fix or suppress a live diagnostic at the caret, and the refactorings.
package odin

import "core:fmt"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Most `import` fixes offered for one unresolved package name.
@(private = "file")
MAX_IMPORT_FIXES :: 4

// Answers the quick fixes for the caret: fixes first, suppressions last.
@(private)
code_actions :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    if req.path == "" {
        return
    }
    rc: Request_Context
    opened := request_open(e, req, &rc)
    defer request_close(&rc)
    if !opened || lang.request_cancelled(req) {
        return
    }
    res.actions = make([dynamic]lang.Code_Action)
    caret := request_caret(&rc)
    if len(rc.parsed.errors) == 0 && rc.live.in_build {
        if m, err := odinsema.scope_map(rc.parsed, context.temp_allocator); err == nil {
            defer odinsema.scope_map_destroy(m, context.temp_allocator)
            whens := make([dynamic]Branch, context.temp_allocator)
            collect_whens(odinsyntax.node_root(rc.parsed.tree), &rc, &whens)
            switch_fixes(&rc, caret, res)
            struct_field_fixes(&rc, caret, res)
            or_return_fixes(&rc, caret, res)
            create_decl_fixes(&rc, caret, res)
            refactor_actions(&rc, m, caret, res)
            unused_variable_fixes(&rc, m, caret, res)
            unused_import_fixes(&rc, m, whens[:], caret, res)
        }
    }
    if !lang.request_cancelled(req) {
        import_fixes(&rc, caret, res)
    }
    if !lang.request_cancelled(req) {
        ignore_fixes(&rc, caret, res)
    }
    res.ok = len(res.actions) > 0
}

// The missing cases of the innermost switch around the caret that leaves some out, and `#partial`.
@(private = "file")
switch_fixes :: proc(rc: ^Request_Context, caret: Caret, res: ^lang.Result) {
    c := request_checker(rc)
    if c == nil {
        return
    }
    tok, ok := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(caret.offset), context.temp_allocator)
    if !ok {
        return
    }
    for n := tok.parent; n != nil; n = n.parent {
        if n.green.kind != .Switch_Stmt && n.green.kind != .Type_Switch_Stmt {
            continue
        }
        missing := odinsema.switch_missing(c, rc.live.id, n^, context.temp_allocator)
        if len(missing) > 0 {
            fill_switch(rc, n^, missing, res)
            return
        }
    }
}

@(private = "file")
fill_switch :: proc(rc: ^Request_Context, sw: odinsyntax.Syntax_Node, missing: []string, res: ^lang.Result) {
    src := rc.req.source
    sw := sw
    is_enum := sw.green.kind == .Switch_Stmt
    body: odinsyntax.Block
    has_body: bool
    if is_enum {
        s, _ := odinsyntax.as_switch_stmt(sw)
        body, has_body = odinsyntax.switch_stmt_body(&s)
    } else {
        s, _ := odinsyntax.as_type_switch_stmt(sw)
        body, has_body = odinsyntax.type_switch_stmt_body(&s)
    }
    if !has_body {
        return
    }
    block := odinsyntax.Syntax_Node(body)
    close, has_close := odinsyntax.find_child_token(&block, {tokens = {.Close_Brace}, last = true})
    if !has_close {
        return
    }
    indent := line_indent(src, int(sw.offset))
    if first, has_case := odinsyntax.find_child_node(&block, {kinds = {.Case_Clause}}); has_case {
        indent = line_indent(src, int(first.offset))
    }
    sb := strings.builder_make(context.temp_allocator)
    for name in missing {
        fmt.sbprintf(&sb, "%scase %s%s:\n", indent, "." if is_enum else "", name)
    }
    at := int(close.offset)
    text := strings.to_string(sb)
    if ls := line_start(src, at); strings.trim_space(src[ls:at]) == "" {
        at = ls
    } else {
        text = fmt.tprintf("\n%s%s", text, line_indent(src, int(sw.offset)))
    }
    title := fmt.tprintf("Add missing case: %s", missing[0]) if len(missing) == 1 else fmt.tprintf("Add %d missing cases", len(missing))
    push_action(res, rc.req, title, Edit_Spec{at, at, text})
    if kw, ok := odinsyntax.find_child_token(&sw, {tokens = {.Switch}}); ok {
        push_action(res, rc.req, "Add #partial", Edit_Spec{int(kw.offset), int(kw.offset), "#partial "})
    }
}

// The fix of each variable on the caret's lines that `-vet-unused-variables` reports.
@(private = "file")
unused_variable_fixes :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, caret: Caret, res: ^lang.Result) {
    if .Unused_Variables not_in live_vet_flags(rc) {
        return
    }
    c := request_checker(rc)
    if c == nil {
        return
    }
    root := odinsyntax.node_root(rc.parsed.tree)
    tok, ok := odinsyntax.node_token_at(root, u32(caret.offset), context.temp_allocator)
    if !ok {
        return
    }
    seen := make([dynamic]int, context.temp_allocator)
    for n := tok.parent; n != nil; n = n.parent {
        if n.green.kind != .Proc_Lit {
            continue
        }
        r, err := odinsema.liveness(c, rc.live.id, m, n^, context.temp_allocator)
        if err != nil {
            return
        }
        for u in r.unused {
            if caret_hits(caret, u.offset, u.offset + len(u.name)) && !slice.contains(seen[:], u.offset) {
                append(&seen, u.offset)
                unused_variable_fix(rc, root, u, res)
            }
        }
    }
}

// Renames the variable to `_` while its declaration keeps another name, else makes the
// declaration an assignment to `_`, or removes it when it has no value.
@(private = "file")
unused_variable_fix :: proc(rc: ^Request_Context, root: odinsyntax.Syntax_Node, u: odinsema.Live_Name, res: ^lang.Result) {
    rename := Edit_Spec{u.offset, u.offset + len(u.name), "_"}
    rename_title := fmt.tprintf("Rename '%s' to '_'", u.name)
    tok, ok := odinsyntax.node_token_at(root, u32(u.offset), context.temp_allocator)
    if !ok || tok.parent == nil || tok.parent.parent == nil {
        return
    }
    list := tok.parent.parent
    decl := list.parent
    if list.green.kind != .Name_List || decl == nil || decl.green.kind != .Value_Decl {
        push_action(res, rc.req, rename_title, rename)
        return
    }
    names := 0
    others := 0
    nl := odinsyntax.Name_List(list^)
    it := odinsyntax.name_list_names(&nl)
    for name in odinsyntax.child_iter_next(&it) {
        names += 1
        if int(name.offset) != u.offset && odinsyntax.node_text(name) != "_" {
            others += 1
        }
    }
    if others > 0 {
        push_action(res, rc.req, rename_title, rename)
        return
    }
    v, _ := odinsyntax.as_value_decl(decl^)
    if values, has_values := odinsyntax.value_decl_values(&v); has_values {
        blanks := make([]string, names, context.temp_allocator)
        slice.fill(blanks, "_")
        head := strings.concatenate({strings.join(blanks, ", ", context.temp_allocator), " = "}, context.temp_allocator)
        push_action(res, rc.req, fmt.tprintf("Assign the value of '%s' to '_'", u.name), Edit_Spec{int(decl.offset), int(values.offset), head})
        return
    }
    start, end := odinsyntax.node_range(decl^)
    push_action(res, rc.req, fmt.tprintf("Remove '%s'", u.name), line_deletion(rc.req.source, int(start), int(end)))
}

// Removes the unused import on the caret's lines, and every unused import of the buffer.
@(private = "file")
unused_import_fixes :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, whens: []Branch, caret: Caret, res: ^lang.Result) {
    if .Unused_Imports not_in live_vet_flags(rc) {
        return
    }
    imports := odinsema.db_imports(&rc.snap, rc.live.id)
    unused, err := odinsema.vet_unused_imports(rc.live.tree, imports, m, branch_spans(whens, false), context.temp_allocator)
    if err != nil || len(unused) == 0 {
        return
    }
    src := rc.req.source
    specs := make([dynamic]Edit_Spec, 0, len(unused), context.temp_allocator)
    hit := false
    for i in unused {
        imp := imports[i]
        if imp.item < 0 || imp.item >= len(rc.live.tree.items) {
            continue
        }
        item := rc.live.tree.items[imp.item]
        spec := line_deletion(src, item.start, item.end)
        append(&specs, spec)
        if !hit && caret_hits(caret, item.start, item.end) {
            hit = true
            push_action(res, rc.req, fmt.tprintf("Remove unused import '%s'", imp.alias), spec)
        }
    }
    if len(specs) > 1 || (len(specs) == 1 && !hit) {
        title := "Remove 1 unused import" if len(specs) == 1 else fmt.tprintf("Remove %d unused imports", len(specs))
        push_action(res, rc.req, title, ..specs[:])
    }
}

// Offers the imports that bind the unresolved package qualifier under the caret.
@(private = "file")
import_fixes :: proc(rc: ^Request_Context, caret: Caret, res: ^lang.Result) {
    src := rc.req.source
    start, end := caret.offset, caret.offset
    for start > 0 && is_word_byte(src[start - 1]) {
        start -= 1
    }
    for end < len(src) && is_word_byte(src[end]) {
        end += 1
    }
    if start == end || end >= len(src) || src[end] != '.' || !odinsema.is_identifier(src[start:end]) {
        return
    }
    tokens, ok := semantic_classify(rc, start, end, strict = true)
    if !ok {
        return
    }
    unresolved := false
    for t in tokens {
        if t.start == start && t.kind == .Unresolved {
            unresolved = true
        }
    }
    if !unresolved {
        return
    }
    name := src[start:end]
    imports := odinsema.db_imports(&rc.snap, rc.live.id)
    count := 0
    next: for p in known_packages(rc.e, rc.req.workspace) {
        if p.name != name {
            continue
        }
        for imp in imports {
            if imp.dir != "" && same_dir(imp.dir, p.dir) {
                continue next
            }
        }
        at, text := import_insert(rc, p.import_path)
        push_action(res, rc.req, fmt.tprintf("Import \"%s\"", p.import_path), Edit_Spec{at, at, text})
        count += 1
        if count >= MAX_IMPORT_FIXES {
            return
        }
    }
}

// Offers a `thor:ignore` comment for each diagnostic id on the caret's lines, for the line and for
// the file.
@(private = "file")
ignore_fixes :: proc(rc: ^Request_Context, caret: Caret, res: ^lang.Result) {
    report: lang.Diagnostic_Report
    done := live_report(rc, &report)
    defer {
        for d in report.items {
            delete(d.path)
            delete(d.message)
        }
        delete(report.items)
    }
    if !done {
        return
    }
    codes := make([dynamic]string, context.temp_allocator)
    lines := make([dynamic]int, context.temp_allocator)
    for d in report.items {
        if d.code == "" || d.line < caret.first || d.line > caret.last || slice.contains(codes[:], d.code) {
            continue
        }
        append(&codes, d.code)
        append(&lines, d.line)
    }
    for code, i in codes {
        push_action(res, rc.req, fmt.tprintf("Ignore %s on this line", code), ignore_line_edit(rc, lines[i], code))
        push_action(res, rc.req, fmt.tprintf("Ignore %s in this file", code), ignore_file_edit(rc, code))
    }
}

// Adds `code` to a `thor:ignore` comment on the line above `line`, or puts one there.
@(private = "file")
ignore_line_edit :: proc(rc: ^Request_Context, line: int, code: string) -> Edit_Spec {
    src := rc.req.source
    ls := rc.live.lines[clamp(line - 1, 0, len(rc.live.lines) - 1)]
    if ls > 0 {
        prev := src[line_start(src, ls - 1):ls - 1]
        if ignore_comment(prev, "thor:ignore") {
            at := ls - 1 - (len(prev) - len(strings.trim_right_space(prev)))
            return {at, at, fmt.tprintf(" %s", code)}
        }
    }
    return {ls, ls, fmt.tprintf("%s// thor:ignore %s\n", line_indent(src, ls), code)}
}

// Adds `code` to a `thor:ignore-file` comment on the line after the package clause, or puts one there.
@(private = "file")
ignore_file_edit :: proc(rc: ^Request_Context, code: string) -> Edit_Spec {
    src := rc.req.source
    p := rc.live.tree.package_offset
    if p < 0 {
        return {0, 0, fmt.tprintf("// thor:ignore-file %s\n", code)}
    }
    pe := line_end(src, min(p, len(src)))
    if pe == len(src) {
        return {pe, pe, fmt.tprintf("\n// thor:ignore-file %s", code)}
    }
    next := src[pe + 1:line_end(src, pe + 1)]
    if ignore_comment(next, "thor:ignore-file") {
        at := pe + 1 + len(strings.trim_right_space(next))
        return {at, at, fmt.tprintf(" %s", code)}
    }
    return {pe + 1, pe + 1, fmt.tprintf("// thor:ignore-file %s\n", code)}
}

// True when `line` holds only a `//` comment whose text starts with the word `word`.
@(private = "file")
ignore_comment :: proc(line, word: string) -> bool {
    text := strings.trim_space(line)
    if !strings.has_prefix(text, "//") {
        return false
    }
    body := strings.trim_left_space(text[2:])
    return strings.has_prefix(body, word) && (len(body) == len(word) || body[len(word)] == ' ' || body[len(word)] == '\t')
}
