package odinsema

import "core:testing"

import odinsyntax "../syntax"

// The text each offset of `offsets` starts, `width` bytes long.
@(private = "file")
snippets :: proc(src: string, offsets: [dynamic]int, width: int) -> []string {
    out := make([]string, len(offsets), context.temp_allocator)
    for at, i in offsets {
        out[i] = src[at:min(at + width, len(src))]
    }
    return out
}

@(private = "file")
expect_snippets :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
    if !testing.expectf(t, len(got) == len(want), "got %q, want %q", got, want, loc = loc) {
        return
    }
    for g, i in got {
        testing.expectf(t, g == want[i], "item %d: got %q, want %q", i, g, want[i], loc = loc)
    }
}

@(test)
test_vet_semicolons :: proc(t: ^testing.T) {
    src := "package p\n\nA :: struct {\n\tx: int,\n};\n\nf :: proc() {\n\tx := 1; y := 2\n\t_ = x; _ = y;\n\tfor i := 0; i < 3; i += 1 { g(); }\n\tif a, b := h();\n\t    a {\n\t}\n\t;\n}\n"
    parsed, err := odinsyntax.parse(src, context.temp_allocator)
    testing.expect_value(t, err, nil)
    got, gerr := vet_semicolons(parsed, context.temp_allocator)
    testing.expect_value(t, gerr, nil)
    expect_snippets(t, snippets(src, got, 3), {";\n\n", ";\n\t", "; }", ";\n}"})
}

@(test)
test_vet_tabs :: proc(t: ^testing.T) {
    src := "package p\n\n g :: proc() {\n }\n\nE :: enum {\n  A,\n\tB,\n}\n\nS :: struct {\n\ta: int,\n  b: int,\n}\n\nf :: proc(\n  a: int,\n) -> (\n  r: int,\n) {\n\tx := 1\n  y := 2\n\t _ = x\n\tswitch x {\n  case 1:\n\t\ty = 3\n\t}\n\t_ = y\n    return 0\n}\n"
    parsed, err := odinsyntax.parse(src, context.temp_allocator)
    testing.expect_value(t, err, nil)
    got, gerr := vet_tabs(parsed, context.temp_allocator)
    testing.expect_value(t, gerr, nil)
    expect_snippets(t, snippets(src, got, 2), {"A,", "b:", "r:", "y ", "_ ", "re"})
}

@(test)
test_vet_style :: proc(t: ^testing.T) {
    src := "package p\n\nE :: enum {\n\tA,\n\tB\n}\n\nf :: proc(\n\ta: int,\n\tb: int\n) {\n\tx := []int{\n\t\t1,\n\t\t2\n\t}\n\ty := []int{1,\n\t\t2}\n\tg(\n\t\t1,\n\t\t2,\n\t)\n\t_ = x\n\t_ = y\n}\n"
    parsed, err := odinsyntax.parse(src, context.temp_allocator)
    testing.expect_value(t, err, nil)
    got, gerr := vet_style(parsed, context.temp_allocator)
    testing.expect_value(t, gerr, nil)
    // Each offset is just after the last element.
    ends := make([]string, len(got), context.temp_allocator)
    for at, i in got {
        ends[i] = src[at - 1:at]
    }
    expect_snippets(t, ends, {"B", "t", "2"})
}
