// Go to definition from the scopes of package odinsema: locals, the package scope, imports,
// the universe scope, enum members and procedure groups. A selector, an implicit selector, a field
// name and a named argument go through the checker.
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

// A declaration a definition can land on. Strings are temp-allocated.
@(private)
Def_Candidate :: struct {
    path:       string,
    name:       string,
    kind:       odinsema.Item_Kind,
    signature:  string,
    offset:     int,
    line:       int,
    inactive:   bool, // under a false `when`, or in a file out of the build
    visibility: odinsema.Visibility, // of the declaration, or of the type that holds the member
    members:    []Def_Member, // Proc_Group
}

// Where a member of a procedure group is declared.
@(private)
Def_Member :: struct {
    dir:  string, // the package directory
    name: string,
    own:  bool, // a bare name, looked up from inside its package
}

// Fills `res` with the declaration the identifier at req.offset names: res.location for one,
// res.symbols for several, active ones first.
@(private)
definition :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    tree := ctx.live.tree

    if dir, on_import := import_under_caret(&ctx, req.offset); on_import {
        if dir != "" {
            package_jump(dir, res)
        }
        return
    }

    m, merr := odinsema.scope_map_range(ctx.parsed, req.offset, req.offset)
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
                emit_candidate(&ctx, &cands, &item, req.path, ctx.live.lines, inactive, "")
                break
            }
        }
        if len(cands) == 0 {
            res.location = lang.Location{path = strings.clone(req.path), start = ref.start, end = ref.end}
            res.ok = true
            return
        }
    case .Free:
        if m.has_using && typed_jump(&ctx, ref.start, res) {
            return
        }
        if dir, is_import := import_alias_dir(&ctx, ref.name); is_import {
            if dir != "" {
                package_jump(dir, res)
            }
            return
        }
        package_candidates(&ctx, own_dir, ref.name, "", true, &cands)
        if len(cands) == 0 {
            builtin_candidates(&ctx, ref.name, &cands)
        }
    case .Package_Qualified:
        if dir, is_import := import_alias_dir(&ctx, ref.operand); is_import {
            if dir != "" {
                package_candidates(&ctx, dir, ref.name, "", false, &cands)
            }
        } else {
            if typed_jump(&ctx, ref.start, res) {
                return
            }
            // `Color.Red`: a member of a type of the package.
            package_candidates(&ctx, own_dir, ref.operand, ref.name, true, &cands)
        }
    case .Field_Or_Member:
        if typed_jump(&ctx, ref.start, res) {
            return
        }
        // `pkg.Type.Member` when the checker gives nothing.
        pkg, type_name, qualified := qualified_type_operand(req.source, m, ref)
        if !qualified {
            return
        }
        if dir, is_import := import_alias_dir(&ctx, pkg); is_import && dir != "" {
            package_candidates(&ctx, dir, type_name, ref.name, false, &cands)
        }
    case .Implicit_Selector, .Field_Name:
        typed_jump(&ctx, ref.start, res)
        return
    }
    if lang.request_cancelled(req) {
        return
    }
    answer(&ctx, cands[:], ref.start, res)
}

// Fills `res` with the declaration the name at `offset` of the buffer refers to through a type. False when the checker finds none.
@(private = "file")
typed_jump :: proc(ctx: ^Request_Context, offset: int, res: ^lang.Result) -> bool {
    sym, found := typed_symbol(ctx, offset)
    if !found {
        return false
    }
    file, start, end, ok := odinsema.symbol_range(request_checker(ctx), sym)
    if !ok {
        return false
    }
    res.location = lang.Location{path = strings.clone(snapshot_path(ctx, file)), start = start, end = end}
    res.ok = true
    return true
}

// Sorts the candidates and fills `res`: one active candidate, or one candidate only, is a jump;
// a lone procedure group is a jump to its members, or a list of them. When the name at `name_offset`
// is the callee of a call, the group gives only the member the arguments pick.
@(private = "file")
answer :: proc(ctx: ^Request_Context, cands: []Def_Candidate, name_offset: int, res: ^lang.Result) {
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
        if len(list) > 1 {
            if i, picked := called_member(ctx, name_offset, list); picked {
                list = list[i:i + 1]
            }
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

// The index of the member a call of the group named at `name_offset` picks by its arguments. False
// when the name is not a callee, the call is ambiguous or no member or more than one has the picked type.
@(private = "file")
called_member :: proc(ctx: ^Request_Context, name_offset: int, members: []Def_Candidate) -> (int, bool) {
    c := request_checker(ctx)
    if c == nil || name_offset < 0 {
        return -1, false
    }
    call, is_callee := odinsema.callee_call(c, ctx.live.id, name_offset)
    if !is_callee {
        return -1, false
    }
    chosen := odinsema.call_group_member(c, ctx.live.id, call)
    if chosen == odinsema.INVALID_TYPE {
        return -1, false
    }
    found := -1
    for m, i in members {
        sym, ok := decl_symbol(ctx, m.path, m.offset)
        if !ok || odinsema.decl_type(c, sym) != chosen {
            continue
        }
        if found >= 0 {
            return -1, false
        }
        found = i
    }
    return found, found >= 0
}

// Appends the declaration of each member of a procedure group that resolves: the first active one of its name.
@(private = "file")
expand_group :: proc(ctx: ^Request_Context, group: Def_Candidate, out: ^[dynamic]Def_Candidate) {
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
@(private)
package_candidates :: proc(ctx: ^Request_Context, dir, name, member: string, own: bool, out: ^[dynamic]Def_Candidate) {
    live := &ctx.live
    replace := odinsema.path_key(dir) == live.dir_key
    start := len(out)
    if replace {
        for &item in live.tree.items {
            if item.name != name || item.kind == .Import || item.kind == .Foreign_Import {
                continue
            }
            inactive := live.in_build && !odinsema.guard_active(live.tree, item.guard, ctx.target)
            emit_candidate(ctx, out, &item, live.path, live.lines, inactive, member)
        }
    }
    // A buffer with no file or outside a workspace stands alone: its directory may be anything.
    if replace && (live.path == "" || ctx.req.workspace == "") {
        return
    }

    view := request_package(ctx, dir)
    if view == nil {
        return
    }
    for ref in odinsema.package_scope_lookup(view.scope, name) {
        if replace && view.files[ref.file] == live.id {
            continue
        }
        item := odinsema.package_item(view.sema_files, ref)
        if !item_reaches(item, own) {
            continue
        }
        data := view.datas[ref.file]
        inactive := !odinsema.package_ref_active(view.scope, ref)
        emit_candidate(ctx, out, item, view.sema_files[ref.file].path, data.lines, inactive, member)
    }
    if len(out) > start {
        return
    }
    for id, i in view.files {
        data := view.datas[i]
        if data == nil || (replace && id == live.id) || odinsema.db_in_build(&ctx.snap, id) {
            continue
        }
        for &item in data.tree.items {
            if item.name == name && item.kind != .Import && item.kind != .Foreign_Import && item_reaches(&item, own) {
                emit_candidate(ctx, out, &item, view.sema_files[i].path, data.lines, true, member)
            }
        }
    }
}

// The package at `dir` in the request's snapshot; nil when it cannot be read or the request is cancelled.
@(private)
request_package :: proc(ctx: ^Request_Context, dir: string) -> ^odinsema.Package_View {
    if dir == "" {
        return nil
    }
    pkg := odinsema.db_package_id(&ctx.snap, dir)
    if pkg == odinsema.NO_PACKAGE {
        return nil
    }
    return odinsema.db_package(&ctx.snap, pkg)
}

// Appends `item`, or with `member` set its field or member of that name, as a candidate.
@(private)
emit_candidate :: proc(
    ctx: ^Request_Context,
    out: ^[dynamic]Def_Candidate,
    item: ^odinsema.Item,
    path: string,
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
        path       = strings.clone(path, context.temp_allocator),
        name       = strings.clone(target.name, context.temp_allocator),
        kind       = target.kind,
        signature  = strings.clone(target.signature, context.temp_allocator),
        offset     = target.name_offset,
        line       = line,
        inactive   = inactive,
        visibility = item.visibility,
    }
    if target.kind == .Proc_Group {
        cand.members = group_members(ctx, target, cand.path)
    }
    append(out, cand)
}

// The package directory and name of each member of a group declared in the file at `path`.
// A qualified member whose import does not resolve is left out.
@(private = "file")
group_members :: proc(ctx: ^Request_Context, item: ^odinsema.Item, path: string) -> []Def_Member {
    out := make([dynamic]Def_Member, context.temp_allocator)
    is_live := path == ctx.live.path
    file_dir := is_live ? live_dir(ctx) : filepath.dir(path)
    imports: []odinsema.File_Import
    has_imports := false
    for m in item.members {
        if m.operand == "" {
            append(&out, Def_Member{dir = file_dir, name = strings.clone(m.name, context.temp_allocator), own = true})
            continue
        }
        if !has_imports {
            has_imports = true
            imports = odinsema.db_imports(&ctx.snap, is_live ? ctx.live.id : odinsema.db_file_id(&ctx.snap, path))
        }
        imp, found := odinsema.lookup_import(imports, m.operand)
        if !found || !imp.exists {
            continue
        }
        append(&out, Def_Member{dir = imp.dir, name = strings.clone(m.name, context.temp_allocator), own = false})
    }
    return out[:]
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
