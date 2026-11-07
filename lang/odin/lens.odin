// Code lens: the reference count of each file-scope declaration of the buffer.
package odin

import lang ".."
import odinsema "sema"

@(private = "file")
Count_Scan :: struct {
    count: int,
}

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
    for &item in ctx.live.tree.items {
        #partial switch item.kind {
        case .Import, .Foreign_Import, .Field, .Enum_Member:
            continue
        }
        if item.name == "_" || item.name == "" {
            continue
        }
        target := Ref_Target {
            kind       = .Package_Item,
            name       = item.name,
            path       = req.path,
            decl       = item.name_offset,
            dir        = dir,
            visibility = item.visibility,
        }
        scan: Count_Scan
        if !visit_references(&ctx, target, false, count_visit, &scan) {
            if lang.request_cancelled(req) {
                return
            }
            continue
        }
        if _, err := append(&res.lenses, lang.Code_Lens_Item{start = item.name_offset, end = item.name_offset + len(item.name), count = scan.count}); err != nil {
            return
        }
    }
    res.ok = len(res.lenses) > 0
}

@(private = "file")
count_visit :: proc(data: rawptr, f: Ref_File) -> bool {
    (cast(^Count_Scan)data).count += len(f.hits)
    return true
}
