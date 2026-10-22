package odin

import "base:runtime"
import "core:strings"
import "core:sync"

import odinsyntax "syntax"

// Number of buffers whose last parse the engine keeps.
PARSE_CACHE_SLOTS :: 8

// The last parse of each recent buffer, so the next request parses only what changed.
// A request takes its entry out and puts it back, so no two workers share a tree.
Parse_Cache :: struct {
    mutex:   sync.Mutex,
    alloc:   runtime.Allocator,
    entries: [dynamic]Parse_Entry, // owned; least recently used first
}

Parse_Entry :: struct {
    path:  string,           // owned
    parse: odinsyntax.Parse, // owned
}

// The parse of `source`, from the cached parse of `path` when there is one. The caller owns it
// and gives it back with parse_cache_put.
parse_cache_get :: proc(c: ^Parse_Cache, path, source: string) -> (odinsyntax.Parse, bool) {
    old, found := parse_cache_take(c, path)
    if !found {
        parsed, err := odinsyntax.parse(source, c.alloc)
        return parsed, err == nil
    }
    parsed, _, err := odinsyntax.reparse(&old, source, c.alloc)
    if err != nil {
        odinsyntax.parse_destroy(&old, c.alloc)
        return {}, false
    }
    return parsed, true
}

// Removes the cached parse of `path` and gives it to the caller.
@(private = "file")
parse_cache_take :: proc(c: ^Parse_Cache, path: string) -> (odinsyntax.Parse, bool) {
    sync.lock(&c.mutex)
    defer sync.unlock(&c.mutex)
    for entry, i in c.entries {
        if entry.path == path {
            ordered_remove(&c.entries, i)
            delete(entry.path, c.alloc)
            return entry.parse, true
        }
    }
    return {}, false
}

// Stores `parsed` as the latest parse of `path`, and destroys the least recently used one past PARSE_CACHE_SLOTS.
parse_cache_put :: proc(c: ^Parse_Cache, path: string, parsed: odinsyntax.Parse) {
    parsed := parsed
    key, err := strings.clone(path, c.alloc)
    if err != nil {
        odinsyntax.parse_destroy(&parsed, c.alloc)
        return
    }
    sync.lock(&c.mutex)
    defer sync.unlock(&c.mutex)
    // A request that ran beside this one may have put its parse back first.
    for &entry, i in c.entries {
        if entry.path == path {
            odinsyntax.parse_destroy(&entry.parse, c.alloc)
            delete(entry.path, c.alloc)
            ordered_remove(&c.entries, i)
            break
        }
    }
    if _, aerr := append(&c.entries, Parse_Entry{key, parsed}); aerr != nil {
        delete(key, c.alloc)
        odinsyntax.parse_destroy(&parsed, c.alloc)
        return
    }
    for len(c.entries) > PARSE_CACHE_SLOTS {
        entry := c.entries[0]
        ordered_remove(&c.entries, 0)
        odinsyntax.parse_destroy(&entry.parse, c.alloc)
        delete(entry.path, c.alloc)
    }
}

parse_cache_clear :: proc(c: ^Parse_Cache) {
    for &entry in c.entries {
        odinsyntax.parse_destroy(&entry.parse, c.alloc)
        delete(entry.path, c.alloc)
    }
    delete(c.entries)
    c.entries = nil
}
