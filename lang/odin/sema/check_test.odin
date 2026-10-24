package odinsema

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
read_file :: proc(path: string, allocator: mem.Allocator) -> (string, bool) {
    data, err := os.read_entire_file(path, allocator)
    return string(data), err == nil
}

// One snapshot and one checker over it. Do not copy after check_begin.
@(private = "file")
Check_Env :: struct {
    db:   Db,
    snap: Snapshot,
    c:    Checker,
}

@(private = "file")
check_begin :: proc(t: ^testing.T, env: ^Check_Env, input: Snapshot_Input, universe: []Universe_Package = nil, home := NO_FILE) -> bool {
    input := input
    if input.target.os == .Unknown {
        input.target = target_host()
    }
    db_init(&env.db, read_file)
    if !testing.expect(t, snapshot_begin(&env.db, &env.snap, input), "snapshot_begin must succeed") {
        db_destroy(&env.db)
        return false
    }
    if !testing.expect_value(t, checker_init(&env.c, &env.snap, universe, home), nil) {
        snapshot_end(&env.snap)
        db_destroy(&env.db)
        return false
    }
    return true
}

@(private = "file")
check_end :: proc(env: ^Check_Env) {
    checker_destroy(&env.c)
    snapshot_end(&env.snap)
    db_destroy(&env.db)
}

// The symbol of `name` in `file`: `Item` or `Item.child`.
@(private = "file")
find_symbol :: proc(c: ^Checker, file: File_Id, name: string) -> (Symbol, bool) {
    fc := file_cache(c, file)
    if fc == nil || fc.data == nil {
        return {}, false
    }
    head, _, child := strings.partition(name, ".")
    for item, i in fc.data.tree.items {
        if item.name != head {
            continue
        }
        if child == "" {
            return Symbol{file, i32(i), -1}, true
        }
        for ch, j in item.children {
            if ch.name == child {
                return Symbol{file, i32(i), i32(j)}, true
            }
        }
    }
    return {}, false
}

// A declaration and the type it should print. `underlying` prints the type a named type stands for.
@(private = "file")
Decl_Case :: struct {
    name:       string,
    want:       string,
    underlying: bool,
}

@(private = "file")
expect_decl :: proc(t: ^testing.T, c: ^Checker, file: File_Id, k: Decl_Case, loc := #caller_location) {
    sym, ok := find_symbol(c, file, k.name)
    if !testing.expectf(t, ok, "%s: not declared", k.name, loc = loc) {
        return
    }
    id := decl_type(c, sym)
    if k.underlying {
        id = type_underlying(&c.table, id)
    }
    got := type_string(&c.table, id, context.temp_allocator)
    testing.expectf(t, got == k.want, "%s: got %q, want %q", k.name, got, k.want, loc = loc)
}

// Checks the declarations of one buffer with no file.
@(private = "file")
expect_decls :: proc(t: ^testing.T, src: string, cases: []Decl_Case, loc := #caller_location) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = src}) {
        return
    }
    defer check_end(&env)
    for k in cases {
        expect_decl(t, &env.c, ANON_FILE, k, loc)
    }
    testing.expect_value(t, env.c.err, nil, loc = loc)
}

@(test)
test_check_records :: proc(t: ^testing.T) {
    src := `package p
Point :: struct {
    x, y: f32,
    tag:  string ` + "`json:\"tag\"`" + `,
}
Node :: struct {
    next:  ^Node,
    value: int,
}
Base :: struct { id: int }
Child :: struct #packed {
    using base: Base,
    kids: [dynamic]^Child,
}
List :: struct($T: typeid, $N: int) #align(8) {
    items: [N]T,
}
Shape :: union #no_nil {Point, Node}
Maybe_Int :: union {int}
Flags :: bit_set[Color; u8]
Letters :: bit_set['a'..='z']
Small :: bit_set[0..<8]
Color :: enum u8 {Red, Green = 4, Blue}
Packed :: bit_field u32 {
    lo: u8 | 4,
    hi: u8 | 4,
}
Raw :: struct #raw_union {i: i32, f: f32}
`
    expect_decls(t, src, {
        {"Point", "Point", false},
        {"Point", "struct {x: f32, y: f32, tag: string}", true},
        {"Point.y", "f32", false},
        {"Node", "struct {next: ^Node, value: int}", true},
        {"Node.next", "^Node", false},
        {"Child", "struct #packed {using base: Base, kids: [dynamic]^Child}", true},
        {"List", "struct($T: typeid, $N: int) #align(8) {items: [?]$T}", true},
        {"Shape", "union #no_nil {Point, Node}", true},
        {"Maybe_Int", "union {int}", true},
        {"Flags", "bit_set[Color; u8]", true},
        {"Letters", "bit_set['a'..='z']", true},
        {"Small", "bit_set[0..=7]", true},
        {"Color", "enum u8 {Red, Green, Blue}", true},
        {"Color.Blue", "Color", false},
        {"Packed", "bit_field u32 {lo: u8 | 4, hi: u8 | 4}", true},
        {"Packed.hi", "u8", false},
        {"Raw", "struct #raw_union {i: i32, f: f32}", true},
    })
}

@(test)
test_check_aliases_and_distinct :: proc(t: ^testing.T) {
    src := `package p
My_Int :: int
Id :: distinct int
Handle :: distinct Id
Ptr :: ^Point
Point :: struct { x: int }
Same :: Point
Vec :: [3]f32
Mat :: #row_major matrix[2, 3]f32
Wide :: #simd[4]f32
Soa :: #soa[]Point
Callback :: #type proc(x: int) -> bool
Lookup :: map[string][]Point
Many :: [^]u8
Grid :: [Color][2]int
Color :: enum {Red, Green}
Any_Id :: typeid
`
    expect_decls(t, src, {
        {"My_Int", "int", false},
        {"Id", "Id", false},
        {"Id", "distinct int", true},
        {"Handle", "distinct Id", true},
        {"Ptr", "^Point", true},
        {"Same", "Point", false},
        {"Vec", "Vec", false},
        {"Vec", "[3]f32", true},
        {"Mat", "#row_major matrix[2, 3]f32", true},
        {"Wide", "#simd[4]f32", true},
        {"Soa", "#soa[]Point", true},
        {"Callback", "proc(x: int) -> bool", true},
        {"Lookup", "map[string][]Point", true},
        {"Many", "[^]u8", true},
        {"Grid", "[Color][2]int", true},
        {"Any_Id", "typeid", false},
    })
}

@(test)
test_check_procs :: proc(t: ^testing.T) {
    src := `package p
add :: proc(a, b: int) -> int { return a + b }
opts :: proc "c" (x: int, y := 2, z: f32 = 1.5, args: ..int) -> (r: int, ok: bool) { return }
flags :: proc(#any_int n: int, #c_vararg rest: ..any, #by_ptr p: Point, #no_alias q: ^int, using pt: Point) {}
stop :: proc() -> ! { for {} }
poly :: proc($T: typeid, x: $E/[]$F) -> T { return {} }
fast :: #force_inline proc(x: f32) -> f32 { return x }
group :: proc{add, fast}
Point :: struct { x: int }
`
    expect_decls(t, src, {
        {"add", "proc(a: int, b: int) -> int", false},
        {"opts", "proc \"c\" (x: int, y := 2, z: f32 = 1.5, args: ..int) -> (r: int, ok: bool)", false},
        {"flags", "proc(#any_int n: int, #c_vararg rest: ..any, #by_ptr p: Point, #no_alias q: ^int, using pt: Point)", false},
        {"stop", "proc() -> !", false},
        {"poly", "proc($T: typeid, x: $E/[]$F) -> $T", false},
        {"fast", "proc(x: f32) -> f32", false},
        {"group", "proc{proc(a: int, b: int) -> int, proc(x: f32) -> f32}", false},
    })
}

@(test)
test_check_values :: proc(t: ^testing.T) {
    src := `package p
N :: 4
M : int : 2
Arr :: [N * 2]int
Typed :: [M + N]u8
pi :: 3.14
name :: "thor"
yes :: true
a := 1
b: f32
c := Point{}
d := &Point{}
e := cast(u8)a
f := u16(a)
g := add(1, 2)
h := N
i, j := pair()
k := Color.Green
size :: size_of(i32)
Point :: struct { x: int }
Color :: enum {Red, Green}
add :: proc(a, b: int) -> int { return a + b }
pair :: proc() -> (int, string) { return 0, "" }
`
    expect_decls(t, src, {
        {"N", "untyped int", false},
        {"M", "int", false},
        {"Arr", "[8]int", true},
        {"Typed", "[6]u8", true},
        {"pi", "untyped float", false},
        {"name", "untyped string", false},
        {"yes", "untyped bool", false},
        {"a", "int", false},
        {"b", "f32", false},
        {"c", "Point", false},
        {"d", "^Point", false},
        {"e", "u8", false},
        {"f", "u16", false},
        {"g", "int", false},
        {"h", "int", false},
        {"i", "int", false},
        {"j", "string", false},
        {"k", "Color", false},
        {"size", "untyped int", false},
    })
}

@(test)
test_check_cycles :: proc(t: ^testing.T) {
    src := `package p
A :: B
B :: A
X :: [Y]int
Y :: len(X)
self :: self
Loop :: struct { inner: Loop }
`
    expect_decls(t, src, {
        {"A", "invalid", false},
        {"B", "invalid", false},
        {"self", "invalid", false},
        {"Loop", "struct {inner: Loop}", true},
    })
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = src}) {
        return
    }
    defer check_end(&env)
    if sym, ok := find_symbol(&env.c, ANON_FILE, "X"); testing.expect(t, ok) {
        _ = decl_type(&env.c, sym)
    }
}

@(test)
test_check_enum_values :: proc(t: ^testing.T) {
    src := `package p
BASE :: 10
E :: enum i32 {
    A,
    B,
    C = 5,
    D,
    E = -3,
    F,
    G = BASE * 2,
    H = C + D,
    I = 1 << 4,
}
`
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = src}) {
        return
    }
    defer check_end(&env)
    sym, ok := find_symbol(&env.c, ANON_FILE, "E")
    if !testing.expect(t, ok) {
        return
    }
    e, is_enum := type_get(&env.c.table, type_underlying(&env.c.table, decl_type(&env.c, sym))).(Enum_Type)
    if !testing.expect(t, is_enum) {
        return
    }
    want := [?]i64{0, 1, 5, 6, -3, -2, 20, 11, 16}
    if !testing.expect_value(t, len(e.members), len(want)) {
        return
    }
    for m, i in e.members {
        testing.expectf(t, m.value == want[i], "%s: got %d, want %d", m.name, m.value, want[i])
    }
    testing.expect_value(t, type_string(&env.c.table, e.backing, context.temp_allocator), "i32")
}

// A constant declaration and the value it should have; nil when it has no known value.
@(private = "file")
Const_Case :: struct {
    name: string,
    want: Const_Value,
}

@(test)
test_check_const_eval :: proc(t: ^testing.T) {
    src := `package p
I1 :: 1 + 2 * 3
I2 :: (1 + 2) * 3
I3 :: 7 / 2
I4 :: -7 % 3
I5 :: -7 %% 3
I6 :: 1 << 10 | 3
I7 :: 0xFF &~ 0x0F
I8 :: ~0
I9 :: 6 ~ 3
I10 :: 1_000_000
I11 :: 0b1010 >> 1
I12 :: -BIG
BIG :: 9_223_372_036_854_775_807
OVER :: BIG + 1
DIV0 :: 1 / 0
MOD0 :: 1 % 0
F1 :: 1.5 * 2
F2 :: 1 / 2.0
S1 :: "ab" + "cd"
S2 :: len("hello")
S3 :: len(S1)
B1 :: 1 < 2 && !false
B2 :: "a" == "b" || 3 >= 3
B3 :: I1 == 7
R1 :: 'a' + 1
T1 :: true ? 1 : 2
T2 :: 3 if false else 4
SZ :: size_of(i64)
AL :: align_of(u16)
CV :: u8(200)
CF :: f32(1)
EM :: Color.Blue
EM2 :: int(Color.Blue) + 1
TYPED : i32 : 40 + 2
REF :: TYPED / 2
CFG :: #config(THOR_NOT_SET, 12)
LOCAL :: proc() -> int {
    K :: 3
    return K
}
Color :: enum {Red, Green, Blue}
`
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = src}) {
        return
    }
    defer check_end(&env)
    cases := [?]Const_Case {
        {"I1", i64(7)},
        {"I2", i64(9)},
        {"I3", i64(3)},
        {"I4", i64(-1)},
        {"I5", i64(2)},
        {"I6", i64(1027)},
        {"I7", i64(0xF0)},
        {"I8", i64(-1)},
        {"I9", i64(5)},
        {"I10", i64(1_000_000)},
        {"I11", i64(5)},
        {"I12", i64(-9_223_372_036_854_775_807)},
        {"BIG", i64(9_223_372_036_854_775_807)},
        {"OVER", nil},
        {"DIV0", nil},
        {"MOD0", nil},
        {"F1", f64(3)},
        {"F2", f64(0.5)},
        {"S1", "abcd"},
        {"S2", i64(5)},
        {"S3", i64(4)},
        {"B1", true},
        {"B2", true},
        {"B3", true},
        {"R1", rune('b')},
        {"T1", i64(1)},
        {"T2", i64(4)},
        {"SZ", i64(8)},
        {"AL", i64(2)},
        {"CV", i64(200)},
        {"CF", f64(1)},
        {"EM", i64(2)},
        {"EM2", i64(3)},
        {"TYPED", i64(42)},
        {"REF", i64(21)},
        {"CFG", i64(12)},
    }
    for k in cases {
        sym, ok := find_symbol(&env.c, ANON_FILE, k.name)
        if !testing.expectf(t, ok, "%s: not declared", k.name) {
            continue
        }
        got := item_operand(&env.c, sym).value
        testing.expectf(t, got == k.want, "%s: got %v, want %v", k.name, got, k.want)
    }

    // A local constant, through the operand of its use.
    if sym, ok := find_symbol(&env.c, ANON_FILE, "LOCAL"); testing.expect(t, ok) {
        item := checker_item(&env.c, sym)
        at := strings.index(src, "return K") + len("return ")
        r := lookup_name(&env.c, ANON_FILE, "K", at)
        testing.expect_value(t, r.kind, Resolved_Kind.Local)
        testing.expect(t, item != nil && at > item.start)
        if n, nok := node_at(&env.c, ANON_FILE, at); testing.expect(t, nok) {
            v, vok := const_eval(&env.c, ANON_FILE, n)
            testing.expect(t, vok && v == Const_Value(i64(3)))
        }
    }
}

@(test)
test_check_odin_constants :: proc(t: ^testing.T) {
    src := `package p
WORD :: ODIN_WORD_SIZE * 8
DEBUG :: ODIN_DEBUG
IS_WINDOWS :: ODIN_OS == .Windows
RETRIES :: 10 when ODIN_OS == .Windows else 1
EXT :: ".exe" when ODIN_OS != .Windows else ""
LIMIT :: max(u32)
LOW :: min(i8)
LEAST :: min(3, 1, 2)
`
    env: Check_Env
    target := Target{os = .Windows, arch = .amd64, debug = true}
    if !check_begin(t, &env, Snapshot_Input{target = target, has_live = true, live_text = src}) {
        return
    }
    defer check_end(&env)
    if sym, ok := find_symbol(&env.c, ANON_FILE, "WORD"); testing.expect(t, ok) {
        testing.expect_value(t, item_operand(&env.c, sym).value, Const_Value(i64(64)))
    }
    cases := [?]Const_Case {
        {"DEBUG", true},
        {"IS_WINDOWS", true},
        {"RETRIES", i64(10)},
        {"EXT", ""},
        {"LIMIT", i64(max(u32))},
        {"LOW", i64(-128)},
        {"LEAST", i64(1)},
    }
    for k in cases {
        if sym, ok := find_symbol(&env.c, ANON_FILE, k.name); testing.expectf(t, ok, "%s: not declared", k.name) {
            got := item_operand(&env.c, sym).value
            testing.expectf(t, got == k.want, "%s: got %v, want %v", k.name, got, k.want)
        }
    }
    if sym, ok := find_symbol(&env.c, ANON_FILE, "EXT"); testing.expect(t, ok) {
        testing.expect_value(t, type_string(&env.c.table, decl_type(&env.c, sym), context.temp_allocator), "untyped string")
    }
    if sym, ok := find_symbol(&env.c, ANON_FILE, "LIMIT"); testing.expect(t, ok) {
        testing.expect_value(t, type_string(&env.c.table, decl_type(&env.c, sym), context.temp_allocator), "u32")
    }
}

@(test)
test_check_locals :: proc(t: ^testing.T) {
    src := `package p
f :: proc($T: typeid, n: int, s := "x") {
    Inner :: struct { v: T }
    x := n
    y: Inner
}
`
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = src}) {
        return
    }
    defer check_end(&env)
    Local_Case :: struct {
        name: string,
        at:   string, // the text whose first occurrence starts the name
        want: string,
    }
    cases := [?]Local_Case {
        {"T", "T }", "$T"},
        {"n", "n\n", "int"},
        {"s", "s :=", "string"},
        {"Inner", "Inner\n", "Inner"},
        {"x", "x :=", "int"},
        {"y", "y:", "Inner"},
    }
    for k in cases {
        at := strings.index(src, k.at)
        if !testing.expectf(t, at >= 0, "%s: no %q", k.name, k.at) {
            continue
        }
        r := lookup_name(&env.c, ANON_FILE, k.name, at)
        if !testing.expectf(t, r.kind == .Local, "%s: got %v", k.name, r.kind) {
            continue
        }
        got := type_string(&env.c.table, decl_type(&env.c, r.symbol), context.temp_allocator)
        testing.expectf(t, got == k.want, "%s: got %q, want %q", k.name, got, k.want)
    }
    r := lookup_name(&env.c, ANON_FILE, "f", 0)
    testing.expect_value(t, r.kind, Resolved_Kind.Item)
    testing.expect_value(t, lookup_name(&env.c, ANON_FILE, "int", 0).kind, Resolved_Kind.Basic)
    testing.expect_value(t, lookup_name(&env.c, ANON_FILE, "nil", 0).kind, Resolved_Kind.Builtin)
    testing.expect_value(t, lookup_name(&env.c, ANON_FILE, "missing", 0).kind, Resolved_Kind.None)
}

// Makes a fresh fixture directory under bin/test.
@(private = "file")
check_fixture :: proc(t: ^testing.T, name: string) -> (string, bool) {
    dir := fmt.tprintf("bin/test/sema_check_%s", name)
    _ = os.remove_all(dir)
    if !testing.expect_value(t, os.make_directory_all(dir), nil) {
        return "", false
    }
    return dir, true
}

@(private = "file")
put_file :: proc(t: ^testing.T, dir, name, text: string) -> string {
    path := fmt.tprintf("%s/%s", dir, name)
    testing.expect_value(t, os.make_directory_all(filepath.dir(path)), nil)
    testing.expect_value(t, os.write_entire_file(path, text), nil)
    return path
}

@(test)
test_check_packages :: proc(t: ^testing.T) {
    dir, ok := check_fixture(t, "packages")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    main_a := put_file(t, dir, "app/a.odin", `package app

import shapes "../geom"

Scene :: struct {
    items: [dynamic]shapes.Shape,
    root:  ^shapes.Node,
    count: [shapes.MAX]Local,
}
first := shapes.make_shape()
kind := shapes.Kind.Circle
`)
    put_file(t, dir, "app/b.odin", `package app

Local :: struct { scene: ^Scene }
`)
    put_file(t, dir, "geom/geom.odin", `package geom

MAX :: 2 + 1

Kind :: enum { Square, Circle }

Shape :: struct {
    kind: Kind,
    next: ^Node,
}

make_shape :: proc() -> Shape { return {} }

@(private)
hidden :: 1
`)
    put_file(t, dir, "geom/node.odin", `package geom

Node :: struct { shape: Shape }
`)
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{}) {
        return
    }
    defer check_end(&env)
    a := db_file_id(&env.snap, main_a)
    env.c.home_key = file_cache(&env.c, a).dir_key
    cases := [?]Decl_Case {
        {"Scene", "struct {items: [dynamic]geom.Shape, root: ^geom.Node, count: [3]Local}", true},
        {"Scene.root", "^geom.Node", false},
        {"first", "geom.Shape", false},
        {"kind", "geom.Kind", false},
    }
    for k in cases {
        expect_decl(t, &env.c, a, k)
    }
    if sym, sok := find_symbol(&env.c, a, "Scene.count"); testing.expect(t, sok) {
        local := type_get(&env.c.table, decl_type(&env.c, sym)).(Array_Type)
        local_struct := type_get(&env.c.table, type_underlying(&env.c.table, local.elem)).(Struct_Type)
        testing.expect_value(t, len(local_struct.fields), 1)
        if len(local_struct.fields) == 1 {
            testing.expect_value(t, type_string(&env.c.table, local_struct.fields[0].type, context.temp_allocator), "^Scene")
        }
    }
    shape_file := db_file_id(&env.snap, fmt.tprintf("%s/geom/geom.odin", dir))
    expect_decl(t, &env.c, shape_file, {"Shape", "struct {kind: geom.Kind, next: ^geom.Node}", true})
    r := lookup_name(&env.c, a, "shapes", 0)
    testing.expect_value(t, r.kind, Resolved_Kind.Import)
    _, hidden := member_lookup(&env.c, r.dir, "hidden", NO_FILE, true)
    testing.expect(t, !hidden, "a private declaration must not be reached from another package")
    testing.expect_value(t, env.c.err, nil)
}

@(test)
test_check_universe :: proc(t: ^testing.T) {
    dir, ok := check_fixture(t, "universe")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    put_file(t, dir, "builtin/builtin.odin", `package builtin

i32  :: i32
byte :: u8
len  :: proc(v: $T) -> int ---
`)
    put_file(t, dir, "runtime/core.odin", `package runtime

Allocator :: struct { data: rawptr }
Context :: struct { allocator: Allocator }
Source_Code_Location :: struct { line: i32 }

@(builtin)
make_it :: proc() -> int { return 0 }

hidden_rt :: proc() {}
`)
    app := put_file(t, dir, "app/app.odin", `package app

import b "../builtin"

W :: b.i32
f :: proc(a := context.allocator, loc := #caller_location) {}
n := make_it()
L :: len("abc")
`)
    universe := [?]Universe_Package{{fmt.tprintf("%s/builtin", dir), true}, {fmt.tprintf("%s/runtime", dir), false}}
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{}, universe[:]) {
        return
    }
    defer check_end(&env)
    id := db_file_id(&env.snap, app)
    env.c.home_key = file_cache(&env.c, id).dir_key
    expect_decl(t, &env.c, id, {"W", "i32", false})
    expect_decl(t, &env.c, id, {"n", "int", false})
    if sym, sok := find_symbol(&env.c, id, "f"); testing.expect(t, sok) {
        p, is_proc := type_get(&env.c.table, decl_type(&env.c, sym)).(Proc_Type)
        if testing.expect(t, is_proc && len(p.params) == 2) {
            testing.expect_value(t, type_string(&env.c.table, p.params[0].type, context.temp_allocator), "runtime.Allocator")
            testing.expect_value(t, type_string(&env.c.table, p.params[1].type, context.temp_allocator), "runtime.Source_Code_Location")
        }
    }
    if sym, sok := find_symbol(&env.c, id, "L"); testing.expect(t, sok) {
        testing.expect_value(t, item_operand(&env.c, sym).value, Const_Value(i64(3)))
    }
    testing.expect_value(t, lookup_name(&env.c, id, "make_it", 0).kind, Resolved_Kind.Item)
    testing.expect_value(t, lookup_name(&env.c, id, "hidden_rt", 0).kind, Resolved_Kind.None)
    testing.expect_value(t, lookup_name(&env.c, id, "byte", 0).kind, Resolved_Kind.Basic)
}

// Every package-level declaration of the repository gets a type with no crash; the share that is
// not invalid is logged. Run from the repository root.
@(test)
test_check_repository_sweep :: proc(t: ^testing.T) {
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
    start := time.tick_now()
    total, typed, whole := 0, 0, 0
    seen := make(map[Type_Id]bool, context.temp_allocator)
    for dir in dirs {
        pkg := db_package_id(&env.snap, dir)
        view := db_package(&env.snap, pkg)
        if view == nil {
            continue
        }
        for id, fi in view.files {
            data := view.datas[fi]
            if data == nil {
                continue
            }
            for item, ii in data.tree.items {
                if item.kind == .Import || item.kind == .Foreign_Import || item.name == "_" {
                    continue
                }
                total += 1
                sym := Symbol{id, i32(ii), -1}
                type := decl_type(&env.c, sym)
                if type == INVALID_TYPE {
                    continue
                }
                typed += 1
                if n, is_named := type_get(&env.c.table, type).(Named_Type); is_named && n.symbol == sym {
                    type = n.underlying
                }
                if !has_invalid(&env.c.table, type, &seen) {
                    whole += 1
                }
            }
        }
    }
    testing.expect(t, total > 1000, "the sweep must reach the repository's declarations")
    testing.expect_value(t, env.c.err, nil)
    share := total > 0 ? 100 * f64(typed) / f64(total) : 0
    whole_share := total > 0 ? 100 * f64(whole) / f64(total) : 0
    log.infof("decl_type sweep: %d of %d declarations typed (%.1f%%), %d with no invalid part (%.1f%%), in %v",
        typed, total, share, whole, whole_share, time.tick_since(start))
}

// True when a type has an invalid part. A named type counts as whole when it has an underlying
// type: its own declaration is checked on its own. `seen` holds the answers.
@(private = "file")
has_invalid :: proc(t: ^Type_Table, id: Type_Id, seen: ^map[Type_Id]bool) -> bool {
    if id == INVALID_TYPE {
        return true
    }
    if answer, ok := seen[id]; ok {
        return answer
    }
    seen[id] = false
    bad := false
    params :: proc(t: ^Type_Table, list: []Proc_Param, seen: ^map[Type_Id]bool) -> bool {
        for p in list {
            if has_invalid(t, p.type, seen) {
                return true
            }
        }
        return false
    }
    switch v in type_get(t, id) {
    case nil:
        bad = true
    case Basic_Type, Untyped_Type:
    case Pointer_Type:          bad = has_invalid(t, v.elem, seen)
    case Multi_Pointer_Type:    bad = has_invalid(t, v.elem, seen)
    case Slice_Type:            bad = has_invalid(t, v.elem, seen)
    case Array_Type:            bad = has_invalid(t, v.elem, seen)
    case Enumerated_Array_Type: bad = has_invalid(t, v.index, seen) || has_invalid(t, v.elem, seen)
    case Dynamic_Array_Type:    bad = has_invalid(t, v.elem, seen)
    case Map_Type:              bad = has_invalid(t, v.key, seen) || has_invalid(t, v.value, seen)
    case Bit_Set_Type:          bad = has_invalid(t, v.elem, seen)
    case Matrix_Type:           bad = has_invalid(t, v.elem, seen)
    case Simd_Type:             bad = has_invalid(t, v.elem, seen)
    case Soa_Type:              bad = has_invalid(t, v.elem, seen)
    case Named_Type:            bad = v.underlying == INVALID_TYPE
    case Distinct_Type:         bad = has_invalid(t, v.base, seen)
    case Poly_Param_Type, Enum_Type:
    case Bit_Field_Type:
        for f in v.fields {
            bad = bad || has_invalid(t, f.type, seen)
        }
    case Struct_Type:
        for f in v.fields {
            bad = bad || has_invalid(t, f.type, seen)
        }
        bad = bad || params(t, v.params, seen)
    case Union_Type:
        for x in v.variants {
            bad = bad || has_invalid(t, x, seen)
        }
        bad = bad || params(t, v.params, seen)
    case Proc_Type:
        bad = params(t, v.params, seen) || params(t, v.results, seen)
    case Tuple_Type:
        for x in v.types {
            bad = bad || has_invalid(t, x, seen)
        }
    case Proc_Group_Type:
        for x in v.members {
            bad = bad || has_invalid(t, x, seen)
        }
    }
    seen[id] = bad
    return bad
}

@(private = "file")
collect_package_dirs :: proc(dir: string, out: ^[dynamic]string) {
    handle, err := os.open(dir)
    if err != nil {
        return
    }
    defer os.close(handle)
    infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if rerr != nil {
        return
    }
    has_source := false
    for info in infos {
        if info.type == .Directory {
            if strings.has_prefix(info.name, ".") || (dir == "." && (info.name == "vendor" || info.name == "bin")) || info.name == "testdata" {
                continue
            }
            path, jerr := filepath.join({dir, info.name}, context.temp_allocator)
            if jerr == nil {
                collect_package_dirs(path, out)
            }
            continue
        }
        if strings.has_suffix(info.name, ".odin") {
            has_source = true
        }
    }
    if has_source {
        append(out, dir)
    }
}
