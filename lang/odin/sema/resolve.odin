package odinsema

import "core:mem"

import odinsyntax "../syntax"

// What the identifier at `offset`, or the one that ends at `offset`, names lexically.
// The strings of the result borrow the text of `parsed`.
resolve_at :: proc(parsed: odinsyntax.Parse, offset: int, allocator := context.allocator) -> (ref: Name_Ref, err: mem.Allocator_Error) {
    ref = Name_Ref{decl = -1, operand_start = -1, operand_end = -1}
    m := scope_map_range(parsed, offset, offset, allocator) or_return
    defer scope_map_destroy(m, allocator)
    if found, ok := ref_at(m, offset); ok {
        ref = found
    }
    return ref, nil
}

// The reference of `m` at `offset`: the identifier that holds it, else the one that ends there.
ref_at :: proc(m: ^Scope_Map, offset: int) -> (Name_Ref, bool) {
    touching := -1
    for r, i in m.refs {
        if r.start <= offset && offset < r.end {
            return r, true
        }
        if r.end == offset {
            touching = i
        }
    }
    if touching < 0 {
        return {}, false
    }
    return m.refs[touching], true
}
