// References and rename from the scopes of package odinsema: locals, import aliases, file-scope
// declarations of a package with their qualified uses in other packages, the names of the universe
// scope, and the members of a file-scope type. A member reached through a value counts by its name until types (M4) prove it
// names another type.
package odin

import "base:runtime"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// One search for the identifiers that name a target.
@(private = "file")
Ref_Scan :: struct {
    ctx:       ^Request_Context,
    target:    Ref_Target,
    with_decl: bool,
    dir_key:   string, // path_key of target.dir
    decl_key:  string, // path_key of target.path; "" for a buffer with no file
    hits:      [dynamic]lang.Symbol, // owned; strings in context.allocator
    bound:     map[string]bool,      // owned; Builtin: whether the package of a directory key binds the name
}

// One file a scan reads. Strings are temp-allocated or borrowed from the snapshot.
@(private = "file")
Scan_File :: struct {
    id:          odinsema.File_Id,
    path:        string,
    key:         string,
    dir:         string,
    dir_key:     string,
    source:      string,
    parsed:      odinsyntax.Parse,
    tree:        ^odinsema.Item_Tree,
    lines:       []int,
    imports:     []odinsema.File_Import,
    has_imports: bool,
}

// Fills `res.symbols` with every identifier that names the declaration under the caret, the
// declaration excluded, sorted by path and offset.
@(private)
references :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    target := ref_target(&ctx)
    if target.kind == .Unbound {
        return
    }
    s := Ref_Scan{ctx = &ctx, target = target}
    if !scan(&s) {
        hits_free(s.hits[:])
        delete(s.hits)
        return
    }
    res.symbols = s.hits
    res.ok = true
}

// Fills `res.edits` with the edits that rename the declaration under the caret and every identifier
// that names it to req.new_name. Answers nothing when the new name is not an identifier or is the
// old one, when the caret names nothing the scopes bind, or when the declaration is outside the
// workspace.
@(private)
rename :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    if !odinsema.is_identifier(req.new_name) {
        return
    }
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    target := ref_target(&ctx)
    if target.kind == .Unbound || target.name == req.new_name || !rename_allowed(&ctx, target) {
        return
    }
    s := Ref_Scan{ctx = &ctx, target = target, with_decl = true}
    if !scan(&s) {
        hits_free(s.hits[:])
        delete(s.hits)
        return
    }
    defer delete(s.hits)
    for &hit in s.hits {
        edit := lang.Text_Edit {
            path     = hit.path,
            start    = hit.offset,
            end      = hit.offset + len(target.name),
            old_text = strings.clone(target.name),
            new_text = strings.clone(req.new_name),
        }
        if _, err := append(&res.edits, edit); err != nil {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        hit.path = ""
        delete(hit.name)
        delete(hit.kind)
        delete(hit.signature)
    }
    res.ok = len(res.edits) > 0
}

// True when the declaration of `target` can be renamed: an implicit import alias cannot, and a
// declaration outside the workspace (or, with no workspace, outside the buffer) is not the user's.
@(private = "file")
rename_allowed :: proc(ctx: ^Request_Context, target: Ref_Target) -> bool {
    if target.kind == .Import_Alias {
        return target.explicit
    }
    if target.kind == .Builtin {
        return false
    }
    if target.path == ctx.req.path && ctx.req.workspace == "" {
        return true
    }
    if ctx.req.workspace == "" || target.path == "" {
        return false
    }
    root := strings.trim_right(odinsema.path_key(ctx.req.workspace), "/")
    key := odinsema.path_key(target.path)
    return key == root || strings.has_prefix(key, strings.concatenate({root, "/"}, context.temp_allocator))
}

// Collects the hits of `s.target`, sorted by path and offset. False when the request is cancelled.
@(private = "file")
scan :: proc(s: ^Ref_Scan) -> bool {
    ctx := s.ctx
    s.hits = make([dynamic]lang.Symbol)
    s.decl_key = s.target.path != "" ? odinsema.path_key(s.target.path) : ""
    if s.target.dir != "" {
        s.dir_key = odinsema.path_key(s.target.dir)
    }
    live := live_scan_file(ctx)

    switch s.target.kind {
    case .Unbound:
        return true
    case .Local:
        offsets, err := odinsema.local_references(ctx.parsed, s.target.decl, context.temp_allocator)
        if err != nil {
            return true
        }
        for offset in offsets {
            if offset != s.target.decl || s.with_decl {
                add_hit(s, &live, offset)
            }
        }
    case .Import_Alias:
        scan_file(s, &live)
    case .Package_Item, .Member:
        if !scan_package(s, &live) {
            return false
        }
    case .Builtin:
        if !scan_workspace(s, &live) {
            return false
        }
    }
    sort_hits(s)
    return true
}

// The buffer of the request as a scan file.
@(private = "file")
live_scan_file :: proc(ctx: ^Request_Context) -> Scan_File {
    dir := live_dir(ctx)
    return Scan_File {
        id      = ctx.live.id,
        path    = ctx.req.path,
        key     = ctx.live.key,
        dir     = dir,
        dir_key = ctx.live.dir_key,
        source  = ctx.req.source,
        parsed  = ctx.parsed,
        tree    = ctx.live.tree,
        lines   = ctx.live.lines,
    }
}

// Scans the buffer, the files of the target's package and the files of the workspace that import it.
// A file-private target is reached from its own file only, a package-private one from its package only.
// Files out of the build count, so a rename keeps the platform halves of a package in step.
@(private = "file")
scan_package :: proc(s: ^Ref_Scan, live: ^Scan_File) -> bool {
    ctx := s.ctx
    req := ctx.req
    if s.target.visibility == .File {
        if s.decl_key == ctx.live.key {
            scan_file(s, live)
        } else {
            scan_disk_file(s, odinsema.db_file_id(&ctx.snap, s.target.path))
        }
        return !lang.request_cancelled(req)
    }
    scan_file(s, live)
    // A buffer with no file or outside a workspace stands alone, as in definition.
    if live.dir_key == s.dir_key && (ctx.live.path == "" || req.workspace == "") {
        return true
    }
    if view := request_package(ctx, s.target.dir); view != nil {
        for id in view.files {
            if lang.request_cancelled(req) {
                return false
            }
            if id != ctx.live.id {
                scan_disk_file(s, id)
            }
        }
    }
    if s.target.visibility != .Public || req.workspace == "" {
        return !lang.request_cancelled(req)
    }
    for id in workspace_importers(s) {
        if lang.request_cancelled(req) {
            return false
        }
        scan_disk_file(s, id)
    }
    return !lang.request_cancelled(req)
}

// Scans the buffer and every file of the workspace.
@(private = "file")
scan_workspace :: proc(s: ^Ref_Scan, live: ^Scan_File) -> bool {
    ctx := s.ctx
    req := ctx.req
    // Outside the temp allocator: scan_disk_file rewinds it after each file.
    s.bound = make(map[string]bool)
    defer {
        for key in s.bound {
            delete(key)
        }
        delete(s.bound)
        s.bound = nil
    }
    scan_file(s, live)
    if req.workspace == "" {
        return !lang.request_cancelled(req)
    }
    for id in workspace_files(s) {
        if lang.request_cancelled(req) {
            return false
        }
        scan_disk_file(s, id)
    }
    return !lang.request_cancelled(req)
}

// The workspace files other than the buffer, sorted by path.
@(private = "file")
workspace_files :: proc(s: ^Ref_Scan) -> []odinsema.File_Id {
    ctx := s.ctx
    out := make([dynamic]odinsema.File_Id, context.temp_allocator)
    for id in odinsema.db_workspace(&ctx.snap, ctx.req.workspace) {
        if id != ctx.live.id {
            append(&out, id)
        }
    }
    return out[:]
}

// The workspace files outside the target's package that import it, sorted by path.
@(private = "file")
workspace_importers :: proc(s: ^Ref_Scan) -> []odinsema.File_Id {
    ctx := s.ctx
    snap := &ctx.snap
    out := make([dynamic]odinsema.File_Id, context.temp_allocator)
    for id in odinsema.db_workspace(snap, ctx.req.workspace) {
        if lang.request_cancelled(ctx.req) {
            break
        }
        if id == ctx.live.id {
            continue
        }
        data := odinsema.db_file(snap, id)
        if data == nil || !imports_package(data.tree) || odinsema.path_key(filepath.dir(odinsema.db_file_path(snap, id))) == s.dir_key {
            continue
        }
        for imp in odinsema.db_imports(snap, id) {
            if imp.exists && odinsema.path_key(imp.dir) == s.dir_key {
                append(&out, id)
                break
            }
        }
    }
    return out[:]
}

// True when the file has a package import.
@(private = "file")
imports_package :: proc(tree: ^odinsema.Item_Tree) -> bool {
    for item in tree.items {
        if item.kind == .Import {
            return true
        }
    }
    return false
}

// Scans one file on disk when it names the target. Files out of the build count too.
@(private = "file")
scan_disk_file :: proc(s: ^Ref_Scan, id: odinsema.File_Id) {
    if id == odinsema.NO_FILE {
        return
    }
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    snap := &s.ctx.snap
    parsed := odinsema.db_parse(snap, id)
    if parsed == nil || parsed.tree == nil || !strings.contains(parsed.tree.text, s.target.name) {
        return
    }
    data := odinsema.db_file(snap, id)
    if data == nil {
        return
    }
    path := odinsema.db_file_path(snap, id)
    dir := filepath.dir(path)
    f := Scan_File {
        id      = id,
        path    = path,
        key     = odinsema.db_file_key(snap, id),
        dir     = dir,
        dir_key = odinsema.path_key(dir),
        source  = parsed.tree.text,
        parsed  = parsed^,
        tree    = data.tree,
        lines   = data.lines,
    }
    scan_file(s, &f)
}

// Adds the identifiers of one file that name the target.
@(private = "file")
scan_file :: proc(s: ^Ref_Scan, f: ^Scan_File) {
    m, err := odinsema.scope_map(f.parsed)
    if err != nil {
        return
    }
    defer odinsema.scope_map_destroy(m)
    for ref in m.refs {
        if ref.name != s.target.name {
            continue
        }
        hit, is_decl := classify(s, f, m, ref)
        if hit && (!is_decl || s.with_decl) {
            add_hit(s, f, ref.start)
        }
    }
}

// Whether `ref` names the target, and whether it is a declaration of it.
@(private = "file")
classify :: proc(s: ^Ref_Scan, f: ^Scan_File, m: ^odinsema.Scope_Map, ref: odinsema.Name_Ref) -> (hit, is_decl: bool) {
    t := &s.target
    switch t.kind {
    case .Unbound, .Local:
        return false, false
    case .Import_Alias:
        #partial switch ref.kind {
        case .Free:
            return true, false
        case .Top_Level:
            return ref.decl_kind == .Import, true
        }
    case .Package_Item:
        in_package := f.dir_key == s.dir_key
        #partial switch ref.kind {
        case .Free:
            return in_package && !shadowed(s, f), false
        case .Top_Level:
            return in_package && ref.decl_kind != .Import && !shadowed(s, f), true
        case .Package_Qualified:
            if in_package {
                return false, false
            }
            imp, found := file_import(s, f, ref.operand)
            return found && imp.exists && odinsema.path_key(imp.dir) == s.dir_key, false
        }
    case .Builtin:
        if ref.kind == .Free {
            return !package_binds(s, f), false
        }
    case .Member:
        #partial switch ref.kind {
        case .Member_Decl:
            return f.key == s.decl_key && ref.start == t.decl, true
        case .Implicit_Selector:
            return true, false
        case .Package_Qualified:
            if _, is_import := file_import(s, f, ref.operand); is_import {
                return false, false
            }
            return !operand_names_other(s, f, m, ref), false
        case .Field_Or_Member, .Field_Name:
            return !operand_names_other(s, f, m, ref), false
        }
    }
    return false, false
}

// True when a file of the package binds the target's name to something else: an import alias of
// the file, or a file-private declaration of another file.
@(private = "file")
shadowed :: proc(s: ^Ref_Scan, f: ^Scan_File) -> bool {
    for item in f.tree.items {
        if item.name != s.target.name {
            continue
        }
        if item.kind == .Import || item.kind == .Foreign_Import {
            return true
        }
        if item.visibility == .File && f.key != s.decl_key {
            return true
        }
    }
    return false
}

// True when the file or its package binds the target's name, which hides the universe scope.
@(private = "file")
package_binds :: proc(s: ^Ref_Scan, f: ^Scan_File) -> bool {
    for item in f.tree.items {
        if item.name == s.target.name {
            return true
        }
    }
    if bound, known := s.bound[f.dir_key]; known {
        return bound
    }
    cands := make([dynamic]Def_Candidate, context.temp_allocator)
    package_candidates(s.ctx, f.dir, s.target.name, "", true, &cands)
    bound := len(cands) > 0
    key, err := strings.clone(f.dir_key)
    if err != nil {
        return bound
    }
    _, value, inserted, merr := map_entry(&s.bound, key)
    if merr != nil || !inserted {
        delete(key)
    }
    if value != nil {
        value^ = bound
    }
    return bound
}

// The import of `f` that binds `alias`.
@(private = "file")
file_import :: proc(s: ^Ref_Scan, f: ^Scan_File, alias: string) -> (odinsema.File_Import, bool) {
    if !f.has_imports {
        f.has_imports = true
        f.imports = odinsema.db_imports(&s.ctx.snap, f.id)
    }
    imp, found := odinsema.lookup_import(f.imports, alias)
    if !found {
        return {}, false
    }
    return imp^, true
}

// True when the operand of a selector, a composite literal or a call is proven to name a type or
// procedure other than the member's type.
@(private = "file")
operand_names_other :: proc(s: ^Ref_Scan, f: ^Scan_File, m: ^odinsema.Scope_Map, ref: odinsema.Name_Ref) -> bool {
    if ref.operand_start < 0 || ref.operand_end > len(f.source) || ref.operand_start >= ref.operand_end {
        return false
    }
    if pkg, type_name, qualified := qualified_type_operand(f.source, m, ref); qualified {
        imp, found := file_import(s, f, pkg)
        if !found || !imp.exists {
            return false
        }
        return odinsema.path_key(imp.dir) != s.dir_key || type_name != s.target.owner
    }
    text := strings.trim_space(f.source[ref.operand_start:ref.operand_end])
    if !odinsema.is_identifier(text) {
        return false
    }
    head, found := odinsema.ref_at(m, ref.operand_start)
    if !found || head.kind != .Free {
        return false
    }
    if text == s.target.owner && f.dir_key == s.dir_key {
        return false
    }
    cands := make([dynamic]Def_Candidate, context.temp_allocator)
    package_candidates(s.ctx, f.dir, text, "", true, &cands)
    for c in cands {
        #partial switch c.kind {
        case .Struct, .Enum, .Union, .Bit_Set, .Bit_Field, .Proc, .Proc_Group:
            return true
        }
    }
    return false
}

// Appends the identifier at `offset` of `f` as a reference row.
@(private = "file")
add_hit :: proc(s: ^Ref_Scan, f: ^Scan_File, offset: int) {
    line, _ := offset_line_col(f.lines, offset)
    start := f.lines[line - 1]
    end := strings.index_byte(f.source[start:], '\n')
    end = end < 0 ? len(f.source) : start + end
    append(&s.hits, lang.Symbol {
        name      = strings.clone(s.target.name),
        kind      = strings.clone("reference"),
        signature = strings.clone(strings.trim_space(f.source[start:end])),
        path      = strings.clone(f.path),
        line      = line,
        offset    = offset,
    })
}

// Sorts the hits by path and offset and drops the duplicates.
@(private = "file")
sort_hits :: proc(s: ^Ref_Scan) {
    slice.sort_by(s.hits[:], proc(a, b: lang.Symbol) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    kept := 0
    for i in 0 ..< len(s.hits) {
        h := s.hits[i]
        if kept > 0 && s.hits[kept - 1].path == h.path && s.hits[kept - 1].offset == h.offset {
            hits_free({h})
            continue
        }
        s.hits[kept] = h
        kept += 1
    }
    resize(&s.hits, kept)
}

@(private = "file")
hits_free :: proc(hits: []lang.Symbol) {
    for h in hits {
        delete(h.name)
        delete(h.kind)
        delete(h.signature)
        delete(h.path)
    }
}
