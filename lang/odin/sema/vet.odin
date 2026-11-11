package odinsema

import "core:mem"
import "core:slice"
import "core:strings"

import odinsyntax "../syntax"

// One check of the compiler's `-vet` set.
Vet_Flag :: enum u8 {
    Unused_Variables,
    Unused_Imports,
    Shadowing,
    Using_Stmt,
    When_Shadowing,
    Cast,
    Unused_Procedures,
    Style,
    Semicolon,
    Tabs,
}

Vet_Flags :: bit_set[Vet_Flag]

// The checks `-vet` turns on.
VET_DEFAULT :: Vet_Flags{.Unused_Variables, .Unused_Imports, .Shadowing, .Using_Stmt, .When_Shadowing, .Cast}

// The checks outside `-vet`, on only when the config or a `#+vet` tag names them.
VET_OPT_IN :: Vet_Flags{.Unused_Procedures, .Style, .Semicolon, .Tabs}

// A byte range of a file.
Offset_Span :: struct {
    start: int,
    end:   int,
}

// The checks that apply to a file: `base`, with the names of its `#+vet` tags added and the `!name` ones
// removed, as the compiler does. A bare `#+vet` adds the `-vet` set.
file_vet_flags :: proc(tree: ^Item_Tree, base: Vet_Flags) -> Vet_Flags {
    if tree == nil {
        return base
    }
    added, removed: Vet_Flags
    for tag in tree.tags {
        name, rest := tag_split(tag)
        if name != "vet" {
            continue
        }
        rest = strings.trim_space(rest)
        if rest == "" {
            added += VET_DEFAULT
            continue
        }
        for word in strings.fields_iterator(&rest) {
            if strings.has_prefix(word, "!") {
                removed += vet_tag_flags(word[1:])
            } else {
                added += vet_tag_flags(word)
            }
        }
    }
    return (base + added) - removed
}

// The checks a build flag or a `#+vet` name stands for: `-vet`, `-vet-<name>` or a bare `<name>`.
// False for a name no check has.
vet_option_flags :: proc(word: string) -> (flags: Vet_Flags, ok: bool) {
    if word == "-vet" {
        return VET_DEFAULT, true
    }
    name := strings.trim_prefix(word, "-vet-")
    flags = vet_tag_flags(name)
    return flags, flags != {}
}

// The checks one `#+vet` name stands for; none for a name outside the `-vet` set.
@(private = "file")
vet_tag_flags :: proc(name: string) -> Vet_Flags {
    switch name {
    case "unused":
        return {.Unused_Variables, .Unused_Imports}
    case "unused-variables":
        return {.Unused_Variables}
    case "unused-imports":
        return {.Unused_Imports}
    case "shadowing":
        return {.Shadowing}
    case "using-stmt":
        return {.Using_Stmt}
    case "when-shadowing":
        return {.When_Shadowing}
    case "cast":
        return {.Cast}
    case "unused-procedures":
        return {.Unused_Procedures}
    case "style":
        return {.Style}
    case "semicolon":
        return {.Semicolon}
    case "tabs":
        return {.Tabs}
    }
    return {}
}

// A variable that shadows a variable of an enclosing scope.
Vet_Shadow :: struct {
    offset:        int, // the name of the shadowing declaration
    name:          string,
    shadowed:      int,       // the name of the shadowed declaration
    item:          int,       // the index of a shadowed package variable in Item_Tree.items; -1 for a local
    kind:          Decl_Kind, // of the shadowing declaration
    shadowed_kind: Decl_Kind,
}

// The variables of the file of `m` that shadow an earlier variable of an enclosing scope of the same
// procedure, or an earlier package variable of the same file, as `-vet-shadowing` reports them when
// both have one type. `x := x` and `x := &x` are not reported. A declaration in `skip` is left out, and so is a name whose
// nearest declaration is in `skip`. `tree` is the item tree of the file.
vet_shadowing :: proc(m: ^Scope_Map, parsed: odinsyntax.Parse, tree: ^Item_Tree, skip: []Offset_Span, allocator := context.allocator) -> (
    out: [dynamic]Vet_Shadow,
    err: mem.Allocator_Error,
) {
    out = make([dynamic]Vet_Shadow, allocator) or_return
    if m == nil || len(m.locals) == 0 || parsed.tree == nil || parsed.tree.root == nil {
        return
    }
    self_init := make(map[int]struct {}, 16, context.temp_allocator) or_return
    collect_self_init(odinsyntax.node_root(parsed.tree), &self_init)
    for l in m.locals {
        #partial switch l.kind {
        case .Var, .Loop_Var, .Switch_Var:
        case:
            continue
        }
        if l.name == "_" || l.name_offset in self_init || in_offset_spans(skip, l.name_offset) {
            continue
        }
        shadowed, item, kind, found := nearest_decl(m, tree, l)
        if !found || in_offset_spans(skip, shadowed) {
            continue
        }
        append(&out, Vet_Shadow{l.name_offset, l.name, shadowed, item, l.kind, kind}) or_return
    }
    slice.sort_by(out[:], proc(a, b: Vet_Shadow) -> bool {
        return a.offset < b.offset
    })
    return
}

// The variable the nearest enclosing declaration of the name of `l` gives, when it is one the
// compiler reports `l` for.
@(private = "file")
nearest_decl :: proc(m: ^Scope_Map, tree: ^Item_Tree, l: Local) -> (shadowed, item: int, kind: Decl_Kind, found: bool) {
    depth := m.scopes[l.scope].proc_depth
    for s := m.scopes[l.scope].parent; s >= 0; s = m.scopes[s].parent {
        best := -1
        for other, i in m.locals {
            if other.scope != s || other.name != l.name || other.kind == .Label {
                continue
            }
            var := var_like(other.kind)
            // The variables of an enclosing procedure are out of reach.
            if var && (m.scopes[s].proc_depth != depth || other.name_offset >= l.name_offset) {
                continue
            }
            if best < 0 || other.name_offset > m.locals[best].name_offset {
                best = i
            }
        }
        if best < 0 {
            continue
        }
        other := m.locals[best]
        if !var_like(other.kind) {
            return -1, -1, .Var, false
        }
        // The compiler reports these as redeclarations.
        parent := m.scopes[l.scope].parent
        if (other.kind == .Param || other.kind == .Result) && s == parent {
            return -1, -1, .Var, false
        }
        if other.kind == .Switch_Var && parent >= 0 && m.scopes[parent].parent == s {
            return -1, -1, .Var, false
        }
        return other.name_offset, -1, other.kind, true
    }
    if tree == nil {
        return -1, -1, .Var, false
    }
    for it, i in tree.items {
        if it.name != l.name {
            continue
        }
        if it.kind != .Var || it.name_offset >= l.name_offset {
            return -1, -1, .Var, false
        }
        return it.name_offset, i, .Var, true
    }
    return -1, -1, .Var, false
}

// Adds the name offsets of `x := x` and `x := &x` declarations under `n`.
@(private = "file")
collect_self_init :: proc(n: odinsyntax.Syntax_Node, out: ^map[int]struct {}) {
    n := n
    if n.green.kind == .Value_Decl && !is_constant_decl(n) {
        v, _               := odinsyntax.as_value_decl(n)
        names, has_names   := odinsyntax.value_decl_names(&v)
        values, has_values := odinsyntax.value_decl_values(&v)
        if has_names && has_values {
            ni := odinsyntax.name_list_names(&names)
            vi := odinsyntax.expr_list_items(&values)
            for {
                name, nok  := odinsyntax.child_iter_next(&ni)
                value, vok := odinsyntax.child_iter_next(&vi)
                if !nok || !vok {
                    break
                }
                if same_ident(name, value) {
                    out[int(name.offset)] = {}
                }
            }
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        collect_self_init(child, out)
    }
}

// True when `value` is the identifier `name` or its address.
@(private = "file")
same_ident :: proc(name, value: odinsyntax.Syntax_Node) -> bool {
    if name.green.kind != .Ident {
        return false
    }
    v := value
    if v.green.kind == .Unary_Expr {
        u, _                 := odinsyntax.as_unary_expr(v)
        op, has_op           := odinsyntax.unary_expr_op(&u)
        operand, has_operand := odinsyntax.unary_expr_operand(&u)
        if !has_op || !has_operand || op.green.kind != .And {
            return false
        }
        v = operand
    }
    return v.green.kind == .Ident && odinsyntax.node_text(v) == odinsyntax.node_text(name)
}

// The imports of a file that no identifier of the file names, as `-vet-unused-imports` reports them.
// A use in `dead` does not count. `_`, `@(require)`, foreign and unresolved imports, base:intrinsics
// and base:builtin are never reported. `tree` is
// the item tree the imports come from.
vet_unused_imports :: proc(tree: ^Item_Tree, imports: []File_Import, m: ^Scope_Map, dead: []Offset_Span, allocator := context.allocator) -> (
    out: [dynamic]int,
    err: mem.Allocator_Error,
) {
    out = make([dynamic]int, allocator) or_return
    if m == nil {
        return
    }
    used := make(map[string]struct {}, len(imports), context.temp_allocator) or_return
    for r in m.refs {
        if r.is_decl || in_offset_spans(dead, r.start) {
            continue
        }
        #partial switch r.kind {
        case .Package_Qualified:
            used[r.operand] = {}
        case .Free:
            used[r.name] = {}
        }
    }
    for imp, i in imports {
        if imp.is_foreign || !imp.alias_valid || imp.alias == "_" || imp.alias in used || imp.problem != .None && imp.problem != .No_Odin_Root {
            continue
        }
        if tree != nil && imp.item >= 0 && imp.item < len(tree.items) && has_attribute(&tree.items[imp.item], "require") {
            continue
        }
        // The compiler never reports base:intrinsics and base:builtin, which it builds in.
        if imp.collection == "base" {
            name := strings.trim_suffix(strings.trim_prefix(imp.path, "base:"), "/")
            if name == "intrinsics" || name == "builtin" {
                continue
            }
        }
        append(&out, i) or_return
    }
    return
}

@(private = "file")
in_offset_spans :: proc(spans: []Offset_Span, offset: int) -> bool {
    for s in spans {
        if s.start <= offset && offset < s.end {
            return true
        }
    }
    return false
}

// The types the variable of a type switch, declared at `var_offset`, has in the case clause that holds
// `at`, or in every clause when `at` is -1. A clause with no type or more than one gives the variable
// the subject's type.
switch_var_types :: proc(c: ^Checker, file: File_Id, var_offset, at: int, allocator := context.allocator) -> []Type_Id {
    out := make([dynamic]Type_Id, allocator)
    sw: odinsyntax.Syntax_Node
    found := false
    for n in node_path(c, file, var_offset) {
        if n.green.kind == .Type_Switch_Stmt {
            sw, found = n, true
        }
    }
    if !found {
        return out[:]
    }
    ts, _          := odinsyntax.as_type_switch_stmt(sw)
    body, has_body := odinsyntax.type_switch_stmt_body(&ts)
    if !has_body {
        return out[:]
    }
    subject := decl_type(c, local_symbol(file, var_offset))
    clauses := odinsyntax.child_iter((^odinsyntax.Syntax_Node)(&body), {kinds = {.Case_Clause}})
    for clause in odinsyntax.child_iter_next(&clauses) {
        start, end := odinsyntax.node_range(clause)
        if at >= 0 && (at < int(start) || at >= int(end)) {
            continue
        }
        cc, _              := odinsyntax.as_case_clause(clause)
        values, has_values := odinsyntax.case_clause_values(&cc)
        if !has_values {
            append(&out, subject)
            continue
        }
        items            := odinsyntax.expr_list_items(&values)
        first, has_first := odinsyntax.child_iter_next(&items)
        _, has_second    := odinsyntax.child_iter_next(&items)
        if !has_first || has_second {
            append(&out, subject)
            continue
        }
        append(&out, type_expr(c, file, first))
    }
    return out[:]
}

// A field a `using` brings in that shadows a variable of an enclosing scope.
Vet_Using_Shadow :: struct {
    offset:   int, // the name of the variable the `using` names
    field:    string,
    shadowed: int, // the name of the shadowed declaration
}

// The `using` locals and `using` statements of the file of `m`, in a block nested in a procedure,
// whose fields shadow an earlier variable of an enclosing scope, or an earlier package variable of
// the file, of the identical type. The compiler reports one field per `using`: the one whose
// shadowed declaration has the lowest line, then the first field. A `using` in `skip` is left out.
vet_using_shadowing :: proc(
    c: ^Checker,
    file: File_Id,
    m: ^Scope_Map,
    parsed: odinsyntax.Parse,
    tree: ^Item_Tree,
    skip: []Offset_Span,
    allocator := context.allocator,
) -> (out: [dynamic]Vet_Using_Shadow, err: mem.Allocator_Error) {
    out = make([dynamic]Vet_Using_Shadow, allocator) or_return
    if c == nil || m == nil || !m.has_using || parsed.tree == nil {
        return
    }
    // The variable each `using` names and the scope it is in.
    Source :: struct {
        local: int,
        scope: int,
        at:    int,
    }
    sources := make([dynamic]Source, context.temp_allocator) or_return
    for l, i in m.locals {
        if l.is_using && (l.kind == .Var || l.kind == .Loop_Var) {
            append(&sources, Source{i, l.scope, l.name_offset}) or_return
        }
    }
    for u in m.usings {
        ref, found := ref_at(m, u.start)
        if !found || ref.kind != .Local || ref.start != u.start || ref.end != u.end {
            continue
        }
        for l, i in m.locals {
            if l.name_offset == ref.decl && (l.kind == .Var || l.kind == .Loop_Var) {
                append(&sources, Source{i, u.scope, u.start}) or_return
                break
            }
        }
    }
    text := parsed.tree.text
    for src in sources {
        l := m.locals[src.local]
        if in_offset_spans(skip, src.at) || proc_top_scope(m, src.scope) {
            continue
        }
        fields    := type_members(c, decl_type(c, local_symbol(file, l.name_offset)), context.temp_allocator)
        best      := Vet_Using_Shadow{offset = -1}
        best_line := max(int)
        for f in fields {
            if f.kind != .Field || f.name == "_" || f.type == INVALID_TYPE {
                continue
            }
            shadowed, item, kind, found := enclosing_var(m, tree, f.name, src.scope, src.at)
            if !found {
                continue
            }
            if !shadow_type_matches(c, file, f.type, shadowed, item, kind, src.at) {
                continue
            }
            line := strings.count(text[:shadowed], "\n")
            if line < best_line {
                best_line = line
                best = Vet_Using_Shadow{l.name_offset, f.name, shadowed}
            }
        }
        if best.offset >= 0 {
            append(&out, best) or_return
        }
    }
    slice.sort_by(out[:], proc(a, b: Vet_Using_Shadow) -> bool {
        return a.offset < b.offset
    })
    return
}

// True when `s` is the scope of a procedure's parameters or of its body, where a `using` collides
// with the other names instead of shadowing them.
@(private = "file")
proc_top_scope :: proc(m: ^Scope_Map, s: int) -> bool {
    opens_proc :: proc(m: ^Scope_Map, s: int) -> bool {
        p := m.scopes[s].parent
        return p < 0 || m.scopes[p].proc_depth < m.scopes[s].proc_depth
    }
    if m.scopes[s].proc_depth == 0 || opens_proc(m, s) {
        return true
    }
    return opens_proc(m, m.scopes[s].parent)
}

// The variable named `name` that the scopes enclosing `scope` give at `before`: a local of the same
// procedure, or else a package variable of the file. False when the nearest declaration is not a
// variable.
@(private = "file")
enclosing_var :: proc(m: ^Scope_Map, tree: ^Item_Tree, name: string, scope, before: int) -> (shadowed, item: int, kind: Decl_Kind, found: bool) {
    depth := m.scopes[scope].proc_depth
    for s := m.scopes[scope].parent; s >= 0 && m.scopes[s].proc_depth == depth; s = m.scopes[s].parent {
        best := -1
        for other, i in m.locals {
            if other.scope != s || other.name != name || other.kind == .Label {
                continue
            }
            if var_like(other.kind) && other.name_offset >= before {
                continue
            }
            if best < 0 || other.name_offset > m.locals[best].name_offset {
                best = i
            }
        }
        if best < 0 {
            continue
        }
        other := m.locals[best]
        if !var_like(other.kind) {
            return -1, -1, .Var, false
        }
        return other.name_offset, -1, other.kind, true
    }
    if tree == nil {
        return -1, -1, .Var, false
    }
    for it, i in tree.items {
        if it.name != name {
            continue
        }
        if it.kind != .Var || it.name_offset >= before {
            return -1, -1, .Var, false
        }
        return it.name_offset, i, .Var, true
    }
    return -1, -1, .Var, false
}

// True when the shadowed declaration has type `t`. A type-switch variable has the type of the case
// clause that holds `at`.
@(private = "file")
shadow_type_matches :: proc(c: ^Checker, file: File_Id, t: Type_Id, shadowed, item: int, kind: Decl_Kind, at: int) -> bool {
    if item >= 0 {
        return decl_type(c, Symbol{file = file, item = i32(item), child = -1}) == t
    }
    if kind == .Switch_Var {
        for other in switch_var_types(c, file, shadowed, at, context.temp_allocator) {
            if other == t {
                return true
            }
        }
        return false
    }
    return decl_type(c, local_symbol(file, shadowed)) == t
}

// The attributes that keep a procedure that nothing in its package names.
@(private = "file")
UNUSED_PROC_EXEMPT :: [?]string{"export", "require", "init", "fini", "test", "link_name", "entry_point_only", "builtin", "objc_name", "objc_type"}

// The procedures declared at file scope that `-vet-unused-procedures` can report: not `main`, `_`, a
// foreign procedure, one under a `when` or one with an attribute that keeps it. Indexes into
// Item_Tree.items.
vet_unused_candidates :: proc(tree: ^Item_Tree, allocator := context.allocator) -> (out: [dynamic]int, err: mem.Allocator_Error) {
    out = make([dynamic]int, allocator) or_return
    if tree == nil {
        return
    }
    exempt := UNUSED_PROC_EXEMPT
    items: for it, i in tree.items {
        if it.kind != .Proc || it.in_foreign || it.guard >= 0 || it.name == "main" || it.name == "_" {
            continue
        }
        for a in it.attributes {
            if slice.contains(exempt[:], a.name) {
                continue items
            }
        }
        append(&out, i) or_return
    }
    return
}

// Adds to `used` every name of `names` that an identifier of `src` spells, other than the identifier at
// `skip` (the declaration itself). A lexical match: a field or a local of the same name counts as a
// use, so the check errs toward silence.
vet_note_names :: proc(src: string, names: map[string]int, used: ^map[string]struct {}, skip: []int) -> mem.Allocator_Error {
    for tok in odinsyntax.lex_all(src, context.temp_allocator) {
        if tok.kind != .Ident {
            continue
        }
        name := src[tok.offset:tok.offset + tok.len]
        if name not_in names || slice.contains(skip, int(tok.offset)) {
            continue
        }
        used[name] = {}
    }
    return nil
}
