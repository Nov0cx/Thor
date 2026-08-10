// The JSON-RPC client core over a Transport: framing, id correlation and the two
// threads a server needs. It knows the base protocol and nothing above it — no
// initialize, no capabilities, no documents — so a test drives it with a scripted
// server and no child process.
package lsp

import "base:runtime"
import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// How much of a stream one read takes.
READ_CHUNK :: 16 * 1024

// How long a waiter sleeps before it looks at its cancel flag and its deadline.
POLL_SLICE :: 25 * time.Millisecond

// How long a close waits for a server to end on its own before the kill.
CLOSE_GRACE :: 1 * time.Second

// The largest tail of the server's log that is kept. Oldest bytes are dropped.
STDERR_TAIL :: 8 * 1024

Rpc_Error :: enum {
    None,
    Timeout,          // the deadline ran out; the server may still answer
    Cancelled,        // the caller's flag went up; $/cancelRequest was sent
    Transport_Closed, // the end of the stream or a failed write
    Server_Error,     // the reply carried "error"
    Bad_Message,      // a reply with neither "result" nor "error"
}

Conn_State :: enum {
    Open,
    Closed,
}

// One reply a caller waits for. The pending map is the token of ownership:
// whoever removes the entry under `pending_mutex` owns the Pending and frees it.
Pending :: struct {
    id:    i64,
    done:  sync.Sema,
    value: json.Value, // owned by conn.allocator; valid once `done` is posted
    error: Rpc_Error,
}

// One message the server sent without being asked.
Notification :: struct {
    method: string,     // owned by conn.allocator
    params: json.Value, // owned by conn.allocator; nil when the message had none
}

// What the reader thread answers the two requests a server makes of its client
// with, as JSON text. Both are borrowed for the connection's whole life and read
// with no lock, so the owner sets them before the connection starts and never
// changes them.
Conn_Answers :: struct {
    settings: string, // the configured `settings` object; "" answers null
    folders:  string, // the workspaceFolders array; "" answers null
    // workspace/applyEdit: decodes params["edit"] and routes it through the
    // Manager's push channel for a main-thread apply. Runs on the reader
    // thread and may block for a bounded wait; nil answers every edit refused
    // (this package's test doubles, which have no Server behind them).
    apply_edit:      proc(data: rawptr, params: json.Value) -> bool,
    apply_edit_data: rawptr, // borrowed; passed to apply_edit as `data`
}

// One JSON-RPC connection over a Transport, which it owns. A reader thread takes
// the frames and a second thread drains the server's log.
Conn :: struct {
    transport:     Transport,
    allocator:     runtime.Allocator,
    answers:       Conn_Answers, // borrowed; immutable for the connection's life
    reader:        ^thread.Thread, // owned
    draining:      ^thread.Thread, // owned; stderr
    stopped:       bool,           // main thread only; conn_close has run
    write_mutex:   sync.Mutex,     // one writer; the reader answers the server too
    pending_mutex: sync.Mutex,
    pending:       map[i64]^Pending, // owned
    next_id:       i64,
    notify_mutex:  sync.Mutex,
    notifications: [dynamic]Notification, // owned
    stderr_mutex:  sync.Mutex,
    stderr_tail:   [dynamic]u8, // owned
    state:         Conn_State,   // atomic
}

// Takes ownership of `transport` and starts both threads.
conn_start :: proc(transport: Transport, allocator := context.allocator, answers := Conn_Answers{}) -> ^Conn {
    c := new(Conn, allocator)
    c.transport = transport
    c.allocator = allocator
    c.answers = answers
    c.pending = make(map[i64]^Pending, allocator = allocator)
    c.notifications = make([dynamic]Notification, allocator)
    c.stderr_tail = make([dynamic]u8, allocator)
    c.state = .Open
    c.reader = thread.create_and_start_with_poly_data(c, conn_reader)
    c.draining = thread.create_and_start_with_poly_data(c, conn_stderr_drain)
    return c
}

conn_state :: proc(c: ^Conn) -> Conn_State {
    return sync.atomic_load(&c.state)
}

// Sends a request and waits for its reply. `params` is JSON text and is left out
// when empty. A deadline of 0 waits until the reply, the cancel flag or the end
// of the stream. The returned value is the reply's "result", or its "error"
// object when the error is .Server_Error, and is the caller's to free with
// conn_free_value.
conn_call :: proc(
    c: ^Conn,
    method: string,
    params: string,
    deadline: time.Duration,
    cancel: ^bool = nil,
) -> (
    json.Value,
    Rpc_Error,
) {
    p := new(Pending, c.allocator)

    // The registration and the state are read under one lock, so a connection
    // that ends here cannot leave a Pending nobody posts.
    sync.lock(&c.pending_mutex)
    if sync.atomic_load(&c.state) == .Closed {
        sync.unlock(&c.pending_mutex)
        free(p, c.allocator)
        return nil, .Transport_Closed
    }
    c.next_id += 1
    p.id = c.next_id
    c.pending[p.id] = p
    sync.unlock(&c.pending_mutex)

    body := make([dynamic]u8, c.allocator)
    envelope_request(&body, p.id, method, params)
    written := conn_write(c, body[:])
    delete(body)
    if !written {
        conn_give_up(c, p)
        return nil, .Transport_Closed
    }

    start := time.tick_now()
    for {
        if sync.sema_wait_with_timeout(&p.done, POLL_SLICE) {
            value, err := p.value, p.error
            free(p, c.allocator)
            return value, err
        }
        if cancel != nil && sync.atomic_load(cancel) {
            digits: [32]u8
            cancel_params := strings.concatenate(
                {`{"id":`, string(strconv.write_int(digits[:], p.id, 10)), `}`},
                c.allocator,
            )
            // A cancellation that does not reach a dead server changes nothing:
            // the caller gave up either way.
            _ = conn_notify(c, "$/cancelRequest", cancel_params)
            delete(cancel_params, c.allocator)
            conn_give_up(c, p)
            return nil, .Cancelled
        }
        if deadline > 0 && time.tick_since(start) >= deadline {
            conn_give_up(c, p)
            return nil, .Timeout
        }
    }
}

// Sends a notification. `params` is JSON text and is left out when empty.
conn_notify :: proc(c: ^Conn, method: string, params: string) -> bool {
    if conn_state(c) == .Closed {
        return false
    }
    body := make([dynamic]u8, c.allocator)
    defer delete(body)
    envelope_notification(&body, method, params)
    return conn_write(c, body[:])
}

// Takes the oldest message the server pushed. The caller frees it with
// conn_free_notification.
conn_take_notification :: proc(c: ^Conn) -> (Notification, bool) {
    sync.guard(&c.notify_mutex)
    if len(c.notifications) == 0 {
        return {}, false
    }
    note := c.notifications[0]
    ordered_remove(&c.notifications, 0)
    return note, true
}

conn_free_value :: proc(c: ^Conn, value: json.Value) {
    json.destroy_value(value, c.allocator)
}

conn_free_notification :: proc(c: ^Conn, note: Notification) {
    delete(note.method, c.allocator)
    json.destroy_value(note.params, c.allocator)
}

// A copy of the last bytes the server logged, for a handshake that failed.
conn_stderr_tail :: proc(c: ^Conn, allocator := context.allocator) -> string {
    sync.guard(&c.stderr_mutex)
    return strings.clone(string(c.stderr_tail[:]), allocator)
}

// Ends the connection: every waiter fails, the server's input closes, and both
// threads are joined. The kill is what frees a reader parked on a server that
// ignores a closed stdin. Runs once, on the main thread.
conn_close :: proc(c: ^Conn) {
    if c.stopped {
        return
    }
    c.stopped = true
    conn_fail(c)
    c.transport.close(c.transport.data)
    start := time.tick_now()
    for time.tick_since(start) < CLOSE_GRACE {
        if thread.is_done(c.reader) && thread.is_done(c.draining) {
            break
        }
        time.sleep(5 * time.Millisecond)
    }
    c.transport.terminate(c.transport.data)
    thread.join(c.reader)
    thread.join(c.draining)
}

// Releases the transport and everything the Conn owns. Closes first when the
// caller did not.
conn_destroy :: proc(c: ^Conn) {
    conn_close(c)
    thread.destroy(c.reader)
    thread.destroy(c.draining)
    c.transport.destroy(c.transport.data)
    for note in c.notifications {
        conn_free_notification(c, note)
    }
    delete(c.notifications)
    delete(c.pending)
    delete(c.stderr_tail)
    free(c, c.allocator)
}

// An i64 out of a JSON number. A server may legally send an id as 1.0, so a
// Float that is exactly whole is accepted.
number :: proc(value: json.Value) -> (i64, bool) {
    #partial switch v in value {
    case json.Integer:
        return i64(v), true
    case json.Float:
        whole := i64(v)
        return whole, f64(whole) == f64(v)
    }
    return 0, false
}

// {"jsonrpc":"2.0","id":N,"method":"M","params":P}
@(private)
envelope_request :: proc(out: ^[dynamic]u8, id: i64, method: string, params: string) {
    digits: [32]u8
    append(out, `{"jsonrpc":"2.0","id":`)
    append(out, strconv.write_int(digits[:], id, 10))
    append(out, `,"method":`)
    write_quoted(out, method)
    if params != "" {
        append(out, `,"params":`)
        append(out, params)
    }
    append(out, "}")
}

// {"jsonrpc":"2.0","method":"M","params":P}
@(private)
envelope_notification :: proc(out: ^[dynamic]u8, method: string, params: string) {
    append(out, `{"jsonrpc":"2.0","method":`)
    write_quoted(out, method)
    if params != "" {
        append(out, `,"params":`)
        append(out, params)
    }
    append(out, "}")
}

// {"jsonrpc":"2.0","id":I,"result":R}. `id` is the raw text of the server's id,
// which JSON-RPC allows to be a string, so it is echoed and never re-typed.
@(private)
envelope_response :: proc(out: ^[dynamic]u8, id: string, result: string) {
    append(out, `{"jsonrpc":"2.0","id":`)
    append(out, id)
    append(out, `,"result":`)
    append(out, result)
    append(out, "}")
}

// {"jsonrpc":"2.0","id":I,"error":{"code":C,"message":"M"}}
@(private)
envelope_error :: proc(out: ^[dynamic]u8, id: string, code: i64, message: string) {
    digits: [32]u8
    append(out, `{"jsonrpc":"2.0","id":`)
    append(out, id)
    append(out, `,"error":{"code":`)
    append(out, strconv.write_int(digits[:], code, 10))
    append(out, `,"message":`)
    write_quoted(out, message)
    append(out, "}}")
}

// A JSON string literal. Method names are our own ASCII, but a message this
// package echoes back is not, so every escape a server can send is handled.
@(private)
write_quoted :: proc(out: ^[dynamic]u8, text: string) {
    digits := "0123456789abcdef"
    append(out, "\"")
    for index in 0 ..< len(text) {
        letter := text[index]
        switch letter {
        case '"':
            append(out, "\\\"")
        case '\\':
            append(out, "\\\\")
        case '\b':
            append(out, "\\b")
        case '\f':
            append(out, "\\f")
        case '\n':
            append(out, "\\n")
        case '\r':
            append(out, "\\r")
        case '\t':
            append(out, "\\t")
        case:
            if letter < 0x20 {
                append(out, "\\u00")
                append(out, digits[letter >> 4])
                append(out, digits[letter & 0xf])
            } else {
                append(out, letter)
            }
        }
    }
    append(out, "\"")
}

// Frames a body and writes it. One writer at a time: the reader thread answers
// the server's own requests over the same stream.
@(private = "file")
conn_write :: proc(c: ^Conn, body: []u8) -> bool {
    out := make([dynamic]u8, c.allocator)
    defer delete(out)
    frame_write(&out, body)
    sync.guard(&c.write_mutex)
    return c.transport.write(c.transport.data, out[:])
}

// Takes the Pending out of the map, which is what claims it. A miss is the
// normal case of a waiter that already gave up.
@(private = "file")
conn_claim :: proc(c: ^Conn, id: i64) -> ^Pending {
    sync.guard(&c.pending_mutex)
    p, found := c.pending[id]
    if !found {
        return nil
    }
    delete_key(&c.pending, id)
    return p
}

// A waiter that timed out or was cancelled. The entry still in the map means the
// reader can no longer reach the Pending; its absence means the reader claimed it
// and will post, so the last wait cannot block for long.
@(private = "file")
conn_give_up :: proc(c: ^Conn, p: ^Pending) {
    sync.lock(&c.pending_mutex)
    _, ours := c.pending[p.id]
    delete_key(&c.pending, p.id)
    sync.unlock(&c.pending_mutex)
    if !ours {
        sync.sema_wait(&p.done)
        json.destroy_value(p.value, c.allocator)
    }
    free(p, c.allocator)
}

// The end of the stream, which is the server's death. Every waiter fails at once;
// without it a crash hangs a pool worker until its deadline.
@(private = "file")
conn_fail :: proc(c: ^Conn) {
    sync.lock(&c.pending_mutex)
    sync.atomic_store(&c.state, Conn_State.Closed)
    for _, p in c.pending {
        p.error = .Transport_Closed
        sync.sema_post(&p.done)
    }
    clear(&c.pending)
    sync.unlock(&c.pending_mutex)
}

@(private = "file")
conn_reader :: proc(c: ^Conn) {
    context.allocator = c.allocator
    buf := make([dynamic]u8, c.allocator)
    defer delete(buf)
    chunk: [READ_CHUNK]u8
    for {
        for {
            body, frame_err, ok := frame_take(&buf, c.allocator)
            if frame_err != .None {
                // The stream cannot resynchronise from a broken frame, so it is
                // the end of the connection just as much as an EOF is.
                conn_fail(c)
                return
            }
            if !ok {
                break
            }
            conn_route(c, body)
            delete(body, c.allocator)
        }
        read := c.transport.read_out(c.transport.data, chunk[:])
        if read <= 0 {
            conn_fail(c)
            return
        }
        append(&buf, ..chunk[:read])
    }
}

@(private = "file")
conn_stderr_drain :: proc(c: ^Conn) {
    context.allocator = c.allocator
    chunk: [READ_CHUNK]u8
    for {
        read := c.transport.read_err(c.transport.data, chunk[:])
        if read <= 0 {
            return
        }
        sync.lock(&c.stderr_mutex)
        append(&c.stderr_tail, ..chunk[:read])
        if len(c.stderr_tail) > STDERR_TAIL {
            remove_range(&c.stderr_tail, 0, len(c.stderr_tail) - STDERR_TAIL)
        }
        sync.unlock(&c.stderr_mutex)
    }
}

// One message: a reply to a waiter, a request the server wants answered, or a
// push. A frame that is not a JSON-RPC message is dropped.
@(private = "file")
conn_route :: proc(c: ^Conn, body: []u8) {
    value, parse_err := json.parse(body, spec = .JSON, parse_integers = true, allocator = c.allocator)
    if parse_err != .None {
        json.destroy_value(value, c.allocator)
        return
    }
    object, is_object := &value.(json.Object)
    if !is_object {
        json.destroy_value(value, c.allocator)
        return
    }

    method, has_method := object["method"].(json.String)
    id_value, has_id := object["id"]
    switch {
    case has_method && has_id:
        conn_answer(c, method, id_value, object["params"])
        json.destroy_value(value, c.allocator)
    case has_method:
        conn_push(c, object)
        json.destroy_value(value, c.allocator)
    case has_id:
        conn_reply(c, id_value, object)
        json.destroy_value(value, c.allocator)
    case:
        json.destroy_value(value, c.allocator)
    }
}

// A reply to one of our requests. "result" is detached from the tree before the
// rest is freed, so the waiter gets it with one parse and one free path.
@(private = "file")
conn_reply :: proc(c: ^Conn, id_value: json.Value, object: ^json.Object) {
    id, ok := number(id_value)
    if !ok {
        return
    }
    p := conn_claim(c, id)
    if p == nil {
        return
    }
    if error_value, has_error := object["error"]; has_error {
        // The error object is handed over in place of the result, so the caller
        // logs the server's own code and message.
        p.error = .Server_Error
        p.value = error_value
        object["error"] = nil
    } else if result, has_result := object["result"]; has_result {
        p.value = result
        object["result"] = nil
    } else {
        p.error = .Bad_Message
    }
    sync.sema_post(&p.done)
}

// A message the server sent without being asked. The method and the params are
// detached from the tree, so the queue owns them and the rest is freed.
@(private = "file")
conn_push :: proc(c: ^Conn, object: ^json.Object) {
    note := Notification {
        method = object["method"].(json.String),
        params = object["params"],
    }
    object["method"] = nil
    object["params"] = nil
    sync.guard(&c.notify_mutex)
    append(&c.notifications, note)
}

// A request the server waits on, answered on the reader thread. A server blocks
// until each of these is answered, so an unknown method gets an error and never
// silence.
@(private = "file")
conn_answer :: proc(c: ^Conn, method: string, id_value: json.Value, params: json.Value) {
    echo := make([dynamic]u8, c.allocator)
    defer delete(echo)
    if !id_text(&echo, id_value) {
        return
    }
    id := string(echo[:])

    out := make([dynamic]u8, c.allocator)
    defer delete(out)
    switch method {
    case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create":
        // No dynamic registration and no progress UI, so both are accepted and
        // ignored.
        envelope_response(&out, id, "null")
    case "workspace/applyEdit":
        // Applying needs a main-thread hop and buffer verification, done by
        // whoever set apply_edit (the owning Server); refusing with no
        // handler wired is still honest.
        applied := c.answers.apply_edit != nil && c.answers.apply_edit(c.answers.apply_edit_data, params)
        envelope_response(&out, id, applied ? `{"applied":true}` : `{"applied":false}`)
    case "workspace/configuration":
        // Every item gets the same answer: the server's configured settings.
        // Which section an item asks for is not read, because the config carries
        // one object per server and not one per section.
        settings := c.answers.settings == "" ? "null" : c.answers.settings
        answer := make([dynamic]u8, c.allocator)
        defer delete(answer)
        append(&answer, "[")
        for index in 0 ..< configuration_items(params) {
            if index > 0 {
                append(&answer, ",")
            }
            append(&answer, settings)
        }
        append(&answer, "]")
        envelope_response(&out, id, string(answer[:]))
    case "workspace/workspaceFolders":
        envelope_response(&out, id, c.answers.folders == "" ? "null" : c.answers.folders)
    case:
        envelope_error(&out, id, -32601, "unhandled")
    }
    conn_write(c, out[:])
}

// How many entries a workspace/configuration request asks for. One is assumed
// when the shape is not the expected one, so the server still gets an answer.
@(private = "file")
configuration_items :: proc(params: json.Value) -> int {
    object, is_object := params.(json.Object)
    if !is_object {
        return 1
    }
    items, is_array := object["items"].(json.Array)
    if !is_array || len(items) == 0 {
        return 1
    }
    return len(items)
}

// The raw JSON text of an id. JSON-RPC allows a string id, and the answer must
// carry back the same one.
@(private = "file")
id_text :: proc(out: ^[dynamic]u8, value: json.Value) -> bool {
    #partial switch v in value {
    case json.Integer, json.Float:
        id, ok := number(value)
        if !ok {
            return false
        }
        digits: [32]u8
        append(out, strconv.write_int(digits[:], id, 10))
    case json.String:
        write_quoted(out, string(v))
    case:
        return false
    }
    return true
}
