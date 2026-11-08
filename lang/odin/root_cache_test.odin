package odin

import "core:os"
import "core:strings"
import "core:testing"

// The root cache file holds a root only under its key and only while the root is a directory.
@(test)
test_root_cache_roundtrip :: proc(t: ^testing.T) {
    DIR :: "bin/test/odin_root_cache"
    _ = os.remove_all(DIR)
    defer os.remove_all(DIR)

    file := root_cache_file(DIR)
    testing.expect(t, file != "")
    testing.expect_value(t, root_cache_file(""), "")

    root := "bin/test/odin_root_cache/fake_root"
    testing.expect_value(t, os.make_directory_all(root), nil)
    root_cache_write(file, "key-a", root)

    testing.expect_value(t, root_cache_read(file, "key-a"), root)
    testing.expect_value(t, root_cache_read(file, "key-b"), "")

    testing.expect_value(t, os.remove(root), nil)
    testing.expect_value(t, root_cache_read(file, "key-a"), "")

    testing.expect_value(t, root_cache_read(DIR + "/missing.txt", "key-a"), "")
    testing.expect_value(t, os.write_entire_file(file, "garbage"), nil)
    testing.expect_value(t, root_cache_read(file, "key-a"), "")
}

// A root found once is read back from the cache directory by a second finder.
@(test)
test_root_cache_find :: proc(t: ^testing.T) {
    DIR :: "bin/test/odin_root_cache_find"
    _ = os.remove_all(DIR)
    defer os.remove_all(DIR)

    if _, set := os.lookup_env("ODIN_ROOT", context.temp_allocator); set {
        return
    }
    key := root_cache_key()
    if key == "" {
        return
    }
    first := odin_root_find(DIR)
    if first == "" {
        return
    }
    first = strings.clone(first, context.temp_allocator)
    file := root_cache_file(DIR)
    testing.expect(t, os.is_file(file))
    data, err := os.read_entire_file(file, context.temp_allocator)
    testing.expect_value(t, err, nil)
    testing.expect(t, strings.has_prefix(string(data), key))
    testing.expect_value(t, root_cache_read(file, key), first)
}
