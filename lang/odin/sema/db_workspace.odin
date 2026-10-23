package odinsema

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

// The `.odin` files under `root`, sorted by path, walked once per snapshot. Directories whose name
// starts with `.` are skipped, and the walk stops at Db.workspace_limit files and
// WORKSPACE_DEPTH_LIMIT levels. The files stay resident while they are in the workspace. Nil when
// the snapshot is cancelled; a cancelled walk keeps the last one.
db_workspace :: proc(snap: ^Snapshot, root: string) -> []File_Id {
    if root == "" || snapshot_cancelled(snap) {
        return nil
    }
    db := snap.db
    ws := &db.workspace
    out: []File_Id
    {
        sync.guard(&ws.mutex)
        key := path_key(root)
        if ws.key != key || ws.epoch != snap.epoch {
            if !workspace_walk(snap, ws, root, key) {
                return nil
            }
        }
        out, _ = slice.clone(ws.files, snap.alloc)
    }
    db_trim(db)
    return out
}

// Walks `root` and replaces the file list. False when cancelled or out of memory. The caller holds the slot.
@(private = "file")
workspace_walk :: proc(snap: ^Snapshot, ws: ^Workspace_Slot, root, key: string) -> bool {
    db := snap.db
    paths := make([dynamic]string, db.allocator)
    defer {
        for p in paths {
            delete(p, db.allocator)
        }
        delete(paths)
    }
    if !walk_dir(snap, root, &paths, 0) || snapshot_cancelled(snap) {
        return false
    }
    slice.sort(paths[:])
    ids := make([dynamic]File_Id, 0, len(paths), db.allocator)
    for p in paths {
        if id := file_intern(db, p); id != NO_FILE {
            append(&ids, id)
        }
    }
    owned_key, kerr := strings.clone(key, db.allocator)
    if kerr != nil {
        delete(ids)
        return false
    }
    files_hold(db, ids[:])
    files_release(db, ws.files)
    delete(ws.files, db.allocator)
    delete(ws.key, db.allocator)
    ws.files = ids[:]
    ws.key = owned_key
    ws.epoch = snap.epoch
    return true
}

// Appends the `.odin` files under `dir`. False when cancelled.
@(private = "file")
walk_dir :: proc(snap: ^Snapshot, dir: string, out: ^[dynamic]string, depth: int) -> bool {
    db := snap.db
    if len(out) >= db.workspace_limit || depth > WORKSPACE_DEPTH_LIMIT {
        return true
    }
    if snapshot_cancelled(snap) {
        return false
    }
    handle, open_err := os.open(dir)
    if open_err != nil {
        return true
    }
    defer os.close(handle)
    infos, read_err := os.read_dir(handle, -1, db.allocator)
    if read_err != nil {
        return true
    }
    defer os.file_info_slice_delete(infos, db.allocator)
    for info in infos {
        if len(out) >= db.workspace_limit {
            return true
        }
        if snapshot_cancelled(snap) {
            return false
        }
        if info.type == .Directory {
            if !strings.has_prefix(info.name, ".") && !walk_dir(snap, info.fullpath, out, depth + 1) {
                return false
            }
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        path, err := strings.clone(info.fullpath, db.allocator)
        if err != nil {
            continue
        }
        if _, aerr := append(out, path); aerr != nil {
            delete(path, db.allocator)
        }
    }
    return true
}
