// Call hierarchy, type hierarchy and implementations. Odin has no inheritance, so a type's
// supertypes are the types its `using` fields embed and its subtypes the types that embed it. The
// implementations of a procedure group are its members, of a procedure the groups of its package that
// hold it, of a union its variants and of any other type its subtypes.
package odin

import "base:runtime"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"

// The declaration the request names: the one under the caret, else the file-scope declaration that
// holds the caret. Strings are temp-allocated or borrowed from the snapshot.
@(private = "file")
decl_under :: proc(ctx: ^Request_Context) -> (cand: Def_Candidate, ok: bool) {
    t := ref_target(ctx)
    if t.kind == .Package_Item && t.dir != "" {
        if c, found := find_candidate(ctx, t.dir, t.name, t.path, t.decl); found {
            return c, true
        }
    }
    offset := ctx.req.offset
    for &item in ctx.live.tree.items {
        if symbol_kind(item.kind) == "" || offset < item.start || offset >= item.end {
            continue
        }
        if c, found := find_candidate(ctx, live_dir(ctx), item.name, ctx.req.path, item.name_offset); found {
            return c, true
        }
        line, _ := offset_line_col(ctx.live.lines, item.name_offset)
        return Def_Candidate {
            path       = ctx.req.path,
            name       = item.name,
            kind       = item.kind,
            signature  = item.signature,
            offset     = item.name_offset,
            line       = line,
            visibility = item.visibility,
        }, true
    }
    return {}, false
}

// The candidate of package `dir` named `name` whose name is at `offset` of the file at `path`.
@(private = "file")
find_candidate :: proc(ctx: ^Request_Context, dir, name, path: string, offset: int) -> (Def_Candidate, bool) {
    cands := make([dynamic]Def_Candidate, context.temp_allocator)
    package_candidates(ctx, dir, name, "", true, &cands)
    key := odinsema.path_key(path)
    for c in cands {
        if c.offset == offset && odinsema.path_key(c.path) == key {
            return c, true
        }
    }
    return {}, false
}

// The directory of the package that holds the file of `cand`.
@(private = "file")
decl_dir :: proc(ctx: ^Request_Context, cand: Def_Candidate) -> string {
    if cand.path == ctx.req.path {
        return live_dir(ctx)
    }
    return filepath.dir(cand.path)
}

@(private = "file")
is_type_kind :: proc(kind: odinsema.Item_Kind) -> bool {
    #partial switch kind {
    case .Struct, .Union, .Enum, .Bit_Set, .Bit_Field, .Type:
        return true
    }
    return false
}

// True when the call `name(` ends at `pos`: the next token is an opening parenthesis.
@(private = "file")
is_call_at :: proc(source: string, pos: int) -> bool {
    i := pos
    for i < len(source) && (source[i] == ' ' || source[i] == '\t') {
        i += 1
    }
    return i < len(source) && source[i] == '('
}

// Appends a symbol row for the item unless a row for the same name offset and file is there.
@(private = "file")
add_item_symbol :: proc(res: ^lang.Result, item: ^odinsema.Item, path: string, lines: []int) {
    for s in res.symbols {
        if s.offset == item.name_offset && s.path == path {
            return
        }
    }
    line := 1
    if len(lines) > 0 {
        line, _ = offset_line_col(lines, item.name_offset)
    }
    append(&res.symbols, lang.Symbol {
        name      = strings.clone(item.name),
        kind      = strings.clone(symbol_kind(item.kind)),
        signature = strings.clone(item.signature),
        path      = strings.clone(path),
        line      = line,
        offset    = item.name_offset,
    })
}

@(private = "file")
add_cand_symbol :: proc(res: ^lang.Result, c: Def_Candidate) {
    for s in res.symbols {
        if s.offset == c.offset && s.path == c.path {
            return
        }
    }
    append(&res.symbols, lang.Symbol {
        name      = strings.clone(c.name),
        kind      = strings.clone(symbol_kind(c.kind)),
        signature = strings.clone(c.signature),
        path      = strings.clone(c.path),
        line      = c.line,
        offset    = c.offset,
    })
}

@(private = "file")
sort_symbols :: proc(res: ^lang.Result) {
    slice.sort_by(res.symbols[:], proc(a, b: lang.Symbol) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
}

// Callers of the procedure under the caret (req.query "up", the default) or the procedures it calls
// ("down"), one row per procedure.
@(private)
call_hierarchy :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    cand, found := decl_under(&ctx)
    if !found || (cand.kind != .Proc && cand.kind != .Proc_Group) {
        return
    }
    if req.query == "down" {
        outgoing_calls(&ctx, cand, res)
    } else if !incoming_calls(&ctx, cand, res) {
        return
    }
    sort_symbols(res)
    res.ok = len(res.symbols) > 0
}

@(private = "file")
Caller_Scan :: struct {
    res:  ^lang.Result,
    name: string,
}

@(private = "file")
incoming_calls :: proc(ctx: ^Request_Context, cand: Def_Candidate, res: ^lang.Result) -> bool {
    target := Ref_Target {
        kind       = .Package_Item,
        name       = cand.name,
        path       = cand.path,
        decl       = cand.offset,
        dir        = decl_dir(ctx, cand),
        visibility = cand.visibility,
    }
    scan := Caller_Scan{res = res, name = cand.name}
    return visit_references(ctx, target, false, caller_visit, &scan)
}

// Adds the declaration that holds each call hit of a file.
@(private = "file")
caller_visit :: proc(data: rawptr, f: Ref_File) -> bool {
    scan := cast(^Caller_Scan)data
    for hit in f.hits {
        if !is_call_at(f.source, hit + len(scan.name)) {
            continue
        }
        for &item in f.tree.items {
            if hit >= item.start && hit < item.end && symbol_kind(item.kind) != "" {
                add_item_symbol(scan.res, &item, f.path, f.lines)
                break
            }
        }
    }
    return true
}

// The procedures called in the body of `cand`, which the buffer must declare.
@(private = "file")
outgoing_calls :: proc(ctx: ^Request_Context, cand: Def_Candidate, res: ^lang.Result) {
    if cand.path != ctx.req.path {
        return
    }
    item: ^odinsema.Item
    for &it in ctx.live.tree.items {
        if it.name_offset == cand.offset {
            item = &it
            break
        }
    }
    if item == nil {
        return
    }
    m, err := odinsema.scope_map(ctx.parsed)
    if err != nil {
        return
    }
    defer odinsema.scope_map_destroy(m)
    source := ctx.req.source
    for ref in m.refs {
        if lang.request_cancelled(ctx.req) {
            return
        }
        if ref.is_decl || ref.start < item.start || ref.start >= item.end {
            continue
        }
        if ref.kind != .Free && ref.kind != .Package_Qualified {
            continue
        }
        end := ref.end > ref.start ? ref.end : ref.start + len(ref.name)
        if !is_call_at(source, end) {
            continue
        }
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
        probe, perr := new_clone(ctx.req^)
        if perr != nil {
            return
        }
        probe.offset = ref.start
        probe.end = ref.start
        saved := ctx.req
        ctx.req = probe
        t := ref_target(ctx)
        ctx.req = saved
        free(probe)
        if t.kind != .Package_Item || t.dir == "" {
            continue
        }
        if c, found := find_candidate(ctx, t.dir, t.name, t.path, t.decl); found && (c.kind == .Proc || c.kind == .Proc_Group) {
            add_cand_symbol(res, c)
        }
    }
}

// The types a record embeds with `using`, by declared type. Builtin types are left out.
@(private = "file")
embedded_types :: proc(c: ^odinsema.Checker, file: odinsema.File_Id, item: ^odinsema.Item, out: ^[dynamic]Type_Found) {
    for child in item.children {
        if child.kind != .Field || child.type_offset < 0 || !strings.has_prefix(child.signature, "using ") {
            continue
        }
        n, ok := odinsema.node_at(c, file, child.type_offset)
        if !ok {
            continue
        }
        op := odinsema.expr_type(c, file, n)
        if op.mode == .Type && op.type != odinsema.INVALID_TYPE {
            collect_type_symbols(c, op.type, out, 0)
        }
    }
}

@(private = "file")
item_of :: proc(ctx: ^Request_Context, sym: odinsema.Symbol) -> (^odinsema.Item, []int) {
    data := odinsema.db_file(&ctx.snap, sym.file)
    if data == nil || sym.item < 0 || int(sym.item) >= len(data.tree.items) {
        return nil, nil
    }
    return &data.tree.items[sym.item], data.lines
}

// The types that embed the type `sym` named `name`, in the buffer and the workspace.
@(private = "file")
subtypes :: proc(ctx: ^Request_Context, c: ^odinsema.Checker, sym: odinsema.Symbol, name: string, res: ^lang.Result) {
    scan_file :: proc(ctx: ^Request_Context, c: ^odinsema.Checker, id: odinsema.File_Id, path: string, sym: odinsema.Symbol, name: string, res: ^lang.Result) {
        data := odinsema.db_file(&ctx.snap, id)
        if data == nil {
            return
        }
        for &item in data.tree.items {
            if item.kind != .Struct {
                continue
            }
            uses := false
            for child in item.children {
                if strings.has_prefix(child.signature, "using ") && strings.contains(child.signature, name) {
                    uses = true
                    break
                }
            }
            if !uses {
                continue
            }
            found := make([dynamic]Type_Found, context.temp_allocator)
            embedded_types(c, id, &item, &found)
            for f in found {
                if !f.builtin && f.symbol == sym {
                    add_item_symbol(res, &item, path, data.lines)
                    break
                }
            }
        }
    }
    scan_file(ctx, c, ctx.live.id, ctx.req.path, sym, name, res)
    if ctx.req.workspace == "" {
        return
    }
    for id in odinsema.db_workspace(&ctx.snap, ctx.req.workspace) {
        if lang.request_cancelled(ctx.req) {
            return
        }
        if id == ctx.live.id || !odinsema.db_in_build(&ctx.snap, id) {
            continue
        }
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
        scan_file(ctx, c, id, odinsema.db_file_path(&ctx.snap, id), sym, name, res)
    }
}

// Appends the declarations of the declared types in `found`.
@(private = "file")
add_found_types :: proc(ctx: ^Request_Context, c: ^odinsema.Checker, found: []Type_Found, res: ^lang.Result) {
    for f in found {
        if f.builtin {
            continue
        }
        j, ok := symbol_jump(ctx, c, f)
        if !ok {
            continue
        }
        dup := false
        for s in res.symbols {
            if s.path == j.path && s.offset == j.start {
                dup = true
                break
            }
        }
        if dup {
            continue
        }
        append(&res.symbols, lang.Symbol {
            name      = strings.clone(j.name),
            kind      = strings.clone(j.kind),
            signature = strings.clone(j.signature),
            path      = strings.clone(j.path),
            line      = j.line,
            offset    = j.start,
        })
    }
}

// The types the type under the caret embeds (req.query "up", the default) or the types that embed it ("down").
@(private)
type_hierarchy :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    cand, found := decl_under(&ctx)
    if !found || !is_type_kind(cand.kind) {
        return
    }
    c := request_checker(&ctx)
    if c == nil {
        return
    }
    sym, ok := decl_symbol(&ctx, cand.path, cand.offset)
    if !ok {
        return
    }
    if req.query == "down" {
        subtypes(&ctx, c, sym, cand.name, res)
    } else if item, _ := item_of(&ctx, sym); item != nil {
        types := make([dynamic]Type_Found, context.temp_allocator)
        embedded_types(c, sym.file, item, &types)
        add_found_types(&ctx, c, types[:], res)
    }
    if lang.request_cancelled(req) {
        return
    }
    sort_symbols(res)
    res.ok = len(res.symbols) > 0
}

// The implementations of the declaration under the caret.
@(private)
implementations :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    cand, found := decl_under(&ctx)
    if !found {
        return
    }
    #partial switch cand.kind {
    case .Proc_Group:
        members := make([dynamic]Def_Candidate, context.temp_allocator)
        expand_group(&ctx, cand, &members)
        for m in members {
            add_cand_symbol(res, m)
        }
    case .Proc:
        holding_groups(&ctx, cand, res)
    case .Union:
        union_variants(&ctx, cand, res)
    case:
        if is_type_kind(cand.kind) {
            c := request_checker(&ctx)
            sym, ok := decl_symbol(&ctx, cand.path, cand.offset)
            if c != nil && ok {
                subtypes(&ctx, c, sym, cand.name, res)
            }
        }
    }
    if lang.request_cancelled(req) {
        return
    }
    sort_symbols(res)
    res.ok = len(res.symbols) > 0
}

// The procedure groups of the package of `cand` that name it as a member.
@(private = "file")
holding_groups :: proc(ctx: ^Request_Context, cand: Def_Candidate, res: ^lang.Result) {
    scan :: proc(ctx: ^Request_Context, id: odinsema.File_Id, path: string, name: string, res: ^lang.Result) {
        data := odinsema.db_file(&ctx.snap, id)
        if data == nil {
            return
        }
        for &item in data.tree.items {
            if item.kind != .Proc_Group {
                continue
            }
            for m in item.members {
                if m.operand == "" && m.name == name {
                    add_item_symbol(res, &item, path, data.lines)
                    break
                }
            }
        }
    }
    scan(ctx, ctx.live.id, ctx.req.path, cand.name, res)
    view := request_package(ctx, decl_dir(ctx, cand))
    if view == nil {
        return
    }
    for id in view.files {
        if id != ctx.live.id {
            scan(ctx, id, odinsema.db_file_path(&ctx.snap, id), cand.name, res)
        }
    }
}

// The declared variant types of the union `cand`.
@(private = "file")
union_variants :: proc(ctx: ^Request_Context, cand: Def_Candidate, res: ^lang.Result) {
    c := request_checker(ctx)
    sym, ok := decl_symbol(ctx, cand.path, cand.offset)
    if c == nil || !ok {
        return
    }
    base := odinsema.type_base(&c.table, odinsema.decl_type(c, sym))
    u, is_union := odinsema.type_get(&c.table, base).(odinsema.Union_Type)
    if !is_union {
        return
    }
    types := make([dynamic]Type_Found, context.temp_allocator)
    for v in u.variants {
        collect_type_symbols(c, v, &types, 0)
    }
    add_found_types(ctx, c, types[:], res)
}
