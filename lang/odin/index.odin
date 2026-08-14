// The resident symbol index: top-level declarations of every workspace file,
// kept across requests and refreshed by stat, so a cross-file lookup re-parses
// only what changed.
package odin

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// A resident top-level declaration: self-owned copies (the parse tree and its
// source are long gone by the time a query reads this) plus the jump target.
// Mirrors the lang.Symbol row a query returns, minus the path (the File_Entry key).
@(private)
Index_Symbol :: struct {
    name:       string,
    kind:       string,
    signature:  string,
    line:       int,
    offset:     int,
    visibility: Visibility, // how far outside its own file this row can be named
    overload:   bool, // a procedure group, whose members go-to-definition reaches through to
}

// One indexed file: its top-level declarations, the set of every identifier name
// it mentions (the reference-scan filter — a file whose `idents` lacks a name
// can't contain a usage, so it is never re-parsed for that search), and the stat
// used to notice it changed, so an unchanged file is never re-parsed at all.
@(private)
File_Entry :: struct {
    modtime: i64,
    size:    i64,
    decls:   [dynamic]Index_Symbol,
    idents:  map[string]bool, // unique identifier names, engine-owned keys
}

// A workspace-wide store of parsed top-level declarations, resident across
// requests so a cross-file lookup re-parses only the files that changed. Guarded
// by its own mutex; every owned field uses `alloc`, the engine's allocator, never
// the per-request Manager one that query results clone into.
@(private)
Symbol_Index :: struct {
    mutex:  sync.Mutex,
    files:  map[string]File_Entry, // keyed by the path exactly as os.read_dir spells it
    root:   string,                // the workspace this was built for
    built:  bool,
    walked: time.Time,             // when the last complete walk ended; zero when none has
    alloc:  runtime.Allocator,
}

// How long a walk of the workspace stands for the requests that fire while the
// user types: they ask again on the next keystroke, so re-stat'ing thousands of
// files for each one buys nothing. Every other kind walks, and a save
// invalidates through index_forget.
@(private)
INDEX_WALK_INTERVAL :: 1 * time.Second

// Kinds that redraw as the user types rather than answering a question the user
// waits on, and so accept an index up to INDEX_WALK_INTERVAL old. Completion is
// deliberately absent: a cross-file candidate list must show what the last
// request would have found.
@(private)
INDEX_TYPING_KINDS :: bit_set[lang.Request_Kind]{.Signature_Help, .Semantic_Tokens}

// Ensures the index reflects `req.workspace` on disk: a full rebuild when the
// workspace changed, otherwise a re-`read_dir` that re-parses only the files
// whose stat differs and prunes the ones that vanished. Index storage lands in
// the engine allocator; the caller holds e.index.mutex.
//
// A cancelled request abandons the walk part-way, leaving the index stale but
// never wrong. The prune is skipped then: `seen` is incomplete, so pruning
// against it would drop live files.
@(private)
index_sync :: proc(e: ^Engine, parser: ts.Parser, req: ^lang.Request) {
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
    } else if req.kind in INDEX_TYPING_KINDS &&
       idx.walked != {} &&
       time.since(idx.walked) < INDEX_WALK_INTERVAL {
        return
    }

    seen := make(map[string]bool, 0, context.temp_allocator)
    count := 0
    index_sync_dir(e, parser, req, workspace, &seen, &count, 0)
    if lang.request_cancelled(req) {
        return // stale, never wrong — and unstamped, so the next sync walks
    }
    idx.walked = time.now()

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

@(private)
index_sync_dir :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    dir: string,
    seen: ^map[string]bool,
    count: ^int,
    depth: int,
) {
    if count^ >= SCAN_FILE_LIMIT || depth > SCAN_DEPTH_LIMIT || lang.request_cancelled(req) {
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
        if count^ >= SCAN_FILE_LIMIT || lang.request_cancelled(req) {
            return
        }
        if info.type == .Directory {
            if strings.has_prefix(info.name, ".") {
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
@(private)
index_reparse :: proc(e: ^Engine, parser: ts.Parser, key: string, modtime, size: i64) {
    idx := &e.index

    source, sok := source_read(key)
    if !sok {
        return
    }

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
            name       = strings.clone(d.name),
            kind       = strings.clone(d.kind),
            signature  = signature_text(source, d), // clones into context.allocator
            line       = strings.count(source[:ident_start], "\n") + 1,
            offset     = d.ident_start,
            visibility = d.visibility,
            overload   = d.overload,
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
@(private)
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

// Cross-file goto: appends every indexed top-level declaration named `name` to
// res.symbols as picker candidates, sorted by path, excluding the live file
// `skip` that was already searched lexically. `dir` narrows to one package, ""
// searches the workspace. Owned strings clone into context.allocator; caller
// holds the mutex. Reports whether the *only* match is a procedure group, so the
// caller can reach through to its members; meaningless when several files
// declare the name, which goes to the picker as it is.
@(private)
index_find_defs :: proc(
    e: ^Engine,
    name, skip, dir: string,
    same_package: bool,
    res: ^lang.Result,
) -> (single_overload: bool) {
    for path, entry in e.index.files {
        if path_equal(path, skip) || !index_scoped(path, dir) {
            continue
        }
        for sym in entry.decls {
            if sym.name != name || !def_reaches(sym.visibility, same_package) {
                continue
            }
            single_overload = sym.overload // only read when this is the one row
            append(&res.symbols, index_symbol_row(sym, path))
        }
    }
    slice.sort_by(res.symbols[:], proc(a, b: lang.Symbol) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    return single_overload && len(res.symbols) == 1
}

// Workspace symbols: appends every indexed declaration of an outline kind whose
// name matches `query` (empty matches everything), excluding the live file
// `skip` the caller already collected from the unsaved buffer. Visibility is
// deliberately not applied — Ctrl+Q is navigation, so a `@(private)` declaration
// is still a place to jump to.
@(private)
index_all_symbols :: proc(e: ^Engine, skip, query: string, res: ^lang.Result) {
    for path, entry in e.index.files {
        if path_equal(path, skip) {
            continue
        }
        for sym in entry.decls {
            if !symbol_kind_shown(sym.kind) || !lang.symbol_matches(query, sym.name) {
                continue
            }
            append(&res.symbols, index_symbol_row(sym, path))
        }
    }
}

// Adds every top-level declaration name in the workspace to `out` — the semantic
// classifier's "is this declared anywhere" test, asked once per request so the
// walk that follows needs no lock. Reports whether the index held any file at
// all, which must not be read as "nothing is declared". Keys clone into `alloc`,
// since another worker may reparse an entry and free its strings the moment the
// mutex drops. Caller holds the mutex.
@(private)
index_declared_names :: proc(e: ^Engine, out: ^map[string]bool, alloc: runtime.Allocator) -> bool {
    any_file := false
    for _, entry in e.index.files {
        any_file = true
        for sym in entry.decls {
            if sym.name not_in out {
                out[strings.clone(sym.name, alloc)] = true
            }
        }
    }
    return any_file
}

// Lexicographically-smallest indexed file declaring `name` (of `kind_filter`, or
// any kind when it is ""), excluding `skip` and confined to the package `dir`
// when one is given (see index_scoped). Deterministic first-hit for hover
// and signature help, which then re-parse just that one file for full detail.
@(private)
index_first_path :: proc(
    e: ^Engine,
    name, skip, kind_filter, dir: string,
    same_package: bool,
) -> (string, bool) {
    best := ""
    found := false
    for path, entry in e.index.files {
        if path_equal(path, skip) || !index_scoped(path, dir) {
            continue
        }
        for sym in entry.decls {
            if sym.name != name || (kind_filter != "" && sym.kind != kind_filter) {
                continue
            }
            if !def_reaches(sym.visibility, same_package) {
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

// Appends the path of every indexed file that mentions `name` to `out`, cloned
// into `out`'s allocator so it survives the mutex being dropped. Files whose
// `idents` lack the name are skipped, so the reference scan re-parses only real
// candidates. A `skip` that fails to match its file would list the live buffer's
// usages twice.
@(private)
index_ref_files :: proc(e: ^Engine, name, skip: string, out: ^[dynamic]string) {
    for path, entry in e.index.files {
        if path_equal(path, skip) {
            continue
        }
        if name in entry.idents {
            append(out, strings.clone(path, out.allocator))
        }
    }
}

// Completion: appends the indexed top-level declarations of the files sitting
// directly in `dir` (a package is one flat directory), excluding `skip` and
// filtered by `prefix`. Reports whether the directory held any indexed file —
// false means it lies outside the workspace (a stdlib or collection package) and
// the caller reads it off disk. Caller holds the mutex; result strings clone into
// context.allocator and dedup keys into scratch, so nothing borrows an index row
// past the unlock.
@(private)
index_dir_completions :: proc(
    e: ^Engine,
    dir, prefix, skip: string,
    same_package: bool,
    res: ^lang.Result,
    seen: ^map[string]bool,
) -> bool {
    indexed := false
    for path, entry in e.index.files {
        if !path_in_dir(path, dir) {
            continue
        }
        indexed = true
        if path_equal(path, skip) {
            continue
        }
        for sym in entry.decls {
            if !symbol_kind_shown(sym.kind) || !completion_matches(sym.name, prefix) {
                continue
            }
            if !def_reaches(sym.visibility, same_package) {
                continue
            }
            if sym.name in seen^ {
                continue
            }
            seen^[strings.clone(sym.name, context.temp_allocator)] = true
            append(&res.symbols, lang.Symbol {
                name      = strings.clone(sym.name),
                kind      = strings.clone(sym.kind),
                signature = strings.clone(sym.signature),
            })
        }
    }
    return indexed
}

// Whether an index row at `path` is in scope for a query confined to the package
// `dir`. An empty `dir` means the whole workspace, which is what every query that
// is genuinely workspace-wide (Ctrl+Q, the widened fallbacks) passes.
@(private)
index_scoped :: proc(path, dir: string) -> bool {
    return dir == "" || path_in_dir(path, dir)
}

// Whether `path` names a file directly inside `dir` — same prefix, one
// separator, nothing nested further. `/` and `\` compare equal, and on Windows
// so do the two cases of a letter, since the index keys os.read_dir's spellings
// and callers pass filepath.dir's. Otherwise literal: a spelling that does not
// line up just misses, and every caller widens or falls back to disk.
@(private)
path_in_dir :: proc(path, dir: string) -> bool {
    if dir == "" || len(path) <= len(dir) + 1 {
        return false
    }
    for i in 0 ..< len(dir) {
        a, b := path_byte(path[i]), path_byte(dir[i])
        if a != b {
            return false
        }
    }
    if !is_path_sep(path[len(dir)]) {
        return false
    }
    return strings.index_any(path[len(dir) + 1:], "/\\") < 0
}

// One path byte normalized for comparison: either separator reads as `/`, and on
// Windows an upper-case letter reads as its lower-case.
@(private)
path_byte :: proc(b: u8) -> u8 {
    if is_path_sep(b) {
        return '/'
    }
    when ODIN_OS == .Windows {
        if b >= 'A' && b <= 'Z' {
            return b + 32
        }
    }
    return b
}

@(private)
is_path_sep :: proc(b: u8) -> bool {
    return b == '/' || b == '\\'
}

// The directory a package-scoped query should filter on for the file at `path`.
// A bare identifier never names a declaration in another directory, so the
// cross-file consumers query this dir first and widen to the workspace only when
// the package declares nothing of the name. The returned dir is the spelling the
// index keys that file's siblings under — the literal dir when the index holds a
// file in it, the absolute form otherwise — since a spelling that does not line
// up would scope every lookup to an empty set. Never fails: an unmatched path
// keeps its own dir and simply finds nothing. Caller holds the mutex.
@(private)
index_package_dir :: proc(e: ^Engine, path: string) -> string {
    dir := filepath.dir(path) // a slice of `path`, no allocation
    if index_dir_populated(e, dir) {
        return dir
    }
    if abs, err := filepath.abs(dir, context.temp_allocator); err == nil && abs != dir {
        if index_dir_populated(e, abs) {
            return abs
        }
    }
    // Neither the literal nor the absolute spelling line up — a symlink, a
    // junction, or (on Windows) an 8.3 short name in `dir`. Resolve `dir` to
    // what the OS considers the same file as every index entry, and see if any
    // of them resolve the same way.
    if real, ok := path_real(dir, context.temp_allocator); ok {
        if found_dir, found := index_dir_real_match(e, real); found {
            return found_dir
        }
    }
    return dir
}

@(private = "file")
index_dir_populated :: proc(e: ^Engine, dir: string) -> bool {
    for path in e.index.files {
        if path_in_dir(path, dir) {
            return true
        }
    }
    return false
}

// Tier 3 of index_package_dir: resolves each distinct index directory with
// path_real and compares against `real`. Reached only once the literal and
// filepath.abs tiers have both missed, so the extra open-and-query calls are paid
// on a genuine spelling mismatch. Returns the index's own spelling, which is what
// path_in_dir keys off.
@(private = "file")
index_dir_real_match :: proc(e: ^Engine, real: string) -> (dir: string, found: bool) {
    seen := make(map[string]bool, 0, context.temp_allocator)
    for path in e.index.files {
        candidate := filepath.dir(path) // a slice of `path`, no allocation
        if candidate in seen {
            continue
        }
        seen[candidate] = true
        if candidate_real, ok := path_real(candidate, context.temp_allocator); ok && path_equal(candidate_real, real) {
            return candidate, true
        }
    }
    return "", false
}

// A lang.Symbol result row copied out of the index, cloned into context.allocator.
@(private)
index_symbol_row :: proc(sym: Index_Symbol, path: string) -> lang.Symbol {
    return lang.Symbol {
        name      = strings.clone(sym.name),
        kind      = strings.clone(sym.kind),
        signature = strings.clone(sym.signature),
        path      = strings.clone(path),
        line      = sym.line,
        offset    = sym.offset,
    }
}

// Frees one entry's owned decl strings and the decls array (engine allocator).
@(private)
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

// Drops one file's entry so the next sync re-parses it, whatever its stat says.
// A save bumps the modification time, so the stat gate catches it on its own on
// a normal file system; this covers a coarse-timestamp one, where two saves
// inside one tick read as no change. Main thread, under the index mutex.
index_forget :: proc(e: ^Engine, path: string) {
    idx := &e.index
    // Main thread, which must not stall behind a worker's whole index build. A
    // dropped invalidation costs nothing: the stat gate still catches the save.
    if !sync.mutex_try_lock(&idx.mutex) {
        return
    }
    defer sync.unlock(&idx.mutex)
    // The key is spelled as os.read_dir gave it, which need not match the
    // editor's spelling of the same file.
    for key, entry in idx.files {
        if !path_equal(key, path) {
            continue
        }
        index_free_entry(idx, entry)
        delete_key(&idx.files, key)
        delete(key, idx.alloc)
        // The entry is gone, so the next sync must walk to find the file again,
        // however recently one ran.
        idx.walked = {}
        return
    }
}

// Tears the whole index down (on destroy, or before a rebuild for a new
// workspace): frees every entry, every owned key, the map, and the root string.
@(private)
index_clear :: proc(e: ^Engine) {
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
    idx.walked = {}
}
