package odinsema

import "core:mem"
import "core:slice"
import "core:strings"

import odinsyntax "../syntax"

// The ownership results of one procedure body. A name borrows the text of the parse.
Ownership_Report :: struct {
    leaks:           [dynamic]Live_Name, // the allocation of a value that a path leaves unfreed
    double_frees:    [dynamic]Live_Name, // a free of a value that every path to it already freed
    uses_after_free: [dynamic]Live_Name, // a use of a value that every path to it already freed
}

@(private = "file")
Own_Kind :: enum u8 {
    Alloc,  // the local gets a fresh allocation
    Free,   // the local is passed to a free
    Use,    // the local is read
    Escape, // the local is handed on: returned, stored, passed to a call, sliced, address taken
    Reset,  // the local gets a value that is not an allocation
}

@(private = "file")
Own_Event :: struct {
    kind:   Own_Kind,
    local:  int, // index into Own_Walk.cands
    offset: int,
}

@(private = "file")
Own_Cand :: struct {
    name:   string,
    decl:   int, // the name offset of the declaration
    offset: int, // the first allocation of it
}

@(private = "file")
Own_Walk :: struct {
    c:      ^Checker,
    file:   File_Id,
    refs:   [dynamic]Name_Ref, // the local references of the body, by start
    locals: map[int]bool,      // the name offsets of the plain variables of the body
    cands:  [dynamic]Own_Cand,
    by_decl: map[int]int,      // name offset -> index into cands
}

@(private = "file")
Callee_Class :: enum u8 {
    Other,
    Free,   // takes the value back
    Borrow, // reads the value and keeps no reference to it
}

@(private = "file")
BORROWING_BUILTINS :: [?]string{"len", "cap", "clear", "resize", "reserve", "shrink", "pop", "pop_safe", "pop_front", "ordered_remove", "unordered_remove", "copy", "raw_data", "min", "max", "abs", "clamp"}

@(private = "file")
BORROWING_PACKAGES :: [?]string{"fmt", "log"}

// The `strings`, `slice` and `fmt` procedures that return a new allocation.
@(private = "file")
allocating_package_proc :: proc(pkg, name: string) -> bool {
    switch pkg {
    case "strings":
        switch name {
        case "clone", "clone_to_cstring", "concatenate", "join", "to_upper", "to_lower", "repeat":
            return true
        }
    case "slice":
        return name == "clone"
    case "fmt":
        switch name {
        case "aprintf", "aprint", "aprintln":
            return true
        }
    }
    return false
}

// The allocation, double-free and use-after-free findings of the procedure literal `lit`, from the
// scope map `m` of its file. A local is followed from a `make`, `new`, `new_clone` or a few `strings`
// calls with the default allocator to the free, or to the place it is handed on; the follow stops
// where the value leaves the procedure's hands, so only a value that no path hands on is reported.
ownership :: proc(c: ^Checker, file: File_Id, m: ^Scope_Map, lit: odinsyntax.Syntax_Node, allocator := context.allocator) -> (out: Ownership_Report, err: mem.Allocator_Error) {
    out.leaks = make([dynamic]Live_Name, allocator)
    out.double_frees = make([dynamic]Live_Name, allocator)
    out.uses_after_free = make([dynamic]Live_Name, allocator)
    pl, is_lit := odinsyntax.as_proc_lit(lit)
    if !is_lit || m == nil {
        return
    }
    body, has_body := odinsyntax.proc_lit_body(&pl)
    if !has_body {
        return
    }
    text := odinsyntax.node_text(body)
    if strings.contains(text, "context.allocator =") || strings.contains(text, "context.allocator=") || strings.contains(text, "context =") {
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
    w := Own_Walk {
        c       = c,
        file    = file,
        refs    = make([dynamic]Name_Ref, alloc),
        locals  = make(map[int]bool, alloc),
        cands   = make([dynamic]Own_Cand, alloc),
        by_decl = make(map[int]int, alloc),
    }
    for l in m.locals {
        if l.kind == .Var && !l.is_using && l.name_offset >= int(lit_start) && l.name_offset < int(lit_end) && m.scopes[l.scope].proc_depth == depth {
            w.locals[l.name_offset] = true
        }
    }
    if len(w.locals) == 0 {
        return
    }
    for r in m.refs {
        if r.kind == .Local && r.start >= int(lit_start) && r.start < int(lit_end) {
            append(&w.refs, r) or_return
        }
    }
    slice.sort_by(w.refs[:], proc(a, b: Name_Ref) -> bool {return a.start < b.start})
    find_allocs(&w, body) or_return
    if len(w.cands) == 0 {
        return
    }
    ownership_flow(&w, lit, &out) or_return
    slice.sort_by(out.leaks[:], name_less)
    slice.sort_by(out.double_frees[:], name_less)
    slice.sort_by(out.uses_after_free[:], name_less)
    return
}

@(private = "file")
name_less :: proc(a, b: Live_Name) -> bool {
    return a.offset < b.offset
}

ownership_destroy :: proc(r: ^Ownership_Report) {
    delete(r.leaks)
    delete(r.double_frees)
    delete(r.uses_after_free)
}

// The reference at `start`, when the body has one there.
@(private = "file")
ref_at :: proc(w: ^Own_Walk, start: int) -> (Name_Ref, bool) {
    i, found := slice.binary_search_by(w.refs[:], start, proc(r: Name_Ref, s: int) -> slice.Ordering {return slice.cmp(r.start, s)})
    if !found {
        return {}, false
    }
    return w.refs[i], true
}

// The candidate an identifier uses. A declaration is not a use.
@(private = "file")
use_cand :: proc(w: ^Own_Walk, n: odinsyntax.Syntax_Node) -> (int, bool) {
    if n.green.kind != .Ident {
        return 0, false
    }
    r, found := ref_at(w, int(n.offset))
    if !found || r.is_decl {
        return 0, false
    }
    index, is_cand := w.by_decl[r.decl]
    return index, is_cand
}

// The items of a list, temp-allocated.
@(private = "file")
list_items :: proc(list: odinsyntax.Expr_List) -> [dynamic]odinsyntax.Syntax_Node {
    list := list
    out := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
    it := odinsyntax.expr_list_items(&list)
    for item in odinsyntax.child_iter_next(&it) {
        append(&out, item)
    }
    return out
}

@(private = "file")
unparen :: proc(n: odinsyntax.Syntax_Node) -> odinsyntax.Syntax_Node {
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

// The package name and the procedure name of a callee: `strings.clone` is ("strings", "clone"), `free` is ("", "free").
@(private = "file")
callee_names :: proc(callee: odinsyntax.Syntax_Node) -> (pkg, name: string, operand: odinsyntax.Syntax_Node) {
    if callee.green.kind == .Ident {
        return "", odinsyntax.node_text(callee), {}
    }
    sel, is_sel := odinsyntax.as_selector_expr(callee)
    if !is_sel {
        return
    }
    if _, arrow := odinsyntax.selector_expr_arrow(&sel); arrow {
        return
    }
    op, has_op := odinsyntax.selector_expr_operand(&sel)
    field, has_field := odinsyntax.selector_expr_field(&sel)
    if !has_op || !has_field || op.green.kind != .Ident {
        return
    }
    return odinsyntax.node_text(op), odinsyntax.node_text(odinsyntax.Syntax_Node(field)), op
}

// True when `name` is a procedure that takes a value back.
@(private = "file")
free_name :: proc(name: string) -> bool {
    return name == "free" || name == "delete" || name == "destroy" || strings.has_prefix(name, "delete_") || strings.has_prefix(name, "free_") || strings.has_prefix(name, "destroy_") || strings.has_suffix(name, "_destroy") || strings.has_suffix(name, "_delete") || strings.has_suffix(name, "_free")
}

@(private = "file")
classify_callee :: proc(w: ^Own_Walk, callee: odinsyntax.Syntax_Node) -> Callee_Class {
    if builtin, ok := core_callee(w, callee); ok {
        if builtin == "delete" || builtin == "free" {
            return .Free
        }
        borrowing := BORROWING_BUILTINS
        if slice.contains(borrowing[:], builtin) {
            return .Borrow
        }
        return .Other
    }
    pkg, name, _ := callee_names(callee)
    if free_name(name) {
        return .Free
    }
    packages := BORROWING_PACKAGES
    if pkg != "" && slice.contains(packages[:], pkg) {
        return .Borrow
    }
    return .Other
}

// True when `expr` is a call that returns a new allocation from the default allocator.
@(private = "file")
alloc_call :: proc(w: ^Own_Walk, expr: odinsyntax.Syntax_Node) -> bool {
    e := unparen(expr)
    if e.green.kind != .Call_Expr {
        return false
    }
    ce, _ := odinsyntax.as_call_expr(e)
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    if !has_callee {
        return false
    }
    if name, ok := core_callee(w, callee); ok {
        if name != "make" && name != "new" && name != "new_clone" {
            return false
        }
    } else {
        pkg, pname, operand := callee_names(callee)
        if pkg == "" || !allocating_package_proc(pkg, pname) || expr_type(w.c, w.file, operand).mode != .Package {
            return false
        }
    }
    args, has_args := odinsyntax.call_expr_args(&ce)
    if !has_args {
        return true
    }
    it := odinsyntax.arg_list_args(&args)
    for arg in odinsyntax.child_iter_next(&it) {
        text := odinsyntax.node_text(arg)
        if !strings.contains(text, "allocator") {
            continue
        }
        compact, _ := strings.replace_all(text, " ", "", context.temp_allocator)
        if compact != "context.allocator" && compact != "allocator=context.allocator" {
            return false
        }
    }
    return true
}

// Notes the locals that get an allocation, from a declaration or a plain `=`.
@(private = "file")
find_allocs :: proc(w: ^Own_Walk, n: odinsyntax.Syntax_Node) -> mem.Allocator_Error {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit:
        return nil
    case .Value_Decl:
        v, _ := odinsyntax.as_value_decl(n)
        attrs := odinsyntax.value_decl_attributes(&v)
        _, has_attrs := odinsyntax.child_iter_next(&attrs)
        names, has_names := odinsyntax.value_decl_names(&v)
        values, has_values := odinsyntax.value_decl_values(&v)
        if !has_attrs && has_names && has_values {
            it := odinsyntax.name_list_names(&names)
            first, one := odinsyntax.child_iter_next(&it)
            _, more := odinsyntax.child_iter_next(&it)
            items := list_items(values)
            if one && !more && len(items) == 1 && w.locals[int(first.offset)] && alloc_call(w, items[0]) {
                add_cand(w, int(first.offset), int(first.offset), odinsyntax.node_text(first)) or_return
            }
        }
    case .Assign_Stmt:
        a, _ := odinsyntax.as_assign_stmt(n)
        lhs, has_lhs := odinsyntax.assign_stmt_lhs(&a)
        rhs, has_rhs := odinsyntax.assign_stmt_rhs(&a)
        if has_lhs && has_rhs {
            l, r := list_items(lhs), list_items(rhs)
            if len(l) == 1 && len(r) == 1 && l[0].green.kind == .Ident && alloc_call(w, r[0]) {
                if ref, found := ref_at(w, int(l[0].offset)); found && ref.is_store && w.locals[ref.decl] {
                    add_cand(w, ref.decl, int(l[0].offset), odinsyntax.node_text(l[0])) or_return
                }
            }
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        find_allocs(w, child) or_return
    }
    return nil
}

@(private = "file")
add_cand :: proc(w: ^Own_Walk, decl, offset: int, name: string) -> mem.Allocator_Error {
    if decl in w.by_decl {
        return nil
    }
    w.by_decl[decl] = len(w.cands)
    _, err := append(&w.cands, Own_Cand{name, decl, offset})
    return err
}

// True for a parent whose direct identifier children are handed on.
@(private = "file")
hands_on :: proc(kind: odinsyntax.Syntax_Kind) -> bool {
    #partial switch kind {
    case .Expr_List, .Arg_List, .Field_Value, .Spread_Expr, .Cast_Expr, .Auto_Cast_Expr, .Comp_Lit, .Slice_Expr:
        return true
    }
    return false
}

// Appends the events of the syntax under `n` in source order. `esc` is true when `n` itself is handed on.
@(private = "file")
walk_own :: proc(w: ^Own_Walk, n: odinsyntax.Syntax_Node, esc: bool, out: ^[dynamic]Own_Event) {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit:
        return
    case .Ident:
        if index, ok := use_cand(w, n); ok {
            append(out, Own_Event{esc ? .Escape : .Use, index, int(n.offset)})
        }
        return
    case .Call_Expr:
        call_events(w, n, out)
        return
    }
    child_esc := hands_on(n.green.kind) || (n.green.kind == .Paren_Expr && esc)
    if n.green.kind == .Unary_Expr {
        u, _ := odinsyntax.as_unary_expr(n)
        if op, ok := odinsyntax.unary_expr_op(&u); ok && op.green.kind == .And {
            child_esc = true
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        walk_own(w, child, child_esc, out)
    }
}

// The target of an argument that is a local: `x`, `(x)`, `&x`, `name = x`.
@(private = "file")
arg_target :: proc(n: odinsyntax.Syntax_Node) -> odinsyntax.Syntax_Node {
    n := n
    for {
        #partial switch n.green.kind {
        case .Field_Value:
            fv, _ := odinsyntax.as_field_value(n)
            inner, ok := odinsyntax.field_value_value(&fv)
            if !ok {
                return n
            }
            n = inner
        case .Paren_Expr:
            n = unparen(n)
            if n.green.kind == .Paren_Expr {
                return n
            }
        case .Unary_Expr:
            u, _ := odinsyntax.as_unary_expr(n)
            op, has_op := odinsyntax.unary_expr_op(&u)
            operand, has_operand := odinsyntax.unary_expr_operand(&u)
            if !has_op || !has_operand || op.green.kind != .And {
                return n
            }
            n = operand
        case:
            return n
        }
    }
}

@(private = "file")
call_events :: proc(w: ^Own_Walk, call: odinsyntax.Syntax_Node, out: ^[dynamic]Own_Event) {
    ce, _ := odinsyntax.as_call_expr(call)
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    if !has_callee {
        return
    }
    class := classify_callee(w, callee)
    walk_own(w, callee, false, out)
    args, has_args := odinsyntax.call_expr_args(&ce)
    if !has_args {
        return
    }
    it := odinsyntax.arg_list_args(&args)
    for arg in odinsyntax.child_iter_next(&it) {
        target := arg_target(arg)
        index, is_cand := use_cand(w, target)
        if !is_cand {
            walk_own(w, arg, false, out)
            continue
        }
        kind := Own_Kind.Escape
        switch class {
        case .Free:
            kind = .Free
        case .Borrow:
            kind = .Use
        case .Other:
        }
        append(out, Own_Event{kind, index, int(target.offset)})
    }
}

@(private = "file")
step_events :: proc(w: ^Own_Walk, s: Cfg_Step, out: ^[dynamic]Own_Event) {
    n := s.node
    if s.kind == .Stmt {
        if is_compound(n.green.kind) {
            return
        }
        #partial switch n.green.kind {
        case .Value_Decl:
            decl_events(w, n, out)
            return
        case .Assign_Stmt:
            assign_events(w, n, out)
            return
        }
    }
    walk_own(w, n, false, out)
}

@(private = "file")
decl_events :: proc(w: ^Own_Walk, n: odinsyntax.Syntax_Node, out: ^[dynamic]Own_Event) {
    v, _ := odinsyntax.as_value_decl(n)
    values, has_values := odinsyntax.value_decl_values(&v)
    if !has_values {
        return
    }
    if names, has_names := odinsyntax.value_decl_names(&v); has_names {
        it := odinsyntax.name_list_names(&names)
        first, one := odinsyntax.child_iter_next(&it)
        _, more := odinsyntax.child_iter_next(&it)
        items := list_items(values)
        if index, is_cand := w.by_decl[int(first.offset)]; one && !more && is_cand && len(items) == 1 && alloc_call(w, items[0]) {
            walk_own(w, items[0], false, out)
            append(out, Own_Event{.Alloc, index, int(first.offset)})
            return
        }
    }
    walk_own(w, odinsyntax.Syntax_Node(values), true, out)
}

@(private = "file")
assign_events :: proc(w: ^Own_Walk, n: odinsyntax.Syntax_Node, out: ^[dynamic]Own_Event) {
    a, _ := odinsyntax.as_assign_stmt(n)
    lhs, has_lhs := odinsyntax.assign_stmt_lhs(&a)
    rhs, has_rhs := odinsyntax.assign_stmt_rhs(&a)
    if !has_lhs || !has_rhs {
        return
    }
    targets, values := list_items(lhs), list_items(rhs)
    allocating := len(targets) == 1 && len(values) == 1 && alloc_call(w, values[0])
    if allocating {
        walk_own(w, values[0], false, out)
    } else {
        walk_own(w, odinsyntax.Syntax_Node(rhs), true, out)
    }
    for t in targets {
        if t.green.kind == .Ident {
            if ref, found := ref_at(w, int(t.offset)); found && ref.is_store {
                if index, is_cand := w.by_decl[ref.decl]; is_cand {
                    append(out, Own_Event{allocating ? .Alloc : .Reset, index, int(t.offset)})
                    continue
                }
            }
        }
        walk_own(w, t, false, out)
    }
}

// What a path knows about each candidate: `owned` if some path allocated and did not hand on or free
// it, `freed` if every path freed it.
@(private = "file")
Own_State :: struct {
    owned: Bits,
    freed: Bits,
}

@(private = "file")
Own_Findings :: struct {
    out:  ^Ownership_Report,
    seen: map[int]bool, // the offsets reported
}

@(private = "file")
apply_event :: proc(w: ^Own_Walk, s: Own_State, e: Own_Event, found: ^Own_Findings) {
    freed := bits_has(s.freed, e.local)
    name := w.cands[e.local].name
    switch e.kind {
    case .Alloc:
        bits_set(s.owned, e.local)
        bits_clear(s.freed, e.local)
        return
    case .Reset:
        bits_clear(s.owned, e.local)
        bits_clear(s.freed, e.local)
        return
    case .Free:
        if freed && found != nil && e.offset not_in found.seen {
            found.seen[e.offset] = true
            append(&found.out.double_frees, Live_Name{e.offset, name})
        }
        bits_set(s.freed, e.local)
        bits_clear(s.owned, e.local)
    case .Use:
        if freed && found != nil && e.offset not_in found.seen {
            found.seen[e.offset] = true
            append(&found.out.uses_after_free, Live_Name{e.offset, name})
        }
    case .Escape:
        if freed && found != nil && e.offset not_in found.seen {
            found.seen[e.offset] = true
            append(&found.out.uses_after_free, Live_Name{e.offset, name})
        }
        bits_clear(s.owned, e.local)
    }
}

// Forward dataflow over the graph of `lit`: owned is a may-fact, freed a must-fact.
@(private = "file")
ownership_flow :: proc(w: ^Own_Walk, lit: odinsyntax.Syntax_Node, out: ^Ownership_Report) -> mem.Allocator_Error {
    alloc := context.temp_allocator
    g := cfg_build(w.c, w.file, lit, alloc) or_return
    if g == nil {
        return nil
    }
    defer cfg_destroy(g, alloc)
    reach := cfg_reachable(g, alloc)
    events := make([][][dynamic]Own_Event, len(g.blocks), alloc)
    for blk, b in g.blocks {
        if !reach[b] {
            continue
        }
        events[b] = make([][dynamic]Own_Event, len(blk.steps), alloc)
        for s, i in blk.steps {
            events[b][i] = make([dynamic]Own_Event, alloc)
            step_events(w, s, &events[b][i])
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
    out_owned := make([]Bits, len(g.blocks), alloc)
    out_freed := make([]Bits, len(g.blocks), alloc)
    for b in 0 ..< len(g.blocks) {
        out_owned[b] = make(Bits, words, alloc)
        out_freed[b] = make(Bits, words, alloc)
        for &word in out_freed[b] {
            word = ~u64(0)
        }
    }
    cur := Own_State{make(Bits, words, alloc), make(Bits, words, alloc)}
    enter := proc(g: ^Cfg, b: int, preds: [][dynamic]int, out_owned, out_freed: []Bits, cur: Own_State) {
        for k in 0 ..< len(cur.owned) {
            cur.owned[k] = 0
            cur.freed[k] = 0
        }
        if Block_Id(b) == g.entry || len(preds[b]) == 0 {
            return
        }
        for k in 0 ..< len(cur.freed) {
            cur.freed[k] = ~u64(0)
        }
        for p in preds[b] {
            for k in 0 ..< len(cur.owned) {
                cur.owned[k] |= out_owned[p][k]
                cur.freed[k] &= out_freed[p][k]
            }
        }
    }
    for changed := true; changed; {
        changed = false
        for _, b in g.blocks {
            if !reach[b] {
                continue
            }
            enter(g, b, preds, out_owned, out_freed, cur)
            for list in events[b] {
                for e in list {
                    apply_event(w, cur, e, nil)
                }
            }
            if !slice.equal(cur.owned, out_owned[b]) || !slice.equal(cur.freed, out_freed[b]) {
                copy(out_owned[b], cur.owned)
                copy(out_freed[b], cur.freed)
                changed = true
            }
        }
    }

    found := Own_Findings{out, make(map[int]bool, alloc)}
    for _, b in g.blocks {
        if !reach[b] {
            continue
        }
        enter(g, b, preds, out_owned, out_freed, cur)
        for list in events[b] {
            for e in list {
                apply_event(w, cur, e, &found)
            }
        }
    }
    if reach[g.exit] {
        enter(g, int(g.exit), preds, out_owned, out_freed, cur)
        for cand, i in w.cands {
            if bits_has(cur.owned, i) {
                append(&out.leaks, Live_Name{cand.offset, cand.name}) or_return
            }
        }
    }
    return nil
}

// The name of a builtin or `base:runtime` procedure a callee names, unless a local shadows it.
@(private = "file")
core_callee :: proc(w: ^Own_Walk, callee: odinsyntax.Syntax_Node) -> (string, bool) {
    if name, ok := builtin_callee(w.c, w.file, callee); ok {
        return name, true
    }
    if callee.green.kind != .Ident {
        return "", false
    }
    name := odinsyntax.node_text(callee)
    if !is_builtin_proc(name) {
        return "", false
    }
    if lookup_name(w.c, w.file, name, int(callee.offset)).kind == .Local {
        return "", false
    }
    return name, true
}
