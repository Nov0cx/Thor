package odinsema

import "core:sync"

import odinsyntax "../syntax"

// Bytes the database holds, by kind. `used` is what the arenas gave out, `reserved` their address space.
Db_Memory :: struct {
    files:           int, // file slots
    packages:        int, // package slots
    disk_bodies:     int, // disk parses resident
    disk_used:       int,
    disk_reserved:   int,
    disk_text:       int, // source text inside the disk parses, base chains included
    live_bodies:     int,
    live_used:       int,
    live_reserved:   int,
    live_text:       int,
    live_trees:      int, // trees in the live chains, bases included
    datas:           int, // item trees resident
    data_used:       int,
    data_reserved:   int,
    lines:           int, // bytes of the line tables
    memos:           int, // package memos resident
    cache_entries:   int,
    cache_bytes:     int, // encoded item trees in the tree cache
    type_states:     int,
    type_used:       int,
    type_reserved:   int,
}

// Counts what the database holds. Takes every slot lock in turn; for tests and benchmarks only.
db_memory :: proc(db: ^Db) -> (m: Db_Memory) {
    m.files = int(slot_count(&db.files))
    m.packages = int(slot_count(&db.packages))
    seen := make(map[^File_Data]struct{}, context.temp_allocator)
    for id in 0 ..< slot_count(&db.files) {
        slot := slot_get(&db.files, id)
        sync.guard(&slot.mutex)
        if slot.body != nil {
            m.disk_bodies += 1
            used, reserved, text, _ := parse_memory(slot.body.parse)
            m.disk_used += used
            m.disk_reserved += reserved
            m.disk_text += text
        }
        if slot.live_body != nil {
            m.live_bodies += 1
            used, reserved, text, trees := parse_memory(slot.live_body.parse)
            m.live_used += used
            m.live_reserved += reserved
            m.live_text += text
            m.live_trees += trees
        }
        for d in ([]^File_Data{slot.disk, slot.live_data}) {
            if d == nil || d in seen {
                continue
            }
            seen[d] = {}
            m.datas += 1
            m.lines += len(d.lines) * size_of(int)
            if d.tree != nil {
                m.data_used += int(d.tree.arena.total_used)
                m.data_reserved += int(d.tree.arena.total_reserved)
            }
        }
    }
    for id in 0 ..< slot_count(&db.packages) {
        slot := slot_get(&db.packages, id)
        sync.guard(&slot.mutex)
        if slot.memo != nil {
            m.memos += 1
        }
    }
    {
        sync.guard(&db.cache.mutex)
        m.cache_entries = len(db.cache.entries)
        for _, e in db.cache.entries {
            m.cache_bytes += len(e.data)
        }
    }
    {
        sync.guard(&db.type_mutex)
        for s in db.type_states {
            if s == nil {
                continue
            }
            m.type_states += 1
            m.type_used += int(s.arena.total_used)
            m.type_reserved += int(s.arena.total_reserved)
        }
    }
    return
}

@(private = "file")
parse_memory :: proc(p: odinsyntax.Parse) -> (used, reserved, text, trees: int) {
    for t := p.tree; t != nil; t = t.base {
        used += int(t.arena.total_used) + len(t.pages)
        reserved += int(t.arena.total_reserved) + len(t.pages)
        text += len(t.text)
        trees += 1
    }
    return
}
