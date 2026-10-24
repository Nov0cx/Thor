package odinsema

import "core:os"
import "core:path/filepath"
import "core:sync"

import odinsyntax "../syntax"

// The declarations of a file: the live buffer's for its file, else the disk's, refreshed by stat
// once per snapshot. Nil when the file cannot be read.
db_file :: proc(snap: ^Snapshot, id: File_Id) -> ^File_Data {
    if snap.live.has && id == snap.live.id {
        return live_ensure(snap) ? snap.live.data : nil
    }
    data := file_data_pinned(snap, id)
    db_trim(snap.db)
    return data
}

// The parse of a file, as db_file chooses its text. Nil when the file cannot be read.
db_parse :: proc(snap: ^Snapshot, id: File_Id) -> ^odinsyntax.Parse {
    if snap.live.has && id == snap.live.id {
        return live_ensure(snap) ? &snap.live.body.parse : nil
    }
    slot := file_slot(snap.db, id)
    if slot == nil {
        return nil
    }
    body: ^File_Body
    {
        sync.guard(&slot.mutex)
        file_refresh(snap, slot)
        if slot.body == nil && slot.disk != nil {
            file_reload_body(snap, slot)
        }
        if slot.body != nil && pin(snap, slot.body) {
            body = slot.body
            lru_touch_locked(snap.db, &snap.db.bodies, u32(id), body.bytes)
        }
    }
    db_trim(snap.db)
    return body != nil ? &body.parse : nil
}

// Drops the pin of one db_parse call before snapshot_end, so a scan does not hold every parse.
// The parse is invalid after the call unless another pin holds it. The live buffer's parse stays.
db_parse_release :: proc(snap: ^Snapshot, parse: ^odinsyntax.Parse) {
    if parse == nil || snap.live.body != nil && parse == &snap.live.body.parse {
        return
    }
    for i := len(snap.pins) - 1; i >= 0; i -= 1 {
        v := snap.pins[i]
        if v.kind == .File_Body && &(^File_Body)(v).parse == parse {
            unordered_remove(&snap.pins, i)
            value_release(snap.db, v)
            break
        }
    }
    db_trim(snap.db)
}

// True when the file is compiled for the snapshot's target. A buffer with no file is in no build.
db_in_build :: proc(snap: ^Snapshot, id: File_Id) -> bool {
    if snap.live.has && id == snap.live.id {
        live := &snap.live
        if !live.in_build_known {
            live.in_build_known = true
            live.in_build = live.id != ANON_FILE && live_ensure(snap) && file_in_build(live.path, live.data.tree.tags, snap.target)
        }
        return live.in_build
    }
    slot := file_slot(snap.db, id)
    if slot == nil {
        return false
    }
    sync.guard(&slot.mutex)
    file_refresh(snap, slot)
    if slot.disk == nil {
        return false
    }
    if !slot.in_build_known || slot.in_build_at != slot.shape_changed_at || slot.in_build_config != snap.config {
        slot.in_build = file_in_build(slot.path, slot.disk.tree.tags, snap.target)
        slot.in_build_known = true
        slot.in_build_at = slot.shape_changed_at
        slot.in_build_config = snap.config
    }
    return slot.in_build
}

// The imports of a file, resolved against the snapshot's collections; `exists` is checked once
// per snapshot. Nil when the file cannot be read.
db_imports :: proc(snap: ^Snapshot, id: File_Id) -> []File_Import {
    db := snap.db
    if snap.live.has && id == snap.live.id {
        live := &snap.live
        if !live.imports_known {
            live.imports_known = true
            if live_ensure(snap) {
                live.imports, _ = file_imports(live.data.tree, live.dir, &snap.collections, snap.alloc)
            }
        }
        return live.imports
    }
    slot := file_slot(db, id)
    if slot == nil {
        return nil
    }
    sync.guard(&slot.mutex)
    file_refresh(snap, slot)
    if slot.disk == nil {
        return nil
    }
    v := slot.imports
    if v != nil && (v.data != slot.disk || v.config != snap.config) {
        v = nil
    }
    if v != nil && v.epoch != snap.epoch {
        if imports_exist_same(v.list) {
            v.epoch = snap.epoch
        } else {
            v = nil
        }
    }
    if v == nil {
        v = imports_new(snap, slot)
        if v == nil {
            return nil
        }
        if slot.imports != nil {
            value_release(db, slot.imports)
        }
        slot.imports = v
    }
    if !pin(snap, v) {
        return nil
    }
    return v.list
}

// The disk data of a file, pinned. The caller holds no slot.
@(private)
file_data_pinned :: proc(snap: ^Snapshot, id: File_Id) -> ^File_Data {
    slot := file_slot(snap.db, id)
    if slot == nil {
        return nil
    }
    sync.guard(&slot.mutex)
    file_refresh(snap, slot)
    if slot.disk == nil || !pin(snap, slot.disk) {
        return nil
    }
    return slot.disk
}

// Brings the disk memos of a file in step with its stamp, once per snapshot. The caller holds the slot.
@(private)
file_refresh :: proc(snap: ^Snapshot, slot: ^File_Slot) {
    if slot.stamped && slot.stat_epoch == snap.epoch {
        return
    }
    db := snap.db
    info, err := os.stat(slot.path, db.allocator)
    if err != nil {
        if slot.disk != nil || slot.exists {
            next_revision(db)
        }
        file_slot_drop_disk(db, slot)
        slot.stamped = true
        slot.exists = false
        slot.stat_epoch = snap.epoch
        return
    }
    modtime := info.modification_time._nsec
    size := info.size
    is_dir := info.type == .Directory
    os.file_info_delete(info, db.allocator)
    if is_dir {
        file_slot_drop_disk(db, slot)
        slot.stamped = true
        slot.exists = false
        slot.stat_epoch = snap.epoch
        return
    }
    if slot.stamped && slot.exists && slot.modtime == modtime && slot.size == size {
        slot.stat_epoch = snap.epoch
        return
    }
    file_load(snap, slot)
    slot.stamped = true
    slot.exists = true
    slot.modtime = modtime
    slot.size = size
    slot.stat_epoch = snap.epoch
}

// Reads and parses a file into new disk memos. A file that cannot be read keeps none.
@(private = "file")
file_load :: proc(snap: ^Snapshot, slot: ^File_Slot) {
    db := snap.db
    file_slot_drop_disk(db, slot)
    rev := next_revision(db)
    text, ok := db.read(slot.path, db.allocator)
    if !ok {
        return
    }
    stat_add(&db.stats.reads)
    parsed, perr := odinsyntax.parse(text, db.allocator)
    delete(text, db.allocator)
    if perr != nil {
        return
    }
    stat_add(&db.stats.parses)
    data := file_data_new(db, parsed)
    if data == nil {
        odinsyntax.parse_destroy(&parsed, db.allocator)
        return
    }
    if !slot.has_shape || slot.shape != data.shape {
        slot.has_shape = true
        slot.shape = data.shape
        slot.shape_changed_at = rev
    }
    data.shape_changed_at = slot.shape_changed_at
    data.changed_at = rev
    slot.disk = data
    if body := file_body_new(db, parsed); body != nil {
        slot.body = body
        lru_touch_locked(db, &db.bodies, u32(slot.id), body.bytes)
    } else {
        odinsyntax.parse_destroy(&parsed, db.allocator)
    }
    if sync.atomic_load(&slot.holders) == 0 {
        lru_touch_locked(db, &db.loose, u32(slot.id))
    }
}

// Parses the disk text again for a body the budget dropped. A file whose stamp moved is read whole
// again. The caller holds the slot.
@(private = "file")
file_reload_body :: proc(snap: ^Snapshot, slot: ^File_Slot) {
    db := snap.db
    info, err := os.stat(slot.path, db.allocator)
    if err != nil {
        return
    }
    moved := info.modification_time._nsec != slot.modtime || info.size != slot.size
    os.file_info_delete(info, db.allocator)
    if moved {
        slot.stat_epoch = 0
        file_refresh(snap, slot)
        return
    }
    text, ok := db.read(slot.path, db.allocator)
    if !ok {
        return
    }
    stat_add(&db.stats.reads)
    parsed, perr := odinsyntax.parse(text, db.allocator)
    delete(text, db.allocator)
    if perr != nil {
        return
    }
    stat_add(&db.stats.parses)
    body := file_body_new(db, parsed)
    if body == nil {
        odinsyntax.parse_destroy(&parsed, db.allocator)
        return
    }
    slot.body = body
}

@(private = "file")
imports_new :: proc(snap: ^Snapshot, slot: ^File_Slot) -> ^Imports_Value {
    db := snap.db
    v, err := new(Imports_Value, db.allocator)
    if err != nil {
        return nil
    }
    dir := filepath.dir(slot.path)
    list, ierr := file_imports(slot.disk.tree, dir == "" ? "." : dir, &snap.collections, db.allocator)
    if ierr != nil {
        free(v, db.allocator)
        return nil
    }
    v.kind = .Imports
    v.refs = 1
    v.data = slot.disk
    value_retain(slot.disk)
    v.config = snap.config
    v.epoch = snap.epoch
    v.list = list
    return v
}

// True when every resolved import directory still exists as recorded.
@(private = "file")
imports_exist_same :: proc(list: []File_Import) -> bool {
    for imp in list {
        if imp.dir == "" {
            continue
        }
        if os.is_dir(imp.dir) != imp.exists {
            return false
        }
    }
    return true
}

// Parses the request's buffer once per snapshot: the last live parse of its file when the text is
// equal, an incremental parse when nothing else holds that parse, else a full one.
@(private)
live_ensure :: proc(snap: ^Snapshot) -> bool {
    live := &snap.live
    if live.ready {
        return live.data != nil
    }
    live.ready = true
    db := snap.db
    if live.id == ANON_FILE {
        parsed, perr := odinsyntax.parse(live.text, db.allocator)
        if perr != nil {
            return false
        }
        stat_add(&db.stats.parses)
        data := file_data_new(db, parsed)
        if data == nil {
            odinsyntax.parse_destroy(&parsed, db.allocator)
            return false
        }
        body := file_body_new(db, parsed)
        if body == nil {
            value_release(db, data)
            odinsyntax.parse_destroy(&parsed, db.allocator)
            return false
        }
        if !pin_owned(snap, body) {
            value_release(db, data)
            return false
        }
        if !pin_owned(snap, data) {
            return false
        }
        data.changed_at = next_revision(db)
        data.shape_changed_at = data.changed_at
        live.data = data
        live.body = body
        return true
    }
    slot := file_slot(db, live.id)
    if slot == nil {
        return false
    }
    sync.guard(&slot.mutex)
    if slot.live_body == nil || slot.live_data == nil || slot.live_body.parse.tree == nil || slot.live_body.parse.tree.text != live.text {
        if !live_parse(snap, slot) {
            return false
        }
    }
    if !pin(snap, slot.live_data) {
        return false
    }
    if !pin(snap, slot.live_body) {
        return false
    }
    live.data = slot.live_data
    live.body = slot.live_body
    lru_touch_locked(db, &db.lives, u32(slot.id))
    return true
}

// Replaces the live memos of a slot with a parse of the snapshot's buffer. The caller holds the slot.
@(private = "file")
live_parse :: proc(snap: ^Snapshot, slot: ^File_Slot) -> bool {
    db := snap.db
    text := snap.live.text
    parsed: odinsyntax.Parse
    reused := false
    old := slot.live_body
    if old != nil && sync.atomic_load(&old.refs) == 1 && old.parse.tree != nil {
        // Only the slot holds the old parse, so the new tree can take it as its base.
        base := old.parse
        result, how, err := odinsyntax.reparse(&base, text, db.allocator)
        if err == nil {
            parsed = result
            reused = true
            old.parse = base
            stat_add(how == .Full ? &db.stats.parses : &db.stats.reparses)
        }
    }
    if !reused {
        result, err := odinsyntax.parse(text, db.allocator)
        if err != nil {
            return false
        }
        parsed = result
        stat_add(&db.stats.parses)
    }
    data := file_data_new(db, parsed)
    if data == nil {
        odinsyntax.parse_destroy(&parsed, db.allocator)
        if reused {
            file_slot_drop_live(db, slot)
        }
        return false
    }
    body := file_body_new(db, parsed)
    if body == nil {
        value_release(db, data)
        odinsyntax.parse_destroy(&parsed, db.allocator)
        if reused {
            file_slot_drop_live(db, slot)
        }
        return false
    }
    rev := next_revision(db)
    data.changed_at = rev
    data.shape_changed_at = rev
    if slot.live_data != nil && slot.live_data.shape == data.shape {
        data.shape_changed_at = slot.live_data.shape_changed_at
    }
    file_slot_drop_live(db, slot)
    slot.live_data = data
    slot.live_body = body
    return true
}
