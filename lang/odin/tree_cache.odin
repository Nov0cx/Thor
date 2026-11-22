package odin

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import "../../atomicfile"
import odinsema "sema"

// Number of new trees after which a request writes the tree cache.
@(private)
TREE_CACHE_BATCH :: 128

// The files that keep the item trees of the Odin root and of the open workspace across sessions.
@(private)
Tree_Cache_File :: struct {
    mutex:    sync.Mutex,
    writing:  bool, // atomic; one write at a time
    alloc:    runtime.Allocator,
    dir:      string, // owned; "" when the cache is off
    known:    bool,   // `key` and `path` were found and the blob was loaded
    key:      string, // owned; the Odin root and the stamp of its compiler
    path:     string, // owned; "" when the cache is off
    ws_known: bool,   // `ws_key` and `ws_path` were found and the workspace blob was loaded
    ws_key:   string, // owned; path_key of the workspace
    ws_path:  string, // owned
}

// Sets the directory of the tree cache; "" turns it off. Call it before the first request.
engine_set_cache_dir :: proc(e: ^Engine, dir: string) {
    c := &e.tree_cache
    sync.guard(&c.mutex)
    tree_cache_clear(c)
    c.dir = strings.clone(dir, c.alloc)
    odin_root_set_cache_dir(&e.root, dir)
}

@(private)
tree_cache_clear :: proc(c: ^Tree_Cache_File) {
    delete(c.dir, c.alloc)
    delete(c.key, c.alloc)
    delete(c.path, c.alloc)
    delete(c.ws_key, c.alloc)
    delete(c.ws_path, c.alloc)
    c.dir, c.key, c.path, c.ws_key, c.ws_path = "", "", "", "", ""
    c.known = false
    c.ws_known = false
}

// Loads the cache of the item trees of `workspace` once. Another workspace writes the cache of the
// one before and empties it first.
@(private)
workspace_cache_ensure :: proc(e: ^Engine, workspace: string) {
    if workspace == "" {
        return
    }
    key := odinsema.path_key(workspace)
    c   := &e.tree_cache
    sync.guard(&c.mutex)
    if c.dir == "" || c.ws_known && c.ws_key == key {
        return
    }
    if c.ws_known {
        // A write on another thread keeps the old cache as it was on disk.
        if _, ok := sync.atomic_compare_exchange_strong(&c.writing, false, true); ok {
            cache_file_write(e, c.ws_path, c.ws_key, true, true)
            sync.atomic_store(&c.writing, false)
        }
        odinsema.db_cache_reset_workspace(&e.db)
    }
    name       := fmt.tprintf("ws-%16x.bin", hash.fnv64a(transmute([]byte)key))
    path, jerr := filepath.join({c.dir, name}, context.temp_allocator)
    if jerr != nil {
        return
    }
    delete(c.ws_key, c.alloc)
    delete(c.ws_path, c.alloc)
    c.ws_key = strings.clone(key, c.alloc)
    c.ws_path = strings.clone(path, c.alloc)
    c.ws_known = true
    blob, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return
    }
    defer delete(blob)
    if !odinsema.db_cache_load(&e.db, blob, c.ws_key, workspace = true) {
        log.debugf("odin: workspace tree cache %s does not match; it is built again", path)
    }
}

// Loads the tree cache once: finds its key and file and hands the blob to the database.
@(private)
tree_cache_ensure :: proc(e: ^Engine) {
    c := &e.tree_cache
    sync.guard(&c.mutex)
    if c.known {
        return
    }
    c.known = true
    if c.dir == "" {
        return
    }
    root := odin_root(&e.root)
    if root == "" {
        return
    }
    key        := fmt.tprintf("%s\n%s", root, compiler_stamp(root))
    name       := fmt.tprintf("items-%16x.bin", hash.fnv64a(transmute([]byte)key))
    path, jerr := filepath.join({c.dir, name}, context.temp_allocator)
    if jerr != nil {
        return
    }
    c.key = strings.clone(key, c.alloc)
    c.path = strings.clone(path, c.alloc)
    blob, rerr := os.read_entire_file(path, context.allocator)
    if rerr != nil {
        return
    }
    defer delete(blob)
    if !odinsema.db_cache_load(&e.db, blob, c.key) {
        log.debugf("odin: tree cache %s does not match; it is built again", path)
    }
}

// The modtime and size of the compiler under `root`; "none" when it is missing. Temp-allocated.
@(private = "file")
compiler_stamp :: proc(root: string) -> string {
    exe        := ODIN_OS == .Windows ? "odin.exe" : "odin"
    path, jerr := filepath.join({root, exe}, context.temp_allocator)
    if jerr != nil {
        return "none"
    }
    info, err := os.stat(path, context.temp_allocator)
    if err != nil {
        return "none"
    }
    return fmt.tprintf("%d:%d", info.modification_time._nsec, info.size)
}

// Writes each tree cache when `force` and a tree was added, else when a batch of trees was added.
// A write that runs on another thread makes this one return.
@(private)
tree_cache_write :: proc(e: ^Engine, force: bool) {
    c := &e.tree_cache
    if _, ok := sync.atomic_compare_exchange_strong(&c.writing, false, true); !ok {
        return
    }
    defer sync.atomic_store(&c.writing, false)
    path, key, ws_path, ws_key: string
    {
        sync.guard(&c.mutex)
        if c.known && c.path != "" {
            path = strings.clone(c.path, context.temp_allocator)
            key = strings.clone(c.key, context.temp_allocator)
        }
        if c.ws_known && c.ws_path != "" {
            ws_path = strings.clone(c.ws_path, context.temp_allocator)
            ws_key = strings.clone(c.ws_key, context.temp_allocator)
        }
    }
    if path != "" && cache_file_write(e, path, key, false, force) {
        remove_old_caches(path)
    }
    if ws_path != "" {
        cache_file_write(e, ws_path, ws_key, true, force)
    }
}

// Writes one tree cache to `path` when `force` and a tree was added, else when a batch was added.
// True when it wrote.
@(private = "file")
cache_file_write :: proc(e: ^Engine, path, key: string, workspace, force: bool) -> bool {
    added := odinsema.db_cache_added(&e.db, workspace)
    if added == 0 || !force && added < TREE_CACHE_BATCH {
        return false
    }
    blob, ok := odinsema.db_cache_encode(&e.db, key, context.allocator, workspace)
    if !ok {
        return false
    }
    defer delete(blob)
    if dir := filepath.dir(path); dir != "" {
        if err := os.make_directory_all(dir); err != nil && err != .Exist {
            log.warnf("odin: cannot make the tree cache directory %s: %v", dir, err)
            return false
        }
    }
    if err := atomicfile.write(path, blob); err != nil {
        log.warnf("odin: cannot write the tree cache %s: %v", path, err)
        return false
    }
    return true
}

// Removes the tree caches beside `path` that another Odin root or compiler wrote.
@(private = "file")
remove_old_caches :: proc(path: string) {
    dir, name  := filepath.split(path)
    infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
    if err != nil {
        return
    }
    for info in infos {
        if info.type == .Directory || info.name == name || !strings.has_prefix(info.name, "items-") || !strings.has_suffix(info.name, ".bin") {
            continue
        }
        if rerr := os.remove(info.fullpath); rerr != nil {
            log.debugf("odin: cannot remove the old tree cache %s: %v", info.fullpath, rerr)
        }
    }
}
