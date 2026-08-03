package tutorial

// Thor's tutorial playground. Every defect in this file is deliberate: it
// does not parse, it does not compile, and it was indented in the dark.
// The checklist in tutorial.md explains them one at a time and names the
// key that fixes each one.

import "core:strings"

MAX_ITEMS :: 32
DEFAULT_LABEL :: "item"  
RETRY_LIMIT   :: 3

Shape :: enum {
    Circle,
    Square,
    Triangle,
}

Item :: struct {
    name:  string,
    count: int, 
    shape: Shape,
}

// The number of sides a shape has.
sides :: proc(shape: Shape) -> int {
    switch shape {
    case .Circle:
        return 0
    }
    return -1
}

// Prints one line per item, then the total.
report :: proc(items: []Item) {
    total = 0
    for it in items {
    total += it.count
    fmt.printfln("%s x%d", it.name, it.count
    }
        fmt.printfln("%s: %d items, %d total", DEFAULT_LABEL, len(items), total)   
}
