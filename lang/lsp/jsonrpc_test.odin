package lsp

import "core:encoding/json"
import "core:testing"

// Run from the repository root: odin test lang/lsp

// The three envelope shapes a client sends. Assembled from parts because
// json.marshal has no json.Value case, so `params` cannot ride in a struct.
@(test)
test_request_envelope :: proc(t: ^testing.T) {
    out := make([dynamic]u8, context.temp_allocator)
    envelope_request(&out, 7, "textDocument/hover", `{"line":1}`)
    testing.expect_value(
        t,
        string(out[:]),
        `{"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"line":1}}`,
    )
}

// Empty params are left out rather than sent as null: a server that reads params
// without checking must not see one that is not there.
@(test)
test_request_envelope_without_params :: proc(t: ^testing.T) {
    out := make([dynamic]u8, context.temp_allocator)
    envelope_request(&out, 1, "shutdown", "")
    testing.expect_value(t, string(out[:]), `{"jsonrpc":"2.0","id":1,"method":"shutdown"}`)
}

// A notification carries no id, which is what tells the server not to answer.
@(test)
test_notification_envelope :: proc(t: ^testing.T) {
    out := make([dynamic]u8, context.temp_allocator)
    envelope_notification(&out, "$/cancelRequest", `{"id":4}`)
    testing.expect_value(t, string(out[:]), `{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":4}}`)
}

// An answer echoes the server's id verbatim, so a string id comes back a string.
@(test)
test_response_envelope :: proc(t: ^testing.T) {
    out := make([dynamic]u8, context.temp_allocator)
    envelope_response(&out, `"abc"`, "null")
    testing.expect_value(t, string(out[:]), `{"jsonrpc":"2.0","id":"abc","result":null}`)

    clear(&out)
    envelope_error(&out, "3", -32601, "unhandled")
    testing.expect_value(
        t,
        string(out[:]),
        `{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"unhandled"}}`,
    )
}

// A method name is our own ASCII, but a message echoed back is not, so the
// quoting must survive what a server can send.
@(test)
test_quoting_escapes_what_json_forbids :: proc(t: ^testing.T) {
    out := make([dynamic]u8, context.temp_allocator)
    write_quoted(&out, "a\"b\\c\nd\te")
    testing.expect_value(t, string(out[:]), `"a\"b\\c\nd\te"`)

    clear(&out)
    write_quoted(&out, "\x01")
    testing.expect_value(t, string(out[:]), "\"\\u0001\"")
}

// Every parse in this package asks for exact integers, but a server may legally
// send an id as 1.0, so a whole Float is still a number and 1.5 is not.
@(test)
test_number_accepts_a_whole_float :: proc(t: ^testing.T) {
    value, ok := number(json.Value(json.Integer(42)))
    testing.expect_value(t, value, i64(42))
    testing.expect(t, ok)

    value, ok = number(json.Value(json.Float(1.0)))
    testing.expect_value(t, value, i64(1))
    testing.expect(t, ok)

    _, ok = number(json.Value(json.Float(1.5)))
    testing.expect(t, !ok, "1.5 is not an id")

    _, ok = number(json.Value(json.String("7")))
    testing.expect(t, !ok, "a string is not a number")

    _, ok = number(nil)
    testing.expect(t, !ok, "a missing member is not a number")
}

// The parse defaults are JSON5 with float numbers, both wrong for a protocol
// whose ids and offsets must be exact.
@(test)
test_parse_settings_keep_an_id_exact :: proc(t: ^testing.T) {
    body := `{"id":9007199254740993}`
    value, err := json.parse(
        transmute([]u8) body,
        spec = .JSON,
        parse_integers = true,
        allocator = context.allocator,
    )
    defer json.destroy_value(value, context.allocator)
    testing.expect_value(t, err, json.Error.None)

    object, is_object := value.(json.Object)
    testing.expect(t, is_object)
    id, ok := number(object["id"])
    testing.expect(t, ok)
    testing.expect_value(t, id, i64(9007199254740993))
}
