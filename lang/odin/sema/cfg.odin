package odinsema

import "core:mem"
import "core:mem/virtual"

import odinsyntax "../syntax"

// The control-flow graph of one procedure body: basic blocks of statements and the edges between
// them. A `defer` runs as a `Defer_Run` step on every exit edge of its scope. A statement after a
// terminator starts a block with no predecessors.
Cfg :: struct {
    arena:      virtual.Arena,
    blocks:     [dynamic]Cfg_Block,
    stmt_block: map[u32]Block_Id, // the block each statement starts in, by offset
    entry:      Block_Id,
    exit:       Block_Id,
}

Block_Id :: distinct i32

NO_BLOCK :: Block_Id(-1)

Cfg_Step_Kind :: enum u8 {
    Stmt,
    Defer_Run, // the statement of a `defer`, run where its scope is left
    Expr,      // a condition, tag, iterated value or case value of a compound statement
}

// One statement a block runs. `node.parent` is nil.
Cfg_Step :: struct {
    node: odinsyntax.Syntax_Node,
    kind: Cfg_Step_Kind,
}

Cfg_Block :: struct {
    steps: [dynamic]Cfg_Step,
    succs: [dynamic]Block_Id,
}

// Where a `break` or `continue` goes.
@(private = "file")
Cfg_Target :: struct {
    label:     string,
    brk:       Block_Id,
    cont:      Block_Id, // NO_BLOCK for a switch or a labelled block
    depth:     int,      // the scope count outside the statement
    implicit:  bool,     // an unlabelled `break` can reach it
}

@(private = "file")
Cfg_Builder :: struct {
    g:       ^Cfg,
    c:       ^Checker,
    file:    File_Id,
    alloc:   mem.Allocator,
    cur:     Block_Id,
    scopes:  [dynamic][dynamic]odinsyntax.Syntax_Node, // the `defer` statements of each open scope
    targets: [dynamic]Cfg_Target,
    fall:    Block_Id, // the block `fallthrough` goes to
    err:     mem.Allocator_Error,
}

@(private = "file")
CFG_ARENA_BLOCK :: 16 * mem.Kilobyte

@(private = "file")
ALL_KINDS :: ~odinsyntax.Kind_Set{}

// The graph of the body of the procedure literal `lit`; nil when it has no body. A nested procedure
// literal is not part of it.
cfg_build :: proc(c: ^Checker, file: File_Id, lit: odinsyntax.Syntax_Node, allocator := context.allocator) -> (g: ^Cfg, err: mem.Allocator_Error) {
    pl, is_lit := odinsyntax.as_proc_lit(lit)
    if !is_lit {
        return nil, nil
    }
    body, has_body := odinsyntax.proc_lit_body(&pl)
    if !has_body {
        return nil, nil
    }
    g = new(Cfg, allocator) or_return
    if err = virtual.arena_init_growing(&g.arena, CFG_ARENA_BLOCK); err != nil {
        free(g, allocator)
        return nil, err
    }
    b := Cfg_Builder {
        g     = g,
        c     = c,
        file  = file,
        alloc = virtual.arena_allocator(&g.arena),
        fall  = NO_BLOCK,
    }
    g.blocks = make([dynamic]Cfg_Block, b.alloc)
    g.stmt_block = make(map[u32]Block_Id, b.alloc)
    b.scopes = make([dynamic][dynamic]odinsyntax.Syntax_Node, b.alloc)
    b.targets = make([dynamic]Cfg_Target, b.alloc)
    g.entry = new_block(&b)
    g.exit = new_block(&b)
    b.cur = g.entry
    build_stmt(&b, body)
    edge(&b, b.cur, g.exit)
    if b.err != nil {
        err = b.err
        cfg_destroy(g, allocator)
        return nil, err
    }
    return g, nil
}

cfg_destroy :: proc(g: ^Cfg, allocator := context.allocator) {
    if g == nil {
        return
    }
    virtual.arena_destroy(&g.arena)
    free(g, allocator)
}

// Which blocks a path from the entry reaches.
cfg_reachable :: proc(g: ^Cfg, allocator := context.allocator) -> []bool {
    seen := make([]bool, len(g.blocks), allocator)
    stack := make([dynamic]Block_Id, context.temp_allocator)
    append(&stack, g.entry)
    seen[g.entry] = true
    for len(stack) > 0 {
        id := pop(&stack)
        for s in g.blocks[id].succs {
            if !seen[s] {
                seen[s] = true
                append(&stack, s)
            }
        }
    }
    return seen
}

// The block statement `stmt` starts in; false for a statement the graph does not hold.
cfg_stmt_block :: proc(g: ^Cfg, stmt: odinsyntax.Syntax_Node) -> (Block_Id, bool) {
    id, ok := g.stmt_block[stmt.offset]
    return id, ok
}

@(private = "file")
note :: proc(b: ^Cfg_Builder, err: mem.Allocator_Error) {
    if err != nil && b.err == nil {
        b.err = err
    }
}

@(private = "file")
new_block :: proc(b: ^Cfg_Builder) -> Block_Id {
    blk := Cfg_Block {
        steps = make([dynamic]Cfg_Step, b.alloc),
        succs = make([dynamic]Block_Id, b.alloc),
    }
    _, err := append(&b.g.blocks, blk)
    note(b, err)
    return Block_Id(len(b.g.blocks) - 1)
}

@(private = "file")
edge :: proc(b: ^Cfg_Builder, from, to: Block_Id) {
    if from == NO_BLOCK || to == NO_BLOCK {
        return
    }
    _, err := append(&b.g.blocks[from].succs, to)
    note(b, err)
}

@(private = "file")
step :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node, kind: Cfg_Step_Kind) {
    n := n
    n.parent = nil
    _, err := append(&b.g.blocks[b.cur].steps, Cfg_Step{n, kind})
    note(b, err)
}

// Ends the current block with no successor, as after `return` or a diverging call.
@(private = "file")
dead_end :: proc(b: ^Cfg_Builder) {
    b.cur = new_block(b)
}

@(private = "file")
open_scope :: proc(b: ^Cfg_Builder) {
    _, err := append(&b.scopes, make([dynamic]odinsyntax.Syntax_Node, b.alloc))
    note(b, err)
}

// Leaves the innermost scope by its end: its defers run, last first.
@(private = "file")
close_scope :: proc(b: ^Cfg_Builder) {
    run_defers(b, len(b.scopes) - 1)
    pop(&b.scopes)
}

// Runs the defers of every scope from the innermost down to scope `depth`, last first.
@(private = "file")
run_defers :: proc(b: ^Cfg_Builder, depth: int) {
    for i := len(b.scopes) - 1; i >= depth && i >= 0; i -= 1 {
        defers := b.scopes[i]
        for j := len(defers) - 1; j >= 0; j -= 1 {
            step(b, defers[j], .Defer_Run)
        }
    }
}

// Leaves the current path for `to` through the defers of the scopes down to `depth`, on a block of
// its own, so the defers do not run on the path that goes on.
@(private = "file")
jump :: proc(b: ^Cfg_Builder, to: Block_Id, depth: int) {
    from := b.cur
    b.cur = new_block(b)
    edge(b, from, b.cur)
    run_defers(b, depth)
    edge(b, b.cur, to)
    b.cur = from
}

// Goes on in a new block after a jump from the middle of a statement, so the steps after it are not
// on the path that left.
@(private = "file")
split :: proc(b: ^Cfg_Builder) {
    from := b.cur
    b.cur = new_block(b)
    edge(b, from, b.cur)
}

@(private = "file")
label_of :: proc(n: odinsyntax.Syntax_Node) -> string {
    n := n
    l, ok := odinsyntax.find_child_node(&n, {kinds = {.Label}})
    if !ok {
        return ""
    }
    lv, _ := odinsyntax.as_label(l)
    name, has_name := odinsyntax.label_name(&lv)
    return has_name ? odinsyntax.node_text(odinsyntax.Syntax_Node(name)) : ""
}

@(private = "file")
push_target :: proc(b: ^Cfg_Builder, label: string, brk, cont: Block_Id, implicit: bool) {
    _, err := append(&b.targets, Cfg_Target{label = label, brk = brk, cont = cont, depth = len(b.scopes), implicit = implicit})
    note(b, err)
}

// The target of a `break` (`is_continue` false) or `continue` with `label`, "" for none.
@(private = "file")
find_target :: proc(b: ^Cfg_Builder, label: string, is_continue: bool) -> (Cfg_Target, bool) {
    for i := len(b.targets) - 1; i >= 0; i -= 1 {
        t := b.targets[i]
        if label != "" {
            if t.label == label {
                return t, !is_continue || t.cont != NO_BLOCK
            }
            continue
        }
        if is_continue && t.cont != NO_BLOCK || !is_continue && t.implicit {
            return t, true
        }
    }
    return {}, false
}

@(private = "file")
branch :: proc(b: ^Cfg_Builder, label: string, is_continue: bool) {
    t, ok := find_target(b, label, is_continue)
    if !ok {
        return
    }
    jump(b, is_continue ? t.cont : t.brk, t.depth)
}

// Notes the block statement `n` starts in.
@(private = "file")
record :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    _, value, _, err := map_entry(&b.g.stmt_block, n.offset)
    if err != nil {
        note(b, err)
        return
    }
    value^ = b.cur
}

@(private = "file")
build_list :: proc(b: ^Cfg_Builder, stmts: odinsyntax.Child_Iter) {
    stmts := stmts
    for s in odinsyntax.child_iter_next(&stmts) {
        build_stmt(b, s)
    }
}

@(private = "file")
build_stmt :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    n := n
    if b.err != nil {
        return
    }
    record(b, n)
    step(b, n, .Stmt)
    #partial switch n.green.kind {
    case .Block:
        blk, _ := odinsyntax.as_block(n)
        label := label_of(n)
        after := NO_BLOCK
        if label != "" {
            after = new_block(b)
            push_target(b, label, after, NO_BLOCK, false)
        }
        open_scope(b)
        build_list(b, odinsyntax.block_stmts(&blk))
        close_scope(b)
        if label != "" {
            pop(&b.targets)
            edge(b, b.cur, after)
            b.cur = after
        }
    case .Do_Body:
        db, _ := odinsyntax.as_do_body(n)
        if s, ok := odinsyntax.do_body_stmt(&db); ok {
            open_scope(b)
            build_stmt(b, s)
            close_scope(b)
        }
    case .Return_Stmt:
        flow_children(b, n)
        jump(b, b.g.exit, 0)
        dead_end(b)
    case .Branch_Stmt:
        bs, _ := odinsyntax.as_branch_stmt(n)
        kw, ok := odinsyntax.branch_stmt_keyword(&bs)
        if !ok {
            return
        }
        label := ""
        if l, has_label := odinsyntax.branch_stmt_label(&bs); has_label {
            label = odinsyntax.node_text(odinsyntax.Syntax_Node(l))
        }
        #partial switch kw.green.kind {
        case .Break:
            branch(b, label, false)
        case .Continue:
            branch(b, label, true)
        case .Fallthrough:
            edge(b, b.cur, b.fall)
        }
        dead_end(b)
    case .Expr_Stmt:
        flow_children(b, n)
        es, _ := odinsyntax.as_expr_stmt(n)
        if expr, ok := odinsyntax.expr_stmt_expr(&es); ok && diverges_known(b.c, b.file, expr) {
            dead_end(b)
        }
    case .Value_Decl:
        if !is_constant_decl(n) {
            flow_children(b, n)
        }
    case .Defer_Stmt:
        ds, _ := odinsyntax.as_defer_stmt(n)
        if s, ok := odinsyntax.defer_stmt_stmt(&ds); ok && len(b.scopes) > 0 {
            s.parent = nil
            _, err := append(&b.scopes[len(b.scopes) - 1], s)
            note(b, err)
        }
    case .If_Stmt:
        build_if(b, n)
    case .When_Stmt:
        build_when(b, n)
    case .For_Stmt:
        build_for(b, n)
    case .Range_Stmt:
        build_range(b, n)
    case .Switch_Stmt, .Type_Switch_Stmt:
        build_switch(b, n)
    case .Foreign_Block, .Import_Decl, .Foreign_Import_Decl:
    case:
        flow_children(b, n)
    }
}

@(private = "file")
build_if :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    is, _ := odinsyntax.as_if_stmt(n)
    label := label_of(n)
    after := new_block(b)
    if label != "" {
        push_target(b, label, after, NO_BLOCK, false)
    }
    open_scope(b)
    if init, ok := odinsyntax.if_stmt_init(&is); ok {
        build_stmt(b, init)
    }
    if cond, ok := odinsyntax.if_stmt_cond(&is); ok {
        step(b, cond, .Expr)
        flow_expr(b, cond)
    }
    head := b.cur
    if body, ok := odinsyntax.if_stmt_body(&is); ok {
        b.cur = new_block(b)
        edge(b, head, b.cur)
        build_stmt(b, body)
        edge(b, b.cur, after)
    }
    if other, ok := odinsyntax.if_stmt_else_branch(&is); ok {
        b.cur = new_block(b)
        edge(b, head, b.cur)
        build_stmt(b, other)
        edge(b, b.cur, after)
    } else {
        edge(b, head, after)
    }
    b.cur = after
    pop(&b.scopes)
    if label != "" {
        pop(&b.targets)
    }
}

// A `when` body opens no scope. A branch the target does not take adds nothing. The code after a
// `when` stays reachable whatever its branches do, since another target or define can take
// another branch.
@(private = "file")
build_when :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    ws, _ := odinsyntax.as_when_stmt(n)
    cond, has_cond := odinsyntax.when_stmt_cond(&ws)
    body, has_body := odinsyntax.when_stmt_body(&ws)
    other, has_else := odinsyntax.when_stmt_else_branch(&ws)
    state := Tri.Unknown
    if has_cond {
        state = when_state(b.c, b.file, cond)
    }
    head := b.cur
    after := new_block(b)
    edge(b, head, after)
    if has_body && state != .False {
        b.cur = new_block(b)
        edge(b, head, b.cur)
        build_when_branch(b, body)
        edge(b, b.cur, after)
    }
    if has_else && state != .True {
        b.cur = new_block(b)
        edge(b, head, b.cur)
        build_when_branch(b, other)
        edge(b, b.cur, after)
    }
    b.cur = after
}

@(private = "file")
build_when_branch :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    n := n
    #partial switch n.green.kind {
    case .Block:
        record(b, n)
        blk, _ := odinsyntax.as_block(n)
        build_list(b, odinsyntax.block_stmts(&blk))
    case .Do_Body:
        db, _ := odinsyntax.as_do_body(n)
        if s, ok := odinsyntax.do_body_stmt(&db); ok {
            build_stmt(b, s)
        }
    case:
        build_stmt(b, n)
    }
}

@(private = "file")
build_for :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    fs, _ := odinsyntax.as_for_stmt(n)
    open_scope(b)
    if init, ok := odinsyntax.for_stmt_init(&fs); ok {
        build_stmt(b, init)
    }
    head := new_block(b)
    edge(b, b.cur, head)
    b.cur = head
    body := new_block(b)
    post := new_block(b)
    after := new_block(b)
    if cond, ok := odinsyntax.for_stmt_cond(&fs); ok {
        step(b, cond, .Expr)
        flow_expr(b, cond)
        edge(b, b.cur, after)
    }
    edge(b, b.cur, body)
    push_target(b, label_of(n), after, post, true)
    b.cur = body
    if s, ok := odinsyntax.for_stmt_body(&fs); ok {
        build_stmt(b, s)
    }
    edge(b, b.cur, post)
    b.cur = post
    if p, ok := odinsyntax.for_stmt_post(&fs); ok {
        build_stmt(b, p)
    }
    edge(b, b.cur, head)
    pop(&b.targets)
    pop(&b.scopes)
    b.cur = after
}

@(private = "file")
build_range :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    rs, _ := odinsyntax.as_range_stmt(n)
    open_scope(b)
    if init, ok := odinsyntax.range_stmt_init(&rs); ok {
        build_stmt(b, init)
    }
    if expr, ok := odinsyntax.range_stmt_expr(&rs); ok {
        step(b, expr, .Expr)
        flow_expr(b, expr)
    }
    head := new_block(b)
    edge(b, b.cur, head)
    body := new_block(b)
    after := new_block(b)
    edge(b, head, body)
    edge(b, head, after)
    push_target(b, label_of(n), after, head, true)
    b.cur = body
    if s, ok := odinsyntax.range_stmt_body(&rs); ok {
        build_stmt(b, s)
    }
    edge(b, b.cur, head)
    pop(&b.targets)
    pop(&b.scopes)
    b.cur = after
}

@(private = "file")
build_switch :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    body: odinsyntax.Block
    has_body := false
    open_scope(b)
    if n.green.kind == .Switch_Stmt {
        ss, _ := odinsyntax.as_switch_stmt(n)
        if init, ok := odinsyntax.switch_stmt_init(&ss); ok {
            build_stmt(b, init)
        }
        if tag, ok := odinsyntax.switch_stmt_tag(&ss); ok {
            step(b, tag, .Expr)
            flow_expr(b, tag)
        }
        body, has_body = odinsyntax.switch_stmt_body(&ss)
    } else {
        ts, _ := odinsyntax.as_type_switch_stmt(n)
        if subject, ok := odinsyntax.type_switch_stmt_subject(&ts); ok {
            step(b, subject, .Expr)
            flow_expr(b, subject)
        }
        body, has_body = odinsyntax.type_switch_stmt_body(&ts)
    }
    head := b.cur
    after := new_block(b)
    push_target(b, label_of(n), after, NO_BLOCK, true)
    has_default := false
    if has_body {
        clauses := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
        it := odinsyntax.child_iter((^odinsyntax.Syntax_Node)(&body), {kinds = {.Case_Clause}})
        for clause in odinsyntax.child_iter_next(&it) {
            append(&clauses, clause)
            cc, _ := odinsyntax.as_case_clause(clause)
            if values, has_values := odinsyntax.case_clause_values(&cc); has_values {
                step(b, odinsyntax.Syntax_Node(values), .Expr)
            }
        }
        starts := make([]Block_Id, len(clauses), context.temp_allocator)
        for &s in starts {
            s = new_block(b)
        }
        saved_fall := b.fall
        for clause, i in clauses {
            cc, _ := odinsyntax.as_case_clause(clause)
            if _, has_values := odinsyntax.case_clause_values(&cc); !has_values {
                has_default = true
            }
            b.cur = starts[i]
            edge(b, head, b.cur)
            b.fall = i + 1 < len(starts) ? starts[i + 1] : after
            open_scope(b)
            build_list(b, odinsyntax.case_clause_stmts(&cc))
            close_scope(b)
            edge(b, b.cur, after)
        }
        b.fall = saved_fall
    }
    if !has_default {
        edge(b, head, after)
    }
    pop(&b.targets)
    pop(&b.scopes)
    b.cur = after
}

// The flow inside the expressions under `n`: `or_return`, `or_break` and `or_continue` leave from
// the current block. A nested procedure literal is not followed.
@(private = "file")
flow_children :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    n := n
    it := odinsyntax.child_iter(&n, {kinds = ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        flow_expr(b, child)
    }
}

@(private = "file")
flow_expr :: proc(b: ^Cfg_Builder, n: odinsyntax.Syntax_Node) {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit:
        return
    case .Or_Return_Expr:
        flow_children(b, n)
        jump(b, b.g.exit, 0)
        split(b)
        return
    case .Or_Branch_Expr:
        flow_children(b, n)
        ob, _ := odinsyntax.as_or_branch_expr(n)
        kw, ok := odinsyntax.or_branch_expr_keyword(&ob)
        if !ok {
            return
        }
        label := ""
        if l, has_label := odinsyntax.or_branch_expr_label(&ob); has_label {
            label = odinsyntax.node_text(odinsyntax.Syntax_Node(l))
        }
        branch(b, label, kw.green.kind == .Or_Continue)
        split(b)
        return
    }
    flow_children(b, n)
}

// True when `expr` is a call of a procedure whose type says it does not return. A callee of unknown
// type does not count.
diverges_known :: proc(c: ^Checker, file: File_Id, expr: odinsyntax.Syntax_Node) -> bool {
    expr := expr
    for expr.green.kind == .Paren_Expr {
        pe, _ := odinsyntax.as_paren_expr(expr)
        inner, ok := odinsyntax.paren_expr_expr(&pe)
        if !ok {
            return false
        }
        expr = inner
    }
    ce, is_call := odinsyntax.as_call_expr(expr)
    if !is_call {
        return false
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    if !has_callee {
        return false
    }
    if _, is_directive := odinsyntax.as_directive(callee); is_directive {
        return false
    }
    fn := expr_type(c, file, callee)
    #partial switch fn.mode {
    case .Value, .Const, .Builtin:
        #partial switch v in type_get(&c.table, type_base(&c.table, fn.type)) {
        case Proc_Type:
            return v.diverging
        case Proc_Group_Type:
            for m in v.members {
                p, is_proc := type_get(&c.table, type_base(&c.table, m)).(Proc_Type)
                if !is_proc || !p.diverging {
                    return false
                }
            }
            return len(v.members) > 0
        }
        return fn.mode == .Builtin && fn.type == INVALID_TYPE && odinsyntax.node_text(callee) == "unreachable"
    }
    return false
}

// What `odin check` reports as "Statements after ... are never executed": a terminator followed in
// its statement list by a statement that is not a `::` declaration.
Never_Executed_Kind :: enum u8 {
    Return,
    Break,
    Continue,
    Diverging, // a call of a procedure that does not return
}

Never_Executed :: struct {
    offset: int, // the terminator
    kind:   Never_Executed_Kind,
}

// The results of a walk over the statement lists of one procedure body.
Unreachable_Report :: struct {
    never_executed: [dynamic]Never_Executed,
    defers:         [dynamic]int, // a `defer` in a list that ends with a diverging call
    dead:           [dynamic]int, // the first statement of each run the graph does not reach
}

@(private = "file")
Report_Walker :: struct {
    c:         ^Checker,
    file:      File_Id,
    g:         ^Cfg,
    reachable: []bool,
    out:       ^Unreachable_Report,
}

// The unreachable code of the procedure literal `lit`. A branch of a `when` the target may not take
// is not walked; a `defer` body counts for `never_executed` and `defers` only.
unreachable_code :: proc(c: ^Checker, file: File_Id, lit: odinsyntax.Syntax_Node, allocator := context.allocator) -> (out: Unreachable_Report, err: mem.Allocator_Error) {
    out.never_executed = make([dynamic]Never_Executed, allocator)
    out.defers = make([dynamic]int, allocator)
    out.dead = make([dynamic]int, allocator)
    g := cfg_build(c, file, lit, context.temp_allocator) or_return
    if g == nil {
        return
    }
    defer cfg_destroy(g, context.temp_allocator)
    w := Report_Walker {
        c         = c,
        file      = file,
        g         = g,
        reachable = cfg_reachable(g, context.temp_allocator),
        out       = &out,
    }
    pl, _ := odinsyntax.as_proc_lit(lit)
    if body, ok := odinsyntax.proc_lit_body(&pl); ok {
        report_stmt(&w, body, true)
    }
    return
}

// Walks the statement lists under `n`. `live` is false inside a run already reported dead or in a
// `defer` body.
@(private = "file")
report_stmt :: proc(w: ^Report_Walker, n: odinsyntax.Syntax_Node, live: bool) {
    n := n
    #partial switch n.green.kind {
    case .Block:
        blk, _ := odinsyntax.as_block(n)
        report_list(w, odinsyntax.block_stmts(&blk), live)
    case .Do_Body:
        db, _ := odinsyntax.as_do_body(n)
        if s, ok := odinsyntax.do_body_stmt(&db); ok {
            report_stmt(w, s, live)
        }
    case .Defer_Stmt:
        ds, _ := odinsyntax.as_defer_stmt(n)
        if s, ok := odinsyntax.defer_stmt_stmt(&ds); ok {
            report_stmt(w, s, false)
        }
    case .If_Stmt:
        is, _ := odinsyntax.as_if_stmt(n)
        if body, ok := odinsyntax.if_stmt_body(&is); ok {
            report_stmt(w, body, live)
        }
        if other, ok := odinsyntax.if_stmt_else_branch(&is); ok {
            report_stmt(w, other, live)
        }
    case .When_Stmt:
        ws, _ := odinsyntax.as_when_stmt(n)
        cond, has_cond := odinsyntax.when_stmt_cond(&ws)
        if !has_cond {
            return
        }
        switch when_state(w.c, w.file, cond) {
        case .True:
            if body, ok := odinsyntax.when_stmt_body(&ws); ok {
                report_stmt(w, body, live)
            }
        case .False:
            if other, ok := odinsyntax.when_stmt_else_branch(&ws); ok {
                report_stmt(w, other, live)
            }
        case .Unknown:
        }
    case .For_Stmt:
        fs, _ := odinsyntax.as_for_stmt(n)
        if body, ok := odinsyntax.for_stmt_body(&fs); ok {
            report_stmt(w, body, live)
        }
    case .Range_Stmt:
        rs, _ := odinsyntax.as_range_stmt(n)
        if body, ok := odinsyntax.range_stmt_body(&rs); ok {
            report_stmt(w, body, live)
        }
    case .Switch_Stmt, .Type_Switch_Stmt:
        body: odinsyntax.Block
        has_body := false
        if n.green.kind == .Switch_Stmt {
            ss, _ := odinsyntax.as_switch_stmt(n)
            body, has_body = odinsyntax.switch_stmt_body(&ss)
        } else {
            ts, _ := odinsyntax.as_type_switch_stmt(n)
            body, has_body = odinsyntax.type_switch_stmt_body(&ts)
        }
        if !has_body {
            return
        }
        it := odinsyntax.child_iter((^odinsyntax.Syntax_Node)(&body), {kinds = {.Case_Clause}})
        for clause in odinsyntax.child_iter_next(&it) {
            cc, _ := odinsyntax.as_case_clause(clause)
            report_list(w, odinsyntax.case_clause_stmts(&cc), live)
        }
    }
}

@(private = "file")
report_list :: proc(w: ^Report_Walker, stmts: odinsyntax.Child_Iter, live: bool) {
    list := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
    stmts := stmts
    for s in odinsyntax.child_iter_next(&stmts) {
        if s.green.kind == .Value_Decl && is_constant_decl(s) {
            continue
        }
        append(&list, s)
    }
    for s, i in list {
        if kind, is_term := terminator_kind(w, s); is_term && i + 1 < len(list) {
            append(&w.out.never_executed, Never_Executed{int(s.offset), kind})
        }
    }
    if len(list) > 0 {
        last := list[len(list) - 1]
        if kind, is_term := terminator_kind(w, last); is_term && kind == .Diverging {
            for s in list {
                if s.green.kind == .Defer_Stmt {
                    append(&w.out.defers, int(s.offset))
                }
            }
        }
    }
    in_run := !live
    for s, i in list {
        if !in_run && !stmt_reachable(w, s) {
            in_run = true
            // The compiler reports a statement right after a terminator.
            after_term := false
            if i > 0 {
                _, after_term = terminator_kind(w, list[i - 1])
            }
            // A last `return` or `unreachable()` after a loop that never ends is a guard, not dead code.
            guard := false
            if i == len(list) - 1 {
                kind, is_term := terminator_kind(w, s)
                guard = is_term && (kind == .Return || kind == .Diverging)
            }
            if !after_term && !guard {
                append(&w.out.dead, int(s.offset))
            }
        }
        report_stmt(w, s, !in_run)
    }
}

@(private = "file")
stmt_reachable :: proc(w: ^Report_Walker, s: odinsyntax.Syntax_Node) -> bool {
    id, ok := cfg_stmt_block(w.g, s)
    return !ok || w.reachable[id]
}

@(private = "file")
terminator_kind :: proc(w: ^Report_Walker, s: odinsyntax.Syntax_Node) -> (Never_Executed_Kind, bool) {
    s := s
    #partial switch s.green.kind {
    case .Return_Stmt:
        return .Return, true
    case .Branch_Stmt:
        bs, _ := odinsyntax.as_branch_stmt(s)
        kw, ok := odinsyntax.branch_stmt_keyword(&bs)
        if !ok {
            return {}, false
        }
        #partial switch kw.green.kind {
        case .Break:
            return .Break, true
        case .Continue:
            return .Continue, true
        }
    case .Expr_Stmt:
        es, _ := odinsyntax.as_expr_stmt(s)
        if expr, ok := odinsyntax.expr_stmt_expr(&es); ok && diverges_known(w.c, w.file, expr) {
            return .Diverging, true
        }
    }
    return {}, false
}
