// Live name errors: what the compiler reports about the names of a file that parses clean.
package odin

import "core:fmt"
import "core:slice"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// A byte range of the buffer.
@(private = "file")
Span :: struct {
    start: int,
    end:   int,
}

// Appends the name errors of the request's buffer to `report`.
@(private)
name_diagnostics :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report) {
    first := len(report.items)
    defer slice.sort_by(report.items[first:], proc(a, b: lang.Diagnostic) -> bool {
        return a.line < b.line || (a.line == b.line && a.col < b.col)
    })
    package_redeclarations(rc, report)
    import_redeclarations(rc, report)
    m, err := odinsema.scope_map(rc.parsed, context.temp_allocator)
    if err != nil || lang.request_cancelled(rc.req) {
        return
    }
    defer odinsema.scope_map_destroy(m, context.temp_allocator)
    local_redeclarations(rc, m, report)
    qualified_names(rc, m, report)
    if lang.request_cancelled(rc.req) {
        return
    }
    undeclared_names(rc, report)
}

// Reports each free name that no scope declares.
@(private = "file")
undeclared_names :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report) {
    tokens, ok := semantic_classify(rc, 0, len(rc.req.source))
    if !ok {
        return
    }
    for tok in tokens {
        if tok.kind == .Unresolved {
            report_error(rc, report, tok.start, fmt.aprintf("Undeclared name: %s", rc.req.source[tok.start:tok.end]))
        }
    }
}

// Reports each `alias.name` whose package declares no public `name`.
@(private = "file")
qualified_names :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, report: ^lang.Diagnostic_Report) {
    using_items := make([dynamic]Span, context.temp_allocator)
    if m.has_using {
        using_spans(rc, m, &using_items)
    }
    for ref in m.refs {
        if ref.kind != .Package_Qualified || in_spans(using_items[:], ref.start) {
            continue
        }
        switch qualified_state(rc, ref.operand, ref.name) {
        case .Public:
        case .Private:
            report_error(rc, report, ref.operand_start, fmt.aprintf("'%s' is not exported by '%s'", ref.name, ref.operand))
        case .Missing:
            report_error(rc, report, ref.operand_start, fmt.aprintf("'%s' is not declared by '%s'", ref.name, ref.operand))
        }
    }
}

// What a package gives for `alias.name`.
@(private = "file")
Qualified_State :: enum u8 {
    Public,  // a public item, or nothing the check can prove
    Private, // only `@(private)` items
    Missing, // no item, or only items private to their file
}

@(private = "file")
qualified_state :: proc(rc: ^Request_Context, alias, name: string) -> Qualified_State {
    dir, is_import := import_alias_dir(rc, alias)
    if !is_import || dir == "" {
        return .Public
    }
    view := request_package(rc, dir)
    if view == nil || view.scope == nil || len(view.scope.files) == 0 {
        return .Public
    }
    // Every file of the directory counts, in the build or not: the target may not be the user's.
    state := Qualified_State.Missing
    for file in view.sema_files {
        if file.items == nil {
            return .Public
        }
        for item in file.items.items {
            if item.name != name || item.kind == .Import || item.kind == .Foreign_Import {
                continue
            }
            switch item.visibility {
            case .Public:
                return .Public
            case .Package:
                state = .Private
            case .File:
            }
        }
    }
    return state
}

// Appends the ranges of the file-scope declarations of the buffer that hold a `using`.
@(private = "file")
using_spans :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, out: ^[dynamic]Span) {
    for item in rc.live.tree.items {
        held := false
        for u in m.usings {
            if item.start <= u.start && u.start < item.end {
                held = true
                break
            }
        }
        for l in m.locals {
            if held {
                break
            }
            held = l.is_using && item.start <= l.name_offset && l.name_offset < item.end
        }
        if held {
            append(out, Span{item.start, item.end})
        }
    }
}

@(private = "file")
in_spans :: proc(spans: []Span, offset: int) -> bool {
    for s in spans {
        if s.start <= offset && offset < s.end {
            return true
        }
    }
    return false
}

// Reports each package-scope declaration of the buffer that another one of the package redeclares.
@(private = "file")
package_redeclarations :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report) {
    if !rc.live.in_build {
        return
    }
    view := request_package(rc, live_dir(rc))
    if view == nil || view.scope == nil {
        return
    }
    live := -1
    for id, i in view.files {
        if id == rc.live.id {
            live = i
            break
        }
    }
    if live < 0 {
        return
    }
    offsets := make([dynamic]int, context.temp_allocator)
    for c in view.scope.conflicts {
        clear(&offsets)
        elsewhere := false
        for ref in c.refs {
            if ref.file != live {
                elsewhere = true
                continue
            }
            append(&offsets, odinsema.package_item(view.sema_files, ref).name_offset)
        }
        slice.sort(offsets[:])
        // In one file the compiler names the later declarations; across files, each file names its own.
        first := elsewhere ? 0 : 1
        for offset in offsets[min(first, len(offsets)):] {
            report_error(rc, report, offset, fmt.aprintf("Redeclaration of '%s' in this scope", c.name))
        }
    }
}

// Reports each import of the buffer whose alias an earlier import of the buffer binds.
@(private = "file")
import_redeclarations :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report) {
    imports := odinsema.db_imports(&rc.snap, rc.live.id)
    seen := make(map[string]struct{}, len(imports), context.temp_allocator)
    for imp in imports {
        if imp.is_foreign || !imp.alias_valid || imp.alias == "_" {
            continue
        }
        if imp.alias in seen {
            report_error(rc, report, imp.name_offset, fmt.aprintf("Redeclaration of '%s' in this scope", imp.alias))
            continue
        }
        seen[imp.alias] = {}
    }
}

// A local declaration by scope and name. Labels and other names do not see each other.
@(private = "file")
Local_Key :: struct {
    scope: int,
    name:  string,
    label: bool,
}

// Reports each local that a declaration of the same scope already binds, a local that redeclares
// the variable of its type-switch case, and a local of a body that shadows a named result.
@(private = "file")
local_redeclarations :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, report: ^lang.Diagnostic_Report) {
    if len(m.locals) == 0 {
        return
    }
    whens := make([dynamic]Span, context.temp_allocator)
    collect_when_bodies(odinsyntax.node_root(rc.parsed.tree), &whens)

    // Source order: a hoisted constant is declared ahead of the statements before it.
    locals := m.locals
    order := make([]int, len(locals), context.temp_allocator)
    for i in 0 ..< len(order) {
        order[i] = i
    }
    sort_by_offset(order, locals)

    first := make(map[Local_Key]int, len(locals), context.temp_allocator)
    for index in order {
        l := &locals[index]
        if under_when(m, l, whens[:]) {
            continue
        }
        key := Local_Key{l.scope, l.name, l.kind == .Label}
        if _, found := first[key]; found {
            report_error(rc, report, l.name_offset, fmt.aprintf("Redeclaration of '%s' in this scope", l.name))
            continue
        }
        first[key] = index
        if l.kind == .Label {
            continue
        }
        switch outer_binding(m, first, l) {
        case .None:
        case .Switch_Var:
            report_error(rc, report, l.name_offset, fmt.aprintf("Redeclaration of '%s' in this scope", l.name))
        case .Result:
            report_error(rc, report, l.name_offset, fmt.aprintf("Direct shadowing of the named return value '%s' in this scope", l.name))
        }
    }
}

// What a local redeclares outside its own scope.
@(private = "file")
Outer_Binding :: enum u8 {
    None,
    Switch_Var, // the variable of the type switch whose case clause holds the local
    Result,     // a named result of the procedure whose body block holds the local
}

@(private = "file")
outer_binding :: proc(m: ^odinsema.Scope_Map, first: map[Local_Key]int, l: ^odinsema.Local) -> Outer_Binding {
    scope := m.scopes[l.scope]
    if scope.parent < 0 {
        return .None
    }
    parent := m.scopes[scope.parent]
    if index, ok := first[Local_Key{scope.parent, l.name, false}]; ok && m.locals[index].kind == .Result && parent.proc_depth == scope.proc_depth {
        return .Result
    }
    if parent.parent < 0 {
        return .None
    }
    if index, ok := first[Local_Key{parent.parent, l.name, false}]; ok && m.locals[index].kind == .Switch_Var {
        return .Switch_Var
    }
    return .None
}

// True when the local is declared in a `when` body of its own scope. A `when` body opens no
// scope, and the compiler checks only the branch that holds.
@(private = "file")
under_when :: proc(m: ^odinsema.Scope_Map, l: ^odinsema.Local, whens: []Span) -> bool {
    scope := m.scopes[l.scope]
    for w in whens {
        if w.start <= l.name_offset && l.name_offset < w.end && w.start >= scope.start && w.end <= scope.end {
            return true
        }
    }
    return false
}

// Appends the bodies and `else` branches of every `when` statement under `n`.
@(private = "file")
collect_when_bodies :: proc(n: odinsyntax.Syntax_Node, out: ^[dynamic]Span) {
    n := n
    if n.green.kind == .When_Stmt {
        ws, _ := odinsyntax.as_when_stmt(n)
        if body, ok := odinsyntax.when_stmt_body(&ws); ok {
            start, end := odinsyntax.node_range(odinsyntax.Syntax_Node(body))
            append(out, Span{int(start), int(end)})
        }
        if other, ok := odinsyntax.when_stmt_else_branch(&ws); ok && other.green.kind != .When_Stmt {
            start, end := odinsyntax.node_range(other)
            append(out, Span{int(start), int(end)})
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        collect_when_bodies(child, out)
    }
}

// Sorts local indices by the offset of their names.
@(private = "file")
sort_by_offset :: proc(order: []int, locals: []odinsema.Local) {
    for i in 1 ..< len(order) {
        cur := order[i]
        j := i
        for j > 0 && locals[order[j - 1]].name_offset > locals[cur].name_offset {
            order[j] = order[j - 1]
            j -= 1
        }
        order[j] = cur
    }
}
