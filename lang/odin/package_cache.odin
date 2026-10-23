package odin

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Number of package directories the engine keeps.
@(private)
PACKAGE_CACHE_SLOTS :: 16

// The item trees and package scopes of recent package directories, refreshed by stat.
// A caller holds the mutex while it reads an entry.
@(private)
Package_Cache :: struct {
    mutex:   sync.Mutex,
    alloc:   runtime.Allocator,
    entries: [dynamic]^Package_Entry, // owned; least recently used first
}

@(private)
Package_Entry :: struct {
    key:        string,                           // owned; path_key of the directory
    dir:        string,                           // owned; the directory as first asked for
    files:      [dynamic]Package_Entry_File,      // owned; sorted by path
    sema_files: [dynamic]odinsema.Package_File,   // owned; borrows the paths and trees of `files`
    scope:      odinsema.Package_Scope,           // owned; valid when has_scope
    has_scope:  bool,
    target:     string,                           // owned; target_key of the scope
}

@(private)
Package_Entry_File :: struct {
    path:     string, // owned
    key:      string, // owned; path_key of the path
    modtime:  i64,
    size:     i64,
    items:    ^odinsema.Item_Tree, // owned; nil when the file cannot be read
    lines:    []int,               // owned; byte offset of each line start
    in_build: bool,
}

// The entry of `dir`, brought in step with the disk and built for `target`; nil when the directory
// cannot be read or the request is cancelled. The caller holds the mutex.
@(private)
package_cache_ensure :: proc(c: ^Package_Cache, dir: string, target: odinsema.Target, req: ^lang.Request) -> ^Package_Entry {
    if dir == "" || lang.request_cancelled(req) {
        return nil
    }
    key := path_key(dir)
    entry: ^Package_Entry
    for candidate, i in c.entries {
        if candidate.key == key {
            entry = candidate
            ordered_remove(&c.entries, i)
            break
        }
    }
    if entry == nil {
        entry = package_entry_new(c, key, dir)
        if entry == nil {
            return nil
        }
    }
    if _, err := append(&c.entries, entry); err != nil {
        package_entry_free(c, entry)
        return nil
    }
    for len(c.entries) > PACKAGE_CACHE_SLOTS {
        old := c.entries[0]
        ordered_remove(&c.entries, 0)
        package_entry_free(c, old)
    }

    changed, ok := package_entry_sync(c, entry, req)
    if !ok {
        package_entry_drop_scope(c, entry)
        return nil
    }
    tkey := target_key(target)
    if entry.has_scope && !changed && entry.target == tkey {
        return entry
    }
    package_entry_drop_scope(c, entry)
    for &f in entry.files {
        f.in_build = f.items != nil && odinsema.file_in_build(f.path, f.items.tags, target)
        append(&entry.sema_files, odinsema.Package_File{f.path, f.items})
    }
    scope, err := odinsema.package_scope(entry.sema_files[:], target, c.alloc)
    if err != nil {
        package_entry_drop_scope(c, entry)
        return nil
    }
    entry.scope = scope
    entry.has_scope = true
    entry.target = strings.clone(tkey, c.alloc)
    return entry
}

@(private = "file")
package_entry_new :: proc(c: ^Package_Cache, key, dir: string) -> ^Package_Entry {
    entry, err := new(Package_Entry, c.alloc)
    if err != nil {
        return nil
    }
    entry.key = strings.clone(key, c.alloc)
    entry.dir = strings.clone(dir, c.alloc)
    entry.files = make([dynamic]Package_Entry_File, c.alloc)
    entry.sema_files = make([dynamic]odinsema.Package_File, c.alloc)
    return entry
}

// Reads the files of the directory that are new or changed by stat and drops the gone ones.
// `changed` is true when the file set or a file moved; `ok` false when the directory cannot be
// read or the request was cancelled.
@(private = "file")
package_entry_sync :: proc(c: ^Package_Cache, entry: ^Package_Entry, req: ^lang.Request) -> (changed, ok: bool) {
    handle, open_err := os.open(entry.dir)
    if open_err != nil {
        return false, false
    }
    defer os.close(handle)
    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return false, false
    }
    slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
        return a.fullpath < b.fullpath
    })

    next := make([dynamic]Package_Entry_File, c.alloc)
    cancelled := false
    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if lang.request_cancelled(req) {
            cancelled = true
            break
        }
        mt := info.modification_time._nsec
        reused := false
        for &old in entry.files {
            if old.path == info.fullpath && old.modtime == mt && old.size == info.size {
                if _, err := append(&next, old); err == nil {
                    old = {}
                    reused = true
                }
                break
            }
        }
        if reused {
            continue
        }
        changed = true
        if f, fok := package_file_read(c, info.fullpath, mt, info.size); fok {
            if _, err := append(&next, f); err != nil {
                package_file_free(c, f)
            }
        }
    }
    for f in entry.files {
        if f.path != "" {
            changed = true
            package_file_free(c, f)
        }
    }
    delete(entry.files)
    entry.files = next
    return changed, !cancelled
}

// Reads one file. A file that cannot be read or parsed keeps a nil item tree.
@(private = "file")
package_file_read :: proc(c: ^Package_Cache, path: string, modtime, size: i64) -> (Package_Entry_File, bool) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    f := Package_Entry_File{modtime = modtime, size = size}
    f.path = strings.clone(path, c.alloc)
    f.key = strings.clone(path_key(path), c.alloc)
    if f.path == "" || f.key == "" {
        package_file_free(c, f)
        return {}, false
    }
    source, ok := lang.source_read(path)
    if !ok {
        return f, true
    }
    parsed, err := odinsyntax.parse(source)
    if err != nil {
        return f, true
    }
    f.items, _ = odinsema.item_tree(parsed, c.alloc)
    odinsyntax.parse_destroy(&parsed)
    if f.items != nil {
        f.lines = slice.clone(line_starts(source), c.alloc)
    }
    return f, true
}

@(private = "file")
package_file_free :: proc(c: ^Package_Cache, f: Package_Entry_File) {
    odinsema.item_tree_destroy(f.items, c.alloc)
    delete(f.lines, c.alloc)
    delete(f.path, c.alloc)
    delete(f.key, c.alloc)
}

@(private = "file")
package_entry_drop_scope :: proc(c: ^Package_Cache, entry: ^Package_Entry) {
    if entry.has_scope {
        odinsema.package_scope_destroy(&entry.scope)
        entry.has_scope = false
    }
    clear(&entry.sema_files)
    delete(entry.target, c.alloc)
    entry.target = ""
}

@(private = "file")
package_entry_free :: proc(c: ^Package_Cache, entry: ^Package_Entry) {
    package_entry_drop_scope(c, entry)
    delete(entry.sema_files)
    for f in entry.files {
        package_file_free(c, f)
    }
    delete(entry.files)
    delete(entry.key, c.alloc)
    delete(entry.dir, c.alloc)
    free(entry, c.alloc)
}

@(private = "file")
target_key :: proc(target: odinsema.Target) -> string {
    return odinsema.target_key(target)
}

@(private)
package_cache_clear :: proc(c: ^Package_Cache) {
    for entry in c.entries {
        package_entry_free(c, entry)
    }
    delete(c.entries)
    c.entries = nil
}
