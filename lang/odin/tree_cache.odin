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

// The file that keeps the item trees of the Odin root across sessions.
@(private)
Tree_Cache_File :: struct {
    mutex:   sync.Mutex,
    writing: sync.Mutex,
    alloc:   runtime.Allocator,
    dir:     string, // owned; "" when the cache is off
    known:   bool,   // `key` and `path` were found and the blob was loaded
    key:     string, // owned; the Odin root and the stamp of its compiler
    path:    string, // owned; "" when the cache is off
}

// Sets the directory of the tree cache; "" turns it off. Call it before the first request.
engine_set_cache_dir :: proc(e: ^Engine, dir: string) {
    c := &e.tree_cache
    sync.guard(&c.mutex)
    tree_cache_clear(c)
    c.dir = strings.clone(dir, c.alloc)
}

@(private)
tree_cache_clear :: proc(c: ^Tree_Cache_File) {
    delete(c.dir, c.alloc)
    delete(c.key, c.alloc)
    delete(c.path, c.alloc)
    c.dir, c.key, c.path = "", "", ""
    c.known = false
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
    key := fmt.tprintf("%s\n%s", root, compiler_stamp(root))
    name := fmt.tprintf("items-%16x.bin", hash.fnv64a(transmute([]byte)key))
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
    exe := ODIN_OS == .Windows ? "odin.exe" : "odin"
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

// Writes the tree cache when `force` and a tree was added, else when a batch of trees was added.
// A write that runs on another thread makes this one return.
@(private)
tree_cache_write :: proc(e: ^Engine, force: bool) {
    c := &e.tree_cache
    added := odinsema.db_cache_added(&e.db)
    if added == 0 || !force && added < TREE_CACHE_BATCH {
        return
    }
    if !sync.mutex_try_lock(&c.writing) {
        return
    }
    defer sync.mutex_unlock(&c.writing)
    path, key: string
    {
        sync.guard(&c.mutex)
        if !c.known || c.path == "" {
            return
        }
        path = strings.clone(c.path, context.temp_allocator)
        key = strings.clone(c.key, context.temp_allocator)
    }
    blob, ok := odinsema.db_cache_encode(&e.db, key, context.allocator)
    if !ok {
        return
    }
    defer delete(blob)
    if dir := filepath.dir(path); dir != "" {
        if err := os.make_directory_all(dir); err != nil && err != .Exist {
            log.warnf("odin: cannot make the tree cache directory %s: %v", dir, err)
            return
        }
    }
    if err := atomicfile.write(path, blob); err != nil {
        log.warnf("odin: cannot write the tree cache %s: %v", path, err)
    }
}
