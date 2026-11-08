package odinsema

import "core:mem"
import "core:slice"
import "core:strings"

import odinsyntax "../syntax"

// A pointer dereference or a call of a procedure value whose operand is nil on every path to it.
// `name` borrows the text of the parse.
Nil_Use :: struct {
    offset:  int, // the identifier
    name:    string,
    is_call: bool,
}

@(private = "file")
Nil_Kind :: enum u8 {
    Nil,   // the place is nil: declared with no value, or set to `nil`
    Reset, // the place gets some other value
    Deref, // the place is dereferenced, indexed or called
}

@(private = "file")
Nil_Event :: struct {
    kind:    Nil_Kind,
    local:   int, // index into Nil_Walk.cands
    offset:  int,
    is_call: bool,
}

@(private = "file")
Nil_Type :: enum u8 {
    None,
    Pointer,
    Multi, // `[^]T`: indexing dereferences it
    Proc,
}

// A place the analysis follows: a local, or a field chain of a local record held by value.
@(private = "file")
Nil_Cand :: struct {
    name:     string, // as written: `p`, `s.cb`
    root:     int,    // the name offset of the declaration of the local
    path:     string, // "" for the local, else `.a.b`
    is_proc:  bool,   // a procedure value: its use is a call
    multi:    bool,   // a `[^]T`
    to_array: bool,   // a pointer to a fixed array: `p[i]` dereferences it
}

// A fact a condition gives about a place when it is true or false.
@(private = "file")
Nil_Fact :: struct {
    local:  int,
    is_nil: bool,
}

@(private = "file")
Nil_Walk :: struct {
    c:           ^Checker,
    file:        File_Id,
    refs:        [dynamic]Name_Ref,
    locals:      map[int]bool,         // the name offsets of the plain variables of the body
    cands:       [dynamic]Nil_Cand,
    places:      map[string]int,       // `<root offset><path>` to a candidate
    root_places: map[int][dynamic]int, // the candidates of a local
    root_skip:   map[int]bool,         // locals the analysis cannot follow
    handled:     map[u32]bool,         // the operator offsets of the comparisons a condition narrows by
    guard:       [dynamic]Nil_Fact,    // what holds while the right operand of `&&` or `||` runs
}

// The dereferences of the pointers and the calls of the procedure values of the procedure literal
// `lit` that are nil on every path to them. A local, or a field chain of a record local held by
// value, is followed from its declaration with no value or with `nil` through plain assignments.
// A branch on `x == nil` or `x != nil` narrows it, through `!`, `&&` and `||`. A local whose address
// is taken, that is compared in any other way, that has attributes or that `using` names is left
// out, since a path that tests it may rule the nil out.
nil_deref :: proc(c: ^Checker, file: File_Id, m: ^Scope_Map, lit: odinsyntax.Syntax_Node, allocator := context.allocator) -> (out: [dynamic]Nil_Use, err: mem.Allocator_Error) {
    out = make([dynamic]Nil_Use, allocator) or_return
    pl, is_lit := odinsyntax.as_proc_lit(lit)
    if !is_lit || m == nil {
        return
    }
    body, has_body := odinsyntax.proc_lit_body(&pl)
    if !has_body {
        return
    }
    lit_start, lit_end := odinsyntax.node_range(lit)
    depth := -1
    for s in m.scopes {
        if s.start == int(lit_start) && s.end == int(lit_end) {
            depth = s.proc_depth
            break
        }
    }
    if depth < 0 {
        return
    }
    alloc := context.temp_allocator
    w := Nil_Walk {
        c           = c,
        file        = file,
        refs        = make([dynamic]Name_Ref, alloc),
        locals      = make(map[int]bool, alloc),
        cands       = make([dynamic]Nil_Cand, alloc),
        places      = make(map[string]int, alloc),
        root_places = make(map[int][dynamic]int, alloc),
        root_skip   = make(map[int]bool, alloc),
        handled     = make(map[u32]bool, alloc),
        guard       = make([dynamic]Nil_Fact, alloc),
    }
    in_lit := locals_between(m, int(lit_start), int(lit_end), alloc)
    for li in in_lit {
        l := m.locals[li]
        if l.kind == .Var && !l.is_using && m.scopes[l.scope].proc_depth == depth {
            w.locals[l.name_offset] = true
        }
    }
    if len(w.locals) == 0 {
        return
    }
    for ri in refs_between(m, int(lit_start), int(lit_end)) {
        r := m.refs[ri]
        if r.kind == .Local {
            append(&w.refs, r) or_return
        }
    }
    slice.sort_by(w.refs[:], proc(a, b: Name_Ref) -> bool {return a.start < b.start})
    for li in in_lit {
        l := m.locals[li]
        if w.locals[l.name_offset] {
            t := decl_type(w.c, local_symbol(w.file, l.name_offset))
            kind, to_array := nil_type_kind(w.c, t)
            if kind == .None {
                continue
            }
            add_cand(&w, Nil_Cand{name = l.name, root = l.name_offset, is_proc = kind == .Proc, multi = kind == .Multi, to_array = to_array}) or_return
        }
    }
    collect_places(&w, body) or_return
    if len(w.cands) == 0 {
        return
    }
    mark_conditions(&w, body)
    exclude_tested(&w, body)
    nil_flow(&w, lit, &out) or_return
    slice.sort_by(out[:], proc(a, b: Nil_Use) -> bool {return a.offset < b.offset})
    return
}

@(private = "file")
add_cand :: proc(w: ^Nil_Walk, cand: Nil_Cand) -> mem.Allocator_Error {
    index := len(w.cands)
    append(&w.cands, cand) or_return
    w.places[place_key(cand.root, cand.path)] = index
    if cand.root not_in w.root_places {
        w.root_places[cand.root] = make([dynamic]int, w.root_places.allocator)
    }
    list := &w.root_places[cand.root]
    append(list, index) or_return
    return nil
}

@(private)
place_key :: proc(root: int, path: string) -> string {
    sb := strings.builder_make(context.temp_allocator)
    strings.write_int(&sb, root)
    strings.write_string(&sb, path)
    return strings.to_string(sb)
}

// Whether the type `t` is a pointer, a multi-pointer or a procedure value, and whether a pointer
// points at a fixed array.
@(private = "file")
nil_type_kind :: proc(c: ^Checker, t: Type_Id) -> (kind: Nil_Type, to_array: bool) {
    if t == INVALID_TYPE {
        return
    }
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Pointer_Type:
        _, to_array = type_get(&c.table, type_base(&c.table, v.elem)).(Array_Type)
        return .Pointer, to_array
    case Multi_Pointer_Type:
        return .Multi, false
    case Proc_Type:
        return .Proc, false
    }
    return
}

// Registers the field chains `s.a.cb` of the records held by value in the body that are pointers,
// multi-pointers or procedure values. A record with a `using` or `#subtype` field, or a raw union,
// is left out, since a name may then reach one field by two paths.
@(private = "file")
collect_places :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node) -> mem.Allocator_Error {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit:
        return nil
    case .Selector_Expr:
        register_place(w, n) or_return
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        collect_places(w, child) or_return
    }
    return nil
}

// The root identifier and the path `.a.b` of the plain selector chain `n`. Not for `->`.
@(private)
flatten_place :: proc(n: odinsyntax.Syntax_Node) -> (root: odinsyntax.Syntax_Node, path: string, ok: bool) {
    names := make([dynamic]string, context.temp_allocator)
    cur := strip_parens(n)
    for {
        #partial switch cur.green.kind {
        case .Selector_Expr:
            se, _ := odinsyntax.as_selector_expr(cur)
            if _, arrow := odinsyntax.selector_expr_arrow(&se); arrow {
                return
            }
            field := odinsyntax.selector_expr_field(&se) or_return
            append(&names, odinsyntax.node_text(odinsyntax.Syntax_Node(field)))
            cur = strip_parens(odinsyntax.selector_expr_operand(&se) or_return)
        case .Ident:
            sb := strings.builder_make(context.temp_allocator)
            #reverse for name in names {
                strings.write_byte(&sb, '.')
                strings.write_string(&sb, name)
            }
            return cur, strings.to_string(sb), true
        case:
            return
        }
    }
}

// The type of the field chain `.a.b` of a record held by value of type `t`. False when a step is
// not a plain field: the record has a `using` or `#subtype` field, or it is a raw union.
@(private)
path_type :: proc(c: ^Checker, t: Type_Id, path: string) -> (Type_Id, bool) {
    t := t
    rest := path
    for len(rest) > 0 {
        st, is_struct := type_get(&c.table, type_base(&c.table, t)).(Struct_Type)
        if !is_struct || .Raw_Union in st.flags {
            return INVALID_TYPE, false
        }
        for f in st.fields {
            if f.is_using || f.is_subtype {
                return INVALID_TYPE, false
            }
        }
        rest = rest[1:]
        end := strings.index_byte(rest, '.')
        name := rest if end < 0 else rest[:end]
        rest = "" if end < 0 else rest[end:]
        next := INVALID_TYPE
        for f in st.fields {
            if f.name == name {
                next = f.type
                break
            }
        }
        if next == INVALID_TYPE {
            return INVALID_TYPE, false
        }
        t = next
    }
    return t, true
}

@(private = "file")
register_place :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node) -> mem.Allocator_Error {
    root, path, ok := flatten_place(n)
    if !ok || path == "" {
        return nil
    }
    r, found := nil_ref(w, int(root.offset))
    if !found || r.is_decl || !w.locals[r.decl] {
        return nil
    }
    if place_key(r.decl, path) in w.places {
        return nil
    }
    t, typed := path_type(w.c, decl_type(w.c, local_symbol(w.file, r.decl)), path)
    if !typed {
        return nil
    }
    kind, to_array := nil_type_kind(w.c, t)
    if kind == .None {
        return nil
    }
    name := strings.concatenate({odinsyntax.node_text(root), path}, context.temp_allocator)
    return add_cand(w, Nil_Cand{name = name, root = r.decl, path = path, is_proc = kind == .Proc, multi = kind == .Multi, to_array = to_array})
}

@(private = "file")
nil_ref :: proc(w: ^Nil_Walk, start: int) -> (Name_Ref, bool) {
    return ref_lookup(w.refs[:], start)
}

// The reference that starts at `start` in `refs`, which is sorted by start.
@(private)
ref_lookup :: proc(refs: []Name_Ref, start: int) -> (Name_Ref, bool) {
    i, found := slice.binary_search_by(refs, start, proc(r: Name_Ref, s: int) -> slice.Ordering {return slice.cmp(r.start, s)})
    if !found {
        return {}, false
    }
    return refs[i], true
}

// The candidate the place `n` names: a local or a field chain. A declaration is not a use.
@(private = "file")
nil_cand :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node) -> (int, bool) {
    inner := strip_parens(n)
    if inner.green.kind != .Ident && inner.green.kind != .Selector_Expr {
        return 0, false
    }
    root, path, ok := flatten_place(inner)
    if !ok {
        return 0, false
    }
    r, found := nil_ref(w, int(root.offset))
    if !found || r.is_decl {
        return 0, false
    }
    index, is_cand := w.places[place_key(r.decl, path)]
    return index, is_cand
}

@(private)
strip_parens :: proc(n: odinsyntax.Syntax_Node) -> odinsyntax.Syntax_Node {
    n := n
    for n.green.kind == .Paren_Expr {
        pe, _ := odinsyntax.as_paren_expr(n)
        inner, ok := odinsyntax.paren_expr_expr(&pe)
        if !ok {
            break
        }
        n = inner
    }
    return n
}

@(private)
nil_items :: proc(list: odinsyntax.Expr_List) -> [dynamic]odinsyntax.Syntax_Node {
    list := list
    out := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
    it := odinsyntax.expr_list_items(&list)
    for item in odinsyntax.child_iter_next(&it) {
        append(&out, item)
    }
    return out
}

// True when `n` is the identifier `nil`.
@(private = "file")
is_nil_literal :: proc(n: odinsyntax.Syntax_Node) -> bool {
    inner := strip_parens(n)
    return (inner.green.kind == .Ident || inner.green.kind == .Literal) && odinsyntax.node_text(inner) == "nil"
}

// True when `n` is a composite literal with no element: `{}` or `T{}`.
@(private)
is_empty_comp_lit :: proc(n: odinsyntax.Syntax_Node) -> bool {
    inner := strip_parens(n)
    if inner.green.kind != .Comp_Lit {
        return false
    }
    cl, _ := odinsyntax.as_comp_lit(inner)
    elems := odinsyntax.comp_lit_elems(&cl)
    _, has := odinsyntax.child_iter_next(&elems)
    return !has
}

// The place compared with `nil` by the comparison `b`, and whether the operator is `==`.
@(private = "file")
nil_compare :: proc(w: ^Nil_Walk, b: odinsyntax.Binary_Expr) -> (cand: int, is_eq: bool, ok: bool) {
    b := b
    op := odinsyntax.binary_expr_op(&b) or_return
    if op.green.kind != .Cmp_Eq && op.green.kind != .Not_Eq {
        return
    }
    lhs := odinsyntax.binary_expr_lhs(&b) or_return
    rhs := odinsyntax.binary_expr_rhs(&b) or_return
    place := lhs
    switch {
    case is_nil_literal(rhs):
    case is_nil_literal(lhs):
        place = rhs
    case:
        return
    }
    cand = nil_cand(w, place) or_return
    return cand, op.green.kind == .Cmp_Eq, true
}

// Appends what holds when the condition `n` has the value `truth`: the places it proves nil or not
// nil, through `!`, `&&` and `||`.
@(private = "file")
cond_facts :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node, truth: bool, out: ^[dynamic]Nil_Fact) {
    n := n
    n = strip_parens(n)
    #partial switch n.green.kind {
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        if op, ok := odinsyntax.unary_expr_op(&u); ok && op.green.kind == .Not {
            if operand, has := odinsyntax.unary_expr_operand(&u); has {
                cond_facts(w, operand, !truth, out)
            }
        }
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(n)
        op, has_op := odinsyntax.binary_expr_op(&b)
        if !has_op {
            return
        }
        #partial switch op.green.kind {
        case .Cmp_And, .Cmp_Or:
            if truth == (op.green.kind == .Cmp_And) {
                if lhs, ok := odinsyntax.binary_expr_lhs(&b); ok {
                    cond_facts(w, lhs, truth, out)
                }
                if rhs, ok := odinsyntax.binary_expr_rhs(&b); ok {
                    cond_facts(w, rhs, truth, out)
                }
            }
        case .Cmp_Eq, .Not_Eq:
            if cand, is_eq, ok := nil_compare(w, b); ok {
                append(out, Nil_Fact{cand, is_eq == truth})
            }
        }
    }
}

// Notes the comparisons that sit on the `!`, `&&` and `||` spine of an `if` or `for` condition.
// The graph narrows by them, so they do not exclude their place. A `defer` body is not walked: it
// runs as one step, with no branch.
@(private = "file")
mark_conditions :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node) {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit, .Defer_Stmt:
        return
    case .If_Stmt:
        is, _ := odinsyntax.as_if_stmt(n)
        if cond, ok := odinsyntax.if_stmt_cond(&is); ok {
            mark_spine(w, cond)
        }
    case .For_Stmt:
        fs, _ := odinsyntax.as_for_stmt(n)
        if cond, ok := odinsyntax.for_stmt_cond(&fs); ok {
            mark_spine(w, cond)
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        mark_conditions(w, child)
    }
}

@(private = "file")
mark_spine :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node) {
    n := n
    n = strip_parens(n)
    #partial switch n.green.kind {
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        if op, ok := odinsyntax.unary_expr_op(&u); ok && op.green.kind == .Not {
            if operand, has := odinsyntax.unary_expr_operand(&u); has {
                mark_spine(w, operand)
            }
        }
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(n)
        op, has_op := odinsyntax.binary_expr_op(&b)
        if !has_op {
            return
        }
        #partial switch op.green.kind {
        case .Cmp_And, .Cmp_Or:
            if lhs, ok := odinsyntax.binary_expr_lhs(&b); ok {
                mark_spine(w, lhs)
            }
            if rhs, ok := odinsyntax.binary_expr_rhs(&b); ok {
                mark_spine(w, rhs)
            }
        case .Cmp_Eq, .Not_Eq:
            if _, _, ok := nil_compare(w, b); ok {
                w.handled[op.offset] = true
            }
        }
    }
}

// Marks the locals the analysis cannot follow: one whose address is taken, one a `->` call passes on, one that a comparison
// other than a branch on nil, a `using` or a declaration with attributes names.
@(private = "file")
exclude_tested :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node) {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit:
        return
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        if op, ok := odinsyntax.unary_expr_op(&u); ok && op.green.kind == .And {
            if operand, has := odinsyntax.unary_expr_operand(&u); has {
                exclude_root(w, operand, true)
            }
        }
    case .Slice_Expr:
        se, _ := odinsyntax.as_slice_expr(n)
        if operand, ok := odinsyntax.slice_expr_operand(&se); ok {
            exclude_root(w, operand, true)
        }
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(n)
        if op, ok := odinsyntax.binary_expr_op(&b); ok && (op.green.kind == .Cmp_Eq || op.green.kind == .Not_Eq) && !w.handled[op.offset] {
            if lhs, has := odinsyntax.binary_expr_lhs(&b); has {
                exclude_root(w, lhs, false)
            }
            if rhs, has := odinsyntax.binary_expr_rhs(&b); has {
                exclude_root(w, rhs, false)
            }
        }
    case .Selector_Expr:
        se, _ := odinsyntax.as_selector_expr(n)
        if _, arrow := odinsyntax.selector_expr_arrow(&se); arrow {
            if operand, ok := odinsyntax.selector_expr_operand(&se); ok {
                exclude_root(w, operand, true)
            }
        }
    case .Using_Stmt:
        us, _ := odinsyntax.as_using_stmt(n)
        if exprs, ok := odinsyntax.using_stmt_exprs(&us); ok {
            for item in nil_items(exprs) {
                exclude_root(w, item, true)
            }
        }
    case .Value_Decl:
        v, _ := odinsyntax.as_value_decl(n)
        attrs := odinsyntax.value_decl_attributes(&v)
        if _, has_attrs := odinsyntax.child_iter_next(&attrs); has_attrs {
            if names, ok := odinsyntax.value_decl_names(&v); ok {
                it := odinsyntax.name_list_names(&names)
                for name in odinsyntax.child_iter_next(&it) {
                    w.root_skip[int(name.offset)] = true
                }
            }
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        exclude_tested(w, child)
    }
}

// Excludes the local at the root of the place `n`: `x`, `x.f`, `x[i]`, `(x)`, `x^`. Unless `always`
// is set, a pointer, multi-pointer or procedure local that `n` only reaches into (`x.f`) stays
// followed, since a comparison of its part says nothing about it.
@(private = "file")
exclude_root :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node, always: bool) {
    n := n
    exact := true
    for {
        next: odinsyntax.Syntax_Node
        ok := false
        #partial switch n.green.kind {
        case .Paren_Expr:
            pe, _ := odinsyntax.as_paren_expr(n)
            next, ok = odinsyntax.paren_expr_expr(&pe)
        case .Selector_Expr:
            se, _ := odinsyntax.as_selector_expr(n)
            next, ok = odinsyntax.selector_expr_operand(&se)
            exact = false
        case .Index_Expr:
            ie, _ := odinsyntax.as_index_expr(n)
            next, ok = odinsyntax.index_expr_operand(&ie)
            exact = false
        case .Deref_Expr:
            de, _ := odinsyntax.as_deref_expr(n)
            next, ok = odinsyntax.deref_expr_operand(&de)
            exact = false
        case .Ident:
            r, found := nil_ref(w, int(n.offset))
            if found && !r.is_decl {
                _, is_plain := w.places[place_key(r.decl, "")]
                if always || exact || !is_plain {
                    w.root_skip[r.decl] = true
                }
            }
        }
        if !ok {
            return
        }
        n = next
    }
}

@(private = "file")
NIL_SIZE_BUILTINS :: [?]string{"size_of", "align_of", "type_of", "typeid_of", "offset_of", "offset_of_by_string", "type_info_of"}

@(private = "file")
Nil_Use_Mode :: enum u8 {
    Deref,
    Call,
    Index,
}

// Appends the events of the syntax under `n` in source order.
@(private = "file")
walk_nil :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node, out: ^[dynamic]Nil_Event) {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit:
        return
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        if op, ok := odinsyntax.unary_expr_op(&u); ok && op.green.kind == .And {
            return
        }
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(n)
        if op, ok := odinsyntax.binary_expr_op(&b); ok && (op.green.kind == .Cmp_And || op.green.kind == .Cmp_Or) {
            lhs, has_lhs := odinsyntax.binary_expr_lhs(&b)
            rhs, has_rhs := odinsyntax.binary_expr_rhs(&b)
            if has_lhs {
                walk_nil(w, lhs, out)
            }
            if has_rhs {
                mark := len(w.guard)
                if has_lhs {
                    cond_facts(w, lhs, op.green.kind == .Cmp_And, &w.guard)
                }
                walk_nil(w, rhs, out)
                resize(&w.guard, mark)
            }
            return
        }
    case .Deref_Expr:
        de, _ := odinsyntax.as_deref_expr(n)
        if operand, ok := odinsyntax.deref_expr_operand(&de); ok {
            deref_event(w, operand, .Deref, out)
        }
    case .Selector_Expr:
        se, _ := odinsyntax.as_selector_expr(n)
        if operand, ok := odinsyntax.selector_expr_operand(&se); ok {
            deref_event(w, operand, .Deref, out)
        }
    case .Index_Expr:
        ie, _ := odinsyntax.as_index_expr(n)
        if operand, ok := odinsyntax.index_expr_operand(&ie); ok {
            deref_event(w, operand, .Index, out)
        }
    case .Call_Expr:
        ce, _ := odinsyntax.as_call_expr(n)
        if callee, ok := odinsyntax.call_expr_callee(&ce); ok {
            if callee.green.kind == .Ident {
                names := NIL_SIZE_BUILTINS
                if slice.contains(names[:], odinsyntax.node_text(callee)) {
                    return
                }
            }
            deref_event(w, callee, .Call, out)
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        walk_nil(w, child, out)
    }
}

// Adds a dereference, an index or a call of `operand` when it names a candidate of that kind and no
// condition around it rules the nil out.
@(private = "file")
deref_event :: proc(w: ^Nil_Walk, operand: odinsyntax.Syntax_Node, mode: Nil_Use_Mode, out: ^[dynamic]Nil_Event) {
    operand := operand
    operand = strip_parens(operand)
    index, is_cand := nil_cand(w, operand)
    if !is_cand {
        return
    }
    cand := w.cands[index]
    ok := false
    switch mode {
    case .Deref:
        ok = !cand.is_proc && !cand.multi
    case .Call:
        ok = cand.is_proc
    case .Index:
        ok = cand.to_array || cand.multi
    }
    if !ok {
        return
    }
    for f in w.guard {
        if f.local == index && !f.is_nil {
            return
        }
    }
    append(out, Nil_Event{.Deref, index, int(operand.offset), mode == .Call})
}

@(private = "file")
step_nil_events :: proc(w: ^Nil_Walk, s: Cfg_Step, out: ^[dynamic]Nil_Event) {
    n := s.node
    if s.kind == .Stmt {
        if is_compound(n.green.kind) {
            return
        }
        #partial switch n.green.kind {
        case .Value_Decl:
            decl_nil_events(w, n, out)
            return
        case .Assign_Stmt:
            assign_nil_events(w, n, out)
            return
        }
    }
    walk_nil(w, n, out)
}

@(private = "file")
decl_nil_events :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node, out: ^[dynamic]Nil_Event) {
    v, _ := odinsyntax.as_value_decl(n)
    names, has_names := odinsyntax.value_decl_names(&v)
    if !has_names {
        return
    }
    values, has_values := odinsyntax.value_decl_values(&v)
    items: [dynamic]odinsyntax.Syntax_Node
    if has_values {
        walk_nil(w, odinsyntax.Syntax_Node(values), out)
        items = nil_items(values)
    }
    it := odinsyntax.name_list_names(&names)
    i := 0
    for name in odinsyntax.child_iter_next(&it) {
        defer i += 1
        places, is_root := w.root_places[int(name.offset)]
        if !is_root {
            continue
        }
        nil_value := !has_values || i < len(items) && is_nil_literal(items[i])
        zero_value := !has_values || i < len(items) && is_empty_comp_lit(items[i])
        for index in places {
            kind := Nil_Kind.Reset
            if w.cands[index].path == "" ? nil_value : zero_value {
                kind = .Nil
            }
            append(out, Nil_Event{kind, index, int(name.offset), false})
        }
    }
}

@(private = "file")
assign_nil_events :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node, out: ^[dynamic]Nil_Event) {
    a, _ := odinsyntax.as_assign_stmt(n)
    lhs, has_lhs := odinsyntax.assign_stmt_lhs(&a)
    rhs, has_rhs := odinsyntax.assign_stmt_rhs(&a)
    if !has_lhs || !has_rhs {
        return
    }
    plain := false
    if op, ok := odinsyntax.assign_stmt_op(&a); ok {
        plain = op.green.kind == .Eq
    }
    walk_nil(w, odinsyntax.Syntax_Node(rhs), out)
    targets, values := nil_items(lhs), nil_items(rhs)
    for target, i in targets {
        walk_nil(w, target, out)
        root, path, is_chain := flatten_place(target)
        if !is_chain {
            continue
        }
        ref, found := nil_ref(w, int(root.offset))
        if !found || ref.is_decl {
            continue
        }
        places, is_root := w.root_places[ref.decl]
        if !is_root {
            continue
        }
        paired := plain && len(targets) == len(values)
        set_nil := paired && is_nil_literal(values[i])
        set_zero := paired && is_empty_comp_lit(values[i])
        under := strings.concatenate({path, "."}, context.temp_allocator)
        for index in places {
            cand_path := w.cands[index].path
            if path != "" && cand_path != path && !strings.has_prefix(cand_path, under) {
                continue
            }
            kind := Nil_Kind.Reset
            if set_nil && cand_path == path || set_zero && cand_path != "" {
                kind = .Nil
            }
            append(out, Nil_Event{kind, index, int(target.offset), false})
        }
    }
}

// Forward must-dataflow over the graph of `lit`: a place is in the set when every path to the point
// left it nil. A branch on `x == nil` sets or clears `x` on its edges.
@(private = "file")
nil_flow :: proc(w: ^Nil_Walk, lit: odinsyntax.Syntax_Node, out: ^[dynamic]Nil_Use) -> mem.Allocator_Error {
    alloc := context.temp_allocator
    g := cfg_cached(w.c, w.file, lit)
    if g == nil {
        return nil
    }
    reach := cfg_reachable(g, alloc)
    events := make([][][dynamic]Nil_Event, len(g.blocks), alloc)
    facts_true := make([][dynamic]Nil_Fact, len(g.blocks), alloc)
    facts_false := make([][dynamic]Nil_Fact, len(g.blocks), alloc)
    for blk, b in g.blocks {
        if !reach[b] {
            continue
        }
        events[b] = make([][dynamic]Nil_Event, len(blk.steps), alloc)
        for s, i in blk.steps {
            events[b][i] = make([dynamic]Nil_Event, alloc)
            step_nil_events(w, s, &events[b][i])
        }
        if blk.has_cond && blk.on_true != blk.on_false {
            facts_true[b] = make([dynamic]Nil_Fact, alloc)
            facts_false[b] = make([dynamic]Nil_Fact, alloc)
            cond_facts(w, blk.cond, true, &facts_true[b])
            cond_facts(w, blk.cond, false, &facts_false[b])
        }
    }
    preds := make([][dynamic]int, len(g.blocks), alloc)
    for &list in preds {
        list = make([dynamic]int, alloc)
    }
    for blk, b in g.blocks {
        if !reach[b] {
            continue
        }
        for s in blk.succs {
            append(&preds[s], b) or_return
        }
    }

    words := (len(w.cands) + 63) / 64
    out_nil := make([]Bits, len(g.blocks), alloc)
    for b in 0 ..< len(g.blocks) {
        out_nil[b] = make(Bits, words, alloc)
        for &word in out_nil[b] {
            word = ~u64(0)
        }
    }
    cur := make(Bits, words, alloc)
    edge_bits := make(Bits, words, alloc)
    enter := proc(g: ^Cfg, b: int, preds: [][dynamic]int, out_nil: []Bits, cur, edge_bits: Bits, facts_true, facts_false: [][dynamic]Nil_Fact) {
        if Block_Id(b) == g.entry || len(preds[b]) == 0 {
            for &word in cur {
                word = 0
            }
            return
        }
        for &word in cur {
            word = ~u64(0)
        }
        for p in preds[b] {
            copy(edge_bits, out_nil[p])
            if blk := g.blocks[p]; blk.has_cond && blk.on_true != blk.on_false {
                facts: [dynamic]Nil_Fact
                if blk.on_true == Block_Id(b) {
                    facts = facts_true[p]
                } else if blk.on_false == Block_Id(b) {
                    facts = facts_false[p]
                }
                for f in facts {
                    if f.is_nil {
                        bits_set(edge_bits, f.local)
                    } else {
                        bits_clear(edge_bits, f.local)
                    }
                }
            }
            for k in 0 ..< len(cur) {
                cur[k] &= edge_bits[k]
            }
        }
    }
    for changed := true; changed; {
        changed = false
        for _, b in g.blocks {
            if !reach[b] {
                continue
            }
            enter(g, b, preds, out_nil, cur, edge_bits, facts_true, facts_false)
            for list in events[b] {
                for e in list {
                    apply_nil_event(w, cur, e, nil)
                }
            }
            if !slice.equal(cur, out_nil[b]) {
                copy(out_nil[b], cur)
                changed = true
            }
        }
    }

    for _, b in g.blocks {
        if !reach[b] {
            continue
        }
        enter(g, b, preds, out_nil, cur, edge_bits, facts_true, facts_false)
        for list in events[b] {
            for e in list {
                apply_nil_event(w, cur, e, out)
            }
        }
    }
    return nil
}

@(private = "file")
apply_nil_event :: proc(w: ^Nil_Walk, cur: Bits, e: Nil_Event, out: ^[dynamic]Nil_Use) {
    if w.root_skip[w.cands[e.local].root] {
        return
    }
    switch e.kind {
    case .Nil:
        bits_set(cur, e.local)
    case .Reset:
        bits_clear(cur, e.local)
    case .Deref:
        if bits_has(cur, e.local) {
            if out != nil {
                append(out, Nil_Use{e.offset, w.cands[e.local].name, e.is_call})
            }
            bits_clear(cur, e.local)
        }
    }
}
