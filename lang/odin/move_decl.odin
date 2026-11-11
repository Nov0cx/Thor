// Move declaration: a file-scope declaration to another file of its package or of another package.
package odin

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// The state of one move, shared with the reference visitor.
@(private = "file")
Move :: struct {
    rc:           ^Request_Context,
    item:         ^odinsema.Item,
    src_dir_key:  string,
    dest_path:    string, // the snapshot's spelling when the file exists
    dest_dir:     string,
    dest_dir_key: string,
    dest_pkg:     string,
    cross:        bool, // the destination is in another package
    moved_start:  int,  // the moved text in the buffer, doc comment included
    moved_end:    int,
    buffer_hits:  [dynamic]int, // uses in the buffer outside the moved text
    edits:        [dynamic]File_Edit,
    allocator:    mem.Allocator, // outlives the temp guard of each scanned file
    reason:       string,
}

// The file-scope declaration of the buffer whose name holds `offset`.
@(private = "file")
item_named_at :: proc(rc: ^Request_Context, offset: int) -> (^odinsema.Item, bool) {
    for &item in rc.live.tree.items {
        if item.kind == .Import || item.kind == .Foreign_Import || item.name_offset < 0 {
            continue
        }
        if item.name_offset <= offset && offset <= item.name_offset + len(item.name) {
            return &item, true
        }
    }
    return nil, false
}

// True when the declaration stands alone on its lines, outside a `when` and a foreign block.
@(private = "file")
movable :: proc(rc: ^Request_Context, item: ^odinsema.Item) -> bool {
    if item.guard >= 0 || item.in_foreign {
        return false
    }
    for &other in rc.live.tree.items {
        if &other != item && other.start == item.start {
            return false
        }
    }
    src := rc.req.source
    return strings.trim_space(src[line_start(src, item.start):item.start]) == "" && strings.trim_space(src[item.end:line_end(src, item.end)]) == ""
}

// `name` in snake case: `Foo_Bar` and `fooBar` give `foo_bar`.
@(private = "file")
snake_case :: proc(name: string) -> string {
    sb         := strings.builder_make(context.temp_allocator)
    prev_lower := false
    for c in name {
        upper := c >= 'A' && c <= 'Z'
        if upper && prev_lower {
            strings.write_byte(&sb, '_')
        }
        strings.write_rune(&sb, upper ? c + ('a' - 'A') : c)
        prev_lower = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    }
    return strings.to_string(sb)
}

// Offers "Move declaration" on a file-scope declaration of the buffer.
@(private)
move_decl_offer :: proc(rc: ^Request_Context, caret: Caret, res: ^lang.Result) {
    if rc.req.path == "" || caret.sel_end > caret.offset {
        return
    }
    item, ok := item_named_at(rc, caret.offset)
    if !ok || !movable(rc, item) {
        return
    }
    push_prompt_action(res, "Move declaration", ACTION_MOVE_DECLARATION, "Move to file", fmt.tprintf("%s.odin", snake_case(item.name)))
}

// The start of the `//` lines directly above the line of `offset`; the line start when none.
@(private = "file")
doc_start :: proc(src: string, offset: int) -> int {
    start := line_start(src, offset)
    for start > 0 {
        prev := line_start(src, start - 1)
        if !strings.has_prefix(strings.trim_left_space(src[prev:start - 1]), "//") {
            break
        }
        start = prev
    }
    return start
}

// Deletes an import line, with the blank line after it when a blank line comes before it too.
@(private = "file")
import_deletion :: proc(src: string, start, end: int) -> Edit_Spec {
    d := line_deletion(src, start, end)
    if d.start == line_start(src, d.start) && d.start > 0 && blank_line(src, line_start(src, d.start - 1)) && blank_line(src, d.end) {
        d.end = min(line_end(src, d.end) + 1, len(src))
    }
    return d
}

@(private = "file")
blank_line :: proc(src: string, start: int) -> bool {
    return start < len(src) && strings.trim_space(src[start:line_end(src, start)]) == ""
}

// The import declaration that gives `dir` the alias `alias` in a file of `from_dir`.
@(private = "file")
import_line :: proc(rc: ^Request_Context, alias, from_dir, dir: string) -> string {
    path := import_path_to(rc, from_dir, dir)
    if alias == filepath.base(dir) {
        return fmt.tprintf("import \"%s\"", path)
    }
    return fmt.tprintf("import %s \"%s\"", alias, path)
}

// The import path of the package directory `dir` from a file of `from_dir`: through a collection
// when `dir` is under one, else relative with `/` separators.
@(private = "file")
import_path_to :: proc(rc: ^Request_Context, from_dir, dir: string) -> string {
    key := odinsema.path_key(dir)
    under :: proc(key, root: string) -> (string, bool) {
        r := strings.trim_right(odinsema.path_key(root), "/")
        if root == "" || !strings.has_prefix(key, strings.concatenate({r, "/"}, context.temp_allocator)) {
            return "", false
        }
        return key[len(r) + 1:], true
    }
    cols := workspace_collections(rc.e, rc.req.workspace)
    for c in cols.custom {
        if rel, ok := under(key, c.root); ok {
            return fmt.tprintf("%s:%s", c.name, rel)
        }
    }
    if cols.odin_root != "" {
        for name in ([]string{"base", "core", "vendor", "shared"}) {
            root, err := filepath.join({cols.odin_root, name}, context.temp_allocator)
            if err != nil {
                continue
            }
            if rel, ok := under(key, root); ok {
                return fmt.tprintf("%s:%s", name, rel)
            }
        }
    }
    rel, err := filepath.rel(odinsema.path_key(from_dir), key, context.temp_allocator)
    if err != nil {
        return key
    }
    out, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
    return out
}

// The edits that move the declaration under the caret to the file `text` names, and the file to create
// when it does not exist. Strings of the edits live in `allocator`.
@(private)
move_decl_edits :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, text: string, allocator: mem.Allocator) -> ([]File_Edit, []lang.Resource_Op, string) {
    src         := rc.req.source
    item, found := item_named_at(rc, rc.req.offset)
    if !found {
        return nil, nil, "the caret is not on a declaration of this file"
    }
    if !movable(rc, item) {
        return nil, nil, "the declaration does not stand alone on its lines"
    }
    dest := strings.trim_space(text)
    if dest == "" {
        return nil, nil, "no file named"
    }
    if !strings.has_suffix(dest, ".odin") {
        dest = strings.concatenate({dest, ".odin"}, context.temp_allocator)
    }
    src_dir := filepath.dir(rc.req.path)
    if !filepath.is_abs(dest) {
        joined, err := filepath.join({src_dir, dest}, context.temp_allocator)
        if err != nil {
            return nil, nil, "out of memory"
        }
        dest = joined
    }
    if abs, err := os.get_absolute_path(dest, context.temp_allocator); err == nil {
        dest = abs
    }
    dest_dir := filepath.dir(dest)
    if !os.is_dir(dest_dir) {
        return nil, nil, fmt.tprintf("the folder %s does not exist", dest_dir)
    }
    if odinsema.path_key(dest) == rc.live.key {
        return nil, nil, "the declaration is in that file already"
    }

    mv := Move{
        rc = rc,
        item = item,
        src_dir_key = odinsema.path_key(src_dir),
        dest_path = dest,
        dest_dir = dest_dir,
        dest_dir_key = odinsema.path_key(dest_dir),
        moved_start = doc_start(src, item.start),
        moved_end = item.end,
        buffer_hits = make([dynamic]int, context.temp_allocator),
        edits = make([dynamic]File_Edit, allocator),
        allocator = allocator,
    }
    mv.cross = mv.dest_dir_key != mv.src_dir_key

    snap     := &rc.snap
    exists   := os.is_file(dest)
    dest_src := ""
    dest_tree: ^odinsema.Item_Tree
    dest_imports: []odinsema.File_Import
    if exists {
        id     := odinsema.db_file_id(snap, dest)
        parsed := odinsema.db_parse(snap, id)
        data   := odinsema.db_file(snap, id)
        if parsed == nil || parsed.tree == nil || data == nil {
            return nil, nil, "the file cannot be read"
        }
        mv.dest_path = odinsema.db_file_path(snap, id)
        dest_src = strings.clone(parsed.tree.text, allocator)
        dest_tree = data.tree
        dest_imports = odinsema.db_imports(snap, id)
    }
    view := request_package(rc, dest_dir)
    if view != nil && view.scope != nil && view.scope.name != "" {
        mv.dest_pkg = view.scope.name
    } else if dest_tree != nil && dest_tree.package_name != "" {
        mv.dest_pkg = dest_tree.package_name
    } else if mv.cross {
        mv.dest_pkg = filepath.base(dest_dir)
    } else {
        mv.dest_pkg = rc.live.tree.package_name
    }
    if !odinsema.is_identifier(mv.dest_pkg) {
        return nil, nil, fmt.tprintf("'%s' is not a package name", mv.dest_pkg)
    }
    if mv.cross && view != nil && view.scope != nil && item.name in view.scope.names {
        return nil, nil, fmt.tprintf("package %s already declares '%s'", mv.dest_pkg, item.name)
    }

    // The names the moved text reads: the imports it needs, and what it uses of its own package.
    src_view       := request_package(rc, src_dir)
    buffer_imports := odinsema.db_imports(snap, rc.live.id)
    needed         := make([dynamic]odinsema.File_Import, context.temp_allocator)
    dropped        := make([dynamic]Edit_Spec, context.temp_allocator) // `alias.` the moved text loses
    for ref in m.refs {
        if ref.start < item.start || ref.start >= item.end {
            continue
        }
        if ref.kind == .Package_Qualified {
            imp, ok := import_of(buffer_imports, ref.operand)
            if !ok {
                continue
            }
            if mv.cross && odinsema.path_key(imp.dir) == mv.dest_dir_key {
                append(&dropped, Edit_Spec{ref.operand_start, ref.start, ""})
            } else if !has_import(needed[:], imp.alias) {
                append(&needed, imp)
            }
            continue
        }
        if ref.kind != .Free || ref.name == item.name {
            continue
        }
        if _, is_alias := import_of(buffer_imports, ref.name); is_alias {
            continue
        }
        if src_view == nil || src_view.scope == nil || ref.name not_in src_view.scope.names {
            continue
        }
        if mv.cross {
            return nil, nil, fmt.tprintf("'%s' uses '%s' of its package; move it too", item.name, ref.name)
        }
        if file_private_item(rc.live.tree, ref.name) {
            return nil, nil, fmt.tprintf("'%s' uses '%s', which is private to this file", item.name, ref.name)
        }
    }

    // The import lines of the destination.
    lines := make([dynamic]string, context.temp_allocator)
    for imp in needed {
        if exists {
            if have, ok := import_of(dest_imports, imp.alias); ok {
                if odinsema.path_key(have.dir) != odinsema.path_key(imp.dir) {
                    return nil, nil, fmt.tprintf("'%s' names another package in %s", imp.alias, filepath.base(dest))
                }
                continue
            }
            if have, ok := import_of_dir(dest_imports, imp.dir); ok {
                return nil, nil, fmt.tprintf("%s imports %s as '%s'", filepath.base(dest), imp.path, have.alias)
            }
        }
        path := imp.path
        if imp.collection == "" && mv.cross {
            path = import_path_to(rc, dest_dir, imp.dir)
        }
        if imp.explicit {
            append(&lines, fmt.tprintf("import %s \"%s\"", imp.alias, path))
        } else {
            append(&lines, fmt.tprintf("import \"%s\"", path))
        }
    }

    target := ref_target(rc)
    if target.kind != .Package_Item || target.decl != item.name_offset {
        return nil, nil, "the declaration has no references to follow"
    }
    if !visit_references(rc, target, false, visit_move_file, &mv) {
        if mv.reason != "" {
            return nil, nil, mv.reason
        }
        return nil, nil, "cancelled"
    }
    if mv.reason != "" {
        return nil, nil, mv.reason
    }
    if !mv.cross && len(mv.buffer_hits) > 0 && item.visibility == .File {
        return nil, nil, fmt.tprintf("'%s' is private to this file and used in it", item.name)
    }

    // The moved text, without the qualifiers of the destination package.
    moved := moved_text(src[mv.moved_start:item.end], mv.moved_start, dropped[:])

    // The buffer: the cut, the imports only the moved text used, and the destination import.
    cut_end := min(line_end(src, item.end) + 1, len(src))
    if blank_line(src, cut_end) && (mv.moved_start == 0 || blank_line(src, line_start(src, mv.moved_start - 1))) {
        cut_end = min(line_end(src, cut_end) + 1, len(src))
    }
    buffer := make([dynamic]Edit_Spec, context.temp_allocator)
    append(&buffer, Edit_Spec{mv.moved_start, cut_end, ""})
    for imp in needed {
        if alias_used_outside(m, imp.alias, mv.moved_start, cut_end) || imp.item < 0 || imp.item >= len(rc.live.tree.items) {
            continue
        }
        it := rc.live.tree.items[imp.item]
        append(&buffer, import_deletion(src, it.start, it.end))
    }
    for d in dropped {
        imp, _ := import_of(buffer_imports, src[d.start:d.end - 1])
        if imp.item < 0 || imp.item >= len(rc.live.tree.items) || alias_used_outside(m, imp.alias, mv.moved_start, cut_end) {
            continue
        }
        it := rc.live.tree.items[imp.item]
        if !has_spec(buffer[:], import_deletion(src, it.start, it.end)) {
            append(&buffer, import_deletion(src, it.start, it.end))
        }
    }
    if mv.cross && len(mv.buffer_hits) > 0 {
        alias, line, reason := dest_alias(&mv, rc.live.tree, buffer_imports, src_dir)
        if reason != "" {
            return nil, nil, reason
        }
        if line != "" {
            at, insert := import_insert_in(src, rc.live.tree, line)
            folded     := false
            for &b in buffer {
                if b.start <= at && at < b.end && b.text == "" && b.start != mv.moved_start {
                    b.text = strings.concatenate({line, "\n"}, context.temp_allocator)
                    folded = true
                    break
                }
            }
            if !folded {
                append(&buffer, Edit_Spec{at, at, insert})
            }
        }
        for h in mv.buffer_hits {
            append(&buffer, Edit_Spec{h, h, strings.concatenate({alias, "."}, context.temp_allocator)})
        }
    }
    for b in buffer {
        append(&mv.edits, File_Edit{rc.req.path, src, b.start, b.end, strings.clone(b.text, allocator)})
    }

    // The destination file.
    ops: []lang.Resource_Op
    if exists {
        for line in lines {
            at, insert := import_insert_in(dest_src, dest_tree, line)
            append(&mv.edits, File_Edit{mv.dest_path, dest_src, at, at, strings.clone(insert, allocator)})
        }
        sep := strings.has_suffix(dest_src, "\n") ? "\n" : "\n\n"
        append(&mv.edits, File_Edit{mv.dest_path, dest_src, len(dest_src), len(dest_src), strings.concatenate({sep, moved, "\n"}, allocator)})
    } else {
        sb := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&sb, "package %s\n", mv.dest_pkg)
        if len(lines) > 0 {
            strings.write_byte(&sb, '\n')
            for line in lines {
                strings.write_string(&sb, line)
                strings.write_byte(&sb, '\n')
            }
        }
        fmt.sbprintf(&sb, "\n%s\n", moved)
        append(&mv.edits, File_Edit{strings.clone(dest, allocator), "", 0, 0, strings.clone(strings.to_string(sb), allocator)})
        ops = make([]lang.Resource_Op, 1, context.temp_allocator)
        ops[0] = lang.Resource_Op{kind = .Create, path = dest}
    }
    return mv.edits[:], ops, ""
}

// `text`, which starts at `base` in the buffer, with the ranges of `drop` removed.
@(private = "file")
moved_text :: proc(text: string, base: int, drop: []Edit_Spec) -> string {
    sb := strings.builder_make(context.temp_allocator)
    at := 0
    for d in sort_specs(drop) {
        strings.write_string(&sb, text[at:d.start - base])
        at = d.end - base
    }
    strings.write_string(&sb, text[at:])
    return strings.to_string(sb)
}

@(private = "file")
sort_specs :: proc(specs: []Edit_Spec) -> []Edit_Spec {
    out := make([]Edit_Spec, len(specs), context.temp_allocator)
    copy(out, specs)
    for i in 1 ..< len(out) {
        for j := i; j > 0 && out[j].start < out[j - 1].start; j -= 1 {
            out[j], out[j - 1] = out[j - 1], out[j]
        }
    }
    return out
}

@(private = "file")
has_spec :: proc(specs: []Edit_Spec, s: Edit_Spec) -> bool {
    for x in specs {
        if x.start == s.start && x.end == s.end {
            return true
        }
    }
    return false
}

@(private = "file")
import_of :: proc(imports: []odinsema.File_Import, alias: string) -> (odinsema.File_Import, bool) {
    for imp in imports {
        if !imp.is_foreign && imp.alias == alias && alias != "_" {
            return imp, true
        }
    }
    return {}, false
}

@(private = "file")
import_of_dir :: proc(imports: []odinsema.File_Import, dir: string) -> (odinsema.File_Import, bool) {
    key := odinsema.path_key(dir)
    for imp in imports {
        if !imp.is_foreign && imp.dir != "" && odinsema.path_key(imp.dir) == key {
            return imp, true
        }
    }
    return {}, false
}

@(private = "file")
has_import :: proc(imports: []odinsema.File_Import, alias: string) -> bool {
    _, ok := import_of(imports, alias)
    return ok
}

// True when `name` is a declaration of `tree` that only its own file can name.
@(private = "file")
file_private_item :: proc(tree: ^odinsema.Item_Tree, name: string) -> bool {
    for item in tree.items {
        if item.name == name && item.visibility == .File {
            return true
        }
    }
    return false
}

// True when the buffer names the import alias `alias` outside [start, end).
@(private = "file")
alias_used_outside :: proc(m: ^odinsema.Scope_Map, alias: string, start, end: int) -> bool {
    for ref in m.refs {
        if ref.start >= start && ref.start < end {
            continue
        }
        if (ref.kind == .Package_Qualified && ref.operand == alias) || (ref.kind == .Free && ref.name == alias) {
            return true
        }
    }
    return false
}

// The alias a file of `file_dir` names the destination package by, and the import line to add; "" as
// the line when the file imports it already.
@(private = "file")
dest_alias :: proc(mv: ^Move, tree: ^odinsema.Item_Tree, imports: []odinsema.File_Import, file_dir: string) -> (alias, line, reason: string) {
    if have, ok := import_of_dir(imports, mv.dest_dir); ok {
        return have.alias, "", ""
    }
    alias = mv.dest_pkg
    taken := has_import(imports, alias)
    for item in tree.items {
        taken ||= item.name == alias && item.kind != .Import
    }
    if taken {
        return "", "", fmt.tprintf("'%s' is taken in %s", alias, filepath.base(file_dir))
    }
    home := odinsema.db_package_id(&mv.rc.snap, file_dir)
    if cycles := odinsema.import_cycles(&mv.rc.snap, home, {mv.dest_dir}); len(cycles) > 0 && cycles[0] {
        return "", "", fmt.tprintf("package %s imports %s, so the import would be a cycle", mv.dest_pkg, filepath.base(file_dir))
    }
    return alias, import_line(mv.rc, alias, file_dir, mv.dest_dir), ""
}

// Records the uses of one file: the buffer's for later, the others' as edits.
@(private = "file")
visit_move_file :: proc(data: rawptr, f: Ref_File) -> bool {
    mv           := cast(^Move)data
    rc           := mv.rc
    item         := mv.item
    in_buffer    := odinsema.path_key(f.path) == rc.live.key
    file_dir     := filepath.dir(f.path)
    dir_key      := odinsema.path_key(file_dir)
    in_dest_file := odinsema.path_key(f.path) == odinsema.path_key(mv.dest_path)
    root         := odinsyntax.node_root(f.parsed.tree)
    // Same package: only a file-private destination can break a use.
    if !mv.cross {
        for offset in f.hits {
            if in_buffer && offset >= mv.moved_start && offset < mv.moved_end {
                continue
            }
            if in_buffer {
                append(&mv.buffer_hits, offset)
            }
            if !in_dest_file && dest_file_private(mv) {
                mv.reason = fmt.aprintf(
                    "%s is private to its file and '%s' is used at %s",
                    filepath.base(mv.dest_path),
                    item.name,
                    move_place(f, offset),
                    allocator = mv.allocator,
                )
                return false
            }
        }
        return true
    }
    source       := ""
    alias        := ""
    needs_import := false
    for offset in f.hits {
        if in_buffer && offset >= mv.moved_start && offset < mv.moved_end {
            continue
        }
        if dir_key != mv.dest_dir_key && (item.visibility != .Public || dest_file_private(mv)) {
            mv.reason = fmt.aprintf(
                "'%s' would be private to package %s and is used at %s",
                item.name,
                mv.dest_pkg,
                move_place(f, offset),
                allocator = mv.allocator,
            )
            return false
        }
        if in_buffer {
            append(&mv.buffer_hits, offset)
            continue
        }
        tok, found := odinsyntax.node_token_at(root, u32(offset), context.temp_allocator)
        if !found || tok.parent == nil {
            continue
        }
        op_start, op_end, qualified := qualifier_of(tok.parent)
        start, end, text := offset, offset, ""
        switch {
        case dir_key == mv.dest_dir_key:
            if !qualified {
                continue
            }
            start, end = op_start, offset
        case dir_key == mv.src_dir_key:
            if qualified {
                continue
            }
            needs_import = true
        case:
            if !qualified {
                continue
            }
            start, end = op_start, op_end
            needs_import = true
        }
        if needs_import && alias == "" {
            id := odinsema.db_file_id(&rc.snap, f.path)
            line, reason: string
            alias, line, reason = dest_alias(mv, f.tree, odinsema.db_imports(&rc.snap, id), file_dir)
            if reason != "" {
                mv.reason = strings.clone(reason, mv.allocator)
                return false
            }
            if line != "" {
                at, insert := import_insert_in(f.source, f.tree, line)
                move_edit(mv, f, &source, at, at, insert)
            }
        }
        switch {
        case dir_key == mv.dest_dir_key:
            text = ""
        case dir_key == mv.src_dir_key:
            text = strings.concatenate({alias, "."}, context.temp_allocator)
        case:
            text = alias
        }
        move_edit(mv, f, &source, start, end, text)
    }
    return true
}

// True when the destination file is `#+private` or `#+private file`.
@(private = "file")
dest_file_private :: proc(mv: ^Move) -> bool {
    if !os.is_file(mv.dest_path) {
        return false
    }
    data := odinsema.db_file(&mv.rc.snap, odinsema.db_file_id(&mv.rc.snap, mv.dest_path))
    return data != nil && data.tree.private != .Public
}

// The operand of `pkg.name` when `ident` is its field and the operand is a name.
@(private = "file")
qualifier_of :: proc(ident: ^odinsyntax.Syntax_Node) -> (start, end: int, ok: bool) {
    p := ident.parent
    if p == nil || p.green.kind != .Selector_Expr {
        return
    }
    sel, _               := odinsyntax.as_selector_expr(p^)
    field, has_field     := odinsyntax.selector_expr_field(&sel)
    operand, has_operand := odinsyntax.selector_expr_operand(&sel)
    if !has_field || !has_operand || field.offset != ident.offset || operand.green.kind != .Ident {
        return
    }
    s, e := odinsyntax.node_range(operand)
    // The field starts after the period, which ends the removed range.
    return int(s), int(e), true
}

@(private = "file")
move_place :: proc(f: Ref_File, offset: int) -> string {
    line, _ := offset_line_col(f.lines, offset)
    return fmt.tprintf("%s:%d", filepath.base(f.path), line)
}

// Appends one edit of `f`; `source` is the copy of the file's text the edits of this file share.
@(private = "file")
move_edit :: proc(mv: ^Move, f: Ref_File, source: ^string, start, end: int, text: string) {
    if source^ == "" {
        source^ = strings.clone(f.source, mv.allocator)
    }
    append(
        &mv.edits,
        File_Edit{path = strings.clone(f.path, mv.allocator), source = source^, start = start, end = end, text = strings.clone(text, mv.allocator)},
    )
}
