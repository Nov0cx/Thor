package odinsema

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import odinsyntax "../syntax"

// An expression of the source and the type it should print. `after` is text the expression follows.
@(private = "file")
Expr_Case :: struct {
    expr:  string,
    want:  string,
    after: string,
}

// The offset of the first `text` after the first `after`; -1 when there is none.
@(private)
marker_offset :: proc(src, text, after: string) -> int {
    base := 0
    if after != "" {
        base = strings.index(src, after)
        if base < 0 {
            return -1
        }
    }
    i := strings.index(src[base:], text)
    return i < 0 ? -1 : base + i
}

// The outermost expression at `offset` whose text is `text`.
@(private)
expr_node_at :: proc(c: ^Checker, file: File_Id, offset: int, text: string) -> (odinsyntax.Syntax_Node, bool) {
    for n in node_path(c, file, offset) {
        if int(n.offset) == offset && n.green.kind in odinsyntax.KINDS_EXPR && strings.trim_space(odinsyntax.node_text(n)) == text {
            return n, true
        }
    }
    return {}, false
}

@(private = "file")
expect_expr :: proc(t: ^testing.T, c: ^Checker, file: File_Id, src: string, k: Expr_Case, loc := #caller_location) {
    at := marker_offset(src, k.expr, k.after)
    if !testing.expectf(t, at >= 0, "%q: not in the source", k.expr, loc = loc) {
        return
    }
    n, ok := expr_node_at(c, file, at, k.expr)
    if !testing.expectf(t, ok, "%q: no expression node", k.expr, loc = loc) {
        return
    }
    op := expr_type(c, file, n)
    got := type_string(&c.table, op.type, context.temp_allocator)
    if op.mode == .Invalid {
        got = "<invalid>"
    }
    testing.expectf(t, got == k.want, "%q: got %q, want %q", k.expr, got, k.want, loc = loc)
}

@(private = "file")
expect_exprs :: proc(t: ^testing.T, src: string, cases: []Expr_Case, loc := #caller_location) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = src}) {
        return
    }
    defer check_end(&env)
    for k in cases {
        expect_expr(t, &env.c, ANON_FILE, src, k, loc)
    }
    testing.expect_value(t, env.c.err, nil, loc = loc)
}

@(private = "file")
EXPR_SRC :: `package p

Point :: struct { x, y: f32 }
Base :: struct { id: int, name: string }
Entity :: struct {
    using base: Base,
    pos:  Point,
    next: ^Entity,
}
Color :: enum { Red, Green, Blue }
Colors :: bit_set[Color]
Vec3 :: [3]f32
Shape :: union { Point, Entity }
List :: struct($T: typeid) { items: []T, count: int }
Grid :: [Color]int
Packed :: bit_field u16 { lo: u8 | 4, hi: u8 | 4 }

pair :: proc() -> (int, string) { return 0, "" }
maybe :: proc() -> (int, bool) #optional_ok { return 0, true }
find :: proc(s: string) -> (int, bool) { return 0, true }
add_int :: proc(a, b: int) -> int { return a + b }
add_f32 :: proc(a, b: f32) -> f32 { return a + b }
add :: proc{add_int, add_f32}
ident :: proc(x: $T) -> T { return x }
first :: proc(xs: []$T) -> T { return xs[0] }
nothing :: proc() {}

work :: proc(e: Entity, pe: ^Entity, v: Vec3, s: []int, a: [4]u8, m: map[string]f64, str: string, sh: Shape, g: Grid, bf: Packed) -> (int, bool) {
    i := 1
    f := 1.5
    b := i < 2
    _ = 1 + 2 * 3
    _ = 'x'
    _ = "lit"
    _ = 2.5 * 2
    _ = i + 2
    _ = 2 + i
    _ = f * 2
    _ = i == 2
    _ = b && true
    _ = i << 2
    _ = -i
    _ = !b
    _ = e.pos
    _ = e.id
    _ = e.base
    _ = e.name
    _ = pe.next
    _ = pe.pos.x
    _ = pe.next.id
    _ = Color.Green
    _ = bf.hi
    _ = v.xy
    _ = v.z
    _ = v.rgb
    _ = pair()
    _ = maybe()
    _ = nothing()
    _ = add(1, 2)
    _ = add(f32(1), 2)
    _ = ident("s")
    _ = ident(f)
    _ = first(s)
    l: List(int)
    _ = l
    _ = l.items
    _ = l.count
    _ = s[0]
    _ = a[1]
    _ = m["k"]
    _ = str[0]
    _ = g[.Red]
    _ = s[1:]
    _ = a[:2]
    _ = str[1:]
    _ = pe^
    _ = &i
    _ = &e.pos
    _ = &m["k"]
    _ = &sh.(Point)
    _ = cast(u8)i
    _ = u16(i)
    _ = transmute(u32)f32(1)
    _ = auto_cast f
    _ = sh.(Point)
    _ = sh.(Point) or_else Point{}
    n := find("x") or_return
    _ = n
    _ = i > 0 ? f32(1) : 2
    _ = 1 if b else 2
    _ = Point{1, 2}
    _ = [?]int{1, 2, 3}
    _ = Colors{.Red}
    _ = map[string]int{}
    _ = len(s)
    _ = len("abc")
    _ = len(a)
    _ = size_of(Point)
    _ = make([]int, 4)
    _ = make(map[string]int)
    _ = new(Point)
    _ = min(i, 3)
    _ = max(f32(1), 2)
    _ = abs(f)
    _ = raw_data(s)
    _ = append(&s2, 1)
    _ = context
    return 0, true
}
s2: [dynamic]int
`

@(test)
test_expr_operands :: proc(t: ^testing.T) {
    expect_exprs(t, EXPR_SRC, {
        {"1 + 2 * 3", "untyped int", ""},
        {"'x'", "untyped rune", ""},
        {`"lit"`, "untyped string", "_ = "},
        {"2.5 * 2", "untyped float", ""},
        {"i + 2", "int", ""},
        {"2 + i", "int", ""},
        {"f * 2", "f64", ""},
        {"i == 2", "untyped bool", ""},
        {"b && true", "untyped bool", ""},
        {"i << 2", "int", ""},
        {"-i", "int", ""},
        {"!b", "bool", ""},
        {"b", "bool", "!"},
        {"e.pos", "Point", ""},
        {"e.id", "int", ""},
        {"e.base", "Base", ""},
        {"e.name", "string", ""},
        {"pe.next", "^Entity", ""},
        {"pe.pos.x", "f32", ""},
        {"pe.next.id", "int", ""},
        {"Color.Green", "Color", ""},
        {"bf.hi", "u8", ""},
        {"v.xy", "[2]f32", ""},
        {"v.z", "f32", ""},
        {"v.rgb", "[3]f32", ""},
        {"pair()", "(int, string)", ""},
        {"maybe()", "int", ""},
        {"add(1, 2)", "int", ""},
        {"add(f32(1), 2)", "f32", ""},
        {`ident("s")`, "string", ""},
        {"ident(f)", "f64", ""},
        {"first(s)", "int", ""},
        {"l", "List(int)", "_ = l\n"},
        {"l.items", "[]int", ""},
        {"l.count", "int", ""},
        {"s[0]", "int", "_ = s[0]"},
        {"a[1]", "u8", ""},
        {`m["k"]`, "f64", ""},
        {"str[0]", "u8", ""},
        {"g[.Red]", "int", ""},
        {"s[1:]", "[]int", ""},
        {"a[:2]", "[]u8", ""},
        {"str[1:]", "string", ""},
        {"pe^", "Entity", ""},
        {"&i", "^int", ""},
        {"&e.pos", "^Point", ""},
        {`&m["k"]`, "^f64", ""},
        {"&sh.(Point)", "^Point", ""},
        {"cast(u8)i", "u8", ""},
        {"u16(i)", "u16", ""},
        {"transmute(u32)f32(1)", "u32", ""},
        {"auto_cast f", "f64", ""},
        {"sh.(Point)", "Point", ""},
        {"sh.(Point) or_else Point{}", "Point", ""},
        {`find("x") or_return`, "int", ""},
        {"n", "int", "_ = n\n"},
        {"i > 0 ? f32(1) : 2", "f32", ""},
        {"1 if b else 2", "untyped int", ""},
        {"Point{1, 2}", "Point", ""},
        {"[?]int{1, 2, 3}", "[3]int", ""},
        {"Colors{.Red}", "Colors", ""},
        {"map[string]int{}", "map[string]int", ""},
        {"len(s)", "int", ""},
        {`len("abc")`, "untyped int", ""},
        {"len(a)", "untyped int", ""},
        {"size_of(Point)", "untyped int", ""},
        {"make([]int, 4)", "[]int", ""},
        {"make(map[string]int)", "map[string]int", ""},
        {"new(Point)", "^Point", ""},
        {"min(i, 3)", "int", ""},
        {"max(f32(1), 2)", "f32", ""},
        {"abs(f)", "f64", ""},
        {"raw_data(s)", "[^]int", ""},
        {"append(&s2, 1)", "int", ""},
    })
}

@(test)
test_expr_modes :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = EXPR_SRC}) {
        return
    }
    defer check_end(&env)
    Mode_Case :: struct {
        expr: string,
        mode: Operand_Mode,
    }
    cases := [?]Mode_Case {
        {"1 + 2 * 3", .Const},
        {"Color.Green", .Const},
        {"nothing()", .No_Value},
        {"e.pos", .Value},
        {"Point{1, 2}", .Value},
        {"List(int)", .Type},
    }
    for k in cases {
        at := marker_offset(EXPR_SRC, k.expr, "")
        n, ok := expr_node_at(&env.c, ANON_FILE, at, k.expr)
        if !testing.expectf(t, ok, "%q: no expression node", k.expr) {
            continue
        }
        op := expr_type(&env.c, ANON_FILE, n)
        testing.expectf(t, op.mode == k.mode, "%q: got %v, want %v", k.expr, op.mode, k.mode)
    }
    at := marker_offset(EXPR_SRC, "1 + 2 * 3", "")
    if n, ok := expr_node_at(&env.c, ANON_FILE, at, "1 + 2 * 3"); testing.expect(t, ok) {
        testing.expect_value(t, expr_type(&env.c, ANON_FILE, n).value, Const_Value(i64(7)))
    }
}

@(test)
test_expr_locals :: proc(t: ^testing.T) {
    src := `package p

Color :: enum { Red, Green }
Point :: struct { x: f32 }
Shape :: union { Point, int }
parts :: proc() -> ([]string, bool) #optional_ok { return nil, true }

walk :: proc(s: []int, m: map[string]f64, str: string, g: [Color]u8, sh: Shape, d: [dynamic]Point) {
    for x in s { _ = x }
    for k, val in m { _ = k; _ = val }
    for r, ri in str { _ = r; _ = ri }
    for j in 0..<10 { _ = j }
    for elem, c in g { _ = elem; _ = c }
    for p, pi in d { _ = p.x; _ = pi }
    for &q in d { _ = q }
    for col, ci in Color { _ = col; _ = ci }
    for part, pn in parts() { _ = part; _ = pn }
    switch v in sh {
    case Point:
        _ = v.x
    case int:
        _ = v
    case:
        _ = v
    }
}
`
    expect_exprs(t, src, {
        {"x", "int", "_ = x"},
        {"k", "string", "_ = k"},
        {"val", "f64", "_ = val"},
        {"r", "rune", "_ = r"},
        {"ri", "int", "_ = ri"},
        {"j", "int", "_ = j"},
        {"elem", "u8", "_ = elem"},
        {"c", "Color", "_ = c"},
        {"p.x", "f32", "_ = "},
        {"pi", "int", "_ = pi"},
        {"q", "Point", "_ = q"},
        {"col", "Color", "_ = col"},
        {"ci", "int", "_ = ci"},
        {"part", "string", "_ = part"},
        {"pn", "int", "_ = pn"},
        {"v.x", "f32", "case Point:"},
        {"v", "int", "case int:"},
        {"v", "Shape", "case:"},
    })
}

@(test)
test_expr_package_member :: proc(t: ^testing.T) {
    dir, ok := check_fixture(t, "expr_package")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    app_src := `package app

import g "../geom"

use :: proc() {
    _ = g.Kind.Circle
    _ = g.make_shape()
    _ = g.make_shape().kind
    _ = g.MAX
    s: g.Shape
    _ = s.next
}
`
    app := put_file(t, dir, "app/app.odin", app_src)
    put_file(t, dir, "geom/geom.odin", `package geom

MAX :: 3
Kind :: enum { Square, Circle }
Shape :: struct { kind: Kind, next: ^Shape }
make_shape :: proc() -> Shape { return {} }
`)
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{}) {
        return
    }
    defer check_end(&env)
    id := db_file_id(&env.snap, app)
    env.c.home_key = file_cache(&env.c, id).dir_key
    cases := [?]Expr_Case {
        {"g.Kind.Circle", "geom.Kind", ""},
        {"g.make_shape()", "geom.Shape", ""},
        {"g.make_shape().kind", "geom.Kind", ""},
        {"g.MAX", "untyped int", ""},
        {"s.next", "^geom.Shape", ""},
    }
    for k in cases {
        expect_expr(t, &env.c, id, app_src, k)
    }
    at := marker_offset(app_src, "g.MAX", "")
    if n, nok := expr_node_at(&env.c, id, at, "g"); testing.expect(t, nok) {
        testing.expect_value(t, expr_type(&env.c, id, n).mode, Operand_Mode.Package)
    }
}

// One kind of failure of the expression sweep, with a first sample.
@(test)
test_expr_build_constants :: proc(t: ^testing.T) {
    dir, ok := check_fixture(t, "expr_constants")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    put_file(t, dir, "runtime/core.odin", `package runtime

Allocator :: struct { data: rawptr }
Odin_OS_Type :: type_of(ODIN_OS)
Odin_Sanitizer_Flags :: type_of(ODIN_SANITIZER_FLAGS)
`)
    src := `package app

use :: proc(d: [dynamic]int, m: map[string]int) {
    _ = ODIN_OS
    _ = ODIN_ARCH
    _ = ODIN_OS == .Windows
    _ = ODIN_SANITIZER_FLAGS
    _ = ODIN_ROOT
    _ = ODIN_TEST
    _ = d.allocator
    _ = m.allocator
}
`
    app := put_file(t, dir, "app/app.odin", src)
    universe := [?]Universe_Package{{fmt.tprintf("%s/runtime", dir), false}}
    env: Check_Env
    target := Target{os = .Windows, arch = .amd64}
    if !check_begin(t, &env, Snapshot_Input{target = target}, universe[:]) {
        return
    }
    defer check_end(&env)
    id := db_file_id(&env.snap, app)
    env.c.home_key = file_cache(&env.c, id).dir_key
    cases := [?]Expr_Case {
        {"ODIN_OS", "runtime.Odin_OS_Type", "_ = "},
        {"ODIN_ARCH", "enum int {Unknown, amd64, i386, arm32, arm64, wasm32, wasm64p32, riscv64}", ""},
        {"ODIN_OS == .Windows", "untyped bool", ""},
        {"ODIN_SANITIZER_FLAGS", "runtime.Odin_Sanitizer_Flags", ""},
        {"ODIN_ROOT", "untyped string", ""},
        {"ODIN_TEST", "untyped bool", ""},
        {"d.allocator", "runtime.Allocator", ""},
        {"m.allocator", "runtime.Allocator", ""},
    }
    for k in cases {
        expect_expr(t, &env.c, id, src, k)
    }
    at := marker_offset(src, "ODIN_OS", "_ = ")
    if n, nok := expr_node_at(&env.c, id, at, "ODIN_OS"); testing.expect(t, nok) {
        testing.expect_value(t, expr_type(&env.c, id, n).value, Const_Value(i64(1)))
    }
    testing.expect_value(t, env.c.err, nil)
}

@(private = "file")
Sweep_Fail :: struct {
    key:    string,
    count:  int,
    sample: string,
}

@(private = "file")
Sweep :: struct {
    c:          ^Checker,
    fails:      map[string]Sweep_Fail,
    idents:     int,
    idents_ok:  int,
    selectors:  int,
    selects_ok: int,
    cascades:   int, // selectors whose operand is invalid
    implicits:  int,
    implicit_ok: int,
}

@(private = "file")
sweep_fail :: proc(s: ^Sweep, file: File_Id, offset: int, key: string) {
    entry, found := &s.fails[key]
    if found {
        entry.count += 1
        return
    }
    parsed := checker_parse(s.c, file)
    text := parsed.tree.text
    line := strings.count(text[:offset], "\n") + 1
    end := strings.index_byte(text[offset:], '\n')
    snippet := end < 0 ? text[offset:] : text[offset:][:end]
    path := db_file_path(s.c.snap, file)
    s.fails[strings.clone(key, context.temp_allocator)] = Sweep_Fail{
        key    = key,
        count  = 1,
        sample = fmt.tprintf("%s:%d: %s", filepath.base(path), line, strings.trim_space(snippet)),
    }
}

// True when an operand is known: a value or a type has a type.
@(private = "file")
sweep_typed :: proc(op: Operand) -> bool {
    #partial switch op.mode {
    case .Invalid:
        return false
    case .Value, .Const, .Type:
        return op.type != INVALID_TYPE
    }
    return true
}

// False for a name that is not an expression: the library of a foreign block, the field of
// `offset_of` or the name of `#config`.
@(private = "file")
sweep_is_expr :: proc(c: ^Checker, file: File_Id, offset: int) -> bool {
    path := node_path(c, file, offset)
    if len(path) < 2 {
        return true
    }
    parent := path[len(path) - 2]
    if parent.green.kind == .Foreign_Block {
        return false
    }
    if parent.green.kind == .Arg_List && len(path) >= 3 {
        call, ok := odinsyntax.as_call_expr(path[len(path) - 3])
        if !ok {
            return true
        }
        if callee, cok := odinsyntax.call_expr_callee(&call); cok {
            text := odinsyntax.node_text(callee)
            if strings.has_prefix(text, "offset_of") || text == "#config" || text == "#defined" {
                return false
            }
        }
    }
    return true
}

// Types every reference of the file-scope declaration at `start`.
@(private = "file")
sweep_decl :: proc(s: ^Sweep, file: File_Id, start: int) {
    c := s.c
    m := scope_map_at(c, file, start)
    if m == nil {
        return
    }
    for ref in m.refs {
        if ref.is_decl || ref.name == "_" {
            continue
        }
        #partial switch ref.kind {
        case .Local, .Free:
            if ref.kind == .Local && ref.decl_kind == .Label {
                continue
            }
            n, ok := node_of_kind(c, file, ref.start, .Ident)
            if !ok || !sweep_is_expr(c, file, ref.start) {
                continue
            }
            s.idents += 1
            if op := expr_type(c, file, n); sweep_typed(op) {
                s.idents_ok += 1
                continue
            }
            r := lookup_name(c, file, ref.name, ref.start)
            key: string
            if op := expr_type(c, file, n); op.mode != .Invalid {
                key = fmt.tprintf("ident %v with no type ", op.mode)
            }
            #partial switch r.kind {
            case .Local:
                key = fmt.tprintf("%sident local %v/%v", key, r.local.kind, r.local.source)
            case .Item:
                item := checker_item(c, r.symbol)
                key = fmt.tprintf("%sident item %v", key, item != nil ? item.kind : Item_Kind{})
            case .None:
                key = fmt.tprintf("ident unresolved %s", ref.name)
            case:
                key = fmt.tprintf("ident %v", r.kind)
            }
            sweep_fail(s, file, ref.start, key)
        case .Field_Or_Member, .Package_Qualified:
            sel: odinsyntax.Syntax_Node
            found := false
            for n in node_path(c, file, ref.start) {
                if n.green.kind == .Selector_Expr {
                    se, _ := odinsyntax.as_selector_expr(n)
                    if field, fok := odinsyntax.selector_expr_field(&se); fok && int(field.offset) == ref.start {
                        sel, found = n, true
                    }
                }
            }
            if !found {
                continue
            }
            s.selectors += 1
            if op := expr_type(c, file, sel); sweep_typed(op) {
                s.selects_ok += 1
                continue
            }
            se, _ := odinsyntax.as_selector_expr(sel)
            operand, _ := odinsyntax.selector_expr_operand(&se)
            op := expr_type(c, file, operand)
            if !sweep_typed(op) {
                s.cascades += 1
                sweep_fail(s, file, ref.start, fmt.tprintf("selector on invalid %v", operand.green.kind))
                continue
            }
            sweep_fail(s, file, ref.start, fmt.tprintf("selector %v on %v", op.mode, type_kind(&c.table, type_base(&c.table, op.type))))
        case .Implicit_Selector:
            n, ok := node_of_kind(c, file, ref.start - 1, .Implicit_Selector)
            if !ok {
                continue
            }
            s.implicits += 1
            expected := expected_type_at(c, file, int(n.offset))
            if op := expr_type(c, file, n, expected); sweep_typed(op) {
                s.implicit_ok += 1
                continue
            }
            path := node_path(c, file, int(n.offset))
            parent := len(path) >= 2 ? path[len(path) - 2].green.kind : .None
            for p, k in path {
                if same_node(p, n) && k > 0 {
                    parent = path[k - 1].green.kind
                }
            }
            sweep_fail(s, file, int(n.offset), fmt.tprintf("implicit selector in %v, expected %v", parent, type_kind(&c.table, type_base(&c.table, expected))))
        }
    }
}

// Every identifier and selector of the repository gets an operand with no crash; the share that is
// not invalid and the most common failures are logged. Run from the repository root.
@(test)
test_expr_repository_sweep :: proc(t: ^testing.T) {
    dirs := make([dynamic]string, context.temp_allocator)
    collect_package_dirs(".", &dirs)
    if !testing.expectf(t, len(dirs) > 10, "only %d package directories", len(dirs)) {
        return
    }
    root := ODIN_ROOT
    builtin_dir, _ := filepath.join({root, "base", "builtin"}, context.temp_allocator)
    runtime_dir, _ := filepath.join({root, "base", "runtime"}, context.temp_allocator)
    universe := [?]Universe_Package{{builtin_dir, true}, {runtime_dir, false}}
    collections := Collections{odin_root = root}
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{collections = &collections}, universe[:]) {
        return
    }
    defer check_end(&env)
    s := Sweep{c = &env.c, fails = make(map[string]Sweep_Fail, context.temp_allocator)}
    start := time.tick_now()
    for dir in dirs {
        view := db_package(&env.snap, db_package_id(&env.snap, dir))
        if view == nil {
            continue
        }
        for id, fi in view.files {
            if view.datas[fi] == nil || !db_in_build(&env.snap, id) {
                continue
            }
            parsed := checker_parse(&env.c, id)
            if parsed == nil || parsed.tree == nil || parsed.tree.root == nil {
                continue
            }
            root_node := odinsyntax.node_root(parsed.tree)
            pos := int(root_node.offset)
            for child in odinsyntax.green_children(root_node.green) {
                if _, is_node := odinsyntax.element_node(child); is_node {
                    sweep_decl(&s, id, pos)
                }
                pos += int(odinsyntax.element_len(child))
            }
        }
    }
    total := s.idents + s.selectors
    ok := s.idents_ok + s.selects_ok
    testing.expect(t, total > 10_000, "the sweep must reach the repository's expressions")
    testing.expect_value(t, env.c.err, nil)
    pct :: proc(a, b: int) -> f64 { return b > 0 ? 100 * f64(a) / f64(b) : 0 }
    log.infof("expr_type sweep: %d of %d typed (%.2f%%); identifiers %d of %d (%.2f%%), selectors %d of %d (%.2f%%, %d on an invalid operand), implicit selectors %d of %d (%.2f%%), in %v",
        ok, total, pct(ok, total), s.idents_ok, s.idents, pct(s.idents_ok, s.idents), s.selects_ok, s.selectors,
        pct(s.selects_ok, s.selectors), s.cascades, s.implicit_ok, s.implicits, pct(s.implicit_ok, s.implicits), time.tick_since(start))
    fails := make([dynamic]Sweep_Fail, context.temp_allocator)
    for _, f in s.fails {
        append(&fails, f)
    }
    slice.sort_by(fails[:], proc(a, b: Sweep_Fail) -> bool { return a.count > b.count })
    for f, i in fails {
        if i >= 25 {
            break
        }
        log.infof("%6d  %s  e.g. %s", f.count, f.key, f.sample)
    }
}
