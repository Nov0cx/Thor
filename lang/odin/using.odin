// `using` outside a struct: the statement (`using p`) and the parameter
// (`proc(using p: Point)`), both of which put a value's fields into the
// surrounding scope under their bare names. The compiler gates the statement
// behind `#+feature using-stmt`, but the grammar parses it and code that enables
// it must still resolve, so both are followed.
//
// An ordinary binding always wins: these answer only where lexical resolution
// found nothing, so a name that is both a local and a `using` field keeps the
// declaration it already had.
package odin

import "core:slice"
import "core:strings"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// How many `using` operands one caret consults, nearest first.
@(private)
USING_LIMIT :: 8

// One `using` in reach: the expression whose fields it opens, the scope it opens
// them in, and the offset they are visible from.
@(private = "file")
Using_Site :: struct {
    operand:     ts.Node,
    scope_start: int,
    scope_end:   int,
    from:        int,
}

// The operands of every `using` covering `offset`, nearest first and capped at
// USING_LIMIT. Temp-allocated. A file with no `using` written in it is answered
// without a walk, since every unresolved name asks this.
@(private)
using_operands :: proc(root: ts.Node, source: string, offset: int) -> []ts.Node {
    if !strings.contains(source, "using") {
        return nil
    }
    sites := make([dynamic]Using_Site, context.temp_allocator)
    collect_using_sites(root, &sites)

    in_reach := make([dynamic]Using_Site, context.temp_allocator)
    for s in sites {
        if offset >= s.from && offset >= s.scope_start && offset <= s.scope_end {
            append(&in_reach, s)
        }
    }
    slice.sort_by(in_reach[:], using_nearer)

    count := min(len(in_reach), USING_LIMIT)
    out := make([dynamic]ts.Node, 0, count, context.temp_allocator)
    for s in in_reach[:count] {
        append(&out, s.operand)
    }
    return out[:]
}

// Whether `a` opens a nearer scope than `b`: the narrower scope first, then the
// later `using` — the order lexical resolution reads a shadowing binding in.
@(private = "file")
using_nearer :: proc(a, b: Using_Site) -> bool {
    if a.scope_start != b.scope_start {
        return a.scope_start > b.scope_start
    }
    return a.from > b.from
}

// Every `using` in the tree. A statement opens its fields in the scope it sits
// in, from the point it is written; a parameter opens them over the whole
// procedure. A `using` with no scope around it is skipped — file scope is not one
// the grammar parses.
@(private = "file")
collect_using_sites :: proc(n: ts.Node, sites: ^[dynamic]Using_Site) {
    switch string(ts.node_type(n)) {
    case "using_statement":
        op := ts.node_named_child(n, 0)
        scope, ok := enclosing_scope(n)
        if !ts.node_is_null(op) && ok {
            append(sites, Using_Site {
                operand     = op,
                scope_start = int(ts.node_start_byte(scope)),
                scope_end   = int(ts.node_end_byte(scope)),
                from        = int(ts.node_end_byte(n)),
            })
        }
    case "parameter":
        id, ok := using_parameter(n)
        proc_node, pok := enclosing_procedure(n)
        if ok && pok {
            append(sites, Using_Site {
                operand     = id,
                scope_start = int(ts.node_start_byte(proc_node)),
                scope_end   = int(ts.node_end_byte(proc_node)),
                from        = int(ts.node_start_byte(proc_node)),
            })
        }
    }
    for i in 0 ..< ts.node_named_child_count(n) {
        collect_using_sites(ts.node_named_child(n, i), sites)
    }
}

// The name a parameter binds when it is written `using p: Point`. The `using` is
// an anonymous token, so the unnamed children are walked too.
@(private = "file")
using_parameter :: proc(n: ts.Node) -> (ts.Node, bool) {
    tagged := false
    for i in 0 ..< ts.node_child_count(n) {
        if string(ts.node_type(ts.node_child(n, i))) == "using" {
            tagged = true
            break
        }
    }
    id := ts.node_named_child(n, 0)
    if !tagged || !is_identifier(id) {
        return {}, false
    }
    return id, true
}

// The `procedure` a node sits in — the scope a `using` parameter opens over.
@(private = "file")
enclosing_procedure :: proc(node: ts.Node) -> (ts.Node, bool) {
    n := ts.node_parent(node)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == "procedure" {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Go-to-definition and hover for a bare `name` that a `using` opened into scope:
// the same member lookup `p.name` does, over each `using` operand in reach.
@(private)
resolve_using_member :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    name: string,
    hover_start, hover_end: int,
    res: ^lang.Result,
) -> bool {
    for op in using_operands(root, req.source, req.offset) {
        if resolve_member(e, parser, root, req, op, name, hover_start, hover_end, res) {
            return true
        }
    }
    return false
}

// Type of a bare `name` that a `using` opened into scope, for the inference that
// a chained access (`name.b`) needs.
@(private)
using_member_type :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    name: string,
    offset, depth: int,
) -> (Type_Ref, bool) {
    for op in using_operands(root, req.source, offset) {
        if tr, ok := member_field_type(e, parser, root, req, op, name, depth); ok {
            return tr, true
        }
    }
    return {}, false
}

// Completion candidates for the fields every `using` in reach opened, offered
// under their bare names beside the identifiers in scope.
@(private)
complete_using_fields :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    offset: int,
    prefix: string,
    res: ^lang.Result,
    seen: ^map[string]bool,
) {
    for op in using_operands(root, req.source, offset) {
        tr, ok := infer_expr_type(e, parser, root, req, op)
        if !ok || !type_is_bare(tr) {
            continue
        }
        ctx := Fields_Ctx {
            prefix = prefix,
            env    = Embed_Env{e = e, parser = parser, root = root, req = req},
            res    = res,
            seen   = seen,
        }
        visit_type_decl(e, parser, root, req, tr, "struct_declaration", "type", fields_visitor, &ctx)
    }
}
