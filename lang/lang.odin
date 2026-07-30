// Language intelligence seam: an editor-agnostic, LSP-shaped request/response
// layer whose backends run either in-client (a native analyzer on a bounded
// pool of worker threads) or, later, out-of-process (a subprocess LSP client).
// The editor only ever talks to the Manager; every backend answers through the
// same async reap the file loader uses (worker appends to a mutex-guarded
// queue, drained on the main thread once per frame).
package lang

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// What the editor is asking for. Kept small on purpose; it grows as features
// land (Definition, Hover, Document_Symbols, Workspace_Symbols, References,
// Signature_Help, Completion, Package_Doc, Rename and Diagnostics today).
Request_Kind :: enum {
    Definition,
    Hover,
    Document_Symbols,
    Workspace_Symbols,
    References,
    Signature_Help,
    Completion,
    Package_Doc,
    Rename,
    Diagnostics,
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

// One text replacement a backend wants applied: `[start, end)` in the file at
// `path` becomes `new_text`. `old_text` is what the backend read there, so the
// editor can verify the range before touching a file that may have moved on
// since the scan. Rename's payload; the shape a code action would reuse.
Text_Edit :: struct {
    path:     string, // owned; absolute file path
    start:    int,
    end:      int,
    old_text: string, // owned; the bytes the backend matched at [start, end)
    new_text: string, // owned; what replaces them
}

// Severity of a compiler diagnostic. Deliberately coarser than LSP's four
// levels: everything a checker emits is either something that stops the build or
// something that does not, and the editor colors exactly those two.
Diagnostic_Severity :: enum {
    Error,
    Warning,
}

// One diagnostic, in the file it belongs to. Line and column rather than the
// byte offsets the rest of the seam speaks: every producer (a compiler's stderr,
// an LSP's publishDiagnostics) reports 1-based line:col, and only the editor —
// which holds the live buffers — can map that onto a piece table. Converting
// here would mean re-reading files the editor already has open.
Diagnostic :: struct {
    path:     string, // owned, absolute
    line:     int,    // 1-based
    col:      int,    // 1-based
    severity: Diagnostic_Severity,
    message:  string, // owned
}

// A check's full answer for one scope. `scope` is the directory (or single file)
// the check covered, and `items` is exhaustive for it: a file that no longer has
// errors simply stops appearing, so `scope` is the only thing that tells the
// editor whose old squiggles to retire. An empty `items` with a scope set means
// "that whole scope is clean", not "nothing was checked" — `ok` distinguishes
// those.
Diagnostic_Report :: struct {
    scope: string, // owned, absolute directory or file path
    items: [dynamic]Diagnostic,
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
    new_name:  string, // owned; the request's argument — Rename's replacement identifier, "" otherwise
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
    // Rename; owned, freed in job_free. Sorted ascending by (path, start), so an
    // applier walks one file's edits back-to-front to keep the offsets valid.
    edits:     [dynamic]Text_Edit,
    report:    Diagnostic_Report, // Diagnostics; owned, freed in job_free
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

// How long a debounced request waits for the input to settle before it is
// dispatched. The typing-driven kinds (completion, signature help) re-trigger on
// every keystroke; hover is already dwell-gated, so its delay is only a floor
// under a mouse sweeping across the buffer.
DEBOUNCE_TYPING :: 50 * time.Millisecond
DEBOUNCE_HOVER :: 150 * time.Millisecond

// The delay for save-driven checks. Far longer than the typing delays because
// the work behind it is far heavier — a whole compiler invocation over a package
// — and because the trigger is coarser: a save-all, or an autosave landing
// behind an explicit save, must cost one run and not one per file.
DEBOUNCE_CHECK :: 400 * time.Millisecond

// How many jobs the worker pool runs at once. Requests are latency-bound (a
// parse, a stat walk) rather than throughput-bound, and cancellation keeps at
// most one live job per kind, so a handful of workers covers the useful
// concurrency; the cap is what stops a workspace scan behind every keystroke
// from spawning a thread each. The floor is 2 so a slow request (a workspace
// scan) can never wedge the pool against a fast one (hover) queued behind it.
WORKERS_MIN :: 2
WORKERS_MAX :: 4

@(private)
Job :: struct {
    manager:   ^Manager,
    backend:   Backend, // copied so a later append to `backends` can't dangle
    request:   Request,
    result:    Result,
    cancelled: bool, // written by the main thread, read atomically by the worker
}

// A request waiting out its debounce delay. One slot per kind: a newer request
// of the same kind overwrites the slot, so a burst of keystrokes costs a single
// dispatch instead of one per key. The strings are owned by the Manager's
// allocator and move into the Job when the slot is flushed. `id` is reserved
// when the slot is filled, so the caller can key its result slot on it right
// away even though no worker exists yet.
@(private)
Pending :: struct {
    active:    bool,
    id:        u64,
    path:      string,
    ext:       string,
    source:    string,
    offset:    int,
    revision:  u64,
    workspace: string,
    new_name:  string,
    due:       time.Time,
}

// Routes requests to backends and reaps their results. One per editor.
Manager :: struct {
    backends:  [dynamic]Backend,
    next_id:   u64,
    allocator: runtime.Allocator,
    mutex:     sync.Mutex, // guards `finished`, `active`, `inflight`, `queue` and `shutdown`
    finished:  [dynamic]^Job,
    active:    map[u64]^Job, // every dispatched job not yet freed, so it can be cancelled by id
    inflight:  int,
    // The worker pool: dispatched jobs wait in `queue` (FIFO) until one of the
    // `workers` picks them up, woken by one `work` post per enqueued job.
    queue:     [dynamic]^Job,
    workers:   []^thread.Thread,
    work:      sync.Sema,
    shutdown:  bool, // set by pool_destroy; a worker that wakes to an empty queue then exits
    // Debounce slots, one per kind. Main-thread only (filled by
    // manager_request_debounced, emptied by manager_flush_debounced and the
    // cancels), so unlike `active` they need no lock.
    pending:   [Request_Kind]Pending,
}

manager_init :: proc(m: ^Manager, allocator := context.allocator) {
    m.allocator = allocator
    m.backends = make([dynamic]Backend, allocator)
    m.finished = make([dynamic]^Job, allocator)
    m.active = make(map[u64]^Job, 0, allocator)
    m.queue = make([dynamic]^Job, allocator)
    m.next_id = 1

    m.workers = make([]^thread.Thread, pool_size(), allocator)
    for i in 0 ..< len(m.workers) {
        m.workers[i] = thread.create_and_start_with_poly_data(m, pool_worker)
    }
}

// Half the machine's cores, clamped to [WORKERS_MIN, WORKERS_MAX]: the editor
// needs the rest of them, and language work is only ever a slice of the frame.
@(private)
pool_size :: proc() -> int {
    return clamp(os.get_processor_core_count() / 2, WORKERS_MIN, WORKERS_MAX)
}

// How many jobs the Manager can run at once — the pool's size.
manager_worker_count :: proc(m: ^Manager) -> int {
    return len(m.workers)
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
// arrives via manager_dispatch on a later frame. `new_name` is the request's
// argument, only Rename uses it.
manager_request :: proc(
    m: ^Manager,
    kind: Request_Kind,
    path, ext, source: string,
    offset: int,
    revision: u64,
    workspace: string,
    new_name := "",
) -> u64 {
    if _, ok := backend_for(m, ext); !ok {
        return 0
    }
    context.allocator = m.allocator
    id := m.next_id
    m.next_id += 1
    return dispatch_owned(
        m,
        id,
        kind,
        strings.clone(path),
        strings.clone(ext),
        strings.clone(source),
        offset,
        revision,
        strings.clone(workspace),
        strings.clone(new_name),
    )
}

// Starts the worker for a request whose strings are *already* owned by the
// Manager's allocator: ownership moves into the Job, which frees them in
// job_free. Lets a flushed debounce slot hand its snapshot over without cloning
// the whole buffer a second time. Frees them and answers 0 when no backend
// claims the extension.
@(private)
dispatch_owned :: proc(
    m: ^Manager,
    id: u64,
    kind: Request_Kind,
    path, ext, source: string,
    offset: int,
    revision: u64,
    workspace: string,
    new_name: string,
) -> u64 {
    context.allocator = m.allocator
    backend, ok := backend_for(m, ext)
    if !ok {
        delete(path)
        delete(ext)
        delete(source)
        delete(workspace)
        delete(new_name)
        return 0
    }

    job := new(Job)
    job.manager = m
    job.backend = backend
    job.request = Request {
        id        = id,
        kind      = kind,
        path      = path,
        ext       = ext,
        source    = source,
        offset    = offset,
        revision  = revision,
        workspace = workspace,
        new_name  = new_name,
    }
    job.request.cancel = &job.cancelled // stable for the job's lifetime
    job.result.id = id
    job.result.kind = kind
    job.result.revision = revision

    sync.lock(&m.mutex)
    m.inflight += 1
    m.active[id] = job
    append(&m.queue, job)
    sync.unlock(&m.mutex)

    sync.sema_post(&m.work) // exactly one post per queued job; see pool_worker
    return id
}

// Abandons the request `id`: its backend stops at the next cancellation check
// and its result is dropped instead of handed to the editor. Returns false when
// the id is unknown (already reaped, or never dispatched). Safe to call on a
// job that has already finished — the flag is simply never read again.
manager_cancel :: proc(m: ^Manager, id: u64) -> bool {
    // A debounced request that hasn't been dispatched yet is cancelled by
    // dropping its slot; its reserved id never reaches a worker.
    for kind in Request_Kind {
        if m.pending[kind].active && m.pending[kind].id == id {
            pending_clear(m, kind)
            return true
        }
    }

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
// of. A debounced request of `kind` still waiting out its delay is dropped too,
// so an explicit trigger can't be overtaken by the typing-driven one it replaced.
// Returns how many were cancelled.
manager_cancel_kind :: proc(m: ^Manager, kind: Request_Kind) -> int {
    n := 0
    if pending_clear(m, kind) {
        n += 1
    }
    sync.lock(&m.mutex)
    defer sync.unlock(&m.mutex)
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
// against the old tree is worth having. Debounced requests still waiting are
// dropped as well. Returns how many were cancelled.
manager_cancel_all :: proc(m: ^Manager) -> int {
    n := 0
    for kind in Request_Kind {
        if pending_clear(m, kind) {
            n += 1
        }
    }
    sync.lock(&m.mutex)
    defer sync.unlock(&m.mutex)
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
    new_name := "",
) -> u64 {
    manager_cancel_kind(m, kind)
    return manager_request(m, kind, path, ext, source, offset, revision, workspace, new_name)
}

// Queues a request to be dispatched once `delay` has passed without another
// request of the same kind arriving. For the triggers that fire on every
// keystroke (completion, signature help): cancellation already stops a
// superseded request mid-work, but it still costs a thread and a full buffer
// clone per key — the debounce collapses a burst into one dispatch. Any
// in-flight or pending request of the same kind is cancelled first, so only the
// last keystroke's answer is ever computed.
//
// The id is reserved now and belongs to the eventual request, so the caller can
// store it in its result slot immediately. Returns 0 when no backend handles the
// extension (nothing is queued). The delay is measured from this call, not from
// the first keystroke of the burst, so continuous typing keeps deferring the
// dispatch — flushed by manager_flush_debounced, which manager_dispatch calls
// once per frame.
manager_request_debounced :: proc(
    m: ^Manager,
    kind: Request_Kind,
    path, ext, source: string,
    offset: int,
    revision: u64,
    workspace: string,
    delay: time.Duration = DEBOUNCE_TYPING,
    new_name := "",
) -> u64 {
    if _, ok := backend_for(m, ext); !ok {
        return 0
    }
    manager_cancel_kind(m, kind) // also drops the slot this one is about to fill

    context.allocator = m.allocator
    id := m.next_id
    m.next_id += 1
    m.pending[kind] = Pending {
        active    = true,
        id        = id,
        path      = strings.clone(path),
        ext       = strings.clone(ext),
        source    = strings.clone(source),
        offset    = offset,
        revision  = revision,
        workspace = strings.clone(workspace),
        new_name  = strings.clone(new_name),
        due       = time.time_add(time.now(), delay),
    }
    return id
}

// Dispatches every debounced request whose delay has elapsed, moving the slot's
// snapshot into the job (no second clone). Called at the head of
// manager_dispatch, so a host that already reaps results once per frame gets
// this for free. `force` ignores the timers — for tests, and for a caller that
// wants the queue drained now. Returns how many were dispatched.
manager_flush_debounced :: proc(m: ^Manager, force := false) -> int {
    n := 0
    for kind in Request_Kind {
        p := &m.pending[kind]
        if !p.active {
            continue
        }
        if !force && time.since(p.due) < 0 {
            continue
        }
        slot := p^
        p.active = false // clear before dispatching: the strings are the job's now
        dispatch_owned(
            m,
            slot.id,
            kind,
            slot.path,
            slot.ext,
            slot.source,
            slot.offset,
            slot.revision,
            slot.workspace,
            slot.new_name,
        )
        n += 1
    }
    return n
}

// True while a request of `kind` is queued but not yet dispatched, so a caller
// can tell "no answer yet" from "answered nothing".
manager_debounce_pending :: proc(m: ^Manager, kind: Request_Kind) -> bool {
    return m.pending[kind].active
}

// Drops a queued debounced request, freeing its snapshot. False when the slot
// was already empty.
@(private)
pending_clear :: proc(m: ^Manager, kind: Request_Kind) -> bool {
    p := &m.pending[kind]
    if !p.active {
        return false
    }
    context.allocator = m.allocator
    delete(p.path)
    delete(p.ext)
    delete(p.source)
    delete(p.workspace)
    delete(p.new_name)
    p^ = {}
    return true
}

// One pool thread: takes jobs off the queue until the Manager shuts down. The
// semaphore is counting, and every enqueue posts exactly once, so a wake with an
// empty queue can only be one of pool_destroy's posts — that is the exit.
@(private)
pool_worker :: proc(m: ^Manager) {
    for {
        sync.sema_wait(&m.work)

        sync.lock(&m.mutex)
        job: ^Job
        if len(m.queue) > 0 {
            job = m.queue[0]
            ordered_remove(&m.queue, 0) // FIFO; the queue is a handful of entries
        }
        stop := m.shutdown
        sync.unlock(&m.mutex)

        if job == nil {
            if stop {
                return
            }
            continue
        }
        job_run(job)
    }
}

@(private)
job_run :: proc(job: ^Job) {
    m := job.manager
    // Owned outputs live in the Manager's allocator (freed on the main thread);
    // scratch stays on this worker's temp allocator, reset after every job since
    // the thread outlives them all.
    context.allocator = m.allocator
    defer free_all(context.temp_allocator)

    // A job cancelled while it queued never reaches the backend: `resolve` would
    // poll the same flag at its head and return having done nothing.
    if !request_cancelled(&job.request) {
        job.backend.resolve(job.backend.data, &job.request, &job.result)
    }
    // Latch it here: a backend that bailed early may have left a partial result,
    // and the main thread must not hand that to the editor.
    job.result.cancelled = request_cancelled(&job.request)

    sync.lock(&m.mutex)
    append(&m.finished, job)
    sync.unlock(&m.mutex)
}

// Drains finished jobs on the main thread. For each, invokes
// `handler(user, ^Result)`, then frees the job and all its owned memory. The
// handler must copy anything from the Result it wants to keep past the call.
// A cancelled job is joined and freed but never handed to the handler: its
// result was superseded, and it may be partial. Debounced requests whose delay
// has run out are dispatched first, so this one per-frame call drives both ends.
manager_dispatch :: proc(m: ^Manager, user: rawptr, handler: proc(user: rawptr, res: ^Result)) {
    manager_flush_debounced(m)

    reaped := make([dynamic]^Job, context.temp_allocator)
    sync.lock(&m.mutex)
    for job in m.finished {
        append(&reaped, job)
    }
    clear(&m.finished)
    sync.unlock(&m.mutex)

    for job in reaped {
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
    delete(job.request.new_name)
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
    for edit in job.result.edits {
        delete(edit.path)
        delete(edit.old_text)
        delete(edit.new_text)
    }
    delete(job.result.edits)
    delete(job.result.report.scope)
    for d in job.result.report.items {
        delete(d.path)
        delete(d.message)
    }
    delete(job.result.report.items)
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

// Drains in-flight jobs, stops the worker pool (so no thread touches freed
// backend state), tears down each backend, and frees the Manager's own storage.
// Every request is cancelled first so a workspace-wide scan started just before
// quit bails at its next check instead of holding the shutdown open; that also
// empties the debounce slots, so the drain loop's manager_dispatch can't keep
// dispatching new work.
manager_destroy :: proc(m: ^Manager) {
    manager_cancel_all(m)
    for manager_busy(m) {
        manager_dispatch(m, nil, nil)
        time.sleep(time.Millisecond)
    }
    // Reap any results that landed between the last busy-check and now.
    manager_dispatch(m, nil, nil)
    pool_destroy(m)

    for b in m.backends {
        if b.destroy != nil {
            b.destroy(b.data)
        }
    }
    delete(m.backends)
    delete(m.finished)
    delete(m.active)
    delete(m.queue)
}

// Retires the pool: one wake per worker so each sees `shutdown` and returns,
// then joins them. Called after the drain, so the queue is empty — the extra
// posts for whatever it still holds are belt-and-braces, keeping the "one wake
// per worker" guarantee even if a job somehow outlived the drain.
@(private)
pool_destroy :: proc(m: ^Manager) {
    sync.lock(&m.mutex)
    m.shutdown = true
    wakes := len(m.workers) + len(m.queue)
    sync.unlock(&m.mutex)

    sync.sema_post(&m.work, wakes)
    for w in m.workers {
        thread.join(w)
        thread.destroy(w)
    }
    delete(m.workers, m.allocator)
    m.workers = nil
}
