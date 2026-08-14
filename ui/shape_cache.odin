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
    // Recency list links, borrowed. Entries are heap-stable, so the list holds
    // the LRU order without a stamp or a scan.
    newer:  ^Shape_Cache_Entry,
    older:  ^Shape_Cache_Entry,
}

// Draw-time shaping cache. Main thread only, like the rest of shape.odin, so
// no locking; every proc below takes the cache explicitly so tests can use
// an isolated instance instead of the shared package one.
Shape_Cache :: struct {
    entries: map[Shape_Cache_Key]^Shape_Cache_Entry,
    newest:  ^Shape_Cache_Entry, // most recently used, borrowed
    oldest:  ^Shape_Cache_Entry, // eviction victim, borrowed
}

// Detaches an entry from the recency list.
@(private = "file")
shape_cache_unlink :: proc(cache: ^Shape_Cache, entry: ^Shape_Cache_Entry) {
    if entry.older != nil {
        entry.older.newer = entry.newer
    } else {
        cache.oldest = entry.newer
    }
    if entry.newer != nil {
        entry.newer.older = entry.older
    } else {
        cache.newest = entry.older
    }
    entry.newer = nil
    entry.older = nil
}

// Puts an unlinked entry at the most-recent end.
@(private = "file")
shape_cache_link_newest :: proc(cache: ^Shape_Cache, entry: ^Shape_Cache_Entry) {
    entry.older = cache.newest
    entry.newer = nil
    if cache.newest != nil {
        cache.newest.newer = entry
    }
    cache.newest = entry
    if cache.oldest == nil {
        cache.oldest = entry
    }
}

// Draw-time cache; the one shape_place_line consults. Main thread only,
// freed in text_shutdown.
@(private)
shape_cache: Shape_Cache

// Cache lookup; a hit bumps the entry's recency and hands back its
// cache-owned glyphs directly (no HarfBuzz, no itemizing).
shape_cache_get :: proc(cache: ^Shape_Cache, key: Shape_Cache_Key) -> ([]Placed_Glyph, bool) {
    entry, hit := cache.entries[key]
    if !hit {
        return nil, false
    }
    shape_cache_unlink(cache, entry)
    shape_cache_link_newest(cache, entry)
    return entry.glyphs, true
}

// Clones key and glyphs into cache-owned storage and inserts, evicting the
// least recently used entry first if the cache is at capacity. Returns the
// cache-owned glyphs slice, safe for the caller to hand onward.
shape_cache_put :: proc(cache: ^Shape_Cache, key: Shape_Cache_Key, glyphs: []Placed_Glyph) -> []Placed_Glyph {
    if len(cache.entries) >= SHAPE_CACHE_CAPACITY {
        shape_cache_evict_oldest(cache)
    }
    entry := new(Shape_Cache_Entry)
    entry.key = key
    entry.key.line = strings.clone(key.line)
    entry.glyphs = slice.clone(glyphs)
    shape_cache_link_newest(cache, entry)
    cache.entries[entry.key] = entry
    return entry.glyphs
}

// Drops the tail of the recency list.
@(private = "file")
shape_cache_evict_oldest :: proc(cache: ^Shape_Cache) {
    oldest := cache.oldest
    if oldest == nil {
        return
    }
    shape_cache_unlink(cache, oldest)
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
    cache.newest = nil
    cache.oldest = nil
}

shape_cache_shutdown :: proc() {
    shape_cache_clear(&shape_cache)
}
