package thor

import "core:testing"

// The same file reached through either separator spelling is one file.
@(test)
test_same_path_separator_spelling :: proc(t: ^testing.T) {
    testing.expect(t, thor_same_path("/a/b/c.odin", "/a\\b\\c.odin"))
    testing.expect(t, thor_same_path("/a/./b/c.odin", "/a/b/c.odin"))
    testing.expect(t, thor_same_path("/a/x/../b/c.odin", "/a/b/c.odin"))
    testing.expect(t, !thor_same_path("/a/b/c.odin", "/a/b/d.odin"))
}

// A relative spelling still matches the absolute form the editor stores, which
// is what lets a tab opened from the command line dedupe against the explorer's.
@(test)
test_same_path_relative_matches_absolute :: proc(t: ^testing.T) {
    absolute := thor_abs_path("paths_probe.tmp")
    testing.expect(t, absolute != "paths_probe.tmp", "the path was never made absolute")
    testing.expect(t, thor_same_path("paths_probe.tmp", absolute))
}

// A sibling whose name merely starts with the ancestor's is not within it.
@(test)
test_path_within_boundary :: proc(t: ^testing.T) {
    testing.expect(t, thor_path_within("/a/b", "/a/b"))
    testing.expect(t, thor_path_within("/a/b/c.odin", "/a/b"))
    testing.expect(t, thor_path_within("/a/b/", "/a/b"))
    testing.expect(t, !thor_path_within("/a/bc/d.odin", "/a/b"))
    testing.expect(t, !thor_path_within("/a", "/a/b"))
}

@(test)
test_file_extension_and_base :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_file_extension("main.odin"), ".odin")
    testing.expect_value(t, thor_file_extension("Makefile"), "")
    testing.expect_value(t, thor_file_extension("a.b/c"), ".b/c")
    testing.expect_value(t, thor_file_base("app/Dockerfile"), "Dockerfile")
    testing.expect_value(t, thor_file_base("app\\Dockerfile"), "Dockerfile")
    testing.expect_value(t, thor_file_base("Dockerfile"), "Dockerfile")
}
