package odinsema

import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
shape_of :: proc(t: ^testing.T, src: string) -> u64 {
    parsed, err := odinsyntax.parse(src)
    if !testing.expect_value(t, err, nil) {
        return 0
    }
    defer odinsyntax.parse_destroy(&parsed)
    tree, terr := item_tree(parsed)
    if !testing.expect_value(t, terr, nil) {
        return 0
    }
    defer item_tree_destroy(tree)
    return item_tree_shape_hash(tree)
}

@(private = "file")
SHAPE_BASE :: `package demo

import "core:fmt"

// Adds two numbers.
add :: proc(a, b: int) -> int {
    return a + b
}

when ODIN_OS == .Windows {
    Handle :: distinct uintptr
}

Point :: struct { x, y: f32 }
`

@(test)
test_shape_hash_ignores_bodies_offsets_and_docs :: proc(t: ^testing.T) {
    base := shape_of(t, SHAPE_BASE)
    same := []string {
        // A body edit.
        `package demo

import "core:fmt"

// Adds two numbers.
add :: proc(a, b: int) -> int {
    fmt.println(a)
    return b + a
}

when ODIN_OS == .Windows {
    Handle :: distinct uintptr
}

Point :: struct { x, y: f32 }
`,
        // Blank lines move every offset.
        `package demo


import "core:fmt"

// Adds two numbers.

add :: proc(a, b: int) -> int {
    return a + b
}


when ODIN_OS == .Windows {
    Handle :: distinct uintptr
}

Point :: struct { x, y: f32 }
`,
        // Another doc comment.
        `package demo

import "core:fmt"

// Gives the sum.
add :: proc(a, b: int) -> int {
    return a + b
}

when ODIN_OS == .Windows {
    Handle :: distinct uintptr
}

Point :: struct { x, y: f32 }
`,
    }
    for src, i in same {
        testing.expectf(t, shape_of(t, src) == base, "case %d must keep the shape", i)
    }
}

@(test)
test_shape_hash_sees_declarations :: proc(t: ^testing.T) {
    base := shape_of(t, SHAPE_BASE)
    changed := []string {
        // A signature.
        `package demo

import "core:fmt"

add :: proc(a, b: int, c: int) -> int {
    return a + b
}

when ODIN_OS == .Windows {
    Handle :: distinct uintptr
}

Point :: struct { x, y: f32 }
`,
        // A guard.
        `package demo

import "core:fmt"

add :: proc(a, b: int) -> int {
    return a + b
}

when ODIN_OS == .Linux {
    Handle :: distinct uintptr
}

Point :: struct { x, y: f32 }
`,
        // A field.
        `package demo

import "core:fmt"

add :: proc(a, b: int) -> int {
    return a + b
}

when ODIN_OS == .Windows {
    Handle :: distinct uintptr
}

Point :: struct { x, y, z: f32 }
`,
        // A new declaration.
        `package demo

import "core:fmt"

add :: proc(a, b: int) -> int {
    return a + b
}

when ODIN_OS == .Windows {
    Handle :: distinct uintptr
}

Point :: struct { x, y: f32 }
ORIGIN :: Point{}
`,
        // The order of two declarations.
        `package demo

import "core:fmt"

Point :: struct { x, y: f32 }

add :: proc(a, b: int) -> int {
    return a + b
}

when ODIN_OS == .Windows {
    Handle :: distinct uintptr
}
`,
        // A file tag.
        `#+private
package demo

import "core:fmt"

add :: proc(a, b: int) -> int {
    return a + b
}

when ODIN_OS == .Windows {
    Handle :: distinct uintptr
}

Point :: struct { x, y: f32 }
`,
    }
    for src, i in changed {
        testing.expectf(t, shape_of(t, src) != base, "case %d must change the shape", i)
    }
}
