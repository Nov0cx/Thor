// The implicit scope: what the toolchain declares into every Odin file with no
// import at all. A bare identifier reaches its own scope, its own file, its own
// package and this — and nothing else, since anything in another directory needs
// an import and a qualifier. So `len`, `append`, `make` and the rest are the only
// standard-library names a bare identifier can name, and they are answered here.
//
// Read off the compiler on disk rather than hardcoded: the set moves with the
// toolchain, and a list baked into this repo would rot the next time the language
// gains a builtin. Built once per process — it is a property of the installed
// compiler, not of the workspace — and never invalidated.
package odin

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// One name the toolchain declares, with enough about it to answer a completion
// row without touching the disk again and to point every other request at the
// single file it has to read.
@(private)
Builtin_Symbol :: struct {
    path:      string, // the file declaring it; borrowed from Builtin_Cache.files
    kind:      string, // LOCALS capture suffix, owned
    signature: string, // one-line declaration for a completion row, owned
    offset:    int,    // its declaring identifier, for a jump target
    line:      int,    // 1-based, for a picker row
    // Whether a *bare* name reaches it. Everything base:builtin documents is in
    // the universal scope; base:runtime is an ordinary package apart from the
    // declarations it marks `@(builtin)`, which the compiler injects into that
    // scope alongside them.
    implicit:  bool,
}

// `ok` false means the toolchain could not be read at all, which disables
// undeclared-name dimming rather than guessing (see dimming_allowed).
@(private)
Builtin_Cache :: struct {
    names: map[string]Builtin_Symbol, // engine-owned keys, alive for the process
    files: [dynamic]string,           // owns the paths the symbols point at
    built: bool,
    ok:    bool,
    alloc: runtime.Allocator,
}

// The packages the compiler puts in scope with no import, and whether *every*
// name in one is in that scope. base:builtin is pure documentation of the
// universal scope, so all of it is; base:runtime also holds the implementations,
// each marked `@(builtin)`, beside an ordinary package that must be imported.
@(private)
BUILTIN_PACKAGES :: [?]struct {
    path: string,
    all:  bool,
} {
    {"base:builtin", true},
    {"base:runtime", false},
}

// Adds every name the implicit scope declares to `declared`, building the cache
// on first call. False when the toolchain could not be read, which takes dimming
// with it. Keys are inserted borrowed — they belong to the engine and outlive the
// map. Deliberately unfiltered: a name base:runtime exports without the
// `@(builtin)` marker is not reachable bare, but over-permitting only ever costs
// a missed dim, where under-permitting flags correct code.
@(private)
builtin_names :: proc(e: ^Engine, parser: ts.Parser, declared: ^map[string]bool) -> bool {
    sync.lock(&e.builtin_mutex)
    defer sync.unlock(&e.builtin_mutex)

    builtins_ensure(e, parser)
    if !e.builtins.ok {
        return false
    }
    for name in e.builtins.names {
        declared[name] = true
    }
    return true
}

// The implicit-scope declaration of `name`, or false when nothing bare reaches
// it. The returned strings belong to the cache, which is never rebuilt and lives
// for the process, so the caller may hold them past the lock.
@(private)
builtin_symbol :: proc(e: ^Engine, parser: ts.Parser, name: string) -> (Builtin_Symbol, bool) {
    sync.lock(&e.builtin_mutex)
    defer sync.unlock(&e.builtin_mutex)

    builtins_ensure(e, parser)
    sym, found := e.builtins.names[name]
    if !found || !sym.implicit {
        return {}, false
    }
    return sym, true
}

// Go-to-definition and hover for a bare name the implicit scope declares. The
// cache names the one file to read; from there it is the ordinary cross-file
// path, so a builtin procedure group (`append`, `make`) offers its members like
// any other group and hover shows the whole declaration.
@(private)
resolve_builtin :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    name: string,
    hover_start, hover_end: int,
    res: ^lang.Result,
) {
    sym, ok := builtin_symbol(e, parser, name)
    if !ok {
        return
    }
    scan_file(e, parser, sym.path, req, name, hover_start, hover_end, res)
}

// Appends every implicit-scope name matching `prefix` as a completion candidate,
// de-duplicated against `seen`. Served entirely from the cache — completion fires
// per keystroke, and the standard library is not re-read for one. The rows come
// out in map order and are sorted by finish_completion with the rest.
@(private)
builtin_completions :: proc(
    e: ^Engine,
    parser: ts.Parser,
    prefix: string,
    res: ^lang.Result,
    seen: ^map[string]bool,
) {
    sync.lock(&e.builtin_mutex)
    defer sync.unlock(&e.builtin_mutex)

    builtins_ensure(e, parser)
    for name, sym in e.builtins.names {
        if !sym.implicit || !completion_matches(name, prefix) || name in seen^ {
            continue
        }
        seen^[name] = true
        append(&res.symbols, lang.Symbol {
            name      = strings.clone(name),
            kind      = strings.clone(sym.kind),
            signature = strings.clone(sym.signature),
        })
    }
}

// Fills the members of a procedure group the toolchain declares (`append`,
// `make`) from the cache, reporting whether the group is one of those at all. A
// group's members are declared beside it, so the cache already holds every one —
// and the walk this replaces would re-read `base:runtime` per request, on the
// per-keystroke signature path, for the most-typed group in the language. A
// member the cache doesn't hold is one the directory scan would not find either
// (written qualified, or declared elsewhere), so it stays unresolved.
@(private)
builtin_member_sites :: proc(e: ^Engine, parser: ts.Parser, group_path: string, sites: []Member_Site) -> bool {
    // A group outside the toolchain's own tree is never one of these, and asking
    // would build the whole cache to say so — every workspace group reaches here.
    // The cached paths were joined onto this root, so the spellings agree; if
    // they ever didn't the caller falls back to its directory scan, which is
    // slower and just as correct.
    root := odin_root()
    if root == "" || !strings.has_prefix(group_path, root) {
        return false
    }

    sync.lock(&e.builtin_mutex)
    defer sync.unlock(&e.builtin_mutex)

    builtins_ensure(e, parser)
    if !builtin_file(e, group_path) {
        return false
    }
    for &site in sites {
        if site.label != "" {
            continue
        }
        sym, found := e.builtins.names[site.name]
        if !found {
            continue
        }
        site.label = strings.clone(sym.signature) // owned by the caller, as the scan's is
        site.path = sym.path                      // the cache outlives the request
        site.offset = sym.offset
        site.line = sym.line
    }
    return true
}

// Whether `path` is one of the files the cache was built from — the exact
// spelling, since every caller got it from the cache in the first place. The
// caller holds builtin_mutex.
@(private = "file")
builtin_file :: proc(e: ^Engine, path: string) -> bool {
    for file in e.builtins.files {
        if file == path {
            return true
        }
    }
    return false
}

// Builds the cache on first use. The caller holds builtin_mutex.
@(private = "file")
builtins_ensure :: proc(e: ^Engine, parser: ts.Parser) {
    if e.builtins.built {
        return
    }
    build_builtin_cache(e, parser)
    e.builtins.built = true
}

// Reads every top-level declaration out of the builtin packages under ODIN_ROOT.
// `ok` stays false unless a package was actually read, so a missing or unreadable
// toolchain leaves the scope empty rather than guessed at.
@(private = "file")
build_builtin_cache :: proc(e: ^Engine, parser: ts.Parser) {
    context.allocator = e.builtins.alloc
    e.builtins.names = make(map[string]Builtin_Symbol)
    e.builtins.files = make([dynamic]string)

    for pkg in BUILTIN_PACKAGES {
        // No requesting file and no workspace: a `base:` path resolves off
        // ODIN_ROOT alone, so neither is consulted.
        dir, dok := package_dir(e, pkg.path, "", "")
        if !dok {
            continue
        }
        if collect_dir_decls(e, parser, dir, pkg.all) {
            e.builtins.ok = true
        }
    }
}

// Records the top-level declarations of every `.odin` file directly in `dir`,
// cloning each into the cache. `all` puts the whole package in the universal
// scope; otherwise only a declaration attributed `@(builtin)` is. The first name
// of a file wins, as the first file of a package does. Reports whether a file was
// read at all.
@(private = "file")
collect_dir_decls :: proc(e: ^Engine, parser: ts.Parser, dir: string, all: bool) -> bool {
    handle, oerr := os.open(dir)
    if oerr != nil {
        return false
    }
    defer os.close(handle)

    infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if rerr != nil {
        return false
    }

    read_any := false
    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if strings.has_suffix(info.name, "_test.odin") {
            continue
        }
        source, sok := source_read(info.fullpath)
        if !sok {
            continue
        }
        tree := ts.parser_parse_string(parser, source)
        if tree == nil {
            continue
        }
        defer ts.tree_delete(tree)
        read_any = true

        path := "" // cloned on the file's first symbol, shared by the rest
        for d in collect_defs(e, ts.tree_root_node(tree), source) {
            if !d.top_level || d.name == "" || d.name in e.builtins.names {
                continue
            }
            if path == "" {
                path = strings.clone(info.fullpath)
                append(&e.builtins.files, path)
            }
            e.builtins.names[strings.clone(d.name)] = Builtin_Symbol {
                path      = path,
                kind      = strings.clone(d.kind),
                signature = signature_text(source, d),
                offset    = d.ident_start,
                line      = strings.count(source[:clamp(d.ident_start, 0, len(source))], "\n") + 1,
                implicit  = symbol_kind_shown(d.kind) && (all || has_builtin_attribute(source, d)),
            }
        }
    }
    return read_any
}

// Whether a declaration carries the `@(builtin)` attribute that puts a
// base:runtime name in the universal scope. Read off the text between the
// declaration's start and its name, which is exactly its attribute list — both
// `@builtin` and `@(builtin, require_results)` spell the marker as an identifier
// there, and a declaration may carry several attribute lines.
@(private = "file")
has_builtin_attribute :: proc(source: string, d: Def) -> bool {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.ident_start, start, len(source))
    return contains_word(source[start:end], "builtin")
}

// `word` occurring in `text` on identifier boundaries, so an attribute naming a
// procedure (`@(deferred_none=end_builtin)`) doesn't read as the marker itself.
@(private = "file")
contains_word :: proc(text, word: string) -> bool {
    at := 0
    for at + len(word) <= len(text) {
        i := strings.index(text[at:], word)
        if i < 0 {
            return false
        }
        s := at + i
        e := s + len(word)
        if (s == 0 || !is_word_byte(text[s - 1])) && (e == len(text) || !is_word_byte(text[e])) {
            return true
        }
        at = e
    }
    return false
}

@(private)
builtins_clear :: proc(e: ^Engine) {
    for name, sym in e.builtins.names {
        delete(name, e.builtins.alloc)
        delete(sym.kind, e.builtins.alloc)
        delete(sym.signature, e.builtins.alloc)
    }
    delete(e.builtins.names)
    for path in e.builtins.files {
        delete(path, e.builtins.alloc)
    }
    delete(e.builtins.files)
    e.builtins = Builtin_Cache{alloc = e.builtins.alloc}
}
