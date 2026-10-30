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
    import_problems(rc, report)
    package_redeclarations(rc, report)
    import_redeclarations(rc, report)
    m, err := odinsema.scope_map(rc.parsed, context.temp_allocator)
    if err != nil || lang.request_cancelled(rc.req) {
        return
    }
    defer odinsema.scope_map_destroy(m, context.temp_allocator)
    whens := make([dynamic]Branch, context.temp_allocator)
    collect_whens(odinsyntax.node_root(rc.parsed.tree), rc, &whens)
    local_redeclarations(rc, m, whens[:], report)
    member_redeclarations(rc, m, report)
    qualified_names(rc, m, report)
    if lang.request_cancelled(rc.req) {
        return
    }
    undeclared_names(rc, whens[:], report)
}

// Reports each free name that no scope declares for the target, outside `when` branches the
// target may not take.
@(private = "file")
undeclared_names :: proc(rc: ^Request_Context, whens: []Branch, report: ^lang.Diagnostic_Report) {
    tokens, ok := semantic_classify(rc, 0, len(rc.req.source), strict = true)
    if !ok {
        return
    }
    for tok in tokens {
        if tok.kind == .Unresolved && !in_untaken_branch(whens, tok.start) {
            report_error(rc, report, tok.start, CODE_UNDECLARED, fmt.aprintf("Undeclared name: %s", rc.req.source[tok.start:tok.end]))
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
            report_error(rc, report, ref.operand_start, CODE_PRIVATE, fmt.aprintf("'%s' is not exported by '%s'", ref.name, ref.operand))
        case .Missing:
            report_error(rc, report, ref.operand_start, CODE_UNDECLARED, fmt.aprintf("'%s' is not declared by '%s'", ref.name, ref.operand))
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
// Two declarations conflict when both are surely active for the target, also under a `when` on a
// package constant, and neither is private to another file.
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
    guards := Guard_Ctx{rc = rc, view = view, states = make(map[odinsema.Item_Ref]odinsema.Tri, 16, context.temp_allocator)}
    done := make(map[string]struct{}, 16, context.temp_allocator)
    clash := make([dynamic]odinsema.Item_Ref, context.temp_allocator)
    offsets := make([dynamic]int, context.temp_allocator)
    for item in rc.live.tree.items {
        if item.kind == .Import || item.kind == .Foreign_Import || item.name == "_" || item.name in done {
            continue
        }
        done[item.name] = {}
        refs := odinsema.package_scope_lookup(view.scope, item.name)
        if len(refs) < 2 {
            continue
        }
        clear(&clash)
        for a, i in refs {
            for b in refs[i + 1:] {
                if (a.file == live || b.file == live) && refs_clash(&guards, a, b) {
                    add_ref(&clash, a)
                    add_ref(&clash, b)
                }
            }
        }
        clear(&offsets)
        elsewhere := false
        for ref in clash {
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
            report_error(rc, report, offset, CODE_REDECLARED, fmt.aprintf("Redeclaration of '%s' in this scope", item.name))
        }
    }
}

@(private = "file")
add_ref :: proc(list: ^[dynamic]odinsema.Item_Ref, ref: odinsema.Item_Ref) {
    for r in list {
        if r == ref {
            return
        }
    }
    append(list, ref)
}

// The guard states of the items of one package, with conditions on package constants read by the checker.
@(private = "file")
Guard_Ctx :: struct {
    rc:     ^Request_Context,
    view:   ^odinsema.Package_View,
    file:   int, // the file of the guard being resolved
    states: map[odinsema.Item_Ref]odinsema.Tri, // by item
}

@(private = "file")
refs_clash :: proc(g: ^Guard_Ctx, a, b: odinsema.Item_Ref) -> bool {
    files := g.view.sema_files
    ia := odinsema.package_item(files, a)
    ib := odinsema.package_item(files, b)
    if a.file != b.file && (ia.visibility == .File || ib.visibility == .File) {
        return false
    }
    return item_state(g, a) == .True && item_state(g, b) == .True
}

@(private = "file")
item_state :: proc(g: ^Guard_Ctx, ref: odinsema.Item_Ref) -> odinsema.Tri {
    if state, ok := g.states[ref]; ok {
        return state
    }
    tree := g.view.sema_files[ref.file].items
    g.file = ref.file
    resolver := odinsema.Guard_Resolver{resolve_guard, g}
    state := odinsema.guard_state(tree, tree.items[ref.item].guard, g.rc.target, &resolver)
    g.states[ref] = state
    return state
}

// The condition of guard `guard` of the file being resolved, read from its parse by the checker.
@(private = "file")
resolve_guard :: proc(data: rawptr, tree: ^odinsema.Item_Tree, guard: int) -> odinsema.Tri {
    g := cast(^Guard_Ctx)data
    rc := g.rc
    id := g.view.files[g.file]
    parsed: ^odinsyntax.Parse
    if id == rc.live.id {
        parsed = &rc.parsed
    } else {
        parsed = odinsema.db_parse(&rc.snap, id)
    }
    if parsed == nil || parsed.tree == nil || parsed.tree.root == nil {
        return .Unknown
    }
    cond, ok := when_cond_at(odinsyntax.node_root(parsed.tree), tree.guards[guard].start)
    if !ok {
        return .Unknown
    }
    return when_state(rc, cond, id)
}

// The condition that starts at `offset` of the `when` statement that holds it.
@(private = "file")
when_cond_at :: proc(root: odinsyntax.Syntax_Node, offset: int) -> (odinsyntax.Syntax_Node, bool) {
    n := root
    for {
        if n.green.kind == .When_Stmt {
            ws, _ := odinsyntax.as_when_stmt(n)
            if cond, ok := odinsyntax.when_stmt_cond(&ws); ok && int(cond.offset) == offset {
                return cond, true
            }
        }
        next_found := false
        it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
        for child in odinsyntax.child_iter_next(&it) {
            start, end := odinsyntax.node_range(child)
            if int(start) <= offset && offset < int(end) {
                n, next_found = child, true
                break
            }
        }
        if !next_found {
            return {}, false
        }
    }
}

// Reports each import of the buffer whose path names no directory. With no Odin root known, a
// root collection is not checked.
@(private = "file")
import_problems :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report) {
    for imp in odinsema.db_imports(&rc.snap, rc.live.id) {
        if imp.is_foreign {
            continue
        }
        offset := rc.live.tree.items[imp.item].start
        switch imp.problem {
        case .None, .No_Odin_Root:
        case .Empty_Path:
            report_error(rc, report, offset, CODE_IMPORT, fmt.aprintf("Invalid import path: '%s'", imp.path))
        case .Unknown_Collection:
            report_error(rc, report, offset, CODE_IMPORT, fmt.aprintf("Unknown library collection: '%s'", imp.collection))
        case .Missing_Dir:
            report_error(rc, report, offset, CODE_IMPORT, fmt.aprintf("Path does not exist: %s", imp.path))
        }
    }
}

// Reports each import of the buffer whose alias an earlier import of the buffer binds.
@(private = "file")
import_redeclarations :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report) {
    imports := odinsema.db_imports(&rc.snap, rc.live.id)
    seen := make(map[string]struct{}, len(imports), context.temp_allocator)
    for imp in imports {
        if imp.is_foreign || !imp.alias_valid || imp.alias == "_" || (imp.problem != .None && imp.problem != .No_Odin_Root) {
            continue
        }
        if imp.alias in seen {
            report_error(rc, report, imp.name_offset, CODE_REDECLARED, fmt.aprintf("Redeclaration of '%s' in this scope", imp.alias))
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
local_redeclarations :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, whens: []Branch, report: ^lang.Diagnostic_Report) {
    if len(m.locals) == 0 {
        return
    }
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
        if under_when(m, l, whens) {
            continue
        }
        // A label is unique in its whole procedure.
        key := Local_Key{l.scope, l.name, false}
        if l.kind == .Label {
            key = Local_Key{proc_scope(m, l.scope), l.name, true}
        }
        if _, found := first[key]; found {
            if l.kind == .Label {
                report_error(rc, report, l.name_offset, CODE_REDECLARED, fmt.aprintf("Duplicate label with the name '%s'", l.name))
            } else {
                report_error(rc, report, l.name_offset, CODE_REDECLARED, fmt.aprintf("Redeclaration of '%s' in this scope", l.name))
            }
            continue
        }
        first[key] = index
        if l.kind == .Label {
            continue
        }
        switch outer_binding(m, first, l) {
        case .None:
        case .Switch_Var:
            report_error(rc, report, l.name_offset, CODE_REDECLARED, fmt.aprintf("Redeclaration of '%s' in this scope", l.name))
        case .Result:
            report_error(rc, report, l.name_offset, CODE_REDECLARED, fmt.aprintf("Direct shadowing of the named return value '%s' in this scope", l.name))
        }
    }
}

// The outermost scope of the procedure that holds scope `scope`.
@(private = "file")
proc_scope :: proc(m: ^odinsema.Scope_Map, scope: int) -> int {
    s := scope
    for m.scopes[s].parent >= 0 && m.scopes[m.scopes[s].parent].proc_depth == m.scopes[s].proc_depth {
        s = m.scopes[s].parent
    }
    return s
}

// A struct, enum or bit_field type of the buffer.
@(private = "file")
Record :: struct {
    start: int,
    end:   int,
    kind:  odinsyntax.Syntax_Kind,
}

// Reports each field or enum member that an earlier one of the same type declares.
@(private = "file")
member_redeclarations :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, report: ^lang.Diagnostic_Report) {
    records := make([dynamic]Record, context.temp_allocator)
    collect_records(odinsyntax.node_root(rc.parsed.tree), &records)
    if len(records) == 0 {
        return
    }
    Member_Key :: struct {
        record: int,
        name:   string,
    }
    seen := make(map[Member_Key]struct{}, 64, context.temp_allocator)
    for ref in m.refs {
        if ref.kind != .Member_Decl || ref.name == "_" {
            continue
        }
        // Records nest in field types, after the field name, so the innermost one that holds the name owns it.
        owner := -1
        for r, i in records {
            if r.start <= ref.start && ref.start < r.end && (owner < 0 || r.start >= records[owner].start) {
                owner = i
            }
        }
        if owner < 0 {
            continue
        }
        key := Member_Key{owner, ref.name}
        if key not_in seen {
            seen[key] = {}
            continue
        }
        #partial switch records[owner].kind {
        case .Enum_Type:
            report_error(rc, report, ref.start, CODE_REDECLARED, fmt.aprintf("'%s' is already declared in this enumeration", ref.name))
        case .Bit_Field_Type:
            report_error(rc, report, ref.start, CODE_REDECLARED, fmt.aprintf("'%s' is already declared in this bit_field", ref.name))
        case:
            report_error(rc, report, ref.start, CODE_REDECLARED, fmt.aprintf("Redeclaration of '%s' in this scope", ref.name))
        }
    }
}

// Appends every struct, enum and bit_field type under `n`, outer ones first.
@(private = "file")
collect_records :: proc(n: odinsyntax.Syntax_Node, out: ^[dynamic]Record) {
    n := n
    #partial switch n.green.kind {
    case .Struct_Type, .Enum_Type, .Bit_Field_Type:
        start, end := odinsyntax.node_range(n)
        append(out, Record{int(start), int(end), n.green.kind})
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        collect_records(child, out)
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

// A `when` body or `else` branch and whether the target takes it.
@(private = "file")
Branch :: struct {
    start: int,
    end:   int,
    state: odinsema.Tri,
}

// True when the local is declared in a `when` branch of its own scope that the target does not
// surely take. A `when` body opens no scope, and the compiler checks only the branch that holds.
@(private = "file")
under_when :: proc(m: ^odinsema.Scope_Map, l: ^odinsema.Local, whens: []Branch) -> bool {
    scope := m.scopes[l.scope]
    for w in whens {
        if w.state != .True && w.start <= l.name_offset && l.name_offset < w.end && w.start >= scope.start && w.end <= scope.end {
            return true
        }
    }
    return false
}

// True when `offset` is in a `when` branch that the target does not surely take.
@(private = "file")
in_untaken_branch :: proc(whens: []Branch, offset: int) -> bool {
    for w in whens {
        if w.state != .True && w.start <= offset && offset < w.end {
            return true
        }
    }
    return false
}

// Appends the branches of every `when` statement under `n`.
@(private = "file")
collect_whens :: proc(n: odinsyntax.Syntax_Node, rc: ^Request_Context, out: ^[dynamic]Branch) {
    n := n
    if n.green.kind == .When_Stmt {
        collect_when_chain(n, .True, rc, out)
        return
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        collect_whens(child, rc, out)
    }
}

// What the `when` condition `cond` gives for the request's target. The build constants are read
// directly; a condition on a constant of the package or the body goes through the checker.
@(private = "file")
when_state :: proc(rc: ^Request_Context, cond: odinsyntax.Syntax_Node, file: odinsema.File_Id) -> odinsema.Tri {
    if state := odinsema.when_condition(cond, rc.target); state != .Unknown {
        return state
    }
    c := request_checker(rc)
    if c == nil {
        return .Unknown
    }
    v, ok := odinsema.const_eval(c, file, cond)
    if !ok {
        return .Unknown
    }
    b, is_bool := v.(bool)
    if !is_bool {
        return .Unknown
    }
    return b ? .True : .False
}

// Appends the branches of the `when` chain at `n`; `reached` tells whether the earlier branches all fail.
@(private = "file")
collect_when_chain :: proc(n: odinsyntax.Syntax_Node, reached: odinsema.Tri, rc: ^Request_Context, out: ^[dynamic]Branch) {
    ws, _ := odinsyntax.as_when_stmt(n)
    cond := odinsema.Tri.Unknown
    if c, ok := odinsyntax.when_stmt_cond(&ws); ok {
        cond = when_state(rc, c, rc.live.id)
    }
    if body, ok := odinsyntax.when_stmt_body(&ws); ok {
        start, end := odinsyntax.node_range(odinsyntax.Syntax_Node(body))
        append(out, Branch{int(start), int(end), odinsema.tri_and(reached, cond)})
        collect_whens(odinsyntax.Syntax_Node(body), rc, out)
    }
    other, ok := odinsyntax.when_stmt_else_branch(&ws)
    if !ok {
        return
    }
    rest := odinsema.tri_and(reached, odinsema.tri_not(cond))
    if other.green.kind == .When_Stmt {
        collect_when_chain(other, rest, rc, out)
        return
    }
    start, end := odinsyntax.node_range(other)
    append(out, Branch{int(start), int(end), rest})
    collect_whens(other, rc, out)
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
