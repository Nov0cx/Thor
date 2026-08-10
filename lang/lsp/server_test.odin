package lsp

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import lang ".."

// Run from the repository root: odin test lang/lsp

@(private = "file")
LIMIT :: 5 * time.Second

// The workspace and the file in it, spelled the way the platform spells them: the
// root walk splits on the platform's separator, and the URI of a drive-letter
// path is not the URI of a rooted one.
when ODIN_OS == .Windows {
    @(private = "file")
    WORKSPACE :: "C:/ws"
    @(private = "file")
    SOURCE :: "C:/ws/src/main.fake"
    @(private = "file")
    WORKSPACE_URI :: "file:///C:/ws"
    @(private = "file")
    SOURCE_URI :: "file:///C:/ws/src/main.fake"
} else {
    @(private = "file")
    WORKSPACE :: "/ws"
    @(private = "file")
    SOURCE :: "/ws/src/main.fake"
    @(private = "file")
    WORKSPACE_URI :: "file:///ws"
    @(private = "file")
    SOURCE_URI :: "file:///ws/src/main.fake"
}

// A scripted server behind a Server: the transport is the in-process Mock, so a
// whole lifetime runs with no child, no installed server and no display.
@(private = "file")
Fake :: struct {
    mock:       Mock,
    serve:      Serve,
    config:     Server_Config,
    extensions: [1]string,
    command:    [1]string,
    caps:       string, // the initialize result it answers with
    result:     string, // what it answers every other request with; "" answers null
    opens:      int,    // how many times a transport was asked for
    refuse:     bool,   // a second start finds no program
    silent:     bool,   // it takes every request but the handshake and never answers
    ended:      bool,   // the scripted server has been stopped
}

@(private = "file")
CAPS_ALL :: `{"capabilities":{"textDocumentSync":{"openClose":true,"change":1,"save":true},` +
`"definitionProvider":true,"hoverProvider":true,"renameProvider":true,"completionProvider":{}}}`

@(private = "file")
fake_open :: proc(s: ^Server) -> (Transport, bool) {
    f := (^Fake)(s.open_data)
    f.opens += 1
    if f.refuse && f.opens > 1 {
        return {}, false
    }
    return mock_transport(&f.mock), true
}

@(private = "file")
fake_answer :: proc(sv: ^Serve, id: i64, method: string) {
    f := (^Fake)(sv.data)
    switch method {
    case "initialize":
        mock_reply(sv.mock, id, f.caps)
    case:
        if f.silent {
            return
        }
        mock_reply(sv.mock, id, f.result == "" ? "null" : f.result)
    }
}

// A server on a scripted transport, not started yet.
@(private = "file")
fake_server :: proc(f: ^Fake, caps: string) -> ^Server {
    f.caps = caps
    f.extensions[0] = ".fake"
    f.command[0] = "fake-language-server"
    f.config = Server_Config {
        id         = "fake",
        extensions = f.extensions[:],
        command    = f.command[:],
        features   = lang.FEATURES_ALL,
        enabled    = true,
    }
    f.serve = Serve {
        mock   = &f.mock,
        answer = fake_answer,
        data   = f,
    }
    mock_serve(&f.serve)

    s := server_create(&f.config, WORKSPACE)
    s.open = fake_open
    s.open_data = f
    return s
}

// Ends the scripted server, the way a killed process does. The serve worker goes
// first: conn_destroy frees the mock's buffers and that worker reads them.
@(private = "file")
fake_kill :: proc(f: ^Fake) {
    if !f.ended {
        mock_serve_stop(&f.serve)
        f.ended = true
    }
    mock_close(&f.mock)
}

@(private = "file")
fake_end :: proc(f: ^Fake, s: ^Server) {
    fake_kill(f)
    server_stop(s)
    server_destroy(s)
    mock_serve_destroy(&f.serve)
}

@(private = "file")
wait_state :: proc(s: ^Server, want: Server_State) -> bool {
    start := time.tick_now()
    for server_state(s) != want {
        if time.tick_since(start) >= LIMIT {
            return false
        }
        time.sleep(time.Millisecond)
    }
    return true
}

@(private = "file")
wait_sent :: proc(f: ^Fake, needle: string) -> bool {
    start := time.tick_now()
    for !fake_sent(f, needle) {
        if time.tick_since(start) >= LIMIT {
            return false
        }
        time.sleep(time.Millisecond)
    }
    return true
}

// Whether the scripted server has taken a frame holding `needle`. The bodies it
// took are the record: the mock's own buffer is drained by the serve thread.
@(private = "file")
fake_sent :: proc(f: ^Fake, needle: string) -> bool {
    sync.guard(&f.serve.mutex)
    for body in f.serve.taken {
        if strings.contains(body, needle) {
            return true
        }
    }
    return false
}

// The order two messages were sent in, -1 when one of them was not.
@(private = "file")
fake_index :: proc(f: ^Fake, needle: string) -> int {
    sync.guard(&f.serve.mutex)
    for body, index in f.serve.taken {
        if strings.contains(body, needle) {
            return index
        }
    }
    return -1
}

// The handshake: initialize with what Thor can consume, then initialized, and
// only then is the server Ready.
@(test)
test_server_handshake :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)

    testing.expect(t, server_start(s, SOURCE))
    testing.expect(t, wait_state(s, .Ready), "the handshake did not finish")

    testing.expect(t, wait_sent(&f, `"method":"initialized"`), "initialized was never sent")
    testing.expect(t, fake_sent(&f, `"method":"initialize"`))
    testing.expect(t, fake_sent(&f, `"positionEncodings":["utf-8","utf-16"]`))
    testing.expect(t, fake_sent(&f, `"snippetSupport":false`))
    testing.expect(t, fake_sent(&f, `"resourceOperations":[]`))
    testing.expect(t, fake_sent(&f, `"rootUri":"` + WORKSPACE_URI + `"`))
    testing.expect(t, fake_index(&f, `"method":"initialize"`) < fake_index(&f, `"method":"initialized"`))
}

// The reply decides what the server is asked for, and the config can decline a
// kind the server offers.
@(test)
test_server_supports :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)

    // Before a start, everything the config allows is claimed: a request that
    // arrives during the handshake must not be swallowed.
    testing.expect(t, server_supports(s, .Definition))
    testing.expect(t, server_supports(s, .Semantic_Tokens))

    f.config.features -= {.Hover}
    testing.expect(t, server_start(s, SOURCE))
    testing.expect(t, wait_state(s, .Ready), "the handshake did not finish")

    testing.expect(t, server_supports(s, .Definition))
    testing.expect(t, server_supports(s, .Rename))
    // Advertised, but the config turned it off.
    testing.expect(t, !server_supports(s, .Hover))
    // Never advertised.
    testing.expect(t, !server_supports(s, .Semantic_Tokens))
    // No LSP method exists for it at all.
    testing.expect(t, !server_supports(s, .Package_Doc))
}

// The document lifetime, in order and with monotonic versions.
@(test)
test_server_document_sync :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)

    server_notify(s, .Opened, SOURCE, ".fake", "one", 1)
    testing.expect(t, wait_state(s, .Ready), "the open did not start the server")
    testing.expect(t, wait_sent(&f, `"method":"textDocument/didOpen"`), "didOpen never arrived")
    testing.expect(t, fake_sent(&f, `"languageId":"fake"`))
    testing.expect(t, fake_sent(&f, `"uri":"` + SOURCE_URI + `"`))
    testing.expect(t, fake_sent(&f, `"text":"one"`))

    server_notify(s, .Changed, SOURCE, ".fake", "one two", 2)
    testing.expect(t, wait_sent(&f, `"method":"textDocument/didChange"`), "didChange never arrived")
    testing.expect(t, fake_sent(&f, `"version":2`))
    testing.expect(t, fake_sent(&f, `"text":"one two"`))

    server_notify(s, .Saved, SOURCE, ".fake", "", 2)
    testing.expect(t, wait_sent(&f, `"method":"textDocument/didSave"`), "didSave never arrived")

    server_notify(s, .Closed, SOURCE, ".fake", "", 2)
    testing.expect(t, wait_sent(&f, `"method":"textDocument/didClose"`), "didClose never arrived")

    open_at := fake_index(&f, `"method":"textDocument/didOpen"`)
    change_at := fake_index(&f, `"method":"textDocument/didChange"`)
    close_at := fake_index(&f, `"method":"textDocument/didClose"`)
    testing.expect(t, open_at < change_at && change_at < close_at, "the notifications arrived out of order")
}

// A change folds into the file's last queued change only. The server is never
// started here, so the outbox keeps everything and can be read.
@(test)
test_server_change_coalescing :: proc(t: ^testing.T) {
    extensions := [1]string{".fake"}
    command := [1]string{"fake-language-server"}
    config := Server_Config {
        id         = "fake",
        extensions = extensions[:],
        command    = command[:],
        features   = lang.FEATURES_ALL,
        enabled    = true,
    }
    s := server_create(&config, WORKSPACE)
    defer {
        server_stop(s)
        server_destroy(s)
    }

    server_notify(s, .Changed, SOURCE, ".fake", "one", 1)
    server_notify(s, .Changed, SOURCE, ".fake", "two", 2)
    testing.expect_value(t, len(s.outbox), 1)
    testing.expect_value(t, s.outbox[0].source, "two")
    testing.expect_value(t, s.outbox[0].revision, 2)

    // A close between them ends the fold: the newer text belongs after the
    // close, not before it.
    server_notify(s, .Closed, SOURCE, ".fake", "", 2)
    server_notify(s, .Changed, SOURCE, ".fake", "three", 3)
    testing.expect_value(t, len(s.outbox), 3)
    testing.expect_value(t, s.outbox[0].source, "two")
    testing.expect_value(t, s.outbox[1].event, lang.Doc_Event.Closed)
    testing.expect_value(t, s.outbox[2].source, "three")

    // Another file never folds into this one's.
    server_notify(s, .Changed, SOURCE + "x", ".fake", "other", 1)
    testing.expect_value(t, len(s.outbox), 4)
}

// A server that asked for no synchronization is sent none.
@(test)
test_server_sync_declined :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, `{"capabilities":{"textDocumentSync":0,"hoverProvider":true}}`)
    defer fake_end(&f, s)

    server_notify(s, .Opened, SOURCE, ".fake", "one", 1)
    testing.expect(t, wait_state(s, .Ready), "the open did not start the server")
    testing.expect(t, wait_sent(&f, `"method":"initialized"`), "initialized was never sent")

    // The change is applied to the document either way; only the wire is quiet.
    server_notify(s, .Changed, SOURCE, ".fake", "two", 2)
    time.sleep(50 * time.Millisecond)
    testing.expect(t, !fake_sent(&f, "textDocument/didOpen"), "didOpen was sent to a server that declined it")
    testing.expect(t, !fake_sent(&f, "textDocument/didChange"), "didChange was sent to a server that declined it")
}

// A server that dies during its handshake is failed for the session, and a failed
// server claims nothing.
@(test)
test_server_eof_during_handshake :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)

    // The transport ends before the reply, as a server that exits at once does.
    fake_kill(&f)

    testing.expect(t, server_start(s, SOURCE))
    testing.expect(t, wait_state(s, .Failed), "a dead handshake left the server running")
    testing.expect(t, !server_supports(s, .Definition))
}

// A start that finds no program fails without a process and without a wait.
@(test)
test_server_no_program :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)
    f.refuse = true
    f.opens = 1 // the next open is the refused one

    testing.expect(t, server_start(s, SOURCE))
    testing.expect(t, wait_state(s, .Failed), "a server with no program stayed alive")
    req := lang.Request {
        path = SOURCE,
    }
    testing.expect(t, !server_ensure_started(s, &req))
}

// A server that dies after the handshake is restarted, and a stop during the
// backoff does not wait it out.
@(test)
test_server_crash_restarts :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)

    testing.expect(t, server_start(s, SOURCE))
    testing.expect(t, wait_state(s, .Ready), "the handshake did not finish")

    f.refuse = true
    fake_kill(&f)
    testing.expect(t, wait_state(s, .Crashed), "the death was not noticed")

    // fake_end stops it while the backoff runs, which must not wait it out.
    start := time.tick_now()
    server_stop(s)
    testing.expect(t, time.tick_since(start) < RESTART_BACKOFF[0], "the stop waited out the backoff")
}

// The two requests a server makes of its client, answered from the config.
@(test)
test_server_answers_configuration :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)
    f.config.settings = `{"fake":{"level":2}}`

    testing.expect(t, server_start(s, SOURCE))
    testing.expect(t, wait_state(s, .Ready), "the handshake did not finish")
    // The configured settings are pushed once at the end of the handshake.
    testing.expect(t, wait_sent(&f, `"method":"workspace/didChangeConfiguration"`), "the settings were never pushed")

    mock_frame(
        &f.mock,
        `{"jsonrpc":"2.0","id":900,"method":"workspace/configuration","params":{"items":[{"section":"fake"},{"section":"other"}]}}`,
    )
    testing.expect(t, wait_sent(&f, `[{"fake":{"level":2}},{"fake":{"level":2}}]`), "configuration went unanswered")

    mock_frame(&f.mock, `{"jsonrpc":"2.0","id":901,"method":"workspace/workspaceFolders"}`)
    testing.expect(t, wait_sent(&f, `[{"uri":"` + WORKSPACE_URI + `","name":"ws"}]`), "workspaceFolders went unanswered")
}

@(private = "file")
BUFFER :: "alpha beta\ngamma"

// A whole request: the file is opened on the server, the position goes out in the
// server's own coordinates, and the reply comes back as a byte offset.
@(test)
test_server_request_round_trip :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)
    defer free_all(context.temp_allocator)
    f.result =
        `{"uri":"` + SOURCE_URI + `","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}}}`

    req := lang.Request {
        kind     = .Definition,
        path     = SOURCE,
        ext      = ".fake",
        source   = BUFFER,
        offset   = 6, // the "b" of "beta"
        revision = 4,
    }
    res := lang.Result {
        kind = .Definition,
    }
    testing.expect(t, server_ensure_started(s, &req), "the server did not start")
    request_answer(s, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "the reply did not reach the result")
    testing.expect_value(t, res.location.path, SOURCE)
    testing.expect_value(t, res.location.start, 11)
    testing.expect_value(t, res.location.end, 16)

    testing.expect(t, fake_sent(&f, `"method":"textDocument/definition"`), "the request was never sent")
    testing.expect(t, fake_sent(&f, `"uri":"` + SOURCE_URI + `"`), "the request named no file")
    testing.expect(t, fake_sent(&f, `"position":{"line":0,"character":6}`), "the caret was converted wrong")
}

// The server must hold the request's text before the request names a position in
// it, and text it already has is not sent again.
@(test)
test_server_syncs_before_a_request :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)
    defer free_all(context.temp_allocator)

    req := lang.Request {
        kind     = .Hover,
        path     = SOURCE,
        ext      = ".fake",
        source   = BUFFER,
        offset   = 0,
        revision = 4,
    }
    res := lang.Result {
        kind = .Hover,
    }
    testing.expect(t, server_ensure_started(s, &req), "the server did not start")
    request_answer(s, &req, &res)

    open_at := fake_index(&f, `"method":"textDocument/didOpen"`)
    hover_at := fake_index(&f, `"method":"textDocument/hover"`)
    testing.expect(t, open_at >= 0, "the file was never opened on the server")
    testing.expect(t, open_at < hover_at, "the position was sent before the text it counts over")
    testing.expect(t, fake_sent(&f, `"text":"alpha beta\ngamma"`), "the buffer was not the text that was sent")

    // A second request at the same revision has nothing to send.
    request_answer(s, &req, &res)
    testing.expect(t, !fake_sent(&f, `"method":"textDocument/didChange"`), "text the server already had was sent again")

    // A newer revision is a change, and it goes out before the second request.
    req.source = "alpha beta\ngamma delta"
    req.revision = 5
    request_answer(s, &req, &res)
    change_at := fake_index(&f, `"method":"textDocument/didChange"`)
    testing.expect(t, change_at > hover_at, "the newer text was never sent")
    testing.expect(t, fake_sent(&f, `"text":"alpha beta\ngamma delta"`), "the newer text was not the text that was sent")
}

// A document event the pump flushes after a request already synced the same file
// must not put the older text back. The revision is monotonic per file, so an
// older one is a queued event the request overtook.
@(test)
test_server_publish_never_goes_backwards :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)

    testing.expect(t, server_start(s, SOURCE))
    testing.expect(t, wait_state(s, .Ready), "the handshake did not finish")

    sync.lock(&s.docs_mutex)
    server_publish(s, SOURCE, ".fake", "three", 3)
    server_publish(s, SOURCE, ".fake", "two", 2)
    doc, found := server_find(s, SOURCE)
    sync.unlock(&s.docs_mutex)

    testing.expect(t, found, "the document was never created")
    if !found {
        return
    }
    testing.expect_value(t, doc.text, "three")
    testing.expect_value(t, doc.revision, u64(3))
    testing.expect(t, wait_sent(&f, `"text":"three"`), "the newer text was never sent")
    testing.expect(t, !fake_sent(&f, `"text":"two"`), "the older text was sent after the newer one")
}

// A request the editor abandoned ends at once and tells the server to stop
// working, instead of holding a worker until the deadline.
@(test)
test_server_request_cancels :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)
    defer free_all(context.temp_allocator)

    f.silent = true
    cancel := false
    req := lang.Request {
        kind     = .Completion,
        path     = SOURCE,
        ext      = ".fake",
        source   = BUFFER,
        revision = 1,
        cancel   = &cancel,
    }
    res := lang.Result {
        kind = .Completion,
    }
    testing.expect(t, server_ensure_started(s, &req), "the server did not start")

    // The editor gives up while the request is in flight, which is what a newer
    // keystroke does.
    cancel = true
    start := time.tick_now()
    request_answer(s, &req, &res)
    testing.expect(t, time.tick_since(start) < DEADLINE_INTERACTIVE, "the cancel did not end the wait")
    testing.expect(t, !res.ok, "a cancelled request must find nothing")
    testing.expect(t, wait_sent(&f, `"method":"$/cancelRequest"`), "the server was never told to stop")
}

// A kind that reaches this backend with no method behind it costs no round trip.
@(test)
test_server_request_without_a_method :: proc(t: ^testing.T) {
    f: Fake
    s := fake_server(&f, CAPS_ALL)
    defer fake_end(&f, s)
    defer free_all(context.temp_allocator)

    req := lang.Request {
        kind     = .Package_Doc,
        path     = SOURCE,
        ext      = ".fake",
        source   = BUFFER,
        revision = 1,
    }
    res := lang.Result {
        kind = .Package_Doc,
    }
    testing.expect(t, server_ensure_started(s, &req), "the server did not start")
    request_answer(s, &req, &res)

    testing.expect(t, !res.ok)
    testing.expect(t, !fake_sent(&f, `"method":"textDocument/didOpen"`), "a kind with no method still synced the file")
}
