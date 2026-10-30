package odin

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import lang ".."

@(private = "file")
CACHE_SRC :: `package demo

import "core:strings"

main :: proc() {
    _ = strings.clone("a")
}
`

@(private = "file")
cache_hover :: proc(e: ^Engine) -> lang.Result {
    req := lang.Request {
        kind   = .Hover,
        path   = "buffer.odin",
        ext    = ".odin",
        source = CACHE_SRC,
        offset = strings.index(CACHE_SRC, "clone"),
    }
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    return res
}

@(private = "file")
cache_files :: proc(dir: string) -> int {
    handle, err := os.open(dir)
    if err != nil {
        return 0
    }
    defer os.close(handle)
    infos, rerr := os.read_dir(handle, -1, context.allocator)
    if rerr != nil {
        return 0
    }
    defer os.file_info_slice_delete(infos, context.allocator)
    n := 0
    for info in infos {
        if strings.has_prefix(info.name, "items-") && strings.has_suffix(info.name, ".bin") {
            n += 1
        }
    }
    return n
}

// An engine writes the trees of the Odin root at destroy and removes the cache another compiler
// wrote; the next engine answers from them.
@(test)
test_tree_cache_across_engines :: proc(t: ^testing.T) {
    DIR :: "bin/test/odin_tree_cache"
    dir := DIR
    _ = os.remove_all(dir)
    defer os.remove_all(dir)
    testing.expect_value(t, os.make_directory_all(dir), nil)
    testing.expect_value(t, os.write_entire_file(DIR + "/items-0000000000000000.bin", "old"), nil)

    first := engine_create()
    engine_set_cache_dir(first, dir)
    res := cache_hover(first)
    want := strings.clone(res.hover.text, context.temp_allocator)
    delete(res.hover.text)
    if !testing.expect(t, res.ok, "expected a hover over strings.clone") {
        engine_destroy(first)
        return
    }
    testing.expect(t, sync.atomic_load(&first.db.stats.trees) > 1)
    engine_destroy(first)
    if !testing.expect_value(t, cache_files(dir), 1) {
        return
    }

    second := engine_create()
    defer engine_destroy(second)
    engine_set_cache_dir(second, dir)
    res = cache_hover(second)
    defer delete(res.hover.text)
    testing.expect(t, res.ok)
    testing.expect_value(t, res.hover.text, want)
    testing.expect(t, sync.atomic_load(&second.db.stats.cache_hits) > 0)
}
