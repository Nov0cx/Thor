package lsp

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Run from the repository root: odin test lang/lsp

// A Transport with no process behind it, so a scripted server runs on every CI
// platform with nothing installed. The whole point of the vtable: the client core
// above it never learns whether a child exists.
// One semaphore per readable stream. A shared one loses a wakeup: the two reader
// threads both wait on it, and the one that takes the post can be the one whose
// stream did not grow.
Mock :: struct {
    mutex:     sync.Mutex,
    out_ready: sync.Sema,   // posted when to_client grows or the mock closes
    err_ready: sync.Sema,   // posted when to_error grows or the mock closes
    to_server: [dynamic]u8, // owned; what the client wrote
    to_client: [dynamic]u8, // owned; what a read_out will take
    to_error:  [dynamic]u8, // owned; what a read_err will take
    closed:    bool,
}

mock_transport :: proc(mock: ^Mock) -> Transport {
    return Transport {
        data = mock,
        write = proc(data: rawptr, bytes: []u8) -> bool {
            mock := (^Mock)(data)
            sync.guard(&mock.mutex)
            if mock.closed {
                return false
            }
            append(&mock.to_server, ..bytes)
            return true
        },
        read_out = proc(data: rawptr, buf: []u8) -> int {
            mock := (^Mock)(data)
            return mock_read(mock, &mock.to_client, &mock.out_ready, buf)
        },
        read_err = proc(data: rawptr, buf: []u8) -> int {
            mock := (^Mock)(data)
            return mock_read(mock, &mock.to_error, &mock.err_ready, buf)
        },
        close = proc(data: rawptr) {
            mock_close((^Mock)(data))
        },
        terminate = proc(data: rawptr) {
            mock_close((^Mock)(data))
        },
        destroy = proc(data: rawptr) {
            mock := (^Mock)(data)
            delete(mock.to_server)
            delete(mock.to_client)
            delete(mock.to_error)
        },
    }
}

// Queues bytes for the client to read, the way a server writing to its stdout
// would. A reader blocked in read_out wakes on it.
mock_send :: proc(mock: ^Mock, bytes: []u8, stdout := true) {
    sync.lock(&mock.mutex)
    append(stdout ? &mock.to_client : &mock.to_error, ..bytes)
    sync.unlock(&mock.mutex)
    sync.sema_post(stdout ? &mock.out_ready : &mock.err_ready)
}

// Ends both streams, the way a dead child's pipes do.
mock_close :: proc(mock: ^Mock) {
    sync.lock(&mock.mutex)
    mock.closed = true
    sync.unlock(&mock.mutex)
    sync.sema_post(&mock.out_ready)
    sync.sema_post(&mock.err_ready)
}

// Takes what the client has written so far. Borrowed from the mock.
mock_written :: proc(mock: ^Mock) -> []u8 {
    sync.guard(&mock.mutex)
    return mock.to_server[:]
}

// Blocks until the stream grows or the mock closes, then takes what fits. 0 means
// the end of the stream, exactly as a dead child's pipe reports it.
@(private = "file")
mock_read :: proc(mock: ^Mock, stream: ^[dynamic]u8, ready: ^sync.Sema, buf: []u8) -> int {
    if len(buf) == 0 {
        return 0
    }
    for {
        sync.lock(&mock.mutex)
        if len(stream) > 0 {
            count := min(len(buf), len(stream))
            copy(buf, stream[:count])
            remove_range(stream, 0, count)
            sync.unlock(&mock.mutex)
            return count
        }
        if mock.closed {
            sync.unlock(&mock.mutex)
            return 0
        }
        sync.unlock(&mock.mutex)
        // A post that arrived before this wait only costs one more turn of the
        // loop, since the streams are re-checked under the lock.
        sync.sema_wait(ready)
    }
}

// Takes what the client has written and clears it, the way a server reading its
// stdin does.
mock_drain :: proc(mock: ^Mock, out: ^[dynamic]u8) {
    sync.guard(&mock.mutex)
    append(out, ..mock.to_server[:])
    clear(&mock.to_server)
}

// Whether the client has written `needle`. Read under the lock: the client's
// write thread appends to the same buffer.
mock_has :: proc(mock: ^Mock, needle: string) -> bool {
    sync.guard(&mock.mutex)
    return strings.contains(string(mock.to_server[:]), needle)
}

// Frames a message and queues it for the client.
mock_frame :: proc(mock: ^Mock, body: string) {
    out := make([dynamic]u8, context.allocator)
    defer delete(out)
    frame_write(&out, transmute([]u8) body)
    mock_send(mock, out[:])
}

mock_reply :: proc(mock: ^Mock, id: i64, result: string) {
    body := fmt.aprintf(`{{"jsonrpc":"2.0","id":%d,"result":%s}}`, id, result)
    defer delete(body)
    mock_frame(mock, body)
}

mock_reply_error :: proc(mock: ^Mock, id: i64, code: i64, message: string) {
    body := fmt.aprintf(`{{"jsonrpc":"2.0","id":%d,"error":{{"code":%d,"message":"%s"}}}}`, id, code, message)
    defer delete(body)
    mock_frame(mock, body)
}

// A scripted server on a thread of its own: it takes every frame the client
// writes, records it, and hands the id and the method to `answer`. The test
// thread stays free to block in conn_call, so the assertions stay there.
Serve :: struct {
    mock:      ^Mock,
    answer:    proc(s: ^Serve, id: i64, method: string),
    data:      rawptr, // the answer's own state
    allocator: runtime.Allocator,
    worker:    ^thread.Thread, // owned
    stop:      bool,           // atomic
    mutex:     sync.Mutex,
    taken:     [dynamic]string, // owned; every body the client sent, in order
}

mock_serve :: proc(s: ^Serve) {
    s.allocator = context.allocator
    s.taken = make([dynamic]string, s.allocator)
    s.worker = thread.create_and_start_with_poly_data(s, serve_worker)
}

// Ends the scripted server. `taken` stays valid until mock_serve_destroy.
mock_serve_stop :: proc(s: ^Serve) {
    sync.atomic_store(&s.stop, true)
    thread.join(s.worker)
    thread.destroy(s.worker)
}

mock_serve_destroy :: proc(s: ^Serve) {
    for body in s.taken {
        delete(body, s.allocator)
    }
    delete(s.taken)
}

@(private = "file")
serve_worker :: proc(s: ^Serve) {
    context.allocator = s.allocator
    buf := make([dynamic]u8, s.allocator)
    defer delete(buf)
    for !sync.atomic_load(&s.stop) {
        mock_drain(s.mock, &buf)
        for {
            body, err, ok := frame_take(&buf, s.allocator)
            if err != .None || !ok {
                break
            }
            serve_dispatch(s, body)
            delete(body, s.allocator)
        }
        time.sleep(time.Millisecond)
    }
}

@(private = "file")
serve_dispatch :: proc(s: ^Serve, body: []u8) {
    sync.lock(&s.mutex)
    append(&s.taken, strings.clone(string(body), s.allocator))
    sync.unlock(&s.mutex)

    value, parse_err := json.parse(body, spec = .JSON, parse_integers = true, allocator = s.allocator)
    defer json.destroy_value(value, s.allocator)
    if parse_err != .None {
        return
    }
    object, is_object := value.(json.Object)
    if !is_object {
        return
    }
    method, _ := object["method"].(json.String)
    id, has_id := number(object["id"])
    if !has_id || s.answer == nil {
        // A notification needs no answer.
        return
    }
    s.answer(s, id, string(method))
}

// A frame written through the transport is the frame the server receives, so the
// two halves of the base protocol agree.
@(test)
test_mock_transport_carries_a_frame :: proc(t: ^testing.T) {
    mock: Mock
    transport := mock_transport(&mock)
    defer transport.destroy(transport.data)

    out := make([dynamic]u8, context.temp_allocator)
    frame_write(&out, transmute([]u8) string(`{"method":"initialize"}`))
    testing.expect(t, transport.write(transport.data, out[:]), "the write failed")

    received := make([dynamic]u8, context.temp_allocator)
    append(&received, ..mock_written(&mock))
    body, err, ok := frame_take(&received, context.temp_allocator)
    testing.expect_value(t, err, Frame_Error.None)
    testing.expect(t, ok)
    testing.expect_value(t, string(body), `{"method":"initialize"}`)
}

// A read is not a message: one frame can arrive in two reads and two frames in
// one, and the parser above the transport must survive both.
@(test)
test_mock_transport_reads_are_not_messages :: proc(t: ^testing.T) {
    mock: Mock
    transport := mock_transport(&mock)
    defer transport.destroy(transport.data)

    whole := make([dynamic]u8, context.temp_allocator)
    frame_write(&whole, transmute([]u8) string("first"))
    split := len(whole) - 2
    mock_send(&mock, whole[:split])

    buf := make([dynamic]u8, context.temp_allocator)
    chunk: [64]u8

    read := transport.read_out(transport.data, chunk[:])
    append(&buf, ..chunk[:read])
    _, err, ok := frame_take(&buf, context.temp_allocator)
    testing.expect_value(t, err, Frame_Error.None)
    testing.expect(t, !ok) // the tail has not arrived

    // The rest of the first frame and a whole second one, in one read.
    rest := make([dynamic]u8, context.temp_allocator)
    append(&rest, ..whole[split:])
    frame_write(&rest, transmute([]u8) string("second"))
    mock_send(&mock, rest[:])

    read = transport.read_out(transport.data, chunk[:])
    append(&buf, ..chunk[:read])
    for want in ([]string{"first", "second"}) {
        body, take_err, take_ok := frame_take(&buf, context.temp_allocator)
        testing.expect_value(t, take_err, Frame_Error.None)
        testing.expectf(t, take_ok, "%q did not come off", want)
        testing.expect_value(t, string(body), want)
    }
}

// stdout and stderr stay apart through the transport too, so a server's log never
// enters the frame stream.
@(test)
test_mock_transport_streams_stay_apart :: proc(t: ^testing.T) {
    mock: Mock
    transport := mock_transport(&mock)
    defer transport.destroy(transport.data)

    mock_send(&mock, transmute([]u8) string("body"), true)
    mock_send(&mock, transmute([]u8) string("log"), false)

    out, err: [64]u8
    out_read := transport.read_out(transport.data, out[:])
    err_read := transport.read_err(transport.data, err[:])
    testing.expect_value(t, string(out[:out_read]), "body")
    testing.expect_value(t, string(err[:err_read]), "log")
}

// The end of the stream is how a dead server is noticed, and it must be reported
// once nothing is left rather than the moment it closes.
@(test)
test_mock_transport_reports_the_end :: proc(t: ^testing.T) {
    mock: Mock
    transport := mock_transport(&mock)
    defer transport.destroy(transport.data)

    mock_send(&mock, transmute([]u8) string("last"))
    transport.close(transport.data)

    buf: [64]u8
    read := transport.read_out(transport.data, buf[:])
    testing.expect_value(t, string(buf[:read]), "last")
    testing.expect_value(t, transport.read_out(transport.data, buf[:]), 0)
    testing.expect_value(t, transport.read_err(transport.data, buf[:]), 0)
    testing.expect(t, !transport.write(transport.data, transmute([]u8) string("x")), "a closed transport took a write")
}

// How long a test waits for a thread to do its work. Far above what any of these
// needs, so a loaded CI runner never fails on timing alone.
@(private = "file")
WAIT_LIMIT :: 5 * time.Second

@(private = "file")
wait_closed :: proc(c: ^Conn) -> bool {
    start := time.tick_now()
    for conn_state(c) != .Closed {
        if time.tick_since(start) >= WAIT_LIMIT {
            return false
        }
        time.sleep(time.Millisecond)
    }
    return true
}

@(private = "file")
wait_notification :: proc(c: ^Conn) -> (Notification, bool) {
    start := time.tick_now()
    for {
        if note, ok := conn_take_notification(c); ok {
            return note, true
        }
        if time.tick_since(start) >= WAIT_LIMIT {
            return {}, false
        }
        time.sleep(time.Millisecond)
    }
}

@(private = "file")
wait_written :: proc(mock: ^Mock, needle: string) -> bool {
    start := time.tick_now()
    for !mock_has(mock, needle) {
        if time.tick_since(start) >= WAIT_LIMIT {
            return false
        }
        time.sleep(time.Millisecond)
    }
    return true
}

// A request goes out framed and its reply comes back to the caller that asked.
@(test)
test_conn_round_trip :: proc(t: ^testing.T) {
    mock: Mock
    serve := Serve {
        mock = &mock,
        answer = proc(s: ^Serve, id: i64, method: string) {
            mock_reply(s.mock, id, `{"ok":true}`)
        },
    }
    mock_serve(&serve)
    defer mock_serve_destroy(&serve)
    c := conn_start(mock_transport(&mock), context.allocator)

    value, err := conn_call(c, "initialize", `{"processId":null}`, WAIT_LIMIT)
    testing.expect_value(t, err, Rpc_Error.None)
    object, is_object := value.(json.Object)
    testing.expect(t, is_object, "the result should be an object")
    answered, _ := object["ok"].(json.Boolean)
    testing.expect(t, bool(answered), "the result did not come through")
    conn_free_value(c, value)

    mock_serve_stop(&serve)
    testing.expect_value(t, len(serve.taken), 1)
    if len(serve.taken) == 1 {
        testing.expect(t, strings.contains(serve.taken[0], `"jsonrpc":"2.0"`), "the request carried no version")
        testing.expect(t, strings.contains(serve.taken[0], `"method":"initialize"`), "the request carried no method")
        testing.expect(t, strings.contains(serve.taken[0], `"id":`), "the request carried no id")
    }
    conn_destroy(c)
}

@(private = "file")
Held :: struct {
    id:     i64,
    method: string, // owned
}

@(private = "file")
Second_Call :: struct {
    conn:  ^Conn,
    value: json.Value,
    error: Rpc_Error,
}

@(private = "file")
second_call :: proc(call: ^Second_Call) {
    call.value, call.error = conn_call(call.conn, "beta", "", WAIT_LIMIT)
}

// Two requests in flight, answered back to front. Each waiter must get its own
// reply, which is the whole point of correlating on the id.
@(test)
test_conn_correlates_out_of_order :: proc(t: ^testing.T) {
    mock: Mock
    held := make([dynamic]Held, context.allocator)
    defer delete(held)
    serve := Serve {
        mock = &mock,
        data = &held,
        answer = proc(s: ^Serve, id: i64, method: string) {
            // Both are held back, then answered newest first with the method
            // echoed, so a reply matched by arrival order swaps them visibly.
            waiting := (^[dynamic]Held)(s.data)
            append(waiting, Held{id = id, method = strings.clone(method, s.allocator)})
            if len(waiting) < 2 {
                return
            }
            for index := len(waiting) - 1; index >= 0; index -= 1 {
                result := fmt.aprintf(`"%s"`, waiting[index].method)
                mock_reply(s.mock, waiting[index].id, result)
                delete(result)
                delete(waiting[index].method, s.allocator)
            }
            clear(waiting)
        },
    }
    mock_serve(&serve)
    defer mock_serve_destroy(&serve)
    c := conn_start(mock_transport(&mock), context.allocator)

    second := Second_Call {
        conn = c,
    }
    worker := thread.create_and_start_with_poly_data(&second, second_call)

    first_value, first_error := conn_call(c, "alpha", "", WAIT_LIMIT)
    thread.join(worker)
    thread.destroy(worker)

    testing.expect_value(t, first_error, Rpc_Error.None)
    testing.expect_value(t, second.error, Rpc_Error.None)
    first_text, _ := first_value.(json.String)
    second_text, _ := second.value.(json.String)
    testing.expect_value(t, string(first_text), "alpha")
    testing.expect_value(t, string(second_text), "beta")
    conn_free_value(c, first_value)
    conn_free_value(c, second.value)

    mock_serve_stop(&serve)
    conn_destroy(c)
}

// An error reply is not a dead server. The caller gets .Server_Error and the
// server's own error object, so the code and the message reach the log.
@(test)
test_conn_reports_a_server_error :: proc(t: ^testing.T) {
    mock: Mock
    serve := Serve {
        mock = &mock,
        answer = proc(s: ^Serve, id: i64, method: string) {
            mock_reply_error(s.mock, id, -32000, "no")
        },
    }
    mock_serve(&serve)
    defer mock_serve_destroy(&serve)
    c := conn_start(mock_transport(&mock), context.allocator)

    value, err := conn_call(c, "textDocument/hover", "", WAIT_LIMIT)
    testing.expect_value(t, err, Rpc_Error.Server_Error)
    object, is_object := value.(json.Object)
    testing.expect(t, is_object, "the error object should come back")
    code, has_code := number(object["code"])
    testing.expect(t, has_code)
    testing.expect_value(t, code, i64(-32000))
    conn_free_value(c, value)

    mock_serve_stop(&serve)
    testing.expect(t, conn_state(c) == .Open, "an error reply is not the end of the connection")
    conn_destroy(c)
}

// A server that never answers must not hold a pool worker forever.
@(test)
test_conn_gives_up_on_the_deadline :: proc(t: ^testing.T) {
    mock: Mock
    c := conn_start(mock_transport(&mock), context.allocator)
    defer conn_destroy(c)

    start := time.tick_now()
    value, err := conn_call(c, "textDocument/hover", "", 60 * time.Millisecond)
    testing.expect_value(t, err, Rpc_Error.Timeout)
    testing.expect(t, value == nil, "a timeout carries no result")
    testing.expect(t, time.tick_since(start) < WAIT_LIMIT, "the deadline did not end the wait")
}

// A server that dies mid-request fails its waiter at once instead of leaving it
// on the deadline.
@(test)
test_conn_fails_a_waiter_at_the_end_of_the_stream :: proc(t: ^testing.T) {
    mock: Mock
    serve := Serve {
        mock = &mock,
        answer = proc(s: ^Serve, id: i64, method: string) {
            mock_close(s.mock)
        },
    }
    mock_serve(&serve)
    defer mock_serve_destroy(&serve)
    c := conn_start(mock_transport(&mock), context.allocator)

    value, err := conn_call(c, "textDocument/hover", "", WAIT_LIMIT)
    testing.expect_value(t, err, Rpc_Error.Transport_Closed)
    testing.expect(t, value == nil, "a dead server carries no result")
    testing.expect_value(t, conn_state(c), Conn_State.Closed)

    mock_serve_stop(&serve)
    conn_destroy(c)
}

// A call on a connection that already ended fails without a wait.
@(test)
test_conn_refuses_a_call_once_closed :: proc(t: ^testing.T) {
    mock: Mock
    c := conn_start(mock_transport(&mock), context.allocator)
    defer conn_destroy(c)

    mock_close(&mock)
    testing.expect(t, wait_closed(c), "the reader did not see the end of the stream")

    value, err := conn_call(c, "textDocument/hover", "", WAIT_LIMIT)
    testing.expect_value(t, err, Rpc_Error.Transport_Closed)
    testing.expect(t, value == nil)
    testing.expect(t, !conn_notify(c, "textDocument/didChange", ""), "a closed connection took a notification")
}

// The caller's cancel flag ends the wait and tells the server to stop working.
@(test)
test_conn_cancels_on_the_flag :: proc(t: ^testing.T) {
    mock: Mock
    c := conn_start(mock_transport(&mock), context.allocator)
    defer conn_destroy(c)

    cancel := true
    value, err := conn_call(c, "textDocument/completion", "", WAIT_LIMIT, &cancel)
    testing.expect_value(t, err, Rpc_Error.Cancelled)
    testing.expect(t, value == nil, "a cancelled call carries no result")
    testing.expect(t, wait_written(&mock, `"method":"$/cancelRequest"`), "the server was not told")
    testing.expect(t, mock_has(&mock, `"id":1`), "the cancellation named no request")
}

// A message the server sent without being asked reaches the main thread whole.
@(test)
test_conn_queues_a_notification :: proc(t: ^testing.T) {
    mock: Mock
    c := conn_start(mock_transport(&mock), context.allocator)
    defer conn_destroy(c)

    mock_frame(
        &mock,
        `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///a.odin"}}`,
    )
    note, ok := wait_notification(c)
    testing.expect(t, ok, "the notification never arrived")
    if !ok {
        return
    }
    defer conn_free_notification(c, note)
    testing.expect_value(t, note.method, "textDocument/publishDiagnostics")
    params, is_object := note.params.(json.Object)
    testing.expect(t, is_object, "the params should come through")
    uri, _ := params["uri"].(json.String)
    testing.expect_value(t, string(uri), "file:///a.odin")
}

// A server blocks on its own requests, so every one is answered — the known ones
// from the fixed table and everything else with an error.
@(test)
test_conn_answers_the_server :: proc(t: ^testing.T) {
    mock: Mock
    c := conn_start(mock_transport(&mock), context.allocator)
    defer conn_destroy(c)

    mock_frame(&mock, `{"jsonrpc":"2.0","id":1,"method":"client/registerCapability","params":{}}`)
    testing.expect(t, wait_written(&mock, `{"jsonrpc":"2.0","id":1,"result":null}`), "the registration went unanswered")

    mock_frame(&mock, `{"jsonrpc":"2.0","id":2,"method":"workspace/applyEdit","params":{}}`)
    testing.expect(
        t,
        wait_written(&mock, `{"jsonrpc":"2.0","id":2,"result":{"applied":false}}`),
        "an edit must be refused, not ignored",
    )

    mock_frame(&mock, `{"jsonrpc":"2.0","id":"x","method":"window/showMessageRequest","params":{}}`)
    testing.expect(t, wait_written(&mock, `"id":"x"`), "a string id must come back a string")
    testing.expect(t, wait_written(&mock, `"code":-32601`), "an unknown method must get an error")
}

// One entry per requested item, so a server that indexes the answer finds them.
@(test)
test_conn_answers_configuration_per_item :: proc(t: ^testing.T) {
    mock: Mock
    c := conn_start(mock_transport(&mock), context.allocator)
    defer conn_destroy(c)

    mock_frame(
        &mock,
        `{"jsonrpc":"2.0","id":3,"method":"workspace/configuration","params":{"items":[{"section":"a"},{"section":"b"}]}}`,
    )
    testing.expect(
        t,
        wait_written(&mock, `{"jsonrpc":"2.0","id":3,"result":[null,null]}`),
        "the answer did not match the request",
    )
}

// A reply nobody waits for is the normal end of a cancelled request, so it is
// dropped and the reader keeps going.
@(test)
test_conn_drops_an_unknown_reply :: proc(t: ^testing.T) {
    mock: Mock
    c := conn_start(mock_transport(&mock), context.allocator)
    defer conn_destroy(c)

    mock_frame(&mock, `{"jsonrpc":"2.0","id":999,"result":{"stale":true}}`)
    mock_frame(&mock, `{"jsonrpc":"2.0","method":"window/logMessage","params":{"message":"still here"}}`)
    note, ok := wait_notification(c)
    testing.expect(t, ok, "the reader stopped on an unknown id")
    if ok {
        conn_free_notification(c, note)
    }
}

// A broken frame cannot be resynchronised from, so it ends the connection the
// same way the end of the stream does.
@(test)
test_conn_ends_on_a_broken_frame :: proc(t: ^testing.T) {
    mock: Mock
    c := conn_start(mock_transport(&mock), context.allocator)
    defer conn_destroy(c)

    mock_send(&mock, transmute([]u8) string("Content-Length: abc\r\n\r\n"))
    testing.expect(t, wait_closed(c), "a broken frame left the connection open")

    _, err := conn_call(c, "textDocument/hover", "", WAIT_LIMIT)
    testing.expect_value(t, err, Rpc_Error.Transport_Closed)
}

// The server's log is kept apart from the frame stream and stays readable, which
// is what a failed handshake needs.
@(test)
test_conn_keeps_the_stderr_tail :: proc(t: ^testing.T) {
    mock: Mock
    c := conn_start(mock_transport(&mock), context.allocator)
    defer conn_destroy(c)

    mock_send(&mock, transmute([]u8) string("panic: no memory\n"), false)
    start := time.tick_now()
    for {
        tail := conn_stderr_tail(c, context.allocator)
        found := strings.contains(tail, "panic: no memory")
        delete(tail)
        if found {
            break
        }
        if time.tick_since(start) >= WAIT_LIMIT {
            testing.fail_now(t, "the server's log never arrived")
        }
        time.sleep(time.Millisecond)
    }
    testing.expect_value(t, conn_state(c), Conn_State.Open)
}
