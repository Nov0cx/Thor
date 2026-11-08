package odinsema

// The most packages import_cycles visits.
CYCLE_PACKAGES :: 512

// For each directory of `dirs`, whether its package imports the package `home`, directly or through
// other packages in the build. One walk serves every directory. Packages of `base`, `core` and
// `vendor` are not followed: they import no workspace package. `home` itself gives false. All false
// after CYCLE_PACKAGES packages. The result is in the snapshot arena.
import_cycles :: proc(snap: ^Snapshot, home: Package_Id, dirs: []string) -> []bool {
    Edge :: struct {
        from, to: Package_Id,
    }
    out, err := make([]bool, len(dirs), snap.alloc)
    if err != nil || home == NO_PACKAGE {
        return out
    }
    starts := make([]Package_Id, len(dirs), snap.alloc)
    seen := make(map[Package_Id]struct{}, 16, snap.alloc)
    queue := make([dynamic]Package_Id, 0, 16, snap.alloc)
    edges := make([dynamic]Edge, 0, 64, snap.alloc)
    seen[home] = {}
    for dir, i in dirs {
        starts[i] = db_package_id(snap, dir)
        if starts[i] == NO_PACKAGE || starts[i] in seen {
            continue
        }
        seen[starts[i]] = {}
        if _, aerr := append(&queue, starts[i]); aerr != nil {
            return out
        }
    }
    for i := 0; i < len(queue); i += 1 {
        if snapshot_cancelled(snap) || len(seen) > CYCLE_PACKAGES {
            return out
        }
        from := queue[i]
        view := db_package(snap, from)
        if view == nil {
            continue
        }
        for f in view.files {
            if !db_in_build(snap, f) {
                continue
            }
            for imp in db_imports(snap, f) {
                if imp.is_foreign || !imp.exists || imp.dir == "" || imp.problem != .None || stable_collection(imp.collection) {
                    continue
                }
                to := db_package_id(snap, imp.dir)
                if to == NO_PACKAGE || to == from {
                    continue
                }
                if _, aerr := append(&edges, Edge{from, to}); aerr != nil {
                    return out
                }
                if to in seen {
                    continue
                }
                seen[to] = {}
                if _, aerr := append(&queue, to); aerr != nil {
                    return out
                }
            }
        }
    }
    reaching := make(map[Package_Id]struct{}, 16, snap.alloc)
    reaching[home] = {}
    for changed := true; changed; {
        changed = false
        for e in edges {
            if e.to in reaching && e.from not_in reaching {
                reaching[e.from] = {}
                changed = true
            }
        }
    }
    for s, i in starts {
        out[i] = s != home && s in reaching
    }
    return out
}

// True for a collection of the Odin root whose packages import only each other.
@(private = "file")
stable_collection :: proc(name: string) -> bool {
    return name == "base" || name == "core" || name == "vendor"
}
