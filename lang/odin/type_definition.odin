// Go to type definition: the declaration of the type of the name or expression under the caret.
package odin

import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"

// Deepest a type is walked through its element, key and result types.
@(private = "file")
TYPE_WALK_DEPTH :: 8

// A type the walk found: a declared type by its symbol, or a basic type by its name.
@(private)
Type_Found :: struct {
    symbol:  odinsema.Symbol,
    name:    string,
    builtin: bool,
}

// A place to jump to. Strings are temp-allocated.
@(private)
Type_Jump :: struct {
    path:      string,
    name:      string,
    kind:      string,
    signature: string,
    start:     int,
    end:       int,
    line:      int,
}

// Fills `res` with the declaration of the type at req.offset: res.location for one, res.symbols for several.
@(private)
type_definition :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    c := request_checker(&ctx)
    if c == nil {
        return
    }
    type := caret_type(&ctx, c)
    if type == odinsema.INVALID_TYPE {
        return
    }
    found := make([dynamic]Type_Found, context.temp_allocator)
    collect_type_symbols(c, type, &found, 0)
    declared := false
    for f in found {
        if !f.builtin {
            declared = true
            break
        }
    }
    jumps := make([dynamic]Type_Jump, context.temp_allocator)
    for f in found {
        if lang.request_cancelled(req) {
            return
        }
        if f.builtin {
            if !declared {
                builtin_jumps(&ctx, f.name, &jumps)
            }
            continue
        }
        if j, ok := symbol_jump(&ctx, c, f); ok {
            append(&jumps, j)
        }
    }
    if lang.request_cancelled(req) {
        return
    }
    switch len(jumps) {
    case 0:
        return
    case 1:
        j := jumps[0]
        res.location = lang.Location{path = strings.clone(j.path), start = j.start, end = j.end}
    case:
        for j in jumps {
            append(&res.symbols, lang.Symbol {
                name      = strings.clone(j.name),
                kind      = strings.clone(j.kind),
                signature = strings.clone(j.signature),
                path      = strings.clone(j.path),
                line      = j.line,
                offset    = j.start,
            })
        }
    }
    res.ok = true
}

// The type of the expression at req.offset, else the declared type of the name there.
@(private = "file")
caret_type :: proc(ctx: ^Request_Context, c: ^odinsema.Checker) -> odinsema.Type_Id {
    if n, ok := odinsema.expr_under(c, ctx.live.id, ctx.req.offset); ok {
        op := odinsema.expr_type(c, ctx.live.id, n)
        #partial switch op.mode {
        case .Type, .Value, .Const:
            if op.type != odinsema.INVALID_TYPE {
                return op.type
            }
        }
    }
    t := ref_target(ctx)
    sym: odinsema.Symbol
    #partial switch t.kind {
    case .Local:
        if t.decl < 0 {
            return odinsema.INVALID_TYPE
        }
        sym = odinsema.local_symbol(ctx.live.id, t.decl)
    case .Param:
        sym = t.symbol
    case .Package_Item, .Builtin, .Member:
        if t.typed {
            sym = t.symbol
        } else if s, ok := decl_symbol(ctx, t.path, t.decl); ok {
            sym = s
        } else {
            return odinsema.INVALID_TYPE
        }
    case:
        return odinsema.INVALID_TYPE
    }
    return odinsema.decl_type(c, sym)
}

// Appends the declared types `type` is built from: itself when it is declared, else its element,
// key, value or result types. A basic type is appended by name.
@(private)
collect_type_symbols :: proc(c: ^odinsema.Checker, type: odinsema.Type_Id, out: ^[dynamic]Type_Found, depth: int) {
    if type == odinsema.INVALID_TYPE || depth > TYPE_WALK_DEPTH {
        return
    }
    switch t in odinsema.type_get(&c.table, type) {
    case odinsema.Named_Type:
        add_found(out, Type_Found{symbol = t.symbol, name = t.name})
    case odinsema.Distinct_Type:
        add_found(out, Type_Found{symbol = t.symbol, name = odinsema.type_string(&c.table, type, context.temp_allocator)})
    case odinsema.Poly_Param_Type:
        add_found(out, Type_Found{symbol = t.symbol, name = t.name})
    case odinsema.Basic_Type:
        add_found(out, Type_Found{name = odinsema.type_string(&c.table, type, context.temp_allocator), builtin = true})
    case odinsema.Pointer_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
    case odinsema.Multi_Pointer_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
    case odinsema.Slice_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
    case odinsema.Array_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
    case odinsema.Enumerated_Array_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
        collect_type_symbols(c, t.index, out, depth + 1)
    case odinsema.Dynamic_Array_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
    case odinsema.Map_Type:
        collect_type_symbols(c, t.key, out, depth + 1)
        collect_type_symbols(c, t.value, out, depth + 1)
    case odinsema.Bit_Set_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
    case odinsema.Matrix_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
    case odinsema.Simd_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
    case odinsema.Soa_Type:
        collect_type_symbols(c, t.elem, out, depth + 1)
    case odinsema.Tuple_Type:
        for elem in t.types {
            collect_type_symbols(c, elem, out, depth + 1)
        }
    case odinsema.Proc_Type:
        for r in t.results {
            collect_type_symbols(c, r.type, out, depth + 1)
        }
    case odinsema.Untyped_Type, odinsema.Bit_Field_Type, odinsema.Struct_Type, odinsema.Union_Type, odinsema.Enum_Type, odinsema.Proc_Group_Type:
    }
}

@(private = "file")
add_found :: proc(out: ^[dynamic]Type_Found, f: Type_Found) {
    for g in out {
        if g.builtin == f.builtin && (f.builtin ? g.name == f.name : g.symbol == f.symbol) {
            return
        }
    }
    append(out, f)
}

// The jump to the declaration of the declared type `f`.
@(private)
symbol_jump :: proc(ctx: ^Request_Context, c: ^odinsema.Checker, f: Type_Found) -> (Type_Jump, bool) {
    file, start, end, ok := odinsema.symbol_range(c, f.symbol)
    if !ok {
        return {}, false
    }
    j := Type_Jump {
        path  = strings.clone(snapshot_path(ctx, file), context.temp_allocator),
        name  = strings.clone(f.name, context.temp_allocator),
        kind  = "type",
        start = start,
        end   = end,
    }
    lines := file == ctx.live.id ? ctx.live.lines : nil
    if data := odinsema.db_file(&ctx.snap, file); data != nil {
        if lines == nil {
            lines = data.lines
        }
        sym := f.symbol
        if sym.item != odinsema.LOCAL_ITEM && int(sym.item) < len(data.tree.items) {
            item := &data.tree.items[sym.item]
            if sym.child >= 0 && int(sym.child) < len(item.children) {
                item = &item.children[sym.child]
            }
            j.name = strings.clone(item.name, context.temp_allocator)
            j.kind = symbol_kind(item.kind)
            j.signature = strings.clone(item.signature, context.temp_allocator)
        }
    }
    if len(lines) > 0 {
        j.line, _ = offset_line_col(lines, start)
    }
    return j, true
}

// Appends the declaration of the basic type `name` in the builtin packages, the active one first.
@(private = "file")
builtin_jumps :: proc(ctx: ^Request_Context, name: string, out: ^[dynamic]Type_Jump) {
    cands := make([dynamic]Def_Candidate, context.temp_allocator)
    builtin_candidates(ctx, name, &cands)
    if len(cands) == 0 {
        return
    }
    slice.sort_by(cands[:], proc(a, b: Def_Candidate) -> bool {
        return !a.inactive && b.inactive
    })
    cand := cands[0]
    append(out, Type_Jump {
        path      = cand.path,
        name      = cand.name,
        kind      = symbol_kind(cand.kind),
        signature = cand.signature,
        start     = cand.offset,
        end       = cand.offset + len(cand.name),
        line      = cand.line,
    })
}
