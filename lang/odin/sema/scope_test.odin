package odinsema

import "core:os"
import "core:strings"
import "core:testing"

import odinsyntax "../syntax"

// `«` marks the caret and `»` the expected declaration name; both are removed before the parse.
@(private = "file")
Marked :: struct {
    src:   string,
    caret: int,
    decl:  int,
}

@(private = "file")
strip_marks :: proc(marked: string) -> Marked {
    out := Marked{caret = -1, decl = -1}
    sb := strings.builder_make(context.temp_allocator)
    rest := marked
    for len(rest) > 0 {
        switch {
        case strings.has_prefix(rest, "«"):
            out.caret = strings.builder_len(sb)
            rest = rest[len("«"):]
        case strings.has_prefix(rest, "»"):
            out.decl = strings.builder_len(sb)
            rest = rest[len("»"):]
        case:
            strings.write_byte(&sb, rest[0])
            rest = rest[1:]
        }
    }
    out.src = strings.to_string(sb)
    return out
}

@(private = "file")
resolve_marked :: proc(t: ^testing.T, marked: string, loc := #caller_location) -> (Marked, Name_Ref) {
    m := strip_marks(marked)
    testing.expect(t, m.caret >= 0, "no caret mark", loc = loc)
    parsed, err := odinsyntax.parse(m.src)
    testing.expect_value(t, err, nil, loc = loc)
    defer odinsyntax.parse_destroy(&parsed)
    ref, rerr := resolve_at(parsed, m.caret)
    testing.expect_value(t, rerr, nil, loc = loc)
    // The strings borrow the parse, which dies here.
    ref.name = strings.clone(ref.name, context.temp_allocator)
    ref.operand = strings.clone(ref.operand, context.temp_allocator)
    return m, ref
}

@(private = "file")
expect_local :: proc(t: ^testing.T, marked: string, kind: Decl_Kind, loc := #caller_location) {
    m, ref := resolve_marked(t, marked, loc)
    testing.expect_value(t, ref.kind, Name_Ref_Kind.Local, loc = loc)
    testing.expect_value(t, ref.decl, m.decl, loc = loc)
    testing.expect_value(t, ref.decl_kind, kind, loc = loc)
}

@(private = "file")
expect_ref :: proc(t: ^testing.T, marked: string, kind: Name_Ref_Kind, loc := #caller_location) -> Name_Ref {
    _, ref := resolve_marked(t, marked, loc)
    testing.expect_value(t, ref.kind, kind, loc = loc)
    return ref
}

@(test)
test_scope_params_and_results :: proc(t: ^testing.T) {
    expect_local(t, "package p\nf :: proc(»a: int) -> int { return «a + 1 }", .Param)
    expect_local(t, "package p\nf :: proc(x, »y: int) { _ = «y }", .Param)
    expect_local(t, "package p\nf :: proc() -> (»err: int) { «err = 1; return }", .Result)
    expect_local(t, "package p\nf :: proc(a: int, »b := 2) { _ = «b }", .Param)
}

@(test)
test_scope_var_after_statement :: proc(t: ^testing.T) {
    expect_local(t, "package p\nf :: proc() {\n    »x := 1\n    _ = «x\n}", .Var)
    expect_local(t, "package p\nf :: proc() {\n    »x: int\n    «x = 2\n}", .Var)
    // `x := x` reads the outer x.
    expect_local(t, "package p\nf :: proc(»x: int) {\n    {\n        x := «x\n    }\n}", .Param)
    expect_local(t, "package p\nf :: proc(x: int) {\n    {\n        »x := x\n        _ = «x\n    }\n}", .Var)
    // A use before the declaration in its block is free.
    expect_ref(t, "package p\nf :: proc() {\n    «y = 1\n    y := 2\n}", .Free)
}

@(test)
test_scope_multi_name :: proc(t: ^testing.T) {
    expect_local(t, "package p\nf :: proc() {\n    a, »b := g()\n    _ = «b\n}", .Var)
    expect_local(t, "package p\nf :: proc() {\n    »a, b := g()\n    _ = «a\n}", .Var)
}

@(test)
test_scope_block_constants_any_order :: proc(t: ^testing.T) {
    expect_local(t, "package p\nf :: proc() {\n    _ = «N\n    »N :: 4\n}", .Const)
    expect_local(t, "package p\nf :: proc() {\n    _ = «inner(1)\n    »inner :: proc(x: int) -> int { return x }\n}", .Proc)
    expect_local(t, "package p\nf :: proc() {\n    v: «T\n    »T :: struct { a: int }\n}", .Type)
    expect_local(t, "package p\nf :: proc() {\n    »fact :: proc(n: int) -> int { return «fact(n - 1) }\n}", .Proc)
    expect_local(t, "package p\nf :: proc() {\n    »C : int : 3\n    _ = «C\n}", .Const)
    // A `when` body opens no scope.
    expect_local(t, "package p\nf :: proc() {\n    when X {\n        »y := 1\n    }\n    _ = «y\n}", .Var)
}

@(test)
test_scope_blocks :: proc(t: ^testing.T) {
    expect_ref(t, "package p\nf :: proc() {\n    {\n        x := 1\n    }\n    _ = «x\n}", .Free)
    expect_local(t, "package p\nf :: proc() {\n    »x := 1\n    {\n        _ = «x\n    }\n}", .Var)
    // Shadowing picks the innermost.
    expect_local(t, "package p\nf :: proc() {\n    x := 1\n    {\n        »x := 2\n        _ = «x\n    }\n}", .Var)
    expect_local(t, "package p\nf :: proc() {\n    »x := 1\n    {\n        x := 2\n    }\n    _ = «x\n}", .Var)
}

@(test)
test_scope_if_for_switch_init :: proc(t: ^testing.T) {
    expect_local(t, "package p\nf :: proc() {\n    if x, »ok := g(); «ok {\n    }\n}", .Var)
    expect_local(t, "package p\nf :: proc() {\n    if »x, ok := g(); ok {\n    } else {\n        _ = «x\n    }\n}", .Var)
    expect_ref(t, "package p\nf :: proc() {\n    if x := g(); x > 0 {\n    }\n    _ = «x\n}", .Free)
    expect_local(t, "package p\nf :: proc() {\n    for »i := 0; i < 10; «i += 1 {\n    }\n}", .Var)
    expect_ref(t, "package p\nf :: proc() {\n    for i := 0; i < 10; i += 1 {\n    }\n    _ = «i\n}", .Free)
    expect_local(t, "package p\nf :: proc() {\n    switch »x := g(); «x {\n    case 1:\n    }\n}", .Var)
    expect_local(t, "package p\nf :: proc() {\n    switch x := g(); x {\n    case 1:\n        »y := 2\n        _ = «y\n    }\n}", .Var)
    expect_ref(t, "package p\nf :: proc() {\n    switch {\n    case:\n        y := 2\n    case:\n        _ = «y\n    }\n}", .Free)
}

@(test)
test_scope_range :: proc(t: ^testing.T) {
    expect_local(t, "package p\nf :: proc(m: map[string]int) {\n    for »k, v in m {\n        _ = «k\n    }\n}", .Loop_Var)
    expect_local(t, "package p\nf :: proc(m: map[string]int) {\n    for k, »v in m {\n        _ = «v\n    }\n}", .Loop_Var)
    expect_local(t, "package p\nf :: proc() {\n    for »i in 0..<10 {\n        _ = «i\n    }\n}", .Loop_Var)
    expect_local(t, "package p\nf :: proc(xs: []int) {\n    for &»x in xs do «x += 1\n}", .Loop_Var)
    // The range expression is read before the variables exist.
    expect_local(t, "package p\nf :: proc(»x: []int) {\n    for x in «x {\n    }\n}", .Param)
    expect_ref(t, "package p\nf :: proc(xs: []int) {\n    for x in xs {\n    }\n    _ = «x\n}", .Free)
}

@(test)
test_scope_type_switch :: proc(t: ^testing.T) {
    src := "package p\nf :: proc(u: U) {\n    switch »v in u {\n    case int:\n        _ = «v\n    case f64:\n        _ = v\n    }\n}"
    expect_local(t, src, .Switch_Var)
    expect_local(t, "package p\nf :: proc(u: U) {\n    switch »v in u {\n    case int:\n    case f64:\n        _ = «v\n    }\n}", .Switch_Var)
    // The case types are read outside the clause.
    expect_ref(t, "package p\nf :: proc(u: U) {\n    switch v in u {\n    case «v:\n    }\n}", .Free)
    expect_local(t, "package p\nf :: proc(»u: U) {\n    switch v in «u {\n    }\n}", .Param)
    expect_ref(t, "package p\nf :: proc(u: U) {\n    switch v in u {\n    }\n    _ = «v\n}", .Free)

}

@(test)
test_scope_labels :: proc(t: ^testing.T) {
    expect_local(t, "package p\nf :: proc(xs: []int) {\n    »outer: for x in xs {\n        for y in xs {\n            break «outer\n        }\n    }\n}", .Label)
    expect_local(t, "package p\nf :: proc(xs: []int) {\n    »outer: for x in xs {\n        for y in xs {\n            if y == 0 do continue «outer\n        }\n    }\n}", .Label)
    expect_local(t, "package p\nf :: proc() {\n    »blk: {\n        break «blk\n    }\n}", .Label)
    expect_local(t, "package p\nf :: proc() {\n    »loop: for {\n        g() or_break «loop\n    }\n}", .Label)
    // A label is not a value, and a value is not a label.
    expect_ref(t, "package p\nf :: proc() {\n    outer: for {\n        _ = «outer\n    }\n}", .Free)
    expect_ref(t, "package p\nf :: proc() {\n    outer := 1\n    for {\n        break «outer\n    }\n}", .Free)
}

@(test)
test_scope_nested_proc_literals :: proc(t: ^testing.T) {
    // Procedures do not capture variables or parameters.
    expect_ref(t, "package p\nf :: proc(a: int) {\n    g :: proc() { _ = «a }\n}", .Free)
    expect_ref(t, "package p\nf :: proc() {\n    x := 1\n    g :: proc() { _ = «x }\n}", .Free)
    expect_ref(t, "package p\nf :: proc() {\n    l: for {\n        g :: proc() { for { break «l } }\n    }\n}", .Free)
    // They see constants, types and procedures.
    expect_local(t, "package p\nf :: proc() {\n    »N :: 3\n    g :: proc() -> int { return «N }\n}", .Const)
    expect_local(t, "package p\nf :: proc() {\n    »T :: struct {}\n    g := proc(t: «T) {}\n}", .Type)
    expect_local(t, "package p\nf :: proc() {\n    »h :: proc() {}\n    g :: proc() { «h() }\n}", .Proc)
    expect_local(t, "package p\nf :: proc() {\n    g :: proc(»a: int) { _ = «a }\n}", .Param)
    // A nested parameter shadows an outer variable.
    expect_local(t, "package p\nf :: proc(x: int) {\n    g :: proc(»x: int) { _ = «x }\n}", .Param)
}

@(test)
test_scope_polymorphic :: proc(t: ^testing.T) {
    expect_local(t, "package p\nf :: proc(x: $»T) -> «T { return x }", .Poly)
    expect_local(t, "package p\nf :: proc(x: «T, y: $»T) {}", .Poly)
    expect_local(t, "package p\nf :: proc($»N: int) -> [«N]int { return {} }", .Poly)
    expect_local(t, "package p\nf :: proc($T: typeid/[]$»E) -> E where size_of(«E) > 1 { return {} }", .Poly)
    expect_local(t, "package p\nf :: proc(x: $»T) {\n    y: «T\n}", .Poly)
    expect_local(t, "package p\nList :: struct($»T: typeid) { items: []«T }", .Poly)
    expect_local(t, "package p\nf :: proc($»T: typeid) {\n    g :: proc() -> «T { return {} }\n}", .Poly)
}

@(test)
test_scope_selectors_and_names :: proc(t: ^testing.T) {
    ref := expect_ref(t, "package p\nf :: proc(a: A) {\n    _ = a.«b\n}", .Field_Or_Member)
    testing.expect_value(t, ref.name, "b")
    testing.expect_value(t, ref.operand_start, 36)
    testing.expect_value(t, ref.operand_end, 37)
    ref = expect_ref(t, "package p\nf :: proc() {\n    fmt.«println(1)\n}", .Package_Qualified)
    testing.expect_value(t, ref.operand, "fmt")
    testing.expect_value(t, ref.name, "println")
    expect_ref(t, "package p\nf :: proc() {\n    «fmt.println(1)\n}", .Free)
    expect_ref(t, "package p\nf :: proc() {\n    fmt := 1\n    fmt.«println(1)\n}", .Field_Or_Member)
    expect_ref(t, "package p\nf :: proc() {\n    a.b.«c = 1\n}", .Field_Or_Member)
    expect_ref(t, "package p\nf :: proc() {\n    x->«m()\n}", .Field_Or_Member)
    expect_ref(t, "package p\nf :: proc() {\n    c := Color.«Red\n}", .Package_Qualified)
    expect_ref(t, "package p\nf :: proc() {\n    c: Color = .«Red\n}", .Implicit_Selector)
    ref = expect_ref(t, "package p\nf :: proc() {\n    p := Point{«x = 1, y = 2}\n}", .Field_Name)
    testing.expect_value(t, ref.operand_start, 33)
    testing.expect_value(t, ref.operand_end, 38)
    expect_local(t, "package p\nf :: proc(»v: int) {\n    p := Point{x = «v}\n}", .Param)
    ref = expect_ref(t, "package p\nf :: proc() {\n    g(«x = 1)\n}", .Field_Name)
    testing.expect_value(t, ref.operand_start, 28)
    expect_ref(t, "package p\nf :: proc() {\n    m := [Color]int{.«Red = 1}\n}", .Implicit_Selector)
}

@(test)
test_scope_declaration_names :: proc(t: ^testing.T) {
    ref := expect_ref(t, "package p\n«»add :: proc(a, b: int) -> int { return a + b }", .Top_Level)
    testing.expect_value(t, ref.decl, 10)
    testing.expect_value(t, ref.decl_kind, Decl_Kind.Proc)
    testing.expect(t, ref.is_decl)
    ref = expect_ref(t, "package p\n«Point :: struct { x: int }", .Top_Level)
    testing.expect_value(t, ref.decl_kind, Decl_Kind.Type)
    ref = expect_ref(t, "package p\n«counter: int", .Top_Level)
    testing.expect_value(t, ref.decl_kind, Decl_Kind.Var)
    ref = expect_ref(t, "package p\nimport «str \"core:strings\"", .Top_Level)
    testing.expect_value(t, ref.decl_kind, Decl_Kind.Import)
    ref = expect_ref(t, "package p\nwhen X {\n    «MAX :: 3\n}", .Top_Level)
    testing.expect_value(t, ref.decl_kind, Decl_Kind.Const)
    expect_ref(t, "package p\nPoint :: struct { «x: int }", .Member_Decl)
    expect_ref(t, "package p\nColor :: enum { Red, «Green = 2 }", .Member_Decl)
    expect_ref(t, "package p\nBits :: bit_field u8 { «low: u8 | 4 }", .Member_Decl)
    expect_ref(t, "package p\nf :: proc() { add(1, 2) }\nadd :: proc(a, b: int) -> int { return «a }", .Local)

    // A local names itself.
    expect_local(t, "package p\nf :: proc() {\n    «»x := 1\n}", .Var)
    expect_local(t, "package p\nf :: proc(«»a: int) {}", .Param)
    expect_local(t, "package p\nf :: proc() {\n    for «»i in 0..<3 {}\n}", .Loop_Var)
    // The caret touching the end of a name.
    expect_local(t, "package p\nf :: proc(»abc: int) { _ = abc« }", .Param)
}

@(test)
test_scope_using_and_blank :: proc(t: ^testing.T) {
    _, ref := resolve_marked(t, "package p\nf :: proc(using »s: S) { _ = «s }")
    testing.expect_value(t, ref.kind, Name_Ref_Kind.Local)
    testing.expect(t, ref.is_using)
    _, ref = resolve_marked(t, "package p\nf :: proc() {\n    using »p: Point\n    _ = «p\n}")
    testing.expect(t, ref.is_using)
    // Names that come into reach through `using` are not resolved here.
    expect_ref(t, "package p\nf :: proc(using s: S) { _ = «field }", .Free)
    expect_ref(t, "package p\nf :: proc() { «_ = 1 }", .None)
    expect_ref(t, "package p\n@(«private) f :: proc() {}", .None)
    expect_ref(t, "package p\nf :: proc() {  «  }", .None)

    src := "package p\nf :: proc(s: S) {\n    using s\n}"
    parsed, err := odinsyntax.parse(src)
    testing.expect_value(t, err, nil)
    defer odinsyntax.parse_destroy(&parsed)
    m, merr := scope_map(parsed)
    testing.expect_value(t, merr, nil)
    defer scope_map_destroy(m)
    testing.expect_value(t, len(m.usings), 1)
    if len(m.usings) == 1 {
        testing.expect_value(t, src[m.usings[0].start:m.usings[0].end], "s")
    }
}

@(test)
test_scope_broken_code :: proc(t: ^testing.T) {
    ref := expect_ref(t, "package p\nf :: proc(a: A) {\n    x := a.«\n}", .None)
    _ = ref
    expect_local(t, "package p\nf :: proc(»a: A) {\n    x := «a.\n}", .Param)
    expect_local(t, "package p\nf :: proc(»a: A) {\n    if «a {\n", .Param)
    expect_local(t, "package p\nf :: proc() {\n    »x := 1\n    for {\n        _ = «x", .Var)
    expect_ref(t, "package p\nf :: proc(a: A) {\n    a.«", .None)
    expect_ref(t, "package p\nf :: proc(a: A) { switch v in { case «", .None)
    expect_ref(t, "package p\nf :: proc(«", .None)
}

// Every identifier of a large file resolves, and every local points at a name with its text.
@(test)
test_scope_smoke_repo_files :: proc(t: ^testing.T) {
    files := []string{"editview/editor.odin", "thor/view.odin", "lang/odin/syntax/parse_stmt.odin", "lang/odin/sema/scope.odin"}
    for path in files {
        data, rerr := os.read_entire_file(path, context.allocator)
        if !testing.expectf(t, rerr == nil, "read %s: %v", path, rerr) {
            continue
        }
        defer delete(data)
        src := string(data)
        parsed, err := odinsyntax.parse(src)
        if !testing.expect_value(t, err, nil) {
            continue
        }
        defer odinsyntax.parse_destroy(&parsed)
        m, merr := scope_map(parsed)
        if !testing.expect_value(t, merr, nil) {
            continue
        }
        defer scope_map_destroy(m)
        locals := 0
        for r in m.refs {
            testing.expect(t, r.start < r.end && r.end <= len(src))
            if r.kind != .Local {
                continue
            }
            locals += 1
            ok := r.decl >= 0 && r.decl + len(r.name) <= len(src) && src[r.decl:][:len(r.name)] == r.name
            testing.expectf(t, ok, "%s: %s at %d resolves to %d", path, r.name, r.start, r.decl)
        }
        testing.expectf(t, locals > 100, "%s: only %d local references", path, locals)
        for r, i in m.refs {
            if i % 97 != 0 {
                continue
            }
            got, gerr := resolve_at(parsed, r.start)
            testing.expect_value(t, gerr, nil)
            testing.expectf(t, got.kind == r.kind && got.decl == r.decl, "%s: %s at %d: %v, want %v", path, r.name, r.start, got.kind, r.kind)
        }
    }
}
