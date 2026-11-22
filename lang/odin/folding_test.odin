package odin

import "core:strings"
import "core:testing"

import lang ".."

@(private = "file")
FOLD_SRC :: "package demo\n\nimport \"core:fmt\"\nimport \"core:os\"\n\n// One.\n// Two.\nmain :: proc() {\n\tx := [2]int{\n\t\t1,\n\t\t2,\n\t}\n\tfmt.println(x) // { not a brace\n}\n\n/*\n block\n*/\nsingle :: proc() {}\n"

// Braces, brackets, comment runs, block comments and import runs that span lines fold; one-line ones do not.
@(test)
test_folding_ranges :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    req := lang.Request{kind = .Folding_Range, path = "buffer.odin", ext = ".odin", source = FOLD_SRC}
    res := lang.Result{kind = .Folding_Range}
    resolve(e, &req, &res)
    defer lang.result_release(&res)
    testing.expect(t, res.ok)

    want := []lang.Text_Range{
        {strings.index(FOLD_SRC, "import \"core:fmt\""), strings.index(FOLD_SRC, "import \"core:os\"")},
        {strings.index(FOLD_SRC, "// One."), strings.index(FOLD_SRC, "// Two.")},
        {strings.index(FOLD_SRC, "{\n\tx"), strings.last_index(FOLD_SRC, "}\n\n/*")},
        {strings.index(FOLD_SRC, "{\n\t\t1"), strings.index(FOLD_SRC, "}\n\tfmt")},
        {strings.index(FOLD_SRC, "/*"), strings.index(FOLD_SRC, "*/") + 1},
    }
    testing.expect_value(t, len(res.ranges), len(want))
    for w in want {
        found := false
        for r in res.ranges {
            found ||= r == w
        }
        testing.expectf(t, found, "missing fold %v", w)
    }
    for r, i in res.ranges {
        if i > 0 {
            testing.expect(t, res.ranges[i - 1].start <= r.start, "folds are not ascending")
        }
    }
}

// Declaration answers like Definition in Odin.
@(test)
test_declaration_is_definition :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nhelper :: proc() {}\n\nmain :: proc() {\n\thelper()\n}\n"
    req := lang.Request{kind = .Declaration, path = "buffer.odin", ext = ".odin", source = src, offset = strings.index(src, "helper()")}
    req.end = req.offset
    res := lang.Result{kind = .Declaration}
    resolve(e, &req, &res)
    defer lang.result_release(&res)
    testing.expect(t, res.ok)
    testing.expect_value(t, res.location.start, strings.index(src, "helper ::"))
}
