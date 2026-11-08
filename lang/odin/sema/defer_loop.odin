// A `defer` in a loop body that frees what the loop does not own (`defer/in-loop`).
package odinsema

import "core:strings"

import odinsyntax "../syntax"

// Names a deferred call has when it releases its argument.
@(private = "file")
RELEASE_WORDS := [?]string{"delete", "free", "destroy", "close", "release"}

// The offsets of the `defer` statements of the body of the loop `loop` that release a variable
// declared outside the loop: they run on every iteration, so the second one frees it again.
// A nested procedure literal and a nested loop are left out; a nested loop is a loop of its own.
loop_defers :: proc(m: ^Scope_Map, loop: odinsyntax.Syntax_Node, allocator := context.allocator) -> []int {
    loop := loop
    body: odinsyntax.Syntax_Node
    ok: bool
    #partial switch loop.green.kind {
    case .For_Stmt:
        f, _ := odinsyntax.as_for_stmt(loop)
        body, ok = odinsyntax.for_stmt_body(&f)
    case .Range_Stmt:
        r, _ := odinsyntax.as_range_stmt(loop)
        body, ok = odinsyntax.range_stmt_body(&r)
    }
    if !ok {
        return nil
    }
    found := make([dynamic]int, allocator)
    collect_defers(m, int(loop.offset), body, &found)
    return found[:]
}

@(private = "file")
collect_defers :: proc(m: ^Scope_Map, loop_start: int, n: odinsyntax.Syntax_Node, found: ^[dynamic]int) {
    n := n
    #partial switch n.green.kind {
    case .Defer_Stmt:
        if releases_outer(m, loop_start, n) {
            append(found, int(n.offset))
        }
    case .Proc_Lit, .For_Stmt, .Range_Stmt:
        return
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        collect_defers(m, loop_start, child, found)
    }
}

// True when the deferred call is a release and every local it names is declared before the loop.
@(private = "file")
releases_outer :: proc(m: ^Scope_Map, loop_start: int, d: odinsyntax.Syntax_Node) -> bool {
    d := d
    ds, _ := odinsyntax.as_defer_stmt(d)
    stmt := odinsyntax.defer_stmt_stmt(&ds) or_return
    if stmt.green.kind != .Expr_Stmt {
        return false
    }
    es, _ := odinsyntax.as_expr_stmt(stmt)
    call := odinsyntax.expr_stmt_expr(&es) or_return
    if call.green.kind != .Call_Expr {
        return false
    }
    ce, _ := odinsyntax.as_call_expr(call)
    callee := odinsyntax.call_expr_callee(&ce) or_return
    if !release_name(odinsyntax.node_text(callee)) {
        return false
    }
    start := int(d.offset)
    end := start + int(d.green.text_len)
    outer := 0
    for r in m.refs {
        if r.start < start || r.start >= end || r.kind != .Local {
            continue
        }
        if r.decl >= loop_start {
            return false
        }
        outer += 1
    }
    return outer > 0
}

// True when the last segment of the callee `text` names a release.
@(private = "file")
release_name :: proc(text: string) -> bool {
    name := text
    if i := strings.last_index_byte(name, '.'); i >= 0 {
        name = name[i + 1:]
    }
    for word in RELEASE_WORDS {
        if strings.contains(name, word) {
            return true
        }
    }
    return false
}
