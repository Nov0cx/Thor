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

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// A resident top-level declaration: self-owned copies (the parse tree and its
// source are long gone by the time a query reads this) plus the jump target.
// Mirrors the lang.Symbol row a query returns, minus the path (the File_Entry key).
@(private)
Index_Symbol :: struct {
    name:      string,
    kind:      string,
    signature: string,
    line:      int,
    offset:    int,
    overload:  bool, // a procedure group, whose members go-to-definition reaches through to
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

// A workspace-wide store of parsed top-level declarations, resident on the
// engine across requests so a cross-file lookup re-parses only the files that
// changed rather than the whole tree. Guarded by its own mutex; every owned
// field uses `alloc` (the engine's allocator, captured at create), never the
// per-request Manager allocator that query results clone into.
@(private)
Symbol_Index :: struct {
    mutex: sync.Mutex,
    files: map[string]File_Entry, // keyed by the path exactly as os.read_dir spells it
    root:  string,                // the workspace this was built for
    built: bool,
    alloc: runtime.Allocator,
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
    }

    seen := make(map[string]bool, 0, context.temp_allocator)
    count := 0
    index_sync_dir(e, parser, req, workspace, &seen, &count, 0)
    if lang.request_cancelled(req) {
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
@(private)
index_reparse :: proc(e: ^Engine, parser: ts.Parser, key: string, modtime, size: i64) {
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
            overload  = d.overload,
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

// Cross-file goto: appends every indexed top-level declaration named `name`
// (excluding the live file `skip`, already searched lexically) to res.symbols as
// picker candidates, sorted by path for a stable order. `dir` narrows the search
// to one package (see index_scoped); "" searches the whole workspace. Owned
// strings clone into context.allocator (the Manager's, as resolve left it).
// Caller holds the mutex.
//
// Reports whether the *only* match is a procedure group, so the caller can reach
// through to its members instead of landing on the list. Meaningless when several
// files declare the name: that ambiguity goes to the picker as it is.
@(private)
index_find_defs :: proc(e: ^Engine, name, skip, dir: string, res: ^lang.Result) -> (single_overload: bool) {
    for path, entry in e.index.files {
        if path_equal(path, skip) || !index_scoped(path, dir) {
            continue
        }
        for sym in entry.decls {
            if sym.name != name {
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

// Workspace symbols: appends every indexed declaration of a shown kind (proc,
// type, enum, constant, var — the outline set), excluding the live file `skip`
// whose decls the caller already collected from the unsaved buffer.
@(private)
index_all_symbols :: proc(e: ^Engine, skip: string, res: ^lang.Result) {
    for path, entry in e.index.files {
        if path_equal(path, skip) {
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

// Adds every top-level declaration name in the workspace to `out`. The semantic
// classifier's "is this name declared anywhere" test, asked once per request
// rather than once per identifier so the walk that follows needs no lock.
// Reports whether the index held any file at all — a false says the index is
// empty, which must not be read as "nothing is declared".
//
// Keys clone into `alloc`: the index rows are engine-owned and another worker may
// reparse this entry and free its strings the moment the mutex drops. Caller
// holds the mutex.
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
index_first_path :: proc(e: ^Engine, name, skip, kind_filter, dir: string) -> (string, bool) {
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
// `skip` matters more here than elsewhere: the buffer was scanned already, and a
// spelling that failed to match it would list every one of its usages twice.
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
// directly in `dir` (a package is one flat directory), excluding the live file
// `skip` and filtered by `prefix`. Reports whether the directory held any indexed
// file at all — false means it lies outside the indexed workspace (a stdlib or
// collection package), and the caller falls back to reading it off disk. Caller
// holds the mutex; result strings clone into context.allocator (the Manager's),
// and the dedup keys into scratch, so nothing borrows an index row past the
// unlock — another worker may reparse this entry and free its strings.
@(private)
index_dir_completions :: proc(
    e: ^Engine,
    dir, prefix, skip: string,
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
// is genuinely workspace-wide (Ctrl+T, the widened fallbacks) passes.
@(private)
index_scoped :: proc(path, dir: string) -> bool {
    return dir == "" || path_in_dir(path, dir)
}

// Whether `path` names a file directly inside `dir` — same prefix, one separator,
// nothing further nested. `/` and `\` compare equal and, on Windows, so do the
// two cases of a letter: the index keys the spellings os.read_dir produced and
// the caller's come from filepath.dir, and neither the separator nor the case is
// something the filesystem distinguishes. The comparison is otherwise literal, so
// the usual canonicalization assumption applies. A spelling that doesn't line up
// just misses, and every caller widens or falls back to disk when it does — this
// can only cost speed, never candidates.
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
//
// **Why every bare-name lookup starts here.** A bare identifier in Odin names
// something in its own scope, its own file, its own *package* or the builtin
// set — never a declaration in another directory, which is reachable only
// through an import and a qualifier. A flat workspace match therefore answers
// with symbols the compiler would not even see: two packages each declaring
// `init` turned every goto on one into a picker over both. So the cross-file
// consumers (goto, hover, the type locator, signature help) query this directory
// first and only widen to the whole workspace when the package declares nothing
// of the name. Widening is a guess by then rather than a wrong answer — the
// correct one does not exist — and it keeps the reach the engine had for the
// cases it still cannot model, so a miss here costs precision, never candidates.
//
// The returned dir is the spelling the index actually keys that file's siblings
// under, which is the part that takes care: the request carries the path its file
// was opened with, the index the one os.read_dir produced. So the literal dir is
// taken when the index holds a file in it, and the absolute form tried only when
// it holds none — a package whose spelling doesn't line up would otherwise scope
// every lookup to an empty set and widen straight back to the flat scan, which is
// exactly the imprecision the scoping removes. Never fails: an unmatched path
// keeps its own dir, which simply finds nothing. Caller holds the mutex.
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
}
