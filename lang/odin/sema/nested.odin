package odinsema

import "core:mem"

import odinsyntax "../syntax"

// A declaration in a procedure body.
Nested_Decl :: struct {
    item:   Item,
    parent: int, // the enclosing Nested_Decl; -1 when it is directly in the body nested_decls reads
}

// The procedures and types declared in the body of procedure `item` of `parsed`, at any depth, in source order.
// Local constants and variables are not given. Every string and slice is allocated with `allocator`,
// which must free all at once (an arena or the temp allocator).
nested_decls :: proc(parsed: odinsyntax.Parse, item: ^Item, allocator: mem.Allocator) -> (decls: []Nested_Decl, err: mem.Allocator_Error) {
    if item.kind != .Proc || parsed.tree == nil || parsed.tree.root == nil {
        return nil, nil
    }
    root := odinsyntax.node_root(parsed.tree)
    found, ok := odinsyntax.node_covering(root, u32(item.start), u32(item.end), context.temp_allocator)
    if !ok {
        return nil, nil
    }
    decl, is_node := found.(odinsyntax.Syntax_Node)
    if !is_node || decl.green.kind != .Value_Decl {
        return nil, nil
    }
    value, _, has_value := decl_value(&decl, item.name_offset)
    if !has_value {
        return nil, nil
    }
    b := Builder {
        alloc = allocator,
        text  = parsed.tree.text,
    }
    out := make([dynamic]Nested_Decl, allocator)
    walk_proc_body(&b, value, -1, &out)
    if b.err != nil {
        return nil, b.err
    }
    return out[:], nil
}

// The value bound to the name at `name_offset` in Value_Decl `n`, and the result of it the name takes:
// `result` is -1 when the value is the name's own. Its parent chain is not kept.
@(private)
decl_value :: proc(n: ^odinsyntax.Syntax_Node, name_offset: int) -> (value: odinsyntax.Syntax_Node, result: int, ok: bool) {
    v, _ := odinsyntax.as_value_decl(n^)
    index, count := -1, 0
    if name_list, has_names := odinsyntax.value_decl_names(&v); has_names {
        it := odinsyntax.name_list_names(&name_list)
        for name in odinsyntax.child_iter_next(&it) {
            if int(name.offset) == name_offset {
                index = count
            }
            count += 1
        }
    }
    value_list, has_values := odinsyntax.value_decl_values(&v)
    if index < 0 || !has_values {
        return {}, -1, false
    }
    values := 0
    it := odinsyntax.expr_list_items(&value_list)
    for item in odinsyntax.child_iter_next(&it) {
        if values == index || (values == 0 && count > 1) {
            value, ok = item, true
        }
        values += 1
    }
    if values != count && values != 1 {
        return {}, -1, false
    }
    result = -1
    if values == 1 && count > 1 {
        result = index
    }
    value.parent = nil
    return
}

// Walks the body of a procedure literal, through a directive such as `#force_inline`.
@(private = "file")
walk_proc_body :: proc(b: ^Builder, value: odinsyntax.Syntax_Node, parent: int, out: ^[dynamic]Nested_Decl) {
    if t, is_tag := odinsyntax.as_tag_expr(value); is_tag {
        if inner, ok := odinsyntax.tag_expr_expr(&t); ok {
            walk_proc_body(b, inner, parent, out)
        }
        return
    }
    p, is_proc := odinsyntax.as_proc_lit(value)
    if !is_proc {
        return
    }
    if body, ok := odinsyntax.proc_lit_body(&p); ok {
        walk_nested(b, body, parent, out)
    }
}

// Finds the declarations under `n`; an anonymous procedure literal counts as part of the enclosing body.
@(private = "file")
walk_nested :: proc(b: ^Builder, n: odinsyntax.Syntax_Node, parent: int, out: ^[dynamic]Nested_Decl) {
    n := n
    if n.green.kind == .Value_Decl {
        add_nested(b, &n, parent, out)
        return
    }
    pos := n.offset
    for child in odinsyntax.green_children(n.green) {
        child_pos := pos
        pos += odinsyntax.element_len(child)
        if g, is_node := odinsyntax.element_node(child); is_node {
            walk_nested(b, odinsyntax.Syntax_Node{g, child_pos, &n, n.tree}, parent, out)
        }
    }
}

@(private = "file")
add_nested :: proc(b: ^Builder, n: ^odinsyntax.Syntax_Node, parent: int, out: ^[dynamic]Nested_Decl) {
    items := make([dynamic]Item, context.temp_allocator)
    add_value_decl(b, n, Decl_Context{guard = -1, visibility = .File}, &items)
    walked := -1
    for item in items {
        value, _, has_value := decl_value(n, item.name_offset)
        #partial switch item.kind {
        case .Const, .Var:
            if has_value && int(value.offset) != walked {
                walked = int(value.offset)
                walk_nested(b, value, parent, out)
            }
            continue
        case .Import, .Foreign_Import, .Field, .Enum_Member:
            continue
        }
        index := len(out)
        if _, err := append(out, Nested_Decl{item = item, parent = parent}); err != nil {
            if b.err == nil {
                b.err = err
            }
            return
        }
        if item.kind == .Proc && has_value {
            walk_proc_body(b, value, index, out)
        }
    }
}
