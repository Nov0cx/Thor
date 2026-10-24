// The request's buffer and the declaration the identifier under the caret names, shared by
// definition, references and rename.
package odin

import "core:path/filepath"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// The buffer of the request, which replaces its file on disk.
@(private)
Live_File :: struct {
    path:     string, // "" for a buffer with no file
    key:      string, // path_key of the path; "" when no path
    dir_key:  string, // path_key of the directory, "." for a buffer with no file
    id:       odinsema.File_Id, // ANON_FILE for a buffer with no file
    tree:     ^odinsema.Item_Tree,
    lines:    []int,
    in_build: bool,
}

// The state of one request on the buffer. Do not move it after request_open: `snap` holds its own arena.
@(private)
Request_Context :: struct {
    e:           ^Engine,
    req:         ^lang.Request,
    target:      odinsema.Target,
    snap:        odinsema.Snapshot, // owned; ended by request_close
    parsed:      odinsyntax.Parse,  // borrowed from `snap`
    live:        Live_File,
}

// What a reference search looks for.
@(private)
Ref_Target_Kind :: enum u8 {
    Unbound,      // an import path, a named argument, or a name the scopes do not bind
    Local,        // a local of the buffer
    Package_Item, // a file-scope declaration of a package
    Builtin,      // a declaration of the universe scope
    Member,       // a field or enum member of a file-scope type
    Import_Alias, // the name an import of the buffer binds
}

// The declaration the identifier under the caret names. Strings are temp-allocated.
@(private)
Ref_Target :: struct {
    kind:       Ref_Target_Kind,
    name:       string, // the name every reference spells
    path:       string, // the file of the declaration
    decl:       int,    // the name offset of the declaration; -1 when not known
    dir:        string, // Package_Item, Member and Builtin: the package directory
    owner:      string, // Member: the type that declares it; "" when it is not a file-scope type
    visibility: odinsema.Visibility, // Package_Item: of the item; Member: of its type
    explicit:   bool,   // Import_Alias: the alias is written in the source
}

// Opens a snapshot on the request's buffer and fills `ctx`. Close it with request_close, also on false.
@(private)
request_open :: proc(e: ^Engine, req: ^lang.Request, ctx: ^Request_Context) -> bool {
    ctx^ = Request_Context {
        e      = e,
        req    = req,
        target = config_target(e, req.workspace),
    }
    collections := workspace_collections(e, req.workspace)
    input := odinsema.Snapshot_Input {
        target      = ctx.target,
        collections = &collections,
        has_live    = true,
        live_path   = req.path,
        live_text   = req.source,
        cancel      = req.cancel,
    }
    if !odinsema.snapshot_begin(&e.db, &ctx.snap, input) {
        return false
    }
    id := odinsema.snapshot_live_file(&ctx.snap)
    data := odinsema.db_file(&ctx.snap, id)
    parsed := odinsema.db_parse(&ctx.snap, id)
    if data == nil || parsed == nil {
        return false
    }
    ctx.parsed = parsed^
    ctx.live = Live_File {
        path  = req.path,
        id    = id,
        tree  = data.tree,
        lines = data.lines,
    }
    if req.path != "" {
        ctx.live.key = odinsema.path_key(req.path)
        ctx.live.in_build = odinsema.db_in_build(&ctx.snap, id)
    }
    ctx.live.dir_key = odinsema.path_key(live_dir(ctx))
    return true
}

@(private)
request_close :: proc(ctx: ^Request_Context) {
    odinsema.snapshot_end(&ctx.snap)
    ctx.parsed = {}
    ctx.live.tree = nil
    ctx.live.lines = nil
}

// The declaration the identifier at req.offset names.
@(private)
ref_target :: proc(ctx: ^Request_Context) -> Ref_Target {
    req := ctx.req
    unbound := Ref_Target{decl = -1}
    m, merr := odinsema.scope_map_range(ctx.parsed, req.offset, req.offset)
    if merr != nil {
        return unbound
    }
    defer odinsema.scope_map_destroy(m)
    ref, found := odinsema.ref_at(m, req.offset)
    if !found {
        return unbound
    }
    name := strings.clone(ref.name, context.temp_allocator)
    own_dir := live_dir(ctx)
    switch ref.kind {
    case .None, .Implicit_Selector, .Field_Name:
        // The last two need the type of an expression (M4).
        return unbound
    case .Local:
        if ref.decl < 0 {
            return unbound
        }
        return Ref_Target{kind = .Local, name = name, path = req.path, decl = ref.decl}
    case .Member_Decl:
        for &item in ctx.live.tree.items {
            for child in item.children {
                if child.name_offset == ref.start {
                    return Ref_Target {
                        kind       = .Member,
                        name       = name,
                        path       = req.path,
                        decl       = ref.start,
                        dir        = own_dir,
                        owner      = strings.clone(item.name, context.temp_allocator),
                        visibility = item.visibility,
                    }
                }
            }
        }
        // A record declared in a body: its members are only reached in this file.
        return Ref_Target{kind = .Member, name = name, path = req.path, decl = ref.start, dir = own_dir, visibility = .File}
    case .Top_Level:
        t := Ref_Target{kind = .Package_Item, name = name, path = req.path, decl = ref.start, dir = own_dir}
        for &item in ctx.live.tree.items {
            if item.name_offset != ref.start {
                continue
            }
            if item.kind == .Import || item.kind == .Foreign_Import {
                t.kind = .Import_Alias
                t.explicit = true
                t.dir = ""
            }
            t.visibility = item.visibility
            break
        }
        return t
    case .Free:
        if alias, is_alias := alias_target(ctx, name); is_alias {
            return alias
        }
        if t := candidate_target(ctx, own_dir, name, "", true); t.kind != .Unbound {
            return t
        }
        return builtin_target(ctx, name)
    case .Package_Qualified:
        if dir, is_import := import_alias_dir(ctx, ref.operand); is_import {
            if dir == "" {
                return unbound
            }
            return candidate_target(ctx, dir, name, "", false)
        }
        // `Color.Red`: a member of a type of the package.
        return candidate_target(ctx, own_dir, strings.clone(ref.operand, context.temp_allocator), name, true)
    case .Field_Or_Member:
        // `pkg.Type.Member`; another operand needs the type of an expression (M4).
        pkg, type_name, qualified := qualified_type_operand(req.source, m, ref)
        if !qualified {
            return unbound
        }
        if dir, is_import := import_alias_dir(ctx, pkg); is_import && dir != "" {
            return candidate_target(ctx, dir, strings.clone(type_name, context.temp_allocator), name, false)
        }
    }
    return unbound
}

// The import alias target when an import or foreign import of the buffer binds `name`.
@(private = "file")
alias_target :: proc(ctx: ^Request_Context, name: string) -> (Ref_Target, bool) {
    for item in ctx.live.tree.items {
        if (item.kind != .Import && item.kind != .Foreign_Import) || item.name != name {
            continue
        }
        t := Ref_Target{kind = .Import_Alias, name = name, path = ctx.req.path, decl = -1}
        imports := odinsema.db_imports(&ctx.snap, ctx.live.id)
        if imports != nil {
            if imp, found := odinsema.lookup_import(imports, name); found {
                t.explicit = imp.explicit
                if imp.explicit {
                    t.decl = imp.name_offset
                }
            }
        }
        return t, true
    }
    return {}, false
}

// The target of the declaration of `name` in the package at `dir`, or of its member `member`:
// the first active candidate, else the first one.
@(private = "file")
candidate_target :: proc(ctx: ^Request_Context, dir, name, member: string, own: bool) -> Ref_Target {
    cands := make([dynamic]Def_Candidate, context.temp_allocator)
    package_candidates(ctx, dir, name, member, own, &cands)
    if len(cands) == 0 {
        return Ref_Target{decl = -1}
    }
    c := first_candidate(cands[:])
    t := Ref_Target {
        kind       = .Package_Item,
        name       = c.name,
        path       = c.path,
        decl       = c.offset,
        dir        = strings.clone(dir, context.temp_allocator),
        visibility = c.visibility,
    }
    if member != "" {
        t.kind = .Member
        t.owner = name
    }
    return t
}

// The target of the universe-scope declaration of `name`: the first active candidate, else the first one.
@(private = "file")
builtin_target :: proc(ctx: ^Request_Context, name: string) -> Ref_Target {
    cands := make([dynamic]Def_Candidate, context.temp_allocator)
    dir := builtin_candidates(ctx, name, &cands)
    if len(cands) == 0 {
        return Ref_Target{decl = -1}
    }
    c := first_candidate(cands[:])
    return Ref_Target{kind = .Builtin, name = c.name, path = c.path, decl = c.offset, dir = dir, visibility = .Public}
}

// The first active candidate by path and offset, else the first one. Sorts `cands`.
@(private = "file")
first_candidate :: proc(cands: []Def_Candidate) -> Def_Candidate {
    slice.sort_by(cands, proc(a, b: Def_Candidate) -> bool {
        if a.inactive != b.inactive {
            return !a.inactive
        }
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    return cands[0]
}

// The names of an operand `pkg.Type` whose `pkg` is a free name.
@(private)
qualified_type_operand :: proc(source: string, m: ^odinsema.Scope_Map, ref: odinsema.Name_Ref) -> (pkg, type_name: string, ok: bool) {
    if ref.operand_start < 0 || ref.operand_end > len(source) || ref.operand_start >= ref.operand_end {
        return
    }
    text := source[ref.operand_start:ref.operand_end]
    dot := strings.index_byte(text, '.')
    if dot < 0 {
        return
    }
    pkg = strings.trim_space(text[:dot])
    type_name = strings.trim_space(text[dot + 1:])
    if !odinsema.is_identifier(pkg) || !odinsema.is_identifier(type_name) {
        return "", "", false
    }
    head, found := odinsema.ref_at(m, ref.operand_start)
    if !found || head.kind != .Free {
        return "", "", false
    }
    return pkg, type_name, true
}

// True when a declaration of another file can be named: from the same package unless file-private,
// from another package only when public.
@(private)
item_reaches :: proc(item: ^odinsema.Item, own: bool) -> bool {
    return own ? item.visibility != .File : item.visibility == .Public
}

// The roots the imports of a workspace resolve against: the Odin root and the configured collections.
// Temp-allocated.
@(private = "file")
workspace_collections :: proc(e: ^Engine, workspace: string) -> odinsema.Collections {
    configured := config_collections(e, workspace)
    custom := make([]odinsema.Collection, len(configured), context.temp_allocator)
    for c, i in configured {
        custom[i] = {name = c.name, root = c.dir}
    }
    return odinsema.Collections{odin_root = odin_root(&e.root), custom = custom}
}

// The package directory of the import of the buffer that binds `alias`. `is_import` is false when no
// import binds it; `dir` is "" when the import does not resolve to a directory that exists.
@(private)
import_alias_dir :: proc(ctx: ^Request_Context, alias: string) -> (dir: string, is_import: bool) {
    bound := false
    for item in ctx.live.tree.items {
        if item.kind == .Import && item.name == alias {
            bound = true
            break
        }
    }
    if !bound {
        return "", false
    }
    imports := odinsema.db_imports(&ctx.snap, ctx.live.id)
    if imports == nil {
        return "", true
    }
    imp, found := odinsema.lookup_import(imports, alias)
    if !found || !imp.exists {
        return "", found
    }
    return imp.dir, true
}

// The package directory of the import declaration under the caret. `on_import` is false when the caret
// is not on a package import.
@(private)
import_under_caret :: proc(ctx: ^Request_Context, offset: int) -> (dir: string, on_import: bool) {
    index := -1
    for item, i in ctx.live.tree.items {
        if item.kind == .Import && item.start <= offset && offset <= item.end {
            index = i
            break
        }
    }
    if index < 0 {
        return "", false
    }
    imports := odinsema.db_imports(&ctx.snap, ctx.live.id)
    if imports == nil {
        return "", true
    }
    for imp in imports {
        if imp.item == index && imp.exists {
            return imp.dir, true
        }
    }
    return "", true
}

// The directory of the buffer; "." when it has no file or the path names no directory.
@(private)
live_dir :: proc(ctx: ^Request_Context) -> string {
    if ctx.live.path == "" {
        return "."
    }
    dir := filepath.dir(ctx.live.path)
    return dir == "" ? "." : dir
}
