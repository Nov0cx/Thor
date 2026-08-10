// One round trip per request kind: the method it is sent as, the params it
// carries, and the connection it goes over. The reply is read in decode.odin.
//
// Everything here runs on a pool worker, which may block. The connection is held
// shared for the whole trip, so the pump cannot free it under a request, and the
// server's copy of the file is brought up to date first — the pump sends document
// events on its own schedule, and a position against text the server does not
// have is silently the wrong position.
package lsp

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
// here: Package_Doc has no LSP method at all, and the rest belong to later
// milestones.
@(private)
METHODS := [lang.Request_Kind]string {
    .Definition        = "textDocument/definition",
    .Hover             = "textDocument/hover",
    .Document_Symbols  = "textDocument/documentSymbol",
    .Workspace_Symbols = "",
    .References        = "textDocument/references",
    .Signature_Help    = "textDocument/signatureHelp",
    .Completion        = "textDocument/completion",
    .Package_Doc       = "",
    .Rename            = "",
    .Diagnostics       = "",
    .Code_Actions      = "",
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

// The params of one request. Every kind names the document; all but the
// whole-file ones name a position in it as well.
@(private)
request_params :: proc(ask: ^Ask) -> string {
    out := make([dynamic]u8, context.temp_allocator)
    append(&out, `{"textDocument":{"uri":`)
    write_quoted(&out, ask.uri)
    append(&out, `}`)

    #partial switch ask.req.kind {
    case .Document_Symbols, .Semantic_Tokens:
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
    }
    append(&out, `}`)
    return string(out[:])
}

@(private)
request_deadline :: proc(kind: lang.Request_Kind) -> time.Duration {
    #partial switch kind {
    case .Document_Symbols, .References, .Semantic_Tokens:
        return DEADLINE_HEAVY
    }
    return DEADLINE_INTERACTIVE
}

// The LF-collapsed text of a file, read once per request. The request's own file
// needs no read: its buffer came with it.
@(private)
ask_source :: proc(ask: ^Ask, path: string) -> (string, bool) {
    if path_equal(path, ask.req.path) {
        return ask.req.source, true
    }
    if text, found := ask.texts[path]; found {
        return text, text != ""
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
