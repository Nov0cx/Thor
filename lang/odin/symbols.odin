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

// Fills `res` with the outline of the request's buffer in source order: each declaration,
// then its fields or members.
@(private)
document_symbols :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    tree := request_item_tree(e, req)
    if tree == nil {
        return
    }
    defer odinsema.item_tree_destroy(tree)
    lines := line_starts(req.source)
    for &item in tree.items {
        if symbol_kind(item.kind) == "" {
            continue
        }
        append_symbol(res, &item, req.path, lines)
        for &child in item.children {
            append_symbol(res, &child, req.path, lines)
        }
    }
    res.ok = true
}

// Fills `res` with the top-level declarations of the workspace whose name matches req.query,
// sorted by name and then path. The live buffer counts in place of its file on disk,
// and a disk file counts when it is in the build of the workspace target (config_target).
@(private)
workspace_symbols :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    live_key := ""
    if req.path != "" {
        live_key = path_key(req.path)
        if tree := request_item_tree(e, req); tree != nil {
            lines := line_starts(req.source)
            for &item in tree.items {
                if symbol_kind(item.kind) != "" && lang.symbol_matches(req.query, item.name) {
                    append_symbol(res, &item, req.path, lines)
                }
            }
            odinsema.item_tree_destroy(tree)
        }
    }
    if req.workspace != "" {
        idx := &e.index
        sync.lock(&idx.mutex)
        defer sync.unlock(&idx.mutex)
        index_sync(e, req)
        for path, &entry in idx.files {
            if lang.request_cancelled(req) {
                return
            }
            if !entry.in_build || entry.items == nil || (live_key != "" && entry.key == live_key) {
                continue
            }
            for &item in entry.items.items {
                if symbol_kind(item.kind) != "" && lang.symbol_matches(req.query, item.name) {
                    append_symbol(res, &item, path, entry.lines)
                }
            }
        }
    }
    slice.sort_by(res.symbols[:], proc(a, b: lang.Symbol) -> bool {
        if a.name != b.name {
            return a.name < b.name
        }
        return a.path < b.path
    })
    res.ok = true
}

// The item tree of the request's buffer, through the parse cache when it has a path; nil on failure.
@(private = "file")
request_item_tree :: proc(e: ^Engine, req: ^lang.Request) -> ^odinsema.Item_Tree {
    parsed: odinsyntax.Parse
    if req.path != "" {
        ok: bool
        parsed, ok = parse_cache_get(&e.parses, req.path, req.source)
        if !ok {
            return nil
        }
        defer parse_cache_put(&e.parses, req.path, parsed)
        tree, err := odinsema.item_tree(parsed)
        return err == nil ? tree : nil
    }
    err: runtime.Allocator_Error
    parsed, err = odinsyntax.parse(req.source)
    if err != nil {
        return nil
    }
    defer odinsyntax.parse_destroy(&parsed)
    tree, terr := odinsema.item_tree(parsed)
    return terr == nil ? tree : nil
}

// Appends one item as a symbol; every string is cloned into context.allocator (the Manager's).
@(private = "file")
append_symbol :: proc(res: ^lang.Result, item: ^odinsema.Item, path: string, lines: []int) {
    line, _ := offset_line_col(lines, item.name_offset)
    append(&res.symbols, lang.Symbol {
        name      = strings.clone(item.name),
        kind      = strings.clone(symbol_kind(item.kind)),
        signature = strings.clone(item.signature),
        path      = strings.clone(path),
        line      = line,
        offset    = item.name_offset,
    })
}

// `path` spelled for comparison: absolute, forward slashes, and lower case where the file system
// ignores case. Temp-allocated.
@(private)
path_key :: proc(path: string) -> string {
    abs, err := os.get_absolute_path(path, context.temp_allocator)
    if err != nil {
        abs = path
    }
    key, _ := strings.replace_all(abs, "\\", "/", context.temp_allocator)
    when ODIN_OS == .Windows || ODIN_OS == .Darwin {
        key = strings.to_lower(key, context.temp_allocator)
    }
    return key
}

// Brings the index in step with req.workspace on disk: a changed file is read again, a gone one dropped.
// A cancelled walk leaves the index stale and does not prune. The caller holds the index mutex.
@(private = "file")
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
