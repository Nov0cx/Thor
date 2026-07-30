// In-client Odin analyzer: the first Language backend, running natively on the
// Manager's worker thread with no subprocess and no serialization. It parses
// with the vendored tree-sitter grammar, then resolves an identifier to its
// declaration using the grammar's LOCALS query for lexical scope, falling back
// to a workspace-wide scan of top-level declarations for cross-file symbols.
package lang

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import ts "../vendor/odin-tree-sitter"
import ts_odin "../vendor/odin-tree-sitter/parsers/odin"

// Files scanned in one cross-file lookup, and directory depth, so a huge tree
// can't stall a goto. Mirrors thor_collect_files' guards.
@(private = "file")
SCAN_FILE_LIMIT :: 4000
@(private = "file")
SCAN_DEPTH_LIMIT :: 12

Odin_Engine :: struct {
    language: ts.Language,
    locals:   ts.Query, // compiled once, immutable, shared read-only across workers
    index:    Symbol_Index,
    config:   Config_Cache,
    trees:    Tree_Cache,
}

// A resident top-level declaration: self-owned copies (the parse tree and its
// source are long gone by the time a query reads this) plus the jump target.
// Mirrors the Symbol row a query returns, minus the path (the File_Entry key).
@(private = "file")
Index_Symbol :: struct {
    name:      string,
    kind:      string,
    signature: string,
    line:      int,
    offset:    int,
}

// One indexed file: its top-level declarations, the set of every identifier name
// it mentions (the reference-scan filter — a file whose `idents` lacks a name
// can't contain a usage, so it is never re-parsed for that search), and the stat
// used to notice it changed, so an unchanged file is never re-parsed at all.
@(private = "file")
File_Entry :: struct {
    modtime: i64,
    size:    i64,
    decls:   [dynamic]Index_Symbol,
    idents:  map[string]bool, // unique identifier names, engine-owned keys
}

// A workspace-wide store of parsed top-level declarations, resident on the
// engine across requests so a cross-file lookup re-parses only the files that
// changed rather than the whole tree. Guarded by its own mutex; every owned
// field uses `alloc` (the engine's allocator, captured at create), never the
// per-request Manager allocator that query results clone into.
@(private = "file")
Symbol_Index :: struct {
    mutex: sync.Mutex,
    files: map[string]File_Entry, // keyed by the path exactly as os.read_dir spells it
    root:  string,                // the workspace this was built for
    built: bool,
    alloc: runtime.Allocator,
}

odin_engine_create :: proc() -> ^Odin_Engine {
    e := new(Odin_Engine)
    e.language = ts_odin.tree_sitter_odin()
    query, _, err := ts.query_new(e.language, ts_odin.LOCALS)
    if err == .None {
        e.locals = query
    }
    e.index.alloc = context.allocator
    e.index.files = make(map[string]File_Entry, 0, e.index.alloc)
    e.config.alloc = context.allocator
    e.trees.alloc = context.allocator
    e.trees.entries = make([dynamic]Tree_Entry, e.trees.alloc)
    return e
}

// Wraps the engine as a Backend for manager_register.
odin_engine_backend :: proc(e: ^Odin_Engine) -> Backend {
    return Backend {
        data    = e,
        name    = "odin (in-client)",
        handles = odin_handles,
        resolve = odin_resolve,
        destroy = odin_destroy,
    }
}

@(private = "file")
odin_handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".odin"
}

@(private)
odin_destroy :: proc(data: rawptr) {
    e := cast(^Odin_Engine) data
    if e.locals != nil {
        ts.query_delete(e.locals)
    }
    index_clear(e)
    config_clear(e)
    tree_cache_clear(e)
    free(e)
}

// Ensures the index reflects `req.workspace` on disk. Rebuilds from scratch when
// the workspace changed; otherwise re-`read_dir`s the tree (cheap) and re-parses
// only files whose stat differs, plus new files, and drops entries for files that
// vanished — so the expensive parse is skipped for the unchanged majority. All
// index storage lands in the engine allocator (context set locally); the caller
// holds e.index.mutex. Bounded by the same file/depth guards as the old scan.
//
// A cancelled request abandons the walk part-way, which leaves the index merely
// stale, never wrong: the entries it did refresh are correct, and the next sync
// re-stats everything anyway. The prune is skipped in that case — `seen` is
// incomplete, so pruning against it would drop live files.
@(private = "file")
index_sync :: proc(e: ^Odin_Engine, parser: ts.Parser, req: ^Request) {
    workspace := req.workspace
    if workspace == "" {
        return
    }
    idx := &e.index
    context.allocator = idx.alloc // every clone/make below is engine-owned

    if !idx.built || idx.root != workspace {
        index_clear(e)
        idx.files = make(map[string]File_Entry)
        idx.root = strings.clone(workspace)
        idx.built = true
    }

    seen := make(map[string]bool, 0, context.temp_allocator)
    count := 0
    index_sync_dir(e, parser, req, workspace, &seen, &count, 0)
    if request_cancelled(req) {
        return
    }

    // Prune files that disappeared (collect first; can't delete while ranging).
    stale := make([dynamic]string, context.temp_allocator)
    for path in idx.files {
        if path not_in seen {
            append(&stale, path)
        }
    }
    for path in stale {
        entry := idx.files[path]
        index_free_entry(idx, entry)
        delete_key(&idx.files, path)
        delete(path, idx.alloc)
    }
}

@(private = "file")
index_sync_dir :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    req: ^Request,
    dir: string,
    seen: ^map[string]bool,
    count: ^int,
    depth: int,
) {
    if count^ >= SCAN_FILE_LIMIT || depth > SCAN_DEPTH_LIMIT || request_cancelled(req) {
        return
    }

    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    for info in infos {
        if count^ >= SCAN_FILE_LIMIT || request_cancelled(req) {
            return
        }
        if info.type == .Directory {
            if info.name == ".git" || strings.has_prefix(info.name, ".") {
                continue
            }
            index_sync_dir(e, parser, req, info.fullpath, seen, count, depth + 1)
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        count^ += 1
        key := info.fullpath // temp-owned; only stored (cloned) when a new entry
        seen^[key] = true
        mt := info.modification_time._nsec
        if entry, ok := e.index.files[key]; ok && entry.modtime == mt && entry.size == info.size {
            continue // unchanged since last sync — keep the parsed decls
        }
        index_reparse(e, parser, key, mt, info.size)
    }
}

// Re-parses one file and replaces its index entry with fresh top-level decls.
// context.allocator is the engine allocator (set by index_sync), so every stored
// string is engine-owned; the source is read into scratch and gone after.
@(private = "file")
index_reparse :: proc(e: ^Odin_Engine, parser: ts.Parser, key: string, modtime, size: i64) {
    idx := &e.index

    data, rerr := os.read_entire_file(key, context.temp_allocator)
    if rerr != nil {
        return
    }
    source := string(data)

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)

    root := ts.tree_root_node(tree)
    entry := File_Entry {
        modtime = modtime,
        size    = size,
        decls   = make([dynamic]Index_Symbol),
        idents  = make(map[string]bool),
    }
    defs := collect_defs(e, root, source)
    for d in defs {
        if !d.top_level {
            continue
        }
        ident_start := clamp(d.ident_start, 0, len(source))
        append(&entry.decls, Index_Symbol {
            name      = strings.clone(d.name),
            kind      = strings.clone(d.kind),
            signature = signature_text(source, d), // clones into context.allocator
            line      = strings.count(source[:ident_start], "\n") + 1,
            offset    = d.ident_start,
        })
    }
    index_collect_idents(root, source, &entry.idents)

    // Existing key: free the old decls and update in place (the owned key stays).
    // New key: clone it into the engine allocator so it outlives the scratch info.
    if old, ok := idx.files[key]; ok {
        index_free_entry(idx, old)
        idx.files[key] = entry
    } else {
        idx.files[strings.clone(key)] = entry
    }
}

// Records every distinct `identifier` name in `node`'s subtree into `set`,
// cloning each new name once into context.allocator (the engine allocator, set by
// index_reparse). This is the reference-scan filter: a name absent from a file's
// set can't be used there, so that file is skipped without a re-parse.
@(private = "file")
index_collect_idents :: proc(node: ts.Node, source: string, set: ^map[string]bool) {
    if is_identifier(node) {
        name := ts.node_text(node, source)
        if name not_in set^ {
            set^[strings.clone(name)] = true
        }
    }
    for i in 0 ..< ts.node_child_count(node) {
        index_collect_idents(ts.node_child(node, i), source, set)
    }
}

// Cross-file goto: appends every indexed top-level declaration named `name`
// (excluding the live file `skip`, already searched lexically) to res.symbols as
// picker candidates, sorted by path for a stable order. Owned strings clone into
// context.allocator (the Manager's, as odin_resolve left it). Caller holds the mutex.
@(private = "file")
index_find_defs :: proc(e: ^Odin_Engine, name, skip: string, res: ^Result) {
    for path, entry in e.index.files {
        if path == skip {
            continue
        }
        for sym in entry.decls {
            if sym.name != name {
                continue
            }
            append(&res.symbols, index_symbol_row(sym, path))
        }
    }
    slice.sort_by(res.symbols[:], proc(a, b: Symbol) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
}

// Workspace symbols: appends every indexed declaration of a shown kind (proc,
// type, enum, constant, var — the outline set), excluding the live file `skip`
// whose decls the caller already collected from the unsaved buffer.
@(private = "file")
index_all_symbols :: proc(e: ^Odin_Engine, skip: string, res: ^Result) {
    for path, entry in e.index.files {
        if path == skip {
            continue
        }
        for sym in entry.decls {
            if !symbol_kind_shown(sym.kind) {
                continue
            }
            append(&res.symbols, index_symbol_row(sym, path))
        }
    }
}

// Lexicographically-smallest indexed file declaring `name` (of `kind_filter`, or
// any kind when it is ""), excluding `skip`. Deterministic first-hit for hover
// and signature help, which then re-parse just that one file for full detail.
@(private = "file")
index_first_path :: proc(e: ^Odin_Engine, name, skip, kind_filter: string) -> (string, bool) {
    best := ""
    found := false
    for path, entry in e.index.files {
        if path == skip {
            continue
        }
        for sym in entry.decls {
            if sym.name != name || (kind_filter != "" && sym.kind != kind_filter) {
                continue
            }
            if !found || path < best {
                best = path
                found = true
            }
            break
        }
    }
    return best, found
}

// Appends the path of every indexed file that mentions `name` (excluding the
// live file `skip`) to `out`, each cloned into `out`'s allocator so it survives
// after the caller drops the mutex. Files whose `idents` lack the name — the
// majority — are skipped, so the reference scan re-parses only real candidates.
@(private = "file")
index_ref_files :: proc(e: ^Odin_Engine, name, skip: string, out: ^[dynamic]string) {
    for path, entry in e.index.files {
        if path == skip {
            continue
        }
        if name in entry.idents {
            append(out, strings.clone(path, out.allocator))
        }
    }
}

// Completion: appends the indexed top-level declarations of the files sitting
// directly in `dir` (a package is one flat directory), excluding the live file
// `skip` and filtered by `prefix`. Reports whether the directory held any indexed
// file at all — false means it lies outside the indexed workspace (a stdlib or
// collection package), and the caller falls back to reading it off disk. Caller
// holds the mutex; result strings clone into context.allocator (the Manager's),
// and the dedup keys into scratch, so nothing borrows an index row past the
// unlock — another worker may reparse this entry and free its strings.
@(private = "file")
index_dir_completions :: proc(
    e: ^Odin_Engine,
    dir, prefix, skip: string,
    res: ^Result,
    seen: ^map[string]bool,
) -> bool {
    indexed := false
    for path, entry in e.index.files {
        if !path_in_dir(path, dir) {
            continue
        }
        indexed = true
        if path == skip {
            continue
        }
        for sym in entry.decls {
            if !symbol_kind_shown(sym.kind) || !completion_matches(sym.name, prefix) {
                continue
            }
            if sym.name in seen^ {
                continue
            }
            seen^[strings.clone(sym.name, context.temp_allocator)] = true
            append(&res.symbols, Symbol {
                name      = strings.clone(sym.name),
                kind      = strings.clone(sym.kind),
                signature = strings.clone(sym.signature),
            })
        }
    }
    return indexed
}

// Whether `path` names a file directly inside `dir` — same prefix, one separator,
// nothing further nested. `/` and `\` compare equal (the index keys the spellings
// os.read_dir produced, the caller's come from filepath.dir), but the comparison
// is otherwise literal, so the usual canonicalization assumption applies. A
// spelling that doesn't line up just misses, and the caller's disk fallback still
// answers correctly — this can only cost speed, never candidates.
@(private = "file")
path_in_dir :: proc(path, dir: string) -> bool {
    if dir == "" || len(path) <= len(dir) + 1 {
        return false
    }
    for i in 0 ..< len(dir) {
        a, b := path[i], dir[i]
        if a == b || (is_path_sep(a) && is_path_sep(b)) {
            continue
        }
        return false
    }
    if !is_path_sep(path[len(dir)]) {
        return false
    }
    return strings.index_any(path[len(dir) + 1:], "/\\") < 0
}

@(private = "file")
is_path_sep :: proc(b: u8) -> bool {
    return b == '/' || b == '\\'
}

// A Symbol result row copied out of the index, cloned into context.allocator.
@(private = "file")
index_symbol_row :: proc(sym: Index_Symbol, path: string) -> Symbol {
    return Symbol {
        name      = strings.clone(sym.name),
        kind      = strings.clone(sym.kind),
        signature = strings.clone(sym.signature),
        path      = strings.clone(path),
        line      = sym.line,
        offset    = sym.offset,
    }
}

// Frees one entry's owned decl strings and the decls array (engine allocator).
@(private = "file")
index_free_entry :: proc(idx: ^Symbol_Index, entry: File_Entry) {
    for sym in entry.decls {
        delete(sym.name, idx.alloc)
        delete(sym.kind, idx.alloc)
        delete(sym.signature, idx.alloc)
    }
    delete(entry.decls)
    for name in entry.idents {
        delete(name, idx.alloc)
    }
    delete(entry.idents)
}

// Tears the whole index down (on destroy, or before a rebuild for a new
// workspace): frees every entry, every owned key, the map, and the root string.
@(private = "file")
index_clear :: proc(e: ^Odin_Engine) {
    idx := &e.index
    for path, entry in idx.files {
        index_free_entry(idx, entry)
        delete(path, idx.alloc)
    }
    delete(idx.files)
    delete(idx.root, idx.alloc)
    idx.files = nil
    idx.root = ""
    idx.built = false
}

// Per-workspace language-backend config, read from `<workspace>/.thor/` — the
// same workspace config folder Thor keeps its `settings.json` in. Thor's own
// file (not `ols.json`), though the shape — a `collections` array, `enable_*`
// toggles — is deliberately familiar.
@(private = "file")
WORKSPACE_CONFIG_DIR :: ".thor"
@(private = "file")
ANALYZER_CONFIG :: "odin-analyzer.json"

// Language-backend settings for one workspace, read from
// `<workspace>/.thor/odin-analyzer.json`. Only the settings the in-client engine
// can act on are kept: import collections (a name → its root directory, so `import
// "shared:foo"` resolves) and the feature-enable toggles. Absent keys take the
// defaults — no collections, every feature on.
@(private = "file")
Config :: struct {
    collections:             map[string]string, // name → resolved absolute dir
    enable_hover:            bool,
    enable_document_symbols: bool,
    enable_references:       bool,
    enable_rename:           bool,
}

// The engine's cached view of one workspace's config file, guarded by its own
// mutex and stat-invalidated exactly like the symbol index: the file is re-read only
// when the workspace changes or its modtime/size moves, so the common request
// pays a single `stat`, not a parse. A missing or malformed file still caches
// the defaults (so a miss isn't re-parsed every request). Owned strings use
// `alloc` (the engine allocator), never the per-request Manager allocator.
@(private = "file")
Config_Cache :: struct {
    mutex:     sync.Mutex,
    alloc:     runtime.Allocator,
    workspace: string, // engine-owned; the workspace this was loaded for
    loaded:    bool,
    modtime:   i64,
    size:      i64,
    cfg:       Config,
}

// Ensures the cache reflects `<workspace>/.thor/odin-analyzer.json` on disk. Rebuilds when the
// workspace changed or the file's stat moved; otherwise leaves the parsed view
// in place. All owned storage lands in the engine allocator (context set
// locally, so callees inherit it). Caller holds cache.mutex.
@(private = "file")
config_ensure :: proc(cache: ^Config_Cache, workspace: string) {
    if workspace == "" {
        return
    }
    context.allocator = cache.alloc // every clone/make below is engine-owned

    path, jerr := filepath.join({workspace, WORKSPACE_CONFIG_DIR, ANALYZER_CONFIG}, context.temp_allocator)
    if jerr != nil {
        return
    }
    present := false
    mt, sz: i64
    if info, err := os.stat(path, context.temp_allocator); err == nil {
        present = true
        mt = info.modification_time._nsec
        sz = info.size
    }

    if cache.loaded && cache.workspace == workspace && cache.modtime == mt && cache.size == sz {
        return // unchanged since last read — keep the parsed view
    }

    config_free(cache)
    cache.cfg = config_defaults()
    if cache.workspace != workspace {
        delete(cache.workspace, cache.alloc)
        cache.workspace = strings.clone(workspace)
    }
    cache.loaded = true
    cache.modtime = mt
    cache.size = sz

    if present {
        config_parse(cache, workspace, path)
    }
}

// A fresh Config with the defaults: no collections, every feature on. Uses
// context.allocator (the engine allocator, set by config_ensure).
@(private = "file")
config_defaults :: proc() -> Config {
    return Config {
        collections             = make(map[string]string),
        enable_hover            = true,
        enable_document_symbols = true,
        enable_references       = true,
        enable_rename           = true,
    }
}

// Parses the config file into `cache.cfg`, layering onto the defaults already in
// place: the recognized `enable_*` booleans and every `collections` entry (a
// relative path resolves against the workspace, an absolute one is used as-is).
// Unknown keys are ignored, so the file can carry settings this engine doesn't
// act on. context.allocator is the engine allocator (set by config_ensure).
@(private = "file")
config_parse :: proc(cache: ^Config_Cache, workspace, path: string) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return
    }
    value, perr := json.parse(data, allocator = context.temp_allocator)
    if perr != .None {
        return
    }
    obj, ook := value.(json.Object)
    if !ook {
        return
    }

    if b, ok := obj["enable_hover"].(json.Boolean); ok {
        cache.cfg.enable_hover = bool(b)
    }
    if b, ok := obj["enable_document_symbols"].(json.Boolean); ok {
        cache.cfg.enable_document_symbols = bool(b)
    }
    if b, ok := obj["enable_references"].(json.Boolean); ok {
        cache.cfg.enable_references = bool(b)
    }
    if b, ok := obj["enable_rename"].(json.Boolean); ok {
        cache.cfg.enable_rename = bool(b)
    }

    arr, aok := obj["collections"].(json.Array)
    if !aok {
        return
    }
    for item in arr {
        entry, eok := item.(json.Object)
        if !eok {
            continue
        }
        name, nok := entry["name"].(json.String)
        p, pok := entry["path"].(json.String)
        if !nok || !pok || name == "" || p == "" {
            continue
        }
        dir: string
        if filepath.is_abs(p) {
            dir = strings.clone(p)
        } else {
            joined, jerr := filepath.join({workspace, p})
            if jerr != nil {
                continue
            }
            dir = joined
        }
        // Last entry for a name wins (mirrors a map assignment); free the prior.
        if old, exists := cache.cfg.collections[name]; exists {
            delete(old, cache.alloc)
            cache.cfg.collections[name] = dir
        } else {
            cache.cfg.collections[strings.clone(name)] = dir
        }
    }
}

// Resolved root directory of the workspace-defined collection `coll`, or false
// when the config declares no such collection. The path is cloned into scratch
// so it outlives the lock.
@(private = "file")
config_collection_dir :: proc(e: ^Odin_Engine, coll, workspace: string) -> (string, bool) {
    if workspace == "" || coll == "" {
        return "", false
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    if dir, ok := cache.cfg.collections[coll]; ok {
        return strings.clone(dir, context.temp_allocator), true
    }
    return "", false
}

// True when the workspace config permits the feature the request `kind` serves.
// Kinds with no toggle (definition, workspace symbols, signature help,
// completion) are always on; the four gated ones — hover, document symbols,
// references, rename — honor the config, defaulting to on when unset.
@(private = "file")
config_allows :: proc(e: ^Odin_Engine, workspace: string, kind: Request_Kind) -> bool {
    #partial switch kind {
    case .Hover, .Document_Symbols, .References, .Rename:
    case:
        return true
    }
    if workspace == "" {
        return true // no workspace, no config to consult — defaults are all on
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    #partial switch kind {
    case .Hover:
        return cache.cfg.enable_hover
    case .Document_Symbols:
        return cache.cfg.enable_document_symbols
    case .References:
        return cache.cfg.enable_references
    case .Rename:
        return cache.cfg.enable_rename
    }
    return true
}

// Frees the cached config's owned collection strings and the map itself. Element
// deletes name the engine allocator explicitly (the map may be torn down from a
// context whose allocator differs, as in odin_destroy).
@(private = "file")
config_free :: proc(cache: ^Config_Cache) {
    for name, dir in cache.cfg.collections {
        delete(name, cache.alloc)
        delete(dir, cache.alloc)
    }
    delete(cache.cfg.collections)
    cache.cfg.collections = nil
}

// Tears the whole config cache down on destroy: its collections and the stored
// workspace path.
@(private = "file")
config_clear :: proc(e: ^Odin_Engine) {
    cache := &e.config
    config_free(cache)
    delete(cache.workspace, cache.alloc)
    cache.workspace = ""
    cache.loaded = false
}

// How many buffers keep a resident parse tree. One tree plus one copy of its
// source per slot; the working set is the open tabs.
@(private)
TREE_CACHE_SLOTS :: 8

// One buffer's last parse: the tree, the source it came from (the diff base —
// tree-sitter keeps no text of its own), and the LRU stamp.
@(private = "file")
Tree_Entry :: struct {
    path:   string, // engine-owned
    source: string, // engine-owned
    tree:   ts.Tree,
    used:   u64,
}

// Resident per-buffer trees, so a request re-parses only what the last edit
// touched. Owned strings use `alloc` (the engine's), never the per-request
// Manager allocator.
@(private = "file")
Tree_Cache :: struct {
    mutex:   sync.Mutex,
    entries: [dynamic]Tree_Entry,
    clock:   u64,
    alloc:   runtime.Allocator,
}

// The parse tree for `source`, reusing this path's resident tree: the cached
// source is diffed down to one changed span, `ts.tree_edit` applies it, and the
// old tree seeds the re-parse so tree-sitter rebuilds only the subtrees the edit
// invalidated. A path with no resident tree is parsed whole.
//
// Returns a shallow copy the caller must `tree_delete` — the entry keeps the
// original, and copies are what make a tree safe to read on this worker while
// another request re-parses the same buffer. The lock spans the parse, so
// concurrent requests on one buffer serialize; the waiter gets the fresh tree.
@(private)
tree_for_source :: proc(e: ^Odin_Engine, parser: ts.Parser, path, source: string) -> ts.Tree {
    cache := &e.trees
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)

    cache.clock += 1
    if i := tree_slot(cache, path); i >= 0 {
        entry := &cache.entries[i]
        entry.used = cache.clock
        if entry.source == source {
            return ts.tree_copy(entry.tree)
        }
        edit := source_edit(entry.source, source)
        ts.tree_edit(entry.tree, &edit)
        fresh := ts.parser_parse_string(parser, source, entry.tree)
        if fresh == nil {
            tree_evict(cache, i) // the tree carries the edit but no text to match it
            return nil
        }
        ts.tree_delete(entry.tree)
        delete(entry.source, cache.alloc)
        entry.tree = fresh
        entry.source = strings.clone(source, cache.alloc)
        return ts.tree_copy(fresh)
    }

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return nil
    }
    tree_store(cache, path, source, tree)
    return ts.tree_copy(tree)
}

// Index of `path`'s slot, or -1.
@(private = "file")
tree_slot :: proc(cache: ^Tree_Cache, path: string) -> int {
    for slot, i in cache.entries {
        if slot.path == path {
            return i
        }
    }
    return -1
}

// Adds `path`'s tree to the cache, retiring the least recently used slot when
// full. Takes ownership of `tree`.
@(private = "file")
tree_store :: proc(cache: ^Tree_Cache, path, source: string, tree: ts.Tree) {
    entry := Tree_Entry {
        path   = strings.clone(path, cache.alloc),
        source = strings.clone(source, cache.alloc),
        tree   = tree,
        used   = cache.clock,
    }
    if len(cache.entries) < TREE_CACHE_SLOTS {
        append(&cache.entries, entry)
        return
    }
    lru := 0
    for slot, i in cache.entries {
        if slot.used < cache.entries[lru].used {
            lru = i
        }
    }
    tree_free_entry(cache, cache.entries[lru])
    cache.entries[lru] = entry
}

@(private = "file")
tree_free_entry :: proc(cache: ^Tree_Cache, entry: Tree_Entry) {
    if entry.tree != nil {
        ts.tree_delete(entry.tree)
    }
    delete(entry.path, cache.alloc)
    delete(entry.source, cache.alloc)
}

@(private = "file")
tree_evict :: proc(cache: ^Tree_Cache, i: int) {
    tree_free_entry(cache, cache.entries[i])
    unordered_remove(&cache.entries, i)
}

// Frees every resident tree.
@(private = "file")
tree_cache_clear :: proc(e: ^Odin_Engine) {
    cache := &e.trees
    for entry in cache.entries {
        tree_free_entry(cache, entry)
    }
    delete(cache.entries)
    cache.entries = nil
}

// The one byte span that turns `old` into `new`, found by trimming the common
// prefix and suffix. A keystroke is a contiguous run, so this recovers it
// exactly; a wider change (multi-cursor, a reload) collapses into one span
// covering them all — still truthful, tree-sitter reuses whatever falls outside
// it. Both ends are pulled onto UTF-8 rune boundaries.
@(private)
source_edit :: proc(old, new: string) -> ts.Input_Edit {
    limit := min(len(old), len(new))

    prefix := 0
    for prefix < limit && old[prefix] == new[prefix] {
        prefix += 1
    }
    for prefix > 0 && prefix < len(new) && is_utf8_tail(new[prefix]) {
        prefix -= 1
    }

    // The suffix stops at the prefix in both strings, or the two would cross and
    // describe a negative-length edit.
    suffix := 0
    for suffix < limit - prefix && old[len(old) - 1 - suffix] == new[len(new) - 1 - suffix] {
        suffix += 1
    }
    old_end, new_end := len(old) - suffix, len(new) - suffix
    for old_end < len(old) && is_utf8_tail(old[old_end]) {
        old_end += 1
        new_end += 1
    }

    return ts.Input_Edit {
        start_byte    = u32(prefix),
        old_end_byte  = u32(old_end),
        new_end_byte  = u32(new_end),
        start_point   = byte_point(new, prefix), // a common prefix: the same in both
        old_end_point = byte_point(old, old_end),
        new_end_point = byte_point(new, new_end),
    }
}

// True for a UTF-8 continuation byte (10xxxxxx) — the middle of a rune.
@(private = "file")
is_utf8_tail :: proc(b: byte) -> bool {
    return b & 0xC0 == 0x80
}

// The tree-sitter Point (0-based row, byte column) at `offset`. Only the edit
// description needs these — resolution here is all raw byte offsets — but
// tree-sitter stores them on the nodes it shifts, so they have to be right.
@(private = "file")
byte_point :: proc(s: string, offset: int) -> ts.Point {
    row, line_start := 0, 0
    for i in 0 ..< offset {
        if s[i] == '\n' {
            row += 1
            line_start = i + 1
        }
    }
    return ts.Point{row = u32(row), col = u32(offset - line_start)}
}

// A declaration found in a parsed tree: the identifier being declared, the byte
// range of the scope it is visible in, and the enclosing declaration node used
// for hover text.
@(private = "file")
Def :: struct {
    name:         string, // slice into the parsed source
    ident_start:  int,
    ident_end:    int,
    kind:         string, // LOCALS capture suffix: "function", "type", "var", ...
    scope_start:  int,
    scope_end:    int,
    visible_from: int, // order-dependent local: first offset past its declaration
    top_level:    bool, // no enclosing block: visible across the whole file/package
    decl_start:   int,
    decl_end:     int,
}

@(private)
odin_resolve :: proc(data: rawptr, req: ^Request, res: ^Result) {
    e := cast(^Odin_Engine) data
    if e.locals == nil {
        return
    }
    // Superseded before the worker even got scheduled — common for the
    // per-keystroke kinds, where the thread often starts after the next edit.
    if request_cancelled(req) {
        return
    }

    // One parser per call (parsers are not shareable across threads); reused for
    // the request buffer and every workspace file the cross-file scan visits.
    parser := ts.parser_new()
    defer ts.parser_delete(parser)
    ts.parser_set_language(parser, e.language)

    // The request buffer is parsed incrementally off the resident tree for this
    // path (see tree_for_source); the workspace files the cross-file scans visit
    // are stat-gated instead and parsed whole.
    tree := tree_for_source(e, parser, req.path, req.source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)
    root := ts.tree_root_node(tree)

    // Respect the workspace's ols.json feature toggles: a disabled feature
    // answers nothing (hover / document symbols / references have OLS gates; the
    // other kinds are always on).
    if !config_allows(e, req.workspace, req.kind) {
        return
    }

    // Document symbols need no caret: enumerate the whole file and return.
    if req.kind == .Document_Symbols {
        collect_document_symbols(e, root, req.source, req.path, res)
        return
    }

    // Workspace symbols enumerate every top-level declaration across the tree,
    // starting from the live buffer (unsaved edits) then every sibling file.
    if req.kind == .Workspace_Symbols {
        collect_workspace_symbols(e, parser, root, req, res)
        return
    }

    // References need the identifier under the caret, but not the import/selector
    // resolution the goto flow runs — they gather every occurrence of the name.
    if req.kind == .References {
        collect_references(e, parser, root, req, res)
        return
    }

    // Rename reuses that same occurrence scan and turns each hit into an edit,
    // so it shares references' reach and its caret handling.
    if req.kind == .Rename {
        rename(e, parser, root, req, res)
        return
    }

    // Signature help works off the caret's position inside a call's argument
    // list, not an identifier under it, so it resolves the call before the
    // identifier/import goto logic below.
    if req.kind == .Signature_Help {
        signature_help(e, parser, root, req, res)
        return
    }

    // Completion works off the partial word before the caret (which may not yet
    // parse to an identifier), so it runs before the identifier/import goto logic.
    if req.kind == .Completion {
        complete(e, parser, root, req, res)
        return
    }

    // Package docs render a whole package, resolved from the caret (an import,
    // a `pkg.Symbol` operand, a bare package name) or, failing that, the file's
    // own package. Its own resolution, so it runs before the goto logic below.
    if req.kind == .Package_Doc {
        package_doc(e, parser, root, req, res)
        return
    }

    // Caret on an import declaration itself (its alias or its quoted path):
    // resolve to the imported package. Handled before identifier_at because the
    // path string is not an identifier, so a caret resting on it would otherwise
    // fail outright.
    if imp, in_import := enclosing_import(root, req.source, req.offset); in_import {
        if raw, rok := import_string(imp, req.source); rok {
            if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                anchor_start := int(ts.node_start_byte(imp))
                anchor_end := int(ts.node_end_byte(imp))
                open_package(dir, raw, req, res, anchor_start, anchor_end)
            }
        }
        return
    }

    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    name := ts.node_text(ident, req.source)
    hover_start := int(ts.node_start_byte(ident))
    hover_end := int(ts.node_end_byte(ident))

    // 0) Selector `operand.member`. Two resolutions, in order:
    //    a) Package-qualified `pkg.Symbol`: when the operand names an imported
    //       package, the symbol lives in that package's directory, so resolve
    //       there and never fall through to the flat scan (which ignores package
    //       boundaries and could match a same-named symbol elsewhere).
    //    b) Value member `value.field`: infer the operand's static type and
    //       resolve the field in that struct (see resolve_member).
    if op_node, member_ident, is_sel := selector_parts(ident); is_sel {
        caret_on_member := same_node(ident, member_ident)
        if is_identifier(op_node) {
            pkg := ts.node_text(op_node, req.source)
            if raw, found := import_path(root, req.source, pkg); found {
                if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                    if caret_on_member {
                        scan_package(e, parser, dir, req, name, hover_start, hover_end, res)
                    } else {
                        open_package(dir, raw, req, res, hover_start, hover_end)
                    }
                }
                return
            }
        }
        // Value member access, only with the caret on the member. Falls through
        // to the flat scan when the type can't be inferred (no struct in reach).
        if caret_on_member && resolve_member(e, parser, root, req, op_node, name, hover_start, hover_end, res) {
            return
        }
    }

    // 1) Same file: lexical resolution via the LOCALS query.
    defs := collect_defs(e, root, req.source)
    if d, found := resolve_local(defs[:], name, req.offset); found {
        fill_result(res, req, req.path, req.source, d, hover_start, hover_end)
        return
    }

    // 2) Workspace: scan sibling files for a matching top-level declaration.
    //    Hover wants the first hit; go-to-definition gathers every match so an
    //    ambiguous name (declared in several packages) offers a picker.
    if req.workspace != "" {
        if req.kind == .Definition {
            resolve_definition_workspace(e, parser, req, name, res)
        } else {
            scan_workspace(e, parser, req, name, hover_start, hover_end, res)
        }
    }
}

// Smallest identifier node covering `offset`, also probing offset-1 so a caret
// resting just after an identifier still resolves it.
@(private = "file")
identifier_at :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    if n := ts.node_named_descendant_for_byte_range(root, off, off); is_identifier(n) {
        return n, true
    }
    if offset > 0 {
        p := off - 1
        if n := ts.node_named_descendant_for_byte_range(root, p, p); is_identifier(n) {
            return n, true
        }
    }
    return {}, false
}

// Nearest import_declaration enclosing `offset`, so a caret anywhere on an
// import line (its alias identifier or its quoted path) resolves to the package.
@(private = "file")
enclosing_import :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    n := ts.node_named_descendant_for_byte_range(root, off, off)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == "import_declaration" {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

@(private = "file")
is_identifier :: proc(n: ts.Node) -> bool {
    return !ts.node_is_null(n) && string(ts.node_type(n)) == "identifier"
}

// Runs the LOCALS query over `root` and records every @definition.* capture with
// the scope it is visible in.
@(private = "file")
collect_defs :: proc(e: ^Odin_Engine, root: ts.Node, source: string) -> [dynamic]Def {
    defs := make([dynamic]Def, context.temp_allocator)

    cursor := ts.query_cursor_new()
    defer ts.query_cursor_delete(cursor)
    ts.query_cursor_exec(cursor, e.locals, root)

    for match in ts.query_cursor_next_match(cursor) {
        for i in 0 ..< int(match.capture_count) {
            c := match.captures[i]
            cname := ts.query_capture_name_for_id(e.locals, c.index)
            if !strings.has_prefix(cname, "definition") {
                continue
            }

            ident := c.node
            d: Def
            d.name = ts.node_text(ident, source)
            d.ident_start = int(ts.node_start_byte(ident))
            d.ident_end = int(ts.node_end_byte(ident))
            d.kind = strings.has_prefix(cname, "definition.") ? cname[len("definition."):] : ""
            d.scope_start = 0
            d.scope_end = len(source)

            // Scope: a parameter is visible in its whole procedure; anything
            // else in its enclosing block or control-flow statement, and when it
            // has neither it is top-level and visible file-wide (procs, structs,
            // enums, package-level consts).
            if d.kind == "parameter" {
                if pd, has := ancestor_type(ident, "procedure_declaration"); has {
                    d.scope_start = int(ts.node_start_byte(pd))
                    d.scope_end = int(ts.node_end_byte(pd))
                } else {
                    d.top_level = true
                }
            } else {
                scope_def(&d, ident)
            }

            if decl, has := ancestor_suffix(ident, "_declaration"); has {
                d.decl_start = int(ts.node_start_byte(decl))
                d.decl_end = int(ts.node_end_byte(decl))
            } else {
                d.decl_start = d.ident_start
                d.decl_end = d.ident_end
            }

            // A local variable is the one order-dependent capture: `::` consts,
            // types and procedures are visible throughout their scope, a `:=`
            // only past its own declaration.
            if d.kind == "var" && !d.top_level {
                d.visible_from = d.decl_end
            }

            append(&defs, d)
        }
    }

    // The vendored LOCALS query captures none of the value declarations this
    // grammar actually produces, so they are collected directly.
    collect_value_decls(root, source, &defs)
    return defs
}

// The scope a declaration at `node` lives in: the nearest enclosing block, or
// the control-flow statement itself when the declaration is one of its clauses
// (`if v, ok := m[k]; ok`, `for i := 0; i < n; i += 1`) — those bindings die
// with the statement instead of leaking into the surrounding block.
@(private = "file")
enclosing_scope :: proc(node: ts.Node) -> (ts.Node, bool) {
    n := ts.node_parent(node)
    for !ts.node_is_null(n) {
        switch string(ts.node_type(n)) {
        case "block", "if_statement", "for_statement", "switch_statement", "when_statement":
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Fills `d`'s visible range from the scope enclosing `node`, marking it
// top-level when there is none.
@(private = "file")
scope_def :: proc(d: ^Def, node: ts.Node) {
    if scope, has := enclosing_scope(node); has {
        d.scope_start = int(ts.node_start_byte(scope))
        d.scope_end = int(ts.node_end_byte(scope))
    } else {
        d.top_level = true
    }
}

// Adds the value declarations the LOCALS query misses: `name := value` short
// declarations (this grammar parses them as an `assignment_statement`, not the
// `variable_declaration` the query looks for), typed `name: T = value`
// declarations, and `for name in expr` loop variables.
@(private = "file")
collect_value_decls :: proc(node: ts.Node, source: string, defs: ^[dynamic]Def) {
    switch string(ts.node_type(node)) {
    case "assignment_statement":
        // Walk the leading children: identifiers (and commas for `a, b := ...`)
        // up to the operator. A `:=` there makes those identifiers definitions;
        // a plain `=` reassignment declares nothing.
        lead := make([dynamic]ts.Node, context.temp_allocator)
        is_decl := false
        scan: for i in 0 ..< ts.node_child_count(node) {
            c := ts.node_child(node, i)
            switch string(ts.node_type(c)) {
            case "identifier":
                append(&lead, c)
                continue
            case ",":
                continue
            case ":=":
                is_decl = true
            }
            break scan
        }
        if is_decl {
            for ident in lead {
                append_value_def(defs, ident, node, source, ordered = true)
            }
        }
    case "var_declaration":
        // `a, b: T = x, y` — the names precede the `(type ...)` child, mirroring
        // named_decl_type. A file-scope one is a package variable, which is
        // order-independent and shows up in the symbol list.
        for i in 0 ..< ts.node_named_child_count(node) {
            c := ts.node_named_child(node, i)
            if !is_identifier(c) {
                break // the type: everything past it is the initializer
            }
            append_value_def(defs, c, node, source, ordered = true)
        }
    case "for_statement":
        // A range loop's variables (`for k, v in m`) are bare identifier
        // children before `in`; the three-clause form has an initializer
        // statement there instead, which the assignment_statement case covers.
        for i in 0 ..< ts.node_child_count(node) {
            c := ts.node_child(node, i)
            if string(ts.node_type(c)) == "in" {
                break
            }
            if is_identifier(c) {
                append_value_def(defs, c, node, source, ordered = false)
            }
        }
    }

    for i in 0 ..< ts.node_child_count(node) {
        collect_value_decls(ts.node_child(node, i), source, defs)
    }
}

// Records `ident` as a variable declared by `decl`. An `ordered` declaration is
// order-dependent — visible only past the declaration it sits in, so a use
// above it still binds whatever it shadows — while a loop variable is seen by
// its whole loop.
@(private = "file")
append_value_def :: proc(defs: ^[dynamic]Def, ident, decl: ts.Node, source: string, ordered: bool) {
    d := Def {
        name        = ts.node_text(ident, source),
        ident_start = int(ts.node_start_byte(ident)),
        ident_end   = int(ts.node_end_byte(ident)),
        kind        = "var",
        decl_start  = int(ts.node_start_byte(decl)),
        decl_end    = int(ts.node_end_byte(decl)),
    }
    scope_def(&d, ident)
    if ordered && !d.top_level {
        d.visible_from = d.decl_end
    }
    append(defs, d)
}

// Whether `d` can be named at `offset`: a file-scope declaration anywhere in the
// file, a local only inside its scope and — when order-dependent — only past its
// own declaration. Its declaring identifier always qualifies, so go-to-definition
// and find-usages on the declaration itself still find it.
@(private = "file")
def_visible_at :: proc(d: Def, offset: int) -> bool {
    if d.top_level {
        return true
    }
    if offset < d.scope_start || offset > d.scope_end {
        return false
    }
    return offset >= d.visible_from || (offset >= d.ident_start && offset <= d.ident_end)
}

// Picks the visible declaration of `name` nearest `offset`: a local shadows a
// file-scope symbol, an inner block shadows an outer, and the last declaration
// before the use shadows the ones above it.
@(private = "file")
resolve_local :: proc(defs: []Def, name: string, offset: int) -> (Def, bool) {
    best: Def
    found := false
    for d in defs {
        if d.name != name || !def_visible_at(d, offset) {
            continue
        }
        if !found || def_better(d, best, offset) {
            best = d
            found = true
        }
    }
    return best, found
}

@(private = "file")
def_better :: proc(a, b: Def, offset: int) -> bool {
    // The caret on a declared name resolves to that very declaration.
    a_self := offset >= a.ident_start && offset <= a.ident_end
    if a_self != (offset >= b.ident_start && offset <= b.ident_end) {
        return a_self
    }
    if a.top_level != b.top_level {
        return !a.top_level // a local shadows a file-scope symbol
    }
    if !a.top_level {
        aw := a.scope_end - a.scope_start
        bw := b.scope_end - b.scope_start
        if aw != bw {
            return aw < bw // the tighter (inner) scope wins
        }
        if a.visible_from != b.visible_from {
            return a.visible_from > b.visible_from // within a scope, the latest one
        }
    }
    return abs(a.ident_start - offset) < abs(b.ident_start - offset)
}

// Finds the workspace file declaring `name` via the symbol index, then re-parses
// just that one file to fill `res` (hover wants the full declaration text, which
// the index doesn't keep). The live buffer (req.path) was already searched with
// its unsaved edits, so it is excluded. Syncs the index under its mutex first.
@(private = "file")
scan_workspace :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    req: ^Request,
    name: string,
    hover_start, hover_end: int,
    res: ^Result,
) {
    path, ok := "", false
    sync.lock(&e.index.mutex)
    index_sync(e, parser, req)
    if p, found := index_first_path(e, name, req.path, ""); found {
        path = strings.clone(p, context.temp_allocator) // survives the unlock
        ok = true
    }
    sync.unlock(&e.index.mutex)

    if ok {
        scan_file(e, parser, path, req, name, hover_start, hover_end, res)
    }
}

@(private = "file")
scan_file :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    path: string,
    req: ^Request,
    name: string,
    hover_start, hover_end: int,
    res: ^Result,
) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return
    }
    source := string(data)

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)

    defs := collect_defs(e, ts.tree_root_node(tree), source)
    for d in defs {
        if d.top_level && d.name == name {
            fill_result(res, req, path, source, d, hover_start, hover_end)
            return
        }
    }
}

// Go-to-definition's cross-file scan. Gathers every workspace file's top-level
// declaration named `name` into res.symbols; unlike scan_workspace (first hit
// wins, used by hover) it never stops early, because the flat cross-file match
// ignores package boundaries — the same name can be declared in several
// packages and the user should choose. A single hit collapses back to
// res.location (the direct-jump path the caller already handles); two or more
// stay as candidates for a picker.
@(private = "file")
resolve_definition_workspace :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    req: ^Request,
    name: string,
    res: ^Result,
) {
    sync.lock(&e.index.mutex)
    index_sync(e, parser, req)
    index_find_defs(e, name, req.path, res)
    sync.unlock(&e.index.mutex)
    switch len(res.symbols) {
    case 0:
        // Unresolved: res.ok stays false so the caller reports "no definition".
    case 1:
        // Single definition: collapse to the location a direct jump uses, moving
        // the (Manager-owned) path into it and freeing the row's other strings.
        sym := res.symbols[0]
        res.location = Location{path = sym.path, start = sym.offset, end = sym.offset + len(sym.name)}
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(res.symbols)
        res.symbols = nil
        res.ok = true
    case:
        // Ambiguous: leave the candidates in res.symbols for the picker.
        res.ok = true
    }
}

// Appends `source`'s top-level declarations (in `path`) to res.symbols. Reuses
// collect_defs — the same walk go-to-definition uses — and keeps only the
// file-scope symbols a symbol list should show (procedures, types, enums,
// constants and package-level vars), dropping parameters, struct fields, labels
// and the package/import namespace captures. Each field is cloned into
// context.allocator (the Manager's), freed on the main thread after the editor
// reads them; the signature is the real Odin declaration line.
@(private = "file")
collect_symbols_into :: proc(e: ^Odin_Engine, root: ts.Node, source, path: string, res: ^Result) {
    defs := collect_defs(e, root, source)
    for d in defs {
        if !d.top_level || !symbol_kind_shown(d.kind) {
            continue
        }
        ident_start := clamp(d.ident_start, 0, len(source))
        append(&res.symbols, Symbol {
            name      = strings.clone(d.name),
            kind      = strings.clone(d.kind),
            signature = signature_text(source, d),
            path      = strings.clone(path),
            line      = strings.count(source[:ident_start], "\n") + 1,
            offset    = d.ident_start,
        })
    }
}

// Fills `res` with one file's top-level declarations for a document outline,
// sorted by position for a stable outline.
@(private = "file")
collect_document_symbols :: proc(e: ^Odin_Engine, root: ts.Node, source, path: string, res: ^Result) {
    collect_symbols_into(e, root, source, path, res)
    slice.sort_by(res.symbols[:], proc(a, b: Symbol) -> bool {
        return a.offset < b.offset
    })
    res.ok = true
}

// Fills `res` with every top-level declaration across the workspace: the live
// buffer first (so unsaved edits win over its on-disk copy, which is skipped),
// then every other file straight from the symbol index (no re-parse of unchanged
// files). Sorted by name (ties by path) for a stable, fuzzy-searchable list.
@(private = "file")
collect_workspace_symbols :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    if req.path != "" {
        collect_symbols_into(e, root, req.source, req.path, res)
    }
    if req.workspace != "" {
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        index_all_symbols(e, req.path, res)
        sync.unlock(&e.index.mutex)
    }
    slice.sort_by(res.symbols[:], proc(a, b: Symbol) -> bool {
        if a.name != b.name {
            return a.name < b.name
        }
        return a.path < b.path
    })
    res.ok = true
}

// Gathers every occurrence of the identifier under the caret ("find usages").
// The kind of match is chosen by resolution: a name that binds to a local or a
// parameter is confined to that declaration's scope in this one file (so an `x`
// in one procedure never lists an unrelated `x` in another); anything else —
// top-level, or a name that doesn't resolve locally — is matched by name across
// the whole workspace, mirroring how cross-file goto flat-matches top-level
// names (no package/type awareness yet, so this is textual-but-AST-aware). Each
// occurrence becomes a Symbol carrying its file, line, offset and the source
// line it sits on for a code-context preview.
@(private = "file")
collect_references :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    name := ts.node_text(ident, req.source)

    defs := collect_defs(e, root, req.source)
    if d, found := resolve_local(defs[:], name, req.offset); found && !d.top_level {
        // Local / parameter: only its own scope in this file, and for an
        // order-dependent local only from its declaration on — an earlier use in
        // the same block names whatever this one shadows.
        start := d.visible_from > 0 ? d.ident_start : d.scope_start
        collect_ident_refs(root, req.source, name, req.path, start, d.scope_end, res)
    } else {
        // Top-level or unresolved: this whole buffer, then every workspace file
        // the index says mentions the name (the rest can't contain a usage).
        collect_ident_refs(root, req.source, name, req.path, 0, len(req.source), res)
        if req.workspace != "" {
            paths := make([dynamic]string, context.temp_allocator)
            sync.lock(&e.index.mutex)
            index_sync(e, parser, req)
            index_ref_files(e, name, req.path, &paths)
            sync.unlock(&e.index.mutex)
            for path in paths {
                if request_cancelled(req) {
                    return
                }
                ref_scan_file(e, parser, path, name, res)
            }
        }
    }

    slice.sort_by(res.symbols[:], proc(a, b: Symbol) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    res.ok = len(res.symbols) > 0
}

// Appends every `identifier` node in `node`'s subtree whose text equals `name`
// and whose span falls within [within_start, within_end) to res.symbols. Each is
// a reference Symbol: the source line it sits on is the preview, path/line/offset
// the jump target. Owned strings use context.allocator (the Manager's).
@(private = "file")
collect_ident_refs :: proc(node: ts.Node, source, name, path: string, within_start, within_end: int, res: ^Result) {
    if is_identifier(node) {
        s := int(ts.node_start_byte(node))
        end := int(ts.node_end_byte(node))
        if s >= within_start && end <= within_end && ts.node_text(node, source) == name {
            append(&res.symbols, Symbol {
                name      = strings.clone(name),
                kind      = strings.clone("reference"),
                signature = source_line(source, s),
                path      = strings.clone(path),
                line      = strings.count(source[:clamp(s, 0, len(source))], "\n") + 1,
                offset    = s,
            })
        }
    }
    for i in 0 ..< ts.node_child_count(node) {
        collect_ident_refs(ts.node_child(node, i), source, name, path, within_start, within_end, res)
    }
}

// The whole source line `offset` falls on, trimmed — a reference row's code
// preview. Cloned into context.allocator.
@(private = "file")
source_line :: proc(source: string, offset: int) -> string {
    lo := clamp(offset, 0, len(source))
    start := strings.last_index_byte(source[:lo], '\n') + 1 // -1 + 1 == 0 for the first line
    end := len(source)
    if nl := strings.index_byte(source[lo:], '\n'); nl >= 0 {
        end = lo + nl
    }
    return strings.clone(strings.trim_space(source[start:end]))
}

// Re-parses one workspace file and appends its occurrences of `name` to `res`.
// Called only for files the index flagged as mentioning the name.
@(private = "file")
ref_scan_file :: proc(e: ^Odin_Engine, parser: ts.Parser, path, name: string, res: ^Result) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return
    }
    source := string(data)

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)

    collect_ident_refs(ts.tree_root_node(tree), source, name, path, 0, len(source), res)
}

// Renames the symbol under the caret to `req.new_name`, returning the
// replacements as `res.edits` rather than touching any file — the editor applies
// them, so the change lands in an open buffer's undo history instead of behind
// its back. Every occurrence find-references would list becomes one edit, so
// rename inherits that reach *and* its imprecision: a local or parameter is
// confined to its declaration's scope in this file, but a top-level name is
// matched across the workspace, and until the type layer lands an unrelated
// same-named symbol in another package is renamed with it. Answers nothing when
// the caret is not on an identifier or the new name isn't a legal Odin one.
@(private = "file")
rename :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    if !valid_identifier(req.new_name) {
        return
    }
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    name := ts.node_text(ident, req.source)
    if name == req.new_name {
        return // renaming to itself: no edits, nothing to apply
    }

    collect_references(e, parser, root, req, res)
    if !res.ok {
        return
    }

    // The reference rows are consumed here: each one's span becomes an edit and
    // its `path` moves into that edit, so a rename result carries edits alone
    // and the display-only fields are freed rather than handed to the editor.
    for sym in res.symbols {
        append(&res.edits, Text_Edit {
            path     = sym.path,
            start    = sym.offset,
            end      = sym.offset + len(name),
            old_text = strings.clone(name),
            new_text = strings.clone(req.new_name),
        })
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
    }
    delete(res.symbols)
    res.symbols = nil // handed over to `edits`; job_free must not free it twice
    res.ok = len(res.edits) > 0
}

// True when `s` can be written as an Odin identifier: a leading letter or `_`,
// then letters, digits and `_`, and not a keyword or builtin type name.
@(private = "file")
valid_identifier :: proc(s: string) -> bool {
    if s == "" || (s[0] >= '0' && s[0] <= '9') {
        return false
    }
    for i in 0 ..< len(s) {
        if !is_word_byte(s[i]) {
            return false
        }
    }
    for kw in ODIN_KEYWORDS {
        if s == kw {
            return false
        }
    }
    return true
}

// Resolves the call the caret sits inside to its procedure declaration and fills
// `res.signature` with that proc's signature line plus the byte range, within
// the line, of the parameter the caret is currently on. The call's function is
// resolved the same three ways goto is — same-file, package-qualified
// (`pkg.fn(...)`) and cross-file workspace scan — so signature help follows the
// same reach. Only procedures produce a result; a call of a non-proc is ignored.
@(private = "file")
signature_help :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    call, ok := enclosing_call(root, req.source, req.offset)
    if !ok {
        return
    }
    fn := ts.node_child_by_field_name(call, "function")
    if ts.node_is_null(fn) {
        return
    }

    src, _, d, found := resolve_call_target(e, parser, root, req, call, fn)
    if !found || d.kind != "function" {
        return
    }

    label := signature_text(src, d) // cloned into context.allocator (the Manager's)
    active := call_active_param(call, req.offset)
    astart, aend := active_param_span(label, active)
    res.signature = Signature_Info {
        label        = label,
        active_start = astart,
        active_end   = aend,
    }
    res.ok = true
}

// Nearest call_expression enclosing `offset`, so a caret anywhere inside a call's
// argument list (including the whitespace between arguments) resolves to that
// call. The innermost call wins, so `outer(inner(|))` picks `inner`.
@(private = "file")
enclosing_call :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    n := ts.node_named_descendant_for_byte_range(root, off, off)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == "call_expression" {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Index of the argument the caret is on: the count of top-level commas in the
// call's parentheses before `offset`. Commas are direct `,` children of the
// call_expression, so a nested call's commas (buried in an argument subtree)
// never leak in. A caret before the first `(` (e.g. on the function name) is 0.
@(private = "file")
call_active_param :: proc(call: ts.Node, offset: int) -> int {
    active := 0
    seen_open := false
    for i in 0 ..< ts.node_child_count(call) {
        c := ts.node_child(call, i)
        switch string(ts.node_type(c)) {
        case "(":
            seen_open = true
        case ")":
            return active
        case ",":
            if seen_open && int(ts.node_start_byte(c)) < offset {
                active += 1
            } else if seen_open {
                return active
            }
        }
    }
    return active
}

// Resolves a call's function operand to its procedure declaration, returning the
// source it lives in and the Def within it. Handles `pkg.fn(...)` (the call node
// nests under a member_expression carrying the package operand) by following the
// import into that package's directory; otherwise the bare function name is
// resolved same-file first, then across the workspace. The returned source is the
// worker's temp-allocated file text (job-lifetime), so the Def's slices stay
// valid after the parse tree is freed.
@(private = "file")
resolve_call_target :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    call, fn: ts.Node,
) -> (source: string, path: string, d: Def, ok: bool) {
    // `pkg.fn(args)`: the call is the second child of a member_expression whose
    // first child is the package operand. Resolve `fn` in that package's dir.
    if parent := ts.node_parent(call); !ts.node_is_null(parent) &&
        string(ts.node_type(parent)) == "member_expression" {
        pkg_node := ts.node_named_child(parent, 0)
        if same_node(ts.node_named_child(parent, 1), call) && is_identifier(pkg_node) && is_identifier(fn) {
            pkg := ts.node_text(pkg_node, req.source)
            name := ts.node_text(fn, req.source)
            if raw, ok := import_path(root, req.source, pkg); ok {
                if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                    return find_proc_in_dir(e, parser, dir, name, req.path)
                }
            }
            return "", "", {}, false
        }
    }

    if !is_identifier(fn) {
        return "", "", {}, false
    }
    name := ts.node_text(fn, req.source)

    // Same file: a top-level procedure of this name (locals of the same name are
    // not callables we can sign, so require the "function" kind).
    defs := collect_defs(e, root, req.source)
    if d, ok := resolve_local(defs[:], name, int(ts.node_start_byte(fn))); ok && d.kind == "function" {
        return req.source, req.path, d, true
    }

    // Workspace: the index points at the file declaring the procedure; re-parse
    // just that one for its Def (the caller needs the live source and decl range).
    if req.workspace != "" {
        path, ok := "", false
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        if p, found := index_first_path(e, name, req.path, "function"); found {
            path = strings.clone(p, context.temp_allocator)
            ok = true
        }
        sync.unlock(&e.index.mutex)
        if ok {
            return first_proc_in_file(e, parser, path, name)
        }
    }
    return "", "", {}, false
}

// First top-level procedure named `name` in `path`, with the file's source and
// path (so the Def stays valid past the parse, and a type its signature names
// keeps a file whose imports qualify it). Reused by the package and workspace
// scans.
@(private = "file")
first_proc_in_file :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    path, name: string,
) -> (source: string, file: string, d: Def, ok: bool) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return "", "", {}, false
    }
    src := string(data)

    tree := ts.parser_parse_string(parser, src)
    if tree == nil {
        return "", "", {}, false
    }
    defer ts.tree_delete(tree)

    defs := collect_defs(e, ts.tree_root_node(tree), src)
    for def in defs {
        if def.top_level && def.kind == "function" && def.name == name {
            return src, path, def, true
        }
    }
    return "", "", {}, false
}

// First top-level procedure named `name` in one package directory (all its .odin
// files, non-recursively — an Odin package is a flat directory). `skip` is the
// requesting file's path, left out so the live buffer's stale on-disk copy loses.
@(private = "file")
find_proc_in_dir :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    dir, name, skip: string,
) -> (source: string, path: string, d: Def, ok: bool) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return "", "", {}, false
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return "", "", {}, false
    }

    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == skip {
            continue
        }
        if src, file, def, found := first_proc_in_file(e, parser, info.fullpath, name); found {
            return src, file, def, found
        }
    }
    return "", "", {}, false
}


// ---------------------------------------------------------------------------
// Type-aware member access (`value.field`).
//
// The engine has no general type system, but the most common selector — a field
// of a struct-typed value — is resolvable with a narrow, name-based inference:
// find the operand's declaration, read its struct type, locate that struct (same
// file, an imported package, or the workspace index) and match the field. The
// type comes from a written-down declaration (`p: Point`, a parameter) or, for a
// `:=` binding, from its initializer — a composite literal, an aliased value, or
// the declared result type of the procedure it calls (`p := make_point()`, which
// resolves the callee the same three ways signature help does). Chained access
// (`a.b.c`) recurses through each struct's field type, and a pointer type is
// transparently dereferenced (Odin auto-derefs `.`). A struct embedded with
// `using` answers for its fields as if they were the outer struct's own, and a
// container (`[]T`, `[N]T`, `[dynamic]T`, `map[K]V`) resolves to its element once
// it is indexed, sliced or ranged over — never before, since a container is not
// the type it holds. Anything else (a union, a bit_set, a builtin) doesn't
// resolve, and the caller falls back to the flat name scan.
// ---------------------------------------------------------------------------

// What a type holds when it is not the named type itself: `[]Point`, `[4]Point`
// and `[dynamic]Point` are arrays of it, `map[string]Point` maps to it. Element
// access (`xs[i]`) and a range loop (`for p in xs`) strip one level off.
@(private = "file")
Container :: enum {
    None,
    Array,
    Map,
}

// A named type reference: the type name plus an optional package qualifier
// (`pkg` in `p: pkg.Point`), the container that holds it (the name is then the
// *element* type — a map's value), and the file the reference was read from, so
// a qualifier written in another file resolves against *that* file's imports.
// Strings slice the source they were read from unless explicitly cloned, so a
// Type_Ref that must outlive a parse is temp-cloned.
@(private = "file")
Type_Ref :: struct {
    name:      string,
    pkg:       string,
    container: Container,
    origin:    string,
}

// A value binding's declared type and the scope it is visible in, so the nearest
// visible declaration of a name can be chosen (mirroring resolve_local). A `:=`
// binding writes no type down, so it carries its initializer expression instead
// (`expr`) and the type is inferred on demand; `result_index` is the slot this
// name takes in a multi-value call (`v, ok := f()`).
@(private = "file")
Binding :: struct {
    tr:           Type_Ref,
    expr:         ts.Node, // valid when has_expr: the `:=` right-hand side
    has_expr:     bool,
    is_range:     bool, // `expr` is a `for x in expr` operand: bind its element
    result_index: int,
    scope_start:  int,
    scope_end:    int,
    visible_from: int, // order-dependent binding: first offset past its declaration
    top_level:    bool,
    pos:          int,
}

// How far the inference recursion may go. Field chains, aliased bindings and call
// results all recurse, and a self-referential declaration (`x := x`, or two
// bindings naming each other) would otherwise never bottom out.
@(private = "file")
INFER_DEPTH_LIMIT :: 8

// Resolves `value.field`: infers the operand's struct type, finds that struct and
// its field, and fills the go-to-definition location or hover text. Returns
// whether it resolved (false when the operand's type isn't an in-reach struct, so
// the caller can fall through). `operand` is the expression left of the dot — a
// bare identifier or a nested `a.b` member access.
@(private = "file")
resolve_member :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    operand: ts.Node,
    field: string,
    hover_start, hover_end: int,
    res: ^Result,
) -> bool {
    tr, ok := infer_expr_type(e, parser, root, req, operand)
    if !ok {
        return false
    }
    ctx := Member_Ctx {
        field = field,
        env = Embed_Env{e = e, parser = parser, root = root, req = req},
    }
    if !visit_type_decl(e, parser, root, req, tr, "struct_declaration", "type", member_visitor, &ctx) || !ctx.got {
        return false
    }
    #partial switch req.kind {
    case .Definition:
        res.location = Location {
            path  = strings.clone(ctx.path),
            start = ctx.ident_start,
            end   = ctx.ident_end,
        }
        res.ok = true
    case .Hover:
        res.hover = Hover_Info {
            text  = declaration_text_range(ctx.src, ctx.decl_start, ctx.decl_end),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
    return res.ok
}

// Static type of an expression node, for member access. A bare identifier resolves
// through its value binding, a nested `a.b` recurses (type of `a`, then the type of
// its `b` field), a composite literal names its own type, and a call resolves to
// its procedure's result type. Anything else is not inferred.
@(private = "file")
infer_expr_type :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    node: ts.Node,
    depth := 0,
) -> (Type_Ref, bool) {
    return infer_expr_result(e, parser, root, req, node, 0, depth)
}

// infer_expr_type with a result slot: `index` picks one type out of a call's
// multi-value return (`v, ok := f()` binds `ok` to slot 1). Every other expression
// shape has a single type, so the index is ignored there.
@(private = "file")
infer_expr_result :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    node: ts.Node,
    index, depth: int,
) -> (Type_Ref, bool) {
    if depth > INFER_DEPTH_LIMIT || ts.node_is_null(node) {
        return {}, false
    }
    if is_identifier(node) {
        name := ts.node_text(node, req.source)
        return binding_type_ref(e, parser, root, req, name, int(ts.node_start_byte(node)), depth + 1)
    }
    switch string(ts.node_type(node)) {
    case "member_expression":
        op := ts.node_named_child(node, 0)
        member := ts.node_named_child(node, 1)
        if ts.node_is_null(op) || ts.node_is_null(member) {
            return {}, false
        }
        // `pkg.fn(...)`: the grammar nests the call under the member expression, so
        // the call — which resolves the package itself — is what has the type.
        if string(ts.node_type(member)) == "call_expression" {
            return call_result_type(e, parser, root, req, member, index, depth + 1)
        }
        if !is_identifier(member) {
            return {}, false
        }
        inner, ok := infer_expr_result(e, parser, root, req, op, 0, depth + 1)
        if !ok {
            return {}, false
        }
        ctx := Member_Ctx {
            field = ts.node_text(member, req.source),
            env = Embed_Env{e = e, parser = parser, root = root, req = req},
        }
        if !visit_type_decl(e, parser, root, req, inner, "struct_declaration", "type", member_visitor, &ctx) || !ctx.got {
            return {}, false
        }
        return ctx.field_type, true
    case "struct":
        // A composite literal (`Point{...}`, `[]Point{...}`) names the type it
        // builds. The grammar drops a container literal's brackets from the named
        // children, so the type is read off the text before the brace.
        return composite_type_name(node, req.source)
    case "call_expression":
        return call_result_type(e, parser, root, req, node, index, depth + 1)
    case "index_expression":
        // `xs[i]` is one element of its container.
        op, ok := infer_expr_result(e, parser, root, req, ts.node_named_child(node, 0), 0, depth + 1)
        if !ok || op.container == .None {
            return {}, false
        }
        op.container = .None
        return op, true
    case "slice_expression":
        // `xs[1:3]` is another container of the same element type.
        op, ok := infer_expr_result(e, parser, root, req, ts.node_named_child(node, 0), 0, depth + 1)
        if !ok || op.container != .Array {
            return {}, false
        }
        return op, true
    case "unary_expression":
        // `&xs[0]` — `.` dereferences, so the pointer is transparent.
        return infer_expr_result(e, parser, root, req, ts.node_named_child(node, 0), index, depth + 1)
    }
    return {}, false
}

// The type a composite literal builds, read from its text up to the opening brace
// (`Point`, `pkg.Point`, `[]Point`, `map[string]Point`) — the grammar keeps a
// container literal's `[]` as anonymous tokens, so the named children alone can't
// tell `[]Point{}` from `Point{}`.
@(private = "file")
composite_type_name :: proc(node: ts.Node, source: string) -> (Type_Ref, bool) {
    text := ts.node_text(node, source)
    if brace := strings.index_byte(text, '{'); brace >= 0 {
        text = text[:brace]
    }
    return result_type_ref(strings.trim_space(text))
}

// Type of the value named `name` visible at `offset`: the nearest enclosing
// binding — a parameter, a typed `var` declaration, or a `:=` short declaration
// whose initializer's type is inferred (a composite literal, a call's result, or
// another binding it aliases). A local shadows a file-scope binding, an inner
// scope shadows an outer, a later declaration shadows an earlier — like
// resolve_local.
@(private = "file")
binding_type_ref :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    name: string,
    offset: int,
    depth := 0,
) -> (Type_Ref, bool) {
    binds := make([dynamic]Binding, context.temp_allocator)
    collect_bindings(root, req.source, name, &binds)

    best: Binding
    found := false
    for b in binds {
        if !b.top_level && (offset < b.scope_start || offset > b.scope_end || offset < b.visible_from) {
            continue
        }
        if !found || binding_better(b, best, offset) {
            best = b
            found = true
        }
    }
    if !found {
        return {}, false
    }
    if best.is_range {
        return range_var_type(e, parser, root, req, best.expr, best.result_index, depth + 1)
    }
    if best.has_expr {
        return infer_expr_result(e, parser, root, req, best.expr, best.result_index, depth + 1)
    }
    return best.tr, true
}

// Type of the `index`-th variable of `for a, b in expr`: over an array the first
// is the element and the second its integer index, over a map the first is the
// key and the second the value. A map's key type isn't tracked (the container
// carries only its element), so ranging over one binds the value alone.
@(private = "file")
range_var_type :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    expr: ts.Node,
    index, depth: int,
) -> (Type_Ref, bool) {
    tr, ok := infer_expr_result(e, parser, root, req, expr, 0, depth)
    if !ok {
        return {}, false
    }
    switch tr.container {
    case .Array:
        if index != 0 {
            return {}, false
        }
    case .Map:
        if index != 1 {
            return {}, false
        }
    case .None:
        return {}, false
    }
    tr.container = .None
    return tr, true
}

@(private = "file")
binding_better :: proc(a, b: Binding, offset: int) -> bool {
    if a.top_level != b.top_level {
        return !a.top_level
    }
    if !a.top_level {
        aw := a.scope_end - a.scope_start
        bw := b.scope_end - b.scope_start
        if aw != bw {
            return aw < bw
        }
        if a.visible_from != b.visible_from {
            return a.visible_from > b.visible_from
        }
    }
    return abs(a.pos - offset) < abs(b.pos - offset)
}

// Walks the tree gathering every binding of `name`: parameters and typed `var`
// declarations (their `(type ...)` child) and `name := value` short declarations
// (the initializer, whose type is inferred later). Each carries the scope it is
// visible in — a parameter its procedure, a local the part of its block that
// follows the declaration, otherwise file-wide.
@(private = "file")
collect_bindings :: proc(node: ts.Node, source, name: string, out: ^[dynamic]Binding) {
    switch string(ts.node_type(node)) {
    case "parameter", "default_parameter":
        if tr, ok := named_decl_type(node, source, name); ok {
            b := Binding{tr = tr, pos = int(ts.node_start_byte(node))}
            if pd, has := ancestor_type(node, "procedure_declaration"); has {
                b.scope_start = int(ts.node_start_byte(pd))
                b.scope_end = int(ts.node_end_byte(pd))
            } else {
                b.top_level = true
            }
            append(out, b)
        }
    case "var_declaration":
        if tr, ok := named_decl_type(node, source, name); ok {
            append(out, scoped_binding(node, Binding{tr = tr}))
        }
    case "assignment_statement":
        if b, ok := short_decl_binding(node, source, name); ok {
            append(out, scoped_binding(node, b))
        }
    case "for_statement":
        if b, ok := range_binding(node, source, name); ok {
            append(out, b)
        }
    }
    for i in 0 ..< ts.node_child_count(node) {
        collect_bindings(ts.node_child(node, i), source, name, out)
    }
}

// `b` scoped to the block or control-flow statement enclosing its declaration,
// or file-wide when there is none. A `:=`/`var` binding is order-dependent, so
// it only takes effect past its own declaration — which is what lets `x := x`
// read the outer `x` rather than itself.
@(private = "file")
scoped_binding :: proc(node: ts.Node, b: Binding) -> Binding {
    out := b
    out.pos = int(ts.node_start_byte(node))
    if scope, has := enclosing_scope(node); has {
        out.scope_start = int(ts.node_start_byte(scope))
        out.scope_end = int(ts.node_end_byte(scope))
        out.visible_from = int(ts.node_end_byte(node))
    } else {
        out.top_level = true
    }
    return out
}

// Type of a `name`-declaring node whose shape is `ident... : type [= value]`
// (a parameter or a `var` declaration). Names precede the `type` child; a
// trailing initializer value is ignored (the walk stops at the type).
@(private = "file")
named_decl_type :: proc(node: ts.Node, source, name: string) -> (Type_Ref, bool) {
    matched := false
    for i in 0 ..< ts.node_named_child_count(node) {
        c := ts.node_named_child(node, i)
        switch string(ts.node_type(c)) {
        case "identifier":
            if ts.node_text(c, source) == name {
                matched = true
            }
        case "type":
            if !matched {
                return {}, false
            }
            return type_ref_from_node(c, source)
        }
    }
    return {}, false
}

// The binding `name` gets from a `:=` short declaration (a `=` reassignment is not
// a declaration and is ignored). The declared names are the identifier children
// before the `:=` token, the initializers the expressions after it, so the
// expression this name binds to is either its positional partner (`a, b := x, y`)
// or — when one call feeds several names — the call plus the result slot to take
// (`v, ok := f()`). The type of that expression is inferred on demand.
@(private = "file")
short_decl_binding :: proc(node: ts.Node, source, name: string) -> (Binding, bool) {
    is_decl := false
    names := 0
    matched := -1
    rhs := make([dynamic]ts.Node, context.temp_allocator)

    for i in 0 ..< ts.node_child_count(node) {
        c := ts.node_child(node, i)
        if string(ts.node_type(c)) == ":=" {
            is_decl = true
            continue
        }
        if !ts.node_is_named(c) {
            continue // the commas separating names and initializers
        }
        if !is_decl {
            if is_identifier(c) {
                if ts.node_text(c, source) == name {
                    matched = names
                }
                names += 1
            }
            continue
        }
        append(&rhs, c)
    }
    if !is_decl || matched < 0 || len(rhs) == 0 {
        return {}, false
    }

    switch {
    case len(rhs) == names:
        return Binding{expr = rhs[matched], has_expr = true}, true
    case len(rhs) == 1:
        // One expression for several names: a multi-value call, one result each.
        return Binding{expr = rhs[0], has_expr = true, result_index = matched}, true
    }
    return {}, false
}

// The binding `name` gets from a range loop (`for value in expr`, `for k, v in
// expr`). Only the range form declares variables — the three-clause form's
// `i := 0` is an assignment_statement collect_bindings already handles — so the
// `in` token is what identifies it. The variables are the identifier children
// before `in`, the ranged expression the first named child after it; the element
// type is inferred on demand. A loop variable is visible only inside its loop, so
// the binding is scoped to the statement rather than the enclosing block.
@(private = "file")
range_binding :: proc(node: ts.Node, source, name: string) -> (Binding, bool) {
    vars := 0
    matched := -1
    seen_in := false
    expr: ts.Node

    for i in 0 ..< ts.node_child_count(node) {
        c := ts.node_child(node, i)
        if string(ts.node_type(c)) == "in" {
            seen_in = true
            continue
        }
        if !ts.node_is_named(c) {
            continue
        }
        if !seen_in {
            // `for &p in xs` wraps the variable, and the three-clause form's
            // first child is a statement — neither is a bare loop variable.
            if is_identifier(c) {
                if ts.node_text(c, source) == name {
                    matched = vars
                }
            }
            vars += 1
            continue
        }
        expr = c
        break
    }
    if !seen_in || matched < 0 || ts.node_is_null(expr) {
        return {}, false
    }
    return Binding {
            expr = expr,
            has_expr = true,
            is_range = true,
            result_index = matched,
            pos = int(ts.node_start_byte(node)),
            scope_start = int(ts.node_start_byte(node)),
            scope_end = int(ts.node_end_byte(node)),
        },
        true
}

// Reads a `(type ...)` node (or a bare type construct) into a Type_Ref. Unwraps a
// pointer type (`^T` — Odin auto-derefs on `.`), reads a package-qualified `pkg.T`
// (a `field_type`), and records a container around a named element type: the
// grammar spells `[]T`, `[N]T` and `[dynamic]T` all as `array_type` (the element
// is the last named child) and `map[K]V` as `map_type` (key then value). A
// container's own members are nothing this engine models, so it must be indexed
// or ranged over before its element's fields resolve. Anything else — a proc
// type, a nested container, a bit_set — returns false.
@(private = "file")
type_ref_from_node :: proc(node: ts.Node, source: string) -> (Type_Ref, bool) {
    n := node
    if string(ts.node_type(n)) == "type" {
        n = ts.node_named_child(n, 0)
    }
    if ts.node_is_null(n) {
        return {}, false
    }
    switch string(ts.node_type(n)) {
    case "identifier":
        return Type_Ref{name = ts.node_text(n, source)}, true
    case "pointer_type":
        return type_ref_from_node(ts.node_named_child(n, 0), source)
    case "field_type":
        a := ts.node_named_child(n, 0)
        b := ts.node_named_child(n, 1)
        if is_identifier(a) && is_identifier(b) {
            return Type_Ref{pkg = ts.node_text(a, source), name = ts.node_text(b, source)}, true
        }
    case "array_type":
        count := ts.node_named_child_count(n)
        if count == 0 {
            return {}, false
        }
        return contained_type(ts.node_named_child(n, count - 1), source, .Array)
    case "map_type":
        if ts.node_named_child_count(n) < 2 {
            return {}, false
        }
        return contained_type(ts.node_named_child(n, 1), source, .Map)
    }
    return {}, false
}

// The element type of a container, tagged with the container that holds it. Only
// one level is modelled: an element that is itself a container (`[][]Point`) has
// no single type to name here.
@(private = "file")
contained_type :: proc(node: ts.Node, source: string, container: Container) -> (Type_Ref, bool) {
    tr, ok := type_ref_from_node(node, source)
    if !ok || tr.container != .None {
        return {}, false
    }
    tr.container = container
    return tr, true
}

// A type named in *expression* position (a composite literal's type, `new`'s
// argument): `Point` or `pkg.Point`. Unlike type_ref_from_node the qualified form
// arrives as a member expression here, since the grammar parses it as a value.
@(private = "file")
expr_type_name :: proc(node: ts.Node, source: string) -> (Type_Ref, bool) {
    if ts.node_is_null(node) {
        return {}, false
    }
    if is_identifier(node) {
        return Type_Ref{name = ts.node_text(node, source)}, true
    }
    switch string(ts.node_type(node)) {
    case "member_expression", "field_type":
        a := ts.node_named_child(node, 0)
        b := ts.node_named_child(node, 1)
        if is_identifier(a) && is_identifier(b) {
            return Type_Ref{pkg = ts.node_text(a, source), name = ts.node_text(b, source)}, true
        }
    case "pointer_type", "unary_expression":
        return expr_type_name(ts.node_named_child(node, 0), source)
    case "array_type", "map_type":
        // A container literal (`[]Point{...}`) names a container type.
        return type_ref_from_node(node, source)
    }
    return {}, false
}

// Type a call evaluates to: resolve the callee the same three ways signature help
// does (same file, `pkg.fn(...)`, workspace index) and read the result type out of
// its signature. `index` picks a slot out of a multi-value return. `new`/`new_clone`
// are answered directly — they are builtins with no declaration to find, and their
// result is the allocated type (a pointer, which `.` auto-dereferences anyway).
//
// A package-qualified result (`-> pkg.Point`) is qualified by the *callee's*
// imports, so the result carries the callee's path and visit_type_decl falls back
// to resolving `pkg` there when the requesting file doesn't import it the same way.
@(private = "file")
call_result_type :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    call: ts.Node,
    index, depth: int,
) -> (Type_Ref, bool) {
    fn := ts.node_child_by_field_name(call, "function")
    if ts.node_is_null(fn) {
        return {}, false
    }
    if is_identifier(fn) {
        switch ts.node_text(fn, req.source) {
        case "new", "new_clone":
            arg := ts.node_child_by_field_name(call, "argument")
            if string(ts.node_type(arg)) == "struct" {
                arg = ts.node_named_child(arg, 0) // new_clone(Point{...})
            }
            return expr_type_name(arg, req.source)
        }
    }

    src, path, d, found := resolve_call_target(e, parser, root, req, call, fn)
    if !found || d.kind != "function" {
        return {}, false
    }
    tr, ok := proc_result_type(src, d, index)
    if !ok {
        return {}, false
    }
    // The result type is spelled in the callee's file, so that file's imports are
    // what qualify it (`-> other.Point`).
    tr.origin = path
    return tr, true
}

// Result type of a procedure declaration, read out of its signature text: what
// follows `->`, or the `index`-th entry of a parenthesized result list. Text-based
// because a cross-file callee's parse tree is already gone by the time its Def
// comes back — only the file's source outlives it. `source` is whatever buffer the
// Def slices, so the Type_Ref lives exactly as long as its Def does.
@(private = "file")
proc_result_type :: proc(source: string, d: Def, index: int) -> (Type_Ref, bool) {
    start := clamp(d.ident_start, 0, len(source))
    sig := source[start:clamp(d.decl_end, start, len(source))]

    // Skip the parameter list first, so neither a nested `proc() -> int` parameter
    // nor a default composite value (`x: Point = Point{}`) is mistaken for this
    // procedure's own result or body. What is left is `-> results` plus the body.
    after, ok := after_paren_group(sig)
    if !ok {
        return {}, false
    }
    if brace := strings.index_byte(after, '{'); brace >= 0 {
        after = after[:brace]
    }
    arrow := strings.index(after, "->")
    if arrow < 0 {
        return {}, false // no results at all
    }
    results := strings.trim_space(after[arrow + 2:])

    if strings.has_prefix(results, "(") {
        inner, iok := after_paren_group(results, want_inner = true)
        if !iok {
            return {}, false
        }
        parts := split_top_level(inner)
        if index < 0 || index >= len(parts) {
            return {}, false
        }
        return result_type_ref(parts[index])
    }
    if index != 0 {
        return {}, false // a single result can only fill slot 0
    }
    return result_type_ref(results)
}

// Splits `text` on its top-level commas (ignoring those nested in brackets), for
// a result list. Temp-allocated.
@(private = "file")
split_top_level :: proc(text: string) -> []string {
    parts := make([dynamic]string, context.temp_allocator)
    depth := 0
    start := 0
    for i in 0 ..< len(text) {
        switch text[i] {
        case '(', '[', '{':
            depth += 1
        case ')', ']', '}':
            depth -= 1
        case ',':
            if depth == 0 {
                append(&parts, text[start:i])
                start = i + 1
            }
        }
    }
    append(&parts, text[start:])
    return parts[:]
}

// Splits `text` at its first balanced bracket group: the text after the group's
// closing bracket, or — with `want_inner` — the text between the brackets. Quoted
// strings are skipped so a bracket inside a default value or a calling convention
// can't unbalance the scan.
@(private = "file")
after_paren_group :: proc(text: string, want_inner := false) -> (string, bool) {
    depth := 0
    open := -1
    quote: u8 = 0
    for i := 0; i < len(text); i += 1 {
        c := text[i]
        if quote != 0 {
            switch c {
            case '\\':
                i += 1
            case quote:
                quote = 0
            }
            continue
        }
        switch c {
        case '"', '\'', '`':
            quote = c
        case '(':
            depth += 1
            if open < 0 {
                open = i
            }
        case ')':
            depth -= 1
            if depth == 0 && open >= 0 {
                return want_inner ? text[open + 1:i] : text[i + 1:], true
            }
            if depth < 0 {
                return "", false
            }
        }
    }
    return "", false
}

// One result's type text (`Point`, `p: ^Point`, `pkg.Point`, `[]Point`,
// `map[string]Point`) as a Type_Ref: a named result drops its name, a pointer is
// dereferenced (Odin auto-dereferences `.`), and a leading `[…]`/`map[…]` becomes
// the container around the element type. Anything else — a proc type, a bit_set, a
// generic `$T` — is rejected rather than guessed, matching type_ref_from_node's
// reach. Text-based because a cross-file callee's tree is gone by now.
@(private = "file")
result_type_ref :: proc(text: string) -> (Type_Ref, bool) {
    s := strings.trim_space(text)
    if colon := strings.index_byte(s, ':'); colon >= 0 {
        s = strings.trim_space(s[colon + 1:])
    }
    for strings.has_prefix(s, "^") {
        s = strings.trim_space(s[1:])
    }
    // A trailing tail (`Point ---` on a foreign proc, a comment) is not part of it.
    if space := strings.index_proc(s, strings.is_space); space >= 0 {
        s = s[:space]
    }

    container := Container.None
    if strings.has_prefix(s, "map[") {
        rest, ok := after_bracket_group(s[3:])
        if !ok {
            return {}, false
        }
        container = .Map
        s = rest
    } else if strings.has_prefix(s, "[") {
        rest, ok := after_bracket_group(s)
        if !ok {
            return {}, false
        }
        container = .Array
        s = rest
    }
    for strings.has_prefix(s, "^") {
        s = s[1:]
    }

    tr, ok := plain_type_ref(s)
    if !ok {
        return {}, false
    }
    tr.container = container
    return tr, true
}

// The text after a balanced `[...]` group at the head of `text` (a container's
// key or length). Nested brackets are counted, so `map[[2]int]Point` still lands
// on `Point`.
@(private = "file")
after_bracket_group :: proc(text: string) -> (string, bool) {
    if !strings.has_prefix(text, "[") {
        return "", false
    }
    depth := 0
    for i in 0 ..< len(text) {
        switch text[i] {
        case '[':
            depth += 1
        case ']':
            depth -= 1
            if depth == 0 {
                return text[i + 1:], true
            }
        }
    }
    return "", false
}

// A bare — optionally package-qualified — type name as a Type_Ref.
@(private = "file")
plain_type_ref :: proc(s: string) -> (Type_Ref, bool) {
    if dot := strings.index_byte(s, '.'); dot >= 0 {
        if is_plain_name(s[:dot]) && is_plain_name(s[dot + 1:]) {
            return Type_Ref{pkg = s[:dot], name = s[dot + 1:]}, true
        }
        return {}, false
    }
    if !is_plain_name(s) {
        return {}, false
    }
    return Type_Ref{name = s}, true
}

// Whether `s` is a bare identifier — the only shape a nominal type name takes.
@(private = "file")
is_plain_name :: proc(s: string) -> bool {
    if s == "" || (s[0] >= '0' && s[0] <= '9') {
        return false
    }
    for i in 0 ..< len(s) {
        if !is_ident_byte(s[i]) {
            return false
        }
    }
    return true
}

// Called with a located type declaration node (a `struct_declaration` or
// `enum_declaration`) and the source/path it lives in, to extract whatever a
// member operation needs (a field, an enum member, or every one of them).
@(private = "file")
Decl_Visitor :: #type proc(decl: ts.Node, source, path: string, ctx: rawptr)

// Locates the type declaration named `tr` (of node type `decl_type`, e.g.
// "struct_declaration") and runs `visit` on it, returning whether one was found.
// Resolution order mirrors goto: the request file first (a declaration in the same
// package file wins), then — for a package-qualified type — the imported package's
// directory, otherwise the workspace index (a file whose top-level decls of kind
// `index_kind` declare the name). The first located declaration is terminal.
@(private = "file")
visit_type_decl :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    tr: Type_Ref,
    decl_type, index_kind: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> bool {
    // A container is not the type it holds: `xs: []Point` must be indexed or
    // ranged over before Point's fields are in reach, so every member operation
    // (field goto, hover, field/enum completion) stops here.
    if tr.container != .None {
        return false
    }
    if decl, ok := locate_decl(root, req.source, tr.name, decl_type); ok {
        visit(decl, req.source, req.path, ctx)
        return true
    }
    if tr.pkg != "" {
        if raw, found := import_path(root, req.source, tr.pkg); found {
            if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                if visit_decl_in_dir(e, parser, dir, tr.name, req.path, decl_type, visit, ctx) {
                    return true
                }
            }
        }
        // The qualifier belongs to the file the type was *written* in (a callee's
        // `-> other.Point`, a cross-file struct's `using base: other.Base`), which
        // the requesting file need not import — or need not import under the same
        // alias. Resolve it against that file's own imports.
        if tr.origin != "" && tr.origin != req.path {
            return visit_qualified_in_origin(e, parser, req, tr, decl_type, visit, ctx)
        }
        return false
    }
    if req.workspace != "" {
        path, ok := "", false
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        if p, found := index_first_path(e, tr.name, req.path, index_kind); found {
            path = strings.clone(p, context.temp_allocator)
            ok = true
        }
        sync.unlock(&e.index.mutex)
        if ok {
            return visit_decl_in_file(e, parser, path, tr.name, decl_type, visit, ctx)
        }
    }
    return false
}

// visit_type_decl for a package-qualified type whose qualifier is spelled in
// another file: re-parse that file, resolve `pkg` through *its* imports, and visit
// the declaration in the package that names. One extra parse, paid only when the
// requesting file's own imports came up empty.
@(private = "file")
visit_qualified_in_origin :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    req: ^Request,
    tr: Type_Ref,
    decl_type: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> bool {
    data, rerr := os.read_entire_file(tr.origin, context.temp_allocator)
    if rerr != nil {
        return false
    }
    source := string(data)

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return false
    }
    defer ts.tree_delete(tree)

    raw, found := import_path(ts.tree_root_node(tree), source, tr.pkg)
    if !found {
        return false
    }
    dir, dok := package_dir(e, raw, tr.origin, req.workspace)
    if !dok {
        return false
    }
    return visit_decl_in_dir(e, parser, dir, tr.name, req.path, decl_type, visit, ctx)
}

// visit_type_decl over one package directory's files (non-recursive — a package is
// a flat dir), skipping the requesting file whose live buffer was searched already.
@(private = "file")
visit_decl_in_dir :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    dir, name, skip, decl_type: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> bool {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return false
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return false
    }

    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == skip {
            continue
        }
        if visit_decl_in_file(e, parser, info.fullpath, name, decl_type, visit, ctx) {
            return true
        }
    }
    return false
}

// visit_type_decl over one file: parse it (source is temp-allocated, job-lifetime,
// so anything the visitor keeps must clone or copy out before the tree is deleted).
@(private = "file")
visit_decl_in_file :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    path, name, decl_type: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> bool {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return false
    }
    source := string(data)

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return false
    }
    defer ts.tree_delete(tree)

    if decl, ok := locate_decl(ts.tree_root_node(tree), source, name, decl_type); ok {
        visit(decl, source, path, ctx)
        return true
    }
    return false
}

// The top-level declaration of node type `decl_type` named `name`, if any. A type
// declaration's first named child is its identifier.
@(private = "file")
locate_decl :: proc(root: ts.Node, source, name, decl_type: string) -> (ts.Node, bool) {
    for i in 0 ..< ts.node_named_child_count(root) {
        c := ts.node_named_child(root, i)
        if string(ts.node_type(c)) != decl_type {
            continue
        }
        if id := ts.node_named_child(c, 0); is_identifier(id) && ts.node_text(id, source) == name {
            return c, true
        }
    }
    return {}, false
}

// What a Decl_Visitor needs to resolve a *further* type declaration from inside
// the one it is visiting — an embedded `using` field's struct. `depth` caps the
// recursion, since two structs can embed each other.
@(private = "file")
Embed_Env :: struct {
    e:      ^Odin_Engine,
    parser: ts.Parser,
    root:   ts.Node,
    req:    ^Request,
    depth:  int,
}

// How deep `using` embedding is followed.
@(private = "file")
EMBED_DEPTH_LIMIT :: 4

// Outputs of member_visitor: the located field's identifier and full-declaration
// byte ranges (into `src`), the field's own type (temp-cloned, for chaining), and
// whether the field was found. `src`/`path` are job-lifetime.
@(private = "file")
Member_Ctx :: struct {
    field:       string,
    env:         Embed_Env,
    got:         bool,
    src:         string,
    path:        string,
    ident_start: int,
    ident_end:   int,
    decl_start:  int,
    decl_end:    int,
    field_type:  Type_Ref,
}

// Decl_Visitor that finds one named field. Records its identifier range (the
// jump target), its whole-declaration range (`x: int`, for hover) and its type
// (for a chained `a.b.c`). The type is cloned into scratch so it survives the
// parse tree's deletion in the cross-file case. A field the struct does not
// declare itself may still come from a struct it embeds with `using`.
@(private = "file")
member_visitor :: proc(sd: ts.Node, source, path: string, ctx_raw: rawptr) {
    ctx := cast(^Member_Ctx) ctx_raw
    id, tn, fd, ok := struct_field(sd, source, ctx.field)
    if !ok {
        visit_embedded(sd, source, path, &ctx.env, member_visitor, ctx)
        return
    }
    ctx.got = true
    ctx.src = source
    ctx.path = path
    ctx.ident_start = int(ts.node_start_byte(id))
    ctx.ident_end = int(ts.node_end_byte(id))
    ctx.decl_start = int(ts.node_start_byte(fd))
    ctx.decl_end = int(ts.node_end_byte(fd))
    if tr, tok := type_ref_from_node(tn, source); tok {
        ctx.field_type = clone_type_ref(tr, path)
    }
}

// Runs `visit` on every struct this one embeds with `using`, so an embedded
// struct's fields answer as if they were the outer struct's own. The embedded
// type is resolved the usual way (same file → imported package → workspace
// index), qualified against the file the embedding was written in.
@(private = "file")
visit_embedded :: proc(
    sd: ts.Node,
    source, path: string,
    env: ^Embed_Env,
    visit: Decl_Visitor,
    ctx: rawptr,
) {
    if env.e == nil || env.depth >= EMBED_DEPTH_LIMIT {
        return
    }
    for i in 0 ..< ts.node_named_child_count(sd) {
        c := ts.node_named_child(sd, i)
        if string(ts.node_type(c)) != "field" || !field_is_using(c) {
            continue
        }
        count := ts.node_named_child_count(c)
        if count == 0 {
            continue
        }
        tn := ts.node_named_child(c, count - 1)
        if string(ts.node_type(tn)) != "type" {
            continue
        }
        tr, ok := type_ref_from_node(tn, source)
        if !ok {
            continue
        }
        tr = clone_type_ref(tr, path)
        env.depth += 1
        visit_type_decl(env.e, env.parser, env.root, env.req, tr, "struct_declaration", "type", visit, ctx)
        env.depth -= 1
    }
}

// Whether a struct field is embedded (`using base: Base`). The grammar keeps
// `using` as an anonymous token on the field.
@(private = "file")
field_is_using :: proc(field: ts.Node) -> bool {
    for i in 0 ..< ts.node_child_count(field) {
        if string(ts.node_type(ts.node_child(field, i))) == "using" {
            return true
        }
    }
    return false
}

// A Type_Ref copied into scratch, tagged with the file it was read from, so it
// outlives the parse tree it came from and keeps its qualifier resolvable.
@(private = "file")
clone_type_ref :: proc(tr: Type_Ref, path: string) -> Type_Ref {
    out := tr
    out.name = strings.clone(tr.name, context.temp_allocator)
    out.pkg = strings.clone(tr.pkg, context.temp_allocator)
    out.origin = strings.clone(path, context.temp_allocator)
    return out
}

// The `field`-named member of a struct: its identifier node, its `(type ...)`
// node, and the whole `field` node. A single `field` can declare several names
// (`x, y: int`), so every identifier before the trailing type is checked.
@(private = "file")
struct_field :: proc(sd: ts.Node, source, field: string) -> (ident, type_node, field_node: ts.Node, ok: bool) {
    for i in 0 ..< ts.node_named_child_count(sd) {
        c := ts.node_named_child(sd, i)
        if string(ts.node_type(c)) != "field" {
            continue
        }
        count := ts.node_named_child_count(c)
        if count < 2 {
            continue
        }
        tn := ts.node_named_child(c, count - 1)
        if string(ts.node_type(tn)) != "type" {
            continue
        }
        for j in 0 ..< count - 1 {
            id := ts.node_named_child(c, j)
            if is_identifier(id) && ts.node_text(id, source) == field {
                return id, tn, c, true
            }
        }
    }
    return {}, {}, {}, false
}

// Outputs of fields_visitor: the completion Result to append to, the typed
// prefix filter and the de-dup set.
@(private = "file")
Fields_Ctx :: struct {
    prefix: string,
    env:    Embed_Env,
    res:    ^Result,
    seen:   ^map[string]bool,
}

// Decl_Visitor that offers every field matching the prefix as a completion
// candidate (`name: type`, kind "field"), including the fields of every struct
// this one embeds with `using`. Owned strings clone into the Manager's allocator
// (context.allocator here).
@(private = "file")
fields_visitor :: proc(sd: ts.Node, source, path: string, ctx_raw: rawptr) {
    ctx := cast(^Fields_Ctx) ctx_raw
    defer visit_embedded(sd, source, path, &ctx.env, fields_visitor, ctx)
    for i in 0 ..< ts.node_named_child_count(sd) {
        c := ts.node_named_child(sd, i)
        if string(ts.node_type(c)) != "field" {
            continue
        }
        count := ts.node_named_child_count(c)
        if count < 2 {
            continue
        }
        for j in 0 ..< count - 1 {
            id := ts.node_named_child(c, j)
            if !is_identifier(id) {
                continue
            }
            fname := ts.node_text(id, source)
            if !completion_matches(fname, ctx.prefix) || fname in ctx.seen^ {
                continue
            }
            ctx.seen^[fname] = true
            append(&ctx.res.symbols, Symbol {
                name      = strings.clone(fname),
                kind      = strings.clone("field"),
                signature = field_signature(source, c),
            })
        }
    }
}

// One field's `name: type` line, trimmed — a member-completion row's label.
// Cloned into context.allocator.
@(private = "file")
field_signature :: proc(source: string, field_node: ts.Node) -> string {
    start := clamp(int(ts.node_start_byte(field_node)), 0, len(source))
    end := clamp(int(ts.node_end_byte(field_node)), start, len(source))
    text := source[start:end]
    if nl := strings.index_byte(text, '\n'); nl >= 0 {
        text = text[:nl]
    }
    return strings.clone(strings.trim_space(text))
}

// Outputs of enum_visitor: the completion Result, the typed prefix filter and the
// de-dup set. Mirrors Fields_Ctx.
@(private = "file")
Enum_Ctx :: struct {
    prefix: string,
    res:    ^Result,
    seen:   ^map[string]bool,
}

// Decl_Visitor that offers an enum's members as implicit-selector completions
// (`a: Axis = .<here>`). The `.` is already typed, so the inserted text is the
// bare member name; kind "enum_member" colors the row. An enum's members are its
// identifier children after the first (the enum name).
@(private = "file")
enum_visitor :: proc(ed: ts.Node, source, path: string, ctx_raw: rawptr) {
    ctx := cast(^Enum_Ctx) ctx_raw
    for i in 1 ..< ts.node_named_child_count(ed) {
        id := ts.node_named_child(ed, i)
        if !is_identifier(id) {
            continue
        }
        name := ts.node_text(id, source)
        if !completion_matches(name, ctx.prefix) || name in ctx.seen^ {
            continue
        }
        ctx.seen^[name] = true
        append(&ctx.res.symbols, Symbol {
            name      = strings.clone(name),
            kind      = strings.clone("enum_member"),
            signature = strings.clone(name),
        })
    }
}

// The type expected at `offset` for an implicit enum selector (`x: Type = .`).
// Walks up from the caret to the enclosing declaration: a `var_declaration`'s
// annotated type, or the type of an `assignment_statement`'s left-hand variable.
// Returns false when no such context is found (so no enum members are offered).
@(private = "file")
expected_type_at :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    offset: int,
) -> (Type_Ref, bool) {
    source := req.source
    off := u32(clamp(offset, 0, len(source)))
    n := ts.node_named_descendant_for_byte_range(root, off, off)
    for !ts.node_is_null(n) {
        switch string(ts.node_type(n)) {
        case "var_declaration":
            for i in 0 ..< ts.node_named_child_count(n) {
                c := ts.node_named_child(n, i)
                if string(ts.node_type(c)) == "type" {
                    return type_ref_from_node(c, source)
                }
            }
            return {}, false
        case "assignment_statement":
            lhs := ts.node_named_child(n, 0)
            if is_identifier(lhs) {
                return binding_type_ref(e, parser, root, req, ts.node_text(lhs, source), int(ts.node_start_byte(lhs)))
            }
            return {}, false
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Trimmed text of a byte range, cloned into context.allocator — a member hover's
// field declaration (`x: int`).
@(private = "file")
declaration_text_range :: proc(source: string, start, end: int) -> string {
    s := clamp(start, 0, len(source))
    e := clamp(end, s, len(source))
    return strings.clone(strings.trim_space(source[s:e]))
}

// Odin keywords and builtin types offered as completion candidates alongside the
// resolved identifiers.
@(private = "file")
ODIN_KEYWORDS :: [?]string {
    "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context",
    "continue", "defer", "distinct", "do", "dynamic", "else", "enum",
    "fallthrough", "for", "foreign", "if", "import", "in", "map", "matrix",
    "not_in", "or_else", "or_return", "package", "proc", "return", "struct",
    "switch", "transmute", "typeid", "union", "using", "when", "where",
    "bool", "b8", "b16", "b32", "b64",
    "int", "i8", "i16", "i32", "i64", "i128",
    "uint", "u8", "u16", "u32", "u64", "u128", "uintptr",
    "f16", "f32", "f64",
    "complex32", "complex64", "complex128",
    "quaternion64", "quaternion128", "quaternion256",
    "rune", "string", "cstring", "rawptr", "any", "byte",
    "true", "false", "nil",
}

// Bytes that make up an Odin identifier, for finding the partial word the caret
// is completing.
@(private = "file")
is_word_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b >= 0x80
}

// Code completion for the partial identifier before the caret. Two contexts:
// after `pkg.` (the operand names an imported package) it lists that package's
// top-level declarations; otherwise it offers the identifiers in scope — locals
// and parameters visible at the caret, this file's and this package's top-level
// declarations, the imported package names, and the Odin keywords and builtin
// types. All filtered by the typed prefix (case-sensitive) and de-duplicated by
// name. After `value.` it offers the operand's struct fields, inferring its type
// the same way member access does (so a `:=` call result works).
@(private = "file")
complete :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    src := req.source
    off := clamp(req.offset, 0, len(src))

    // The partial word being completed: the run of identifier bytes before the caret.
    start := off
    for start > 0 && is_word_byte(src[start - 1]) {
        start -= 1
    }
    prefix := src[start:off]

    // `pkg.<prefix>`: the char before the word is a `.` preceded by an identifier
    // that names an imported package. List that package's top-level symbols.
    if start > 0 && src[start - 1] == '.' {
        op_end := start - 1
        op_start := op_end
        for op_start > 0 && is_word_byte(src[op_start - 1]) {
            op_start -= 1
        }
        if op_start < op_end {
            operand := src[op_start:op_end]
            if raw, found := import_path(root, src, operand); found {
                // `pkg.<prefix>`: the imported package's top-level symbols.
                if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                    seen := make(map[string]bool, 0, context.temp_allocator)
                    complete_dir_toplevel(e, parser, req, dir, prefix, "", res, &seen)
                }
            } else if op_start == 0 || src[op_start - 1] != '.' {
                // `value.<prefix>`: infer the operand's struct type and offer its
                // fields. Only a bare operand — a chain (`a.b.`) isn't inferred here.
                if tr, tok := binding_type_ref(e, parser, root, req, operand, op_start); tok {
                    seen := make(map[string]bool, 0, context.temp_allocator)
                    ctx := Fields_Ctx {
                        prefix = prefix,
                        env    = Embed_Env{e = e, parser = parser, root = root, req = req},
                        res    = res,
                        seen   = &seen,
                    }
                    visit_type_decl(e, parser, root, req, tr, "struct_declaration", "type", fields_visitor, &ctx)
                }
            }
        } else {
            // Leading `.<prefix>` with no operand: an implicit enum selector
            // (`x: Axis = .`). Infer the expected type; if it's an enum, offer its
            // members. (`)`/`]` before the dot is a member on an expression result,
            // which has no inferable enum context here.)
            before := op_end > 0 ? src[op_end - 1] : 0 // the char just before the dot
            if before != ')' && before != ']' {
                if tr, tok := expected_type_at(e, parser, root, req, op_end); tok {
                    seen := make(map[string]bool, 0, context.temp_allocator)
                    ctx := Enum_Ctx{prefix = prefix, res = res, seen = &seen}
                    visit_type_decl(e, parser, root, req, tr, "enum_declaration", "enum", enum_visitor, &ctx)
                }
            }
        }
        finish_completion(res)
        return
    }

    seen := make(map[string]bool, 0, context.temp_allocator)

    // In-scope locals and parameters, plus this file's top-level declarations
    // (collect_defs yields both).
    defs := collect_defs(e, root, src)
    for d in defs {
        if !completion_def_ok(d, off) || !completion_matches(d.name, prefix) {
            continue
        }
        add_completion(res, src, d, &seen)
    }

    // This package's sibling files (an Odin package is one flat directory): their
    // top-level declarations are visible here unqualified.
    if req.path != "" {
        complete_dir_toplevel(e, parser, req, filepath.dir(req.path), prefix, req.path, res, &seen)
    }

    // Imported package names are completable identifiers too (`widgets`, `fmt`) —
    // the operand you then qualify with `.` — though they're not declarations
    // collect_defs yields.
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        if name, _, iok := import_name_and_path(child, src); iok && completion_matches(name, prefix) && name not_in seen {
            seen[name] = true
            append(&res.symbols, Symbol {
                name      = strings.clone(name),
                kind      = strings.clone("namespace"),
                signature = strings.clone(name),
            })
        }
    }

    // Keywords and builtin types.
    for kw in ODIN_KEYWORDS {
        if completion_matches(kw, prefix) && kw not_in seen {
            seen[kw] = true
            append(&res.symbols, Symbol {
                name      = strings.clone(kw),
                kind      = strings.clone("keyword"),
                signature = strings.clone(kw),
            })
        }
    }

    finish_completion(res)
}

// Whether a declaration belongs in the general completion list: an in-scope
// local or parameter (visible at the caret), or any file-scope declaration.
// Struct fields, the package/import namespace and labels are excluded — a field
// is only reachable through an instance, which needs type inference.
@(private = "file")
completion_def_ok :: proc(d: Def, off: int) -> bool {
    switch d.kind {
    case "field", "namespace", "label", "":
        return false
    }
    return def_visible_at(d, off)
}

// Case-sensitive prefix match; an empty prefix matches everything.
@(private = "file")
completion_matches :: proc(name, prefix: string) -> bool {
    return strings.has_prefix(name, prefix)
}

// Appends a completion candidate for `d`, de-duplicated by name. The label is the
// declaration line for a top-level symbol, or just the name for a local/param.
// Owned strings clone into context.allocator (the Manager's).
@(private = "file")
add_completion :: proc(res: ^Result, source: string, d: Def, seen: ^map[string]bool) {
    if d.name in seen^ {
        return
    }
    seen^[d.name] = true
    label := d.top_level ? signature_text(source, d) : strings.clone(d.name)
    append(&res.symbols, Symbol {
        name      = strings.clone(d.name),
        kind      = strings.clone(d.kind),
        signature = label,
    })
}

// Appends one directory's top-level declarations (its .odin files, non-recursive
// — an Odin package is a flat dir) whose names match `prefix`, skipping `skip`
// (the requesting file, whose live buffer was scanned already).
//
// Served from the resident symbol index when the directory is inside the indexed
// workspace, which is the per-keystroke case: completion fires while typing, and
// re-reading and re-parsing every sibling file for each keystroke was the last
// consumer still doing that. The index sync only re-parses files whose stat moved,
// so a burst of keystrokes costs a readdir walk instead of a package of parses.
// A directory outside the index — a `core:`/`vendor:` package, a collection —
// still reads off disk.
@(private = "file")
complete_dir_toplevel :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    req: ^Request,
    dir, prefix, skip: string,
    res: ^Result,
    seen: ^map[string]bool,
) {
    if req.workspace != "" {
        indexed := false
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        if !request_cancelled(req) {
            indexed = index_dir_completions(e, dir, prefix, skip, res, seen)
        }
        sync.unlock(&e.index.mutex)
        if indexed || request_cancelled(req) {
            return
        }
    }
    complete_dir_scan(e, parser, req, dir, prefix, skip, res, seen)
}

// The off-disk half of complete_dir_toplevel: reads and parses each .odin file in
// `dir`. Used for packages the index doesn't cover.
@(private = "file")
complete_dir_scan :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    req: ^Request,
    dir, prefix, skip: string,
    res: ^Result,
    seen: ^map[string]bool,
) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    for info in infos {
        // The keystroke that asked for these candidates is already stale — the
        // next one has its own request, and this parse would be thrown away.
        if request_cancelled(req) {
            return
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == skip {
            continue
        }
        data, rerr := os.read_entire_file(info.fullpath, context.temp_allocator)
        if rerr != nil {
            continue
        }
        source := string(data)
        tree := ts.parser_parse_string(parser, source)
        if tree == nil {
            continue
        }
        defs := collect_defs(e, ts.tree_root_node(tree), source)
        for d in defs {
            if d.top_level && symbol_kind_shown(d.kind) && completion_matches(d.name, prefix) {
                add_completion(res, source, d, seen)
            }
        }
        ts.tree_delete(tree)
    }
}

// Sorts completion candidates by name for a stable list and flags the result ok
// when any matched.
@(private = "file")
finish_completion :: proc(res: ^Result) {
    slice.sort_by(res.symbols[:], proc(a, b: Symbol) -> bool {
        return a.name < b.name
    })
    res.ok = len(res.symbols) > 0
}

// Byte range, within a signature line, of the `active`-th parameter — used to
// emphasize the argument the caret is on. Splits the first parenthesized group
// (the parameter list; a `-> (a, b)` return tuple comes after and is never
// reached) on top-level commas, tracking bracket depth so a comma inside a nested
// type (`b: proc(x: int)`, `c: [dynamic]int`) doesn't split a parameter. Returns
// an empty range when `active` is past the last parameter.
@(private = "file")
active_param_span :: proc(label: string, active: int) -> (int, int) {
    open := strings.index_byte(label, '(')
    if open < 0 {
        return 0, 0
    }
    depth := 0
    idx := 0
    param_start := open + 1
    for i := open; i < len(label); i += 1 {
        switch label[i] {
        case '(', '[', '{':
            depth += 1
        case ')', ']', '}':
            depth -= 1
            if depth == 0 {
                if idx == active {
                    return trim_span(label, param_start, i)
                }
                return 0, 0
            }
        case ',':
            if depth == 1 {
                if idx == active {
                    return trim_span(label, param_start, i)
                }
                idx += 1
                param_start = i + 1
            }
        }
    }
    return 0, 0
}

// Shrinks [start, end) past leading and trailing ASCII spaces/tabs.
@(private = "file")
trim_span :: proc(label: string, start, end: int) -> (int, int) {
    s, e := start, end
    for s < e && (label[s] == ' ' || label[s] == '\t') {
        s += 1
    }
    for e > s && (label[e - 1] == ' ' || label[e - 1] == '\t') {
        e -= 1
    }
    return s, e
}

// LOCALS capture suffixes that belong in a document outline. Excludes
// "parameter"/"field" (nested), "namespace" (package name and import aliases)
// and "" (labels).
@(private = "file")
symbol_kind_shown :: proc(kind: string) -> bool {
    switch kind {
    case "function", "type", "enum", "constant", "var":
        return true
    }
    return false
}

// Writes the resolved declaration into the result for the requested feature.
// Owned strings use context.allocator, which the worker set to the Manager's
// allocator, so they are freed on the main thread after the editor reads them.
@(private = "file")
fill_result :: proc(res: ^Result, req: ^Request, path, source: string, d: Def, hover_start, hover_end: int) {
    #partial switch req.kind {
    case .Definition:
        res.location = Location {
            path  = strings.clone(path),
            start = d.ident_start,
            end   = d.ident_end,
        }
        res.ok = true
    case .Hover:
        res.hover = Hover_Info {
            text  = declaration_text(source, d),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
}

// One-line signature for a symbol-list row: `name :: type`, trimmed. Starts at
// the declared identifier (so any leading `@(...)` attribute is skipped) and
// stops at the body brace or first newline. `foo :: proc(x: int) -> int {` and
// `Point :: struct {` yield `foo :: proc(x: int) -> int` and `Point :: struct`.
// Cloned into context.allocator.
@(private = "file")
signature_text :: proc(source: string, d: Def) -> string {
    start := clamp(d.ident_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := source[start:end]

    if brace := strings.index_byte(text, '{'); brace >= 0 {
        text = text[:brace]
    }
    if nl := strings.index_byte(text, '\n'); nl >= 0 {
        text = text[:nl]
    }
    return strings.clone(strings.trim_space(text))
}

// The full declaration text for a hover popup: the whole declaration node,
// trimmed, including any leading `@(...)` attribute (the grammar nests it as the
// declaration's first child, so decl_start already covers it). A procedure keeps
// only its signature — the body brace onward is dropped — while a type
// declaration (struct/enum/union/bit_field) or any other multi-line declaration
// is shown complete, across every line. Cloned into context.allocator.
@(private = "file")
declaration_text :: proc(source: string, d: Def) -> string {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := source[start:end]

    // Procedures: show the signature, not the body. The first `{` opens the body
    // (attributes use `(...)`, the signature has no brace), so cutting there keeps
    // any attribute line and the `name :: proc(...) -> ...` head.
    if d.kind == "function" {
        if brace := strings.index_byte(text, '{'); brace >= 0 {
            text = text[:brace]
        }
    }
    return strings.clone(strings.trim_space(text))
}

// Nearest ancestor whose node type equals `type`.
@(private = "file")
ancestor_type :: proc(node: ts.Node, type: string) -> (ts.Node, bool) {
    n := ts.node_parent(node)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == type {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Nearest ancestor whose node type ends with `suffix` (e.g. "_declaration").
@(private = "file")
ancestor_suffix :: proc(node: ts.Node, suffix: string) -> (ts.Node, bool) {
    n := ts.node_parent(node)
    for !ts.node_is_null(n) {
        if strings.has_suffix(string(ts.node_type(n)), suffix) {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// True when both nodes are non-null and cover the same byte range. tree-sitter
// Nodes are values, not pointers, so identity is compared by span.
@(private = "file")
same_node :: proc(a, b: ts.Node) -> bool {
    return !ts.node_is_null(a) && !ts.node_is_null(b) &&
        ts.node_start_byte(a) == ts.node_start_byte(b) &&
        ts.node_end_byte(a) == ts.node_end_byte(b)
}

// If `ident` is part of a `pkg.member` selector, returns the package operand
// node and the member (symbol) node, whether the caret sits on either side.
// Handles the three grammar shapes this produces:
//   `pkg.Symbol`      -> member_expression (identifier . identifier)
//   `pkg.fn(args)`    -> member_expression (identifier . call_expression)
//   `pkg.Type` (type) -> field_type        (identifier . identifier)
@(private = "file")
selector_parts :: proc(ident: ts.Node) -> (pkg: ts.Node, member: ts.Node, ok: bool) {
    p := ts.node_parent(ident)
    if ts.node_is_null(p) {
        return {}, {}, false
    }
    pt := string(ts.node_type(p))

    if pt == "member_expression" || pt == "field_type" {
        a := ts.node_named_child(p, 0)
        b := ts.node_named_child(p, 1)
        if ts.node_is_null(a) || ts.node_is_null(b) {
            return {}, {}, false
        }
        // `pkg.fn(args)`: the member is the call's function identifier.
        if string(ts.node_type(b)) == "call_expression" {
            if fn := ts.node_child_by_field_name(b, "function"); !ts.node_is_null(fn) {
                b = fn
            }
        }
        return a, b, true
    }

    // Caret on `fn` in `pkg.fn(args)`: the identifier's parent is the call, whose
    // parent is the member_expression carrying the package operand.
    if pt == "call_expression" {
        gp := ts.node_parent(p)
        if !ts.node_is_null(gp) && string(ts.node_type(gp)) == "member_expression" {
            a := ts.node_named_child(gp, 0)
            if same_node(ts.node_named_child(gp, 1), p) {
                return a, ident, true
            }
        }
    }

    return {}, {}, false
}

// Import path (the collection-qualified or relative string) declared in `root`
// for the package named `pkg`, matching either an explicit alias or the name
// derived from the path's last segment.
@(private = "file")
import_path :: proc(root: ts.Node, source: string, pkg: string) -> (string, bool) {
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        if name, raw, ok := import_name_and_path(child, source); ok && name == pkg {
            return raw, true
        }
    }
    return "", false
}

// Package name and path for one import_declaration. The name is the explicit
// alias when present, otherwise the path's last segment.
@(private = "file")
import_name_and_path :: proc(imp: ts.Node, source: string) -> (name: string, raw: string, ok: bool) {
    raw, ok = import_string(imp, source)
    if !ok {
        return "", "", false
    }
    if alias := ts.node_child_by_field_name(imp, "alias"); !ts.node_is_null(alias) && is_identifier(alias) {
        return ts.node_text(alias, source), raw, true
    }
    return package_name_from_path(raw), raw, true
}

// The quoted path of an import_declaration, unquoted (via the string_content
// child, falling back to trimming the quote bytes).
@(private = "file")
import_string :: proc(imp: ts.Node, source: string) -> (string, bool) {
    for i in 0 ..< ts.node_named_child_count(imp) {
        c := ts.node_named_child(imp, i)
        if string(ts.node_type(c)) != "string" {
            continue
        }
        for j in 0 ..< ts.node_named_child_count(c) {
            sc := ts.node_named_child(c, j)
            if string(ts.node_type(sc)) == "string_content" {
                return ts.node_text(sc, source), true
            }
        }
        t := ts.node_text(c, source)
        t = strings.trim_prefix(t, "\"")
        t = strings.trim_suffix(t, "\"")
        return t, true
    }
    return "", false
}

// Last path segment of an import path, after any collection prefix and any
// slash: "core:fmt" -> "fmt", "core:odin/parser" -> "parser", "../lang" -> "lang".
@(private = "file")
package_name_from_path :: proc(raw: string) -> string {
    s := raw
    if colon := strings.last_index_byte(s, ':'); colon >= 0 {
        s = s[colon + 1:]
    }
    if slash := strings.last_index_byte(s, '/'); slash >= 0 {
        s = s[slash + 1:]
    }
    if back := strings.last_index_byte(s, '\\'); back >= 0 {
        s = s[back + 1:]
    }
    return s
}

// Directory an import path points at. Relative paths resolve against the
// importing file's directory (fully in-workspace). `core:`/`vendor:`/`base:`
// collections resolve against ODIN_ROOT when the environment exposes it; any
// other collection is looked up in the workspace's `.thor/odin-analyzer.json`
// config, so a project's custom collections (`import "shared:foo"`) resolve.
// An unknown collection has no mapping. Returned dir is scratch-allocated.
@(private = "file")
package_dir :: proc(e: ^Odin_Engine, raw: string, req_path: string, workspace: string) -> (string, bool) {
    if colon := strings.index_byte(raw, ':'); colon >= 0 {
        coll := raw[:colon]
        sub := raw[colon + 1:]
        if coll == "core" || coll == "vendor" || coll == "base" {
            root := odin_root()
            if root == "" {
                return "", false
            }
            joined, err := filepath.join({root, coll, sub}, context.temp_allocator)
            return joined, err == nil
        }
        if croot, ok := config_collection_dir(e, coll, workspace); ok {
            joined, err := filepath.join({croot, sub}, context.temp_allocator)
            return joined, err == nil
        }
        return "", false
    }

    base := filepath.dir(req_path)
    joined, jerr := filepath.join({base, raw}, context.temp_allocator)
    if jerr != nil {
        return "", false
    }
    cleaned, cerr := filepath.clean(joined, context.temp_allocator)
    if cerr != nil {
        return joined, true
    }
    return cleaned, true
}

// Odin's install root, so `core:`/`vendor:`/`base:` imports can be located. The
// ODIN_ROOT environment variable wins when set (lets a user point at a different
// toolchain); otherwise fall back to the compiler's own root, baked in at build
// time as the `ODIN_ROOT` constant — this is what makes the standard library
// resolve out of the box, with no environment set up.
@(private = "file")
odin_root :: proc() -> string {
    if v, found := os.lookup_env("ODIN_ROOT", context.temp_allocator); found && v != "" {
        return v
    }
    return ODIN_ROOT
}

// Scans one package directory (all its .odin files, non-recursively — an Odin
// package is a single flat directory) for a matching top-level declaration.
@(private = "file")
scan_package :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    dir: string,
    req: ^Request,
    name: string,
    hover_start, hover_end: int,
    res: ^Result,
) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    for info in infos {
        if res.ok {
            return
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        scan_file(e, parser, info.fullpath, req, name, hover_start, hover_end, res)
    }
}

// Caret on the package operand itself (`pkg` in `pkg.Symbol`): "go to package".
// Definition jumps to the head of the file named like the package (the `foo.odin`
// entry file in package `foo`, the usual convention). When no such file exists it
// falls back to the .odin file whose name is fuzzily closest to the package name
// (a prefix like `foo_windows.odin` beats an unrelated `zebra.odin`), so the
// caret still lands on the most package-like file rather than reporting nothing.
// Hover shows the import path.
@(private = "file")
open_package :: proc(dir, raw: string, req: ^Request, res: ^Result, hover_start, hover_end: int) {
    #partial switch req.kind {
    case .Definition:
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
        best_name := "" // the fuzzily-closest .odin file, the fallback target
        best_path := ""
        best_score := 0
        for info in infos {
            if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
                continue
            }
            if info.name == want {
                res.location = Location{path = strings.clone(info.fullpath), start = 0, end = 0}
                res.ok = true
                return
            }
            // Higher score is closer; ties break lexicographically for a stable pick.
            s := pkg_file_score(strings.trim_suffix(info.name, ".odin"), pkg)
            if best_name == "" || s > best_score || (s == best_score && info.name < best_name) {
                best_name = info.name
                best_path = info.fullpath
                best_score = s
            }
        }
        // No `foo.odin`: land on the closest file so navigation still works.
        if best_path != "" {
            res.location = Location{path = strings.clone(best_path), start = 0, end = 0}
            res.ok = true
        }
    case .Hover:
        text := strings.concatenate({"import \"", raw, "\""}, context.temp_allocator)
        res.hover = Hover_Info {
            text  = strings.clone(text),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
}

// Renders a documentation page for the package the caret refers to. The package
// is resolved from the caret (an import line, a `pkg.Symbol` operand, or a bare
// identifier naming an imported package) and, failing that, falls back to the
// file's own package directory — so F3 anywhere in an Odin file shows something.
@(private = "file")
package_doc :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    dir, ok := package_dir_under_caret(e, root, req)
    owned_dir := "" // the fallback dir is allocated on context.allocator; free it
    if !ok {
        if req.path == "" {
            return
        }
        // No package under the caret: document the file's own package.
        owned_dir = filepath.dir(req.path)
        dir = owned_dir
    }
    defer if owned_dir != "" {
        delete(owned_dir)
    }
    render_package_doc(e, parser, req, dir, res)
}

// Resolves the package directory the caret refers to, the same three ways the
// goto flow does (an import declaration, a `pkg.Symbol` operand, a bare package
// name), reusing package_dir so collections and relative paths resolve alike.
@(private = "file")
package_dir_under_caret :: proc(e: ^Odin_Engine, root: ts.Node, req: ^Request) -> (string, bool) {
    if imp, in_import := enclosing_import(root, req.source, req.offset); in_import {
        if raw, rok := import_string(imp, req.source); rok {
            return package_dir(e, raw, req.path, req.workspace)
        }
        return "", false
    }
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return "", false
    }
    // `pkg.Symbol`: the operand names an imported package.
    if op_node, _, is_sel := selector_parts(ident); is_sel && is_identifier(op_node) {
        pkg := ts.node_text(op_node, req.source)
        if raw, found := import_path(root, req.source, pkg); found {
            return package_dir(e, raw, req.path, req.workspace)
        }
    }
    // A bare identifier that names an imported package (its alias by itself).
    name := ts.node_text(ident, req.source)
    if raw, found := import_path(root, req.source, name); found {
        return package_dir(e, raw, req.path, req.workspace)
    }
    return "", false
}

// One rendered entry in a package doc page: the declaration name (the sort key),
// its Odin signature (goes in a ```odin fence), and the cleaned doc-comment prose
// (the `//`-stripped comment above it). All slices/temp strings that outlive the
// source through the job's temp allocator.
@(private = "file")
Doc_Entry :: struct {
    name:      string,
    signature: string,
    doc:       string,
}

// Fence and section delimiters mirroring how OLS assembles its hover
// documentation: a signature in a ```odin code block, then a `---` rule, then the
// doc-comment prose. See build_markup_content in ols/src/server/documentation.odin.
@(private = "file")
DOC_FENCE_OPEN :: "```odin\n"
@(private = "file")
DOC_FENCE_CLOSE :: "\n```\n"
@(private = "file")
DOC_SECTION_RULE :: "\n---\n\n"

// Builds a Markdown documentation page for one package directory, rendered the
// way OLS shows documentation: every public top-level declaration across the
// package's .odin files (an Odin package is one flat directory), each as a
// ```odin-fenced signature followed by its cleaned doc-comment prose, sorted by
// name. Fills res.doc; ok when the package had at least one public symbol.
@(private = "file")
render_package_doc :: proc(e: ^Odin_Engine, parser: ts.Parser, req: ^Request, dir: string, res: ^Result) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)
    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    entries := make([dynamic]Doc_Entry, context.temp_allocator)
    pkg_name := ""
    pkg_doc := ""
    for info in infos {
        if request_cancelled(req) {
            return // a half-rendered page is worse than none
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        // Test files pad the package with @(test) procs that aren't API surface.
        if strings.has_suffix(info.name, "_test.odin") {
            continue
        }
        data, rerr := os.read_entire_file(info.fullpath, context.temp_allocator)
        if rerr != nil {
            continue
        }
        source := string(data)
        if pkg_name == "" {
            if n, off, nok := package_clause(source); nok {
                pkg_name = n
                pkg_doc = doc_prose_above(source, off) // the comment above `package X`
            }
        }
        tree := ts.parser_parse_string(parser, source)
        if tree == nil {
            continue
        }
        defs := collect_defs(e, ts.tree_root_node(tree), source)
        for d in defs {
            if !d.top_level || !symbol_kind_shown(d.kind) || !decl_is_public(source, d) {
                continue
            }
            append(&entries, Doc_Entry {
                name      = d.name,
                signature = decl_doc_text(source, d),
                doc       = doc_prose_above(source, d.decl_start),
            })
        }
        ts.tree_delete(tree)
    }

    if pkg_name == "" {
        pkg_name = filepath.base(dir)
    }
    slice.sort_by(entries[:], proc(a, b: Doc_Entry) -> bool {
        return a.name < b.name
    })

    page := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&page, "# package %s\n\n", pkg_name)
    fmt.sbprintf(&page, "`%s` — %d symbol%s\n", dir, len(entries), len(entries) == 1 ? "" : "s")
    if pkg_doc != "" {
        fmt.sbprintf(&page, "\n%s\n", pkg_doc)
    }
    for entry in entries {
        fmt.sbprintf(&page, "\n## %s\n\n", entry.name)
        strings.write_string(&page, DOC_FENCE_OPEN)
        strings.write_string(&page, entry.signature)
        strings.write_string(&page, DOC_FENCE_CLOSE)
        if entry.doc != "" {
            strings.write_string(&page, DOC_SECTION_RULE)
            strings.write_string(&page, entry.doc)
            strings.write_byte(&page, '\n')
        }
    }

    res.doc = Doc_Info {
        title = strings.concatenate({"package ", pkg_name}),
        path  = strings.clone(dir),
        text  = strings.clone(strings.to_string(page)),
    }
    res.ok = len(entries) > 0
}

// The name and line offset of a file's `package X` clause, scanning lines until
// it finds one (blank lines and comments precede it). The offset is the start of
// the package line, so doc_prose_above reads the package's own doc comment.
@(private = "file")
package_clause :: proc(source: string) -> (name: string, offset: int, ok: bool) {
    i := 0
    for i < len(source) {
        line_start := i
        line_end := i
        for line_end < len(source) && source[line_end] != '\n' {
            line_end += 1
        }
        t := strings.trim_space(source[line_start:line_end])
        if strings.has_prefix(t, "package") && len(t) > 7 && (t[7] == ' ' || t[7] == '\t') {
            rest := strings.trim_left_space(t[7:])
            end := 0
            for end < len(rest) && is_ident_byte(rest[end]) {
                end += 1
            }
            if end > 0 {
                return rest[:end], line_start, true
            }
        }
        i = line_end + 1
    }
    return "", 0, false
}

// True when the declaration is package-public: no `@(private)` (in any form)
// among the attributes the declaration carries before its identifier.
@(private = "file")
decl_is_public :: proc(source: string, d: Def) -> bool {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.ident_start, start, len(source))
    return !strings.contains(source[start:end], "private")
}

// The doc comment directly above the line at `offset`, cleaned into prose the way
// OLS's get_comment does: the contiguous run of `//` lines above it, each with its
// `//` (and one following space) stripped and joined by newlines. Stops at a blank
// or non-comment line. "" when there is no comment. Temp-allocated.
@(private = "file")
doc_prose_above :: proc(source: string, offset: int) -> string {
    decl_line := line_start_before(source, offset)
    block_start := decl_line
    for block_start > 0 {
        prev_line := line_start_before(source, block_start - 1)
        line := source[prev_line:block_start - 1] // excludes the '\n' at block_start-1
        if strings.has_prefix(strings.trim_left_space(line), "//") {
            block_start = prev_line
        } else {
            break
        }
    }
    if block_start >= decl_line {
        return ""
    }

    b := strings.builder_make(context.temp_allocator)
    first := true
    it := source[block_start:decl_line]
    for raw in strings.split_lines_iterator(&it) {
        t := strings.trim_left_space(raw)
        if !strings.has_prefix(t, "//") {
            continue // the trailing empty split, or a stray non-comment line
        }
        t = t[2:]                             // strip the `//`
        t = strings.trim_prefix(t, " ")       // and the one conventional space after it
        if !first {
            strings.write_byte(&b, '\n')
        }
        strings.write_string(&b, t)
        first = false
    }
    return strings.to_string(b)
}

// Start byte of the line containing byte `i` (the byte after the preceding '\n').
@(private = "file")
line_start_before :: proc(source: string, i: int) -> int {
    j := clamp(i, 0, len(source))
    for j > 0 && source[j - 1] != '\n' {
        j -= 1
    }
    return j
}

// The declaration text shown on a doc page: the whole declaration (including any
// leading `@(...)` attribute), with a procedure's body dropped after the opening
// brace, trimmed. A slice into `source` (no allocation) so it can be appended to
// the page builder, which copies it.
@(private = "file")
decl_doc_text :: proc(source: string, d: Def) -> string {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := source[start:end]
    if d.kind == "function" {
        if brace := strings.index_byte(text, '{'); brace >= 0 {
            text = text[:brace]
        }
    }
    return strings.trim_space(text)
}

// True for bytes that may appear in an Odin identifier.
@(private = "file")
is_ident_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

// Fuzzy closeness of a file stem to the package name, higher is closer. A shared
// prefix and contiguous runs score highest, and a full subsequence match adds a
// bonus; when the package name isn't even a subsequence the shared-prefix length
// still orders the candidates, so the package-operand fallback always lands on
// the most package-like file (`foo_windows` over `zebra` for package `foo`).
@(private = "file")
pkg_file_score :: proc(stem, pkg: string) -> int {
    score := 0

    n := min(len(stem), len(pkg))
    prefix := 0
    for prefix < n && ascii_lower(stem[prefix]) == ascii_lower(pkg[prefix]) {
        prefix += 1
    }
    score += prefix * 8

    // Subsequence of pkg within stem, rewarding contiguous runs.
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
        score += 20 // the whole package name is present in order
    }

    score -= abs(len(stem) - len(pkg)) / 4 // prefer a similar length
    return score
}

@(private = "file")
ascii_lower :: proc(b: u8) -> u8 {
    return b >= 'A' && b <= 'Z' ? b + 32 : b
}
