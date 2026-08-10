package lsp

import "core:encoding/json"
import "core:testing"

// Run from the repository root: odin test lang/lsp

// The spelling a server is given. Every byte a URI cannot carry is escaped,
// including each byte of a multi-byte character; the drive letter's colon is not.
@(test)
test_uri_from_path :: proc(t: ^testing.T) {
    Case :: struct {
        path: string,
        want: string,
    }
    cases := []Case {
        {"/home/user/main.c", "file:///home/user/main.c"},
        {"C:/src/main.c", "file:///C:/src/main.c"},
        {"C:\\src\\main.c", "file:///C:/src/main.c"},
        {"C:/src/my file.c", "file:///C:/src/my%20file.c"},
        {"/tmp/héllo.c", "file:///tmp/h%C3%A9llo.c"},
        {"/tmp/a#b?c", "file:///tmp/a%23b%3Fc"},
        {"/tmp/100%.c", "file:///tmp/100%25.c"},
    }
    for entry in cases {
        got := uri_from_path(entry.path)
        defer delete(got)
        testing.expectf(t, got == entry.want, "%q gave %q, wanted %q", entry.path, got, entry.want)
    }
}

// The spelling a server sends back, which is not always the one it was given:
// other clients percent-encode the drive letter's colon.
@(test)
test_uri_to_path :: proc(t: ^testing.T) {
    Case :: struct {
        uri:  string,
        want: string,
    }
    cases := []Case {
        {"file:///home/user/main.c", "/home/user/main.c"},
        {"file:///C:/src/main.c", "C:/src/main.c"},
        {"file:///C%3A/src/main.c", "C:/src/main.c"},
        {"file:///c%3a/src/main.c", "c:/src/main.c"},
        {"file:///tmp/my%20file.c", "/tmp/my file.c"},
        {"file:///tmp/h%C3%A9llo.c", "/tmp/héllo.c"},
        {"file://localhost/home/x", "/home/x"},
        {"file:///tmp/x.c?v=1", "/tmp/x.c"},
        {"file:///tmp/x.c#L10", "/tmp/x.c"},
        // A '%' that begins no escape is a '%'.
        {"file:///tmp/100%zz", "/tmp/100%zz"},
        {"file:///tmp/trailing%", "/tmp/trailing%"},
    }
    for entry in cases {
        got, ok := uri_to_path(entry.uri)
        defer delete(got)
        testing.expectf(t, ok, "%q was refused", entry.uri)
        testing.expectf(t, got == entry.want, "%q gave %q, wanted %q", entry.uri, got, entry.want)
    }
}

// A URI that names no local file is refused rather than read as one.
@(test)
test_uri_to_path_refuses :: proc(t: ^testing.T) {
    cases := []string{"http://example.com/x.c", "untitled:Untitled-1", "", "file:", "file://remote-host/share/x.c"}
    for uri in cases {
        path, ok := uri_to_path(uri)
        defer delete(path)
        testing.expectf(t, !ok, "%q was read as %q", uri, path)
    }
}

// The round trip a diagnostic makes: out as a URI, back as the path the editor
// keyed the document on.
@(test)
test_uri_round_trip :: proc(t: ^testing.T) {
    paths := []string {
        "/home/user/main.c",
        "C:/src/main.c",
        "/tmp/my file.c",
        "/tmp/héllo世界.c",
        "/tmp/a#b?c&d.c",
        "C:/Users/tester/AppData/Local/Temp/x.c",
    }
    for path in paths {
        uri := uri_from_path(path)
        defer delete(uri)
        back, ok := uri_to_path(uri)
        defer delete(back)
        testing.expectf(t, ok, "%q came back as nothing", path)
        testing.expectf(t, back == path, "%q came back as %q", path, back)
    }
}

// A URI carries one separator and Windows has two, so the comparison the document
// lookup makes cannot be a string compare there.
@(test)
test_path_equal :: proc(t: ^testing.T) {
    testing.expect(t, path_equal("/home/x/main.c", "/home/x/main.c"))
    testing.expect(t, !path_equal("/home/x/main.c", "/home/x/other.c"))
    testing.expect(t, !path_equal("/home/x", "/home/x/"))

    when ODIN_OS == .Windows {
        testing.expect(t, path_equal("C:/src/main.c", "c:\\src\\Main.c"))
    } else {
        testing.expect(t, !path_equal("/home/X", "/home/x"))
    }
}

// clangd reads the languageId to tell a header from a source file; an extension
// nothing names passes through without its dot.
@(test)
test_language_id_for :: proc(t: ^testing.T) {
    testing.expect_value(t, language_id_for(".c"), "c")
    testing.expect_value(t, language_id_for(".hpp"), "cpp")
    testing.expect_value(t, language_id_for(".rs"), "rust")
    testing.expect_value(t, language_id_for(".tsx"), "typescriptreact")
    testing.expect_value(t, language_id_for(".nim"), "nim")
    testing.expect_value(t, language_id_for(""), "")
}

// A document starts at version 1 and the index always describes the text that was
// last sent.
@(test)
test_document_versions :: proc(t: ^testing.T) {
    doc: Document
    document_init(&doc, "C:/src/main.c", "one\ntwo", .Utf16)
    defer document_destroy(&doc)

    testing.expect_value(t, doc.version, 1)
    testing.expect_value(t, doc.uri, "file:///C:/src/main.c")
    testing.expect(t, !doc.open)
    testing.expect_value(t, len(doc.lines.starts), 2)

    document_set_text(&doc, "one\ntwo\nthree")
    testing.expect_value(t, doc.version, 2)
    testing.expect_value(t, doc.text, "one\ntwo\nthree")
    testing.expect_value(t, len(doc.lines.starts), 3)
    testing.expect_value(t, offset_from_position(&doc.lines, 2, 0), 8)
    testing.expect_value(t, doc.lines.encoding, Encoding.Utf16)
}

// The notification the server has to be able to parse back, whatever the buffer
// holds: a quote, a newline and an astral character all survive the escaping.
@(test)
test_did_open_params :: proc(t: ^testing.T) {
    text := "line \"one\"\n\ttab 😀\n"
    doc: Document
    document_init(&doc, "/src/main.c", text, .Utf16)
    defer document_destroy(&doc)

    params := did_open_params(&doc, "c")
    defer delete(params)

    value, err := json.parse(transmute([]u8)params, allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
    root, rok := value.(json.Object)
    testing.expect(t, rok)
    if !rok {
        return
    }
    item, iok := root["textDocument"].(json.Object)
    testing.expect(t, iok)
    if !iok {
        return
    }
    testing.expect_value(t, string(item["uri"].(json.String)), "file:///src/main.c")
    testing.expect_value(t, string(item["languageId"].(json.String)), "c")
    testing.expect_value(t, string(item["text"].(json.String)), text)
    version, vok := number(item["version"])
    testing.expect(t, vok)
    testing.expect_value(t, version, 1)
}

// didChange carries the whole buffer as one change with no range, and the version
// it belongs to.
@(test)
test_did_change_params :: proc(t: ^testing.T) {
    doc: Document
    document_init(&doc, "/src/main.c", "before", .Utf16)
    defer document_destroy(&doc)
    document_set_text(&doc, "after")

    params := did_change_params(&doc)
    defer delete(params)

    value, err := json.parse(transmute([]u8)params, allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
    root, rok := value.(json.Object)
    testing.expect(t, rok)
    if !rok {
        return
    }
    item, iok := root["textDocument"].(json.Object)
    testing.expect(t, iok)
    if !iok {
        return
    }
    version, vok := number(item["version"])
    testing.expect(t, vok)
    testing.expect_value(t, version, 2)

    changes, cok := root["contentChanges"].(json.Array)
    testing.expect(t, cok)
    if !cok || len(changes) != 1 {
        return
    }
    change, chok := changes[0].(json.Object)
    testing.expect(t, chok)
    if !chok {
        return
    }
    testing.expect_value(t, string(change["text"].(json.String)), "after")
    _, has_range := change["range"]
    testing.expect(t, !has_range)
}

// The incremental form carries a range and only the replaced substring, not
// the whole buffer — the shape server_publish sends when the server's
// capabilities advertise Incremental sync.
@(test)
test_did_change_incremental_params :: proc(t: ^testing.T) {
    doc: Document
    document_init(&doc, "/src/main.c", "hello world", .Utf16)
    defer document_destroy(&doc)
    document_set_text(&doc, "hello brave world")

    params := did_change_incremental_params(&doc, 0, 6, 0, 6, "brave ")
    defer delete(params)

    value, err := json.parse(transmute([]u8)params, allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
    root, rok := value.(json.Object)
    testing.expect(t, rok)
    if !rok {
        return
    }
    version, vok := number(root["textDocument"].(json.Object)["version"])
    testing.expect(t, vok)
    testing.expect_value(t, version, 2)

    changes, cok := root["contentChanges"].(json.Array)
    testing.expect(t, cok)
    if !cok || len(changes) != 1 {
        return
    }
    change, chok := changes[0].(json.Object)
    testing.expect(t, chok)
    if !chok {
        return
    }
    testing.expect_value(t, string(change["text"].(json.String)), "brave ")

    rng, rngok := change["range"].(json.Object)
    testing.expect(t, rngok)
    if !rngok {
        return
    }
    start, sok := rng["start"].(json.Object)
    testing.expect(t, sok)
    end, eok := rng["end"].(json.Object)
    testing.expect(t, eok)
    if !sok || !eok {
        return
    }
    start_line, slok := number(start["line"])
    start_char, scok := number(start["character"])
    end_line, elok := number(end["line"])
    end_char, ecok := number(end["character"])
    testing.expect(t, slok && scok && elok && ecok)
    testing.expect_value(t, start_line, 0)
    testing.expect_value(t, start_char, 6)
    testing.expect_value(t, end_line, 0)
    testing.expect_value(t, end_char, 6)
}

// didSave and didClose name the document and send nothing else.
@(test)
test_did_identify_params :: proc(t: ^testing.T) {
    doc: Document
    document_init(&doc, "/src/main.c", "x", .Utf16)
    defer document_destroy(&doc)

    params := did_identify_params(&doc)
    defer delete(params)
    testing.expect_value(t, params, `{"textDocument":{"uri":"file:///src/main.c"}}`)
}
