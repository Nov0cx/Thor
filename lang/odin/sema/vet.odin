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
}

Vet_Flags :: bit_set[Vet_Flag]

// The checks `-vet` turns on.
VET_DEFAULT :: Vet_Flags{.Unused_Variables, .Unused_Imports, .Shadowing, .Using_Stmt, .When_Shadowing}

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

// The checks one `#+vet` name stands for; none for a name outside the `-vet` set.
@(private = "file")
vet_tag_flags :: proc(name: string) -> Vet_Flags {
    switch name {
    case "unused":           return {.Unused_Variables, .Unused_Imports}
    case "unused-variables": return {.Unused_Variables}
    case "unused-imports":   return {.Unused_Imports}
    case "shadowing":        return {.Shadowing}
    case "using-stmt":       return {.Using_Stmt}
    case "when-shadowing":   return {.When_Shadowing}
    }
    return {}
}

// A variable that shadows a variable of an enclosing scope.
Vet_Shadow :: struct {
    offset:   int, // the name of the shadowing declaration
    name:     string,
    shadowed: int, // the name of the shadowed declaration
    item:     int, // the index of a shadowed package variable in Item_Tree.items; -1 for a local
    kind:     Decl_Kind, // of the shadowing declaration
    shadowed_kind: Decl_Kind,
}

// The variables of the file of `m` that shadow an earlier variable of an enclosing scope of the same
// procedure, or an earlier package variable of the same file, as `-vet-shadowing` reports them when
// both have one type. `x := x` and `x := &x` are not reported. A declaration in `skip` is left out, and so is a name whose
// nearest declaration is in `skip`. `tree` is the item tree of the file.
vet_shadowing :: proc(m: ^Scope_Map, parsed: odinsyntax.Parse, tree: ^Item_Tree, skip: []Offset_Span, allocator := context.allocator) -> (out: [dynamic]Vet_Shadow, err: mem.Allocator_Error) {
    out = make([dynamic]Vet_Shadow, allocator) or_return
    if m == nil || len(m.locals) == 0 || parsed.tree == nil || parsed.tree.root == nil {
        return
    }
    self_init := make(map[int]struct{}, 16, context.temp_allocator) or_return
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
    slice.sort_by(out[:], proc(a, b: Vet_Shadow) -> bool {return a.offset < b.offset})
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
collect_self_init :: proc(n: odinsyntax.Syntax_Node, out: ^map[int]struct{}) {
    n := n
    if n.green.kind == .Value_Decl && !is_constant_decl(n) {
        v, _ := odinsyntax.as_value_decl(n)
        names, has_names := odinsyntax.value_decl_names(&v)
        values, has_values := odinsyntax.value_decl_values(&v)
        if has_names && has_values {
            ni := odinsyntax.name_list_names(&names)
            vi := odinsyntax.expr_list_items(&values)
            for {
                name, nok := odinsyntax.child_iter_next(&ni)
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
        u, _ := odinsyntax.as_unary_expr(v)
        op, has_op := odinsyntax.unary_expr_op(&u)
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
vet_unused_imports :: proc(tree: ^Item_Tree, imports: []File_Import, m: ^Scope_Map, dead: []Offset_Span, allocator := context.allocator) -> (out: [dynamic]int, err: mem.Allocator_Error) {
    out = make([dynamic]int, allocator) or_return
    if m == nil {
        return
    }
    used := make(map[string]struct{}, len(imports), context.temp_allocator) or_return
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
    ts, _ := odinsyntax.as_type_switch_stmt(sw)
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
        cc, _ := odinsyntax.as_case_clause(clause)
        values, has_values := odinsyntax.case_clause_values(&cc)
        if !has_values {
            append(&out, subject)
            continue
        }
        items := odinsyntax.expr_list_items(&values)
        first, has_first := odinsyntax.child_iter_next(&items)
        _, has_second := odinsyntax.child_iter_next(&items)
        if !has_first || has_second {
            append(&out, subject)
            continue
        }
        append(&out, type_expr(c, file, first))
    }
    return out[:]
}
