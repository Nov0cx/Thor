// One language server: its process, its handshake, its documents and its death.
//
// Three threads meet here. The main thread queues document events and never
// blocks on a server. A worker thread inside `resolve` waits for a start. And one
// pump thread per server does everything that can block on a pipe — it spawns the
// child, runs the handshake, drains the outbox and restarts a server that died.
// State the other two read is published with `sync.atomic_store`: `state` while it
// runs, and `caps`, which is written before `state` becomes .Ready and never
// again, so `supports` reads it with no lock.
package lsp

import "base:runtime"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import lang ".."
import "../../shell"

// How long a start may take before the server is given up on. A cold clangd
// indexing a large project answers `initialize` well inside it.
DEADLINE_START :: 10 * time.Second

// How long `shutdown` may take before the process is killed instead.
DEADLINE_EXIT :: 2 * time.Second

// How many times a server that died on its own is started again, and the wait
// before each. A server that crashes on the file the user is editing would
// otherwise be restarted forever.
RESTART_LIMIT :: 3
RESTART_BACKOFF := [RESTART_LIMIT]time.Duration{1 * time.Second, 4 * time.Second, 16 * time.Second}

// How often a waiting worker looks at the state again.
@(private)
READY_SLICE :: 5 * time.Millisecond

Server_State :: enum {
    Idle,     // nothing has needed it yet
    Starting, // the pump has it; the handshake is running
    Ready,
    Stopping,
    Crashed, // it died and is waiting out its backoff
    Failed,  // it will not be started again this session
}

// One document event on its way to the server. The source is copied because the
// buffer it came from is borrowed for the call only.
@(private)
Doc_Notice :: struct {
    event:    lang.Doc_Event,
    path:     string, // owned
    ext:      string, // owned
    source:   string, // owned; empty for Saved and Closed
    revision: u64,
}

Server :: struct {
    config:      ^Server_Config, // borrowed from the Client's Config
    workspace:   string,         // owned
    root:        string,         // owned; chosen at the first start
    folders:     string,         // owned; the workspaceFolders array, as JSON text
    allocator:   runtime.Allocator,
    state:       Server_State, // atomic
    caps:        Capabilities, // written before state becomes .Ready, never after
    // The pump, and the lock that makes two starters one.
    start_mutex: sync.Mutex,
    started:     bool,           // guarded by start_mutex
    pump:        ^thread.Thread, // owned; guarded by start_mutex
    stopping:    bool,           // atomic
    conn:        ^Conn,          // owned; the pump's, and the main thread's after the join
    // The outbox. `wake` is posted for every entry, so a pump waiting out its
    // slice leaves it at once.
    out_mutex:   sync.Mutex,
    outbox:      [dynamic]Doc_Notice, // owned
    wake:        sync.Sema,
    // The documents the server knows about. The pump thread alone reads and
    // writes them, and the main thread only after it has joined the pump; a
    // request path that reads them (M5) needs a lock here.
    docs:        [dynamic]^Document, // owned
    restarts:    int,                // pump thread only
    // How the process is opened, and what it is opened from. The default starts
    // the configured command; a test replaces it with a scripted server running
    // in this process, which is what makes the lifetime testable with no server
    // installed on any of the four CI platforms.
    open:        proc(s: ^Server) -> (Transport, bool),
    open_data:   rawptr, // borrowed by `open`
}

// A server that is not running. `config` is borrowed and must outlive it.
server_create :: proc(config: ^Server_Config, workspace: string, allocator := context.allocator) -> ^Server {
    s := new(Server, allocator)
    s.config = config
    s.workspace = strings.clone(workspace, allocator)
    s.allocator = allocator
    s.state = .Idle
    s.outbox = make([dynamic]Doc_Notice, allocator)
    s.docs = make([dynamic]^Document, allocator)
    s.open = server_open_child
    return s
}

server_state :: proc(s: ^Server) -> Server_State {
    return sync.atomic_load(&s.state)
}

// Makes sure a pump exists, without waiting for it. `path` is the file that
// needed the server, which is what its root is looked for above. False means the
// server is done for this session.
server_start :: proc(s: ^Server, path: string) -> bool {
    #partial switch server_state(s) {
    case .Failed, .Stopping:
        return false
    case .Starting, .Ready, .Crashed:
        return true
    }

    sync.guard(&s.start_mutex)
    if s.started || sync.atomic_load(&s.state) != .Idle {
        return sync.atomic_load(&s.state) != .Failed
    }
    s.root = server_root(s, path)
    s.folders = folders_json(s.root, s.allocator)
    sync.atomic_store(&s.state, .Starting)
    s.started = true

    // The pump inherits this context for its logger; it never uses the temp
    // allocator, whose arena belongs to the thread that started it.
    pump_context := context
    pump_context.allocator = s.allocator
    s.pump = thread.create_and_start_with_poly_data(s, server_pump, pump_context)
    return true
}

// Starts the server and waits for the handshake. Called on a worker thread, which
// may block; false means it will not answer.
server_ensure_started :: proc(s: ^Server, path: string) -> bool {
    if !server_start(s, path) {
        return false
    }
    start := time.tick_now()
    for time.tick_since(start) < DEADLINE_START {
        #partial switch server_state(s) {
        case .Ready:
            return true
        case .Failed, .Stopping:
            return false
        }
        time.sleep(READY_SLICE)
    }
    return false
}

// True when the server is running and its reply said it answers `kind`. While the
// handshake runs the answer is yes for everything it is configured for:
// otherwise the first requests after a start are swallowed and the user learns
// that a feature works only on the second try. Main thread, no lock.
server_supports :: proc(s: ^Server, kind: lang.Request_Kind) -> bool {
    if kind not_in s.config.features {
        return false
    }
    #partial switch server_state(s) {
    case .Idle, .Starting, .Crashed:
        return true
    case .Ready:
        return kind in s.caps.kinds
    }
    return false
}

// Queues a document event and returns. Main thread: it must never wait on a
// server, so nothing here touches the connection.
server_notify :: proc(s: ^Server, event: lang.Doc_Event, path, ext, source: string, revision: u64) {
    #partial switch server_state(s) {
    case .Failed, .Stopping:
        return
    }
    if event == .Opened {
        server_start(s, path)
    }

    notice := Doc_Notice {
        event    = event,
        path     = strings.clone(path, s.allocator),
        ext      = strings.clone(ext, s.allocator),
        revision = revision,
    }
    if event == .Opened || event == .Changed {
        notice.source = strings.clone(source, s.allocator)
    }

    sync.lock(&s.out_mutex)
    // A change that has not been sent yet is replaced by the newer one: only the
    // last text is worth sending, and a stalled server must not grow the queue
    // for every keystroke.
    replaced := false
    if event == .Changed {
        for &queued in s.outbox {
            if queued.event != .Changed || !path_equal(queued.path, path) {
                continue
            }
            delete(queued.source, s.allocator)
            queued.source = notice.source
            queued.revision = notice.revision
            replaced = true
            break
        }
    }
    if replaced {
        delete(notice.path, s.allocator)
        delete(notice.ext, s.allocator)
    } else {
        append(&s.outbox, notice)
    }
    sync.unlock(&s.out_mutex)
    sync.sema_post(&s.wake)
}

// Ends the server: the pump leaves, the protocol's own goodbye is sent, and the
// process is killed if it does not go. Main thread, once, with no worker in
// flight.
server_stop :: proc(s: ^Server) {
    sync.atomic_store(&s.stopping, true)
    sync.atomic_store(&s.state, .Stopping)

    sync.lock(&s.start_mutex)
    pump := s.pump
    s.pump = nil
    s.started = false
    sync.unlock(&s.start_mutex)

    if pump != nil {
        sync.sema_post(&s.wake)
        thread.join(pump)
        thread.destroy(pump)
    }
    // The pump is gone, so the connection and the documents are this thread's.
    if s.conn != nil {
        server_goodbye(s)
        conn_destroy(s.conn)
        s.conn = nil
    }
}

// Frees the server. server_stop must have run.
server_destroy :: proc(s: ^Server) {
    for doc in s.docs {
        document_destroy(doc)
        free(doc, s.allocator)
    }
    delete(s.docs)
    server_drop_outbox(s)
    delete(s.outbox)
    delete(s.workspace, s.allocator)
    delete(s.root, s.allocator)
    delete(s.folders, s.allocator)
    free(s, s.allocator)
}

// The pump. It owns the connection and the documents for its whole life.
@(private)
server_pump :: proc(s: ^Server) {
    for {
        if !server_launch(s) {
            sync.atomic_store(&s.state, .Failed)
            server_drop_outbox(s)
            return
        }
        sync.atomic_store(&s.state, .Ready)
        log.debugf("lsp: %s started, answering %v", s.config.id, s.caps.kinds)

        server_serve(s)
        if sync.atomic_load(&s.stopping) {
            return
        }

        // The connection ended without anyone asking it to.
        server_teardown(s)
        if s.restarts >= RESTART_LIMIT {
            log.warnf("lsp: %s died %d times and will not be started again", s.config.id, s.restarts + 1)
            sync.atomic_store(&s.state, .Failed)
            server_drop_outbox(s)
            return
        }
        sync.atomic_store(&s.state, .Crashed)
        log.warnf("lsp: %s died; restarting", s.config.id)
        if !server_backoff(s, RESTART_BACKOFF[s.restarts]) {
            return
        }
        s.restarts += 1
        sync.atomic_store(&s.state, .Starting)
    }
}

// Spawns the process and runs the handshake. The documents of a server that died
// are opened again, so a restart is invisible above this line.
@(private)
server_launch :: proc(s: ^Server) -> bool {
    transport, opened := s.open(s)
    if !opened {
        log.debugf("lsp: %s did not start (%v)", s.config.id, s.config.command)
        return false
    }
    s.conn = conn_start(transport, s.allocator, Conn_Answers{settings = s.config.settings, folders = s.folders})

    params := initialize_params(s)
    result, err := conn_call(s.conn, "initialize", params, DEADLINE_START)
    delete(params, s.allocator)
    if err != .None {
        tail := conn_stderr_tail(s.conn, s.allocator)
        log.warnf("lsp: %s did not answer initialize (%v) %s", s.config.id, err, tail)
        delete(tail, s.allocator)
        conn_free_value(s.conn, result)
        server_teardown(s)
        return false
    }
    s.caps = capabilities_decode(result)
    conn_free_value(s.conn, result)

    conn_notify(s.conn, "initialized", "{}")
    if s.config.settings != "" {
        settings := strings.concatenate({`{"settings":`, s.config.settings, "}"}, s.allocator)
        conn_notify(s.conn, "workspace/didChangeConfiguration", settings)
        delete(settings, s.allocator)
    }
    for doc in s.docs {
        server_send_open(s, doc, language_id_for(filepath.ext(doc.path)))
    }
    return true
}

// Drains the outbox until the server is stopped or the connection ends.
@(private)
server_serve :: proc(s: ^Server) {
    for !sync.atomic_load(&s.stopping) {
        if conn_state(s.conn) == .Closed {
            return
        }
        server_flush(s)
        server_drain_pushes(s)
        sync.sema_wait_with_timeout(&s.wake, POLL_SLICE)
    }
}

// Takes what the server pushed and drops it. A push becomes a lang.Result in M6;
// until then the queue must still be emptied, or a server that publishes
// diagnostics on every keystroke grows it without bound. The pump drains it
// because the pump owns the connection: a main-thread drain would read `conn`
// while a restart replaces it.
@(private)
server_drain_pushes :: proc(s: ^Server) {
    for {
        note, ok := conn_take_notification(s.conn)
        if !ok {
            return
        }
        conn_free_notification(s.conn, note)
    }
}

@(private)
server_flush :: proc(s: ^Server) {
    for {
        sync.lock(&s.out_mutex)
        if len(s.outbox) == 0 {
            sync.unlock(&s.out_mutex)
            return
        }
        notice := s.outbox[0]
        ordered_remove(&s.outbox, 0)
        sync.unlock(&s.out_mutex)

        server_apply(s, notice)
        notice_destroy(s, &notice)
    }
}

// One document event, as the notification the server expects. A capability the
// server did not advertise is not sent: a server that asked for no sync gets no
// sync.
@(private)
server_apply :: proc(s: ^Server, notice: Doc_Notice) {
    switch notice.event {
    case .Opened, .Changed:
        doc := server_document(s, notice.path, notice.source)
        if !doc.open {
            server_send_open(s, doc, language_id_for(notice.ext))
            return
        }
        if s.caps.changes {
            params := did_change_params(doc, s.allocator)
            conn_notify(s.conn, "textDocument/didChange", params)
            delete(params, s.allocator)
        }
    case .Saved:
        doc, found := server_find(s, notice.path)
        if !found || !doc.open || !s.caps.saves {
            return
        }
        params := did_identify_params(doc, s.allocator)
        conn_notify(s.conn, "textDocument/didSave", params)
        delete(params, s.allocator)
    case .Closed:
        doc, found := server_find(s, notice.path)
        if !found {
            return
        }
        if doc.open && s.caps.open_close {
            params := did_identify_params(doc, s.allocator)
            conn_notify(s.conn, "textDocument/didClose", params)
            delete(params, s.allocator)
        }
        server_forget(s, doc)
    }
}

@(private)
server_send_open :: proc(s: ^Server, doc: ^Document, language_id: string) {
    if s.caps.open_close {
        params := did_open_params(doc, language_id, s.allocator)
        conn_notify(s.conn, "textDocument/didOpen", params)
        delete(params, s.allocator)
    }
    doc.open = true
}

// The document for `path`, created at version 1 or moved to the new text.
@(private)
server_document :: proc(s: ^Server, path, text: string) -> ^Document {
    if doc, found := server_find(s, path); found {
        document_set_text(doc, text)
        return doc
    }
    doc := new(Document, s.allocator)
    document_init(doc, path, text, s.caps.encoding, s.allocator)
    append(&s.docs, doc)
    return doc
}

@(private)
server_find :: proc(s: ^Server, path: string) -> (^Document, bool) {
    for doc in s.docs {
        if path_equal(doc.path, path) {
            return doc, true
        }
    }
    return nil, false
}

@(private)
server_forget :: proc(s: ^Server, doc: ^Document) {
    for other, index in s.docs {
        if other != doc {
            continue
        }
        ordered_remove(&s.docs, index)
        break
    }
    document_destroy(doc)
    free(doc, s.allocator)
}

// The protocol's goodbye: `shutdown` and then `exit`. A server that answers
// neither is killed by conn_destroy.
@(private)
server_goodbye :: proc(s: ^Server) {
    if conn_state(s.conn) == .Closed {
        return
    }
    result, _ := conn_call(s.conn, "shutdown", "", DEADLINE_EXIT)
    conn_free_value(s.conn, result)
    conn_notify(s.conn, "exit", "")
}

// Ends a connection that will not be used again, leaving the documents in place
// for the next start to open.
@(private)
server_teardown :: proc(s: ^Server) {
    if s.conn == nil {
        return
    }
    conn_destroy(s.conn)
    s.conn = nil
    for doc in s.docs {
        doc.open = false
    }
}

// Waits out a restart delay, in slices, so a stop does not have to wait for it.
// False means the server was stopped meanwhile.
@(private)
server_backoff :: proc(s: ^Server, delay: time.Duration) -> bool {
    start := time.tick_now()
    for time.tick_since(start) < delay {
        if sync.atomic_load(&s.stopping) {
            return false
        }
        sync.sema_wait_with_timeout(&s.wake, POLL_SLICE)
    }
    return !sync.atomic_load(&s.stopping)
}

@(private)
server_drop_outbox :: proc(s: ^Server) {
    sync.guard(&s.out_mutex)
    for &notice in s.outbox {
        notice_destroy(s, &notice)
    }
    clear(&s.outbox)
}

@(private)
notice_destroy :: proc(s: ^Server, notice: ^Doc_Notice) {
    delete(notice.path, s.allocator)
    delete(notice.ext, s.allocator)
    delete(notice.source, s.allocator)
    notice^ = {}
}

// The default `open`: the configured command as a child process.
@(private)
server_open_child :: proc(s: ^Server) -> (Transport, bool) {
    cmd, resolved := command_resolve(s.config.command, s.allocator)
    if !resolved {
        return {}, false
    }
    defer command_destroy(&cmd)
    return transport_child(
        shell.Child_Spec {
            exe = cmd.exe,
            args = cmd.args,
            cwd = s.config.cwd != "" ? s.config.cwd : s.root,
            env = s.config.env,
        },
    )
}

// The directory the server is rooted at: the nearest one at or above the file
// that holds a configured marker, and the workspace when none does. A server is
// started once, so the first file that needs it decides.
@(private)
server_root :: proc(s: ^Server, path: string) -> string {
    // filepath.dir borrows from `path`, and every step up is a slice of that same
    // string, so the walk allocates only the paths it stats.
    dir := filepath.dir(path)
    for at := dir; len(s.config.root_markers) > 0 && at != ""; {
        if has_marker(at, s.config.root_markers, s.allocator) {
            return strings.clone(at, s.allocator)
        }
        separator := strings.last_index_any(at, "/\\")
        if separator <= 0 {
            break
        }
        at = at[:separator]
    }

    if s.workspace != "" {
        return strings.clone(s.workspace, s.allocator)
    }
    return strings.clone(dir, s.allocator)
}

@(private)
has_marker :: proc(dir: string, markers: []string, allocator: runtime.Allocator) -> bool {
    for marker in markers {
        path, err := filepath.join({dir, marker}, allocator)
        if err != nil {
            continue
        }
        found := os.exists(path)
        delete(path, allocator)
        if found {
            return true
        }
    }
    return false
}

// [{"uri":...,"name":...}], the answer to workspace/workspaceFolders and part of
// the initialize params.
@(private)
folders_json :: proc(root: string, allocator: runtime.Allocator) -> string {
    if root == "" {
        return ""
    }
    uri := uri_from_path(root, allocator)
    defer delete(uri, allocator)
    out := make([dynamic]u8, allocator)
    append(&out, `[{"uri":`)
    write_quoted(&out, uri)
    append(&out, `,"name":`)
    write_quoted(&out, filepath.base(root))
    append(&out, `}]`)
    return string(out[:])
}

@(private)
initialize_params :: proc(s: ^Server) -> string {
    out := make([dynamic]u8, s.allocator)
    append(&out, `{"processId":`)
    write_number(&out, i64(os.get_pid()))
    append(&out, `,"clientInfo":{"name":"Thor"}`)
    if s.root == "" {
        append(&out, `,"rootUri":null,"rootPath":null,"workspaceFolders":null`)
    } else {
        uri := uri_from_path(s.root, s.allocator)
        defer delete(uri, s.allocator)
        append(&out, `,"rootUri":`)
        write_quoted(&out, uri)
        append(&out, `,"rootPath":`)
        write_quoted(&out, s.root)
        append(&out, `,"workspaceFolders":`)
        append(&out, s.folders)
    }
    append(&out, `,"capabilities":`)
    append(&out, CLIENT_CAPABILITIES)
    if s.config.init_options != "" {
        append(&out, `,"initializationOptions":`)
        append(&out, s.config.init_options)
    }
    append(&out, "}")
    return string(out[:])
}

// What Thor can consume, and nothing else: a server that is told the truth here
// does not send shapes that would be dropped. utf-8 is offered first, since a
// server that counts in bytes removes the whole position conversion.
// `resourceOperations: []` is what stops a rename answering with file creations
// and deletions the seam cannot express.
@(private)
CLIENT_CAPABILITIES :: `{` +
`"general":{"positionEncodings":["utf-8","utf-16"]},` +
`"window":{"workDoneProgress":true},` +
`"workspace":{"configuration":true,"workspaceFolders":true,` +
`"didChangeConfiguration":{"dynamicRegistration":false},` +
`"symbol":{"dynamicRegistration":false},` +
`"workspaceEdit":{"documentChanges":true,"resourceOperations":[]}},` +
`"textDocument":{` +
`"synchronization":{"dynamicRegistration":false,"didSave":true,"willSave":false,"willSaveWaitUntil":false},` +
`"completion":{"dynamicRegistration":false,"contextSupport":true,` +
`"completionItem":{"snippetSupport":false,"documentationFormat":["plaintext"],"deprecatedSupport":false,"preselectSupport":false}},` +
`"hover":{"dynamicRegistration":false,"contentFormat":["plaintext","markdown"]},` +
`"signatureHelp":{"dynamicRegistration":false,` +
`"signatureInformation":{"documentationFormat":["plaintext"],"parameterInformation":{"labelOffsetSupport":true}}},` +
`"definition":{"dynamicRegistration":false,"linkSupport":true},` +
`"references":{"dynamicRegistration":false},` +
`"documentSymbol":{"dynamicRegistration":false,"hierarchicalDocumentSymbolSupport":true},` +
`"codeAction":{"dynamicRegistration":false,` +
`"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["quickfix","refactor","source"]}},` +
`"resolveSupport":{"properties":["edit"]}},` +
`"rename":{"dynamicRegistration":false,"prepareSupport":true},` +
`"publishDiagnostics":{"relatedInformation":false,"versionSupport":true},` +
`"semanticTokens":{"dynamicRegistration":false,"requests":{"full":true},"formats":["relative"],` +
`"tokenModifiers":[],` +
`"tokenTypes":["namespace","type","class","enum","interface","struct","typeParameter","parameter",` +
`"variable","property","enumMember","event","function","method","macro","keyword","modifier",` +
`"comment","string","number","regexp","operator"]}}}`
