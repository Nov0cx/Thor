package odinsema

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"

@(private = "file")
read_text :: proc(path: string, allocator: mem.Allocator) -> (string, bool) {
    data, err := os.read_entire_file(path, allocator)
    return string(data), err == nil
}

// The type of `name` in `path`, printed; its underlying type when `underlying`.
@(private = "file")
decl_text :: proc(c: ^Checker, path, name: string, underlying := false, allocator := context.temp_allocator) -> string {
    sym, ok := find_symbol(c, db_file_id(c.snap, path), name)
    if !ok {
        return "<undeclared>"
    }
    id := decl_type(c, sym)
    if underlying {
        id = type_underlying(&c.table, id)
    }
    return type_string(&c.table, id, allocator)
}

@(private = "file")
Cache_Fixture :: struct {
    live:  string, // a/a.odin
    other: string, // a/other.odin
    dep:   string, // b/b.odin
}

@(private = "file")
cache_fixture :: proc(t: ^testing.T, name: string) -> (Cache_Fixture, string, bool) {
    dir, ok := check_fixture(t, name)
    if !ok {
        return {}, "", false
    }
    f := Cache_Fixture {
        live  = put_file(t, dir, "a/a.odin", "package a\n\nL :: struct { n: int }\n\nmain :: proc() {}\n"),
        other = put_file(t, dir, "a/other.odin", "package a\n\nimport \"../b\"\n\nv: b.S\nw: L\n"),
        dep   = put_file(t, dir, "b/b.odin", "package b\n\nS :: struct { x: int }\n"),
    }
    return f, dir, true
}

// Runs one snapshot and checker over the live buffer `text` and reads `v` and `w` of other.odin.
@(private = "file")
cache_request :: proc(t: ^testing.T, db: ^Db, f: Cache_Fixture, text: string) -> (v, w: string) {
    snap: Snapshot
    input := Snapshot_Input{target = target_host(), has_live = true, live_path = f.live, live_text = text}
    if !testing.expect(t, snapshot_begin(db, &snap, input), "snapshot_begin must succeed") {
        return
    }
    defer snapshot_end(&snap)
    c: Checker
    if !testing.expect_value(t, checker_init(&c, &snap), nil) {
        checker_destroy(&c)
        return
    }
    defer checker_destroy(&c)
    v = decl_text(&c, f.other, "v", true)
    w = decl_text(&c, f.other, "w", true)
    testing.expect_value(t, c.err, nil)
    return
}

@(private = "file")
cache_stats :: proc(db: ^Db) -> (hits, states: int) {
    return sync.atomic_load(&db.stats.type_hits), sync.atomic_load(&db.stats.type_states)
}

@(test)
test_type_cache_reuse_and_invalidate :: proc(t: ^testing.T) {
    f, dir, ok := cache_fixture(t, "tcache_invalidate")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    db: Db
    db_init(&db, read_text)
    defer db_destroy(&db)
    text := "package a\n\nL :: struct { n: int }\n\nmain :: proc() {}\n"

    v, w := cache_request(t, &db, f, text)
    testing.expect_value(t, v, "struct {x: int}")
    testing.expect_value(t, w, "struct {n: int}")
    hits, states := cache_stats(&db)
    testing.expect_value(t, hits, 0)
    testing.expect_value(t, states, 1)

    // A body edit of the live buffer keeps the state.
    v, w = cache_request(t, &db, f, "package a\n\nL :: struct { n: int }\n\nmain :: proc() { x := 1 }\n")
    testing.expect_value(t, v, "struct {x: int}")
    testing.expect_value(t, w, "struct {n: int}")
    hits, _ = cache_stats(&db)
    testing.expect_value(t, hits, 1)

    // A record of the live buffer is read again: `w` of another file depends on it.
    v, w = cache_request(t, &db, f, "package a\n\nL :: struct { n: f32 }\n\nmain :: proc() { x := 1 }\n")
    testing.expect_value(t, v, "struct {x: int}")
    testing.expect_value(t, w, "struct {n: f32}")
    hits, _ = cache_stats(&db)
    testing.expect_value(t, hits, 2)

    // A field type changed on disk in another package drops the state.
    put_file(t, dir, "b/b.odin", "package b\n\nS :: struct { x: f64, y: int }\n")
    v, w = cache_request(t, &db, f, text)
    testing.expect_value(t, v, "struct {x: f64, y: int}")
    testing.expect_value(t, w, "struct {n: int}")
    hits, states = cache_stats(&db)
    testing.expect_value(t, hits, 2)
    testing.expect_value(t, states, 2)

    // A file added to a package drops the state.
    put_file(t, dir, "b/more.odin", "package b\n\nT :: int\n")
    v, _ = cache_request(t, &db, f, text)
    testing.expect_value(t, v, "struct {x: f64, y: int}")
    hits, _ = cache_stats(&db)
    testing.expect_value(t, hits, 2)
    v, _ = cache_request(t, &db, f, text)
    hits, _ = cache_stats(&db)
    testing.expect_value(t, hits, 3)
}

// A new declaration in the live buffer can change what a name of another file of its package means.
@(test)
test_type_cache_live_shape :: proc(t: ^testing.T) {
    f, dir, ok := cache_fixture(t, "tcache_shape")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    db: Db
    db_init(&db, read_text)
    defer db_destroy(&db)
    v, _ := cache_request(t, &db, f, "package a\n\nL :: struct { n: int }\n\nmain :: proc() {}\n")
    testing.expect_value(t, v, "struct {x: int}")
    // `b` of the buffer shadows the import of other.odin.
    v, _ = cache_request(t, &db, f, "package a\n\nL :: struct { n: int }\nb :: struct { S: int }\n\nmain :: proc() {}\n")
    testing.expect(t, v != "struct {x: int}", "a declaration of the buffer must shadow the import")
    hits, _ := cache_stats(&db)
    testing.expect_value(t, hits, 0)
}

@(private = "file")
Cache_Worker :: struct {
    t:    ^testing.T,
    db:   ^Db,
    f:    Cache_Fixture,
    good: bool,
}

@(private = "file")
cache_worker_run :: proc(w: ^Cache_Worker) {
    w.good = true
    for i in 0 ..< 6 {
        text := fmt.aprintf("package a\n\nL :: struct {{ n: int }}\n\nmain :: proc() {{ x := %d }}\n", i)
        defer delete(text)
        snap: Snapshot
        input := Snapshot_Input{target = target_host(), has_live = true, live_path = w.f.live, live_text = text}
        if !snapshot_begin(w.db, &snap, input) {
            w.good = false
            return
        }
        c: Checker
        if checker_init(&c, &snap) == nil {
            v := decl_text(&c, w.f.other, "v", true, context.allocator)
            u := decl_text(&c, w.f.other, "w", true, context.allocator)
            w.good = w.good && v == "struct {x: int}" && u == "struct {n: int}" && c.err == nil
            delete(v)
            delete(u)
        } else {
            w.good = false
        }
        checker_destroy(&c)
        snapshot_end(&snap)
    }
}

@(test)
test_type_cache_concurrent :: proc(t: ^testing.T) {
    f, dir, ok := cache_fixture(t, "tcache_concurrent")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    db: Db
    db_init(&db, read_text)
    defer db_destroy(&db)

    workers: [6]Cache_Worker
    threads: [6]^thread.Thread
    for i in 0 ..< len(workers) {
        workers[i] = Cache_Worker{t = t, db = &db, f = f}
        threads[i] = thread.create_and_start_with_poly_data(&workers[i], cache_worker_run, init_context = context)
    }
    for th in threads {
        if th != nil {
            thread.join(th)
            thread.destroy(th)
        }
    }
    for w, i in workers {
        testing.expectf(t, w.good, "worker %d must see the right types", i)
    }
    hits, states := cache_stats(&db)
    testing.expectf(t, hits > 0, "a worker must start from a frozen state, got %d hits", hits)
    testing.expect(t, states >= 1)
}
