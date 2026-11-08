// A cache of the identifier counts of disk files, keyed on the revision the sema db read them at.
package odin

import "core:strings"
import "core:sync"

import odinsema "sema"

// Most files the cache holds; a full cache is dropped whole.
@(private)
COUNT_CACHE_MAX :: 1024

// The uses of one name in a file.
@(private)
Name_Counts :: struct {
    free:      int,            // bare uses
    qualified: map[string]int, // `pkg.name` uses by package name; owned
}

// The name counts of one file text.
@(private)
File_Counts :: struct {
    changed_at: u64,                    // File_Data.changed_at the counts were built from
    names:      map[string]Name_Counts, // owned
}

// Per-file name counts. Guarded by `mutex`.
@(private)
Count_Cache :: struct {
    mutex:  sync.Mutex,
    files:  map[string]File_Counts, // by path key; owned
    builds: int,                    // files counted from a scope map, for tests
}

// Counts the free and package-qualified names of `m`. Strings are cloned.
@(private)
file_counts_build :: proc(m: ^odinsema.Scope_Map, changed_at: u64) -> File_Counts {
    fc := File_Counts{changed_at = changed_at}
    for ref in m.refs {
        if ref.kind != .Free && ref.kind != .Package_Qualified {
            continue
        }
        entry, found := &fc.names[ref.name]
        if !found {
            key := strings.clone(ref.name)
            fc.names[key] = {}
            entry = &fc.names[key]
        }
        if ref.kind == .Free {
            entry.free += 1
        } else if n, has := &entry.qualified[ref.operand]; has {
            n^ += 1
        } else {
            entry.qualified[strings.clone(ref.operand)] = 1
        }
    }
    return fc
}

@(private)
file_counts_destroy :: proc(fc: ^File_Counts) {
    for name, &entry in fc.names {
        for alias in entry.qualified {
            delete(alias)
        }
        delete(entry.qualified)
        delete(name)
    }
    delete(fc.names)
    fc^ = {}
}

// Stores `fc` under `key`, replacing an older entry. The cache owns `fc` afterwards.
// Caller holds the mutex.
@(private)
count_cache_put :: proc(c: ^Count_Cache, key: string, fc: File_Counts) {
    if old, found := &c.files[key]; found {
        file_counts_destroy(old)
        old^ = fc
        return
    }
    if len(c.files) >= COUNT_CACHE_MAX {
        count_cache_clear(c)
    }
    c.files[strings.clone(key)] = fc
}

// Drops every entry. Caller holds the mutex.
@(private)
count_cache_clear :: proc(c: ^Count_Cache) {
    for key, &fc in c.files {
        file_counts_destroy(&fc)
        delete(key)
    }
    clear(&c.files)
}

@(private)
count_cache_destroy :: proc(c: ^Count_Cache) {
    count_cache_clear(c)
    delete(c.files)
}
