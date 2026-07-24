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
}

// A completed request. Owned fields use the Manager's allocator and are freed
// on the main thread after the editor consumes them (see manager_dispatch).
Result :: struct {
    id:       u64,
    kind:     Request_Kind,
    revision: u64,
    ok:        bool,
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
    manager: ^Manager,
    backend: Backend, // copied so a later append to `backends` can't dangle
    request: Request,
    result:  Result,
    worker:  ^thread.Thread,
}

// Routes requests to backends and reaps their results. One per editor.
Manager :: struct {
    backends:  [dynamic]Backend,
    next_id:   u64,
    allocator: runtime.Allocator,
    mutex:     sync.Mutex, // guards `finished` and `inflight`
    finished:  [dynamic]^Job,
    inflight:  int,
}

manager_init :: proc(m: ^Manager, allocator := context.allocator) {
    m.allocator = allocator
    m.backends = make([dynamic]Backend, allocator)
    m.finished = make([dynamic]^Job, allocator)
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
    job.result.id = m.next_id
    job.result.kind = kind
    job.result.revision = revision
    m.next_id += 1

    sync.lock(&m.mutex)
    m.inflight += 1
    sync.unlock(&m.mutex)

    job.worker = thread.create_and_start_with_poly_data(job, job_worker)
    return job.request.id
}

@(private)
job_worker :: proc(job: ^Job) {
    // Owned outputs live in the Manager's allocator (freed on the main thread);
    // scratch stays on this worker's temp allocator.
    context.allocator = job.manager.allocator
    defer free_all(context.temp_allocator)

    job.backend.resolve(job.backend.data, &job.request, &job.result)

    sync.lock(&job.manager.mutex)
    append(&job.manager.finished, job)
    sync.unlock(&job.manager.mutex)
}

// Drains finished jobs on the main thread. For each, joins its worker, invokes
// `handler(user, ^Result)`, then frees the job and all its owned memory. The
// handler must copy anything from the Result it wants to keep past the call.
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
        if handler != nil {
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
    free(job)

    sync.lock(&m.mutex)
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
// each backend, and frees the Manager's own storage.
manager_destroy :: proc(m: ^Manager) {
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
}
