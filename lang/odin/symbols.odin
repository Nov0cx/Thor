// Document and workspace symbols from the item trees of package odinsema.
package odin

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Most files and directory levels a workspace walk reads.
@(private)
SCAN_FILE_LIMIT :: 4000
@(private)
SCAN_DEPTH_LIMIT :: 12

// The item trees of the workspace's .odin files, kept across requests and refreshed by stat.
@(private)
Symbol_Index :: struct {
    mutex: sync.Mutex,
    alloc: runtime.Allocator,
    root:  string,                // owned; the workspace the index is for
    files: map[string]Index_File, // owned keys, spelled as os.read_dir gives them
}

@(private)
Index_File :: struct {
    modtime:  i64,
    size:     i64,
    items:    ^odinsema.Item_Tree, // owned
    lines:    []int,               // owned; byte offset of each line start
    key:      string,              // owned; path_key of the path
    in_build: bool,
    seen:     bool,
}

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
    inactive := make([dynamic]lang.Symbol, context.temp_allocator)
    target := config_target(e, req.workspace)
    live_key := ""
    if req.path != "" {
        ctx: Request_Context
        if request_open(e, req, &ctx) {
            live_key = ctx.live.key
            append_matches(res, &inactive, req.query, ctx.live.tree, req.path, ctx.live.lines, ctx.target)
        } else {
            live_key = path_key(req.path)
        }
        request_close(&ctx)
    }
    if req.workspace != "" {
        idx := &e.index
        sync.lock(&idx.mutex)
        defer sync.unlock(&idx.mutex)
        index_sync(e, req)
        for path, &entry in idx.files {
            if lang.request_cancelled(req) {
                append(&res.symbols, ..inactive[:])
                return
            }
            if !entry.in_build || entry.items == nil || (live_key != "" && entry.key == live_key) {
                continue
            }
            append_matches(res, &inactive, req.query, entry.items, path, entry.lines, target)
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

// Brings the index in step with req.workspace on disk: a changed file is read again, a gone one dropped.
// A cancelled walk leaves the index stale and does not prune. The caller holds the index mutex.
@(private)
index_sync :: proc(e: ^Engine, req: ^lang.Request) {
    idx := &e.index
    if idx.root != req.workspace {
        index_clear(idx)
        idx.root = strings.clone(req.workspace, idx.alloc)
        idx.files = make(map[string]Index_File, idx.alloc)
    }
    for _, &entry in idx.files {
        entry.seen = false
    }
    count := 0
    target := config_target(e, req.workspace)
    index_sync_dir(idx, req, req.workspace, target, &count, 0)
    if lang.request_cancelled(req) {
        return
    }
    stale := make([dynamic]string, context.temp_allocator)
    for path, entry in idx.files {
        if !entry.seen {
            append(&stale, path)
        }
    }
    for path in stale {
        key, entry := delete_key(&idx.files, path)
        index_free_file(idx, entry)
        delete(key, idx.alloc)
    }
}

@(private = "file")
index_sync_dir :: proc(idx: ^Symbol_Index, req: ^lang.Request, dir: string, target: odinsema.Target, count: ^int, depth: int) {
    if count^ >= SCAN_FILE_LIMIT || depth > SCAN_DEPTH_LIMIT || lang.request_cancelled(req) {
        return
    }
    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }
    for info in infos {
        if count^ >= SCAN_FILE_LIMIT || lang.request_cancelled(req) {
            return
        }
        if info.type == .Directory {
            if !strings.has_prefix(info.name, ".") {
                index_sync_dir(idx, req, info.fullpath, target, count, depth + 1)
            }
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        count^ += 1
        mt := info.modification_time._nsec
        if entry, ok := &idx.files[info.fullpath]; ok && entry.modtime == mt && entry.size == info.size {
            entry.seen = true
            entry.in_build = entry.items != nil && odinsema.file_in_build(info.fullpath, entry.items.tags, target)
            continue
        }
        index_read_file(idx, info.fullpath, mt, info.size, target)
    }
}

// Reads one file into its index entry. A file that cannot be read keeps an empty entry.
@(private = "file")
index_read_file :: proc(idx: ^Symbol_Index, path: string, modtime, size: i64, target: odinsema.Target) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    entry := Index_File{modtime = modtime, size = size, seen = true}
    entry.key = strings.clone(path_key(path), idx.alloc)
    if source, ok := lang.source_read(path); ok {
        if parsed, err := odinsyntax.parse(source); err == nil {
            entry.items, _ = odinsema.item_tree(parsed, idx.alloc)
            odinsyntax.parse_destroy(&parsed)
        }
        if entry.items != nil {
            entry.in_build = odinsema.file_in_build(path, entry.items.tags, target)
            entry.lines = slice.clone(line_starts(source), idx.alloc)
        }
    }
    if old, found := &idx.files[path]; found {
        index_free_file(idx, old^)
        old^ = entry
        return
    }
    key, err := strings.clone(path, idx.alloc)
    if err != nil {
        index_free_file(idx, entry)
        return
    }
    idx.files[key] = entry
}

@(private = "file")
index_free_file :: proc(idx: ^Symbol_Index, entry: Index_File) {
    odinsema.item_tree_destroy(entry.items, idx.alloc)
    delete(entry.lines, idx.alloc)
    delete(entry.key, idx.alloc)
}

@(private)
index_clear :: proc(idx: ^Symbol_Index) {
    for key, entry in idx.files {
        index_free_file(idx, entry)
        delete(key, idx.alloc)
    }
    delete(idx.files)
    idx.files = nil
    delete(idx.root, idx.alloc)
    idx.root = ""
}
