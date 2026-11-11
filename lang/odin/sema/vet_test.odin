package odinsema

import "core:log"
import "core:strings"
import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
SHADOW_SRC :: `package p

g := 1
K :: 2
h: int

U :: union { int, f32 }
P :: struct { x: int }

nested_block :: proc(p: int) {
    x := 1
    {
        x := 2 // shadow x
        _ = x
    }
    {
        x := x
        y := &x
        _ = y
    }
    {
        p := 3 // shadow p
        _ = p
    }
    {
        g := 4 // shadow g
        _ = g
    }
    for i in 0 ..< 3 {
        for i in 0 ..< 3 { // shadow i
            _ = i
        }
    }
    _ = x
}
top_scope :: proc(h: int) {
    g := 4 // shadow g
    K := 5
    _ = g
    _ = K
    later_too := 1
    _ = later_too
}
not_shadow :: proc() {
    a := 1
    inner :: proc() {
        a := 2
        _ = a
    }
    {
        y := 1
        _ = y
    }
    y := 2
    _ = y
    c :: 1
    {
        c := 2
        _ = c
    }
    n := 1
    {
        n, m := n, 2
        _ = m
    }
    _ = a
}
switches :: proc(u: U) {
    v := 1
    switch v in u { // shadow v
    case int:
        _ = v
    }
    s := 1
    if s := 2; s > 0 { // shadow s
        _ = s
    }
    q := 1
    {
        q := q + 1 // shadow q
        _ = q
    }
    _ = s
}

later_too := 0
`

// The marked `// shadow name` lines of SHADOW_SRC are the ones reported.
@(test)
test_vet_shadowing :: proc(t: ^testing.T) {
    parsed, err := odinsyntax.parse(SHADOW_SRC, context.temp_allocator)
    testing.expect_value(t, err, nil)
    m, merr := scope_map(parsed, context.temp_allocator)
    testing.expect_value(t, merr, nil)
    defer scope_map_destroy(m, context.temp_allocator)
    tree, terr := item_tree(parsed, context.temp_allocator)
    testing.expect_value(t, terr, nil)
    defer item_tree_destroy(tree, context.temp_allocator)

    got, gerr := vet_shadowing(m, parsed, tree, nil, context.temp_allocator)
    testing.expect_value(t, gerr, nil)

    want   := make([dynamic]int, context.temp_allocator)
    rest   := SHADOW_SRC
    offset := 0
    for line in strings.split_lines_iterator(&rest) {
        if at := strings.index(line, "// shadow "); at >= 0 {
            name := strings.trim_space(line[at + len("// shadow "):])
            col  := strings.index(line, strings.concatenate({name, " "}, context.temp_allocator))
            append(&want, offset + col)
        }
        offset += len(line) + 1
    }
    if !testing.expect_value(t, len(got), len(want)) {
        for s in got {
            log.infof("got %s at %d", s.name, s.offset)
        }
        return
    }
    for s, i in got {
        testing.expect_value(t, s.offset, want[i])
    }
    // The shadowed declaration of the first is the outer `x`.
    testing.expect_value(t, got[0].shadowed, strings.index(SHADOW_SRC, "x := 1"))

    // A declaration in a skipped range is not reported.
    first      := got[0].offset
    skipped, _ := vet_shadowing(m, parsed, tree, {{first, first + 1}}, context.temp_allocator)
    testing.expect_value(t, len(skipped), len(got) - 1)
}

@(private = "file")
IMPORT_SRC :: `package p

import "core:fmt"
import str "core:strings"
import _ "core:slice"
import "core:mem"
import "core:os"
import "core:math"
@(require) import "core:time"
import "base:intrinsics"
import "base:builtin"

f :: proc(a: mem.Allocator) {
    fmt.println("x")
    when ODIN_OS == .JS {
        _ = os.args
    }
    m := 1
    math := m
    _ = math.x
}
`

@(test)
test_vet_unused_imports :: proc(t: ^testing.T) {
    parsed, err := odinsyntax.parse(IMPORT_SRC, context.temp_allocator)
    testing.expect_value(t, err, nil)
    m, merr := scope_map(parsed, context.temp_allocator)
    testing.expect_value(t, merr, nil)
    defer scope_map_destroy(m, context.temp_allocator)
    tree, terr := item_tree(parsed, context.temp_allocator)
    testing.expect_value(t, terr, nil)
    defer item_tree_destroy(tree, context.temp_allocator)
    collections   := Collections{}
    imports, ierr := file_imports(tree, ".", &collections, context.temp_allocator)
    testing.expect_value(t, ierr, nil)
    defer file_imports_destroy(imports, context.temp_allocator)

    start        := strings.index(IMPORT_SRC, "when")
    end          := strings.index(IMPORT_SRC, "    m := 1")
    unused, uerr := vet_unused_imports(tree, imports, m, {{start, end}}, context.temp_allocator)
    testing.expect_value(t, uerr, nil)
    names := make([dynamic]string, context.temp_allocator)
    for i in unused {
        append(&names, imports[i].alias)
    }
    testing.expect_value(t, strings.join(names[:], ",", context.temp_allocator), "str,os,math")

    // With no dead range the `when` use counts.
    unused, _ = vet_unused_imports(tree, imports, m, nil, context.temp_allocator)
    testing.expect_value(t, len(unused), 2)
}

@(test)
test_file_vet_flags :: proc(t: ^testing.T) {
    Case :: struct {
        header: string,
        base:   Vet_Flags,
        want:   Vet_Flags,
    }
    cases := []Case{
        {"", VET_DEFAULT, VET_DEFAULT},
        {"", {}, {}},
        {"#+vet\n", {}, VET_DEFAULT},
        {"#+vet shadowing\n", {}, {.Shadowing}},
        {"#+vet unused shadowing\n", {}, {.Shadowing, .Unused_Variables, .Unused_Imports}},
        {"#+vet !shadowing\n", VET_DEFAULT, VET_DEFAULT - {.Shadowing}},
        {"#+vet !unused unknown-name\n", VET_DEFAULT, VET_DEFAULT - {.Unused_Variables, .Unused_Imports}},
        {"#+vet style semicolon\n", VET_DEFAULT, VET_DEFAULT + {.Style, .Semicolon}},
        {"#+vet !cast\n", VET_DEFAULT, VET_DEFAULT - {.Cast}},
    }
    for c in cases {
        src       := strings.concatenate({c.header, "package p\n"}, context.temp_allocator)
        parsed, _ := odinsyntax.parse(src, context.temp_allocator)
        tree, _   := item_tree(parsed, context.temp_allocator)
        testing.expectf(t, file_vet_flags(tree, c.base) == c.want, "%q: got %v, want %v", c.header, file_vet_flags(tree, c.base), c.want)
        item_tree_destroy(tree, context.temp_allocator)
    }
}

@(private = "file")
POLY_SRC_A :: `package p

inner :: proc(v: $T) { _ = INNER_USE }
outer :: proc(v: $T) { inner(v) }
in2 :: proc(v: $T) { _ = IN2_USE }
out2 :: proc(v: $T) { in2(v) }
sig :: proc(a: SIG_USE, v: $T, b := DEFAULT_USE) -> RESULT_USE where WHERE_USE { return {} }
np :: proc(v: $T) {
    f :: proc() { _ = NESTED_USE }
    f()
}
Box :: struct($T: typeid) { a: BOX_USE }
Un :: struct($T: typeid) where UN_WHERE { a: UN_USE }
anon := proc(v: $T) { _ = ANON_USE }
`

@(private = "file")
POLY_SRC_B :: `package p

main :: proc() {
    outer(1)
    B :: Box(int)
}
`

// The bodies no use reaches, over two files: a chain nothing calls, a nested procedure, a `where`
// clause and an uninstantiated record are out; a call from another file, a type use, the signature
// and an anonymous literal are in.
@(test)
test_poly_uninstantiated :: proc(t: ^testing.T) {
    srcs := [2]string{POLY_SRC_A, POLY_SRC_B}
    files: [2]Poly_File
    for src, i in srcs {
        parsed, err := odinsyntax.parse(src, context.temp_allocator)
        testing.expect_value(t, err, nil)
        f, ferr := poly_file(parsed, context.temp_allocator)
        testing.expect_value(t, ferr, nil)
        files[i] = f
    }
    spans, err := poly_uninstantiated(files[:], context.temp_allocator)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(spans[1]), 0)

    dead :: proc(spans: []Offset_Span, name: string) -> bool {
        at := strings.index(POLY_SRC_A, name)
        for s in spans {
            if s.start <= at && at < s.end {
                return true
            }
        }
        return false
    }
    out := []string{"IN2_USE", "WHERE_USE", "NESTED_USE", "UN_WHERE", "UN_USE"}
    in_ := []string{"INNER_USE", "SIG_USE", "DEFAULT_USE", "RESULT_USE", "BOX_USE", "ANON_USE", "inner(v)"}
    for name in out {
        testing.expectf(t, dead(spans[0], name), "%s should be in an uninstantiated body", name)
    }
    for name in in_ {
        testing.expectf(t, !dead(spans[0], name), "%s should be checked", name)
    }
}
