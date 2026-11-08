// Values of the temp allocator that reach a place outliving the frame (`mem/temp-escape`).
package odinsema

import "core:mem"
import "core:slice"
import "core:strings"

import odinsyntax "../syntax"

// A value of the temp allocator stored where it outlives the next `free_all`. `offset` is the
// stored value.
Temp_Store :: struct {
    offset:   int,
    returned: bool, // a dangling pointer that a `return` hands out
}

// A place the flow follows: a local, or a field chain of a record local held by value.
@(private = "file")
Temp_Cand :: struct {
    root: int,    // the name offset of the declaration of the local
    path: string, // "" for the local, else `.a.b`
}

// Which parameters a procedure may hand back in its result.
@(private = "file")
Temp_Alias :: struct {
    params: u64,
    ok:     bool, // false when a result is something the analysis cannot read
}

@(private = "file")
Alias_Key :: struct {
    file:   File_Id,
    offset: int,
}

@(private = "file")
TEMP_ALIAS_DEPTH :: 3

@(private = "file")
Temp_Update :: struct {
    index: int,
    taint: bool,
}

@(private = "file")
Temp_Walk :: struct {
    c:           ^Checker,
    file:        File_Id,
    dangling:    bool, // follow the address of a local, not a temp value
    refs:        [dynamic]Name_Ref,
    locals:      map[int]bool,
    places:      map[string]int,
    cands:       [dynamic]Temp_Cand,
    root_places: map[int][dynamic]int,
    root_skip:   map[int]bool,                         // locals whose address is taken, or that `using` or attributes name
    real:        map[u32]odinsyntax.Syntax_Node,       // the declarations and assignments of the body, with their parents
    alias:       map[Alias_Key]Temp_Alias,
}

// The stores of a value of the temp allocator into a global or through a pointer or slice
// parameter in the procedure literal `lit`. A value is a call given `context.temp_allocator`, a
// `tprint*` call, a slice, conversion or `or_else` of one, a call that hands one of its
// arguments back, or a local or field of a record local that every path to the store filled with
// one. A local whose address is taken is not followed. A procedure with `temp` or `tprint` in
// its name is left out.
temp_stores :: proc(c: ^Checker, file: File_Id, m: ^Scope_Map, lit: odinsyntax.Syntax_Node, allocator := context.allocator) -> (out: [dynamic]Temp_Store, err: mem.Allocator_Error) {
    return flow_stores(c, file, m, lit, false, allocator)
}

// The same flow for the address of a by-value local (`dangling_place`): the stores into a place
// that outlives the frame and the returns, of a value that is not itself `&x` or `x[:]`, which
// the direct check reports. A procedure with `temp` in its name is not left out.
dangling_flow :: proc(c: ^Checker, file: File_Id, m: ^Scope_Map, lit: odinsyntax.Syntax_Node, allocator := context.allocator) -> (out: [dynamic]Temp_Store, err: mem.Allocator_Error) {
    return flow_stores(c, file, m, lit, true, allocator)
}

@(private = "file")
flow_stores :: proc(c: ^Checker, file: File_Id, m: ^Scope_Map, lit: odinsyntax.Syntax_Node, dangling: bool, allocator: mem.Allocator) -> (out: [dynamic]Temp_Store, err: mem.Allocator_Error) {
    out = make([dynamic]Temp_Store, allocator) or_return
    pl, is_lit := odinsyntax.as_proc_lit(lit)
    if !is_lit || m == nil || !dangling && temp_helper(lit) {
        return
    }
    body, has_body := odinsyntax.proc_lit_body(&pl)
    if !has_body {
        return
    }
    text := odinsyntax.node_text(body)
    if dangling {
        if !strings.contains(text, "&") && !strings.contains(text, "[") {
            return
        }
    } else if !strings.contains(text, "temp_allocator") && !strings.contains(text, "tprint") {
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
    w := Temp_Walk {
        c           = c,
        file        = file,
        dangling    = dangling,
        refs        = make([dynamic]Name_Ref, alloc),
        locals      = make(map[int]bool, alloc),
        places      = make(map[string]int, alloc),
        cands       = make([dynamic]Temp_Cand, alloc),
        root_places = make(map[int][dynamic]int, alloc),
        root_skip   = make(map[int]bool, alloc),
        real        = make(map[u32]odinsyntax.Syntax_Node, alloc),
        alias       = make(map[Alias_Key]Temp_Alias, alloc),
    }
    in_lit := locals_between(m, int(lit_start), int(lit_end), alloc)
    for li in in_lit {
        l := m.locals[li]
        if l.kind == .Var && !l.is_using && m.scopes[l.scope].proc_depth == depth {
            w.locals[l.name_offset] = true
        }
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
            temp_add(&w, l.name_offset, "") or_return
        }
    }
    temp_prepare(&w, new_clone(body, context.temp_allocator) or_return) or_return
    temp_flow(&w, lit, &out) or_return
    return
}

@(private = "file")
temp_add :: proc(w: ^Temp_Walk, root: int, path: string) -> mem.Allocator_Error {
    index := len(w.cands)
    append(&w.cands, Temp_Cand{root, path}) or_return
    w.places[place_key(root, path)] = index
    if root not_in w.root_places {
        w.root_places[root] = make([dynamic]int, w.root_places.allocator)
    }
    list := &w.root_places[root]
    append(list, index) or_return
    return nil
}

// Notes the declarations and assignments with parents that stay valid, registers the field chains of record locals and marks
// the locals that cannot be followed.
@(private = "file")
temp_prepare :: proc(w: ^Temp_Walk, node: ^odinsyntax.Syntax_Node) -> mem.Allocator_Error {
    n := node^
    #partial switch n.green.kind {
    case .Proc_Lit:
        return nil
    case .Assign_Stmt, .Return_Stmt:
        w.real[n.offset] = n
    case .Value_Decl:
        w.real[n.offset] = n
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
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        if op, ok := odinsyntax.unary_expr_op(&u); ok && op.green.kind == .And {
            if operand, has := odinsyntax.unary_expr_operand(&u); has {
                temp_skip_root(w, operand)
            }
        }
    case .Using_Stmt:
        us, _ := odinsyntax.as_using_stmt(n)
        if exprs, ok := odinsyntax.using_stmt_exprs(&us); ok {
            for item in nil_items(exprs) {
                temp_skip_root(w, item)
            }
        }
    case .Selector_Expr:
        se, _ := odinsyntax.as_selector_expr(n)
        if _, arrow := odinsyntax.selector_expr_arrow(&se); arrow {
            if operand, ok := odinsyntax.selector_expr_operand(&se); ok {
                temp_skip_root(w, operand)
            }
        }
        temp_register(w, n) or_return
    }
    it := odinsyntax.child_iter(node, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        temp_prepare(w, new_clone(child, context.temp_allocator) or_return) or_return
    }
    return nil
}

// Marks the local at the root of the place `n`.
@(private = "file")
temp_skip_root :: proc(w: ^Temp_Walk, n: odinsyntax.Syntax_Node) {
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
            if r, found := ref_lookup(w.refs[:], int(n.offset)); found && !r.is_decl {
                w.root_skip[r.decl] = true
            }
        }
        if !ok {
            return
        }
        n = next
    }
}

@(private = "file")
temp_register :: proc(w: ^Temp_Walk, n: odinsyntax.Syntax_Node) -> mem.Allocator_Error {
    root, path, ok := flatten_place(n)
    if !ok || path == "" {
        return nil
    }
    r, found := ref_lookup(w.refs[:], int(root.offset))
    if !found || r.is_decl || !w.locals[r.decl] || place_key(r.decl, path) in w.places {
        return nil
    }
    if _, typed := path_type(w.c, decl_type(w.c, local_symbol(w.file, r.decl)), path); !typed {
        return nil
    }
    return temp_add(w, r.decl, path)
}

// The candidate the place `n` names.
@(private = "file")
temp_cand :: proc(w: ^Temp_Walk, n: odinsyntax.Syntax_Node) -> (int, bool) {
    inner := strip_parens(n)
    if inner.green.kind != .Ident && inner.green.kind != .Selector_Expr {
        return 0, false
    }
    root, path, ok := flatten_place(inner)
    if !ok {
        return 0, false
    }
    r, found := ref_lookup(w.refs[:], int(root.offset))
    if !found || r.is_decl {
        return 0, false
    }
    index, is_cand := w.places[place_key(r.decl, path)]
    return index, is_cand
}

// Whether the place is filled with a temp value, or holds a field that is.
@(private = "file")
place_tainted :: proc(w: ^Temp_Walk, cur: Bits, index: int) -> bool {
    cand := w.cands[index]
    if w.root_skip[cand.root] {
        return false
    }
    if bits_has(cur, index) {
        return true
    }
    under := strings.concatenate({cand.path, "."}, context.temp_allocator)
    for other in w.root_places[cand.root] {
        if strings.has_prefix(w.cands[other].path, under) && bits_has(cur, other) {
            return true
        }
    }
    return false
}

// Whether the value of `n` is, or holds, a temp value in the state `cur`.
@(private = "file")
taint_expr :: proc(w: ^Temp_Walk, cur: Bits, n: odinsyntax.Syntax_Node, depth := 0) -> bool {
    n := n
    n = strip_parens(n)
    #partial switch n.green.kind {
    case .Ident, .Selector_Expr:
        if index, ok := temp_cand(w, n); ok {
            return place_tainted(w, cur, index)
        }
    case .Unary_Expr:
        if w.dangling {
            _, _, source := dangling_place(w.c, w.file, n)
            return source
        }
    case .Slice_Expr:
        if w.dangling {
            if _, _, source := dangling_place(w.c, w.file, n); source {
                return true
            }
        }
        se, _ := odinsyntax.as_slice_expr(n)
        if operand, ok := odinsyntax.slice_expr_operand(&se); ok {
            return taint_expr(w, cur, operand, depth)
        }
    case .Cast_Expr:
        ce, _ := odinsyntax.as_cast_expr(n)
        if operand, ok := odinsyntax.cast_expr_operand(&ce); ok {
            return !pointer_cast(w, n) && taint_expr(w, cur, operand, depth)
        }
    case .Auto_Cast_Expr:
        ac, _ := odinsyntax.as_auto_cast_expr(n)
        if operand, ok := odinsyntax.auto_cast_expr_operand(&ac); ok {
            return taint_expr(w, cur, operand, depth)
        }
    case .Or_Else_Expr:
        oe, _ := odinsyntax.as_or_else_expr(n)
        lhs, has_lhs := odinsyntax.or_else_expr_lhs(&oe)
        rhs, has_rhs := odinsyntax.or_else_expr_rhs(&oe)
        return has_lhs && taint_expr(w, cur, lhs, depth) || has_rhs && taint_expr(w, cur, rhs, depth)
    case .Call_Expr:
        return taint_call(w, cur, n, depth)
    }
    return false
}

@(private = "file")
taint_call :: proc(w: ^Temp_Walk, cur: Bits, call: odinsyntax.Syntax_Node, depth: int) -> bool {
    if !w.dangling && temp_call(call) {
        return true
    }
    ce, _ := odinsyntax.as_call_expr(call)
    callee := odinsyntax.call_expr_callee(&ce) or_return
    list := odinsyntax.call_expr_args(&ce) or_return
    args := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
    it := odinsyntax.arg_list_args(&list)
    for arg in odinsyntax.child_iter_next(&it) {
        if arg.green.kind == .Field_Value || arg.green.kind == .Spread_Expr {
            return false
        }
        append(&args, arg)
    }
    if len(args) == 0 {
        return false
    }
    if sel, is_sel := odinsyntax.as_selector_expr(callee); is_sel {
        if _, arrow := odinsyntax.selector_expr_arrow(&sel); arrow {
            return false
        }
    }
    op := expr_type(w.c, w.file, callee)
    if op.mode == .Type {
        return len(args) == 1 && !pointer_cast(w, call) && taint_expr(w, cur, args[0], depth)
    }
    if depth >= TEMP_ALIAS_DEPTH || len(args) > 64 {
        return false
    }
    mask: u64
    for arg, j in args {
        if taint_expr(w, cur, arg, depth + 1) {
            mask |= u64(1) << u64(j)
        }
    }
    if mask == 0 {
        return false
    }
    alias := proc_alias(w, op, 0)
    return alias.ok && alias.params & mask != 0
}

// Which parameters the procedure the operand `op` names may return, read from its body.
@(private = "file")
proc_alias :: proc(w: ^Temp_Walk, op: Operand, depth: int) -> Temp_Alias {
    if !op.has_symbol || op.symbol.child >= 0 || depth > TEMP_ALIAS_DEPTH {
        return {}
    }
    item := checker_item(w.c, op.symbol)
    if item == nil || item.kind != .Proc || item.value_offset < 0 {
        return {}
    }
    key := Alias_Key{op.symbol.file, item.value_offset}
    if cached, found := w.alias[key]; found {
        return cached
    }
    w.alias[key] = {}
    p, is_proc := type_get(&w.c.table, type_base(&w.c.table, op.type)).(Proc_Type)
    if !is_proc || len(p.results) != 1 || len(p.params) > 64 {
        return {}
    }
    for param in p.params {
        if .Variadic in param.flags || .C_Vararg in param.flags {
            return {}
        }
    }
    lit, found := node_of_kind(w.c, op.symbol.file, item.value_offset, .Proc_Lit)
    if !found {
        return {}
    }
    pl, _ := odinsyntax.as_proc_lit(lit)
    body, has_body := odinsyntax.proc_lit_body(&pl)
    if !has_body {
        return {}
    }
    out := Temp_Alias{ok = true}
    collect_returns(w, op.symbol.file, p, body, depth, &out)
    if !out.ok {
        out.params = 0
    }
    w.alias[key] = out
    return out
}

// Adds what every `return` under `n` hands back to `out`.
@(private = "file")
collect_returns :: proc(w: ^Temp_Walk, file: File_Id, p: Proc_Type, n: odinsyntax.Syntax_Node, depth: int, out: ^Temp_Alias) {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit:
        return
    case .Return_Stmt:
        rs, _ := odinsyntax.as_return_stmt(n)
        values, has_values := odinsyntax.return_stmt_values(&rs)
        items: [dynamic]odinsyntax.Syntax_Node
        if has_values {
            items = nil_items(values)
        }
        if len(items) != 1 {
            out.ok = false
            return
        }
        mask, ok := alias_expr(w, file, p, items[0], depth)
        out.params |= mask
        out.ok &&= ok
        return
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        collect_returns(w, file, p, child, depth, out)
    }
}

// The parameters of `p` that the value of `n`, read in `file`, may share memory with. False when
// `n` is something the analysis cannot read.
@(private = "file")
alias_expr :: proc(w: ^Temp_Walk, file: File_Id, p: Proc_Type, n: odinsyntax.Syntax_Node, depth: int) -> (mask: u64, ok: bool) {
    n := n
    n = strip_parens(n)
    #partial switch n.green.kind {
    case .Literal:
        return 0, true
    case .Comp_Lit:
        return 0, is_empty_comp_lit(n)
    case .Ident:
        text := odinsyntax.node_text(n)
        if text == "nil" || text == "true" || text == "false" {
            return 0, true
        }
        r := lookup_name(w.c, file, text, int(n.offset))
        if r.kind != .Local || r.local.kind != .Param {
            return 0, false
        }
        for param, j in p.params {
            if param.name_offset == r.local.name_offset {
                return u64(1) << u64(j), true
            }
        }
        return 0, false
    case .Slice_Expr:
        se, _ := odinsyntax.as_slice_expr(n)
        operand := odinsyntax.slice_expr_operand(&se) or_return
        return alias_expr(w, file, p, operand, depth)
    case .Cast_Expr:
        ce, _ := odinsyntax.as_cast_expr(n)
        operand := odinsyntax.cast_expr_operand(&ce) or_return
        return alias_expr(w, file, p, operand, depth)
    case .Call_Expr:
        ce, _ := odinsyntax.as_call_expr(n)
        callee := odinsyntax.call_expr_callee(&ce) or_return
        list := odinsyntax.call_expr_args(&ce) or_return
        args := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
        it := odinsyntax.arg_list_args(&list)
        for arg in odinsyntax.child_iter_next(&it) {
            if arg.green.kind == .Field_Value || arg.green.kind == .Spread_Expr {
                return 0, false
            }
            append(&args, arg)
        }
        op := expr_type(w.c, file, callee)
        if op.mode == .Type {
            if len(args) != 1 {
                return 0, false
            }
            return alias_expr(w, file, p, args[0], depth)
        }
        inner := proc_alias(w, op, depth + 1)
        if !inner.ok {
            return 0, false
        }
        for arg, j in args {
            if j < 64 && inner.params >> u64(j) & 1 != 0 {
                m, arg_ok := alias_expr(w, file, p, arg, depth)
                if !arg_ok {
                    return 0, false
                }
                mask |= m
            }
        }
        return mask, true
    }
    return 0, false
}

// The new state of the places a store to `dst_path` of the local `root` changes. `val` is the
// stored value; a place copied from a place gets the matching field of the source.
@(private = "file")
temp_updates :: proc(w: ^Temp_Walk, cur: Bits, root: int, dst_path: string, val: odinsyntax.Syntax_Node, has_val: bool, out: ^[dynamic]Temp_Update) {
    places, tracked := w.root_places[root]
    if !tracked {
        return
    }
    whole := has_val && taint_expr(w, cur, val)
    src_root, src_path, copies := 0, "", false
    if has_val {
        if root_node, path, is_chain := flatten_place(val); is_chain {
            if r, found := ref_lookup(w.refs[:], int(root_node.offset)); found && !r.is_decl && r.decl in w.root_places {
                src_root, src_path, copies = r.decl, path, true
            }
        }
    }
    under := strings.concatenate({dst_path, "."}, context.temp_allocator)
    for index in places {
        path := w.cands[index].path
        if dst_path != "" && path != dst_path && !strings.has_prefix(path, under) {
            continue
        }
        taint := false
        suffix := path[len(dst_path):]
        switch {
        case w.root_skip[root]:
        case suffix == "":
            taint = whole
        case copies:
            if source, found := w.places[place_key(src_root, strings.concatenate({src_path, suffix}, context.temp_allocator))]; found {
                taint = bits_has(cur, source)
            }
        }
        append(out, Temp_Update{index, taint})
    }
}

// True in the dangling flow when `n` converts to a pointer or `rawptr`: a deliberate cast, as of an
// intrusive list node that lives on the stack while its owner waits.
@(private = "file")
pointer_cast :: proc(w: ^Temp_Walk, n: odinsyntax.Syntax_Node) -> bool {
    if !w.dangling {
        return false
    }
    #partial switch v in type_get(&w.c.table, type_base(&w.c.table, expr_type(w.c, w.file, n).type)) {
    case Pointer_Type, Multi_Pointer_Type:
        return true
    case Basic_Type:
        return v.kind == .Rawptr
    }
    return false
}

// True when the dangling flow follows `n` and the direct check (`dangling_place`) reports it.
@(private = "file")
direct_dangling :: proc(w: ^Temp_Walk, n: odinsyntax.Syntax_Node) -> bool {
    if !w.dangling {
        return false
    }
    _, _, direct := dangling_place(w.c, w.file, n)
    return direct
}

@(private = "file")
temp_step :: proc(w: ^Temp_Walk, s: Cfg_Step, cur: Bits, out: ^[dynamic]Temp_Store) {
    n := s.node
    if s.kind == .Stmt && is_compound(n.green.kind) {
        return
    }
    real, found := w.real[n.offset]
    if !found || real.green.kind != n.green.kind {
        return
    }
    updates := make([dynamic]Temp_Update, context.temp_allocator)
    #partial switch real.green.kind {
    case .Value_Decl:
        v, _ := odinsyntax.as_value_decl(real)
        names, has_names := odinsyntax.value_decl_names(&v)
        if !has_names {
            return
        }
        values, has_values := odinsyntax.value_decl_values(&v)
        items: [dynamic]odinsyntax.Syntax_Node
        if has_values {
            items = nil_items(values)
        }
        it := odinsyntax.name_list_names(&names)
        i := 0
        for name in odinsyntax.child_iter_next(&it) {
            defer i += 1
            temp_updates(w, cur, int(name.offset), "", i < len(items) ? items[i] : {}, i < len(items), &updates)
        }
    case .Assign_Stmt:
        a, _ := odinsyntax.as_assign_stmt(real)
        lhs, has_lhs := odinsyntax.assign_stmt_lhs(&a)
        rhs, has_rhs := odinsyntax.assign_stmt_rhs(&a)
        if !has_lhs || !has_rhs {
            return
        }
        plain := false
        if op, ok := odinsyntax.assign_stmt_op(&a); ok {
            plain = op.green.kind == .Eq
        }
        targets, values := nil_items(lhs), nil_items(rhs)
        for target, i in targets {
            has_val := plain && i < len(values)
            if has_val && out != nil && outliving_store(w.c, w.file, target, results = w.dangling) && !cleared_by_defer(real, target) && taint_expr(w, cur, values[i]) && !direct_dangling(w, values[i]) {
                append(out, Temp_Store{offset = int(strip_parens(values[i]).offset)})
            }
            root_node, path, is_chain := flatten_place(target)
            if !is_chain {
                continue
            }
            if r, ref_found := ref_lookup(w.refs[:], int(root_node.offset)); ref_found && !r.is_decl {
                temp_updates(w, cur, r.decl, path, has_val ? values[i] : {}, has_val, &updates)
            }
        }
    case .Return_Stmt:
        if !w.dangling || out == nil {
            return
        }
        rs, _ := odinsyntax.as_return_stmt(real)
        if values, has_values := odinsyntax.return_stmt_values(&rs); has_values {
            for value in nil_items(values) {
                if taint_expr(w, cur, value) && !direct_dangling(w, value) {
                    append(out, Temp_Store{offset = int(strip_parens(value).offset), returned = true})
                }
            }
        }
        return
    case:
        return
    }
    for u in updates {
        if u.taint {
            bits_set(cur, u.index)
        } else {
            bits_clear(cur, u.index)
        }
    }
}

// Forward must-dataflow over the graph of `lit`: a place is in the set when every path to the point
// filled it with a temp value.
@(private = "file")
temp_flow :: proc(w: ^Temp_Walk, lit: odinsyntax.Syntax_Node, out: ^[dynamic]Temp_Store) -> mem.Allocator_Error {
    alloc := context.temp_allocator
    g := cfg_cached(w.c, w.file, lit)
    if g == nil {
        return nil
    }
    reach := cfg_reachable(g, alloc)
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
    out_bits := make([]Bits, len(g.blocks), alloc)
    for b in 0 ..< len(g.blocks) {
        out_bits[b] = make(Bits, words, alloc)
        for &word in out_bits[b] {
            word = ~u64(0)
        }
    }
    cur := make(Bits, words, alloc)
    enter := proc(g: ^Cfg, b: int, preds: [][dynamic]int, out_bits: []Bits, cur: Bits) {
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
                cur[k] &= out_bits[p][k]
            }
        }
    }
    for changed := true; changed; {
        changed = false
        for blk, b in g.blocks {
            if !reach[b] {
                continue
            }
            enter(g, b, preds, out_bits, cur)
            for s in blk.steps {
                temp_step(w, s, cur, nil)
            }
            if !slice.equal(cur, out_bits[b]) {
                copy(out_bits[b], cur)
                changed = true
            }
        }
    }
    for blk, b in g.blocks {
        if !reach[b] {
            continue
        }
        enter(g, b, preds, out_bits, cur)
        for s in blk.steps {
            temp_step(w, s, cur, out)
        }
    }
    slice.sort_by(out[:], proc(a, b: Temp_Store) -> bool {return a.offset < b.offset})
    return nil
}
