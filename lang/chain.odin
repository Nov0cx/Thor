package lang

import "core:slice"
import "core:strings"

// One producer of answers for a request: a backend, or a server a backend hosts.
Link :: struct {
    id:      string, // written into `origin`; see Request.backend
    data:    rawptr,
    resolve: proc(data: rawptr, req: ^Request, res: ^Result),
}

// Runs a job's backend chain on a worker. Owned output uses the Manager's
// allocator (set by job_run).
@(private)
job_resolve :: proc(job: ^Job) {
    links := make([]Link, job.chain_len, context.temp_allocator)
    for b, i in job.chain[:job.chain_len] {
        links[i] = Link{id = backend_id(b), data = b.data, resolve = b.resolve}
    }
    resolve_links(links, &job.request, &job.result)
}

// Visits `links` in order. A merge kind combines every answer; any other kind keeps
// the first link that answers. `res` carries the id, kind and revision to keep.
// Call it with context.allocator set to the Manager's.
resolve_links :: proc(links: []Link, req: ^Request, res: ^Result) {
    if len(links) == 1 {
        links[0].resolve(links[0].data, req, res)
        result_stamp_origin(res, links[0].id)
        return
    }

    head := res^
    merging := req.kind in MERGE_KINDS
    fallback: Result
    have_fallback := false
    answered := false
    for link in links {
        if request_cancelled(req) {
            break
        }
        part := Result {
            id       = head.id,
            kind     = head.kind,
            revision = head.revision,
        }
        link.resolve(link.data, req, &part)
        if !part.ok {
            // Keeps the first refusal whole: a reason in `message` belongs to it.
            if have_fallback {
                result_release(&part)
            } else {
                fallback, have_fallback = part, true
            }
            continue
        }
        result_stamp_origin(&part, link.id)
        if merging && answered {
            result_merge(res, &part, req.kind)
            continue
        }
        res^ = part
        answered = true
        if !merging {
            break
        }
    }
    if answered {
        if have_fallback {
            result_release(&fallback)
        }
        return
    }
    if have_fallback {
        res^ = fallback
    }
}

// Every gate id the registered backends list, in registration order.
manager_gate_ids :: proc(m: ^Manager, allocator := context.temp_allocator) -> []string {
    out := make([dynamic]string, allocator)
    for b in m.backends {
        if b.gate_ids == nil {
            continue
        }
        append(&out, ..b.gate_ids(b.data, allocator))
    }
    return out[:]
}

// Pushes one gate to the backend that lists `id`. False when none does.
manager_set_gate :: proc(m: ^Manager, id: string, enabled: bool, features: bit_set[Request_Kind]) -> bool {
    for b in m.backends {
        if b.set_gate != nil && b.set_gate(b.data, id, enabled, features) {
            return true
        }
    }
    return false
}

// The gate `id` starts at. Fully on when no backend lists it.
manager_gate_defaults :: proc(m: ^Manager, id: string) -> (enabled: bool, features: bit_set[Request_Kind]) {
    for b in m.backends {
        if b.gate_defaults == nil {
            continue
        }
        if e, f, ok := b.gate_defaults(b.data, id); ok {
            return e, f
        }
    }
    return true, FEATURES_ALL
}

// The Settings row title of gate `id`, "" when no backend labels it.
manager_gate_label :: proc(m: ^Manager, id: string) -> string {
    for b in m.backends {
        if b.gate_label != nil {
            if label := b.gate_label(b.data, id); label != "" {
                return label
            }
        }
    }
    return ""
}

// Sets `origin` on every offer of `res` that no backend named yet. Clones into the
// Manager's allocator, which is the context here.
result_stamp_origin :: proc(res: ^Result, id: string) {
    for &item in res.completions {
        if item.origin == "" {
            item.origin = strings.clone(id)
        }
    }
    for &action in res.actions {
        if action.origin == "" {
            action.origin = strings.clone(id)
        }
    }
}

// Moves what `src` holds into `dst` and frees `src`. Lists the editor walks in one
// forward pass are sorted again, and an item both backends report appears once.
result_merge :: proc(dst, src: ^Result, kind: Request_Kind) {
    #partial switch kind {
    case .Completion:
        move_all(&dst.completions, &src.completions)
        dst.incomplete = dst.incomplete || src.incomplete
    case .Code_Actions:
        move_all(&dst.actions, &src.actions)
    case .Document_Symbols, .Workspace_Symbols:
        move_all(&dst.symbols, &src.symbols)
    case .References, .Implementations:
        move_all(&dst.symbols, &src.symbols)
        dedup_symbols(&dst.symbols)
    case .Inlay_Hints:
        move_all(&dst.inlays, &src.inlays)
        slice.stable_sort_by(dst.inlays[:], proc(a, b: Inlay_Hint) -> bool {return a.offset < b.offset})
        dedup_inlays(&dst.inlays)
    case .Code_Lens:
        move_all(&dst.lenses, &src.lenses)
        slice.stable_sort_by(dst.lenses[:], proc(a, b: Code_Lens_Item) -> bool {return a.start < b.start})
        dedup_by(&dst.lenses, proc(a, b: Code_Lens_Item) -> bool {return a.start == b.start && a.end == b.end})
    case .Document_Highlight:
        move_all(&dst.highlights, &src.highlights)
        slice.stable_sort_by(dst.highlights[:], proc(a, b: Document_Highlight) -> bool {return a.start < b.start})
        dedup_by(&dst.highlights, proc(a, b: Document_Highlight) -> bool {return a.start == b.start && a.end == b.end})
    }
    dst.ok = true
    result_release(src)
}

// Appends `src` to `dst` and empties `src`, so freeing it releases no moved item.
@(private = "file")
move_all :: proc(dst, src: ^[dynamic]$T) {
    append(dst, ..src[:])
    delete(src^)
    src^ = nil
}

// Drops a later element equal to an earlier one, for lists sorted so equals are adjacent.
@(private = "file")
dedup_by :: proc(list: ^[dynamic]$T, same: proc(a, b: T) -> bool) {
    out := 0
    for i in 0 ..< len(list) {
        if out > 0 && same(list[out - 1], list[i]) {
            continue
        }
        list[out] = list[i]
        out += 1
    }
    resize(list, out)
}

// Drops a reference or implementation another backend already reported.
@(private = "file")
dedup_symbols :: proc(list: ^[dynamic]Symbol) {
    out := 0
    for i in 0 ..< len(list) {
        dup := false
        for j in 0 ..< out {
            if list[j].offset == list[i].offset && list[j].path == list[i].path {
                dup = true
                break
            }
        }
        if dup {
            delete(list[i].name)
            delete(list[i].kind)
            delete(list[i].signature)
            delete(list[i].path)
            continue
        }
        list[out] = list[i]
        out += 1
    }
    resize(list, out)
}

// Drops a hint at the same offset with the same label, freeing the label it drops.
@(private = "file")
dedup_inlays :: proc(list: ^[dynamic]Inlay_Hint) {
    out := 0
    for i in 0 ..< len(list) {
        if out > 0 && list[out - 1].offset == list[i].offset && list[out - 1].label == list[i].label {
            delete(list[i].label)
            continue
        }
        list[out] = list[i]
        out += 1
    }
    resize(list, out)
}
