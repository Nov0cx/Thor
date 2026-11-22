package lsp

import "core:encoding/json"
import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_glob_match :: proc(t: ^testing.T) {
    Case :: struct {
        pattern, path: string,
        want:          bool,
    }
    cases := []Case{
        {"**/*.go", "src/a/b.go", true},
        {"**/*.go", "b.go", true},
        {"**/*.go", "src/b.goo", false},
        {"*.go", "src/b.go", false},
        {"src/*.{c,h}", "src/a.h", true},
        {"src/*.{c,h}", "src/a.o", false},
        {"**/go.{mod,sum}", "x/go.sum", true},
        {"a?c", "abc", true},
        {"a?c", "a/c", false},
        {"[a-c]x", "bx", true},
        {"[!a-c]x", "bx", false},
        {"**", "any/depth/file", true},
        {"src/**/test/*.rs", "src/test/a.rs", true},
        {"src/**/test/*.rs", "src/x/y/test/a.rs", true},
    }
    for c in cases {
        testing.expectf(t, glob_match(c.pattern, c.path) == c.want, "%q on %q: want %v", c.pattern, c.path, c.want)
    }
}

@(private = "file")
register_test_server :: proc(config: ^Server_Config) -> ^Server {
    s := server_create(config, "ws")
    s.state = .Ready
    return s
}

@(private = "file")
register_json :: proc(s: ^Server, text: string, unregister := false) {
    value, err := json.parse_string(text, parse_integers = true)
    defer json.destroy_value(value)
    if err != nil {
        return
    }
    server_register(s, value, unregister)
}

// A registration adds its kinds to what the server answers, and an unregister removes them.
@(test)
test_register_capability_adds_and_removes_kinds :: proc(t: ^testing.T) {
    config := Server_Config{id = "fake", features = lang.FEATURES_ALL, enabled = true}
    s      := register_test_server(&config)
    defer server_destroy(s)

    testing.expect(t, !server_supports(s, .Hover), "no hover before the registration")
    register_json(s, `{"registrations":[{"id":"h1","method":"textDocument/hover"},{"id":"c1","method":"textDocument/completion"}]}`)
    testing.expect(t, server_supports(s, .Hover))
    testing.expect(t, server_supports(s, .Package_Doc), "package docs ride hover")
    testing.expect(t, !server_supports(s, .Completion), "completion stays static")
    testing.expect_value(t, len(s.registrations), 1)

    register_json(s, `{"unregisterations":[{"id":"h1","method":"textDocument/hover"}]}`, unregister = true)
    testing.expect(t, !server_supports(s, .Hover), "the unregister kept hover")
    testing.expect_value(t, len(s.registrations), 0)
}

// A watched-files registration keeps the changes its globs match and sends them as one notification.
@(test)
test_register_watched_files :: proc(t: ^testing.T) {
    config := Server_Config{id = "fake", features = lang.FEATURES_ALL, enabled = true}
    s      := register_test_server(&config)
    defer server_destroy(s)

    register_json(
        s,
        `{"registrations":[{"id":"w","method":"workspace/didChangeWatchedFiles","registerOptions":{"watchers":[` +
            `{"globPattern":"**/*.toml"},` +
            `{"globPattern":{"baseUri":"file:///ws/sub","pattern":"*.lock"},"kind":4}]}}]}`,
    )
    testing.expect(t, s.watching, "the watcher was not kept")

    changes := []lang.File_Change{
        {path = "ws/Cargo.toml", kind = .Changed},
        {path = "ws/src/main.rs", kind = .Changed},
        {path = "/ws/sub/Cargo.lock", kind = .Changed},
        {path = "/ws/sub/Cargo.lock", kind = .Deleted},
    }
    server_files_changed(s, changes)
    testing.expect_value(t, len(s.watched), 2)
    if len(s.watched) == 2 {
        testing.expect_value(t, s.watched[0].path, "ws/Cargo.toml")
        testing.expect_value(t, s.watched[1].kind, lang.File_Change_Kind.Deleted)
    }

    mock: Mock
    s.conn = conn_start(mock_transport(&mock), context.allocator)
    defer {
        conn_destroy(s.conn)
        s.conn = nil
    }
    server_send_watched(s)
    testing.expect(t, wait_written(&mock, `"method":"workspace/didChangeWatchedFiles"`), "no notification")
    testing.expect(t, wait_written(&mock, `"type":3`), "the delete was not sent")
    testing.expect_value(t, len(s.watched), 0)
}

// A server that registered no watcher gets no file changes.
@(test)
test_files_changed_needs_a_watcher :: proc(t: ^testing.T) {
    config := Server_Config{id = "fake", features = lang.FEATURES_ALL, enabled = true}
    s      := register_test_server(&config)
    defer server_destroy(s)

    changes := []lang.File_Change{{path = "ws/a.toml", kind = .Created}}
    server_files_changed(s, changes)
    testing.expect_value(t, len(s.watched), 0)
    testing.expect(t, !strings.contains(CLIENT_CAPABILITIES, `"completion":{"dynamicRegistration":true`), "completion must stay static")
}
