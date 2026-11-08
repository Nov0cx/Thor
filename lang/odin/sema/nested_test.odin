package odinsema

import "core:mem/virtual"
import "core:testing"

import odinsyntax "../syntax"

@(test)
test_nested_decls :: proc(t: ^testing.T) {
    src := `package demo

outer :: proc() {
    Local :: struct { a: int, b: f32 }
    N :: 4
    count := 0
    inner :: proc() -> int {
        deepest :: #force_inline proc() {}
        if true {
            Kind :: enum { One, Two }
        }
        return 1
    }
    sort(proc() {
        Hidden :: union { int }
    })
    after :: proc() {}
}

other :: proc() {}
`
    parsed, err := odinsyntax.parse(src)
    testing.expect_value(t, err, nil)
    defer odinsyntax.parse_destroy(&parsed)
    tree, terr := item_tree(parsed)
    testing.expect_value(t, terr, nil)
    defer item_tree_destroy(tree)
    testing.expect_value(t, len(tree.items), 2)
    if len(tree.items) != 2 {
        return
    }

    arena: virtual.Arena
    testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
    defer virtual.arena_destroy(&arena)
    alloc := virtual.arena_allocator(&arena)

    decls, derr := nested_decls(parsed, &tree.items[0], alloc)
    testing.expect_value(t, derr, nil)
    Want :: struct {
        name:   string,
        kind:   Item_Kind,
        parent: int,
    }
    want := []Want {
        {"Local", .Struct, -1},
        {"inner", .Proc, -1},
        {"deepest", .Proc, 1},
        {"Kind", .Enum, 1},
        {"Hidden", .Union, -1},
        {"after", .Proc, -1},
    }
    testing.expect_value(t, len(decls), len(want))
    for w, i in want {
        if i >= len(decls) {
            break
        }
        d := decls[i]
        testing.expect_value(t, d.item.name, w.name)
        testing.expect_value(t, d.item.kind, w.kind)
        testing.expect_value(t, d.parent, w.parent)
        testing.expect_value(t, src[d.item.name_offset:][:len(w.name)], w.name)
    }
    if len(decls) == len(want) {
        testing.expect_value(t, decls[0].item.signature, "Local :: struct")
        testing.expect_value(t, len(decls[0].item.children), 2)
        testing.expect_value(t, decls[1].item.signature, "inner :: proc() -> int")
        testing.expect_value(t, decls[2].item.signature, "deepest :: #force_inline proc()")
    }

    none, nerr := nested_decls(parsed, &tree.items[1], alloc)
    testing.expect_value(t, nerr, nil)
    testing.expect_value(t, len(none), 0)
}
