package odinsema

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

// The package at a directory for the snapshot: its files, their declarations and its scope. The live
// buffer replaces its file, or joins the package when it is in the directory but not on disk. Nil
// when the directory cannot be read and holds no live buffer, or when the snapshot is cancelled.
db_package :: proc(snap: ^Snapshot, pkg: Package_Id) -> ^Package_View {
    if view, ok := snap.views[pkg]; ok {
        return view
    }
    if snapshot_cancelled(snap) {
        return nil
    }
    db := snap.db
    slot := package_slot(db, pkg)
    if slot == nil {
        return nil
    }
    view := package_view(snap, slot)
    db_trim(db)
    if view != nil {
        snap.views[pkg] = view
    }
    return view
}

@(private = "file")
package_view :: proc(snap: ^Snapshot, slot: ^Package_Slot) -> ^Package_View {
    db := snap.db
    view, verr := new(Package_View, snap.alloc)
    if verr != nil {
        return nil
    }
    view.id = slot.id
    view.dir = slot.dir
    live := &snap.live
    has_live := live.has && live.id != ANON_FILE && live.dir_key == slot.key
    {
        sync.guard(&slot.mutex)
        datas, state := package_refresh(snap, slot)
        switch state {
        case .Cancelled:
            return nil
        case .No_Dir:
            if !has_live {
                return nil
            }
        case .Ready:
            memo := slot.memo
            if !pin(snap, memo) {
                return nil
            }
            lru_touch_locked(db, &db.scopes, u32(slot.id))
            view.files = memo.files
            view.datas = datas
            view.scope = &memo.scope
        }
    }
    serr: mem.Allocator_Error
    if view.sema_files, serr = make([]Package_File, len(view.files), snap.alloc); serr != nil {
        return nil
    }
    for id, i in view.files {
        view.sema_files[i] = Package_File{path = file_path_of(db, id), items = view.datas[i] != nil ? view.datas[i].tree : nil}
    }
    if !has_live || !live_ensure(snap) {
        return view.scope != nil ? view : nil
    }
    if i, found := slice.linear_search(view.files, live.id); found {
        cached := view.scope != nil && view.datas[i] != nil && view.datas[i].shape == live.data.shape
        datas, cerr := slice.clone(view.datas, snap.alloc)
        if cerr != nil {
            return nil
        }
        datas[i] = live.data
        view.datas = datas
        view.sema_files[i].items = live.data.tree
        if cached {
            return view
        }
    } else {
        live_path := file_path_of(db, live.id)
        at := 0
        for at < len(view.files) && file_path_of(db, view.files[at]) < live_path {
            at += 1
        }
        files := make([dynamic]File_Id, 0, len(view.files) + 1, snap.alloc)
        datas := make([dynamic]^File_Data, 0, len(view.files) + 1, snap.alloc)
        sema := make([dynamic]Package_File, 0, len(view.files) + 1, snap.alloc)
        append(&files, ..view.files[:at])
        append(&files, live.id)
        append(&files, ..view.files[at:])
        append(&datas, ..view.datas[:at])
        append(&datas, live.data)
        append(&datas, ..view.datas[at:])
        append(&sema, ..view.sema_files[:at])
        append(&sema, Package_File{path = live_path, items = live.data.tree})
        append(&sema, ..view.sema_files[at:])
        if len(files) != len(view.files) + 1 || len(datas) != len(files) || len(sema) != len(files) {
            return nil
        }
        view.files = files[:]
        view.datas = datas[:]
        view.sema_files = sema[:]
    }
    scope, err := new(Package_Scope, snap.alloc)
    if err != nil {
        return nil
    }
    if scope^, err = package_scope(view.sema_files, snap.target, snap.alloc); err != nil {
        return nil
    }
    stat_add(&db.stats.local_scopes)
    view.scope = scope
    view.local = true
    return view
}

@(private = "file")
Refresh_State :: enum u8 {
    Ready,
    No_Dir,
    Cancelled,
}

// Lists the directory once per snapshot, and at most once per Db.stable_interval under the Odin
// root or Db.workspace_interval elsewhere, refreshes every file and builds the memo again when the
// file set, a file's shape or the configuration changed. Gives the pinned data of each file.
// A cancelled refresh keeps the old memo. The caller holds the slot.
@(private = "file")
package_refresh :: proc(snap: ^Snapshot, slot: ^Package_Slot) -> (datas: []^File_Data, state: Refresh_State) {
    db := snap.db
    if slot.listed_epoch != snap.epoch && !(slot.listed_epoch != 0 && key_fresh(snap, slot.key, sync.atomic_load(&slot.listed_time))) {
        listing, lstate := package_list(snap, slot.dir)
        switch lstate {
        case .Cancelled:
            return nil, .Cancelled
        case .No_Dir:
            if key_stable(snap, slot.key) {
                cache_prune_dir(db, slot.key, nil)
            }
            package_slot_drop_memo(db, slot)
            delete(slot.listing, db.allocator)
            slot.listing = nil
            slot.listed_epoch = 0
            return nil, .No_Dir
        case .Ready:
        }
        delete(slot.listing, db.allocator)
        slot.listing = listing
        slot.listed_epoch = snap.epoch
        sync.atomic_store(&slot.listed_time, snap.now)
        if key_stable(snap, slot.key) {
            cache_prune_listing(snap, slot)
        }
    }
    ids := slot.listing
    datas = make([]^File_Data, len(ids), snap.alloc)
    for id, i in ids {
        if snapshot_cancelled(snap) {
            return nil, .Cancelled
        }
        datas[i] = file_data_pinned(snap, id)
    }
    if memo := slot.memo; memo != nil && memo.config == snap.config && slice.equal(memo.files, ids) {
        same := true
        for d, i in datas {
            if (d != nil ? d.shape_changed_at : 0) != memo.built_from[i] {
                same = false
                break
            }
        }
        if same {
            return datas, .Ready
        }
    }
    memo := package_memo_new(snap, ids, datas)
    if memo == nil {
        return nil, .Cancelled
    }
    files_hold(db, memo.files)
    package_slot_drop_memo(db, slot)
    slot.memo = memo
    return datas, .Ready
}

// Drops the tree cache entries of files of the directory that its listing no longer holds.
@(private = "file")
cache_prune_listing :: proc(snap: ^Snapshot, slot: ^Package_Slot) {
    present := make([]string, len(slot.listing), snap.alloc)
    for id, i in slot.listing {
        if f := file_slot(snap.db, id); f != nil {
            present[i] = f.key
        }
    }
    cache_prune_dir(snap.db, slot.key, present)
}

@(private = "file")
package_memo_new :: proc(snap: ^Snapshot, ids: []File_Id, datas: []^File_Data) -> ^Package_Memo {
    db := snap.db
    m, err := new(Package_Memo, db.allocator)
    if err != nil {
        return nil
    }
    m.kind = .Package_Memo
    m.refs = 1
    m.config = snap.config
    m.files, _ = slice.clone(ids, db.allocator)
    m.built_from, _ = make([]u64, len(ids), db.allocator)
    sema, serr := make([]Package_File, len(ids), snap.alloc)
    ok := serr == nil && (len(ids) == 0 || (m.files != nil && m.built_from != nil))
    if ok {
        for d, i in datas {
            sema[i] = Package_File{path = file_path_of(db, ids[i]), items = d != nil ? d.tree : nil}
            if d != nil {
                m.built_from[i] = d.shape_changed_at
            }
        }
        scope, perr := package_scope(sema, snap.target, db.allocator)
        m.scope = scope
        ok = perr == nil
    }
    if !ok {
        value_release(db, m)
        return nil
    }
    stat_add(&db.stats.scopes)
    return m
}

// The `.odin` files of a directory as interned ids, sorted by path.
@(private = "file")
package_list :: proc(snap: ^Snapshot, dir: string) -> ([]File_Id, Refresh_State) {
    db := snap.db
    stat_add(&db.stats.listings)
    handle, open_err := os.open(dir)
    if open_err != nil {
        return nil, .No_Dir
    }
    defer os.close(handle)
    infos, read_err := os.read_dir(handle, -1, db.allocator)
    if read_err != nil {
        return nil, .No_Dir
    }
    defer os.file_info_slice_delete(infos, db.allocator)
    slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
        return a.fullpath < b.fullpath
    })
    ids := make([dynamic]File_Id, 0, len(infos), db.allocator)
    for info in infos {
        if snapshot_cancelled(snap) {
            delete(ids)
            return nil, .Cancelled
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        id := file_intern(db, info.fullpath)
        if id == NO_FILE {
            continue
        }
        append(&ids, id)
    }
    return ids[:], .Ready
}

@(private)
file_path_of :: proc(db: ^Db, id: File_Id) -> string {
    slot := file_slot(db, id)
    return slot != nil ? slot.path : ""
}
