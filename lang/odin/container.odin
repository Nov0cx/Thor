// The two members an array offers itself, which no struct lookup can answer
// because a container is not the type it holds.
//
// A fixed array of up to four components swizzles: `v: [4]f32` reads `v.x` as an
// f32 and `v.xy` as a `[2]f32`, over the `xyzw` and `rgba` component sets. A
// swizzle declares nothing, so it has a type but no definition to jump to.
//
// An `#soa` array holds one array per field of its element struct, so
// `s: #soa[]Point` reads `s.x` as a `[]f32` — the element's field, wrapped back
// in the array that holds it. That one *does* name a declaration: the field of
// the element struct, which is where go-to-definition lands.
package odin

import "core:strings"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// Component sets a swizzle names, index by position: `.z` is component 2 in
// both, and no swizzle mixes the two.
@(private)
SWIZZLE_SETS :: [?]string{"xyzw", "rgba"}

// Longest swizzle Odin accepts, which is also the longest array it swizzles.
@(private)
SWIZZLE_LIMIT :: 4

// Type of `v.field` when `v` is a swizzlable fixed array: one component reads as
// the element type, several as a fixed array of it. Fails unless every component
// comes from one set and indexes inside the array.
@(private)
swizzle_type :: proc(tr: Type_Ref, field: string) -> (Type_Ref, bool) {
    layer, ok := outer_container(tr)
    if !ok || layer.kind != .Array || layer.soa {
        return {}, false
    }
    if layer.length <= 0 || layer.length > SWIZZLE_LIMIT {
        return {}, false
    }
    if len(field) == 0 || len(field) > SWIZZLE_LIMIT || !swizzle_in_set(field, layer.length) {
        return {}, false
    }
    elem, _, _ := unwrap_container(tr)
    if len(field) == 1 {
        return elem, true
    }
    return wrap_container(elem, Container_Layer{kind = .Array, length = len(field)})
}

// Whether every byte of `field` names a component of one set, inside `length`.
@(private = "file")
swizzle_in_set :: proc(field: string, length: int) -> bool {
    for set in SWIZZLE_SETS {
        ok := true
        for i in 0 ..< len(field) {
            if idx := strings.index_byte(set, field[i]); idx < 0 || idx >= length {
                ok = false
                break
            }
        }
        if ok {
            return true
        }
    }
    return false
}

// The array an `#soa` array's per-field arrays are: the same shape, minus the
// tag that made it hold structs field-wise.
@(private = "file")
soa_held_layer :: proc(layer: Container_Layer) -> Container_Layer {
    out := layer
    out.soa = false
    return out
}

// Locates the `#soa` element struct's `field` and fills `ctx` with it, reporting
// the array the field is held in. Fails when the operand is not an `#soa` array
// or its element declares no such field.
@(private = "file")
soa_member :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    tr: Type_Ref,
    field: string,
    ctx: ^Member_Ctx,
) -> (Container_Layer, bool) {
    layer, ok := outer_container(tr)
    if !ok || !layer.soa {
        return {}, false
    }
    elem, _, _ := unwrap_container(tr)
    ctx^ = Member_Ctx {
        field = field,
        env = Embed_Env{e = e, parser = parser, root = root, req = req},
    }
    if !visit_type_decl(e, parser, root, req, elem, "struct_declaration", "type", member_visitor, ctx) || !ctx.got {
        return {}, false
    }
    return soa_held_layer(layer), true
}

// Type of `operand.field` when the operand is a container — the chaining half of
// resolve_container_member, for `v.xy.x` and `s.x[0]`.
@(private)
container_member_type :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    tr: Type_Ref,
    field: string,
) -> (Type_Ref, bool) {
    if st, ok := swizzle_type(tr, field); ok {
        return st, true
    }
    ctx: Member_Ctx
    layer, ok := soa_member(e, parser, root, req, tr, field, &ctx)
    if !ok {
        return {}, false
    }
    return wrap_container(ctx.field_type, layer)
}

// resolve_member for a container operand: fills the go-to-definition location or
// the hover text, and reports whether it answered. A swizzle has no declaration,
// so it answers hover alone and lets go-to-definition fall through.
@(private)
resolve_container_member :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    tr: Type_Ref,
    field: string,
    hover_start, hover_end: int,
    res: ^lang.Result,
) -> bool {
    if st, ok := swizzle_type(tr, field); ok {
        if req.kind != .Hover {
            return false
        }
        res.hover = lang.Hover_Info {
            text  = member_type_text(field, st),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
        return true
    }

    ctx: Member_Ctx
    layer, ok := soa_member(e, parser, root, req, tr, field, &ctx)
    if !ok {
        return false
    }
    #partial switch req.kind {
    case .Definition:
        res.location = lang.Location {
            path  = strings.clone(ctx.path),
            start = ctx.ident_start,
            end   = ctx.ident_end,
        }
        res.ok = true
    case .Hover:
        // Not the type written in the struct: the field is held one array per
        // field, so `x: f32` of a `#soa[]Point` reads as `[]f32` here.
        held, hok := wrap_container(ctx.field_type, layer)
        if !hok {
            return false
        }
        res.hover = lang.Hover_Info {
            text  = member_type_text(field, held),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
    return res.ok
}

// A `name: type` hover line for a member that has no declaration to quote.
// Cloned into context.allocator, like every other hover text.
@(private = "file")
member_type_text :: proc(field: string, tr: Type_Ref) -> string {
    return strings.concatenate({field, ": ", type_ref_text(tr)})
}

// Completion candidates a container operand offers. An `#soa` array offers its
// element struct's fields — under their own declarations, which name the field's
// element type rather than the array it is held in — and a swizzlable array its
// single components. Multi-component swizzles are not offered: there are hundreds
// and none is likelier than the next.
@(private)
complete_container_members :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    tr: Type_Ref,
    prefix: string,
    res: ^lang.Result,
    seen: ^map[string]bool,
) {
    layer, ok := outer_container(tr)
    if !ok || layer.kind != .Array {
        return
    }
    if layer.soa {
        elem, _, _ := unwrap_container(tr)
        ctx := Fields_Ctx {
            prefix = prefix,
            env    = Embed_Env{e = e, parser = parser, root = root, req = req},
            res    = res,
            seen   = seen,
        }
        visit_type_decl(e, parser, root, req, elem, "struct_declaration", "type", fields_visitor, &ctx)
        return
    }
    if layer.length <= 0 || layer.length > SWIZZLE_LIMIT {
        return
    }
    elem, _, _ := unwrap_container(tr)
    elem_text := type_ref_text(elem)
    for set in SWIZZLE_SETS {
        for i in 0 ..< layer.length {
            name := set[i:i + 1]
            if !completion_matches(name, prefix) || name in seen^ {
                continue
            }
            seen^[name] = true
            append(&res.symbols, lang.Symbol {
                name      = strings.clone(name),
                kind      = strings.clone("field"),
                signature = strings.concatenate({name, ": ", elem_text}),
            })
        }
    }
}
