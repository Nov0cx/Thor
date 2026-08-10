// One round trip per request kind: the method it is sent as, the params it
// carries, and the connection it goes over. The reply is read in decode.odin.
//
// Everything here runs on a pool worker, which may block. The connection is held
// shared for the whole trip, so the pump cannot free it under a request, and the
// server's copy of the file is brought up to date first — the pump sends document
// events on its own schedule, and a position against text the server does not
// have is silently the wrong position.
package lsp

import "core:encoding/json"
import "core:log"
import "core:sync"
import "core:time"

import lang ".."

// How long an interactive request may take. Completion and signature help are
// drawn while the user types, so a slow server must not hold a worker.
DEADLINE_INTERACTIVE :: 3 * time.Second

// How long a whole-file request may take. A cold index answers references and
// semantic tokens well inside it.
DEADLINE_HEAVY :: 15 * time.Second

// The method each kind is sent as. An empty entry is a kind no server answers
// here: Package_Doc has no LSP method at all.
@(private)
METHODS := [lang.Request_Kind]string {
    .Definition        = "textDocument/definition",
    .Hover             = "textDocument/hover",
    .Document_Symbols  = "textDocument/documentSymbol",
    .Workspace_Symbols = "workspace/symbol",
    .References        = "textDocument/references",
    .Signature_Help    = "textDocument/signatureHelp",
    .Completion        = "textDocument/completion",
    .Package_Doc       = "",
    .Rename            = "textDocument/rename",
    .Diagnostics       = "textDocument/diagnostic",
    .Code_Actions      = "textDocument/codeAction",
    .Semantic_Tokens   = "textDocument/semanticTokens/full",
}

// One request in flight, and what it needs to turn positions into byte offsets.
// Everything owned here is on the worker's temp allocator, which the pool frees
// after the job.
@(private)
Ask :: struct {
    server: ^Server,
    conn:   ^Conn,
    req:    ^lang.Request,
    uri:    string,     // the request file's URI
    lines:  Line_Index, // over req.source, in the encoding the server counts in
    texts:  map[string]string,      // path -> LF-collapsed source; one read per file
    raws:   map[string]^Line_Index, // path -> index over the raw disk bytes; nil marks an unreadable file
}

// Sends one request and fills `res` from the reply. A kind with no method, a
// connection that ended, a deadline, a cancel and a reply that named nothing all
// leave res.ok false, which the seam reads as "found nothing".
request_answer :: proc(s: ^Server, req: ^lang.Request, res: ^lang.Result) {
    method := METHODS[req.kind]
    if method == "" {
        return
    }

    sync.rw_mutex_shared_lock(&s.conn_lock)
    defer sync.rw_mutex_shared_unlock(&s.conn_lock)
    if s.conn == nil {
        return
    }
    server_sync_document(s, req)

    ask := Ask {
        server = s,
        conn   = s.conn,
        req    = req,
        uri    = uri_from_path(req.path, context.temp_allocator),
        lines  = line_index_build(req.source, s.caps.encoding, context.temp_allocator),
        texts  = make(map[string]string, allocator = context.temp_allocator),
        raws   = make(map[string]^Line_Index, allocator = context.temp_allocator),
    }

    // A server that advertises prepareProvider gets one veto before the rename
    // itself: a null (or defaultBehavior:false) reply means "not renameable
    // here", and sending textDocument/rename anyway would ask a question the
    // server already answered.
    if req.kind == .Rename && s.caps.prepare_rename && !prepare_rename_ok(&ask) {
        return
    }

    params := request_params(&ask)
    value, err := conn_call(ask.conn, method, params, request_deadline(req.kind), req.cancel)
    defer conn_free_value(ask.conn, value)
    if err != .None {
        if err == .Server_Error || err == .Timeout {
            log.debugf("lsp: %s answered %v to %s", s.config.id, err, method)
        }
        return
    }
    request_decode(&ask, value, res)
}

// The params of one request. Every kind but Workspace_Symbols names the document;
// all but the whole-file ones name a position in it as well.
@(private)
request_params :: proc(ask: ^Ask) -> string {
    // workspace/symbol names no document at all. The query is empty: nothing
    // above the seam carries one, so the server answers with what it indexed.
    if ask.req.kind == .Workspace_Symbols {
        return `{"query":""}`
    }

    out := make([dynamic]u8, context.temp_allocator)
    append(&out, `{"textDocument":{"uri":`)
    write_quoted(&out, ask.uri)
    append(&out, `}`)

    #partial switch ask.req.kind {
    case .Document_Symbols, .Semantic_Tokens, .Diagnostics:
    case .Code_Actions:
        // Request carries only a caret offset, no selection end (lang.odin), so
        // a zero-width range at the caret goes out; a selection-scoped action
        // stays unreachable until Request grows a selection end.
        line, character := position_from_offset(&ask.lines, ask.req.offset)
        append(&out, `,"range":{"start":{"line":`)
        write_number(&out, i64(line))
        append(&out, `,"character":`)
        write_number(&out, i64(character))
        append(&out, `},"end":{"line":`)
        write_number(&out, i64(line))
        append(&out, `,"character":`)
        write_number(&out, i64(character))
        append(&out, `}}`)
    case:
        line, character := position_from_offset(&ask.lines, ask.req.offset)
        append(&out, `,"position":{"line":`)
        write_number(&out, i64(line))
        append(&out, `,"character":`)
        write_number(&out, i64(character))
        append(&out, `}`)
    }

    #partial switch ask.req.kind {
    case .References:
        // A declaration is not a use of itself; Thor's own references drop it.
        append(&out, `,"context":{"includeDeclaration":false}`)
    case .Completion:
        // Invoked: the editor opens the popup, never a trigger character.
        append(&out, `,"context":{"triggerKind":1}`)
    case .Rename:
        append(&out, `,"newName":`)
        write_quoted(&out, ask.req.new_name)
    case .Code_Actions:
        // No live diagnostics are threaded into Ask; a server that needs one to
        // offer a fix (e.g. "add missing import") sees none. Documented v1 gap.
        append(&out, `,"context":{"diagnostics":[]}`)
    }
    append(&out, `}`)
    return string(out[:])
}

// Sends textDocument/prepareRename at the caret. False means "not renameable
// here": an RPC error, a null reply, or an explicit defaultBehavior:false. A
// Range, a {range,placeholder} object or defaultBehavior:true all mean go
// ahead — textDocument/rename itself still verifies the identifier.
@(private)
prepare_rename_ok :: proc(ask: ^Ask) -> bool {
    out := make([dynamic]u8, context.temp_allocator)
    append(&out, `{"textDocument":{"uri":`)
    write_quoted(&out, ask.uri)
    append(&out, `},"position":{"line":`)
    line, character := position_from_offset(&ask.lines, ask.req.offset)
    write_number(&out, i64(line))
    append(&out, `,"character":`)
    write_number(&out, i64(character))
    append(&out, `}}`)

    value, err := conn_call(ask.conn, "textDocument/prepareRename", string(out[:]), DEADLINE_INTERACTIVE, ask.req.cancel)
    defer conn_free_value(ask.conn, value)
    if err != .None {
        return false
    }
    if _, is_null := value.(json.Null); is_null {
        return false
    }
    if object, ok := value.(json.Object); ok {
        if flag, fok := object["defaultBehavior"].(json.Boolean); fok {
            return bool(flag)
        }
    }
    return true
}

@(private)
request_deadline :: proc(kind: lang.Request_Kind) -> time.Duration {
    #partial switch kind {
    case .Document_Symbols, .Workspace_Symbols, .References, .Diagnostics, .Semantic_Tokens:
        return DEADLINE_HEAVY
    }
    return DEADLINE_INTERACTIVE
}

// The LF-collapsed text of a file, read once per request. The request's own file
// needs no read: its buffer came with it. A file the server already holds open
// answers from that buffer, not disk — the server's positions were computed
// against it, and disk can be stale or (as in a workspace-wide rename touching
// an unsaved tab) simply wrong.
@(private)
ask_source :: proc(ask: ^Ask, path: string) -> (string, bool) {
    if path_equal(path, ask.req.path) {
        return ask.req.source, true
    }
    if text, found := ask.texts[path]; found {
        return text, text != ""
    }
    if text, held := server_document_text(ask.server, path, context.temp_allocator); held {
        ask.texts[clone_temp(path)] = text
        return text, true
    }
    text, read := lang.source_read(path, context.temp_allocator)
    ask.texts[clone_temp(path)] = read ? text : ""
    return text, read
}

// The line index of a file as the server read it, CRLF intact, built once per
// request. nil means the file could not be read.
@(private)
ask_raw_index :: proc(ask: ^Ask, path: string) -> ^Line_Index {
    if index, found := ask.raws[path]; found {
        return index
    }
    key := clone_temp(path)
    raw, read := read_raw(path)
    if !read {
        ask.raws[key] = nil
        return nil
    }
    index := new(Line_Index, context.temp_allocator)
    index^ = line_index_build(raw, ask.server.caps.encoding, context.temp_allocator)
    ask.raws[key] = index
    return index
}
