package odinsema

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
read_plain :: proc(path: string, allocator: mem.Allocator) -> (string, bool) {
    data, err := os.read_entire_file(path, allocator)
    return string(data), err == nil
}

@(private = "file")
encode_of :: proc(tree: ^Item_Tree, lines: []int) -> []byte {
    buf := make([dynamic]byte, context.temp_allocator)
    if !tree_encode(tree, lines, &buf) {
        return nil
    }
    return buf[:]
}

// Decoding an encoded item tree of each core:strings file gives the same tree.
@(test)
test_tree_codec_round_trip :: proc(t: ^testing.T) {
    dir := fmt.tprintf("%s/core/strings", strings.trim_right(ODIN_ROOT, "/\\"))
    handle, oerr := os.open(dir)
    if !testing.expect_value(t, oerr, nil) {
        return
    }
    defer os.close(handle)
    infos, rerr := os.read_dir(handle, -1, context.allocator)
    if !testing.expect_value(t, rerr, nil) {
        return
    }
    defer os.file_info_slice_delete(infos, context.allocator)
    count := 0
    for info in infos {
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        text, ok := read_plain(info.fullpath, context.allocator)
        if !testing.expect(t, ok) {
            continue
        }
        defer delete(text)
        parsed, perr := odinsyntax.parse(text)
        if !testing.expect_value(t, perr, nil) {
            continue
        }
        defer odinsyntax.parse_destroy(&parsed)
        tree, terr := item_tree(parsed)
        if !testing.expect_value(t, terr, nil) {
            continue
        }
        defer item_tree_destroy(tree)
        lines := line_starts(text, context.temp_allocator)
        blob := encode_of(tree, lines)
        if !testing.expectf(t, blob != nil, "%s must encode", info.name) {
            continue
        }
        back, back_lines, dok := tree_decode(blob)
        if !testing.expectf(t, dok, "%s must decode", info.name) {
            continue
        }
        defer item_tree_destroy(back)
        defer delete(back_lines)
        testing.expect(t, slice.equal(encode_of(back, back_lines), blob))
        testing.expect(t, slice.equal(back_lines, lines))
        testing.expect_value(t, item_tree_shape_hash(back), item_tree_shape_hash(tree))
        testing.expect_value(t, back.package_name, tree.package_name)
        testing.expect_value(t, len(back.items), len(tree.items))
        for item, i in tree.items {
            testing.expect_value(t, back.items[i].name, item.name)
            testing.expect_value(t, back.items[i].signature, item.signature)
            testing.expect_value(t, back.items[i].doc, item.doc)
            testing.expect_value(t, len(back.items[i].children), len(item.children))
        }
        count += 1
    }
    testing.expect(t, count > 3)
}

// A truncated or altered encoding is refused or decodes without fault.
@(test)
test_tree_codec_corrupt :: proc(t: ^testing.T) {
    text := "package p\n\n// Doc.\nRec :: struct {\n    a: int,\n}\n\nwhen ODIN_OS == .Windows {\n    f :: proc(x: int) -> int { return x }\n}\n"
    parsed, perr := odinsyntax.parse(text)
    if !testing.expect_value(t, perr, nil) {
        return
    }
    defer odinsyntax.parse_destroy(&parsed)
    tree, terr := item_tree(parsed)
    if !testing.expect_value(t, terr, nil) {
        return
    }
    defer item_tree_destroy(tree)
    blob := encode_of(tree, line_starts(text, context.temp_allocator))
    if !testing.expect(t, blob != nil) {
        return
    }
    for n in 0 ..< len(blob) {
        back, lines, ok := tree_decode(blob[:n])
        testing.expectf(t, !ok, "a blob cut to %d bytes must be refused", n)
        if ok {
            item_tree_destroy(back)
            delete(lines)
        }
    }
    bad := slice.clone(blob, context.temp_allocator)
    for i in 0 ..< len(bad) {
        saved := bad[i]
        bad[i] = ~saved
        if back, lines, ok := tree_decode(bad); ok {
            item_tree_destroy(back)
            delete(lines)
        }
        bad[i] = saved
    }
}

@(private = "file")
fixture_dir :: proc(t: ^testing.T, name: string) -> (string, bool) {
    dir := fmt.tprintf("bin/test/sema_codec_%s", name)
    _ = os.remove_all(dir)
    if !testing.expect_value(t, os.make_directory_all(dir), nil) {
        return "", false
    }
    return dir, true
}

@(private = "file")
codec_stats :: proc(db: ^Db) -> (reads, trees, hits: int) {
    return sync.atomic_load(&db.stats.reads), sync.atomic_load(&db.stats.trees), sync.atomic_load(&db.stats.cache_hits)
}

// A second database takes the trees of files under the Odin root from the blob of the first, parses
// on db_parse only, and rebuilds a tree whose stamp moved. A bad blob loads as empty.
@(test)
test_tree_cache_db :: proc(t: ^testing.T) {
    root, ok := fixture_dir(t, "root")
    if !ok {
        return
    }
    defer os.remove_all(root)
    pkg := fmt.tprintf("%s/core/p", root)
    testing.expect_value(t, os.make_directory_all(pkg), nil)
    path, _ := filepath.join({pkg, "a.odin"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(path, "package p\n\n// One.\none :: proc() {}\n"), nil)
    colls := Collections{odin_root = root}
    input := Snapshot_Input{target = target_host(), collections = &colls}
    KEY :: "root\nversion"

    blob: []byte
    {
        db: Db
        db_init(&db, read_plain)
        defer db_destroy(&db)
        snap: Snapshot
        if !testing.expect(t, snapshot_begin(&db, &snap, input)) {
            return
        }
        view := db_package(&snap, db_package_id(&snap, pkg))
        testing.expect(t, view != nil && len(package_scope_lookup(view.scope, "one")) > 0)
        snapshot_end(&snap)
        testing.expect_value(t, db_cache_added(&db), 1)
        eok: bool
        blob, eok = db_cache_encode(&db, KEY)
        testing.expect(t, eok)
        testing.expect_value(t, db_cache_added(&db), 0)
    }
    defer delete(blob)

    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)
    testing.expect(t, !db_cache_load(&db, blob, "other key"))
    for n in 0 ..< len(blob) {
        testing.expect(t, !db_cache_load(&db, blob[:n], KEY))
    }
    testing.expect(t, db_cache_load(&db, blob, KEY))
    {
        snap: Snapshot
        if !testing.expect(t, snapshot_begin(&db, &snap, input)) {
            return
        }
        defer snapshot_end(&snap)
        view := db_package(&snap, db_package_id(&snap, pkg))
        testing.expect(t, view != nil && len(package_scope_lookup(view.scope, "one")) > 0)
        reads, trees, hits := codec_stats(&db)
        testing.expect_value(t, reads, 0)
        testing.expect_value(t, trees, 0)
        testing.expect_value(t, hits, 1)
        data := db_file(&snap, db_file_id(&snap, path))
        testing.expect(t, data != nil && data.tree.items[0].doc == "One.")
        testing.expect(t, db_parse(&snap, db_file_id(&snap, path)) != nil)
        reads, _, _ = codec_stats(&db)
        testing.expect_value(t, reads, 1)
    }

    testing.expect_value(t, os.write_entire_file(path, "package p\n\none :: proc() {}\ntwo :: 2\n"), nil)
    db.stable_interval = 0
    {
        snap: Snapshot
        if !testing.expect(t, snapshot_begin(&db, &snap, input)) {
            return
        }
        defer snapshot_end(&snap)
        view := db_package(&snap, db_package_id(&snap, pkg))
        testing.expect(t, view != nil && len(package_scope_lookup(view.scope, "two")) > 0)
        _, trees, hits := codec_stats(&db)
        testing.expect_value(t, trees, 1)
        testing.expect_value(t, hits, 1)
        testing.expect_value(t, db_cache_added(&db), 1)
    }
}

// A file deleted from a package under the Odin root, or its whole directory, leaves the tree cache.
@(test)
test_tree_cache_prune :: proc(t: ^testing.T) {
    root, ok := fixture_dir(t, "prune")
    if !ok {
        return
    }
    defer os.remove_all(root)
    pkg := fmt.tprintf("%s/core/p", root)
    other := fmt.tprintf("%s/core/q", root)
    testing.expect_value(t, os.make_directory_all(pkg), nil)
    testing.expect_value(t, os.make_directory_all(other), nil)
    a, _ := filepath.join({pkg, "a.odin"}, context.temp_allocator)
    b, _ := filepath.join({pkg, "b.odin"}, context.temp_allocator)
    q, _ := filepath.join({other, "q.odin"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(a, "package p\n\none :: 1\n"), nil)
    testing.expect_value(t, os.write_entire_file(b, "package p\n\ntwo :: 2\n"), nil)
    testing.expect_value(t, os.write_entire_file(q, "package q\n\nthree :: 3\n"), nil)
    colls := Collections{odin_root = root}
    input := Snapshot_Input{target = target_host(), collections = &colls}

    db: Db
    db_init(&db, read_plain)
    defer db_destroy(&db)
    db.stable_interval = 0
    read_packages :: proc(t: ^testing.T, db: ^Db, input: Snapshot_Input, dirs: ..string) {
        snap: Snapshot
        if !testing.expect(t, snapshot_begin(db, &snap, input)) {
            return
        }
        defer snapshot_end(&snap)
        for dir in dirs {
            _ = db_package(&snap, db_package_id(&snap, dir))
        }
    }
    read_packages(t, &db, input, pkg, other)
    testing.expect_value(t, len(db.cache.entries), 3)
    _, eok := db_cache_encode(&db, "key", context.temp_allocator)
    testing.expect(t, eok)

    testing.expect_value(t, os.remove(b), nil)
    read_packages(t, &db, input, pkg, other)
    testing.expect_value(t, len(db.cache.entries), 2)
    testing.expect_value(t, db_cache_added(&db), 1)

    testing.expect_value(t, os.remove(q), nil)
    testing.expect_value(t, os.remove(other), nil)
    read_packages(t, &db, input, pkg, other)
    testing.expect_value(t, len(db.cache.entries), 1)
}
