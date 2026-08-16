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
    Code_Actions,
    Semantic_Tokens,
    Format,
    // Whole-line range formatting over [offset, end) — a selection, aligned to
    // whole lines by the host before dispatch.
    Format_Range,
    // Fired after one typed character (Request.trigger), debounced like
    // completion. Answers the same Result.edits shape as Format.
    Format_On_Type,
    // Runs a Code_Action that carries a command instead of edits
    // (Request.command / command_args). The server does the work and sends its
    // changes back as a pushed Apply_Edit, so the result carries no edits of its
    // own — only whether the command ran.
    Execute_Command,
    // Fills in the parts of a completion candidate the backend deferred — the
    // changes elsewhere it needs, and its follow-up command. Dispatched when the
    // user picks a row, never while the list is being built, and carries the
    // candidate back verbatim in Request.item. Only a backend that defers
    // answers it; an in-client analyzer computes everything up front.
    Resolve_Completion,
    // Push-only: never dispatched through manager_request*, only produced by
    // Backend.poll (a server's unsolicited $/progress notification).
    Progress,
    // Push-only, like Progress: a server-initiated workspace/applyEdit. `edits`
    // carries the decoded WorkspaceEdit; `token`/`on_applied` on Result carry
    // the reply the server is waiting on back to the backend.
    Apply_Edit,
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

// A rendered documentation page for the package the caret refers to: `title` is
// a short heading ("package fmt"), `path` the directory it was rendered from,
// `text` the public top-level declarations with their doc comments.
Doc_Info :: struct {
    title: string, // owned; "package fmt"
    path:  string, // owned; the package directory the page was built from
    text:  string, // owned; the rendered documentation page
}

// One candidate signature for the call the caret sits in: a procedure's
// signature line and the byte range within it of the parameter the caret is
// currently on, so the editor can emphasize the active argument.
Signature_Entry :: struct {
    label:        string, // owned; "add :: proc(a: int, b: int) -> int"
    active_start: int,     // [active_start, active_end) within label; empty when unknown
    active_end:   int,
}

// Signature help for the call the caret sits in. A list, because a call can name
// a procedure group (`sizes :: proc{sized_a, sized_b}`) whose own declaration
// has no parameters — only its members are worth showing. An ordinary call
// answers with one entry. `active` indexes the entry the written arguments best
// match; the editor emphasizes that one.
Signature_Info :: struct {
    entries: [dynamic]Signature_Entry, // owned, freed in job_free
    active:  int,
}

// One entry in a symbol list (a file outline, or the whole workspace): a
// declaration's name, its kind (the LOCALS capture suffix, which drives the
// display color), its real Odin declaration line, and the file, 1-based line and
// byte offset to jump to. References reuse the shape with kind "reference" and
// the usage's source line as the signature.
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

// One completion candidate. `label` is the row text and `insert` what lands in
// the buffer — an editor-agnostic snippet template when `snippet` is set.
// `start`/`end` are byte offsets in the request's own source that the insert
// replaces, both -1 when the backend named no range and the editor falls back to
// the word being typed. `extra_edits` are the changes elsewhere the candidate
// needs, such as an import line. The last four are a deferring backend's
// round-trip payloads and are empty for an in-client one.
Completion_Item :: struct {
    label:       string, // owned; the row text
    kind:        string, // owned; drives the row color, the vocabulary Symbol.kind uses
    detail:      string, // owned; the signature shown beside the row
    insert:      string, // owned; "" inserts the label
    filter:      string, // owned; what the editor's prefix filter matches, "" the label
    sort:        string, // owned; the backend's ordering key, "" the label
    start:       int,    // byte offset the insert replaces; -1 when unset
    end:         int,    // one past it; -1 when unset
    snippet:     bool,   // `insert` is a snippet template, not literal text
    preselect:   bool,   // the backend's own pick for the initially selected row
    extra_edits: [dynamic]Text_Edit, // owned; applied after the insert lands
    command:     string, // owned; run after the edits, "" when none
    arguments:   string, // owned; the command's arguments as raw JSON array text
    raw:         string, // owned; the candidate verbatim as JSON text, echoed back on resolve
}

// A formatter's opinion on a file's line ending, read from its own config
// (odinfmt's newline_style). Unspecified when the config never named one —
// the seam and every buffer are LF internally regardless (see source_read),
// so this only ever governs Thor's own line_ending bookkeeping on save.
Newline_Preference :: enum {
    Unspecified,
    LF,
    CRLF,
}

// What a resource operation does to a file, outside the text-edit path.
Resource_Op_Kind :: enum {
    Create,
    Rename,
    Delete,
}

// A file-level change a WorkspaceEdit named alongside its text edits: LSP's
// CreateFile / RenameFile / DeleteFile. `path` is the file created or deleted,
// or a rename's source; `new_path` is set for Rename only. An applier runs these
// in a fixed phase order — Create, text edits, Rename, Delete — rather than
// documentChanges' array position, which gets create-then-populate right and
// does not preserve interleavings real emitters do not produce.
Resource_Op :: struct {
    kind:             Resource_Op_Kind,
    path:             string, // owned; absolute
    new_path:         string, // owned; absolute, Rename only, "" otherwise
    overwrite:        bool,
    ignore_if_exists: bool,
}

// One fix the backend is offering at the caret: a title to show the user and the
// edits that apply it. Unlike LSP, the edits are computed up front rather than
// resolved in a second round trip — that split exists to keep IPC off the offer
// path, and an in-client backend has no IPC to keep off it. Computing both at
// once also closes the window where the buffer moves between offer and apply.
Code_Action :: struct {
    title:         string,              // owned; "Import core:fmt"
    kind:          string,              // owned; "quickfix" / "refactor" — drives the row color
    edits:         [dynamic]Text_Edit,  // owned; same ordering contract as Result.edits
    resource_ops:  [dynamic]Resource_Op, // owned; same fixed-phase-order contract as Result.resource_ops
    // The one exception to "computed up front": an LSP server may offer a fix as
    // a command it runs itself. Picking it dispatches Execute_Command, and the
    // changes arrive later as a pushed Apply_Edit. Both empty for an in-client
    // backend, and an action may carry edits *and* a command — LSP applies the
    // edits first, then runs it.
    command:       string, // owned; "" when the action carries its own edits
    arguments:     string, // owned; the command's arguments as raw JSON array text
}

// What a classified identifier turned out to be — what the analyzer proved, not
// what the parse shape suggests, since a parameter, a local, a field and a
// package all parse as a bare `identifier`. `Unresolved` is an *absence*:
// emitted only when every lookup completed and came up empty, so a backend that
// cannot see far enough must leave the name unclassified instead.
Token_Kind :: enum {
    Parameter,
    Local,
    Field,
    Procedure,
    Type,
    Enum_Member,
    Package,
    Unresolved,
}

// One classified identifier: a byte range and what the analyzer proved it to be.
// Carries no owned strings, unlike every other payload here — a file is
// thousands of rows, so a `string` kind would be a clone and a free per
// identifier per keystroke. The editor maps the enum to a color itself.
Semantic_Token :: struct {
    start: int,
    end:   int,
    kind:  Token_Kind,
}

// One step of a server's unsolicited work-progress report ($/progress). `done`
// marks the "end" phase, which carries no message — the editor clears its
// indicator on it rather than showing a blank one.
Progress_Info :: struct {
    message: string, // owned; "" once done
    done:    bool,
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

// A check's full answer for one scope. `items` is exhaustive for `scope`, so a
// file that no longer has errors just stops appearing and `scope` is what tells
// the editor whose old squiggles to retire. Empty `items` with a scope set means
// the scope is clean, not that nothing was checked — `ok` distinguishes those.
Diagnostic_Report :: struct {
    scope: string, // owned, absolute directory or file path
    items: [dynamic]Diagnostic,
}

// A diagnostic already in byte-offset form, handed to a Code_Actions request by
// the host, which holds the live buffer and has already done the line:col to
// offset conversion `Diagnostic` itself defers.
Diagnostic_Ref :: struct {
    start:    int,
    end:      int,
    severity: Diagnostic_Severity,
    message:  string, // owned
}

// `diags` with every message cloned onto `allocator`, so a request snapshot
// outlives the host's own diagnostic list.
clone_diagnostic_refs :: proc(diags: []Diagnostic_Ref, allocator: runtime.Allocator) -> []Diagnostic_Ref {
    if len(diags) == 0 {
        return nil
    }
    out := make([]Diagnostic_Ref, len(diags), allocator)
    for d, i in diags {
        out[i] = d
        out[i].message = strings.clone(d.message, allocator)
    }
    return out
}

@(private)
free_diagnostic_refs :: proc(diags: []Diagnostic_Ref) {
    for d in diags {
        delete(d.message)
    }
    delete(diags)
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
    offset:    int,     // byte offset of the caret, or a selection's low end
    end:       int,     // byte offset of a selection's high end; == offset outside a selection
    revision:  u64,
    workspace: string, // owned, absolute
    new_name:  string, // owned; the request's argument — Rename's replacement identifier, "" otherwise
    query:     string, // owned; Workspace_Symbols' filter text, "" otherwise (an unfiltered scan)
    // owned (each message cloned); Code_Actions' diagnostics overlapping the
    // caret/selection, empty otherwise and for every other kind.
    diagnostics: []Diagnostic_Ref,
    // Format / Format_Range / Format_On_Type: spaces per indent level of the
    // request's buffer. 0 means unset — a backend falls back to its own default.
    tab_size: int,
    // Format_On_Type and Completion; owned. The character just typed, as UTF-8,
    // "" when the request was not driven by one. A backend uses it to tell an
    // explicitly opened list from one a character asked for.
    trigger:  string,
    // Execute_Command only; owned. The command identifier, and its arguments as
    // the raw JSON array text the offer carried — kept verbatim rather than
    // decoded, since the seam never reads them and the server round-trips its
    // own shapes.
    command:      string,
    command_args: string,
    // Resolve_Completion only; owned. The candidate the user picked, verbatim as
    // the raw JSON text the offer carried — kept undecoded for the same reason
    // command_args is.
    item:      string,
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

// A completed request. Owned fields use the Manager's allocator and are freed on
// the main thread after the editor consumes them. A `cancelled` result is freed
// without reaching the handler, so `ok == false` always means "found nothing",
// never "abandoned half-done". `id` is 0 on a result no request asked for (see
// Backend.poll), which a consumer matching a stored id must tolerate.
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
    symbols:   [dynamic]Symbol, // Document_Symbols / Workspace_Symbols / References; owned, freed in job_free
    // Completion; owned, freed in job_free. In the order the editor lists them —
    // a backend that has an opinion sorts before it answers.
    completions: [dynamic]Completion_Item,
    // Completion. True when the backend answered only the candidates it could
    // find quickly, so the editor must ask again as the word grows instead of
    // narrowing the list it has.
    incomplete:  bool,
    // Rename; owned, freed in job_free. Sorted ascending by (path, start), so an
    // applier walks one file's edits back-to-front to keep the offsets valid.
    edits:     [dynamic]Text_Edit,
    // Rename; owned, freed in job_free. See Resource_Op for the apply order.
    resource_ops: [dynamic]Resource_Op,
    report:    Diagnostic_Report, // Diagnostics; owned, freed in job_free
    // Code_Actions; owned, freed in job_free. Each carries its own edit set, so
    // the editor applies exactly the one the user picked.
    actions:   [dynamic]Code_Action,
    // Semantic_Tokens; owned, freed in job_free. Ascending by `start` and
    // non-overlapping, so the editor can merge them against its syntax spans in
    // one pass. Sparse by design: an identifier the backend could not classify
    // is simply absent, and keeps whatever color the grammar gave it.
    tokens:    [dynamic]Semantic_Token,
    // Format only. Set from the workspace's odin-formatter.json newline_style
    // key, and only when that key is actually present — an absent key must
    // never flip a repo's line endings on the first format. Unspecified means
    // the applier leaves the file's line ending untouched.
    newline:   Newline_Preference,
    progress:  Progress_Info, // Progress; owned message, freed in result_free
    // Apply_Edit only. `edits` (above) carries the decoded WorkspaceEdit. Not
    // owned strings — job_free/result_free must not touch them — but the
    // handler must call `on_applied(token, ok)` exactly once, since it is the
    // reply a server is blocked waiting on.
    token:      rawptr,
    on_applied: proc(token: rawptr, applied: bool),
}

// What a buffer did, for a backend that must track document state rather than
// only answer requests (a subprocess LSP client's didOpen / didChange /
// didSave / didClose).
Doc_Event :: enum {
    Opened,
    Changed,
    Saved,
    Closed,
}

// A language backend. Both the in-client engine and a future subprocess LSP
// client implement this. `resolve` runs on a worker thread and may block
// (parse, disk scan, pipe read); it fills `res` using context.allocator for any
// owned output. `handles` gates routing by file extension. The last three are
// optional — nil is what an in-client engine leaves them.
Backend :: struct {
    data:    rawptr,
    name:    string,
    handles: proc(data: rawptr, ext: string) -> bool,
    resolve: proc(data: rawptr, req: ^Request, res: ^Result),
    destroy: proc(data: rawptr),
    // True when the backend can answer `kind` for `ext`; nil means every kind it
    // claims by extension. Lets manager_allows tell a caller with a fallback
    // (rename -> find and replace) which one to run. Called on the main thread
    // while a worker may be inside resolve, so it must read only atomically
    // published data and must not lock.
    supports: proc(data: rawptr, ext: string, kind: Request_Kind) -> bool,
    // Takes the next result the backend produced without being asked (a server
    // pushing diagnostics). Called on the main thread once per frame until it
    // answers false. Owned strings use the Manager's allocator.
    poll:     proc(data: rawptr, res: ^Result) -> bool,
    // Tells the backend a buffer changed state. Main thread, must not block: a
    // subprocess backend queues a notification and returns. `source` is
    // borrowed for the call.
    notify:   proc(data: rawptr, event: Doc_Event, path, ext, source: string, revision: u64),
    // True when typing `char` in a file of `ext` should trigger on-type
    // formatting — an LSP backend answers from the server's advertised trigger
    // characters. nil (the in-client engine's default) means never; a caller
    // must not dispatch Format_On_Type without asking first, unlike the other
    // kinds where an unwanted dispatch just answers ok=false.
    on_type_trigger: proc(data: rawptr, ext: string, char: string) -> bool,
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

// How many jobs the worker pool runs at once. Requests are latency-bound and
// cancellation keeps at most one live job per kind, so the cap only has to stop
// a workspace scan per keystroke from spawning a thread each. The floor is 2, so
// a slow scan can never wedge the pool against a fast hover queued behind it.
WORKERS_MIN :: 2
WORKERS_MAX :: 4

// Kinds that must never have two jobs in flight at once, because the work is a
// whole external process rather than a parse. A second one waits in its debounce
// slot until the first is reaped (see manager_flush_debounced) — letting it wait
// on a worker instead would pin that worker for the run's whole duration, which
// with WORKERS_MIN workers is the starvation the floor exists to prevent.
EXCLUSIVE_KINDS :: bit_set[Request_Kind]{.Diagnostics}

// How many unsolicited results one backend may hand over in a frame. A cap
// rather than a full drain: a backend whose `poll` never runs dry would
// otherwise hold the frame open, and the rest arrives on the next one anyway.
POLL_MAX_PER_FRAME :: 64

@(private)
Job :: struct {
    manager:   ^Manager,
    backend:   Backend, // copied so a later append to `backends` can't dangle
    request:   Request,
    result:    Result,
    cancelled: bool, // written by the main thread, read atomically by the worker
}

// A request waiting out its debounce delay. One slot per kind, overwritten by a
// newer request of that kind, so a burst of keystrokes costs one dispatch. The
// strings are Manager-allocated and move into the Job when the slot is flushed.
// `id` is reserved when the slot is filled, so the caller can key its result
// slot on it before a worker exists.
@(private)
Pending :: struct {
    active:    bool,
    id:        u64,
    path:      string,
    ext:       string,
    source:    string,
    offset:      int,
    end:         int,
    revision:    u64,
    workspace:   string,
    new_name:    string,
    query:       string,
    diagnostics: []Diagnostic_Ref,
    tab_size:    int,
    trigger:     string,
    due:         time.Time,
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
    // Reserved ids a flush could not dispatch, answered as `ok == false` by the
    // next manager_dispatch. Main-thread only, like `pending`.
    failed:    [dynamic]Result,
    // The feature gate the host's config sets: the master switch and the kinds
    // that may still be dispatched. Main-thread only, read by every request
    // entry point. manager_init turns everything on.
    enabled:   bool,
    features:  bit_set[Request_Kind],
}

manager_init :: proc(m: ^Manager, allocator := context.allocator) {
    m.allocator = allocator
    m.enabled = true
    m.features = FEATURES_ALL
    m.backends = make([dynamic]Backend, allocator)
    m.finished = make([dynamic]^Job, allocator)
    m.active = make(map[u64]^Job, 0, allocator)
    m.queue = make([dynamic]^Job, allocator)
    m.failed = make([dynamic]Result, allocator)
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

// The registered backend named `name`, if any. Read-only lookup for a caller
// that needs to reach one directly — a workspace change destroying just the
// LSP backend without disturbing another that needs no rebuild.
manager_backend_named :: proc(m: ^Manager, name: string) -> (Backend, bool) {
    for b in m.backends {
        if b.name == name {
            return b, true
        }
    }
    return {}, false
}

// Replaces the whole registered set in one call, in the order given — for a
// workspace change, where precedence (an LSP client's "override" flag) can flip
// and manager_register only appends. The caller must have drained the manager
// (manager_cancel_all plus a manager_busy loop) so no worker is inside a
// backend's resolve, and must destroy any outgoing backend itself: one left out
// of `backends` is dropped, never destroyed here.
manager_set_backends :: proc(m: ^Manager, backends: ..Backend) {
    clear(&m.backends)
    for b in backends {
        append(&m.backends, b)
    }
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

// The backend that claims `ext`, and whether it answers `kind`. Precedence stays
// all-or-nothing per extension: the first claimant is the answer even when it
// declines the kind, so a request never falls through to a second backend that
// would resolve it against a different language model.
@(private)
backend_for_kind :: proc(m: ^Manager, ext: string, kind: Request_Kind) -> (Backend, bool) {
    b, ok := backend_for(m, ext)
    if !ok {
        return {}, false
    }
    if b.supports != nil && !b.supports(b.data, ext, kind) {
        return {}, false
    }
    return b, true
}

// True when some backend handles `ext` and language intelligence is on, so the
// editor can gate its UI (grey out "Go to definition") without dispatching a
// request.
manager_supports :: proc(m: ^Manager, ext: string) -> bool {
    if !m.enabled {
        return false
    }
    _, ok := backend_for(m, ext)
    return ok
}

// Turns the whole seam off or on. Off refuses every request, whatever backend
// claims the extension, and cancels the work already in flight — the switch a
// user throws to make the editor a plain text editor again. On restores the
// per-feature gate as it stands.
manager_set_enabled :: proc(m: ^Manager, enabled: bool) {
    if m.enabled == enabled {
        return
    }
    m.enabled = enabled
    if !enabled {
        manager_cancel_all(m)
    }
}

// True while language intelligence is on as a whole, whatever the per-feature
// gate says.
manager_enabled :: proc(m: ^Manager) -> bool {
    return m.enabled
}

// Sets which kinds may be dispatched. A kind that goes off has its in-flight and
// debounced work cancelled at once, so a feature turned off in the settings
// stops answering on the same frame instead of after one more result.
manager_set_features :: proc(m: ^Manager, features: bit_set[Request_Kind]) {
    for kind in m.features - features {
        manager_cancel_kind(m, kind)
    }
    m.features = features
}

// The kinds the per-feature gate lets through, whether or not the master switch
// is on.
manager_features :: proc(m: ^Manager) -> bit_set[Request_Kind] {
    return m.features
}

// True when `kind` may be dispatched: the master switch is on and the gate
// holds the kind.
manager_feature_enabled :: proc(m: ^Manager, kind: Request_Kind) -> bool {
    return m.enabled && kind in m.features
}

// True when `kind` may be dispatched for `ext` — the gate, a backend that claims
// the extension, and that backend answering the kind. The check a caller makes
// when a feature has a fallback to run instead (rename falling back to find and
// replace).
manager_allows :: proc(m: ^Manager, ext: string, kind: Request_Kind) -> bool {
    if !manager_feature_enabled(m, kind) {
        return false
    }
    _, ok := backend_for_kind(m, ext, kind)
    return ok
}

// True when typing `char` in a file of `ext` should trigger Format_On_Type: the
// feature gate, a backend that claims the extension and answers the kind, and
// that backend's own on_type_trigger (nil means never). This is the check a
// caller makes before every keystroke, so a request is never dispatched on a
// character no server asked for.
manager_on_type_trigger :: proc(m: ^Manager, ext, char: string) -> bool {
    if !manager_feature_enabled(m, .Format_On_Type) {
        return false
    }
    b, ok := backend_for_kind(m, ext, .Format_On_Type)
    if !ok || b.on_type_trigger == nil {
        return false
    }
    return b.on_type_trigger(b.data, ext, char)
}

// Dispatches a request on a worker thread, snapshotting the string inputs into
// the Manager's allocator so the caller keeps its own buffers. Returns the
// request id, or 0 when the feature gate refuses the kind or no backend handles
// the extension; the result arrives via manager_dispatch on a later frame. The
// per-kind arguments — `new_name` (Rename), `query` (Workspace_Symbols), `end`,
// `diagnostics` (Code_Actions, a negative `end` collapsing to `offset`),
// `command`/`command_args` (Execute_Command) and `item` (Resolve_Completion) —
// are ignored by every other kind.
manager_request :: proc(
    m: ^Manager,
    kind: Request_Kind,
    path, ext, source: string,
    offset: int,
    revision: u64,
    workspace: string,
    new_name := "",
    query := "",
    end := -1,
    diagnostics: []Diagnostic_Ref = nil,
    tab_size := 0,
    trigger := "",
    command := "",
    command_args := "",
    item := "",
) -> u64 {
    if !manager_feature_enabled(m, kind) {
        return 0
    }
    if _, ok := backend_for_kind(m, ext, kind); !ok {
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
        end < 0 ? offset : end,
        revision,
        strings.clone(workspace),
        strings.clone(new_name),
        strings.clone(query),
        clone_diagnostic_refs(diagnostics, m.allocator),
        tab_size,
        strings.clone(trigger),
        strings.clone(command),
        strings.clone(command_args),
        strings.clone(item),
    )
}

// Tells the backend that claims `ext` a buffer changed state, so a backend that
// mirrors the editor's documents (a subprocess LSP client) keeps them in step
// without a request having to arrive first. Does nothing while the master switch
// is off, when no backend claims the extension, or when that backend defines no
// `notify`. Main thread; `source` is borrowed for the call only.
manager_notify :: proc(m: ^Manager, event: Doc_Event, path, ext, source: string, revision: u64) {
    if !m.enabled {
        return
    }
    b, ok := backend_for(m, ext) // document sync is not a request kind
    if !ok || b.notify == nil {
        return
    }
    b.notify(b.data, event, path, ext, source, revision)
}

// Starts the worker for a request whose strings are *already* owned by the
// Manager's allocator: ownership moves into the Job, which frees them in
// job_free. Lets a flushed debounce slot hand its snapshot over without cloning
// the whole buffer a second time. Frees them and answers 0 when no backend
// claims the extension or none answers the kind.
@(private)
dispatch_owned :: proc(
    m: ^Manager,
    id: u64,
    kind: Request_Kind,
    path, ext, source: string,
    offset: int,
    end: int,
    revision: u64,
    workspace: string,
    new_name: string,
    query: string,
    diagnostics: []Diagnostic_Ref = nil,
    tab_size: int = 0,
    trigger: string = "",
    command: string = "",
    command_args: string = "",
    item: string = "",
) -> u64 {
    context.allocator = m.allocator
    backend, ok := backend_for_kind(m, ext, kind)
    if !ok {
        delete(path)
        delete(ext)
        delete(source)
        delete(workspace)
        delete(new_name)
        delete(query)
        free_diagnostic_refs(diagnostics)
        delete(trigger)
        delete(command)
        delete(command_args)
        delete(item)
        return 0
    }

    job := new(Job)
    job.manager = m
    job.backend = backend
    job.request = Request {
        id          = id,
        kind        = kind,
        path        = path,
        ext         = ext,
        source      = source,
        offset      = offset,
        end         = end,
        revision    = revision,
        workspace   = workspace,
        new_name    = new_name,
        query       = query,
        diagnostics = diagnostics,
        tab_size    = tab_size,
        trigger     = trigger,
        command      = command,
        command_args = command_args,
        item         = item,
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

// Cancels every in-flight request of `kind` — the "latest wins" primitive for
// the kinds the editor re-triggers as the user types. Cancelling by kind rather
// than by a remembered id also catches requests the caller lost track of, and a
// debounced request of `kind` is dropped too, so an explicit trigger cannot be
// overtaken by the typing-driven one it replaced. Returns how many were
// cancelled.
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
    query := "",
    end := -1,
    diagnostics: []Diagnostic_Ref = nil,
    tab_size := 0,
    trigger := "",
    command := "",
    command_args := "",
    item := "",
) -> u64 {
    manager_cancel_kind(m, kind)
    return manager_request(
        m,
        kind,
        path,
        ext,
        source,
        offset,
        revision,
        workspace,
        new_name,
        query,
        end,
        diagnostics,
        tab_size,
        trigger,
        command,
        command_args,
        item,
    )
}

// Queues a request to be dispatched once `delay` has passed without another of
// the same kind arriving, collapsing a burst of keystrokes into one dispatch
// where plain cancellation would still cost a thread and a buffer clone per key.
// Any in-flight or pending request of the kind is cancelled first.
//
// The id is reserved now and belongs to the eventual request, so the caller can
// store it in its result slot immediately. Returns 0 when the feature gate
// refuses the kind or no backend handles the extension. The delay runs from this
// call, not from the burst's first keystroke, so continuous typing keeps
// deferring the dispatch; manager_flush_debounced releases it.
manager_request_debounced :: proc(
    m: ^Manager,
    kind: Request_Kind,
    path, ext, source: string,
    offset: int,
    revision: u64,
    workspace: string,
    delay: time.Duration = DEBOUNCE_TYPING,
    new_name := "",
    query := "",
    end := -1,
    diagnostics: []Diagnostic_Ref = nil,
    tab_size := 0,
    trigger := "",
) -> u64 {
    if !manager_feature_enabled(m, kind) {
        return 0
    }
    if _, ok := backend_for_kind(m, ext, kind); !ok {
        return 0
    }
    manager_cancel_kind(m, kind) // also drops the slot this one is about to fill

    context.allocator = m.allocator
    id := m.next_id
    m.next_id += 1
    m.pending[kind] = Pending {
        active      = true,
        id          = id,
        path        = strings.clone(path),
        ext         = strings.clone(ext),
        source      = strings.clone(source),
        offset      = offset,
        end         = end < 0 ? offset : end,
        revision    = revision,
        workspace   = strings.clone(workspace),
        new_name    = strings.clone(new_name),
        query       = strings.clone(query),
        diagnostics = clone_diagnostic_refs(diagnostics, m.allocator),
        tab_size    = tab_size,
        trigger     = strings.clone(trigger),
        due         = time.time_add(time.now(), delay),
    }
    return id
}

// Dispatches every debounced request whose delay has elapsed, moving the slot's
// snapshot into the job with no second clone. Called at the head of
// manager_dispatch, so a host that reaps once per frame gets this for free.
// `force` ignores the timers, but not the EXCLUSIVE_KINDS hold-back: that slot
// waits out an in-flight job of its kind, costing no worker while the newest
// snapshot still wins. Returns how many were dispatched.
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
        if kind in EXCLUSIVE_KINDS && kind_inflight(m, kind) {
            continue // re-tested next frame, when the running job may be reaped
        }
        slot := p^
        p.active = false // clear before dispatching: the strings are the job's now
        dispatched := dispatch_owned(
            m,
            slot.id,
            kind,
            slot.path,
            slot.ext,
            slot.source,
            slot.offset,
            slot.end,
            slot.revision,
            slot.workspace,
            slot.new_name,
            slot.query,
            slot.diagnostics,
            slot.tab_size,
            slot.trigger,
        )
        if dispatched == 0 {
            // The backend stopped claiming the kind between the reserve and here
            // — a server that died, a feature switched off. The caller stored the
            // reserved id already, so answer it rather than leave the slot stale.
            append(&m.failed, Result{id = slot.id, kind = kind})
            continue
        }
        n += 1
    }
    return n
}

// True while a job of `kind` is dispatched but not yet reaped. Counts cancelled
// jobs too, unlike manager_busy_kinds: cancellation is cooperative, so a job
// already inside an uninterruptible step holds its resources until it returns.
@(private)
kind_inflight :: proc(m: ^Manager, kind: Request_Kind) -> bool {
    sync.lock(&m.mutex)
    defer sync.unlock(&m.mutex)
    for _, job in m.active {
        if job.request.kind == kind {
            return true
        }
    }
    return false
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
    delete(p.query)
    free_diagnostic_refs(p.diagnostics)
    delete(p.trigger)
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

// Drains finished jobs on the main thread: invokes `handler(user, ^Result)`,
// then frees the job and everything it owns, so the handler must copy what it
// keeps past the call. A cancelled job is freed without reaching the handler —
// its result was superseded and may be partial. Debounced requests are
// dispatched first, so this one per-frame call drives both ends.
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

    // Reserved ids no job was ever built for. Answered like any other empty
    // result, which is what clears the caller's request slot.
    for &res in m.failed {
        if handler != nil {
            handler(user, &res)
        }
        result_free(m, &res)
    }
    clear(&m.failed)

    // Results no request asked for. Gated like a dispatch, so a kind the user
    // turned off cannot arrive through the back door. Bounded per backend, so a
    // backend that always answers true costs one frame's latency and not the
    // frame itself.
    for b in m.backends {
        if b.poll == nil {
            continue
        }
        for _ in 0 ..< POLL_MAX_PER_FRAME {
            res: Result
            if !b.poll(b.data, &res) {
                break
            }
            if handler != nil && manager_feature_enabled(m, res.kind) {
                handler(user, &res)
            } else if res.on_applied != nil {
                // Apply_Edit only: a drain with no handler, or the kind gated
                // off mid-flight. Answer "not applied" ourselves, same as
                // server_drop_push does for a push nobody took off its own
                // queue, so the reader thread blocked on it is never left
                // waiting.
                res.on_applied(res.token, false)
            }
            result_free(m, &res)
        }
    }
}

@(private)
job_free :: proc(m: ^Manager, job: ^Job) {
    context.allocator = m.allocator
    delete(job.request.path)
    delete(job.request.ext)
    delete(job.request.source)
    delete(job.request.workspace)
    delete(job.request.command)
    delete(job.request.command_args)
    delete(job.request.item)
    delete(job.request.new_name)
    delete(job.request.query)
    free_diagnostic_refs(job.request.diagnostics)
    delete(job.request.trigger)
    result_free(m, &job.result)
    id := job.request.id
    free(job)

    sync.lock(&m.mutex)
    delete_key(&m.active, id) // no longer cancellable; the pointer is dead
    m.inflight -= 1
    sync.unlock(&m.mutex)
}

// Frees every owned field of a Result. The Manager's allocator owns them, so
// this runs on the main thread once the editor has consumed the result.
@(private)
result_free :: proc(m: ^Manager, res: ^Result) {
    context.allocator = m.allocator
    delete(res.location.path)
    delete(res.hover.text)
    delete(res.doc.title)
    delete(res.doc.path)
    delete(res.doc.text)
    for entry in res.signature.entries {
        delete(entry.label)
    }
    delete(res.signature.entries)
    for sym in res.symbols {
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(sym.path)
    }
    delete(res.symbols)
    for item in res.completions {
        delete(item.label)
        delete(item.kind)
        delete(item.detail)
        delete(item.insert)
        delete(item.filter)
        delete(item.sort)
        delete(item.command)
        delete(item.arguments)
        delete(item.raw)
        for edit in item.extra_edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(item.extra_edits)
    }
    delete(res.completions)
    for edit in res.edits {
        delete(edit.path)
        delete(edit.old_text)
        delete(edit.new_text)
    }
    delete(res.edits)
    for op in res.resource_ops {
        delete(op.path)
        delete(op.new_path)
    }
    delete(res.resource_ops)
    for action in res.actions {
        delete(action.title)
        delete(action.kind)
        delete(action.command)
        delete(action.arguments)
        for edit in action.edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(action.edits)
        for op in action.resource_ops {
            delete(op.path)
            delete(op.new_path)
        }
        delete(action.resource_ops)
    }
    delete(res.actions)
    delete(res.tokens) // no owned strings on a token; the array is the whole allocation
    delete(res.report.scope)
    for d in res.report.items {
        delete(d.path)
        delete(d.message)
    }
    delete(res.report.items)
    delete(res.progress.message)
}

// True while any request is still being worked. Used by manager_destroy and
// available to the editor for a "busy" indicator.
manager_busy :: proc(m: ^Manager) -> bool {
    sync.lock(&m.mutex)
    defer sync.unlock(&m.mutex)
    return m.inflight > 0
}

// The kinds of the requests in flight (queued or being worked), so a busy
// indicator can name the work. A cancelled request is left out: it is on its
// way to being dropped, and nothing waits for it. Debounced requests are not
// counted either — they have not been dispatched yet.
manager_busy_kinds :: proc(m: ^Manager) -> (kinds: bit_set[Request_Kind]) {
    sync.lock(&m.mutex)
    defer sync.unlock(&m.mutex)
    for _, job in m.active {
        if request_cancelled(&job.request) {
            continue
        }
        kinds += {job.request.kind}
    }
    return
}

// Drains in-flight jobs, stops the worker pool so no thread touches freed
// backend state, tears down each backend and frees the Manager's storage. Every
// request is cancelled first, so a workspace scan started just before quit bails
// at its next check; that also empties the debounce slots, so the drain loop
// cannot keep dispatching new work.
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
    delete(m.failed)
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
