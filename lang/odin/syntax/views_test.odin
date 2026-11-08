package odinsyntax

import "core:fmt"
import "core:testing"

// Why an accessor result in the tree is wrong, or "" when none is. Every result must be a direct
// child of the node it was asked of; with `accepted`, every required accessor must find its child.
view_error :: proc(tree: ^Green_Tree, accepted: bool) -> string {
    @(static) by_kind: [Syntax_Kind][]View_Accessor
    @(static) grouped: bool
    if !grouped {
        start := 0
        for i in 1 ..= len(VIEW_ACCESSORS) {
            if i == len(VIEW_ACCESSORS) || VIEW_ACCESSORS[i].kind != VIEW_ACCESSORS[start].kind {
                by_kind[VIEW_ACCESSORS[start].kind] = VIEW_ACCESSORS[start:i]
                start = i
            }
        }
        grouped = true
    }
    walk :: proc(n: ^Syntax_Node, accepted: bool, by_kind: ^[Syntax_Kind][]View_Accessor) -> string {
        ns, ne := node_range(n^)
        for acc in by_kind[n.green.kind] {
            e, ok := acc.call(n)
            if !ok {
                if accepted && acc.required {
                    return fmt.tprintf("%v@%d has no %s", n.green.kind, n.offset, acc.name)
                }
                continue
            }
            es, ee := element_range(e)
            parent: ^Syntax_Node
            switch v in e {
            case Syntax_Node:  parent = v.parent
            case Syntax_Token: parent = v.parent
            }
            if parent != n || es < ns || ee > ne {
                return fmt.tprintf("%v@%d: %s gives %d..%d, not a child", n.green.kind, n.offset, acc.name, es, ee)
            }
        }
        offset := n.offset
        for child in green_children(n.green) {
            if c, is_node := element_node(child); is_node {
                sub := Syntax_Node{c, offset, n, n.tree}
                if msg := walk(&sub, accepted, by_kind); msg != "" {
                    return msg
                }
            }
            offset += element_len(child)
        }
        return ""
    }
    root := node_root(tree)
    return walk(&root, accepted, &by_kind)
}

// The first node of `kind` in `src`, depth first. Its parents are in the temp allocator.
@(private = "file")
first_node :: proc(t: ^testing.T, src: string, kind: Syntax_Kind, loc := #caller_location) -> (^Syntax_Node, ^Green_Tree) {
    result, err := parse(src, context.temp_allocator)
    if !testing.expect_value(t, err, nil, loc) {
        return nil, nil
    }
    find :: proc(n: ^Syntax_Node, kind: Syntax_Kind) -> ^Syntax_Node {
        if n.green.kind == kind {
            return n
        }
        offset := n.offset
        for child in green_children(n.green) {
            if c, is_node := element_node(child); is_node {
                if found := find(new_clone(Syntax_Node{c, offset, n, n.tree}, context.temp_allocator), kind); found != nil {
                    return found
                }
            }
            offset += element_len(child)
        }
        return nil
    }
    root := new_clone(node_root(result.tree), context.temp_allocator)
    found := find(root, kind)
    testing.expectf(t, found != nil, "no %v in %q", kind, src, loc = loc)
    return found, result.tree
}

@(private = "file")
text_of :: proc(e: $T, ok: bool) -> string {
    if !ok {
        return "<missing>"
    }
    when T == Syntax_Token {
        return syntax_token_text(e)
    } else {
        return node_text(Syntax_Node(e))
    }
}

@(private = "file")
iter_texts :: proc(it: Child_Iter) -> []string {
    it := it
    out := make([dynamic]string, context.temp_allocator)
    for c in child_iter_next(&it) {
        append(&out, node_text(c))
    }
    return out[:]
}

@(private = "file")
expect_texts :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
    if !testing.expectf(t, len(got) == len(want), "got %v, want %v", got, want, loc = loc) {
        return
    }
    for g, i in got {
        testing.expectf(t, g == want[i], "item %d: got %q, want %q", i, g, want[i], loc = loc)
    }
}

@(test)
test_view_value_decl :: proc(t: ^testing.T) {
    n, tree := first_node(t, "package p\n@(private) a, b: int : 1, 2\n", .Value_Decl)
    if n == nil {
        return
    }
    defer tree_destroy(tree, context.temp_allocator)
    v, is_v := as_value_decl(n^)
    testing.expect(t, is_v)
    _, is_block := as_block(n^)
    testing.expect(t, !is_block)
    names, names_ok := value_decl_names(&v)
    testing.expect(t, names_ok)
    expect_texts(t, iter_texts(name_list_names(&names)), {"a", "b"})
    testing.expect_value(t, text_of(value_decl_type(&v)), "int")
    values, values_ok := value_decl_values(&v)
    testing.expect(t, values_ok)
    expect_texts(t, iter_texts(expr_list_items(&values)), {"1", "2"})
    expect_texts(t, iter_texts(value_decl_attributes(&v)), {"@(private)"})

    m, mtree := first_node(t, "package p\nx :: 1\n", .Value_Decl)
    if m == nil {
        return
    }
    defer tree_destroy(mtree, context.temp_allocator)
    mv, _ := as_value_decl(m^)
    testing.expect_value(t, text_of(value_decl_type(&mv)), "<missing>")
}

@(test)
test_view_proc :: proc(t: ^testing.T) {
    src := "package p\nf :: proc \"c\" (#no_alias a: ^int, b := 2, $T: typeid) -> (r: int, ok: bool) { return }\n"
    n, tree := first_node(t, src, .Proc_Lit)
    if n == nil {
        return
    }
    defer tree_destroy(tree, context.temp_allocator)
    lit, _ := as_proc_lit(n^)
    typ, typ_ok := proc_lit_type(&lit)
    testing.expect(t, typ_ok)
    testing.expect_value(t, text_of(proc_type_calling_convention(&typ)), "\"c\"")
    params, params_ok := proc_type_params(&typ)
    testing.expect(t, params_ok)
    it := param_list_fields(&params)
    want_types := []string{"^int", "<missing>", "typeid"}
    want_names := []string{"a", "b", "$T"}
    i := 0
    for f in child_iter_next(&it) {
        field := Field(f)
        names, _ := field_names(&field)
        if i < len(want_types) {
            testing.expect_value(t, text_of(field_type(&field)), want_types[i])
            testing.expect_value(t, node_text(Syntax_Node(names)), want_names[i])
        }
        i += 1
    }
    testing.expect_value(t, i, 3)
    results, results_ok := proc_type_results(&typ)
    testing.expect(t, results_ok)
    expect_texts(t, iter_texts(result_list_fields(&results)), {"r: int", "ok: bool"})
    testing.expect_value(t, text_of(proc_lit_body(&lit)), "{ return }")

    u, utree := first_node(t, "package p\nf :: proc(int, ..string) {}\n", .Field)
    if u == nil {
        return
    }
    defer tree_destroy(utree, context.temp_allocator)
    uf, _ := as_field(u^)
    testing.expect_value(t, text_of(field_type(&uf)), "int")
    testing.expect_value(t, text_of(field_names(&uf)), "<missing>")
}

@(test)
test_view_exprs :: proc(t: ^testing.T) {
    {
        n, tree := first_node(t, "package p\nx := a.b.c\n", .Selector_Expr)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        s, _ := as_selector_expr(n^)
        testing.expect_value(t, text_of(selector_expr_operand(&s)), "a.b")
        testing.expect_value(t, text_of(selector_expr_field(&s)), "c")
        testing.expect_value(t, text_of(selector_expr_arrow(&s)), "<missing>")
    }
    {
        n, tree := first_node(t, "package p\nx := f(1, y = 2, ..z)\n", .Call_Expr)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        c, _ := as_call_expr(n^)
        testing.expect_value(t, text_of(call_expr_callee(&c)), "f")
        args, _ := call_expr_args(&c)
        expect_texts(t, iter_texts(arg_list_args(&args)), {"1", "y = 2", "..z"})
    }
    {
        n, tree := first_node(t, "package p\nx := a + b * -c\n", .Binary_Expr)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        b, _ := as_binary_expr(n^)
        testing.expect_value(t, text_of(binary_expr_lhs(&b)), "a")
        testing.expect_value(t, text_of(binary_expr_op(&b)), "+")
        testing.expect_value(t, text_of(binary_expr_rhs(&b)), "b * -c")
    }
    {
        n, tree := first_node(t, "package p\nx := Point{x = 1, 2}\n", .Comp_Lit)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        c, _ := as_comp_lit(n^)
        testing.expect_value(t, text_of(comp_lit_type(&c)), "Point")
        expect_texts(t, iter_texts(comp_lit_elems(&c)), {"x = 1", "2"})
    }
    {
        n, tree := first_node(t, "package p\nx := a[1:]\n", .Slice_Expr)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        s, _ := as_slice_expr(n^)
        testing.expect_value(t, text_of(slice_expr_operand(&s)), "a")
        testing.expect_value(t, text_of(slice_expr_low(&s)), "1")
        testing.expect_value(t, text_of(slice_expr_high(&s)), "<missing>")
    }
    {
        n, tree := first_node(t, "package p\nx := cast(int)y\n", .Cast_Expr)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        c, _ := as_cast_expr(n^)
        testing.expect_value(t, text_of(cast_expr_type(&c)), "int")
        testing.expect_value(t, text_of(cast_expr_operand(&c)), "y")
    }
}

@(test)
test_view_stmts :: proc(t: ^testing.T) {
    body := "package p\nf :: proc() {{\n%s\n}}\n"
    {
        n, tree := first_node(t, fmt.tprintf(body, "if x := g(); x > 0 { } else { }"), .If_Stmt)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        s, _ := as_if_stmt(n^)
        testing.expect_value(t, text_of(if_stmt_init(&s)), "x := g()")
        testing.expect_value(t, text_of(if_stmt_cond(&s)), "x > 0")
        testing.expect_value(t, text_of(if_stmt_body(&s)), "{ }")
        testing.expect_value(t, text_of(if_stmt_else_branch(&s)), "{ }")
    }
    {
        n, tree := first_node(t, fmt.tprintf(body, "loop: for i := 0; i < n; i += 1 { }"), .For_Stmt)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        s, _ := as_for_stmt(n^)
        testing.expect_value(t, text_of(for_stmt_label(&s)), "loop:")
        testing.expect_value(t, text_of(for_stmt_init(&s)), "i := 0")
        testing.expect_value(t, text_of(for_stmt_cond(&s)), "i < n")
        testing.expect_value(t, text_of(for_stmt_post(&s)), "i += 1")
    }
    {
        n, tree := first_node(t, fmt.tprintf(body, "for x < 3 { }"), .For_Stmt)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        s, _ := as_for_stmt(n^)
        testing.expect_value(t, text_of(for_stmt_init(&s)), "<missing>")
        testing.expect_value(t, text_of(for_stmt_cond(&s)), "x < 3")
        testing.expect_value(t, text_of(for_stmt_post(&s)), "<missing>")
    }
    {
        n, tree := first_node(t, fmt.tprintf(body, "#reverse for v, i in xs { }"), .Range_Stmt)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        s, _ := as_range_stmt(n^)
        testing.expect_value(t, text_of(range_stmt_vars(&s)), "v, i")
        testing.expect_value(t, text_of(range_stmt_expr(&s)), "xs")
    }
    {
        n, tree := first_node(t, fmt.tprintf(body, "#partial switch v in u {\ncase int, f32:\n\tx = 1\n}"), .Type_Switch_Stmt)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        s, _ := as_type_switch_stmt(n^)
        testing.expect_value(t, text_of(type_switch_stmt_vars(&s)), "v")
        testing.expect_value(t, text_of(type_switch_stmt_subject(&s)), "u")
        blk, _ := type_switch_stmt_body(&s)
        cases := block_stmts(&blk)
        testing.expect(t, cases.parent != nil)
        c, tree2 := first_node(t, fmt.tprintf(body, "switch x { case 1, 2: y(); z() }"), .Case_Clause)
        if c == nil {
            return
        }
        defer tree_destroy(tree2, context.temp_allocator)
        cc, _ := as_case_clause(c^)
        testing.expect_value(t, text_of(case_clause_values(&cc)), "1, 2")
        expect_texts(t, iter_texts(case_clause_stmts(&cc)), {"y()", "z()"})
    }
}

@(test)
test_view_types :: proc(t: ^testing.T) {
    {
        n, tree := first_node(t, "package p\nS :: struct($T: typeid) #packed { a, b: T `tag`, using c: int }\n", .Struct_Type)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        s, _ := as_struct_type(n^)
        _, has_params := struct_type_params(&s)
        testing.expect(t, has_params)
        fields, _ := struct_type_fields(&s)
        it := field_list_fields(&fields)
        f1, _ := child_iter_next(&it)
        field1 := Field(f1)
        testing.expect_value(t, text_of(field_tag(&field1)), "`tag`")
        f2, _ := child_iter_next(&it)
        field2 := Field(f2)
        testing.expect_value(t, text_of(field_using(&field2)), "using")
        testing.expect_value(t, text_of(field_type(&field2)), "int")
    }
    {
        n, tree := first_node(t, "package p\nE :: enum u8 { A, B = 2 }\n", .Enum_Type)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        e, _ := as_enum_type(n^)
        testing.expect_value(t, text_of(enum_type_backing(&e)), "u8")
        expect_texts(t, iter_texts(enum_type_members(&e)), {"A", "B = 2"})
    }
    {
        n, tree := first_node(t, "package p\nM :: map[string][]int\n", .Map_Type)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        m, _ := as_map_type(n^)
        testing.expect_value(t, text_of(map_type_key(&m)), "string")
        testing.expect_value(t, text_of(map_type_value(&m)), "[]int")
    }
    {
        n, tree := first_node(t, "package p\nB :: bit_set[E; u16]\n", .Bit_Set_Type)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        b, _ := as_bit_set_type(n^)
        testing.expect_value(t, text_of(bit_set_type_elem(&b)), "E")
        testing.expect_value(t, text_of(bit_set_type_backing(&b)), "u16")
    }
    {
        n, tree := first_node(t, "package p\nimport fmt \"core:fmt\"\n", .Import_Decl)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        d, _ := as_import_decl(n^)
        testing.expect_value(t, text_of(import_decl_alias(&d)), "fmt")
        testing.expect_value(t, text_of(import_decl_path(&d)), "\"core:fmt\"")
    }
}

// Broken code gives missing children, not wrong ones.
@(test)
test_view_broken_code :: proc(t: ^testing.T) {
    {
        n, tree := first_node(t, "package p\nf :: proc() {\n\tx := a.\n\ty := 1\n}\n", .Selector_Expr)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        s, _ := as_selector_expr(n^)
        testing.expect_value(t, text_of(selector_expr_operand(&s)), "a")
        testing.expect_value(t, text_of(selector_expr_field(&s)), "<missing>")
    }
    {
        n, tree := first_node(t, "package p\nf :: proc() {\n\tfoo(", .Call_Expr)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        c, _ := as_call_expr(n^)
        testing.expect_value(t, text_of(call_expr_callee(&c)), "foo")
        args, has_args := call_expr_args(&c)
        testing.expect(t, has_args)
        expect_texts(t, iter_texts(arg_list_args(&args)), {})
    }
    {
        n, tree := first_node(t, "package p\nx :=\ny := 1\n", .Value_Decl)
        if n == nil {
            return
        }
        defer tree_destroy(tree, context.temp_allocator)
        v, _ := as_value_decl(n^)
        testing.expect_value(t, text_of(value_decl_values(&v)), "<missing>")
    }
    for src in ([]string{"package p\nx := (", "package p\nS :: struct {", "package p\nf :: proc() { if { for ; ; } }"}) {
        result, err := parse(src, context.temp_allocator)
        if testing.expect_value(t, err, nil) {
            testing.expect_value(t, view_error(result.tree, false), "")
            tree_destroy(result.tree, context.temp_allocator)
        }
    }
}
