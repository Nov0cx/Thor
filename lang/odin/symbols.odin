// Document and workspace symbols from the item trees of package odinsema.
package odin

import "base:runtime"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"

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
    for &item in ctx.live.tree.items {
        if symbol_kind(item.kind) == "" {
            continue
        }
        append_symbol(res, &item, req.path, lines)
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
    if req.path != "" {
        append_matches(res, &inactive, req.query, ctx.live.tree, req.path, ctx.live.lines, ctx.target)
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
            append_matches(res, &inactive, req.query, data.tree, odinsema.db_file_path(&ctx.snap, id), data.lines, ctx.target)
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

// Appends the items of `tree` whose name matches `query`: to `res`, or to `inactive` with
// " (inactive)" after the signature when a known-false guard drops the item for `target`.
@(private = "file")
append_matches :: proc(res: ^lang.Result, inactive: ^[dynamic]lang.Symbol, query: string, tree: ^odinsema.Item_Tree, path: string, lines: []int, target: odinsema.Target) {
    for &item in tree.items {
        if symbol_kind(item.kind) == "" || !lang.symbol_matches(query, item.name) {
            continue
        }
        if odinsema.guard_active(tree, item.guard, target) {
            append_symbol(res, &item, path, lines)
            continue
        }
        signature := strings.concatenate({item.signature, " (inactive)"}, context.temp_allocator)
        append_symbol_to(inactive, &item, path, lines, signature)
    }
}

// Appends one item as a symbol; every string is cloned into context.allocator (the Manager's).
@(private = "file")
append_symbol :: proc(res: ^lang.Result, item: ^odinsema.Item, path: string, lines: []int) {
    append_symbol_to(&res.symbols, item, path, lines, item.signature)
}

@(private = "file")
append_symbol_to :: proc(out: ^[dynamic]lang.Symbol, item: ^odinsema.Item, path: string, lines: []int, signature: string) {
    line, _ := offset_line_col(lines, item.name_offset)
    append(out, lang.Symbol {
        name      = strings.clone(item.name),
        kind      = strings.clone(symbol_kind(item.kind)),
        signature = strings.clone(signature),
        path      = strings.clone(path),
        line      = line,
        offset    = item.name_offset,
    })
}

@(private)
path_key :: proc(path: string) -> string {
    return odinsema.path_key(path)
}
