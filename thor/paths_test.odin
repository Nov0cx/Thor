package thor

import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

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

// Case matters everywhere but Windows, where the filesystem itself folds it.
@(test)
test_same_path_case_sensitivity :: proc(t: ^testing.T) {
    when ODIN_OS == .Windows {
        testing.expect(t, thor_same_path("/src/Main.odin", "/src/main.odin"))
    } else {
        testing.expect(t, !thor_same_path("/src/Main.odin", "/src/main.odin"))
    }
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

@(test)
test_relative_path :: proc(t: ^testing.T) {
    sep :: filepath.SEPARATOR_STRING
    testing.expect_value(t, thor_relative_path("ws/sub/x.odin", "ws"), "sub" + sep + "x.odin")
    testing.expect_value(t, thor_relative_path("ws\\sub/x.odin", "ws/"), "sub" + sep + "x.odin")
    testing.expect(t, thor_relative_path("other/x.odin", "ws") != "x.odin")
}

@(test)
test_path_middle :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_path_middle("a/b.odin", 40), "a/b.odin")
    testing.expect_value(t, thor_path_middle("aaaaaaaaaa/bbbbbbbbbb/c.odin", 16), "aaaaaaa…/c.odin")
    testing.expect_value(t, thor_path_middle("verylongname.odin", 5), "verylongname.odin")
}

@(private = "file")
measure_chars :: proc(text: string) -> f32 {
    return f32(utf8.rune_count_in_string(text))
}

@(test)
test_cut_middle :: proc(t: ^testing.T) {
    head, tail, cut := thor_cut_middle("short", 10, measure_chars)
    testing.expect(t, !cut && head == 5 && tail == 5)

    text := "aaaaaaaaaa/bbbbbbbbbb/cccccccccc/"
    head, tail, cut = thor_cut_middle(text, 13, measure_chars)
    testing.expect(t, cut)
    shown := strings.concatenate({text[:head], "…", text[tail:]}, context.temp_allocator)
    testing.expect_value(t, utf8.rune_count_in_string(shown), 13)
    testing.expect_value(t, shown, "aaaa…ccccccc/")

    // A cut never splits a rune.
    wide := "ääääää/öööööö/"
    head, tail, cut = thor_cut_middle(wide, 6, measure_chars)
    testing.expect(t, cut && utf8.valid_string(wide[:head]) && utf8.valid_string(wide[tail:]))
}
