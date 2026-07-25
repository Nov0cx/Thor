// Language intelligence seam: an editor-agnostic, LSP-shaped request/response
// layer whose backends run either in-client (a native analyzer on a worker
// thread) or, later, out-of-process (a subprocess LSP client). The editor only
// ever talks to the Manager; every backend answers through the same async reap
// the file loader uses (worker appends to a mutex-guarded queue, drained on the
// main thread once per frame).
package lang

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// What the editor is asking for. Kept small on purpose; it grows as features
// land (Definition, Hover, Document_Symbols, Workspace_Symbols, References,
// Signature_Help and Completion today).
Request_Kind :: enum {
    Definition,
    Hover,
    Document_Symbols,
    Workspace_Symbols,
    References,
    Signature_Help,
    Completion,
    Package_Doc,
}

// A byte range in a named file. Byte offsets, not line/column: the editor and
// the piece table already work in bytes, so the in-client path never converts.
// A subprocess LSP backend converts UTF-16 positions to bytes at its own edge.
Location :: struct {
    path:  string, // owned
    start: int,
    end:   int,
}

// Hover payload: display text plus the symbol range it describes, so the editor
// can underline exactly what was resolved.
Hover_Info :: struct {
    text:  string, // owned; a signature / declaration line
    start: int,
    end:   int,
}

// Package-documentation payload: a rendered documentation page for the package
// the caret refers to (an import, a `pkg.Symbol` operand, or the file's own
// package). `title` is a short heading ("package fmt"), `path` the package
// directory it was rendered from, and `text` the full page — the package's
// public top-level declarations, each with the doc comment above it. The editor
// shows it in a side pane.
Doc_Info :: struct {
    title: string, // owned; "package fmt"
    path:  string, // owned; the package directory the page was built from
    text:  string, // owned; the rendered documentation page
}

// Signature-help payload for the call the caret sits in: the resolved
// procedure's signature line and the byte range within it of the parameter the
// caret is currently on, so the editor can emphasize the active argument.
Signature_Info :: struct {
    label:        string, // owned; "add :: proc(a: int, b: int) -> int"
    active_start: int,     // [active_start, active_end) within label; empty when unknown
    active_end:   int,
}

// One entry in a symbol list (a file outline, or the whole workspace): a
// declaration's name, its kind (the LOCALS capture suffix: "function", "type",
// "enum", "constant", "var" — drives the display color), the real Odin
// declaration line ("add :: proc(a, b: int) -> int"), the file it lives in and
// the 1-based line there, and the byte offset to jump to (the identifier start).
// References reuse this shape: kind is "reference" and signature is the source
// line the usage sits on (its code context), with path/line/offset the jump.
// Completion candidates reuse it too: name is the identifier to insert, kind
// drives the row color ("function"/"type"/... or "keyword"), signature is a
// display label; path/line/offset go unused.
Symbol :: struct {
    name:      string, // owned
    kind:      string, // owned
    signature: string, // owned; the declaration line, e.g. "add :: proc(...) -> int"
    path:      string, // owned; absolute file path the symbol is declared in
    line:      int,    // 1-based line of the declaration in that file
    offset:    int,    // byte offset of the identifier within that file
}

// An editor request. `source` is an owned snapshot taken when the request is
// made, so the worker never races the live buffer; `revision` lets the editor
// drop a result a later edit has already invalidated.
Request :: struct {
    id:        u64,
    kind:      Request_Kind,
    path:      string, // owned, absolute
    ext:       string, // owned, e.g. ".odin"
    source:    string, // owned snapshot of the buffer
    offset:    int,     // byte offset of the caret
    revision:  u64,
    workspace: string, // owned, absolute
    cancel:    ^bool,  // Job-owned cancellation flag; read via request_cancelled, nil when hand-built
}

// True once the request has been abandoned (a newer one superseded it, or the
// Manager is shutting down). Backends poll this at the head of every expensive
// loop — a directory walk, a per-file re-parse — and return early; the work is
// thrown away regardless, so finishing it only costs latency for the request
// that replaced it. Cooperative: nothing interrupts a backend that never asks.
request_cancelled :: proc(req: ^Request) -> bool {
    return req.cancel != nil && sync.atomic_load(req.cancel)
}

// A completed request. Owned fields use the Manager's allocator and are freed
// on the main thread after the editor consumes them (see manager_dispatch).
// `cancelled` marks a result nobody is waiting for any more: manager_dispatch
// frees it without calling the handler, so `ok == false` always means "the
// backend found nothing", never "the work was abandoned half-done".
Result :: struct {
    id:        u64,
    kind:      Request_Kind,
    revision:  u64,
    ok:        bool,
    cancelled: bool,
    location:  Location,        // Definition
    hover:     Hover_Info,      // Hover
    doc:       Doc_Info,        // Package_Doc
    signature: Signature_Info,  // Signature_Help
    symbols:   [dynamic]Symbol, // Document_Symbols / Workspace_Symbols / References / Completion; owned, freed in job_free
}

// A language backend. Both the in-client engine and a future subprocess LSP
// client implement this. `resolve` runs on a worker thread and may block
// (parse, disk scan, pipe read); it fills `res` using context.allocator for any
// owned output. `handles` gates routing by file extension.
Backend :: struct {
    data:    rawptr,
    name:    string,
    handles: proc(data: rawptr, ext: string) -> bool,
    resolve: proc(data: rawptr, req: ^Request, res: ^Result),
    destroy: proc(data: rawptr),
}

@(private)
Job :: struct {
    manager:   ^Manager,
    backend:   Backend, // copied so a later append to `backends` can't dangle
    request:   Request,
    result:    Result,
    worker:    ^thread.Thread,
    cancelled: bool, // written by the main thread, read atomically by the worker
}

// Routes requests to backends and reaps their results. One per editor.
Manager :: struct {
    backends:  [dynamic]Backend,
    next_id:   u64,
    allocator: runtime.Allocator,
    mutex:     sync.Mutex, // guards `finished`, `active` and `inflight`
    finished:  [dynamic]^Job,
    active:    map[u64]^Job, // every dispatched job not yet freed, so it can be cancelled by id
    inflight:  int,
}

manager_init :: proc(m: ^Manager, allocator := context.allocator) {
    m.allocator = allocator
    m.backends = make([dynamic]Backend, allocator)
    m.finished = make([dynamic]^Job, allocator)
    m.active = make(map[u64]^Job, 0, allocator)
    m.next_id = 1
}

// Registers a backend. Registration order is priority: the first backend that
// claims an extension wins, so an in-client engine registered before an LSP
// fallback takes precedence for the languages it supports.
manager_register :: proc(m: ^Manager, backend: Backend) {
    append(&m.backends, backend)
}

@(private)
backend_for :: proc(m: ^Manager, ext: string) -> (Backend, bool) {
    for b in m.backends {
        if b.handles(b.data, ext) {
            return b, true
        }
    }
    return {}, false
}

// True when some backend handles `ext`, so the editor can gate its UI (grey out
// "Go to definition") without dispatching a request.
manager_supports :: proc(m: ^Manager, ext: string) -> bool {
    _, ok := backend_for(m, ext)
    return ok
}

// Dispatches a request on a worker thread. Snapshots the string inputs into the
// Manager's allocator so the caller keeps ownership of its own buffers. Returns
// the request id, or 0 when no backend handles the extension. The result
// arrives via manager_dispatch on a later frame.
manager_request :: proc(
    m: ^Manager,
    kind: Request_Kind,
    path, ext, source: string,
    offset: int,
    revision: u64,
    workspace: string,
) -> u64 {
    backend, ok := backend_for(m, ext)
    if !ok {
        return 0
    }
    context.allocator = m.allocator

    job := new(Job)
    job.manager = m
    job.backend = backend
    job.request = Request {
        id        = m.next_id,
        kind      = kind,
        path      = strings.clone(path),
        ext       = strings.clone(ext),
        source    = strings.clone(source),
        offset    = offset,
        revision  = revision,
        workspace = strings.clone(workspace),
    }
    job.request.cancel = &job.cancelled // stable for the job's lifetime
    job.result.id = m.next_id
    job.result.kind = kind
    job.result.revision = revision
    m.next_id += 1

    sync.lock(&m.mutex)
    m.inflight += 1
    m.active[job.request.id] = job
    sync.unlock(&m.mutex)

    job.worker = thread.create_and_start_with_poly_data(job, job_worker)
    return job.request.id
}

// Abandons the request `id`: its backend stops at the next cancellation check
// and its result is dropped instead of handed to the editor. Returns false when
// the id is unknown (already reaped, or never dispatched). Safe to call on a
// job that has already finished — the flag is simply never read again.
manager_cancel :: proc(m: ^Manager, id: u64) -> bool {
    sync.lock(&m.mutex)
    defer sync.unlock(&m.mutex)
    job, ok := m.active[id]
    if !ok {
        return false
    }
    sync.atomic_store(&job.cancelled, true)
    return true
}

// Cancels every in-flight request of `kind`. This is the "latest wins" primitive
// for the kinds the editor re-triggers as the user types (completion, signature
// help, hover): cancel the previous ones, then dispatch. Cancelling by kind
// rather than by a remembered id also catches requests the caller has lost track
// of. Returns how many were cancelled.
manager_cancel_kind :: proc(m: ^Manager, kind: Request_Kind) -> int {
    sync.lock(&m.mutex)
    defer sync.unlock(&m.mutex)
    n := 0
    for _, job in m.active {
        if job.request.kind == kind && !job.cancelled {
            sync.atomic_store(&job.cancelled, true)
            n += 1
        }
    }
    return n
}

// Cancels every in-flight request, whatever its kind. Used at shutdown; also the
// right call when the workspace changes under the editor and no answer computed
// against the old tree is worth having. Returns how many were cancelled.
manager_cancel_all :: proc(m: ^Manager) -> int {
    sync.lock(&m.mutex)
    defer sync.unlock(&m.mutex)
    n := 0
    for _, job in m.active {
        if !job.cancelled {
            sync.atomic_store(&job.cancelled, true)
            n += 1
        }
    }
    return n
}

// Cancels the in-flight requests of `kind` and dispatches a replacement. The
// common path for a per-keystroke trigger, so a caller can't forget the cancel.
manager_request_latest :: proc(
    m: ^Manager,
    kind: Request_Kind,
    path, ext, source: string,
    offset: int,
    revision: u64,
    workspace: string,
) -> u64 {
    manager_cancel_kind(m, kind)
    return manager_request(m, kind, path, ext, source, offset, revision, workspace)
}

@(private)
job_worker :: proc(job: ^Job) {
    // Owned outputs live in the Manager's allocator (freed on the main thread);
    // scratch stays on this worker's temp allocator.
    context.allocator = job.manager.allocator
    defer free_all(context.temp_allocator)

    job.backend.resolve(job.backend.data, &job.request, &job.result)
    // Latch it here: a backend that bailed early may have left a partial result,
    // and the main thread must not hand that to the editor.
    job.result.cancelled = request_cancelled(&job.request)

    sync.lock(&job.manager.mutex)
    append(&job.manager.finished, job)
    sync.unlock(&job.manager.mutex)
}

// Drains finished jobs on the main thread. For each, joins its worker, invokes
// `handler(user, ^Result)`, then frees the job and all its owned memory. The
// handler must copy anything from the Result it wants to keep past the call.
// A cancelled job is joined and freed but never handed to the handler: its
// result was superseded, and it may be partial.
manager_dispatch :: proc(m: ^Manager, user: rawptr, handler: proc(user: rawptr, res: ^Result)) {
    reaped := make([dynamic]^Job, context.temp_allocator)
    sync.lock(&m.mutex)
    for job in m.finished {
        append(&reaped, job)
    }
    clear(&m.finished)
    sync.unlock(&m.mutex)

    for job in reaped {
        thread.join(job.worker)
        thread.destroy(job.worker)
        if handler != nil && !job.result.cancelled {
            handler(user, &job.result)
        }
        job_free(m, job)
    }
}

@(private)
job_free :: proc(m: ^Manager, job: ^Job) {
    context.allocator = m.allocator
    delete(job.request.path)
    delete(job.request.ext)
    delete(job.request.source)
    delete(job.request.workspace)
    delete(job.result.location.path)
    delete(job.result.hover.text)
    delete(job.result.doc.title)
    delete(job.result.doc.path)
    delete(job.result.doc.text)
    delete(job.result.signature.label)
    for sym in job.result.symbols {
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(sym.path)
    }
    delete(job.result.symbols)
    id := job.request.id
    free(job)

    sync.lock(&m.mutex)
    delete_key(&m.active, id) // no longer cancellable; the pointer is dead
    m.inflight -= 1
    sync.unlock(&m.mutex)
}

// True while any request is still being worked. Used by manager_destroy and
// available to the editor for a "busy" indicator.
manager_busy :: proc(m: ^Manager) -> bool {
    sync.lock(&m.mutex)
    defer sync.unlock(&m.mutex)
    return m.inflight > 0
}

// Drains in-flight workers (so none touches freed backend state), tears down
// each backend, and frees the Manager's own storage. Every worker is cancelled
// first so a workspace-wide scan started just before quit bails at its next
// check instead of holding the shutdown open.
manager_destroy :: proc(m: ^Manager) {
    manager_cancel_all(m)
    for manager_busy(m) {
        manager_dispatch(m, nil, nil)
        time.sleep(time.Millisecond)
    }
    // Reap any results that landed between the last busy-check and now.
    manager_dispatch(m, nil, nil)

    for b in m.backends {
        if b.destroy != nil {
            b.destroy(b.data)
        }
    }
    delete(m.backends)
    delete(m.finished)
    delete(m.active)
}
