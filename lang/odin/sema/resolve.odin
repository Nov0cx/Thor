package odinsema

import "core:mem"
import "core:slice"

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

// The offsets, in order, of every identifier that names the local declared at `decl_offset`, the
// declaration's own name included. Empty when `decl_offset` is not the name of a local.
local_references :: proc(parsed: odinsyntax.Parse, decl_offset: int, allocator := context.allocator) -> (offsets: []int, err: mem.Allocator_Error) {
    m := scope_map_range(parsed, decl_offset, decl_offset, allocator) or_return
    defer scope_map_destroy(m, allocator)
    count := 0
    for r in m.refs {
        if r.kind == .Local && r.decl == decl_offset {
            count += 1
        }
    }
    offsets = make([]int, count, allocator) or_return
    i := 0
    for r in m.refs {
        if r.kind == .Local && r.decl == decl_offset {
            offsets[i] = r.start
            i += 1
        }
    }
    slice.sort(offsets)
    return offsets, nil
}
