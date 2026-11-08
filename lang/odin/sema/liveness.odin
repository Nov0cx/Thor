package odinsema

import "core:mem"
import "core:slice"

import odinsyntax "../syntax"

// The liveness results of one procedure body.
Liveness_Report :: struct {
    unused:      [dynamic]Live_Name, // the name of a variable that no reference uses
    dead_stores: [dynamic]Live_Name, // the identifier of a store that no path reads
}

// A name of the body. `name` borrows the text of the parse.
Live_Name :: struct {
    offset: int,
    name:   string,
}

@(private = "file")
Name_Key :: struct {
    scope: int,
    name:  string,
}

@(private = "file")
Live_Ref :: struct {
    start:    int,
    end:      int,
    local:    int, // index into Live_Walk.tracked
    is_decl:  bool,
    is_store: bool,
}

@(private = "file")
Live_Local :: struct {
    local:      int,  // index into Scope_Map.locals
    excluded:   bool, // the dead-store analysis cannot follow it: address taken, `using`, attributes, a use out of the graph
    reportable: bool, // a dead store of it is reported
}

@(private = "file")
Def :: struct {
    local:      int,
    offset:     int,
    reportable: bool,
}

// What one step does: its defs happen before its uses when walked backward.
@(private = "file")
Effect :: struct {
    defs: [dynamic]Def,
    uses: [dynamic]int,
}

@(private = "file")
Span :: struct {
    start: int,
    end:   int,
}

@(private = "file")
Live_Walk :: struct {
    c:        ^Checker,
    file:     File_Id,
    m:        ^Scope_Map,
    tracked:  [dynamic]Live_Local,
    by_decl:  map[int]int, // name offset -> index into tracked
    refs:     [dynamic]Live_Ref,
    untaken:  [dynamic]Span, // the `when` branches the target does not take
    attrs:    [dynamic]int,  // the name offsets of declarations with attributes
    computed: map[int]bool,  // the name offsets of declarations whose value holds a call
    alloc:    mem.Allocator,
}

@(private = "file")
LIVE_ALL_KINDS :: ~odinsyntax.Kind_Set{}

// The unused variables and dead stores of the procedure literal `lit`, from the scope map `m` of its
// file. A variable is unused when no reference but its declaration names it, as the compiler's
// `-vet-unused-variables` counts: a plain `=` is a use, and a reference in a `when` branch the
// target does not take is not. A dead store is a plain `=`, or a declaration value that holds a call,
// that no path reads.
liveness :: proc(c: ^Checker, file: File_Id, m: ^Scope_Map, lit: odinsyntax.Syntax_Node, allocator := context.allocator) -> (out: Liveness_Report, err: mem.Allocator_Error) {
    out.unused = make([dynamic]Live_Name, allocator)
    out.dead_stores = make([dynamic]Live_Name, allocator)
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
    w := Live_Walk {
        c       = c,
        file    = file,
        m       = m,
        tracked = make([dynamic]Live_Local, alloc),
        by_decl = make(map[int]int, alloc),
        refs    = make([dynamic]Live_Ref, alloc),
        untaken = make([dynamic]Span, alloc),
        attrs   = make([dynamic]int, alloc),
        computed = make(map[int]bool, alloc),
        alloc   = alloc,
    }
    for i in locals_between(m, int(lit_start), int(lit_end), alloc) {
        l := m.locals[i]
        if m.scopes[l.scope].proc_depth != depth {
            continue
        }
        #partial switch l.kind {
        case .Var, .Param, .Result, .Loop_Var:
            append(&w.tracked, Live_Local{local = i, excluded = l.is_using, reportable = l.kind != .Loop_Var}) or_return
            w.by_decl[l.name_offset] = len(w.tracked) - 1
        }
    }
    if len(w.tracked) == 0 {
        return
    }
    for ri in refs_between(m, int(lit_start), int(lit_end)) {
        r := m.refs[ri]
        if r.kind != .Local {
            continue
        }
        if index, ok := w.by_decl[r.decl]; ok {
            append(&w.refs, Live_Ref{r.start, r.end, index, r.is_decl, r.is_store}) or_return
        }
    }
    slice.sort_by(w.refs[:], proc(a, b: Live_Ref) -> bool {return a.start < b.start})
    scan(&w, body)
    for at in w.attrs {
        if index, ok := w.by_decl[at]; ok {
            w.tracked[index].excluded = true
        }
    }

    // Unused variables. The branches of a `when` can declare one name twice in a scope, and a use
    // binds to the last: a name counts as used for every declaration of it in its scope.
    used := make([]bool, len(w.tracked), alloc)
    for r in w.refs {
        if !r.is_decl && !in_spans(w.untaken[:], r.start) {
            used[r.local] = true
        }
    }
    groups := make(map[Name_Key][dynamic]int, alloc)
    for t, i in w.tracked {
        l := m.locals[t.local]
        key := Name_Key{l.scope, l.name}
        if key not_in groups {
            groups[key] = make([dynamic]int, alloc)
        }
        append(&groups[key], i) or_return
    }
    for _, members in groups {
        if len(members) < 2 {
            continue
        }
        any_used := false
        for i in members {
            any_used ||= used[i]
            w.tracked[i].excluded = true
        }
        for i in members {
            used[i] = any_used
        }
    }
    for t, i in w.tracked {
        l := m.locals[t.local]
        if l.kind != .Var && l.kind != .Loop_Var {
            continue
        }
        if used[i] || l.is_using || slice.contains(w.attrs[:], l.name_offset) || in_spans(w.untaken[:], l.name_offset) {
            continue
        }
        append(&out.unused, Live_Name{l.name_offset, l.name}) or_return
    }
    for &t, i in w.tracked {
        if !used[i] {
            t.excluded = true
        }
    }
    dead_stores(&w, lit, &out) or_return
    slice.sort_by(out.unused[:], name_less)
    slice.sort_by(out.dead_stores[:], name_less)
    return
}

@(private = "file")
name_less :: proc(a, b: Live_Name) -> bool {
    return a.offset < b.offset
}

liveness_destroy :: proc(r: ^Liveness_Report) {
    delete(r.unused)
    delete(r.dead_stores)
}

@(private = "file")
in_spans :: proc(spans: []Span, offset: int) -> bool {
    for s in spans {
        if offset >= s.start && offset < s.end {
            return true
        }
    }
    return false
}

// Notes the untaken `when` branches, the declarations with attributes, the computed values and the locals
// whose address escapes under `n`. A nested procedure literal is not walked.
@(private = "file")
scan :: proc(w: ^Live_Walk, n: odinsyntax.Syntax_Node) {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit:
        return
    case .When_Stmt:
        ws, _ := odinsyntax.as_when_stmt(n)
        if cond, ok := odinsyntax.when_stmt_cond(&ws); ok {
            state := when_state(w.c, w.file, cond)
            if body, has_body := odinsyntax.when_stmt_body(&ws); has_body && state == .False {
                add_span(w, body)
            }
            if other, has_else := odinsyntax.when_stmt_else_branch(&ws); has_else && state == .True {
                add_span(w, other)
            }
        }
    case .Value_Decl:
        scan_decl(w, n)
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        if op, ok := odinsyntax.unary_expr_op(&u); ok && op.green.kind == .And {
            if operand, has := odinsyntax.unary_expr_operand(&u); has {
                escape(w, operand)
            }
        }
    case .Slice_Expr:
        se, _ := odinsyntax.as_slice_expr(n)
        if operand, ok := odinsyntax.slice_expr_operand(&se); ok {
            escape(w, operand)
        }
    case .Selector_Expr:
        sel, _ := odinsyntax.as_selector_expr(n)
        if _, arrow := odinsyntax.selector_expr_arrow(&sel); arrow {
            if operand, ok := odinsyntax.selector_expr_operand(&sel); ok {
                escape(w, operand)
            }
        }
    case .Range_Stmt:
        rs, _ := odinsyntax.as_range_stmt(n)
        if vars, ok := odinsyntax.range_stmt_vars(&rs); ok && has_ref_var(vars) {
            if expr, has := odinsyntax.range_stmt_expr(&rs); has {
                escape(w, expr)
            }
        }
    case .Type_Switch_Stmt:
        ts, _ := odinsyntax.as_type_switch_stmt(n)
        if vars, ok := odinsyntax.type_switch_stmt_vars(&ts); ok && has_ref_var(vars) {
            if subject, has := odinsyntax.type_switch_stmt_subject(&ts); has {
                escape(w, subject)
            }
        }
    case .Using_Stmt:
        us, _ := odinsyntax.as_using_stmt(n)
        if exprs, ok := odinsyntax.using_stmt_exprs(&us); ok {
            items := odinsyntax.expr_list_items(&exprs)
            for item in odinsyntax.child_iter_next(&items) {
                escape(w, item)
            }
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = LIVE_ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        scan(w, child)
    }
}

@(private = "file")
add_span :: proc(w: ^Live_Walk, n: odinsyntax.Syntax_Node) {
    start, end := odinsyntax.node_range(n)
    append(&w.untaken, Span{int(start), int(end)})
}

@(private = "file")
scan_decl :: proc(w: ^Live_Walk, n: odinsyntax.Syntax_Node) {
    v, _ := odinsyntax.as_value_decl(n)
    attrs := odinsyntax.value_decl_attributes(&v)
    _, has_attrs := odinsyntax.child_iter_next(&attrs)
    names, has_names := odinsyntax.value_decl_names(&v)
    if !has_names {
        return
    }
    it := odinsyntax.name_list_names(&names)
    n := n
    for name in odinsyntax.child_iter_next(&it) {
        if has_attrs {
            append(&w.attrs, int(name.offset))
            continue
        }
        if value, _, ok := decl_value(&n, int(name.offset)); ok && has_call(w, value) {
            w.computed[int(name.offset)] = true
        }
    }
}

// True for `v` and `&v` lists that hold a `&v`.
@(private = "file")
has_ref_var :: proc(vars: odinsyntax.Expr_List) -> bool {
    vars := vars
    it := odinsyntax.expr_list_items(&vars)
    for item in odinsyntax.child_iter_next(&it) {
        if item.green.kind == .Unary_Expr {
            return true
        }
    }
    return false
}

// Excludes the local at the root of the place `n`: `x`, `x.f`, `x[i]`, `x[a:b]`, `(x)`.
@(private = "file")
escape :: proc(w: ^Live_Walk, n: odinsyntax.Syntax_Node) {
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
        case .Slice_Expr:
            se, _ := odinsyntax.as_slice_expr(n)
            next, ok = odinsyntax.slice_expr_operand(&se)
        case .Type_Assertion:
            ta, _ := odinsyntax.as_type_assertion(n)
            next, ok = odinsyntax.type_assertion_operand(&ta)
        case .Ident:
            if i, found := find_ref(w, int(n.offset)); found {
                w.tracked[w.refs[i].local].excluded = true
            }
        }
        if !ok {
            return
        }
        n = next
    }
}

// The index into Live_Walk.refs of the reference at `start`.
@(private = "file")
find_ref :: proc(w: ^Live_Walk, start: int) -> (int, bool) {
    i, found := slice.binary_search_by(w.refs[:], start, proc(r: Live_Ref, s: int) -> slice.Ordering {return slice.cmp(r.start, s)})
    return i, found
}

// True when `n` holds a call outside a nested procedure literal. A conversion `T(x)` and a call
// with a constant value do not count.
@(private = "file")
has_call :: proc(w: ^Live_Walk, n: odinsyntax.Syntax_Node) -> bool {
    n := n
    #partial switch n.green.kind {
    case .Call_Expr:
        ce, _ := odinsyntax.as_call_expr(n)
        callee, has_callee := odinsyntax.call_expr_callee(&ce)
        if !has_callee {
            return true
        }
        if expr_type(w.c, w.file, callee).mode != .Type && expr_type(w.c, w.file, n).mode != .Const {
            return true
        }
    case .Proc_Lit:
        return false
    }
    it := odinsyntax.child_iter(&n, {kinds = LIVE_ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        if has_call(w, child) {
            return true
        }
    }
    return false
}

// A compound statement whose parts are steps of their own.
is_compound :: proc(kind: odinsyntax.Syntax_Kind) -> bool {
    #partial switch kind {
    case .Block, .Do_Body, .If_Stmt, .When_Stmt, .For_Stmt, .Range_Stmt, .Switch_Stmt, .Type_Switch_Stmt, .Defer_Stmt, .Foreign_Block:
        return true
    }
    return false
}

// True when `n` holds an `or_return`, `or_break` or `or_continue` outside a nested procedure literal.
@(private = "file")
has_or_branch :: proc(n: odinsyntax.Syntax_Node) -> bool {
    n := n
    #partial switch n.green.kind {
    case .Or_Return_Expr, .Or_Branch_Expr:
        return true
    case .Proc_Lit:
        return false
    }
    it := odinsyntax.child_iter(&n, {kinds = LIVE_ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        if has_or_branch(child) {
            return true
        }
    }
    return false
}

Bits :: []u64

bits_has :: #force_inline proc(b: Bits, i: int) -> bool {
    return b[i >> 6] & (1 << uint(i & 63)) != 0
}

bits_set :: #force_inline proc(b: Bits, i: int) {
    b[i >> 6] |= 1 << uint(i & 63)
}

bits_clear :: #force_inline proc(b: Bits, i: int) {
    b[i >> 6] &~= 1 << uint(i & 63)
}

// Live before the step, from live after it.
@(private = "file")
transfer :: proc(live: Bits, e: Effect) {
    for d in e.defs {
        bits_clear(live, d.local)
    }
    for u in e.uses {
        bits_set(live, u)
    }
}

// Backward may-liveness over the graph of `lit`, then each reportable def whose local is not live
// after it.
@(private = "file")
dead_stores :: proc(w: ^Live_Walk, lit: odinsyntax.Syntax_Node, out: ^Liveness_Report) -> mem.Allocator_Error {
    g := cfg_cached(w.c, w.file, lit)
    if g == nil {
        return nil
    }
    reach := cfg_reachable(g, w.alloc)
    effects := make([][]Effect, len(g.blocks), w.alloc)
    covered := make([]bool, len(w.refs), w.alloc)
    for blk, b in g.blocks {
        effects[b] = make([]Effect, len(blk.steps), w.alloc)
        for s, i in blk.steps {
            if s.kind == .Stmt && is_compound(s.node.green.kind) {
                continue
            }
            e := &effects[b][i]
            e.defs = make([dynamic]Def, w.alloc)
            e.uses = make([dynamic]int, w.alloc)
            start, end := odinsyntax.node_range(s.node)
            or_branch := s.kind == .Stmt && has_or_branch(s.node)
            first, _ := slice.binary_search_by(w.refs[:], int(start), proc(r: Live_Ref, s: int) -> slice.Ordering {return slice.cmp(r.start, s)})
            for j := first; j < len(w.refs) && w.refs[j].start < int(end); j += 1 {
                r := w.refs[j]
                covered[j] = true
                is_def := s.kind != .Defer_Run && (r.is_decl || r.is_store)
                if !is_def {
                    if !reach[b] && s.kind != .Defer_Run {
                        // A value read only in dead code: left to the unreachable-code report.
                        w.tracked[r.local].excluded = true
                    }
                    append(&e.uses, r.local)
                    continue
                }
                if or_branch {
                    continue
                }
                l := w.m.locals[w.tracked[r.local].local]
                reportable := r.is_store || (l.value_offset >= 0 && w.computed[r.start])
                append(&e.defs, Def{r.local, r.start, reportable})
            }
        }
    }
    for r, j in w.refs {
        if !covered[j] && !r.is_decl {
            w.tracked[r.local].excluded = true
        }
    }

    words := (len(w.tracked) + 63) / 64
    live_in := make([]Bits, len(g.blocks), w.alloc)
    live_out := make([]Bits, len(g.blocks), w.alloc)
    for b in 0 ..< len(g.blocks) {
        live_in[b] = make(Bits, words, w.alloc)
        live_out[b] = make(Bits, words, w.alloc)
    }
    for t, i in w.tracked {
        if w.m.locals[t.local].kind == .Result {
            bits_set(live_in[g.exit], i)
        }
    }
    tmp := make(Bits, words, w.alloc)
    for changed := true; changed; {
        changed = false
        #reverse for blk, b in g.blocks {
            if Block_Id(b) == g.exit {
                continue
            }
            for &word in live_out[b] {
                word = 0
            }
            for s in blk.succs {
                for word, k in live_in[s] {
                    live_out[b][k] |= word
                }
            }
            copy(tmp, live_out[b])
            #reverse for e in effects[b] {
                transfer(tmp, e)
            }
            if !slice.equal(tmp, live_in[b]) {
                copy(live_in[b], tmp)
                changed = true
            }
        }
    }

    for _, b in g.blocks {
        if !reach[b] {
            continue
        }
        copy(tmp, live_out[b])
        #reverse for e in effects[b] {
            for d in e.defs {
                t := w.tracked[d.local]
                if d.reportable && t.reportable && !t.excluded && !bits_has(tmp, d.local) {
                    name := w.m.locals[t.local].name
                    append(&out.dead_stores, Live_Name{d.offset, name}) or_return
                }
            }
            transfer(tmp, e)
        }
    }
    return nil
}
