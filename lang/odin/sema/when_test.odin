package odinsema

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
when_tree :: proc(t: ^testing.T, src: string) -> ^Item_Tree {
    parsed, err := odinsyntax.parse(src)
    testing.expect_value(t, err, nil)
    defer odinsyntax.parse_destroy(&parsed)
    tree, terr := item_tree(parsed)
    testing.expect_value(t, terr, nil)
    return tree
}

// The state of `when cond { X :: 1 }` for `target`.
@(private = "file")
cond_state :: proc(t: ^testing.T, cond: string, target: Target) -> Tri {
    src := strings.concatenate({"package p\n\nwhen ", cond, " {\n    X :: 1\n}\n"}, context.temp_allocator)
    tree := when_tree(t, src)
    defer item_tree_destroy(tree)
    if !testing.expectf(t, len(tree.guards) == 1, "%q: want one guard", cond) {
        return .Unknown
    }
    return guard_state(tree, 0, target)
}

@(private = "file")
item_named :: proc(tree: ^Item_Tree, name: string) -> ^Item {
    for &item in tree.items {
        if item.name == name {
            return &item
        }
    }
    return nil
}

@(test)
test_when_conditions :: proc(t: ^testing.T) {
    defines := []Target_Define {
        {"FAST", true},
        {"LEVEL", i64(3)},
        {"NAME", "thor"},
        {"ODIN_TEST", false},
    }
    win := Target{os = .Windows, arch = .amd64}
    lin := Target{os = .Linux, arch = .i386, debug = true, defines = defines}

    Case :: struct {
        cond:     string,
        win, lin: Tri,
    }
    cases := []Case {
        {"true", .True, .True},
        {"false", .False, .False},
        {"ODIN_OS == .Windows", .True, .False},
        {".Linux == ODIN_OS", .False, .True},
        {"ODIN_OS != .Windows", .False, .True},
        {"ODIN_ARCH == .amd64", .True, .False},
        {"ODIN_ARCH == .i386 || ODIN_ARCH == .arm32", .False, .True},
        {"ODIN_OS == .Windows && ODIN_ARCH == .amd64", .True, .False},
        {"!(ODIN_OS == .Windows)", .False, .True},
        {`ODIN_OS_STRING == "windows"`, .True, .False},
        {"ODIN_ARCH_STRING == `i386`", .False, .True},
        {"ODIN_ENDIAN == .Little", .True, .True},
        {"ODIN_ENDIAN == .Big", .False, .False},
        {"ODIN_DEBUG", .False, .True},
        {"!ODIN_NO_RTTI", .True, .True},
        {"ODIN_TEST", .Unknown, .False},
        {"ODIN_OS in {.Windows, .Darwin}", .True, .False},
        {"ODIN_OS not_in {.Windows, .Darwin}", .False, .True},
        {"size_of(rawptr) == 8", .True, .False},
        {"size_of(int) == 8 || ODIN_ARCH == .i386", .True, .True},
        {"size_of(u16) == 2", .True, .True},
        {"size_of(Float) == 8", .Unknown, .Unknown},
        {"#config(FAST, false)", .False, .True},
        {"#config(LEVEL, 1) >= 2", .False, .True},
        {`#config(NAME, "") == "thor"`, .False, .True},
        {"!#config(FAST, false) && ODIN_OS == .Linux", .False, .False},
        {"#defined(ODIN_OS)", .True, .True},
        {"#defined(SOMETHING)", .Unknown, .Unknown},
        {"#exists(\"lib\")", .Unknown, .Unknown},
        {"LIB != \"\"", .Unknown, .Unknown},
        {"MAP_ENABLED && ODIN_OS == .Darwin", .False, .False},
        {"MAP_ENABLED || ODIN_OS == .Windows", .True, .Unknown},
        {"MAP_ENABLED && ODIN_OS == .Windows", .Unknown, .False},
        {"ODIN_OS == 1", .Unknown, .Unknown},
        {"-1 < 0", .True, .True},
        {"(ODIN_OS == .Linux)", .False, .True},
        {"ODIN_OS == .Linux ? true : false", .Unknown, .Unknown},
    }
    for c in cases {
        got := cond_state(t, c.cond, win)
        testing.expectf(t, got == c.win, "%q on windows: got %v, want %v", c.cond, got, c.win)
        got = cond_state(t, c.cond, lin)
        testing.expectf(t, got == c.lin, "%q on linux: got %v, want %v", c.cond, got, c.lin)
    }

    testing.expect_value(t, cond_state(t, "ODIN_OS == .Windows", Target{}), Tri.Unknown)
    testing.expect_value(t, cond_state(t, "size_of(int) == 8", Target{arch = .wasm64p32}), Tri.True)
    testing.expect_value(t, cond_state(t, "size_of(uintptr) == 4", Target{arch = .wasm64p32}), Tri.True)
}

@(test)
test_when_chains :: proc(t: ^testing.T) {
    src := `package p

when ODIN_OS == .Windows {
    OS :: "windows"
} else when ODIN_OS == .Linux {
    OS :: "linux"
    when ODIN_ARCH == .amd64 {
        WIDE :: true
    } else {
        WIDE :: false
    }
} else {
    OS :: "other"
}

when UNKNOWN_FLAG {
    MAYBE :: 1
} else when ODIN_OS == .Windows {
    MAYBE :: 2
} else {
    MAYBE :: 3
}

when ODIN_OS == .Windows {
    SURE :: 1
} else when UNKNOWN_FLAG {
    SURE :: 2
} else {
    SURE :: 3
}

PLAIN :: 0
`
    tree := when_tree(t, src)
    defer item_tree_destroy(tree)

    State :: struct {
        name:  string,
        index: int, // which declaration of the name
        win:   Tri,
        lin:   Tri,
        mac:   Tri,
    }
    win := Target{os = .Windows, arch = .amd64}
    lin := Target{os = .Linux, arch = .arm64}
    mac := Target{os = .Darwin, arch = .arm64}
    cases := []State {
        {"OS", 0, .True, .False, .False},
        {"OS", 1, .False, .True, .False},
        {"OS", 2, .False, .False, .True},
        {"WIDE", 0, .False, .False, .False},
        {"WIDE", 1, .False, .True, .False},
        {"MAYBE", 0, .Unknown, .Unknown, .Unknown},
        {"MAYBE", 1, .Unknown, .False, .False},
        {"MAYBE", 2, .False, .Unknown, .Unknown},
        {"SURE", 0, .True, .False, .False},
        {"SURE", 1, .False, .Unknown, .Unknown},
        {"SURE", 2, .False, .Unknown, .Unknown},
        {"PLAIN", 0, .True, .True, .True},
    }
    for c in cases {
        seen := 0
        item: ^Item
        for &it in tree.items {
            if it.name != c.name {
                continue
            }
            if seen == c.index {
                item = &it
                break
            }
            seen += 1
        }
        if !testing.expectf(t, item != nil, "%s #%d missing", c.name, c.index) {
            continue
        }
        got := guard_state(tree, item.guard, win)
        testing.expectf(t, got == c.win, "%s #%d on windows: got %v, want %v", c.name, c.index, got, c.win)
        got = guard_state(tree, item.guard, lin)
        testing.expectf(t, got == c.lin, "%s #%d on linux: got %v, want %v", c.name, c.index, got, c.lin)
        got = guard_state(tree, item.guard, mac)
        testing.expectf(t, got == c.mac, "%s #%d on darwin: got %v, want %v", c.name, c.index, got, c.mac)
        testing.expect_value(t, item_active(tree, item, win), c.win != .False)
    }

    // An inactive parent decides its children whatever their own condition says.
    wide := item_named(tree, "WIDE")
    if testing.expect(t, wide != nil) {
        testing.expect_value(t, guard_condition(tree, wide.guard, win), Tri.True)
        testing.expect_value(t, guard_active(tree, wide.guard, win), false)
    }
}

@(test)
test_when_do_body_and_foreign :: proc(t: ^testing.T) {
    src := `package p

when ODIN_OS == .Linux do ONE :: 1

when ODIN_OS == .Windows {
    foreign import lib "system:kernel32.lib"
    @(default_calling_convention = "system")
    foreign lib {
        Sleep :: proc(ms: u32) ---
    }
}
`
    tree := when_tree(t, src)
    defer item_tree_destroy(tree)
    win := Target{os = .Windows, arch = .amd64}
    lin := Target{os = .Linux, arch = .amd64}
    one := item_named(tree, "ONE")
    sleep := item_named(tree, "Sleep")
    lib := item_named(tree, "lib")
    if !testing.expect(t, one != nil && sleep != nil && lib != nil) {
        return
    }
    testing.expect(t, !item_active(tree, one, win))
    testing.expect(t, item_active(tree, one, lin))
    testing.expect(t, item_active(tree, sleep, win))
    testing.expect(t, !item_active(tree, sleep, lin))
    testing.expect(t, !item_active(tree, lib, lin))
}

@(test)
test_when_broken_conditions :: proc(t: ^testing.T) {
    srcs := []string {
        "package p\nwhen ODIN_OS == {\n X :: 1\n}\n",
        "package p\nwhen {\n X :: 1\n}\n",
        "package p\nwhen #config(, ) {\n X :: 1\n}\n",
        "package p\nwhen ODIN_OS in {.Windows, {\n X :: 1\n}\n",
        "package p\nwhen size_of() == 8 {\n X :: 1\n}\n",
        "package p\nwhen !!!!true {\n X :: 1\n}\n",
    }
    for src in srcs {
        tree := when_tree(t, src)
        for g in 0 ..< len(tree.guards) {
            _ = guard_state(tree, g, target_host())
        }
        item_tree_destroy(tree)
    }
}

// Every `when` at file scope of the toolchain's `core:os` and `core:sys` evaluates without a crash,
// and nine in ten of them to a known answer. Runs only when ODIN_ROOT is set.
@(test)
test_when_core_smoke :: proc(t: ^testing.T) {
    root := os.get_env("ODIN_ROOT", context.temp_allocator)
    if root == "" {
        return
    }
    total, known := 0, 0
    for sub in ([]string{"core/os", "core/sys"}) {
        dir, jerr := filepath.join({root, sub}, context.temp_allocator)
        if jerr != nil {
            continue
        }
        smoke_dir(t, dir, &total, &known, 0)
    }
    if total > 0 {
        testing.expectf(t, known * 10 > total * 9, "%d of %d guards known", known, total)
    }
}

@(private = "file")
smoke_dir :: proc(t: ^testing.T, dir: string, total, known: ^int, depth: int) {
    if depth > 6 {
        return
    }
    handle, err := os.open(dir)
    if err != nil {
        return
    }
    defer os.close(handle)
    infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if rerr != nil {
        return
    }
    targets := []Target{{os = .Windows, arch = .amd64}, {os = .Linux, arch = .arm64}, {os = .Darwin, arch = .arm64}}
    for info in infos {
        if info.type == .Directory {
            smoke_dir(t, info.fullpath, total, known, depth + 1)
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        data, ferr := os.read_entire_file(info.fullpath, context.temp_allocator)
        if ferr != nil {
            continue
        }
        tree := when_tree(t, string(data))
        if tree == nil {
            continue
        }
        for g in 0 ..< len(tree.guards) {
            for target in targets {
                total^ += 1
                if guard_state(tree, g, target) != .Unknown {
                    known^ += 1
                }
            }
        }
        item_tree_destroy(tree)
    }
}

// A `when` in a body gives the same answer as one at file scope.
@(test)
test_when_condition_in_body :: proc(t: ^testing.T) {
    src := "package p\n\nf :: proc() {\n    when ODIN_OS == .Windows && !ODIN_DEBUG {\n        x := 1\n    }\n}\n"
    parsed, err := odinsyntax.parse(src)
    testing.expect_value(t, err, nil)
    defer odinsyntax.parse_destroy(&parsed)
    at := strings.index(src, "ODIN_OS")
    n := odinsyntax.node_root(parsed.tree)
    cond: odinsyntax.Syntax_Node
    found := false
    for !found {
        it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
        next_found := false
        for child in odinsyntax.child_iter_next(&it) {
            start, end := odinsyntax.node_range(child)
            if int(start) == at && child.green.kind == .Binary_Expr {
                cond, found = child, true
                break
            }
            if int(start) <= at && at < int(end) {
                n, next_found = child, true
                break
            }
        }
        if !found && !next_found {
            break
        }
    }
    if !testing.expect(t, found, "the condition must be found") {
        return
    }
    testing.expect_value(t, when_condition(cond, Target{os = .Windows}), Tri.True)
    testing.expect_value(t, when_condition(cond, Target{os = .Windows, debug = true}), Tri.False)
    testing.expect_value(t, when_condition(cond, Target{os = .Linux}), Tri.False)
    testing.expect_value(t, tri_and(.True, .Unknown), Tri.Unknown)
    testing.expect_value(t, tri_and(.Unknown, .False), Tri.False)
    testing.expect_value(t, tri_not(.Unknown), Tri.Unknown)
}

// A resolver answers the conditions the evaluator leaves unknown, and only those.
@(test)
test_guard_state_resolver :: proc(t: ^testing.T) {
    tree := when_tree(t, "package p\n\nwhen FLAG {\n    A :: 1\n} else when ODIN_OS == .Linux {\n    B :: 1\n} else {\n    C :: 1\n}\n")
    defer item_tree_destroy(tree)
    answer := Tri.True
    resolver := Guard_Resolver{
        resolve = proc(data: rawptr, tree: ^Item_Tree, guard: int) -> Tri {
            return (cast(^Tri)data)^
        },
        data = &answer,
    }
    target := Target{os = .Linux}
    a, b, c := item_named(tree, "A"), item_named(tree, "B"), item_named(tree, "C")
    if !testing.expect(t, a != nil && b != nil && c != nil) {
        return
    }
    testing.expect_value(t, guard_state(tree, a.guard, target), Tri.Unknown)
    testing.expect_value(t, guard_state(tree, a.guard, target, &resolver), Tri.True)
    testing.expect_value(t, guard_state(tree, b.guard, target, &resolver), Tri.False)
    answer = .False
    testing.expect_value(t, guard_state(tree, b.guard, target, &resolver), Tri.True)
    testing.expect_value(t, guard_state(tree, c.guard, target, &resolver), Tri.False)
}
