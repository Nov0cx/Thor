package ui

import "core:slice"
import "core:strings"

// Bounds cache memory regardless of file size or session length. Only preloaded
// (family, size) combinations reach the cache path at all, so this capacity
// bounds distinct line content — many screens across every open pane.
SHAPE_CACHE_CAPACITY :: 4096

// Cache key: content-addressed, so an edited line becomes a different key rather
// than invalidating anything, and stale entries age out via LRU. `line` borrows
// the caller's string for a lookup; shape_cache_put clones it before storing.
Shape_Cache_Key :: struct {
    family:    ^Font_Family,
    size:      i32,
    ligatures: bool,
    line:      string,
}

@(private = "file")
Shape_Cache_Entry :: struct {
    key:    Shape_Cache_Key, // cache-owned line
    glyphs: []Placed_Glyph,  // cache-owned
    used:   u64,             // LRU stamp
}

// Draw-time shaping cache. Main thread only, like the rest of shape.odin, so
// no locking; every proc below takes the cache explicitly so tests can use
// an isolated instance instead of the shared package one.
Shape_Cache :: struct {
    entries: map[Shape_Cache_Key]^Shape_Cache_Entry,
    clock:   u64,
}

// Draw-time cache; the one shape_place_line consults. Main thread only,
// freed in text_shutdown.
@(private)
shape_cache: Shape_Cache

// Cache lookup; a hit bumps the entry's recency and hands back its
// cache-owned glyphs directly (no HarfBuzz, no itemizing).
shape_cache_get :: proc(cache: ^Shape_Cache, key: Shape_Cache_Key) -> ([]Placed_Glyph, bool) {
    cache.clock += 1
    entry, hit := cache.entries[key]
    if !hit {
        return nil, false
    }
    entry.used = cache.clock
    return entry.glyphs, true
}

// Clones key and glyphs into cache-owned storage and inserts, evicting the
// least recently used entry first if the cache is at capacity. Returns the
// cache-owned glyphs slice, safe for the caller to hand onward.
shape_cache_put :: proc(cache: ^Shape_Cache, key: Shape_Cache_Key, glyphs: []Placed_Glyph) -> []Placed_Glyph {
    if len(cache.entries) >= SHAPE_CACHE_CAPACITY {
        shape_cache_evict_oldest(cache)
    }
    cache.clock += 1
    entry := new(Shape_Cache_Entry)
    entry.key = key
    entry.key.line = strings.clone(key.line)
    entry.glyphs = slice.clone(glyphs)
    entry.used = cache.clock
    cache.entries[entry.key] = entry
    return entry.glyphs
}

// Oldest-first eviction: one linear scan over the capacity-bounded entry set,
// amortized against the itemize+HarfBuzz-shape cost the triggering miss pays.
@(private = "file")
shape_cache_evict_oldest :: proc(cache: ^Shape_Cache) {
    oldest: ^Shape_Cache_Entry
    for _, entry in cache.entries {
        if oldest == nil || entry.used < oldest.used {
            oldest = entry
        }
    }
    if oldest == nil {
        return
    }
    delete_key(&cache.entries, oldest.key)
    delete(oldest.key.line)
    delete(oldest.glyphs)
    free(oldest)
}

// Resident entry count; test introspection.
shape_cache_len :: proc(cache: ^Shape_Cache) -> int {
    return len(cache.entries)
}

// Frees every entry and the map's backing storage, leaving the cache reusable (a
// nil map reallocates on the next put). Also the hook a runtime font-atlas
// rebuild must call after mutating family.shaped/hb_font.
shape_cache_clear :: proc(cache: ^Shape_Cache) {
    for _, entry in cache.entries {
        delete(entry.key.line)
        delete(entry.glyphs)
        free(entry)
    }
    delete(cache.entries)
    cache.entries = nil
}

shape_cache_shutdown :: proc() {
    shape_cache_clear(&shape_cache)
    shape_cache.clock = 0
}
