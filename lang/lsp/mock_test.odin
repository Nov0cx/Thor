package lsp

import "core:sync"
import "core:testing"

// Run from the repository root: odin test lang/lsp

// A Transport with no process behind it, so a scripted server runs on every CI
// platform with nothing installed. The whole point of the vtable: the client core
// above it never learns whether a child exists.
Mock :: struct {
    mutex:     sync.Mutex,
    ready:     sync.Sema,   // posted whenever a stream grows or the mock closes
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
            return mock_read((^Mock)(data), &((^Mock)(data)).to_client, buf)
        },
        read_err = proc(data: rawptr, buf: []u8) -> int {
            return mock_read((^Mock)(data), &((^Mock)(data)).to_error, buf)
        },
        close = proc(data: rawptr) {
            mock := (^Mock)(data)
            sync.lock(&mock.mutex)
            mock.closed = true
            sync.unlock(&mock.mutex)
            sync.sema_post(&mock.ready)
        },
        terminate = proc(data: rawptr) {
            mock := (^Mock)(data)
            sync.lock(&mock.mutex)
            mock.closed = true
            sync.unlock(&mock.mutex)
            sync.sema_post(&mock.ready)
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
    sync.sema_post(&mock.ready)
}

// Takes what the client has written so far. Borrowed from the mock.
mock_written :: proc(mock: ^Mock) -> []u8 {
    sync.guard(&mock.mutex)
    return mock.to_server[:]
}

// Blocks until the stream grows or the mock closes, then takes what fits. 0 means
// the end of the stream, exactly as a dead child's pipe reports it.
@(private = "file")
mock_read :: proc(mock: ^Mock, stream: ^[dynamic]u8, buf: []u8) -> int {
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
        sync.sema_wait(&mock.ready)
    }
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
