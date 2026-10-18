package vt

import "core:strings"

// An interned string pool a cell refers to by id.
@(private)
Pool :: enum {
    Link,
    Grapheme,
}

// Returns the id of `text` in a pool, adding it when new. A full pool is first
// compacted to the ids a cell or a pen still holds.
@(private)
pool_intern :: proc(t: ^Term, which: Pool, text: string) -> (u32, bool) {
    strs, ids, limit := pool_of(t, which)
    if id, found := ids[text]; found {
        return id, true
    }
    if len(strs) >= limit {
        pool_compact(t, which)
        if len(strs) >= limit {
            return 0, false
        }
    }
    s, err := strings.clone(text, t.allocator)
    if err != nil {
        return 0, false
    }
    append(strs, s)
    id := u32(len(strs) - 1)
    ids[s] = id
    return id, true
}

@(private = "file")
pool_of :: proc(t: ^Term, which: Pool) -> (^[dynamic]string, ^map[string]u32, int) {
    switch which {
    case .Link:
        return &t.links, &t.link_ids, MAX_LINKS
    case .Grapheme:
        return &t.graphemes, &t.grapheme_ids, MAX_GRAPHEMES
    }
    unreachable()
}

// Drops the entries no cell or pen refers to and renumbers the rest.
@(private)
pool_compact :: proc(t: ^Term, which: Pool) {
    strs, ids, _ := pool_of(t, which)
    remap, err := make([]u32, len(strs), t.allocator)
    if err != nil {
        return
    }
    defer delete(remap, t.allocator)

    pool_visit(t, which, remap, proc(remap: []u32, id: ^u32) {
        if int(id^) < len(remap) {
            remap[id^] = 1
        }
    })

    next := 1
    for i in 1 ..< len(strs) {
        if remap[i] == 0 {
            delete(strs[i], t.allocator)
            continue
        }
        remap[i] = u32(next)
        strs[next] = strs[i]
        next += 1
    }
    resize(strs, next)
    clear(ids)
    for i in 1 ..< len(strs) {
        ids[strs[i]] = u32(i)
    }

    pool_visit(t, which, remap, proc(remap: []u32, id: ^u32) {
        id^ = int(id^) < len(remap) ? remap[id^] : 0
    })
}

// Calls `visit` on every non-zero id of the pool held by a cell or a pen.
@(private = "file")
pool_visit :: proc(t: ^Term, which: Pool, remap: []u32, visit: proc(remap: []u32, id: ^u32)) {
    grids := [3]^[dynamic]Line{&t.primary, &t.alt, &t.scrollback}
    for grid in grids {
        for &line in grid {
            for &cell in line.cells {
                id := which == .Link ? &cell.link : &cell.grapheme
                if id^ != 0 {
                    visit(remap, id)
                }
            }
        }
    }
    if which == .Link {
        pens := [3]^Pen{&t.cur.pen, &t.saved.cur.pen, &t.saved_alt.cur.pen}
        for pen in pens {
            if pen.link != 0 {
                visit(remap, &pen.link)
            }
        }
    }
}

// Empties both pools back to their "none" entry.
@(private)
pool_clear :: proc(t: ^Term) {
    for link in t.links[1:] {
        delete(link, t.allocator)
    }
    resize(&t.links, 1)
    clear(&t.link_ids)
    for g in t.graphemes[1:] {
        delete(g, t.allocator)
    }
    resize(&t.graphemes, 1)
    clear(&t.grapheme_ids)
}
