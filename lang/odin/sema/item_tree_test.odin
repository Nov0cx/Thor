package odinsema

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
build_tree :: proc(t: ^testing.T, src: string) -> ^Item_Tree {
    parsed, err := odinsyntax.parse(src)
    testing.expect_value(t, err, nil)
    defer odinsyntax.parse_destroy(&parsed)
    tree, terr := item_tree(parsed)
    testing.expect_value(t, terr, nil)
    return tree
}

@(private = "file")
find_item :: proc(tree: ^Item_Tree, name: string) -> (Item, bool) {
    for item in tree.items {
        if item.name == name {
            return item, true
        }
    }
    return {}, false
}

@(test)
test_item_tree_kinds_and_signatures :: proc(t: ^testing.T) {
    src := `package demo

import "core:fmt"
import str "core:strings"

Color :: enum u8 { Red, Green = 2 }
Point :: struct {
    x, y: f32, // position
    using base: Base,
}
Value :: union { int, f64 }
Flags :: bit_set[Color; u8]
Id :: distinct int
Bits :: bit_field u16 { low: u8 | 4 }
Handle :: int
MAX :: 100
counter: int
ready := true

add :: proc(a: int, // left
            b: int) -> int {
    return a + b
}
sizes :: proc{add, sub}
Generic :: struct($T: typeid) where size_of(T) > 0 { items: []T }
`
    tree := build_tree(t, src)
    defer item_tree_destroy(tree)

    testing.expect_value(t, tree.package_name, "demo")
    testing.expect_value(t, tree.package_offset, 8)

    Want :: struct {
        name:      string,
        kind:      Item_Kind,
        signature: string,
    }
    wants := []Want {
        {"fmt", .Import, `import "core:fmt"`},
        {"str", .Import, `import str "core:strings"`},
        {"Color", .Enum, "Color :: enum u8"},
        {"Point", .Struct, "Point :: struct"},
        {"Value", .Union, "Value :: union"},
        {"Flags", .Bit_Set, "Flags :: bit_set[Color; u8]"},
        {"Id", .Type, "Id :: distinct int"},
        {"Bits", .Bit_Field, "Bits :: bit_field u16"},
        {"Handle", .Type, "Handle :: int"},
        {"MAX", .Const, "MAX :: 100"},
        {"counter", .Var, "counter: int"},
        {"ready", .Var, "ready := true"},
        {"add", .Proc, "add :: proc(a: int, b: int) -> int"},
        {"sizes", .Proc_Group, "sizes :: proc{add, sub}"},
        {"Generic", .Struct, "Generic :: struct($T: typeid) where size_of(T) > 0"},
    }
    testing.expect_value(t, len(tree.items), len(wants))
    for want, i in wants {
        if i >= len(tree.items) {
            break
        }
        item := tree.items[i]
        testing.expect_value(t, item.name, want.name)
        testing.expect_value(t, item.kind, want.kind)
        testing.expect_value(t, item.signature, want.signature)
        testing.expect_value(t, item.guard, -1)
        if item.kind != .Import {
            testing.expectf(t, strings.has_prefix(src[item.name_offset:], item.name), "%s: offset %d", item.name, item.name_offset)
        }
    }

    imp, _ := find_item(tree, "str")
    testing.expect_value(t, imp.path, "core:strings")
    testing.expect_value(t, imp.visibility, Visibility.File)

    point, _ := find_item(tree, "Point")
    testing.expect_value(t, len(point.children), 3)
    if len(point.children) == 3 {
        testing.expect_value(t, point.children[0].name, "x")
        testing.expect_value(t, point.children[0].signature, "x, y: f32")
        testing.expect_value(t, point.children[1].name, "y")
        testing.expect_value(t, point.children[1].signature, "y: f32")
        testing.expect_value(t, point.children[2].name, "base")
        testing.expect_value(t, point.children[2].kind, Item_Kind.Field)
    }
    color, _ := find_item(tree, "Color")
    testing.expect_value(t, len(color.children), 2)
    if len(color.children) == 2 {
        testing.expect_value(t, color.children[0].name, "Red")
        testing.expect_value(t, color.children[1].name, "Green")
        testing.expect_value(t, color.children[1].signature, "Green = 2")
        testing.expect_value(t, color.children[1].kind, Item_Kind.Enum_Member)
    }
    bits, _ := find_item(tree, "Bits")
    testing.expect_value(t, len(bits.children), 1)
}

@(test)
test_item_tree_visibility_and_attributes :: proc(t: ^testing.T) {
    src := `#+private
package demo

a :: 1
@(private = "file")
b :: 2
@(require_results, deprecated = "use d")
c :: proc() -> int { return 0 }
`
    tree := build_tree(t, src)
    defer item_tree_destroy(tree)

    testing.expect_value(t, tree.private, Visibility.Package)
    testing.expect_value(t, len(tree.tags), 1)
    a, _ := find_item(tree, "a")
    testing.expect_value(t, a.visibility, Visibility.Package)
    b, _ := find_item(tree, "b")
    testing.expect_value(t, b.visibility, Visibility.File)
    c, _ := find_item(tree, "c")
    testing.expect_value(t, len(c.attributes), 2)
    if len(c.attributes) == 2 {
        testing.expect_value(t, c.attributes[0].name, "require_results")
        testing.expect_value(t, c.attributes[0].value, "")
        testing.expect_value(t, c.attributes[1].name, "deprecated")
        testing.expect_value(t, c.attributes[1].value, `"use d"`)
    }
    testing.expect_value(t, c.start, strings.index(src, "@(require"))

    file_src := "#+private file\npackage demo\n\n@(private)\nx :: 1\ny :: 2\n"
    file_tree := build_tree(t, file_src)
    defer item_tree_destroy(file_tree)
    testing.expect_value(t, file_tree.private, Visibility.File)
    x, _ := find_item(file_tree, "x")
    testing.expect_value(t, x.visibility, Visibility.Package)
    y, _ := find_item(file_tree, "y")
    testing.expect_value(t, y.visibility, Visibility.File)
}

@(test)
test_item_tree_when_and_foreign :: proc(t: ^testing.T) {
    src := `package demo

foreign import libc "system:c"

@(private)
foreign libc {
    puts :: proc(s: cstring) -> i32 ---
    errno: i32
}

when ODIN_OS == .Windows {
    OS :: "windows"
} else when ODIN_OS == .Linux {
    OS :: "linux"
    when ODIN_ARCH == .amd64 do WIDE :: true
} else {
    OS :: "other"
}
`
    tree := build_tree(t, src)
    defer item_tree_destroy(tree)

    libc, _ := find_item(tree, "libc")
    testing.expect_value(t, libc.kind, Item_Kind.Foreign_Import)
    testing.expect_value(t, libc.path, "system:c")

    puts, _ := find_item(tree, "puts")
    testing.expect_value(t, puts.kind, Item_Kind.Proc)
    testing.expect(t, puts.in_foreign)
    testing.expect_value(t, puts.visibility, Visibility.Package)
    testing.expect_value(t, puts.signature, "puts :: proc(s: cstring) -> i32")
    errno, _ := find_item(tree, "errno")
    testing.expect_value(t, errno.kind, Item_Kind.Var)
    testing.expect(t, errno.in_foreign)

    testing.expect_value(t, len(tree.guards), 4)
    os_items := make([dynamic]Item, context.temp_allocator)
    for item in tree.items {
        if item.name == "OS" {
            append(&os_items, item)
        }
    }
    testing.expect_value(t, len(os_items), 3)
    if len(os_items) == 3 && len(tree.guards) == 4 {
        g0 := tree.guards[os_items[0].guard]
        testing.expect_value(t, g0.cond, "ODIN_OS == .Windows")
        testing.expect_value(t, g0.previous, -1)
        g1 := tree.guards[os_items[1].guard]
        testing.expect_value(t, g1.cond, "ODIN_OS == .Linux")
        testing.expect_value(t, g1.previous, os_items[0].guard)
        g2 := tree.guards[os_items[2].guard]
        testing.expect_value(t, g2.cond, "")
        testing.expect_value(t, g2.previous, os_items[1].guard)
    }
    wide, ok := find_item(tree, "WIDE")
    testing.expect(t, ok)
    if ok {
        g := tree.guards[wide.guard]
        testing.expect_value(t, g.cond, "ODIN_ARCH == .amd64")
        testing.expect_value(t, g.parent, os_items[1].guard if len(os_items) == 3 else -2)
    }
}

@(test)
test_item_tree_legacy_tags_and_broken_source :: proc(t: ^testing.T) {
    tree := build_tree(t, "//+build linux\n//+private\npackage demo\n\nx :: proc(\n")
    defer item_tree_destroy(tree)
    testing.expect_value(t, len(tree.tags), 2)
    if len(tree.tags) == 2 {
        testing.expect_value(t, tree.tags[0], "#+build linux")
        testing.expect_value(t, tree.tags[1], "#+private")
    }
    testing.expect_value(t, tree.private, Visibility.Package)

    empty := build_tree(t, "")
    defer item_tree_destroy(empty)
    testing.expect_value(t, len(empty.items), 0)
    testing.expect_value(t, empty.package_offset, -1)
}

// Every .odin file of the repository gives an item tree. Run from the repository root.
@(test)
test_item_tree_repository :: proc(t: ^testing.T) {
    count := 0
    walk_repository(t, ".", &count)
    testing.expectf(t, count > 100, "only %d files were read", count)
}

@(private = "file")
walk_repository :: proc(t: ^testing.T, dir: string, count: ^int) {
    handle, err := os.open(dir)
    if err != nil {
        return
    }
    defer os.close(handle)
    infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if rerr != nil {
        return
    }
    for info in infos {
        path, jerr := filepath.join({dir, info.name}, context.temp_allocator)
        if jerr != nil {
            continue
        }
        if info.type == .Directory {
            if strings.has_prefix(info.name, ".") || (dir == "." && (info.name == "vendor" || info.name == "bin")) {
                continue
            }
            walk_repository(t, path, count)
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        data, derr := os.read_entire_file(path, context.temp_allocator)
        if derr != nil {
            continue
        }
        parsed, perr := odinsyntax.parse(string(data))
        if perr != nil {
            testing.expectf(t, false, "%s: parse failed", path)
            continue
        }
        tree, terr := item_tree(parsed)
        odinsyntax.parse_destroy(&parsed)
        testing.expectf(t, terr == nil, "%s: item tree failed", path)
        if terr == nil {
            testing.expectf(t, tree.package_name != "", "%s: no package name", path)
            item_tree_destroy(tree)
        }
        count^ += 1
    }
}
