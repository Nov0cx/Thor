package odinsema

import "core:mem"

import odinsyntax "../syntax"

// The part of a polymorphic procedure or record that the compiler checks only per instance: the
// body and `where` clause of a procedure, the fields and `where` clause of a record.
Poly_Body :: struct {
    name:  string, // the constant that declares it; "" for an anonymous one
    span:   Offset_Span,
    parent: int, // the body that holds this one; -1 for none
    names:  [dynamic]string, // the identifiers in the body, outside nested polymorphic bodies
}

// The polymorphic bodies of one file and the identifiers outside them.
Poly_File :: struct {
    bodies:  [dynamic]Poly_Body,
    outside: [dynamic]string,
}

@(private = "file")
Poly_Walker :: struct {
    file: ^Poly_File,
    err:  mem.Allocator_Error,
}

// The polymorphic bodies of `parsed` and the identifiers each one holds. The names of a
// declaration are not collected, so a declaration does not count as a use of itself.
poly_file :: proc(parsed: odinsyntax.Parse, allocator := context.allocator) -> (out: Poly_File, err: mem.Allocator_Error) {
    out.bodies = make([dynamic]Poly_Body, allocator) or_return
    out.outside = make([dynamic]string, allocator) or_return
    if parsed.tree == nil || parsed.tree.root == nil {
        return
    }
    w := Poly_Walker{file = &out}
    poly_walk(&w, odinsyntax.node_root(parsed.tree), -1, "")
    return out, w.err
}

// Frees what poly_file allocated.
poly_file_destroy :: proc(f: ^Poly_File) {
    for &b in f.bodies {
        delete(b.names)
    }
    delete(f.bodies)
    delete(f.outside)
}

// `body` is the index of the innermost polymorphic body that holds `n`, -1 for none; `name` the
// constant `n` is the value of.
@(private = "file")
poly_walk :: proc(w: ^Poly_Walker, n: odinsyntax.Syntax_Node, body: int, name: string) {
    n := n
    body := body
    #partial switch n.green.kind {
    case .Ident:
        list := &w.file.outside if body < 0 else &w.file.bodies[body].names
        if _, err := append(list, odinsyntax.node_text(n)); err != nil {
            w.err = err
        }
        return
    case .Value_Decl:
        poly_walk_decl(w, n, body)
        return
    case .Proc_Lit, .Struct_Type, .Union_Type:
        if start, ok := poly_body_start(n); ok {
            _, end := odinsyntax.node_range(n)
            b := Poly_Body{name = name, span = {start, int(end)}, parent = body}
            b.names.allocator = w.file.bodies.allocator
            if _, err := append(&w.file.bodies, b); err != nil {
                w.err = err
                return
            }
            // The signature stays outside: the compiler checks it with the declaration.
            outer := body
            body = len(w.file.bodies) - 1
            it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
            for child in odinsyntax.child_iter_next(&it) {
                cs, _ := odinsyntax.node_range(child)
                poly_walk(w, child, body if int(cs) >= start else outer, "")
            }
            return
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        poly_walk(w, child, body, "")
    }
}

// Walks a declaration with its names left out. A constant passes its name to its value.
@(private = "file")
poly_walk_decl :: proc(w: ^Poly_Walker, n: odinsyntax.Syntax_Node, body: int) {
    n := n
    v, _ := odinsyntax.as_value_decl(n)
    constant := is_constant_decl(n)
    names := make([dynamic]string, context.temp_allocator)
    if list, ok := odinsyntax.value_decl_names(&v); ok {
        it := odinsyntax.name_list_names(&list)
        for name in odinsyntax.child_iter_next(&it) {
            append(&names, odinsyntax.node_text(name))
        }
    }
    values, has_values := odinsyntax.value_decl_values(&v)
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        #partial switch child.green.kind {
        case .Name_List:
            continue
        case .Expr_List:
            if has_values && child.offset == values.offset {
                vi := odinsyntax.expr_list_items(&values)
                i := 0
                for value in odinsyntax.child_iter_next(&vi) {
                    name := ""
                    if constant && len(names) == 1 {
                        name = names[0]
                    } else if constant && i < len(names) {
                        name = names[i]
                    }
                    poly_walk(w, value, body, name)
                    i += 1
                }
                continue
            }
        }
        poly_walk(w, child, body, "")
    }
}

// Where the per-instance part of a polymorphic procedure or record starts; false when `n` has no
// `$` parameter.
@(private = "file")
poly_body_start :: proc(n: odinsyntax.Syntax_Node) -> (int, bool) {
    params: odinsyntax.Param_List
    ok: bool
    #partial switch n.green.kind {
    case .Proc_Lit:
        pl, _ := odinsyntax.as_proc_lit(n)
        pt, has_type := odinsyntax.proc_lit_type(&pl)
        if !has_type {
            return 0, false
        }
        if params, ok = odinsyntax.proc_type_params(&pt); !ok || !has_poly_type(odinsyntax.Syntax_Node(params)) {
            return 0, false
        }
        _, end := odinsyntax.node_range(odinsyntax.Syntax_Node(pt))
        return int(end), true
    case .Struct_Type:
        st, _ := odinsyntax.as_struct_type(n)
        params, ok = odinsyntax.struct_type_params(&st)
    case .Union_Type:
        ut, _ := odinsyntax.as_union_type(n)
        params, ok = odinsyntax.union_type_params(&ut)
    }
    if !ok || !has_poly_type(odinsyntax.Syntax_Node(params)) {
        return 0, false
    }
    _, end := odinsyntax.node_range(odinsyntax.Syntax_Node(params))
    return int(end), true
}

// True when a `$` name is under `n`, outside nested procedures and records.
@(private = "file")
has_poly_type :: proc(n: odinsyntax.Syntax_Node) -> bool {
    n := n
    #partial switch n.green.kind {
    case .Poly_Type:
        return true
    case .Proc_Lit, .Struct_Type, .Union_Type:
        return false
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        if has_poly_type(child) {
            return true
        }
    }
    return false
}

// The polymorphic bodies of each file of one package that no use instantiates: a body is
// instantiated when the body that holds it is, and its name is used outside every polymorphic
// body or in a body that is instantiated. The match is by name, so a same-named local can only
// keep a body in. An anonymous body counts as instantiated.
poly_uninstantiated :: proc(files: []Poly_File, allocator := context.allocator) -> (out: [][]Offset_Span, err: mem.Allocator_Error) {
    used := make(map[string]struct{}, 64, context.temp_allocator) or_return
    for &f in files {
        for name in f.outside {
            used[name] = {}
        }
    }
    reached := make([][]bool, len(files), context.temp_allocator) or_return
    for &f, i in files {
        reached[i] = make([]bool, len(f.bodies), context.temp_allocator) or_return
    }
    for changed := true; changed; {
        changed = false
        for &f, i in files {
            for &b, j in f.bodies {
                if reached[i][j] || (b.parent >= 0 && !reached[i][b.parent]) || (b.name != "" && b.name not_in used) {
                    continue
                }
                reached[i][j] = true
                changed = true
                for name in b.names {
                    used[name] = {}
                }
            }
        }
    }
    out = make([][]Offset_Span, len(files), allocator) or_return
    for &f, i in files {
        spans := make([dynamic]Offset_Span, allocator) or_return
        for b, j in f.bodies {
            if !reached[i][j] {
                append(&spans, b.span) or_return
            }
        }
        out[i] = spans[:]
    }
    return
}
