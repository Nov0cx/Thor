// The packages a buffer can import: every package directory under the `base`, `core` and `vendor`
// collections of the Odin root and under the configured collections, cached on the engine.
package odin

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import odinsema "sema"

// Deepest directory level the package walk reads below a collection root.
@(private = "file")
PACKAGE_WALK_DEPTH :: 8

// One package a buffer can import.
@(private)
Known_Package :: struct {
    name:   string, // the last path element, the default import alias
    import_path: string, // `core:encoding/json`
    dir:    string, // the cleaned package directory
    rank:   int,    // core, base, configured collections, then vendor
}

// The known packages for one set of collection roots, guarded by its own mutex.
@(private)
Package_Index :: struct {
    mutex:    sync.Mutex,
    alloc:    runtime.Allocator,
    key:      string, // owned; the roots the list was built for
    built:    bool,
    packages: [dynamic]Known_Package, // owned, with their strings
}

// The known packages for the Odin root and the collections of `workspace`, sorted by rank, then by
// depth and path. Built on the first call for a set of roots. Temp-allocated copies.
@(private)
known_packages :: proc(e: ^Engine, workspace: string) -> []Known_Package {
    root := odin_root(&e.root)
    colls := config_collections(e, workspace)
    slice.sort_by(colls, proc(a, b: Collection) -> bool {
        return a.name < b.name
    })
    kb := strings.builder_make(context.temp_allocator)
    strings.write_string(&kb, root)
    for c in colls {
        strings.write_byte(&kb, 0)
        strings.write_string(&kb, c.name)
        strings.write_byte(&kb, '=')
        strings.write_string(&kb, c.dir)
    }
    key := strings.to_string(kb)

    index := &e.packages
    sync.lock(&index.mutex)
    defer sync.unlock(&index.mutex)
    if !index.built || index.key != key {
        package_index_clear(index)
        index.built = true
        cloned, err := strings.clone(key, index.alloc)
        if err == nil {
            index.key = cloned
        }
        if root != "" {
            ROOT_COLLECTIONS :: [3]struct {
                name: string,
                rank: int,
            }{{"core", 0}, {"base", 1}, {"vendor", 3}}
            for coll in ROOT_COLLECTIONS {
                dir, jerr := filepath.join({root, coll.name}, context.temp_allocator)
                if jerr == nil {
                    index_collection(index, coll.name, dir, coll.rank)
                }
            }
        }
        for c in colls {
            index_collection(index, c.name, c.dir, 2)
        }
        slice.sort_by(index.packages[:], proc(a, b: Known_Package) -> bool {
            if a.rank != b.rank {
                return a.rank < b.rank
            }
            da, db := strings.count(a.import_path, "/"), strings.count(b.import_path, "/")
            if da != db {
                return da < db
            }
            return a.import_path < b.import_path
        })
    }
    out := make([]Known_Package, len(index.packages), context.temp_allocator)
    for p, i in index.packages {
        out[i] = Known_Package {
            name        = strings.clone(p.name, context.temp_allocator),
            import_path = strings.clone(p.import_path, context.temp_allocator),
            dir         = strings.clone(p.dir, context.temp_allocator),
            rank        = p.rank,
        }
    }
    return out
}

// Adds the package directories under the root `dir` of the collection `name`.
@(private = "file")
index_collection :: proc(index: ^Package_Index, name, dir: string, rank: int) {
    if dir == "" || !os.is_dir(dir) {
        return
    }
    clean, err := filepath.clean(dir, context.temp_allocator)
    if err != nil {
        return
    }
    walk_packages(index, name, clean, "", rank, 0)
}

// Adds `dir` when it holds an `.odin` file, then walks its subdirectories. `rel` is the path below
// the collection root with `/` separators.
@(private = "file")
walk_packages :: proc(index: ^Package_Index, coll, dir, rel: string, rank, depth: int) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
    if err != nil {
        return
    }
    has_source := false
    for info in infos {
        if info.type != .Directory && strings.has_suffix(info.name, ".odin") && !strings.has_suffix(info.name, "_test.odin") {
            has_source = true
            break
        }
    }
    if has_source && rel != "" {
        name := rel[strings.last_index_byte(rel, '/') + 1:]
        if odinsema.is_identifier(name) {
            add_known(index, Known_Package{name = name, import_path = strings.concatenate({coll, ":", rel}, context.temp_allocator), dir = dir, rank = rank})
        }
    }
    if depth >= PACKAGE_WALK_DEPTH {
        return
    }
    for info in infos {
        if info.type != .Directory || skip_package_dir(info.name) {
            continue
        }
        sub := rel == "" ? info.name : strings.concatenate({rel, "/", info.name}, context.temp_allocator)
        walk_packages(index, coll, info.fullpath, sub, rank, depth + 1)
    }
}

// True for a directory the walk does not enter: tests, examples and hidden ones.
@(private = "file")
skip_package_dir :: proc(name: string) -> bool {
    switch name {
    case "test", "tests", "testdata", "example", "examples":
        return true
    }
    return name == "" || name[0] == '.' || name[0] == '_'
}

@(private = "file")
add_known :: proc(index: ^Package_Index, p: Known_Package) {
    a := index.alloc
    name, e1 := strings.clone(p.name, a)
    path, e2 := strings.clone(p.import_path, a)
    dir, e3 := strings.clone(p.dir, a)
    if e1 != nil || e2 != nil || e3 != nil {
        delete(name, a)
        delete(path, a)
        delete(dir, a)
        return
    }
    if _, aerr := append(&index.packages, Known_Package{name = name, import_path = path, dir = dir, rank = p.rank}); aerr != nil {
        delete(name, a)
        delete(path, a)
        delete(dir, a)
    }
}

// Frees the list and the key. Caller holds index.mutex, or is the only user.
@(private)
package_index_clear :: proc(index: ^Package_Index) {
    for p in index.packages {
        delete(p.name, index.alloc)
        delete(p.import_path, index.alloc)
        delete(p.dir, index.alloc)
    }
    delete(index.packages)
    index.packages = make([dynamic]Known_Package, index.alloc)
    delete(index.key, index.alloc)
    index.key = ""
    index.built = false
}

// Frees the index on engine destroy.
@(private)
package_index_destroy :: proc(index: ^Package_Index) {
    package_index_clear(index)
    delete(index.packages)
    index.packages = nil
}

// True when the two directories are the same; case-insensitive on Windows.
@(private)
same_dir :: proc(a, b: string) -> bool {
    ca, ea := filepath.clean(a, context.temp_allocator)
    cb, eb := filepath.clean(b, context.temp_allocator)
    if ea != nil || eb != nil {
        return false
    }
    when ODIN_OS == .Windows {
        return strings.equal_fold(ca, cb)
    } else {
        return ca == cb
    }
}
