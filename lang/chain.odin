package lang

import "core:slice"
import "core:strings"

// Runs a job's backend chain on a worker. A merge kind visits every backend and
// combines the answers; any other kind keeps the first backend that answers.
// Owned output uses the Manager's allocator (set by job_run).
@(private)
job_resolve :: proc(job: ^Job) {
    chain := job.chain[:job.chain_len]
    if len(chain) == 1 {
        b := chain[0]
        b.resolve(b.data, &job.request, &job.result)
        result_stamp_origin(&job.result, backend_id(b))
        return
    }

    head := job.result // id, kind and revision the Manager preset
    merging := job.request.kind in MERGE_KINDS
    fallback: Result
    have_fallback := false
    answered := false
    for b in chain {
        if request_cancelled(&job.request) {
            break
        }
        part := Result {
            id       = head.id,
            kind     = head.kind,
            revision = head.revision,
        }
        b.resolve(b.data, &job.request, &part)
        if !part.ok {
            // Keeps the first refusal whole: a reason in `message` belongs to it.
            if have_fallback {
                result_free(job.manager, &part)
            } else {
                fallback, have_fallback = part, true
            }
            continue
        }
        result_stamp_origin(&part, backend_id(b))
        if merging && answered {
            result_merge(job.manager, &job.result, &part, job.request.kind)
            continue
        }
        job.result = part
        answered = true
        if !merging {
            break
        }
    }
    if answered {
        if have_fallback {
            result_free(job.manager, &fallback)
        }
        return
    }
    if have_fallback {
        job.result = fallback
    }
}

// Sets `origin` on every offer of `res` that no backend named yet. Clones into the
// Manager's allocator, which is the context here.
@(private)
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
@(private)
result_merge :: proc(m: ^Manager, dst, src: ^Result, kind: Request_Kind) {
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
    result_free(m, src)
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
