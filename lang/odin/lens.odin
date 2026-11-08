// Code lens: the reference count of each file-scope declaration of the buffer.
package odin

import lang ".."
import odinsema "sema"

// Fills `res.lenses` with one row per file-scope declaration, in source order. A count is the
// number of identifiers that name the declaration, the declaration excluded.
@(private)
code_lens :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    dir := live_dir(&ctx)
    items := make([dynamic]^odinsema.Item, context.temp_allocator)
    targets := make([dynamic]Ref_Target, context.temp_allocator)
    for &item in ctx.live.tree.items {
        #partial switch item.kind {
        case .Import, .Foreign_Import, .Field, .Enum_Member:
            continue
        }
        if item.name == "_" || item.name == "" {
            continue
        }
        append(&items, &item)
        append(&targets, Ref_Target {
            kind       = .Package_Item,
            name       = item.name,
            path       = req.path,
            decl       = item.name_offset,
            dir        = dir,
            visibility = item.visibility,
        })
    }
    counts := make([]int, len(targets), context.temp_allocator)
    if !count_references(&ctx, targets[:], counts) {
        return
    }
    for item, i in items {
        if _, err := append(&res.lenses, lang.Code_Lens_Item{start = item.name_offset, end = item.name_offset + len(item.name), count = counts[i]}); err != nil {
            return
        }
    }
    res.ok = len(res.lenses) > 0
}
