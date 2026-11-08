package odinsema

import "core:mem"
import "core:slice"

import odinsyntax "../syntax"

// A pointer dereference or a call of a procedure value whose operand is nil on every path to it.
// `name` borrows the text of the parse.
Nil_Use :: struct {
    offset: int, // the identifier
    name:   string,
    is_call: bool,
}

@(private = "file")
Nil_Kind :: enum u8 {
    Nil,   // the local is nil: declared with no value, or set to `nil`
    Reset, // the local gets some other value
    Deref, // the local is dereferenced, or called
}

@(private = "file")
Nil_Event :: struct {
    kind:    Nil_Kind,
    local:   int, // index into Nil_Walk.cands
    offset:  int,
    is_call: bool,
}

@(private = "file")
Nil_Cand :: struct {
    name:    string,
    decl:    int,  // the name offset of the declaration
    is_proc: bool, // a procedure value: its use is a call
    skip:    bool, // the analysis cannot follow it
}

@(private = "file")
Nil_Walk :: struct {
    c:       ^Checker,
    file:    File_Id,
    refs:    [dynamic]Name_Ref,
    locals:  map[int]bool, // the name offsets of the plain variables of the body
    cands:   [dynamic]Nil_Cand,
    by_decl: map[int]int,
}

// The dereferences of the pointers and the calls of the procedure values of the procedure literal
// `lit` that are nil on every path to them. Only a local variable is followed, from its declaration
// with no value or with `nil`, through plain assignments; a local whose address is taken, that is
// compared with anything, that has attributes or that `using` names is left out, since a path that
// tests it may rule the nil out.
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
        c       = c,
        file    = file,
        refs    = make([dynamic]Name_Ref, alloc),
        locals  = make(map[int]bool, alloc),
        cands   = make([dynamic]Nil_Cand, alloc),
        by_decl = make(map[int]int, alloc),
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
            kind := nil_kind(&w, l.name_offset)
            if kind == .None {
                continue
            }
            w.by_decl[l.name_offset] = len(w.cands)
            append(&w.cands, Nil_Cand{name = l.name, decl = l.name_offset, is_proc = kind == .Proc}) or_return
        }
    }
    if len(w.cands) == 0 {
        return
    }
    exclude_tested(&w, body)
    nil_flow(&w, lit, &out) or_return
    slice.sort_by(out[:], proc(a, b: Nil_Use) -> bool {return a.offset < b.offset})
    return
}

@(private = "file")
Nil_Type :: enum u8 {
    None,
    Pointer,
    Proc,
}

// Whether the local declared at `name_offset` is a pointer or a procedure value.
@(private = "file")
nil_kind :: proc(w: ^Nil_Walk, name_offset: int) -> Nil_Type {
    t := decl_type(w.c, local_symbol(w.file, name_offset))
    if t == INVALID_TYPE {
        return .None
    }
    #partial switch _ in type_get(&w.c.table, type_base(&w.c.table, t)) {
    case Pointer_Type:
        return .Pointer
    case Proc_Type:
        return .Proc
    }
    return .None
}

@(private = "file")
nil_ref :: proc(w: ^Nil_Walk, start: int) -> (Name_Ref, bool) {
    i, found := slice.binary_search_by(w.refs[:], start, proc(r: Name_Ref, s: int) -> slice.Ordering {return slice.cmp(r.start, s)})
    if !found {
        return {}, false
    }
    return w.refs[i], true
}

// The candidate an identifier names. A declaration is not a use.
@(private = "file")
nil_cand :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node) -> (int, bool) {
    if n.green.kind != .Ident {
        return 0, false
    }
    r, found := nil_ref(w, int(n.offset))
    if !found || r.is_decl {
        return 0, false
    }
    index, is_cand := w.by_decl[r.decl]
    return index, is_cand
}

@(private = "file")
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

@(private = "file")
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

// Marks the candidates the analysis cannot follow: one whose address is taken, one that a comparison,
// a `using` or a declaration with attributes names.
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
                exclude_root(w, operand)
            }
        }
    case .Slice_Expr:
        se, _ := odinsyntax.as_slice_expr(n)
        if operand, ok := odinsyntax.slice_expr_operand(&se); ok {
            exclude_root(w, operand)
        }
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(n)
        if op, ok := odinsyntax.binary_expr_op(&b); ok && (op.green.kind == .Cmp_Eq || op.green.kind == .Not_Eq) {
            if lhs, has := odinsyntax.binary_expr_lhs(&b); has {
                exclude_root(w, lhs)
            }
            if rhs, has := odinsyntax.binary_expr_rhs(&b); has {
                exclude_root(w, rhs)
            }
        }
    case .Using_Stmt:
        us, _ := odinsyntax.as_using_stmt(n)
        if exprs, ok := odinsyntax.using_stmt_exprs(&us); ok {
            for item in nil_items(exprs) {
                exclude_root(w, item)
            }
        }
    case .Value_Decl:
        v, _ := odinsyntax.as_value_decl(n)
        attrs := odinsyntax.value_decl_attributes(&v)
        if _, has_attrs := odinsyntax.child_iter_next(&attrs); has_attrs {
            if names, ok := odinsyntax.value_decl_names(&v); ok {
                it := odinsyntax.name_list_names(&names)
                for name in odinsyntax.child_iter_next(&it) {
                    if index, is_cand := w.by_decl[int(name.offset)]; is_cand {
                        w.cands[index].skip = true
                    }
                }
            }
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        exclude_tested(w, child)
    }
}

// Excludes the candidate at the root of the place `n`: `x`, `x.f`, `x[i]`, `(x)`, `x^`.
@(private = "file")
exclude_root :: proc(w: ^Nil_Walk, n: odinsyntax.Syntax_Node) {
    n := n
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
        case .Index_Expr:
            ie, _ := odinsyntax.as_index_expr(n)
            next, ok = odinsyntax.index_expr_operand(&ie)
        case .Deref_Expr:
            de, _ := odinsyntax.as_deref_expr(n)
            next, ok = odinsyntax.deref_expr_operand(&de)
        case .Ident:
            if index, is_cand := nil_cand(w, n); is_cand {
                w.cands[index].skip = true
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
    case .Deref_Expr:
        de, _ := odinsyntax.as_deref_expr(n)
        if operand, ok := odinsyntax.deref_expr_operand(&de); ok {
            deref_event(w, strip_parens(operand), false, out)
        }
    case .Selector_Expr:
        se, _ := odinsyntax.as_selector_expr(n)
        if operand, ok := odinsyntax.selector_expr_operand(&se); ok {
            deref_event(w, strip_parens(operand), false, out)
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
            deref_event(w, strip_parens(callee), true, out)
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        walk_nil(w, child, out)
    }
}

// Adds a dereference or call of `operand` when it names a pointer or a procedure value candidate.
@(private = "file")
deref_event :: proc(w: ^Nil_Walk, operand: odinsyntax.Syntax_Node, is_call: bool, out: ^[dynamic]Nil_Event) {
    index, is_cand := nil_cand(w, operand)
    if is_cand && w.cands[index].is_proc == is_call {
        append(out, Nil_Event{.Deref, index, int(operand.offset), is_call})
    }
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
        index, is_cand := w.by_decl[int(name.offset)]
        if !is_cand {
            continue
        }
        switch {
        case !has_values:
            append(out, Nil_Event{.Nil, index, int(name.offset), false})
        case i < len(items) && is_nil_literal(items[i]):
            append(out, Nil_Event{.Nil, index, int(name.offset), false})
        case:
            append(out, Nil_Event{.Reset, index, int(name.offset), false})
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
        if target.green.kind == .Ident {
            if ref, found := nil_ref(w, int(target.offset)); found {
                if index, is_cand := w.by_decl[ref.decl]; is_cand {
                    kind := Nil_Kind.Reset
                    if plain && len(targets) == len(values) && is_nil_literal(values[i]) {
                        kind = .Nil
                    }
                    append(out, Nil_Event{kind, index, int(target.offset), false})
                    continue
                }
            }
        }
        walk_nil(w, target, out)
    }
}

// Forward must-dataflow over the graph of `lit`: a local is in the set when every path to the point
// left it nil.
@(private = "file")
nil_flow :: proc(w: ^Nil_Walk, lit: odinsyntax.Syntax_Node, out: ^[dynamic]Nil_Use) -> mem.Allocator_Error {
    alloc := context.temp_allocator
    g := cfg_cached(w.c, w.file, lit)
    if g == nil {
        return nil
    }
    reach := cfg_reachable(g, alloc)
    events := make([][][dynamic]Nil_Event, len(g.blocks), alloc)
    for blk, b in g.blocks {
        if !reach[b] {
            continue
        }
        events[b] = make([][dynamic]Nil_Event, len(blk.steps), alloc)
        for s, i in blk.steps {
            events[b][i] = make([dynamic]Nil_Event, alloc)
            step_nil_events(w, s, &events[b][i])
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
    enter := proc(g: ^Cfg, b: int, preds: [][dynamic]int, out_nil: []Bits, cur: Bits) {
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
            for k in 0 ..< len(cur) {
                cur[k] &= out_nil[p][k]
            }
        }
    }
    for changed := true; changed; {
        changed = false
        for _, b in g.blocks {
            if !reach[b] {
                continue
            }
            enter(g, b, preds, out_nil, cur)
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
        enter(g, b, preds, out_nil, cur)
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
    if w.cands[e.local].skip {
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
