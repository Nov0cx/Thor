// Document and workspace symbols from the item trees of package odinsema.
package odin

import "base:runtime"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// The lang.Symbol kind of an item; "" for an item no symbol list shows.
@(private)
symbol_kind :: proc(kind: odinsema.Item_Kind) -> string {
    switch kind {
    case .Proc, .Proc_Group:
        return "function"
    case .Struct, .Union, .Bit_Set, .Bit_Field, .Type:
        return "type"
    case .Enum:
        return "enum"
    case .Const:
        return "constant"
    case .Var:
        return "var"
    case .Field:
        return "field"
    case .Enum_Member:
        return "enum_member"
    case .Import, .Foreign_Import:
        return ""
    }
    return ""
}

// Fills `res` with the outline of the request's buffer in source order: each declaration, then its
// fields or members, then the procedures and types declared in its body.
@(private)
document_symbols :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    lines := ctx.live.lines
    for &item, i in ctx.live.tree.items {
        if symbol_kind(item.kind) == "" {
            continue
        }
        if kind := alias_symbol_kind(&ctx, ctx.live.id, &item, i); kind != "" {
            append_symbol_to(&res.symbols, &item, req.path, lines, item.signature, kind)
        } else {
            append_symbol(res, &item, req.path, lines)
        }
        for &child in item.children {
            append_symbol(res, &child, req.path, lines)
        }
        if item.kind != .Proc {
            continue
        }
        nested, err := odinsema.nested_decls(ctx.parsed, &item, context.temp_allocator)
        if err != nil {
            continue
        }
        for &decl in nested {
            append_symbol(res, &decl.item, req.path, lines)
            for &child in decl.item.children {
                append_symbol(res, &child, req.path, lines)
            }
        }
    }
    res.ok = true
}

// The symbol kind the checker gives a constant of `file` whose value is a name, `Foo :: pkg.Bar`:
// "type", "enum" or "function". "" when the item is no such constant or the checker gives no other kind.
@(private = "file")
alias_symbol_kind :: proc(ctx: ^Request_Context, file: odinsema.File_Id, item: ^odinsema.Item, index: int) -> string {
    if item.kind != .Const || item.value_offset < 0 {
        return ""
    }
    c := request_checker(ctx)
    if c == nil {
        return ""
    }
    value, ok := odinsema.node_at(c, file, item.value_offset)
    if !ok || (value.green.kind != .Ident && value.green.kind != .Selector_Expr) {
        return ""
    }
    op := odinsema.item_operand(c, odinsema.Symbol{file = file, item = i32(index), child = -1})
    #partial switch op.mode {
    case .Type:
        if odinsema.type_kind(&c.table, odinsema.type_base(&c.table, op.type)) == .Enum {
            return "enum"
        }
        return "type"
    case .Builtin:
        return "function"
    case .Value, .Const:
        #partial switch odinsema.type_kind(&c.table, odinsema.type_base(&c.table, op.type)) {
        case .Proc, .Proc_Group:
            return "function"
        }
    }
    return ""
}

// Fills `res` with the top-level declarations of the workspace whose name matches req.query,
// sorted by name and then path; those a known-false `when` drops for the workspace target
// (config_target) come last, marked " (inactive)". The live buffer counts in place of its file
// on disk, and a disk file counts when it is in the build of that target.
@(private)
workspace_symbols :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    inactive := make([dynamic]lang.Symbol, context.temp_allocator)
    budget   := WORKSPACE_ALIAS_MAX
    if req.path != "" {
        append_matches(&ctx, res, &inactive, req.query, ctx.live.id, ctx.live.tree, req.path, ctx.live.lines, &budget)
    }
    if req.workspace != "" {
        for id in odinsema.db_workspace(&ctx.snap, req.workspace) {
            if lang.request_cancelled(req) {
                append(&res.symbols, ..inactive[:])
                return
            }
            if id == ctx.live.id || !odinsema.db_in_build(&ctx.snap, id) {
                continue
            }
            data := odinsema.db_file(&ctx.snap, id)
            if data == nil {
                continue
            }
            append_matches(&ctx, res, &inactive, req.query, id, data.tree, odinsema.db_file_path(&ctx.snap, id), data.lines, &budget)
        }
    }
    slice.sort_by(res.symbols[:], symbol_less)
    slice.sort_by(inactive[:], symbol_less)
    append(&res.symbols, ..inactive[:])
    res.ok = true
}

@(private = "file")
symbol_less :: proc(a, b: lang.Symbol) -> bool {
    if a.name != b.name {
        return a.name < b.name
    }
    return a.path < b.path
}

// The most constant aliases one workspace query types with the checker.
@(private = "file")
WORKSPACE_ALIAS_MAX :: 64

// Appends the items of `tree` (the file `file`) whose name matches `query`: to `res`, or to
// `inactive` with " (inactive)" after the signature when a known-false guard drops the item for the
// request's target. A constant whose value is a name takes the kind the checker gives it, while
// `budget` lasts.
@(private = "file")
append_matches :: proc(
    ctx: ^Request_Context,
    res: ^lang.Result,
    inactive: ^[dynamic]lang.Symbol,
    query: string,
    file: odinsema.File_Id,
    tree: ^odinsema.Item_Tree,
    path: string,
    lines: []int,
    budget: ^int,
) {
    for &item, i in tree.items {
        if symbol_kind(item.kind) == "" || !lang.symbol_matches(query, item.name) {
            continue
        }
        kind := ""
        if budget^ > 0 && item.kind == .Const && alias_signature(item.signature) && !lang.request_cancelled(ctx.req) {
            budget^ -= 1
            kind = alias_symbol_kind(ctx, file, &item, i)
        }
        if odinsema.guard_active(tree, item.guard, ctx.target) {
            append_symbol_to(&res.symbols, &item, path, lines, item.signature, kind)
            continue
        }
        signature := strings.concatenate({item.signature, " (inactive)"}, context.temp_allocator)
        append_symbol_to(inactive, &item, path, lines, signature, kind)
    }
}

// True when the signature `NAME :: value` has a name or a selector chain for its value.
@(private = "file")
alias_signature :: proc(signature: string) -> bool {
    at := strings.index(signature, "::")
    if at < 0 {
        return false
    }
    want_name := true
    for tok in odinsyntax.lex_all(signature[at + 2:], context.temp_allocator) {
        #partial switch tok.kind {
        case .Whitespace:
        case .Ident:
            if !want_name {
                return false
            }
            want_name = false
        case .Period:
            if want_name {
                return false
            }
            want_name = true
        case .EOF:
            return !want_name
        case:
            return false
        }
    }
    return false
}

// Appends one item as a symbol; every string is cloned into context.allocator (the Manager's).
@(private = "file")
append_symbol :: proc(res: ^lang.Result, item: ^odinsema.Item, path: string, lines: []int) {
    append_symbol_to(&res.symbols, item, path, lines, item.signature)
}

@(private = "file")
append_symbol_to :: proc(out: ^[dynamic]lang.Symbol, item: ^odinsema.Item, path: string, lines: []int, signature: string, kind := "") {
    line, _ := offset_line_col(lines, item.name_offset)
    append(
        out,
        lang.Symbol{
            name = strings.clone(item.name),
            kind = strings.clone(kind != "" ? kind : symbol_kind(item.kind)),
            signature = strings.clone(signature),
            path = strings.clone(path),
            line = line,
            offset = item.name_offset,
        },
    )
}
