package odinsema

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
FIXTURE_DIR :: "bin/test/sema_imports_fixture"

@(private = "file")
Imports_Case :: struct {
    tree:    ^Item_Tree,
    imports: []File_Import,
}

@(private = "file")
read_imports :: proc(t: ^testing.T, src, file_dir: string, collections: ^Collections) -> (c: Imports_Case, ok: bool) {
    parsed, perr := odinsyntax.parse(src)
    if !testing.expect_value(t, perr, nil) {
        return
    }
    defer odinsyntax.parse_destroy(&parsed)
    tree, terr := item_tree(parsed)
    if !testing.expect_value(t, terr, nil) {
        return
    }
    imports, ierr := file_imports(tree, file_dir, collections)
    if !testing.expect_value(t, ierr, nil) {
        item_tree_destroy(tree)
        return
    }
    return Imports_Case{tree, imports}, true
}

@(private = "file")
destroy_case :: proc(c: ^Imports_Case) {
    file_imports_destroy(c.imports)
    item_tree_destroy(c.tree)
}

// `path` with `/` as the only separator.
@(private = "file")
slashed :: proc(path: string) -> string {
    out, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
    return out
}

@(private = "file")
odin_root :: proc() -> string {
    if v, found := os.lookup_env("ODIN_ROOT", context.temp_allocator); found && v != "" {
        return v
    }
    return ODIN_ROOT
}

@(test)
test_import_aliases :: proc(t: ^testing.T) {
    src := `package app

import "core:fmt"
import f "core:strings"
import "core:encoding/json"
import _ "core:mem"
import "foo/bar-baz"
import "shared:util/"
foreign import kernel32 "system:Kernel32.lib"
`
    collections := Collections{odin_root = "odin"}
    c, ok := read_imports(t, src, "app", &collections)
    if !ok {
        return
    }
    defer destroy_case(&c)
    if !testing.expect_value(t, len(c.imports), 7) {
        return
    }
    want := []struct {
        alias:    string,
        explicit: bool,
        valid:    bool,
        coll:     string,
        dir:      string,
    } {
        {"fmt", false, true, "core", "odin/core/fmt"},
        {"f", true, true, "core", "odin/core/strings"},
        {"json", false, true, "core", "odin/core/encoding/json"},
        {"_", true, true, "core", "odin/core/mem"},
        {"bar-baz", false, false, "", "app/foo/bar-baz"},
        {"util", false, true, "shared", "odin/shared/util"},
    }
    for w, i in want {
        imp := c.imports[i]
        testing.expect_value(t, imp.alias, w.alias)
        testing.expect_value(t, imp.explicit, w.explicit)
        testing.expect_value(t, imp.alias_valid, w.valid)
        testing.expect_value(t, imp.collection, w.coll)
        testing.expect_value(t, slashed(imp.dir), w.dir)
        testing.expect_value(t, imp.is_foreign, false)
        testing.expect_value(t, imp.problem, Import_Problem.Missing_Dir)
        testing.expect_value(t, imp.exists, false)
    }
    kernel := c.imports[6]
    testing.expect_value(t, kernel.is_foreign, true)
    testing.expect_value(t, kernel.alias, "kernel32")
    testing.expect_value(t, kernel.path, "system:Kernel32.lib")
    testing.expect_value(t, kernel.dir, "")

    // Offsets point at the alias and the opening quote of the path.
    fmt_imp := c.imports[0]
    testing.expect_value(t, src[fmt_imp.name_offset:][:len(`"core:fmt"`)], `"core:fmt"`)
    testing.expect_value(t, fmt_imp.path_offset, fmt_imp.name_offset)
    f_imp := c.imports[1]
    testing.expect_value(t, src[f_imp.name_offset:][:1], "f")
    testing.expect(t, f_imp.path_offset >= 0)
    if f_imp.path_offset >= 0 {
        testing.expect_value(t, src[f_imp.path_offset:][:len(`"core:strings"`)], `"core:strings"`)
    }

    found, fok := lookup_import(c.imports, "f")
    testing.expect(t, fok && found.path == "core:strings")
    _, sok := lookup_import(c.imports, "strings")
    testing.expect(t, !sok)
    _, bok := lookup_import(c.imports, "_")
    testing.expect(t, !bok)
    _, kok := lookup_import(c.imports, "kernel32")
    testing.expect(t, !kok)
    _, iok := lookup_import(c.imports, "bar-baz")
    testing.expect(t, !iok)
}

@(test)
test_import_relative_and_unknown :: proc(t: ^testing.T) {
    src := `package app

import "../lib"
import "./sub/./inner"
import "mine:tools/x"
import "nope:thing"
import "core:fmt"
`
    custom := []Collection{{"mine", "ext/mine"}}
    collections := Collections{custom = custom}
    c, ok := read_imports(t, src, "work/app/src", &collections)
    if !ok {
        return
    }
    defer destroy_case(&c)
    if !testing.expect_value(t, len(c.imports), 5) {
        return
    }
    testing.expect_value(t, c.imports[0].alias, "lib")
    testing.expect_value(t, slashed(c.imports[0].dir), "work/app/lib")
    testing.expect_value(t, c.imports[0].collection, "")
    testing.expect_value(t, c.imports[1].alias, "inner")
    testing.expect_value(t, slashed(c.imports[1].dir), "work/app/src/sub/inner")
    testing.expect_value(t, c.imports[2].collection, "mine")
    testing.expect_value(t, slashed(c.imports[2].dir), "ext/mine/tools/x")
    testing.expect_value(t, c.imports[3].problem, Import_Problem.Unknown_Collection)
    testing.expect_value(t, c.imports[3].collection, "nope")
    testing.expect_value(t, c.imports[3].dir, "")
    testing.expect_value(t, c.imports[4].problem, Import_Problem.No_Odin_Root)
    testing.expect_value(t, c.imports[4].dir, "")
}

@(test)
test_import_backslash_dir :: proc(t: ^testing.T) {
    src := "package app\n\nimport \"../lib\"\nimport \"..\\\\other\\\\pkg\"\n"
    c, ok := read_imports(t, src, "D:\\work\\app\\src\\", nil)
    if !ok {
        return
    }
    defer destroy_case(&c)
    if !testing.expect_value(t, len(c.imports), 2) {
        return
    }
    testing.expect_value(t, slashed(c.imports[0].dir), "D:/work/app/lib")
    testing.expect_value(t, c.imports[1].alias, "pkg")
    testing.expect_value(t, slashed(c.imports[1].dir), "D:/work/app/other/pkg")
}

@(test)
test_import_odin_root :: proc(t: ^testing.T) {
    root := odin_root()
    fmt_dir, jerr := filepath.join({root, "core", "fmt"}, context.temp_allocator)
    if !testing.expect_value(t, jerr, nil) {
        return
    }
    if root == "" || !os.is_dir(fmt_dir) {
        log.infof("no Odin root at %q; resolution against it is skipped", root)
        return
    }
    src := `package app

import "core:fmt"
import "base:runtime"
import "core:not_a_package_zz"
`
    collections := Collections{odin_root = root}
    c, ok := read_imports(t, src, ".", &collections)
    if !ok {
        return
    }
    defer destroy_case(&c)
    if !testing.expect_value(t, len(c.imports), 3) {
        return
    }
    testing.expect_value(t, c.imports[0].problem, Import_Problem.None)
    testing.expect(t, c.imports[0].exists)
    testing.expect(t, c.imports[1].exists)
    testing.expect_value(t, c.imports[2].problem, Import_Problem.Missing_Dir)

    files, ferr := package_dir_files(c.imports[0].dir)
    if !testing.expect_value(t, ferr, nil) {
        return
    }
    defer package_dir_files_destroy(files)
    has_fmt := false
    for f in files {
        testing.expect(t, strings.has_suffix(f, ".odin"))
        has_fmt ||= filepath.base(f) == "fmt.odin"
    }
    testing.expect(t, has_fmt)
}

@(test)
test_package_dir_files :: proc(t: ^testing.T) {
    sub, jerr := filepath.join({FIXTURE_DIR, "nested"}, context.temp_allocator)
    if !testing.expect_value(t, jerr, nil) {
        return
    }
    _ = os.remove_all(FIXTURE_DIR)
    if !testing.expect_value(t, os.make_directory_all(sub), nil) {
        return
    }
    defer {
        if err := os.remove_all(FIXTURE_DIR); err != nil {
            log.errorf("cannot remove %s: %v", FIXTURE_DIR, err)
        }
    }
    names := []string{"zeta.odin", "alpha.odin", "mid_test.odin", "notes.txt", "nested/inner.odin"}
    for name in names {
        path, perr := filepath.join({FIXTURE_DIR, name}, context.temp_allocator)
        if !testing.expect_value(t, perr, nil) {
            return
        }
        if !testing.expect_value(t, os.write_entire_file(path, "package fixture\n"), nil) {
            return
        }
    }

    files, err := package_dir_files(FIXTURE_DIR)
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer package_dir_files_destroy(files)
    want := []string{"alpha.odin", "mid_test.odin", "zeta.odin"}
    if !testing.expect_value(t, len(files), len(want)) {
        return
    }
    for w, i in want {
        testing.expect_value(t, filepath.base(files[i]), w)
    }

    _, missing := package_dir_files("bin/test/sema_imports_no_such_dir")
    testing.expect(t, missing != nil)
}
