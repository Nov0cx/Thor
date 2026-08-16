// The documents a server knows about, and the `file:` URI it names them by.
// Sync defaults to TextDocumentSyncKind.Full: every change carries the whole
// buffer, which is always correct and keeps the LF-collapsed text the position
// layer indexes. A server that advertises Incremental gets a ranged change
// instead (`did_change_incremental_params`, built in `server.odin` from a
// `treecache.source_edit` against the document's previous text).
package lsp

import "base:runtime"
import "core:strconv"
import "core:strings"

// One document the client has opened on a server. `text` is the exact bytes that
// were sent, which is what turns a server's (line, character) into a byte offset
// without reading the file again.
Document :: struct {
    uri:       string,     // owned
    path:      string,     // owned
    text:      string,     // owned; LF-collapsed, exactly as sent
    lines:     Line_Index, // owned; indexes `text`
    version:   i64,
    // The editor revision `text` came from. Monotonic per file, so a document
    // event that carries an older one is already in the server's copy.
    revision:  u64,
    open:      bool, // didOpen was sent and didClose was not
    // The last full semanticTokens reply, kept so the next request can ask for
    // a delta instead of the whole list; nil/"" until the first fetch, or after
    // a delta the cache disagreed with (see server_clear_semantic).
    semantic_data:      []i64, // owned; the flat, delta-encoded token array
    semantic_result_id: string, // owned
    // The last publish/pull diagnostics for this document, kept verbatim so a
    // codeAction request can replay the ones overlapping its range back to the
    // server — a server (basedpyright, notably) that gates a fix like "add missing
    // import" on seeing its own diagnostic in the request otherwise never
    // offers it.
    diagnostics: [dynamic]Cached_Diagnostic, // owned
    allocator: runtime.Allocator,
}

// One diagnostic as last reported for this document.
Cached_Diagnostic :: struct {
    start_line, start_char, end_line, end_char: int,
    json: string, // owned; the diagnostic object exactly as the server sent it
}

// A document at version 1, not yet sent.
document_init :: proc(doc: ^Document, path, text: string, encoding: Encoding, allocator := context.allocator) {
    doc.allocator = allocator
    doc.path = strings.clone(path, allocator)
    doc.uri = uri_from_path(path, allocator)
    doc.text = strings.clone(text, allocator)
    doc.lines = line_index_build(doc.text, encoding, allocator)
    doc.version = 1
    doc.open = false
}

// Replaces the text and bumps the version. The index is rebuilt because it
// borrows the text it was built over.
document_set_text :: proc(doc: ^Document, text: string) {
    line_index_destroy(&doc.lines)
    delete(doc.text, doc.allocator)
    doc.text = strings.clone(text, doc.allocator)
    doc.lines = line_index_build(doc.text, doc.lines.encoding, doc.allocator)
    doc.version += 1
}

document_destroy :: proc(doc: ^Document) {
    line_index_destroy(&doc.lines)
    delete(doc.uri, doc.allocator)
    delete(doc.path, doc.allocator)
    delete(doc.text, doc.allocator)
    delete(doc.semantic_data, doc.allocator)
    delete(doc.semantic_result_id, doc.allocator)
    for d in doc.diagnostics {
        delete(d.json, doc.allocator)
    }
    delete(doc.diagnostics)
    doc^ = {}
}

// {"textDocument":{"uri":...,"languageId":...,"version":N,"text":...}}
did_open_params :: proc(doc: ^Document, language_id: string, allocator := context.allocator) -> string {
    out := make([dynamic]u8, allocator)
    append(&out, `{"textDocument":{"uri":`)
    write_quoted(&out, doc.uri)
    append(&out, `,"languageId":`)
    write_quoted(&out, language_id)
    append(&out, `,"version":`)
    write_number(&out, doc.version)
    append(&out, `,"text":`)
    write_quoted(&out, doc.text)
    append(&out, `}}`)
    return string(out[:])
}

// The whole buffer as one content change, the form the protocol defines for a
// change with no range.
did_change_params :: proc(doc: ^Document, allocator := context.allocator) -> string {
    out := make([dynamic]u8, allocator)
    append(&out, `{"textDocument":{"uri":`)
    write_quoted(&out, doc.uri)
    append(&out, `,"version":`)
    write_number(&out, doc.version)
    append(&out, `},"contentChanges":[{"text":`)
    write_quoted(&out, doc.text)
    append(&out, `}]}`)
    return string(out[:])
}

// One content change over a byte range, converted to an LSP `Range` by the
// caller against the document's *previous* Line_Index (server_publish's, since
// document_set_text has not run yet when the range is computed). `text` is the
// replacement for that range alone, not the whole buffer.
did_change_incremental_params :: proc(
    doc: ^Document,
    start_line, start_char, end_line, end_char: int,
    text: string,
    allocator := context.allocator,
) -> string {
    out := make([dynamic]u8, allocator)
    append(&out, `{"textDocument":{"uri":`)
    write_quoted(&out, doc.uri)
    append(&out, `,"version":`)
    write_number(&out, doc.version)
    append(&out, `},"contentChanges":[{"range":{"start":{"line":`)
    write_number(&out, i64(start_line))
    append(&out, `,"character":`)
    write_number(&out, i64(start_char))
    append(&out, `},"end":{"line":`)
    write_number(&out, i64(end_line))
    append(&out, `,"character":`)
    write_number(&out, i64(end_char))
    append(&out, `}},"text":`)
    write_quoted(&out, text)
    append(&out, `}]}`)
    return string(out[:])
}

// {"textDocument":{"uri":...}} — the params of didSave and didClose. No text is
// sent with a save: the server has the buffer already.
did_identify_params :: proc(doc: ^Document, allocator := context.allocator) -> string {
    out := make([dynamic]u8, allocator)
    append(&out, `{"textDocument":{"uri":`)
    write_quoted(&out, doc.uri)
    append(&out, `}}`)
    return string(out[:])
}

// The `file:` URI of a path. The drive letter's colon is left as it is: a colon
// is legal in the path of an absolute URI, and it keeps a log line readable. The
// reader accepts the percent-encoded spelling other clients emit.
uri_from_path :: proc(path: string, allocator := context.allocator) -> string {
    out := make([dynamic]u8, 0, len(path) + 16, allocator)
    append(&out, "file://")
    if !strings.has_prefix(path, "/") && !strings.has_prefix(path, "\\") {
        append(&out, "/")
    }
    for index in 0 ..< len(path) {
        char := path[index]
        switch {
        case char == '\\':
            append(&out, '/')
        case unreserved(char):
            append(&out, char)
        case:
            // Every other byte, which includes each byte of a multi-byte
            // character, has to be escaped for the URI to survive a round trip.
            append(&out, u8('%'), HEX[char >> 4], HEX[char & 0xF])
        }
    }
    return string(out[:])
}

// The path a `file:` URI names, or ok=false when it names something else. A
// remote authority is refused rather than read as a local file.
uri_to_path :: proc(uri: string, allocator := context.allocator) -> (string, bool) {
    if !strings.has_prefix(uri, "file://") {
        return "", false
    }
    rest := uri[len("file://"):]
    if !strings.has_prefix(rest, "/") {
        at := strings.index_byte(rest, '/')
        if at < 0 || rest[:at] != "localhost" {
            return "", false
        }
        rest = rest[at:]
    }
    if at := strings.index_any(rest, "?#"); at >= 0 {
        rest = rest[:at]
    }
    if drive_prefixed(rest) {
        // "/C:/src" carries a separator the URI needs and the file system does not.
        rest = rest[1:]
    }

    out := make([dynamic]u8, 0, len(rest), allocator)
    for index := 0; index < len(rest); {
        if index + 2 < len(rest) && rest[index] == '%' {
            high, hok := hex_value(rest[index + 1])
            low, lok := hex_value(rest[index + 2])
            if hok && lok {
                append(&out, high << 4 | low)
                index += 3
                continue
            }
        }
        append(&out, rest[index])
        index += 1
    }
    return string(out[:]), true
}

// Whether two paths name one file. Windows compares without case and reads the
// two separators alike, because a URI carries only one of them.
path_equal :: proc(a, b: string) -> bool {
    when ODIN_OS == .Windows {
        if len(a) != len(b) {
            return false
        }
        for index in 0 ..< len(a) {
            if path_byte(a[index]) != path_byte(b[index]) {
                return false
            }
        }
        return true
    } else {
        return a == b
    }
}

// The `languageId` of the file at `path`: its whole name where that names a
// language, else its extension. Every didOpen goes through this, so a restart's
// re-open names the same language the first open did.
language_id_for_path :: proc(path: string) -> string {
    slash := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
    switch path[slash + 1:] {
    case "Makefile", "makefile", "GNUmakefile":
        return "makefile"
    case "Dockerfile", "dockerfile", "Containerfile":
        return "dockerfile"
    case "CMakeLists.txt":
        return "cmake"
    }
    dot := strings.last_index_byte(path[slash + 1:], '.')
    return language_id_for(dot < 0 ? "" : path[slash + 1 + dot:])
}

// The `languageId` of didOpen. A server that serves one language ignores it, but
// clangd reads it to tell a header from a source file. An extension nothing names
// passes through without its dot.
language_id_for :: proc(ext: string) -> string {
    switch ext {
    case ".c":
        return "c"
    case ".h", ".hpp", ".hh", ".hxx", ".cpp", ".cc", ".cxx":
        return "cpp"
    case ".rs":
        return "rust"
    case ".go":
        return "go"
    case ".py", ".pyi":
        return "python"
    case ".ts", ".mts", ".cts":
        return "typescript"
    case ".tsx":
        return "typescriptreact"
    case ".js", ".mjs", ".cjs":
        return "javascript"
    case ".jsx":
        return "javascriptreact"
    case ".lua":
        return "lua"
    case ".zig", ".zon":
        return "zig"
    case ".odin":
        return "odin"
    }
    return strings.has_prefix(ext, ".") ? ext[1:] : ext
}

@(private)
HEX := "0123456789ABCDEF"

// The characters a URI path may carry as they are. '/' is the separator itself
// and ':' belongs to the drive letter.
@(private)
unreserved :: proc(char: u8) -> bool {
    switch char {
    case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~', '/', ':':
        return true
    }
    return false
}

@(private)
hex_value :: proc(char: u8) -> (u8, bool) {
    switch char {
    case '0' ..= '9':
        return char - '0', true
    case 'a' ..= 'f':
        return char - 'a' + 10, true
    case 'A' ..= 'F':
        return char - 'A' + 10, true
    }
    return 0, false
}

// True for "/C:/..." and for the "/C%3A/..." other clients write.
@(private)
drive_prefixed :: proc(text: string) -> bool {
    if len(text) < 3 || text[0] != '/' {
        return false
    }
    switch text[1] {
    case 'A' ..= 'Z', 'a' ..= 'z':
    case:
        return false
    }
    if text[2] == ':' {
        return true
    }
    return len(text) >= 5 && text[2] == '%' && text[3] == '3' && (text[4] == 'A' || text[4] == 'a')
}

@(private)
path_byte :: proc(char: u8) -> u8 {
    if char == '\\' {
        return '/'
    }
    if char >= 'A' && char <= 'Z' {
        return char + ('a' - 'A')
    }
    return char
}

@(private)
write_number :: proc(out: ^[dynamic]u8, value: i64) {
    digits: [32]u8
    append(out, strconv.write_int(digits[:], value, 10))
}
