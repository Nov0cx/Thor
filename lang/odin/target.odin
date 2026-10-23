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
    tree:     ^odinsema.Item_Tree,
    lines:    []int,
    in_build: bool,
}

// The state of one request on the buffer.
@(private)
Request_Context :: struct {
    e:           ^Engine,
    req:         ^lang.Request,
    target:      odinsema.Target,
    parsed:      odinsyntax.Parse, // owned; given back by request_close
    live:        Live_File,
    collections: odinsema.Collections,
    has_colls:   bool,
}

// What a reference search looks for.
@(private)
Ref_Target_Kind :: enum u8 {
    Unbound,      // a builtin, an import path, a named argument, or a name the scopes do not bind
    Local,        // a local of the buffer
    Package_Item, // a file-scope declaration of a package
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
    dir:        string, // Package_Item and Member: the package directory
    owner:      string, // Member: the type that declares it; "" when it is not a file-scope type
    visibility: odinsema.Visibility, // Package_Item: of the item; Member: of its type
    explicit:   bool,   // Import_Alias: the alias is written in the source
}

// Parses the request's buffer and fills `ctx`. Give it back with request_close.
@(private)
request_open :: proc(e: ^Engine, req: ^lang.Request, ctx: ^Request_Context) -> bool {
    parsed, ok := request_parse(e, req)
    if !ok {
        return false
    }
    tree, terr := odinsema.item_tree(parsed)
    if terr != nil {
        request_release(e, req, &parsed)
        return false
    }
    ctx^ = Request_Context {
        e      = e,
        req    = req,
        target = config_target(e, req.workspace),
        parsed = parsed,
    }
    ctx.live = Live_File {
        path  = req.path,
        tree  = tree,
        lines = line_starts(req.source),
    }
    if req.path != "" {
        ctx.live.key = path_key(req.path)
        ctx.live.in_build = odinsema.file_in_build(req.path, tree.tags, ctx.target)
    }
    ctx.live.dir_key = path_key(live_dir(ctx))
    return true
}

@(private)
request_close :: proc(ctx: ^Request_Context) {
    odinsema.item_tree_destroy(ctx.live.tree)
    ctx.live.tree = nil
    request_release(ctx.e, ctx.req, &ctx.parsed)
}

// The parse of the request's buffer, through the parse cache when it has a path.
@(private = "file")
request_parse :: proc(e: ^Engine, req: ^lang.Request) -> (odinsyntax.Parse, bool) {
    if req.path != "" {
        return parse_cache_get(&e.parses, req.path, req.source)
    }
    parsed, err := odinsyntax.parse(req.source, e.parses.alloc)
    return parsed, err == nil
}

@(private = "file")
request_release :: proc(e: ^Engine, req: ^lang.Request, parsed: ^odinsyntax.Parse) {
    if req.path != "" {
        parse_cache_put(&e.parses, req.path, parsed^)
        parsed^ = {}
    } else {
        odinsyntax.parse_destroy(parsed, e.parses.alloc)
    }
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
        return candidate_target(ctx, own_dir, name, "", true)
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
        imports, err := odinsema.file_imports(ctx.live.tree, live_dir(ctx), request_collections(ctx), context.temp_allocator)
        if err == nil {
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
    slice.sort_by(cands[:], proc(a, b: Def_Candidate) -> bool {
        if a.inactive != b.inactive {
            return !a.inactive
        }
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    c := cands[0]
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

// The roots the imports of the request resolve against: the Odin root and the configured collections.
@(private)
request_collections :: proc(ctx: ^Request_Context) -> ^odinsema.Collections {
    if ctx.has_colls {
        return &ctx.collections
    }
    ctx.has_colls = true
    ctx.collections.odin_root = odin_root(&ctx.e.root)
    configured := config_collections(ctx.e, ctx.req.workspace)
    custom := make([]odinsema.Collection, len(configured), context.temp_allocator)
    for c, i in configured {
        custom[i] = {name = c.name, root = c.dir}
    }
    ctx.collections.custom = custom
    return &ctx.collections
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
    imports, err := odinsema.file_imports(ctx.live.tree, live_dir(ctx), request_collections(ctx), context.temp_allocator)
    if err != nil {
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
    imports, err := odinsema.file_imports(ctx.live.tree, live_dir(ctx), request_collections(ctx), context.temp_allocator)
    if err != nil {
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
