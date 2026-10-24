// Static analysis of Odin source on the lossless tree of package odinsyntax.
package odinsema

import "core:mem"
import "core:mem/virtual"
import "core:strings"

import odinsyntax "../syntax"

// What a declaration declares.
Item_Kind :: enum u8 {
    Proc,
    Proc_Group,
    Struct,
    Enum,
    Union,
    Bit_Set,
    Bit_Field,
    Type,
    Const,
    Var,
    Import,
    Foreign_Import,
    Field,
    Enum_Member,
}

// How far outside its file a declaration can be named.
Visibility :: enum u8 {
    Public,
    Package,
    File,
}

// One attribute element: `name` or `name = value`. `value` is the source text, "" when bare.
Item_Attribute :: struct {
    name:  string,
    value: string,
}

// One branch of a `when` chain. guard_state evaluates it for a target.
When_Guard :: struct {
    cond:     string, // the condition text; "" for a final `else`
    expr:     int,    // the compiled condition in Item_Tree.conds; -1 for a final `else`
    start:    int,    // the branch range: the condition (or `else` body) to the end of its body
    end:      int,
    previous: int,    // the earlier branch of the chain, whose condition is false here; -1 when none
    parent:   int,    // the enclosing guard; -1 at file scope
}

// A member of a procedure group: `name`, or `operand.name` when it is qualified.
Group_Member :: struct {
    operand: string, // "" for a bare name
    name:    string,
    offset:  int, // the name
}

// One declaration of a file, or a field or member of one.
Item :: struct {
    name:         string,
    kind:         Item_Kind,
    visibility:   Visibility,
    name_offset:  int,
    start:        int, // the declaration range, attributes included
    end:          int,
    signature:    string, // the declaration head on one line, from the name: "add :: proc(a, b: int) -> int"
    doc:          string, // the `//` lines directly above the declaration, markers stripped; "" when none
    attributes:   []Item_Attribute,
    guard:        int,  // innermost When_Guard; -1 when none
    in_foreign:   bool, // declared in a foreign block
    path:         string, // Import and Foreign_Import: the unquoted path
    path_offset:  int,    // Import and Foreign_Import: the opening quote of the path; -1 when none
    children:     []Item, // struct and bit_field fields, enum members
    members:      []Group_Member, // Proc_Group: the members that are a name or `operand.name`
    type_offset:  int, // the type expression; -1 when absent
    value_offset: int, // the value expression; -1 when absent
    value_index:  int, // the result of a multi-value value the name takes; -1 when the value is its own
}

// The declarations of one file. Proc bodies are not read. Every string is a copy in `arena`.
Item_Tree :: struct {
    arena:          virtual.Arena,
    package_name:   string,
    package_offset: int, // -1 when the file has no package clause
    package_doc:    string, // the `//` lines directly above the package clause, markers stripped
    tags:           []string, // file tags as `#+build ...`; the legacy `//+` form is rewritten to `#+`
    private:        Visibility, // from `#+private` / `#+private file`
    items:          []Item,
    guards:         []When_Guard,
    conds:          []Cond_Expr, // the compiled `when` conditions
}

@(private = "file")
ITEM_ARENA_BLOCK :: 8 * mem.Kilobyte

@(private)
Builder :: struct {
    tree:   ^Item_Tree,
    alloc:  mem.Allocator,
    text:   string,
    guards: [dynamic]When_Guard,
    conds:  [dynamic]Cond_Expr,
    err:    mem.Allocator_Error,
}

// The scope a declaration is found in.
@(private)
Decl_Context :: struct {
    guard:      int,
    in_foreign: bool,
    visibility: Visibility,
}

// The item tree of a parsed file. The tree keeps no reference to `parsed`.
item_tree :: proc(parsed: odinsyntax.Parse, allocator := context.allocator) -> (tree: ^Item_Tree, err: mem.Allocator_Error) {
    tree = new(Item_Tree, allocator) or_return
    if err = virtual.arena_init_growing(&tree.arena, ITEM_ARENA_BLOCK); err != nil {
        free(tree, allocator)
        return nil, err
    }
    tree.package_offset = -1
    if parsed.tree == nil || parsed.tree.root == nil {
        return tree, nil
    }
    b := Builder {
        tree  = tree,
        alloc = virtual.arena_allocator(&tree.arena),
        text  = parsed.tree.text,
    }
    b.guards = make([dynamic]When_Guard, b.alloc)
    b.conds = make([dynamic]Cond_Expr, b.alloc)
    items := make([dynamic]Item, b.alloc)

    root_node := odinsyntax.node_root(parsed.tree)
    root, _ := odinsyntax.as_root(root_node)
    read_header(&b, &root)
    ctx := Decl_Context{guard = -1, visibility = tree.private}
    decls := odinsyntax.root_decls(&root)
    for n in odinsyntax.child_iter_next(&decls) {
        walk_decl(&b, n, ctx, &items)
    }
    tree.items = items[:]
    tree.guards = b.guards[:]
    tree.conds = b.conds[:]
    if b.err != nil {
        item_tree_destroy(tree, allocator)
        return nil, b.err
    }
    return tree, nil
}

item_tree_destroy :: proc(tree: ^Item_Tree, allocator := context.allocator) {
    if tree == nil {
        return
    }
    virtual.arena_destroy(&tree.arena)
    free(tree, allocator)
}

// Reads the package clause and the file tags, legacy `//+` comment tags before the package included.
@(private = "file")
read_header :: proc(b: ^Builder, root: ^odinsyntax.Root) {
    tags := make([dynamic]string, b.alloc)
    if pkg, ok := odinsyntax.root_package(root); ok {
        if name, nok := odinsyntax.package_decl_name(&pkg); nok {
            start, _ := odinsyntax.node_range(odinsyntax.Syntax_Node(name))
            b.tree.package_name = clone(b, odinsyntax.node_text(odinsyntax.Syntax_Node(name)))
            b.tree.package_offset = int(start)
        }
        b.tree.package_doc = doc_above(b, (^odinsyntax.Syntax_Node)(root), pkg.offset)
    }
    offset := root.offset
    for child in odinsyntax.green_children(root.green) {
        child_offset := offset
        offset += odinsyntax.element_len(child)
        tok, is_token := odinsyntax.element_token(child)
        if !is_token {
            n, _ := odinsyntax.element_node(child)
            if n.kind == .File_Tag {
                append_tag(b, &tags, b.text[child_offset:offset])
            } else if n.kind == .Package_Decl {
                break
            }
            continue
        }
        if tok.kind == .Line_Comment {
            text := b.text[child_offset:offset]
            if strings.has_prefix(text, "//+") {
                append_tag(b, &tags, strings.concatenate({"#+", text[3:]}, context.temp_allocator))
            }
        }
    }
    b.tree.tags = tags[:]
    for tag in b.tree.tags {
        name, rest := tag_split(tag)
        if name != "private" {
            continue
        }
        b.tree.private = strings.trim_space(rest) == "file" ? .File : .Package
    }
}

@(private = "file")
append_tag :: proc(b: ^Builder, tags: ^[dynamic]string, text: string) {
    if _, err := append(tags, clone(b, strings.trim_space(text))); err != nil && b.err == nil {
        b.err = err
    }
}

// The name of a `#+name rest` tag and the rest.
tag_split :: proc(tag: string) -> (name, rest: string) {
    body := strings.trim_prefix(tag, "#+")
    end := 0
    for end < len(body) && body[end] != ' ' && body[end] != '\t' {
        end += 1
    }
    return body[:end], body[end:]
}

@(private = "file")
walk_decl :: proc(b: ^Builder, n: odinsyntax.Syntax_Node, ctx: Decl_Context, out: ^[dynamic]Item) {
    n := n
    #partial switch n.green.kind {
    case .Value_Decl:
        add_value_decl(b, &n, ctx, out)
    case .Import_Decl:
        add_import(b, &n, ctx, out)
    case .Foreign_Import_Decl:
        add_foreign_import(b, &n, ctx, out)
    case .Foreign_Block:
        fb, _ := odinsyntax.as_foreign_block(n)
        inner := ctx
        inner.in_foreign = true
        attrs := odinsyntax.foreign_block_attributes(&fb)
        for attr in odinsyntax.child_iter_next(&attrs) {
            attr := attr
            if vis, ok := attribute_visibility(b, &attr); ok {
                inner.visibility = vis
            }
        }
        if body, ok := odinsyntax.foreign_block_body(&fb); ok {
            walk_block(b, odinsyntax.Syntax_Node(body), inner, out)
        }
    case .When_Stmt:
        walk_when(b, n, ctx, -1, out)
    }
}

// Walks the statements of a Block or the one statement of a Do_Body.
@(private = "file")
walk_block :: proc(b: ^Builder, n: odinsyntax.Syntax_Node, ctx: Decl_Context, out: ^[dynamic]Item) {
    n := n
    if blk, ok := odinsyntax.as_block(n); ok {
        stmts := odinsyntax.block_stmts(&blk)
        for s in odinsyntax.child_iter_next(&stmts) {
            walk_decl(b, s, ctx, out)
        }
    } else if body, dok := odinsyntax.as_do_body(n); dok {
        if s, sok := odinsyntax.do_body_stmt(&body); sok {
            walk_decl(b, s, ctx, out)
        }
    }
}

@(private = "file")
walk_when :: proc(b: ^Builder, n: odinsyntax.Syntax_Node, ctx: Decl_Context, previous: int, out: ^[dynamic]Item) {
    w, _ := odinsyntax.as_when_stmt(n)
    guard := When_Guard{expr = -1, previous = previous, parent = ctx.guard}
    guard.start = int(n.offset)
    guard.end = guard.start
    if cond, ok := odinsyntax.when_stmt_cond(&w); ok {
        guard.cond = clone(b, odinsyntax.node_text(cond))
        guard.expr = cond_compile(cond, b.alloc, &b.conds, &b.err)
        guard.start = int(cond.offset)
    }
    body, has_body := odinsyntax.when_stmt_body(&w)
    if has_body {
        _, end := odinsyntax.node_range(body)
        guard.end = int(end)
    }
    index := push_guard(b, guard)
    inner := ctx
    inner.guard = index
    if has_body {
        walk_block(b, body, inner, out)
    }
    other, has_else := odinsyntax.when_stmt_else_branch(&w)
    if !has_else {
        return
    }
    if other.green.kind == .When_Stmt {
        walk_when(b, other, ctx, index, out)
        return
    }
    start, end := odinsyntax.node_range(other)
    inner.guard = push_guard(b, When_Guard{start = int(start), end = int(end), expr = -1, previous = index, parent = ctx.guard})
    walk_block(b, other, inner, out)
}

@(private = "file")
push_guard :: proc(b: ^Builder, guard: When_Guard) -> int {
    if _, err := append(&b.guards, guard); err != nil {
        if b.err == nil {
            b.err = err
        }
        return guard.parent
    }
    return len(b.guards) - 1
}

@(private)
add_value_decl :: proc(b: ^Builder, n: ^odinsyntax.Syntax_Node, ctx: Decl_Context, out: ^[dynamic]Item) {
    v, _ := odinsyntax.as_value_decl(n^)
    start, end := odinsyntax.node_range(n^)
    doc := doc_above(b, n.parent, n.offset)

    vis := ctx.visibility
    attrs := make([dynamic]Item_Attribute, b.alloc)
    attr_iter := odinsyntax.value_decl_attributes(&v)
    for attr in odinsyntax.child_iter_next(&attr_iter) {
        attr := attr
        if av, ok := attribute_visibility(b, &attr); ok {
            vis = av
        }
        read_attributes(b, &attr, &attrs)
    }

    // `::` and `: T :` declare constants; `:` and `:=` declare variables.
    colons := 0
    for child in odinsyntax.green_children(n.green) {
        if tok, ok := odinsyntax.element_token(child); ok && tok.kind == .Colon {
            colons += 1
        }
    }
    constant := colons >= 2
    type_offset := -1
    if type, ok := odinsyntax.value_decl_type(&v); ok {
        type_offset = int(type.offset)
    }

    names := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
    if name_list, ok := odinsyntax.value_decl_names(&v); ok {
        it := odinsyntax.name_list_names(&name_list)
        for name in odinsyntax.child_iter_next(&it) {
            append(&names, name)
        }
    }

    for &name in names {
        if name.green.kind != .Ident {
            continue
        }
        value, result, has_value := decl_value(n, int(name.offset))
        item := Item {
            name         = clone(b, odinsyntax.node_text(name)),
            kind         = .Var,
            visibility   = vis,
            name_offset  = int(name.offset),
            start        = int(start),
            end          = int(end),
            doc          = doc,
            attributes   = attrs[:],
            guard        = ctx.guard,
            in_foreign   = ctx.in_foreign,
            type_offset  = type_offset,
            value_offset = -1,
            value_index  = result,
        }
        cut := end
        if has_value {
            item.value_offset = int(value.offset)
            cut = value_cut(value, end)
            if constant {
                item.kind = classify(value)
                item.children = read_children(b, value)
                if item.kind == .Proc_Group {
                    item.members = read_members(b, value)
                }
            }
        } else if constant {
            item.kind = .Const
        }
        item.signature = token_text(b, n^, name.offset, cut)
        if _, err := append(out, item); err != nil && b.err == nil {
            b.err = err
        }
    }
}

@(private = "file")
add_import :: proc(b: ^Builder, n: ^odinsyntax.Syntax_Node, ctx: Decl_Context, out: ^[dynamic]Item) {
    imp, _ := odinsyntax.as_import_decl(n^)
    start, end := odinsyntax.node_range(n^)
    item := Item {
        kind         = .Import,
        visibility   = .File,
        start        = int(start),
        end          = int(end),
        guard        = ctx.guard,
        signature    = token_text(b, n^, start, end),
        doc          = doc_above(b, n.parent, n.offset),
        path_offset  = -1,
        type_offset  = -1,
        value_offset = -1,
        value_index  = -1,
    }
    path_tok, has_path := odinsyntax.import_decl_path(&imp)
    if has_path {
        item.path = clone(b, unquote(odinsyntax.syntax_token_text(path_tok)))
        item.path_offset = int(path_tok.offset)
        item.name_offset = int(path_tok.offset)
        item.name = clone(b, import_name(unquote(odinsyntax.syntax_token_text(path_tok))))
    }
    if alias, ok := odinsyntax.import_decl_alias(&imp); ok {
        item.name = clone(b, odinsyntax.node_text(odinsyntax.Syntax_Node(alias)))
        item.name_offset = int(alias.offset)
    }
    if item.name == "" {
        return
    }
    if _, err := append(out, item); err != nil && b.err == nil {
        b.err = err
    }
}

@(private = "file")
add_foreign_import :: proc(b: ^Builder, n: ^odinsyntax.Syntax_Node, ctx: Decl_Context, out: ^[dynamic]Item) {
    imp, _ := odinsyntax.as_foreign_import_decl(n^)
    start, end := odinsyntax.node_range(n^)
    name, ok := odinsyntax.foreign_import_decl_name(&imp)
    if !ok {
        return
    }
    item := Item {
        name         = clone(b, odinsyntax.node_text(odinsyntax.Syntax_Node(name))),
        kind         = .Foreign_Import,
        visibility   = .File,
        name_offset  = int(name.offset),
        start        = int(start),
        end          = int(end),
        guard        = ctx.guard,
        signature    = token_text(b, n^, start, end),
        doc          = doc_above(b, n.parent, n.offset),
        path_offset  = -1,
        type_offset  = -1,
        value_offset = -1,
        value_index  = -1,
    }
    if tok, tok_ok := odinsyntax.foreign_import_decl_path(&imp); tok_ok {
        item.path = clone(b, unquote(odinsyntax.syntax_token_text(tok)))
        item.path_offset = int(tok.offset)
    } else {
        paths := odinsyntax.foreign_import_decl_paths(&imp)
        if first, first_ok := odinsyntax.child_iter_next(&paths); first_ok {
            item.path = clone(b, unquote(strings.trim_space(odinsyntax.node_text(first))))
            first_start, _ := odinsyntax.node_range(first)
            item.path_offset = int(first_start)
        }
    }
    if _, err := append(out, item); err != nil && b.err == nil {
        b.err = err
    }
}

// The visibility a `private` attribute element sets, if the attribute has one.
@(private = "file")
attribute_visibility :: proc(b: ^Builder, attr: ^odinsyntax.Syntax_Node) -> (vis: Visibility, found: bool) {
    a, _ := odinsyntax.as_attribute(attr^)
    elems := odinsyntax.attribute_elems(&a)
    for elem in odinsyntax.child_iter_next(&elems) {
        name, value := attribute_element(elem)
        if name != "private" {
            continue
        }
        found = true
        vis = unquote(value) == "file" ? .File : .Package
    }
    return
}

@(private = "file")
read_attributes :: proc(b: ^Builder, attr: ^odinsyntax.Syntax_Node, out: ^[dynamic]Item_Attribute) {
    a, _ := odinsyntax.as_attribute(attr^)
    elems := odinsyntax.attribute_elems(&a)
    for elem in odinsyntax.child_iter_next(&elems) {
        name, value := attribute_element(elem)
        if name == "" {
            continue
        }
        if _, err := append(out, Item_Attribute{clone(b, name), clone(b, value)}); err != nil && b.err == nil {
            b.err = err
        }
    }
}

// The name and value text of one attribute element.
@(private = "file")
attribute_element :: proc(elem: odinsyntax.Syntax_Node) -> (name, value: string) {
    elem := elem
    if elem.green.kind == .Ident {
        return odinsyntax.node_text(elem), ""
    }
    fv, ok := odinsyntax.as_field_value(elem)
    if !ok {
        return "", ""
    }
    if n, nok := odinsyntax.field_value_name(&fv); nok {
        name = odinsyntax.node_text(n)
    }
    if v, vok := odinsyntax.field_value_value(&fv); vok {
        value = odinsyntax.node_text(v)
    }
    return
}

// The kind a constant declaration has from its value.
@(private = "file")
classify :: proc(value: odinsyntax.Syntax_Node) -> Item_Kind {
    value := value
    #partial switch value.green.kind {
    case .Proc_Lit:
        return .Proc
    case .Proc_Group:
        return .Proc_Group
    case .Struct_Type:
        return .Struct
    case .Enum_Type:
        return .Enum
    case .Union_Type:
        return .Union
    case .Bit_Set_Type:
        return .Bit_Set
    case .Bit_Field_Type:
        return .Bit_Field
    case .Distinct_Type:
        d, _ := odinsyntax.as_distinct_type(value)
        if inner, ok := odinsyntax.distinct_type_type(&d); ok {
            kind := classify(inner)
            return kind == .Const ? .Type : kind
        }
        return .Type
    case .Tag_Expr:
        t, _ := odinsyntax.as_tag_expr(value)
        if inner, ok := odinsyntax.tag_expr_expr(&t); ok && inner.green.kind in odinsyntax.KINDS_TYPE {
            return classify(inner)
        }
        if inner, ok := odinsyntax.tag_expr_expr(&t); ok && inner.green.kind == .Proc_Lit {
            return .Proc
        }
        return .Const
    case .Ident:
        if is_builtin_type(odinsyntax.node_text(value)) {
            return .Type
        }
        return .Const
    }
    if value.green.kind in odinsyntax.KINDS_TYPE {
        return .Type
    }
    return .Const
}

@(private = "file")
is_builtin_type :: proc(name: string) -> bool {
    switch name {
    case "bool", "b8", "b16", "b32", "b64",
         "int", "i8", "i16", "i32", "i64", "i128",
         "uint", "u8", "u16", "u32", "u64", "u128", "uintptr",
         "i16le", "i32le", "i64le", "i128le", "u16le", "u32le", "u64le", "u128le",
         "i16be", "i32be", "i64be", "i128be", "u16be", "u32be", "u64be", "u128be",
         "f16", "f32", "f64", "f16le", "f32le", "f64le", "f16be", "f32be", "f64be",
         "complex32", "complex64", "complex128",
         "quaternion64", "quaternion128", "quaternion256",
         "rune", "string", "cstring", "string16", "cstring16", "rawptr", "typeid", "any":
        return true
    }
    return false
}

// Where the one-line signature of a declaration stops: before a body, a member list or a literal.
@(private = "file")
value_cut :: proc(value: odinsyntax.Syntax_Node, decl_end: u32) -> u32 {
    value := value
    #partial switch value.green.kind {
    case .Proc_Lit:
        p, _ := odinsyntax.as_proc_lit(value)
        cut := decl_end
        if pt, ok := odinsyntax.proc_lit_type(&p); ok {
            _, cut = odinsyntax.node_range(odinsyntax.Syntax_Node(pt))
        }
        if wc, ok := odinsyntax.proc_lit_where_clause(&p); ok {
            _, cut = odinsyntax.node_range(odinsyntax.Syntax_Node(wc))
        }
        return cut
    case .Proc_Group:
        return decl_end
    case .Struct_Type:
        s, _ := odinsyntax.as_struct_type(value)
        if fields, ok := odinsyntax.struct_type_fields(&s); ok {
            return fields.offset
        }
    case .Enum_Type, .Union_Type, .Bit_Field_Type, .Comp_Lit:
        if brace, ok := direct_token_offset(value, .Open_Brace); ok {
            return brace
        }
    case .Distinct_Type:
        d, _ := odinsyntax.as_distinct_type(value)
        if inner, ok := odinsyntax.distinct_type_type(&d); ok {
            return value_cut(inner, decl_end)
        }
    case .Tag_Expr:
        t, _ := odinsyntax.as_tag_expr(value)
        if inner, ok := odinsyntax.tag_expr_expr(&t); ok {
            return value_cut(inner, decl_end)
        }
    }
    _, end := odinsyntax.node_range(value)
    return min(end, decl_end)
}

@(private = "file")
direct_token_offset :: proc(n: odinsyntax.Syntax_Node, kind: odinsyntax.Token_Kind) -> (u32, bool) {
    offset := n.offset
    for child in odinsyntax.green_children(n.green) {
        if tok, ok := odinsyntax.element_token(child); ok && tok.kind == kind {
            return offset, true
        }
        offset += odinsyntax.element_len(child)
    }
    return 0, false
}

// The fields of a struct or bit_field and the members of an enum, through `distinct`.
@(private = "file")
read_children :: proc(b: ^Builder, value: odinsyntax.Syntax_Node) -> []Item {
    value := value
    out := make([dynamic]Item, b.alloc)
    #partial switch value.green.kind {
    case .Distinct_Type:
        d, _ := odinsyntax.as_distinct_type(value)
        if inner, ok := odinsyntax.distinct_type_type(&d); ok {
            return read_children(b, inner)
        }
    case .Struct_Type:
        s, _ := odinsyntax.as_struct_type(value)
        list, ok := odinsyntax.struct_type_fields(&s)
        if !ok {
            break
        }
        fields := odinsyntax.field_list_fields(&list)
        for field in odinsyntax.child_iter_next(&fields) {
            field := field
            f, _ := odinsyntax.as_field(field)
            names, nok := odinsyntax.field_names(&f)
            if !nok {
                continue
            }
            _, end := odinsyntax.node_range(field)
            type_offset := -1
            if type, tok := odinsyntax.field_type(&f); tok {
                type_offset = int(type.offset)
            }
            it := odinsyntax.name_list_names(&names)
            for name in odinsyntax.child_iter_next(&it) {
                if name.green.kind == .Ident {
                    push_child(b, &out, .Field, field, name, end, type_offset, -1)
                }
            }
        }
    case .Bit_Field_Type:
        bf, _ := odinsyntax.as_bit_field_type(value)
        fields := odinsyntax.bit_field_type_fields(&bf)
        for field in odinsyntax.child_iter_next(&fields) {
            field := field
            f, _ := odinsyntax.as_bit_field_field(field)
            if name, ok := odinsyntax.bit_field_field_name(&f); ok {
                _, end := odinsyntax.node_range(field)
                type_offset := -1
                if type, tok := odinsyntax.bit_field_field_type(&f); tok {
                    type_offset = int(type.offset)
                }
                push_child(b, &out, .Field, field, odinsyntax.Syntax_Node(name), end, type_offset, -1)
            }
        }
    case .Enum_Type:
        e, _ := odinsyntax.as_enum_type(value)
        members := odinsyntax.enum_type_members(&e)
        for member in odinsyntax.child_iter_next(&members) {
            member := member
            _, end := odinsyntax.node_range(member)
            if member.green.kind == .Ident {
                push_child(b, &out, .Enum_Member, member, member, end, -1, -1)
            } else if fv, ok := odinsyntax.as_field_value(member); ok {
                if name, nok := odinsyntax.field_value_name(&fv); nok && name.green.kind == .Ident {
                    value_offset := -1
                    if v, vok := odinsyntax.field_value_value(&fv); vok {
                        value_offset = int(v.offset)
                    }
                    push_child(b, &out, .Enum_Member, member, name, end, -1, value_offset)
                }
            }
        }
    }
    return out[:]
}

// The members of a procedure group that are a name or `operand.name`; other expressions are skipped.
@(private = "file")
read_members :: proc(b: ^Builder, value: odinsyntax.Syntax_Node) -> []Group_Member {
    out := make([dynamic]Group_Member, b.alloc)
    group, ok := odinsyntax.as_proc_group(value)
    if !ok {
        return out[:]
    }
    it := odinsyntax.proc_group_members(&group)
    for member in odinsyntax.child_iter_next(&it) {
        m := Group_Member{offset = int(member.offset)}
        #partial switch member.green.kind {
        case .Ident:
            m.name = clone(b, odinsyntax.node_text(member))
        case .Selector_Expr:
            sel, _ := odinsyntax.as_selector_expr(member)
            operand, has_operand := odinsyntax.selector_expr_operand(&sel)
            field, has_field := odinsyntax.selector_expr_field(&sel)
            if !has_operand || !has_field || operand.green.kind != .Ident {
                continue
            }
            m.operand = clone(b, odinsyntax.node_text(operand))
            m.name = clone(b, odinsyntax.node_text(odinsyntax.Syntax_Node(field)))
            m.offset = int(field.offset)
        case:
            continue
        }
        if _, err := append(&out, m); err != nil && b.err == nil {
            b.err = err
        }
    }
    return out[:]
}

@(private = "file")
push_child :: proc(b: ^Builder, out: ^[dynamic]Item, kind: Item_Kind, decl, name: odinsyntax.Syntax_Node, end: u32, type_offset, value_offset: int) {
    start, _ := odinsyntax.node_range(decl)
    item := Item {
        name         = clone(b, odinsyntax.node_text(name)),
        kind         = kind,
        name_offset  = int(name.offset),
        start        = int(start),
        end          = int(end),
        guard        = -1,
        signature    = token_text(b, decl, name.offset, end),
        doc          = doc_above(b, decl.parent, decl.offset),
        type_offset  = type_offset,
        value_offset = value_offset,
        value_index  = -1,
    }
    if _, err := append(out, item); err != nil && b.err == nil {
        b.err = err
    }
}

// The run of `//` lines directly above the child of `parent` at `offset`, read from the trivia of
// `parent`: `//` and one space stripped, lines joined with "\n". A blank line, a trailing comment
// or a `//+` tag ends the run.
@(private = "file")
doc_above :: proc(b: ^Builder, parent: ^odinsyntax.Syntax_Node, offset: u32) -> string {
    if parent == nil || parent.green == nil {
        return ""
    }
    kids := odinsyntax.green_children(parent.green)
    index := -1
    pos := parent.offset
    for child, i in kids {
        if _, is_node := odinsyntax.element_node(child); is_node && pos == offset {
            index = i
            break
        }
        pos += odinsyntax.element_len(child)
        if pos > offset {
            break
        }
    }
    if index < 0 {
        return ""
    }
    lines := make([dynamic]string, context.temp_allocator)
    newlines := 0
    end := offset
    scan: for i := index - 1; i >= 0; i -= 1 {
        tok, is_token := odinsyntax.element_token(kids[i])
        if !is_token {
            break
        }
        start := end - tok.len
        #partial switch tok.kind {
        case .Whitespace:
        case .Newline:
            newlines += 1
            if newlines > 1 {
                break scan
            }
        case .Line_Comment:
            text := b.text[start:end]
            if newlines != 1 || !strings.has_prefix(text, "//") || strings.has_prefix(text, "//+") || !starts_line(b.text, int(start)) {
                break scan
            }
            append(&lines, text)
            newlines = 0
        case:
            break scan
        }
        end = start
    }
    if len(lines) == 0 {
        return ""
    }
    sb := strings.builder_make(context.temp_allocator)
    for i := len(lines) - 1; i >= 0; i -= 1 {
        line := strings.trim_prefix(lines[i][2:], " ")
        strings.write_string(&sb, strings.trim_right(line, "\r"))
        if i > 0 {
            strings.write_byte(&sb, '\n')
        }
    }
    return clone(b, strings.to_string(sb))
}

// True when only spaces and tabs come before `offset` on its line.
@(private = "file")
starts_line :: proc(text: string, offset: int) -> bool {
    for i := offset - 1; i >= 0; i -= 1 {
        switch text[i] {
        case ' ', '\t':
        case '\n':
            return true
        case:
            return false
        }
    }
    return true
}

// The tokens of `n` in [lo, hi) on one line: comments dropped, each run of trivia one space.
@(private = "file")
token_text :: proc(b: ^Builder, n: odinsyntax.Syntax_Node, lo, hi: u32) -> string {
    sb := strings.builder_make(context.temp_allocator)
    space := false
    write_tokens(&sb, b.text, n.green, n.offset, lo, hi, &space)
    return clone(b, strings.to_string(sb))
}

@(private = "file")
write_tokens :: proc(sb: ^strings.Builder, text: string, node: ^odinsyntax.Green_Node, offset, lo, hi: u32, space: ^bool) {
    pos := offset
    for child in odinsyntax.green_children(node) {
        child_len := odinsyntax.element_len(child)
        child_pos := pos
        pos += child_len
        if pos <= lo {
            continue
        }
        if child_pos >= hi {
            return
        }
        if n, is_node := odinsyntax.element_node(child); is_node {
            write_tokens(sb, text, n, child_pos, lo, hi, space)
            continue
        }
        tok, _ := odinsyntax.element_token(child)
        if odinsyntax.token_is_trivia(tok.kind) {
            space^ = strings.builder_len(sb^) > 0
            continue
        }
        if child_len == 0 {
            continue
        }
        if space^ {
            strings.write_byte(sb, ' ')
            space^ = false
        }
        strings.write_string(sb, text[child_pos:pos])
    }
}

// The name an import is known by without an alias: the last element of its path.
import_name :: proc(path: string) -> string {
    name := path
    if i := strings.last_index_byte(name, ':'); i >= 0 {
        name = name[i + 1:]
    }
    name = strings.trim_right(name, "/\\")
    if i := strings.last_index_any(name, "/\\"); i >= 0 {
        name = name[i + 1:]
    }
    return name
}

// `s` without its enclosing quotes or backquotes.
unquote :: proc(s: string) -> string {
    if len(s) >= 2 && (s[0] == '"' || s[0] == '`') && s[len(s) - 1] == s[0] {
        return s[1:len(s) - 1]
    }
    return s
}

@(private = "file")
clone :: proc(b: ^Builder, s: string) -> string {
    if s == "" {
        return ""
    }
    out, err := strings.clone(s, b.alloc)
    if err != nil && b.err == nil {
        b.err = err
    }
    return out
}
