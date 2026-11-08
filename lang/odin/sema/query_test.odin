package odinsema

import "core:os"
import "core:strings"
import "core:testing"

// A place in the source and the type an expression there is expected to have.
@(private = "file")
Expected_Case :: struct {
    at:    string,
    after: string,
    want:  string,
}

@(private = "file")
QUERY_SRC :: `package p

Color :: enum { Red, Green, Blue }
Colors :: bit_set[Color]
Point :: struct { x, y: f32, c: Color }
Grid :: [Color]int
paint :: proc(c: Color, p: Point = {}) {}
paint_i :: proc(i: int) {}
paint_f :: proc(f: f32, c: Color) {}
paints :: proc{paint_i, paint_f}
pick :: proc() -> (Color, int) {
    return .Red, 1
}
Base :: struct { id: int, name: string }
Entity :: struct {
    using base: Base,
    pos:  Point,
    next: ^Entity,
}
Packed :: bit_field u16 { lo: u8 | 4, hi: u8 | 4 }

main :: proc() {
    c: Color = .Green
    c = .Blue
    flags: Colors = {.Red, .Green}
    paint(.Red)
    paint(c = .Blue)
    paints(1.5, .Green)
    p := Point{1, 2, .Red}
    q := Point{c = .Blue}
    g := Grid{.Red = 1}
    if c == .Red {}
    if .Green != c {}
    switch c {
    case .Green:
    }
    m: map[Color]int
    _ = m[.Red]
    v: Point = {}
    i := 3
    x: u8 = auto_cast i
    has := .Red in flags
    if has {}
    e: Entity
    _ = e.id
    _ = e.pos
    _ = Color.Green
    _ = p.c
    _ = e.pos.c
    pe := &e
    _ = pe.name
    nested := [2]Point{{c = .Green}, {}}
    store(&c, .Blue)
    pickc := Color.Red if has else .Green
    switch c {
    case .Red ..= .Green:
    }
}
store :: proc(dst: ^$T, val: T) {}
`

@(private = "file")
query_offset :: proc(t: ^testing.T, src, at, after: string, loc := #caller_location) -> int {
    off := marker_offset(src, at, after)
    testing.expectf(t, off >= 0, "%q after %q: not in the source", at, after, loc = loc)
    return off
}

@(test)
test_query_expected_type :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = QUERY_SRC}) {
        return
    }
    defer check_end(&env)
    cases := [?]Expected_Case {
        {".Green", "c: Color = ", "Color"},
        {".Blue", "c = ", "Color"},
        {"{.Red, .Green}", "flags: Colors = ", "Colors"},
        {".Red", "flags: Colors = {", "Color"},
        {".Green", "flags: Colors = {.Red, ", "Color"},
        {".Red", "paint(", "Color"},
        {".Blue", "paint(c = ", "Color"},
        {"Blue", "paint(c = .", "Color"},
        {".Green", "paints(1.5, ", "Color"},
        {"1.5", "paints(", "f32"},
        {"2", "Point{1, ", "f32"},
        {".Red", "Point{1, 2, ", "Color"},
        {".Blue", "Point{c = ", "Color"},
        {".Red", "Grid{", "Color"},
        {"1", "Grid{.Red = ", "int"},
        {".Red", "c == ", "Color"},
        {".Green", "if ", "Color"},
        {".Green", "case ", "Color"},
        {".Red", "return ", "Color"},
        {"1", "return .Red, ", "int"},
        {".Red", "m[", "Color"},
        {"{}", "v: Point = ", "Point"},
        {"{}", "p: Point = ", "Point"},
        {"auto_cast i", "", "u8"},
        {".Red", "has := ", "Color"},
        {".Green", "nested := [2]Point{{c = ", "Color"},
        {"{c = .Green}", "nested := [2]Point{", "Point"},
        {"has", "if has", "bool"},
        {"e.id", "_ = ", "invalid"},
        {".Blue", "store(&c, ", "Color"},
        {".Green", "pickc := Color.Red if has else ", "Color"},
        {".Green", "case .Red ..= ", "Color"},
        {".Red", "    case .Red", "Color"},
    }
    for k in cases {
        off := query_offset(t, QUERY_SRC, k.at, k.after)
        if off < 0 {
            continue
        }
        got := type_string(&env.c.table, expected_type_at(&env.c, ANON_FILE, off), context.temp_allocator)
        testing.expectf(t, got == k.want, "%q after %q: got %q, want %q", k.at, k.after, got, k.want)
    }
    // The expected type types an implicit selector, a literal with no type and `auto_cast`.
    Typed_Case :: struct {
        at, after, want: string,
    }
    typed := [?]Typed_Case {
        {".Blue", "c = ", "Color"},
        {"{.Red, .Green}", "flags: Colors = ", "Colors"},
        {"auto_cast i", "", "u8"},
        {".Green", "nested := [2]Point{{c = ", "Color"},
    }
    for k in typed {
        off := query_offset(t, QUERY_SRC, k.at, k.after)
        n, ok := expr_node_at(&env.c, ANON_FILE, off, k.at)
        if !testing.expectf(t, ok, "%q: no expression node", k.at) {
            continue
        }
        op := expr_type(&env.c, ANON_FILE, n, expected_type_at(&env.c, ANON_FILE, off))
        got := type_string(&env.c.table, op.type, context.temp_allocator)
        testing.expectf(t, got == k.want, "%q: got %q, want %q", k.at, got, k.want)
    }
    testing.expect_value(t, env.c.err, nil)
}

// The text of a member list: `name: type` joined by ", ".
@(private = "file")
members_text :: proc(c: ^Checker, members: []Member) -> string {
    sb := strings.builder_make(context.temp_allocator)
    for m, i in members {
        if i > 0 {
            strings.write_string(&sb, ", ")
        }
        strings.write_string(&sb, m.name)
        strings.write_string(&sb, ": ")
        strings.write_string(&sb, type_string(&c.table, m.type, context.temp_allocator))
    }
    return strings.to_string(sb)
}

@(test)
test_query_type_members :: proc(t: ^testing.T) {
    src := `package p

Point :: struct { x, y: f32 }
Base :: struct { id: int, name: string }
Mid :: struct { using base: Base, id: i64, depth: u8 }
Entity :: struct {
    using mid: Mid,
    pos:  Point,
    next: ^Entity,
}
Color :: enum { Red, Green }
Packed :: bit_field u16 { lo: u8 | 4, hi: u8 | 4 }
Soa_Points :: #soa[4]Point
Soa_Slice :: #soa[]Point
Soa_Vecs :: #soa[4][3]f32
Shape :: union { Point }
v_entity: Entity
v_ptr: ^Entity
v_packed: Packed
v_soa: Soa_Points
v_soa_slice: Soa_Slice
v_soa_vecs: Soa_Vecs
v_soa_pairs: #soa[][2]f64
v_any: any
v_shape: Shape
v_vec: [3]f32
`
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = src}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    Members_Case :: struct {
        name: string,
        want: string,
    }
    cases := [?]Members_Case {
        {"v_entity", "mid: Mid, pos: Point, next: ^Entity, base: Base, id: i64, depth: u8, name: string"},
        {"v_ptr", "mid: Mid, pos: Point, next: ^Entity, base: Base, id: i64, depth: u8, name: string"},
        {"v_packed", "lo: u8, hi: u8"},
        {"v_soa", "x: [4]f32, y: [4]f32"},
        {"v_soa_slice", "x: [^]f32, y: [^]f32"},
        {"v_soa_vecs", "x: [4]f32, y: [4]f32, z: [4]f32"},
        {"v_soa_pairs", "x: [^]f64, y: [^]f64"},
        {"v_any", "data: rawptr, id: typeid"},
        {"v_shape", ""},
        {"v_vec", ""},
    }
    for k in cases {
        sym, ok := find_symbol(c, ANON_FILE, k.name)
        if !testing.expectf(t, ok, "%s: not declared", k.name) {
            continue
        }
        members := type_members(c, decl_type(c, sym), context.temp_allocator)
        got := members_text(c, members)
        testing.expectf(t, got == k.want, "%s: got %q, want %q", k.name, got, k.want)
    }
    if sym, ok := find_symbol(c, ANON_FILE, "v_soa_vecs"); testing.expect(t, ok) {
        vecs := decl_type(c, sym)
        hit, found := find_field(c, vecs, "z")
        testing.expect(t, found && type_string(&c.table, hit.type, context.temp_allocator) == "[4]f32")
        _, found = find_field(c, vecs, "w")
        testing.expect(t, !found)
    }
    if sym, ok := find_symbol(c, ANON_FILE, "v_entity"); testing.expect(t, ok) {
        members := type_members(c, decl_type(c, sym), context.temp_allocator)
        for m in members {
            want_depth := 0
            switch m.name {
            case "base", "id", "depth": want_depth = 1
            case "name":                want_depth = 2
            }
            testing.expectf(t, m.depth == want_depth, "%s: depth %d, want %d", m.name, m.depth, want_depth)
            testing.expectf(t, m.kind == .Field && m.has_symbol, "%s: kind %v", m.name, m.kind)
            if m.name == "id" {
                // The shallower `Mid.id` hides `Base.id`.
                item := checker_item(c, m.symbol)
                testing.expect(t, item != nil && item.name == "id" && m.symbol.item == find_item_index(c, "Mid"))
            }
        }
    }
    if sym, ok := find_symbol(c, ANON_FILE, "Color"); testing.expect(t, ok) {
        members := operand_members(c, item_operand(c, sym), context.temp_allocator)
        testing.expect_value(t, members_text(c, members), "Red: Color, Green: Color")
        for m in members {
            testing.expect(t, m.kind == .Enum_Member && m.has_symbol && m.symbol.child >= 0)
        }
    }
    testing.expect_value(t, env.c.err, nil)
}

// The index of the item named `name` of the live buffer; -1 when there is none.
@(private = "file")
find_item_index :: proc(c: ^Checker, name: string) -> i32 {
    sym, ok := find_symbol(c, ANON_FILE, name)
    return ok ? sym.item : -1
}

// A name a selector symbol is asked for, and the declaration name it should give.
@(private = "file")
Symbol_Case :: struct {
    at:         string, // the name
    after:      string,
    decl:       string, // the declared name
    decl_after: string,
}

@(test)
test_query_selector_symbol :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = QUERY_SRC}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    cases := [?]Symbol_Case {
        {"id", "_ = e.", "id", "Base :: struct { "},
        {"pos", "_ = e.", "pos", "Entity :: struct {"},
        {"Green", "_ = Color.", "Green", "Color :: enum { Red, "},
        {"c", "_ = p.", "c", "f32, c"},
        {"c", "_ = e.pos.", "c", "f32, c"},
        {"name", "_ = pe.", "name", "Base :: struct { id: int, "},
        {"Blue", "c = .", "Blue", "Color :: enum { Red, Green, "},
        {"Red", "paint(.", "Red", "Color :: enum { "},
        {"Green", "case .", "Green", "Color :: enum { Red, "},
        {"c", "q := Point{", "c", "f32, c"},
        {"c", "nested := [2]Point{{", "c", "f32, c"},
        {"c", "paint(", "c", "(c: Color, p: Point"},
        {"Red", "Grid{.", "Red", "Color :: enum { "},
    }
    for k in cases {
        off := query_offset(t, QUERY_SRC, k.at, k.after)
        if off < 0 {
            continue
        }
        sym, ok := selector_symbol(c, ANON_FILE, off)
        if !testing.expectf(t, ok, "%q after %q: no symbol", k.at, k.after) {
            continue
        }
        file, start, end, rok := symbol_range(c, sym)
        if !testing.expectf(t, rok, "%q after %q: no range for %v", k.at, k.after, sym) {
            continue
        }
        want := marker_offset(QUERY_SRC, k.decl, k.decl_after)
        testing.expectf(t, file == ANON_FILE && start == want && end == want + len(k.decl),
            "%q after %q: got [%d, %d), want [%d, %d)", k.at, k.after, start, end, want, want + len(k.decl))
        if sym.item != LOCAL_ITEM {
            testing.expectf(t, sym.child >= 0, "%q after %q: a field must be an item child, got %v", k.at, k.after, sym)
        }
    }
    // A name that is not on the right side of a selector gives nothing.
    if off := query_offset(t, QUERY_SRC, "e", "_ = e.id"); off >= 0 {
        _, ok := selector_symbol(c, ANON_FILE, off)
        testing.expect(t, !ok)
    }
    // The symbol of a field is the item child decl_type reads.
    if off := query_offset(t, QUERY_SRC, "pos", "_ = e."); off >= 0 {
        if sym, ok := selector_symbol(c, ANON_FILE, off); testing.expect(t, ok) {
            testing.expect_value(t, type_string(&c.table, decl_type(c, sym), context.temp_allocator), "Point")
        }
    }
    testing.expect_value(t, env.c.err, nil)
}

@(test)
test_query_package_members :: proc(t: ^testing.T) {
    dir, ok := check_fixture(t, "query_package")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    app_src := `package app

import g "../geom"

use :: proc() {
    _ = g.make_shape()
    _ = g.Kind.Circle
}
`
    app := put_file(t, dir, "app/app.odin", app_src)
    geom_src := `package geom

MAX :: 3
Kind :: enum { Square, Circle }
Shape :: struct { kind: Kind }
make_shape :: proc() -> Shape { return {} }
group :: proc{make_shape}

@(private)
hidden :: 1
`
    geom := put_file(t, dir, "geom/geom.odin", geom_src)
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    id := db_file_id(&env.snap, app)
    geom_id := db_file_id(&env.snap, geom)
    r := lookup_name(c, id, "g", 0)
    if !testing.expect_value(t, r.kind, Resolved_Kind.Import) {
        return
    }
    members := operand_members(c, Operand{mode = .Package, dir = r.dir}, context.temp_allocator)
    names := make([dynamic]string, context.temp_allocator)
    for m in members {
        append(&names, m.name)
        want_kind := Member_Kind.Package_Member
        if m.name == "make_shape" || m.name == "group" {
            want_kind = .Proc
        }
        testing.expectf(t, m.kind == want_kind, "%s: kind %v, want %v", m.name, m.kind, want_kind)
    }
    testing.expect_value(t, strings.join(names[:], ",", context.temp_allocator), "Kind,MAX,Shape,group,make_shape")
    own := package_members(c, r.dir, geom_id, context.temp_allocator)
    testing.expect_value(t, len(own), 6)

    off := marker_offset(app_src, "make_shape", "")
    if sym, sok := selector_symbol(c, id, off); testing.expect(t, sok) {
        file, start, end, rok := symbol_range(c, sym)
        testing.expect(t, rok && file == geom_id)
        want := marker_offset(geom_src, "make_shape ::", "")
        testing.expect(t, start == want && end == want + len("make_shape"))
    }
    off = marker_offset(app_src, "Circle", "")
    if sym, sok := selector_symbol(c, id, off); testing.expect(t, sok) {
        file, start, _, rok := symbol_range(c, sym)
        testing.expect(t, rok && file == geom_id && start == marker_offset(geom_src, "Circle", ""))
    }
    testing.expect_value(t, env.c.err, nil)
}

// A place in the source and the type of the expression expr_under finds there; "" for none.
@(private = "file")
Under_Case :: struct {
    at:    string,
    after: string,
    want:  string,
}

@(test)
test_query_expr_under :: proc(t: ^testing.T) {
    src := `package p

Point :: struct { x, y: f32 }
twice :: proc(n: int) -> int { return n * 2 }

main :: proc() {
    a, b: int
    p: Point
    s := a + b // note
    k := twice(a)
    f := p.y
    l := 42
    v: [3]f32
    w := v.xy
}
`
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = src}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    cases := [?]Under_Case {
        {"+", "s := a ", "int"},
        {"a", "s := ", "int"},
        {")", "twice(a", "int"},
        {"(", "k := twice", "int"},
        {"y", "f := p.", "f32"},
        {"42", "l := ", "untyped int"},
        {"xy", "w := v.", "[2]f32"},
        {" ", "s := a", ""},
        {"note", "// ", ""},
        {"return", "{ ", ""},
    }
    for k in cases {
        off := query_offset(t, src, k.at, k.after)
        if off < 0 {
            continue
        }
        n, ok := expr_under(c, ANON_FILE, off)
        if k.want == "" {
            testing.expectf(t, !ok, "%q after %q: want nothing", k.at, k.after)
            continue
        }
        if !testing.expectf(t, ok, "%q after %q: no expression", k.at, k.after) {
            continue
        }
        got := type_string(&c.table, expr_type(c, ANON_FILE, n).type, context.temp_allocator)
        testing.expectf(t, got == k.want, "%q after %q: got %q, want %q", k.at, k.after, got, k.want)
    }
    testing.expect_value(t, env.c.err, nil)
}
