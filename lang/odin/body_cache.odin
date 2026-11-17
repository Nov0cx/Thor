// A cache of the live body errors of each file-scope declaration, so an edit types only the declarations it changed.
package odin

import "core:hash"
import "core:mem"
import "core:strings"
import "core:sync"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Most files the cache holds; a full cache is dropped whole.
@(private)
BODY_CACHE_MAX :: 64

// One body error, at a byte offset from the start of its declaration.
@(private)
Body_Item :: struct {
    offset:   int,
    code:     string, // a static CODE_* literal
    message:  string, // owned
    severity: lang.Diagnostic_Severity,
    lint:     bool,
}

// The body errors of one file text. Valid while the configuration, the text outside the procedure
// bodies, the check settings and the inputs from other files are as they were.
@(private)
Body_File :: struct {
    config:   u32,
    outline:  u64,
    settings: u64,
    inputs:   odinsema.Checker_Inputs,
    granules: map[u64][]Body_Item, // by hash of the declaration text; owned
}

// Per-file body errors, by path key. Guarded by `mutex`; an entry is taken out while a request uses it.
@(private)
Body_Cache :: struct {
    mutex: sync.Mutex,
    files: map[string]^Body_File, // keys and values owned
    walks: int,                   // declarations walked, for tests; atomic
}

@(private)
body_items_destroy :: proc(items: []Body_Item) {
    for item in items {
        delete(item.message)
    }
    delete(items)
}

@(private)
body_file_destroy :: proc(f: ^Body_File) {
    if f == nil {
        return
    }
    for _, items in f.granules {
        body_items_destroy(items)
    }
    delete(f.granules)
    odinsema.checker_inputs_destroy(&f.inputs)
    free(f)
}

@(private)
body_cache_destroy :: proc(c: ^Body_Cache) {
    for key, f in c.files {
        delete(key)
        body_file_destroy(f)
    }
    delete(c.files)
    c.files = nil
}

// Takes the entry of `key` out of the cache. Nil when there is none.
@(private)
body_cache_take :: proc(c: ^Body_Cache, key: string) -> ^Body_File {
    sync.mutex_lock(&c.mutex)
    defer sync.mutex_unlock(&c.mutex)
    if key not_in c.files {
        return nil
    }
    stored, f := delete_key(&c.files, key)
    delete(stored)
    return f
}

// Puts `f` back under `key`. The cache owns `f` afterwards; an entry another request put there first is replaced.
@(private)
body_cache_put :: proc(c: ^Body_Cache, key: string, f: ^Body_File) {
    sync.mutex_lock(&c.mutex)
    defer sync.mutex_unlock(&c.mutex)
    if old, found := c.files[key]; found {
        body_file_destroy(old)
        c.files[key] = f
        return
    }
    if len(c.files) >= BODY_CACHE_MAX {
        for k, old in c.files {
            delete(k)
            body_file_destroy(old)
        }
        clear(&c.files)
    }
    c.files[strings.clone(key)] = f
}

// A hash of the buffer with every procedure body left out: the declarations, types, constants,
// imports, tags and `when` conditions a body may read.
@(private)
outline_hash :: proc(n: odinsyntax.Syntax_Node, src: string) -> u64 {
    h   := hash.fnv64a(nil)
    pos := 0
    outline_walk(n, src, &pos, &h)
    return hash.fnv64a(transmute([]byte)src[pos:], h)
}

@(private = "file")
outline_walk :: proc(n: odinsyntax.Syntax_Node, src: string, pos: ^int, h: ^u64) {
    n := n
    if n.green.kind == .Proc_Lit {
        pl, _ := odinsyntax.as_proc_lit(n)
        if body, has := odinsyntax.proc_lit_body(&pl); has {
            start, end := odinsyntax.node_range(body)
            if int(start) >= pos^ && int(end) <= len(src) {
                h^ = hash.fnv64a(transmute([]byte)src[pos^:start], h^)
                h^ = hash.fnv64a([]byte{0}, h^)
                pos^ = int(end)
            }
            return
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        outline_walk(child, src, pos, h)
    }
}

// A hash of the settings the body check reads.
@(private)
body_settings_hash :: proc(rc: ^Request_Context) -> u64 {
    Settings :: struct {
        naming:                          odinsema.Naming_Rules,
        vet:                             odinsema.Vet_Flags,
        own_leak, own_double, own_after: bool,
        in_build:                        bool,
    }
    s := Settings{rc.naming, rc.vet, rc.own_leak, rc.own_double, rc.own_after, rc.live.in_build}
    return hash.fnv64a(mem.any_to_bytes(s))
}

// Walks each file-scope declaration of the buffer, or reuses its errors when its text and the
// inputs it read are unchanged.
@(private)
body_walk_cached :: proc(
    rc: ^Request_Context,
    c: ^odinsema.Checker,
    m: ^odinsema.Scope_Map,
    whens: []Branch,
    root: odinsyntax.Syntax_Node,
    report: ^lang.Diagnostic_Report,
) {
    src     := rc.req.source
    key     := rc.live.key
    outline := outline_hash(root, src)
    entry   := body_cache_take(&rc.e.bodies, key)
    if entry != nil &&
        (entry.config != rc.snap.config ||
            entry.outline != outline ||
            entry.settings != body_settings_hash(rc) ||
            !odinsema.checker_inputs_valid(&rc.snap, &entry.inputs)) {
        body_file_destroy(entry)
        entry = nil
    }
    if entry == nil {
        entry = new(Body_File)
        entry.config = rc.snap.config
        entry.outline = outline
        entry.settings = body_settings_hash(rc)
    }
    granules := make(map[u64][]Body_Item)
    root     := root
    it       := odinsyntax.child_iter(&root, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        if lang.request_cancelled(rc.req) {
            break
        }
        start, end := odinsyntax.node_range(child)
        h          := hash.fnv64a(transmute([]byte)src[start:end])
        if items, found := entry.granules[h]; found {
            for item in items {
                report_error(rc, report, int(start) + item.offset, item.code, strings.clone(item.message), item.severity, item.lint)
            }
            granules[h] = items
            continue
        }
        if items, found := granules[h]; found {
            for item in items {
                report_error(rc, report, int(start) + item.offset, item.code, strings.clone(item.message), item.severity, item.lint)
            }
            continue
        }
        first := len(report.items)
        rc.read_formatters = false
        odinsema.checker_watch(c, int(start), int(end))
        walk_body(rc, c, m, whens, child, report)
        outside := odinsema.checker_watch_end(c)
        sync.atomic_add(&rc.e.bodies.walks, 1)
        if outside || rc.read_formatters || lang.request_cancelled(rc.req) {
            continue
        }
        items := make([]Body_Item, len(report.items) - first)
        for d, i in report.items[first:] {
            offset := rc.live.lines[d.line - 1] + d.col - 1
            items[i] = {offset - int(start), d.code, strings.clone(d.message), d.severity, d.lint}
        }
        granules[h] = items
    }
    for h, items in entry.granules {
        if h not_in granules {
            body_items_destroy(items)
        }
    }
    delete(entry.granules)
    entry.granules = granules
    if lang.request_cancelled(rc.req) || odinsema.checker_inputs_add(&entry.inputs, c) != nil {
        body_file_destroy(entry)
        return
    }
    body_cache_put(&rc.e.bodies, key, entry)
}
