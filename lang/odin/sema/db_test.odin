package odinsema

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
read_plain :: proc(path: string, allocator: mem.Allocator) -> (string, bool) {
    data, err := os.read_entire_file(path, allocator)
    return string(data), err == nil
}

// Makes a fresh fixture directory under bin/test.
@(private = "file")
fixture :: proc(t: ^testing.T, name: string) -> (string, bool) {
    dir := fmt.tprintf("bin/test/sema_db_%s", name)
    _ = os.remove_all(dir)
    if !testing.expect_value(t, os.make_directory_all(dir), nil) {
        return "", false
    }
    return dir, true
}

@(private = "file")
put :: proc(t: ^testing.T, dir, name, text: string) -> string {
    path := fmt.tprintf("%s/%s", dir, name)
    testing.expect_value(t, os.write_entire_file(path, text), nil)
    return path
}

@(private = "file")
stats_of :: proc(db: ^Db) -> Db_Stats {
    return Db_Stats {
        reads        = sync.atomic_load(&db.stats.reads),
        parses       = sync.atomic_load(&db.stats.parses),
        reparses     = sync.atomic_load(&db.stats.reparses),
        trees        = sync.atomic_load(&db.stats.trees),
        scopes       = sync.atomic_load(&db.stats.scopes),
        local_scopes = sync.atomic_load(&db.stats.local_scopes),
    }
}

@(private = "file")
begin :: proc(t: ^testing.T, db: ^Db, snap: ^Snapshot, input := Snapshot_Input{}) -> bool {
    input := input
    if input.target.os == .Unknown {
        input.target = target_host()
    }
    return testing.expect(t, snapshot_begin(db, snap, input), "snapshot_begin must succeed")
}

@(private = "file")
has_name :: proc(view: ^Package_View, name: string) -> bool {
    return view != nil && len(package_scope_lookup(view.scope, name)) > 0
}

@(test)
test_db_file_reused :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "reuse")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    path := put(t, dir, "a.odin", "package a\n\nrun :: proc() {}\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)

    for _ in 0 ..< 2 {
        snap: Snapshot
        if !begin(t, &db, &snap) {
            return
        }
        data := db_file(&snap, db_file_id(&snap, path))
        testing.expect(t, data != nil && len(data.tree.items) == 1)
        testing.expect(t, db_in_build(&snap, db_file_id(&snap, path)))
        parsed := db_parse(&snap, db_file_id(&snap, path))
        testing.expect(t, parsed != nil && parsed.tree.text == "package a\n\nrun :: proc() {}\n")
        snapshot_end(&snap)
    }
    s := stats_of(&db)
    testing.expect_value(t, s.trees, 1)
    testing.expect_value(t, s.parses, 1)
    testing.expect_value(t, s.reads, 1)
}

@(test)
test_db_stat_refresh :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "refresh")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    a := put(t, dir, "a.odin", "package p\n\none :: 1\n")
    b := put(t, dir, "b.odin", "package p\n\ntwo :: 2\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)

    snap: Snapshot
    if !begin(t, &db, &snap) {
        return
    }
    first := db_file(&snap, db_file_id(&snap, a))
    view := db_package(&snap, db_package_id(&snap, dir))
    testing.expect(t, view != nil && len(view.files) == 2)
    testing.expect(t, has_name(view, "two"))

    put(t, dir, "a.odin", "package p\n\none :: 1\nthree :: 3\n")
    testing.expect_value(t, os.remove(b), nil)
    // The open snapshot already checked both files.
    testing.expect(t, db_file(&snap, db_file_id(&snap, a)) == first)
    snapshot_end(&snap)

    if !begin(t, &db, &snap) {
        return
    }
    defer snapshot_end(&snap)
    second := db_file(&snap, db_file_id(&snap, a))
    testing.expect(t, second != nil && len(second.tree.items) == 2)
    testing.expect(t, db_file(&snap, db_file_id(&snap, b)) == nil)
    view = db_package(&snap, db_package_id(&snap, dir))
    testing.expect(t, view != nil && len(view.files) == 1)
    testing.expect(t, has_name(view, "three"))
    testing.expect(t, !has_name(view, "two"))
    testing.expect_value(t, stats_of(&db).trees, 3)
}

@(private = "file")
fake_now: i64

@(private = "file")
fake_clock :: proc() -> i64 {
    return sync.atomic_load(&fake_now)
}

// A package under the Odin root is listed and stated once per interval; a workspace file once per snapshot.
@(test)
test_db_stable_throttle :: proc(t: ^testing.T) {
    root, ok := fixture(t, "stable_root")
    if !ok {
        return
    }
    defer os.remove_all(root)
    ws, wok := fixture(t, "stable_ws")
    if !wok {
        return
    }
    defer os.remove_all(ws)
    pkg := fmt.tprintf("%s/core/p", root)
    testing.expect_value(t, os.make_directory_all(pkg), nil)
    put(t, pkg, "a.odin", "package p\n\none :: 1\n")
    w := put(t, ws, "w.odin", "package w\n\nx :: 1\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)
    db.clock = fake_clock
    sync.atomic_store(&fake_now, i64(1_000_000_000))
    colls := Collections{odin_root = root}

    look :: proc(t: ^testing.T, db: ^Db, colls: ^Collections, pkg, w: string) -> (files: int, has_two: bool) {
        snap: Snapshot
        if !begin(t, db, &snap, Snapshot_Input{collections = colls}) {
            return
        }
        defer snapshot_end(&snap)
        testing.expect(t, db_file(&snap, db_file_id(&snap, w)) != nil)
        view := db_package(&snap, db_package_id(&snap, pkg))
        if !testing.expect(t, view != nil) {
            return
        }
        return len(view.files), has_name(view, "two")
    }

    files, two := look(t, &db, &colls, pkg, w)
    testing.expect_value(t, files, 1)
    stats := sync.atomic_load(&db.stats.stats)
    listings := sync.atomic_load(&db.stats.listings)

    sync.atomic_add(&fake_now, i64(time.Second))
    look(t, &db, &colls, pkg, w)
    testing.expect_value(t, sync.atomic_load(&db.stats.listings), listings)
    testing.expect_value(t, sync.atomic_load(&db.stats.stats), stats + 1)

    put(t, pkg, "a.odin", "package p\n\none :: 1\ntwo :: 2\n")
    put(t, pkg, "b.odin", "package p\n\nthree :: 3\n")
    sync.atomic_add(&fake_now, i64(time.Second))
    files, two = look(t, &db, &colls, pkg, w)
    testing.expect_value(t, files, 1)
    testing.expect(t, !two)

    sync.atomic_add(&fake_now, i64(STABLE_INTERVAL))
    files, two = look(t, &db, &colls, pkg, w)
    testing.expect_value(t, files, 2)
    testing.expect(t, two)
    testing.expect_value(t, sync.atomic_load(&db.stats.listings), listings + 1)
}

// A body edit keeps the package scope; a signature edit and a new file build it again.
@(test)
test_db_scope_early_cutoff :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "cutoff")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    a := put(t, dir, "a.odin", "package p\n\nrun :: proc() {\n}\n")
    put(t, dir, "b.odin", "package p\n\nwalk :: proc() {}\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)

    s1: Snapshot
    if !begin(t, &db, &s1) {
        return
    }
    defer snapshot_end(&s1)
    v1 := db_package(&s1, db_package_id(&s1, dir))
    d1 := db_file(&s1, db_file_id(&s1, a))
    if !testing.expect(t, v1 != nil && d1 != nil) {
        return
    }

    put(t, dir, "a.odin", "package p\n\n\nrun :: proc() {\n    x := 1\n    _ = x\n}\n")
    s2: Snapshot
    if !begin(t, &db, &s2) {
        return
    }
    defer snapshot_end(&s2)
    v2 := db_package(&s2, db_package_id(&s2, dir))
    d2 := db_file(&s2, db_file_id(&s2, a))
    if !testing.expect(t, v2 != nil && d2 != nil) {
        return
    }
    testing.expect(t, d2 != d1, "a rewrite must read the file again")
    testing.expect_value(t, d2.shape_changed_at, d1.shape_changed_at)
    testing.expect(t, v2.scope == v1.scope, "a body edit must keep the scope")
    testing.expect(t, !v2.local)
    testing.expect(t, v2.sema_files[0].items == d2.tree, "the view must read the current tree")
    refs := package_scope_lookup(v2.scope, "run")
    if testing.expect_value(t, len(refs), 1) {
        testing.expect_value(t, package_item(v2.sema_files, refs[0]).name_offset, 12)
    }
    testing.expect_value(t, stats_of(&db).scopes, 1)

    put(t, dir, "a.odin", "package p\n\n\nrun :: proc(n: int) {\n    x := 1\n    _ = x\n}\n")
    s3: Snapshot
    if !begin(t, &db, &s3) {
        return
    }
    defer snapshot_end(&s3)
    v3 := db_package(&s3, db_package_id(&s3, dir))
    testing.expect(t, v3 != nil && v3.scope != v2.scope, "a signature edit must build the scope again")
    testing.expect(t, db_file(&s3, db_file_id(&s3, a)).shape_changed_at > d2.shape_changed_at)
    testing.expect_value(t, stats_of(&db).scopes, 2)

    put(t, dir, "c.odin", "package p\n\nfly :: proc() {}\n")
    s4: Snapshot
    if !begin(t, &db, &s4) {
        return
    }
    defer snapshot_end(&s4)
    v4 := db_package(&s4, db_package_id(&s4, dir))
    testing.expect(t, v4 != nil && len(v4.files) == 3 && has_name(v4, "fly"))
    testing.expect_value(t, stats_of(&db).scopes, 3)
}

@(test)
test_db_target_change :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "target")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    host := target_host()
    other := host
    other.os = host.os == .Linux ? .Windows : .Linux
    path := put(t, dir, fmt.tprintf("x_%s.odin", target_os_name(other.os)), "package p\n\nonly_other :: 1\n")
    put(t, dir, "main.odin", "package p\n\nboth :: 1\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)

    for round in 0 ..< 2 {
        for target, i in ([]Target{host, other}) {
            snap: Snapshot
            if !begin(t, &db, &snap, Snapshot_Input{target = target}) {
                return
            }
            testing.expect_value(t, db_in_build(&snap, db_file_id(&snap, path)), i == 1)
            view := db_package(&snap, db_package_id(&snap, dir))
            testing.expect_value(t, has_name(view, "only_other"), i == 1)
            testing.expect(t, has_name(view, "both"))
            snapshot_end(&snap)
        }
        testing.expect_value(t, stats_of(&db).scopes, 2 * (round + 1))
    }
    testing.expect_value(t, stats_of(&db).trees, 2)
}

@(test)
test_db_live_overlay :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "live")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    a := put(t, dir, "a.odin", "package p\n\nrun :: proc() {}\n")
    put(t, dir, "b.odin", "package p\n\nwalk :: proc() {}\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)
    pkg_id: Package_Id

    {
        // A body edit: the live tree, the cached scope.
        snap: Snapshot
        if !begin(t, &db, &snap) {
            return
        }
        defer snapshot_end(&snap)
        pkg_id = db_package_id(&snap, dir)
        cached := db_package(&snap, pkg_id)
        if !testing.expect(t, cached != nil) {
            return
        }
        cached_scope := cached.scope
        snapshot_end(&snap)

        live_text := "package p\n\nrun :: proc() {\n    walk()\n}\n"
        if !begin(t, &db, &snap, Snapshot_Input{has_live = true, live_path = a, live_text = live_text}) {
            return
        }
        id := snapshot_live_file(&snap)
        testing.expect(t, id == db_file_id(&snap, a))
        data := db_file(&snap, id)
        testing.expect(t, data != nil && len(data.lines) == 6)
        parsed := db_parse(&snap, id)
        testing.expect(t, parsed != nil && parsed.tree.text == live_text)
        view := db_package(&snap, pkg_id)
        if !testing.expect(t, view != nil) {
            return
        }
        testing.expect(t, view.scope == cached_scope, "an equal shape must keep the cached scope")
        testing.expect(t, !view.local)
        testing.expect(t, view.datas[0] == data)
    }
    {
        // A new declaration: a scope of this snapshot only.
        snap: Snapshot
        if !begin(t, &db, &snap, Snapshot_Input{has_live = true, live_path = a, live_text = "package p\n\nrun :: proc() {}\nfresh :: 1\n"}) {
            return
        }
        view := db_package(&snap, pkg_id)
        testing.expect(t, view != nil && view.local)
        testing.expect(t, has_name(view, "fresh"))
        testing.expect(t, has_name(view, "walk"))
        snapshot_end(&snap)

        if !begin(t, &db, &snap) {
            return
        }
        view = db_package(&snap, pkg_id)
        testing.expect(t, view != nil && !view.local && !has_name(view, "fresh"), "the overlay must end with its snapshot")
        snapshot_end(&snap)
    }
    {
        // A buffer not on disk joins its directory.
        snap: Snapshot
        new_path := fmt.tprintf("%s/new.odin", dir)
        if !begin(t, &db, &snap, Snapshot_Input{has_live = true, live_path = new_path, live_text = "package p\n\nborn :: 1\n"}) {
            return
        }
        defer snapshot_end(&snap)
        view := db_package(&snap, pkg_id)
        testing.expect(t, view != nil && len(view.files) == 3 && view.local)
        testing.expect(t, has_name(view, "born") && has_name(view, "run"))
        testing.expect(t, db_in_build(&snap, snapshot_live_file(&snap)))
    }
    {
        // A buffer with no file.
        snap: Snapshot
        if !begin(t, &db, &snap, Snapshot_Input{has_live = true, live_text = "package q\n\nalone :: 1\n"}) {
            return
        }
        defer snapshot_end(&snap)
        id := snapshot_live_file(&snap)
        testing.expect(t, id == ANON_FILE)
        data := db_file(&snap, id)
        testing.expect(t, data != nil && len(data.tree.items) == 1)
        testing.expect(t, db_parse(&snap, id) != nil)
        testing.expect(t, !db_in_build(&snap, id))
    }
}

@(test)
test_db_live_reparse :: proc(t: ^testing.T) {
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)
    path := "bin/test/sema_db_reparse/a.odin"
    texts := []string {
        "package p\n\nrun :: proc() {\n    x := 1\n}\n",
        "package p\n\nrun :: proc() {\n    x := 12\n}\n",
        "package p\n\nrun :: proc() {\n    x := 123\n}\n",
        "package p\n\nrun :: proc() {\n    x := 1234\n}\n",
    }
    for text in texts[:2] {
        snap: Snapshot
        if !begin(t, &db, &snap, Snapshot_Input{has_live = true, live_path = path, live_text = text}) {
            return
        }
        parsed := db_parse(&snap, snapshot_live_file(&snap))
        testing.expect(t, parsed != nil && parsed.tree.text == text)
        snapshot_end(&snap)
    }
    s := stats_of(&db)
    testing.expect_value(t, s.parses, 1)
    testing.expect_value(t, s.reparses, 1)

    // The same text again reuses the parse.
    snap: Snapshot
    if !begin(t, &db, &snap, Snapshot_Input{has_live = true, live_path = path, live_text = texts[1]}) {
        return
    }
    held := db_parse(&snap, snapshot_live_file(&snap))
    testing.expect_value(t, stats_of(&db).trees, 2)

    // A pinned parse cannot be consumed, so the next text parses in full.
    other: Snapshot
    if !begin(t, &db, &other, Snapshot_Input{has_live = true, live_path = path, live_text = texts[2]}) {
        snapshot_end(&snap)
        return
    }
    testing.expect(t, db_parse(&other, snapshot_live_file(&other)) != nil)
    snapshot_end(&other)
    testing.expect(t, held != nil && held.tree.text == texts[1], "a pinned parse must stay valid")
    snapshot_end(&snap)
    s = stats_of(&db)
    testing.expect_value(t, s.parses, 2)
    testing.expect_value(t, s.reparses, 1)

    if !begin(t, &db, &snap, Snapshot_Input{has_live = true, live_path = path, live_text = texts[3]}) {
        return
    }
    testing.expect(t, db_parse(&snap, snapshot_live_file(&snap)) != nil)
    snapshot_end(&snap)
    testing.expect_value(t, stats_of(&db).reparses, 2)
}

@(test)
test_db_cancel :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "cancel")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    put(t, dir, "a.odin", "package p\n\nrun :: 1\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)

    snap: Snapshot
    if !begin(t, &db, &snap) {
        return
    }
    pkg := db_package_id(&snap, dir)
    testing.expect(t, db_package(&snap, pkg) != nil)
    testing.expect_value(t, len(db_workspace(&snap, dir)), 1)
    snapshot_end(&snap)

    put(t, dir, "b.odin", "package p\n\nwalk :: 1\n")
    cancel := true
    if !begin(t, &db, &snap, Snapshot_Input{cancel = &cancel}) {
        return
    }
    testing.expect(t, snapshot_cancelled(&snap))
    testing.expect(t, db_package(&snap, pkg) == nil)
    testing.expect(t, db_workspace(&snap, dir) == nil)
    snapshot_end(&snap)
    testing.expect(t, db.packages[pkg].memo != nil, "a cancelled request must keep the old memo")
    testing.expect_value(t, len(db.workspace.files), 1)
    testing.expect_value(t, stats_of(&db).scopes, 1)

    if !begin(t, &db, &snap) {
        return
    }
    defer snapshot_end(&snap)
    view := db_package(&snap, pkg)
    testing.expect(t, view != nil && len(view.files) == 2 && has_name(view, "walk"))
    testing.expect_value(t, len(db_workspace(&snap, dir)), 2)
    testing.expect_value(t, stats_of(&db).scopes, 2)
}

@(private = "file")
Worker :: struct {
    db:    ^Db,
    dir:   string,
    found: bool,
}

@(private = "file")
worker_run :: proc(w: ^Worker) {
    snap: Snapshot
    if !snapshot_begin(w.db, &snap, Snapshot_Input{target = target_host()}) {
        return
    }
    defer snapshot_end(&snap)
    view := db_package(&snap, db_package_id(&snap, w.dir))
    w.found = has_name(view, "f3") && len(view.files) == 6
}

@(test)
test_db_concurrent_package :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "concurrent")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    for i in 0 ..< 6 {
        put(t, dir, fmt.tprintf("f%d.odin", i), fmt.tprintf("package p\n\nf%d :: proc() {{}}\n", i))
    }
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)

    workers: [8]Worker
    threads: [8]^thread.Thread
    for i in 0 ..< len(workers) {
        workers[i] = Worker{db = &db, dir = dir}
        threads[i] = thread.create_and_start_with_poly_data(&workers[i], worker_run, init_context = context)
    }
    for th in threads {
        if th != nil {
            thread.join(th)
            thread.destroy(th)
        }
    }
    for w, i in workers {
        testing.expectf(t, w.found, "worker %d must see the package", i)
    }
    s := stats_of(&db)
    testing.expect_value(t, s.scopes, 1)
    testing.expect_value(t, s.trees, 6)
}

@(test)
test_db_body_budget :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "budget")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    a := put(t, dir, "a.odin", "package p\n\nrun :: proc() {}\n")
    b := put(t, dir, "b.odin", "package p\n\nwalk :: proc() {}\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)
    db.body_budget = 1

    snap: Snapshot
    if !begin(t, &db, &snap) {
        return
    }
    aid := db_file_id(&snap, a)
    bid := db_file_id(&snap, b)
    testing.expect(t, db_file(&snap, bid) != nil)
    testing.expect(t, db.files[bid].body == nil, "an unpinned parse past the budget must be freed")
    testing.expect(t, db.files[bid].disk != nil, "the declarations stay")

    held := db_parse(&snap, aid)
    testing.expect(t, held != nil)
    testing.expect(t, db.files[aid].body == nil, "the database must drop its own reference")
    testing.expect(t, held != nil && held.tree.text == "package p\n\nrun :: proc() {}\n", "a pinned parse lives until snapshot_end")
    snapshot_end(&snap)

    parses := stats_of(&db).parses
    if !begin(t, &db, &snap) {
        return
    }
    defer snapshot_end(&snap)
    testing.expect(t, db_parse(&snap, aid) != nil)
    testing.expect_value(t, stats_of(&db).parses, parses + 1)
    testing.expect_value(t, stats_of(&db).trees, 2)
}

@(test)
test_db_workspace_walk :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "workspace")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    for sub in ([]string{"sub", ".git", "sub/deep"}) {
        testing.expect_value(t, os.make_directory_all(fmt.tprintf("%s/%s", dir, sub)), nil)
    }
    put(t, dir, "main.odin", "package main\n")
    put(t, dir, "notes.txt", "text\n")
    put(t, dir, "sub/a.odin", "package sub\n")
    put(t, dir, "sub/deep/b.odin", "package deep\n")
    put(t, dir, ".git/hook.odin", "package hook\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)

    snap: Snapshot
    if !begin(t, &db, &snap) {
        return
    }
    files := db_workspace(&snap, dir)
    testing.expect_value(t, len(files), 3)
    for id in files {
        path := db_file_path(&snap, id)
        testing.expectf(t, !contains_dot_dir(path), "%s must be skipped", path)
    }
    testing.expect(t, len(files) == 3 && db_file_path(&snap, files[0]) < db_file_path(&snap, files[1]), "the files must be sorted")
    for id in files {
        testing.expect_value(t, sync.atomic_load(&db.files[id].holders), 1)
    }
    snapshot_end(&snap)

    db.workspace_limit = 2
    if !begin(t, &db, &snap) {
        return
    }
    defer snapshot_end(&snap)
    testing.expect_value(t, len(db_workspace(&snap, dir)), 2)
}

@(private = "file")
contains_dot_dir :: proc(path: string) -> bool {
    for i in 0 ..< len(path) - 1 {
        if (path[i] == '/' || path[i] == '\\') && path[i + 1] == '.' {
            return true
        }
    }
    return false
}

@(private = "file")
body_pins :: proc(snap: ^Snapshot) -> int {
    n := 0
    for v in snap.pins {
        if v.kind == .File_Body {
            n += 1
        }
    }
    return n
}

@(test)
test_db_parse_release :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "release")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    a := put(t, dir, "a.odin", "package p\n\nrun :: proc() {}\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)

    snap: Snapshot
    if !begin(t, &db, &snap) {
        return
    }
    defer snapshot_end(&snap)
    aid := db_file_id(&snap, a)
    first := db_parse(&snap, aid)
    second := db_parse(&snap, aid)
    testing.expect(t, first != nil && first == second, "a cached parse is shared")
    testing.expect_value(t, body_pins(&snap), 2)
    db_parse_release(&snap, second)
    testing.expect_value(t, body_pins(&snap), 1)
    testing.expect(t, first.tree.text == "package p\n\nrun :: proc() {}\n", "the other pin keeps the parse")
    db_parse_release(&snap, first)
    testing.expect_value(t, body_pins(&snap), 0)
    testing.expect(t, db.files[aid].body != nil, "a parse in the budget stays cached")
    db_parse_release(&snap, first)
    testing.expect(t, db.files[aid].body != nil && db.files[aid].body.refs == 1, "a second release is a no-op")

    db.body_budget = 1
    held := db_parse(&snap, aid)
    testing.expect(t, held != nil && db.files[aid].body == nil, "past the budget only the pin holds the parse")
    testing.expect_value(t, body_pins(&snap), 1)
    db_parse_release(&snap, held)
    testing.expect_value(t, body_pins(&snap), 0)
}

@(private = "file")
workspace_now: i64

@(private = "file")
workspace_clock :: proc() -> i64 {
    return sync.atomic_load(&workspace_now)
}

// A workspace file and directory are checked at most once per workspace interval; a touch makes the
// next snapshot check them at once.
@(test)
test_db_workspace_throttle :: proc(t: ^testing.T) {
    dir, ok := fixture(t, "workspace_throttle")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    a := put(t, dir, "a.odin", "package p\n\none :: 1\n")
    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)
    db.clock = workspace_clock
    db.workspace_interval = i64(WORKSPACE_INTERVAL)
    sync.atomic_store(&workspace_now, i64(1_000_000_000))

    look :: proc(t: ^testing.T, db: ^Db, dir: string) -> (files: int, has_two: bool) {
        snap: Snapshot
        if !begin(t, db, &snap) {
            return
        }
        defer snapshot_end(&snap)
        view := db_package(&snap, db_package_id(&snap, dir))
        if !testing.expect(t, view != nil) {
            return
        }
        return len(view.files), has_name(view, "two")
    }

    files, two := look(t, &db, dir)
    testing.expect_value(t, files, 1)
    stats := sync.atomic_load(&db.stats.stats)
    listings := sync.atomic_load(&db.stats.listings)

    put(t, dir, "a.odin", "package p\n\none :: 1\ntwo :: 2\n")
    put(t, dir, "b.odin", "package p\n\nthree :: 3\n")
    sync.atomic_add(&workspace_now, i64(WORKSPACE_INTERVAL / 2))
    files, two = look(t, &db, dir)
    testing.expect_value(t, files, 1)
    testing.expect(t, !two)
    testing.expect_value(t, sync.atomic_load(&db.stats.stats), stats)
    testing.expect_value(t, sync.atomic_load(&db.stats.listings), listings)

    db_touch(&db, a)
    files, two = look(t, &db, dir)
    testing.expect_value(t, files, 2)
    testing.expect(t, two)

    put(t, dir, "b.odin", "package p\n\nthree :: 3\nfour :: 4\n")
    sync.atomic_add(&workspace_now, i64(WORKSPACE_INTERVAL))
    stats = sync.atomic_load(&db.stats.stats)
    look(t, &db, dir)
    testing.expect(t, sync.atomic_load(&db.stats.stats) > stats)
}
