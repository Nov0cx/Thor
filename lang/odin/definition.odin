// Go to definition from the scopes of package odinsema: locals, the package scope, imports,
// enum members and procedure groups. A selector on a value, an implicit selector and a field
// name need the type of an expression, which the engine does not compute yet.
package odin

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import lang ".."
import "../../shell"
import odinsema "sema"
import odinsyntax "syntax"

// The root of the Odin toolchain, found once per engine.
@(private)
Odin_Root :: struct {
    mutex: sync.Mutex,
    alloc: runtime.Allocator,
    path:  string, // owned; "" when not found
    known: bool,
}

// Longest `odin root` may run.
@(private)
ODIN_ROOT_TIMEOUT :: 10 * time.Second

// The buffer of the request, which replaces its file on disk.
@(private = "file")
Live_File :: struct {
    path:     string, // "" for a buffer with no file
    key:      string, // path_key of the path; "" when no path
    dir_key:  string, // path_key of the directory, "." for a buffer with no file
    tree:     ^odinsema.Item_Tree,
    lines:    []int,
    in_build: bool,
}

// The state of one definition request.
@(private = "file")
Def_Context :: struct {
    e:           ^Engine,
    req:         ^lang.Request,
    target:      odinsema.Target,
    live:        Live_File,
    collections: odinsema.Collections,
    has_colls:   bool,
}

// A declaration a definition can land on. Strings are temp-allocated.
@(private = "file")
Def_Candidate :: struct {
    path:      string,
    name:      string,
    kind:      odinsema.Item_Kind,
    signature: string,
    offset:    int,
    line:      int,
    inactive:  bool, // under a false `when`, or in a file out of the build
    members:   []Def_Member, // Proc_Group
}

// Where a member of a procedure group is declared.
@(private = "file")
Def_Member :: struct {
    dir:  string, // the package directory
    name: string,
    own:  bool, // a bare name, looked up from inside its package
}

// Fills `res` with the declaration the identifier at req.offset names: res.location for one,
// res.symbols for several, active ones first.
@(private)
definition :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    parsed, ok := definition_parse(e, req)
    if !ok {
        return
    }
    defer if req.path != "" {
        parse_cache_put(&e.parses, req.path, parsed)
    } else {
        odinsyntax.parse_destroy(&parsed, e.parses.alloc)
    }
    tree, terr := odinsema.item_tree(parsed)
    if terr != nil {
        return
    }
    defer odinsema.item_tree_destroy(tree)

    ctx := Def_Context {
        e      = e,
        req    = req,
        target = config_target(e, req.workspace),
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

    ctx.live.dir_key = path_key(live_dir(&ctx))

    if dir, on_import := import_under_caret(&ctx, req.offset); on_import {
        if dir != "" {
            package_jump(dir, res)
        }
        return
    }

    m, merr := odinsema.scope_map_range(parsed, req.offset, req.offset)
    if merr != nil {
        return
    }
    defer odinsema.scope_map_destroy(m)
    ref, found := odinsema.ref_at(m, req.offset)
    if !found {
        return
    }

    cands := make([dynamic]Def_Candidate, context.temp_allocator)
    own_dir := live_dir(&ctx)
    switch ref.kind {
    case .None:
        return
    case .Local, .Member_Decl:
        start := ref.kind == .Local ? ref.decl : ref.start
        if start < 0 {
            return
        }
        res.location = lang.Location{path = strings.clone(req.path), start = start, end = start + len(ref.name)}
        res.ok = true
        return
    case .Top_Level:
        for &item in tree.items {
            if item.name_offset == ref.start && item.kind != .Import && item.kind != .Foreign_Import {
                inactive := ctx.live.in_build && !odinsema.guard_active(tree, item.guard, ctx.target)
                emit_candidate(&ctx, &cands, &item, req.path, tree, ctx.live.lines, inactive, "")
                break
            }
        }
        if len(cands) == 0 {
            res.location = lang.Location{path = strings.clone(req.path), start = ref.start, end = ref.end}
            res.ok = true
            return
        }
    case .Free:
        if dir, is_import := import_alias_dir(&ctx, ref.name); is_import {
            if dir != "" {
                package_jump(dir, res)
            }
            return
        }
        package_candidates(&ctx, own_dir, ref.name, "", true, &cands)
    case .Package_Qualified:
        if dir, is_import := import_alias_dir(&ctx, ref.operand); is_import {
            if dir != "" {
                package_candidates(&ctx, dir, ref.name, "", false, &cands)
            }
        } else {
            // `Color.Red`: a member of a type of the package.
            package_candidates(&ctx, own_dir, ref.operand, ref.name, true, &cands)
        }
    case .Field_Or_Member, .Implicit_Selector, .Field_Name:
        // These need the type of an expression (M4).
        return
    }
    if lang.request_cancelled(req) {
        return
    }
    answer(&ctx, cands[:], res)
}

// The parse of the request's buffer, through the parse cache when it has a path.
@(private = "file")
definition_parse :: proc(e: ^Engine, req: ^lang.Request) -> (odinsyntax.Parse, bool) {
    if req.path != "" {
        return parse_cache_get(&e.parses, req.path, req.source)
    }
    parsed, err := odinsyntax.parse(req.source, e.parses.alloc)
    return parsed, err == nil
}

// Sorts the candidates and fills `res`: one active candidate, or one candidate only, is a jump;
// a lone procedure group is a jump to its members, or a list of them.
@(private = "file")
answer :: proc(ctx: ^Def_Context, cands: []Def_Candidate, res: ^lang.Result) {
    slice.sort_by(cands, proc(a, b: Def_Candidate) -> bool {
        if a.inactive != b.inactive {
            return !a.inactive
        }
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    active := 0
    for c in cands {
        if !c.inactive {
            active += 1
        }
    }
    list := cands
    if active == 1 || len(cands) == 1 {
        list = cands[:1]
    }
    if len(list) == 1 && list[0].kind == .Proc_Group {
        members := make([dynamic]Def_Candidate, context.temp_allocator)
        expand_group(ctx, list[0], &members)
        if len(members) > 0 {
            list = members[:]
        }
    }
    switch len(list) {
    case 0:
        return
    case 1:
        c := list[0]
        res.location = lang.Location{path = strings.clone(c.path), start = c.offset, end = c.offset + len(c.name)}
    case:
        for c in list {
            append(&res.symbols, lang.Symbol {
                name      = strings.clone(c.name),
                kind      = strings.clone(symbol_kind(c.kind)),
                signature = strings.clone(c.signature),
                path      = strings.clone(c.path),
                line      = c.line,
                offset    = c.offset,
            })
        }
    }
    res.ok = true
}

// Appends the declaration of each member of a procedure group that resolves: the first active one of its name.
@(private = "file")
expand_group :: proc(ctx: ^Def_Context, group: Def_Candidate, out: ^[dynamic]Def_Candidate) {
    for m in group.members {
        if lang.request_cancelled(ctx.req) {
            return
        }
        found := make([dynamic]Def_Candidate, context.temp_allocator)
        package_candidates(ctx, m.dir, m.name, "", m.own, &found)
        if len(found) == 0 {
            continue
        }
        pick := found[0]
        for c in found {
            if !c.inactive {
                pick = c
                break
            }
        }
        append(out, pick)
    }
}

// Appends the declarations named `name` of the package at `dir`, or with `member` set, their field
// or member of that name. `own` is a lookup from inside the package, which reaches its package-private
// declarations; else only public ones count. The live buffer replaces its file. Files out of the build
// are read only when nothing else declares the name, and their candidates are inactive.
@(private = "file")
package_candidates :: proc(ctx: ^Def_Context, dir, name, member: string, own: bool, out: ^[dynamic]Def_Candidate) {
    live := &ctx.live
    replace := path_key(dir) == live.dir_key
    start := len(out)
    if replace {
        for &item in live.tree.items {
            if item.name != name || item.kind == .Import || item.kind == .Foreign_Import {
                continue
            }
            inactive := live.in_build && !odinsema.guard_active(live.tree, item.guard, ctx.target)
            emit_candidate(ctx, out, &item, live.path, live.tree, live.lines, inactive, member)
        }
    }
    // A buffer with no file or outside a workspace stands alone: its directory may be anything.
    if replace && (live.path == "" || ctx.req.workspace == "") {
        return
    }

    c := &ctx.e.packages
    sync.lock(&c.mutex)
    defer sync.unlock(&c.mutex)
    entry := package_cache_ensure(c, dir, ctx.target, ctx.req)
    if entry == nil {
        return
    }
    for ref in odinsema.package_scope_lookup(&entry.scope, name) {
        f := &entry.files[ref.file]
        if replace && f.key == live.key {
            continue
        }
        item := odinsema.package_item(entry.sema_files[:], ref)
        if !item_reaches(item, own) {
            continue
        }
        inactive := !odinsema.package_ref_active(&entry.scope, ref)
        emit_candidate(ctx, out, item, f.path, f.items, f.lines, inactive, member)
    }
    if len(out) > start {
        return
    }
    for &f in entry.files {
        if f.in_build || f.items == nil || (replace && f.key == live.key) {
            continue
        }
        for &item in f.items.items {
            if item.name == name && item.kind != .Import && item.kind != .Foreign_Import && item_reaches(&item, own) {
                emit_candidate(ctx, out, &item, f.path, f.items, f.lines, true, member)
            }
        }
    }
}

// True when a declaration of another file can be named: from the same package unless file-private,
// from another package only when public.
@(private = "file")
item_reaches :: proc(item: ^odinsema.Item, own: bool) -> bool {
    return own ? item.visibility != .File : item.visibility == .Public
}

// Appends `item`, or with `member` set its field or member of that name, as a candidate.
@(private = "file")
emit_candidate :: proc(
    ctx: ^Def_Context,
    out: ^[dynamic]Def_Candidate,
    item: ^odinsema.Item,
    path: string,
    tree: ^odinsema.Item_Tree,
    lines: []int,
    inactive: bool,
    member: string,
) {
    target := item
    if member != "" {
        target = nil
        for &child in item.children {
            if child.name == member {
                target = &child
                break
            }
        }
        if target == nil {
            return
        }
    }
    line, _ := offset_line_col(lines, target.name_offset)
    cand := Def_Candidate {
        path      = strings.clone(path, context.temp_allocator),
        name      = strings.clone(target.name, context.temp_allocator),
        kind      = target.kind,
        signature = strings.clone(target.signature, context.temp_allocator),
        offset    = target.name_offset,
        line      = line,
        inactive  = inactive,
    }
    if target.kind == .Proc_Group {
        cand.members = group_members(ctx, target, cand.path, tree)
    }
    append(out, cand)
}

// The package directory and name of each member of a group declared in the file at `path`.
// A qualified member whose import does not resolve is left out.
@(private = "file")
group_members :: proc(ctx: ^Def_Context, item: ^odinsema.Item, path: string, tree: ^odinsema.Item_Tree) -> []Def_Member {
    out := make([dynamic]Def_Member, context.temp_allocator)
    file_dir := path == ctx.live.path ? live_dir(ctx) : filepath.dir(path)
    imports: []odinsema.File_Import
    has_imports := false
    for m in item.members {
        if m.operand == "" {
            append(&out, Def_Member{dir = file_dir, name = strings.clone(m.name, context.temp_allocator), own = true})
            continue
        }
        if !has_imports {
            has_imports = true
            imports, _ = odinsema.file_imports(tree, file_dir, def_collections(ctx), context.temp_allocator)
        }
        imp, found := odinsema.lookup_import(imports, m.operand)
        if !found || !imp.exists {
            continue
        }
        append(&out, Def_Member{dir = imp.dir, name = strings.clone(m.name, context.temp_allocator), own = false})
    }
    return out[:]
}

// The roots the imports of the request resolve against: the Odin root and the configured collections.
@(private = "file")
def_collections :: proc(ctx: ^Def_Context) -> ^odinsema.Collections {
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
@(private = "file")
import_alias_dir :: proc(ctx: ^Def_Context, alias: string) -> (dir: string, is_import: bool) {
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
    imports, err := odinsema.file_imports(ctx.live.tree, live_dir(ctx), def_collections(ctx), context.temp_allocator)
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
@(private = "file")
import_under_caret :: proc(ctx: ^Def_Context, offset: int) -> (dir: string, on_import: bool) {
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
    imports, err := odinsema.file_imports(ctx.live.tree, live_dir(ctx), def_collections(ctx), context.temp_allocator)
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
@(private = "file")
live_dir :: proc(ctx: ^Def_Context) -> string {
    if ctx.live.path == "" {
        return "."
    }
    dir := filepath.dir(ctx.live.path)
    return dir == "" ? "." : dir
}

// Fills `res` with the head of the file of the package at `dir` that is named like the package, else
// the file whose name is closest to it.
@(private = "file")
package_jump :: proc(dir: string, res: ^lang.Result) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)
    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }
    pkg := filepath.base(dir)
    want := strings.concatenate({pkg, ".odin"}, context.temp_allocator)
    best_name, best_path := "", ""
    best_score := 0
    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.name == want {
            best_path = info.fullpath
            break
        }
        s := pkg_file_score(strings.trim_suffix(info.name, ".odin"), pkg)
        if best_name == "" || s > best_score || (s == best_score && info.name < best_name) {
            best_name = info.name
            best_path = info.fullpath
            best_score = s
        }
    }
    if best_path == "" {
        return
    }
    res.location = lang.Location{path = strings.clone(best_path)}
    res.ok = true
}

// How close a file stem is to a package name: a shared prefix, the name as a subsequence and a
// similar length score higher.
@(private = "file")
pkg_file_score :: proc(stem, pkg: string) -> int {
    score := 0
    n := min(len(stem), len(pkg))
    prefix := 0
    for prefix < n && ascii_lower(stem[prefix]) == ascii_lower(pkg[prefix]) {
        prefix += 1
    }
    score += prefix * 8
    qi := 0
    streak := 0
    for i in 0 ..< len(stem) {
        if qi >= len(pkg) {
            break
        }
        if ascii_lower(stem[i]) == ascii_lower(pkg[qi]) {
            score += 2 + streak
            streak += 1
            qi += 1
        } else {
            streak = 0
        }
    }
    if qi == len(pkg) {
        score += 20
    }
    score -= abs(len(stem) - len(pkg)) / 4
    return score
}

@(private = "file")
ascii_lower :: proc(c: u8) -> u8 {
    return c >= 'A' && c <= 'Z' ? c + 32 : c
}

// The Odin root: ODIN_ROOT from the environment, else what `odin root` prints, else the root the
// engine was built with. "" when none is a directory. Temp-allocated.
@(private)
odin_root :: proc(r: ^Odin_Root) -> string {
    sync.lock(&r.mutex)
    defer sync.unlock(&r.mutex)
    if !r.known {
        r.known = true
        r.path = strings.clone(odin_root_find(), r.alloc)
    }
    return strings.clone(r.path, context.temp_allocator)
}

@(private = "file")
odin_root_find :: proc() -> string {
    if v, found := os.lookup_env("ODIN_ROOT", context.temp_allocator); found {
        if root := root_trim(v); root != "" && os.is_dir(root) {
            return root
        }
    }
    output, code, ran := shell.exec_status("odin", {"root"}, "", ODIN_ROOT_TIMEOUT)
    defer delete(output)
    if ran && code == 0 {
        if root := root_trim(output); root != "" && os.is_dir(root) {
            return strings.clone(root, context.temp_allocator)
        }
    }
    if root := root_trim(ODIN_ROOT); root != "" && os.is_dir(root) {
        return root
    }
    return ""
}

// `path` without surrounding space and trailing separators.
@(private = "file")
root_trim :: proc(path: string) -> string {
    return strings.trim_right(strings.trim_space(path), "/\\")
}

@(private)
odin_root_clear :: proc(r: ^Odin_Root) {
    delete(r.path, r.alloc)
    r.path = ""
    r.known = false
}
