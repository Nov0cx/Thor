package lsp

import "core:encoding/json"
import "core:strings"
import "core:testing"

import lang ".."

// Run from the repository root: odin test lang/lsp

// The paths spelled the way the platform spells them: the URI of a drive-letter
// path is not the URI of a rooted one.
when ODIN_OS == .Windows {
    @(private = "file")
    FILE :: "C:/ws/main.fake"
    @(private = "file")
    FILE_URI :: "file:///C:/ws/main.fake"
    @(private = "file")
    OTHER :: "C:/ws/other.fake"
    @(private = "file")
    OTHER_URI :: "file:///C:/ws/other.fake"
} else {
    @(private = "file")
    FILE :: "/ws/main.fake"
    @(private = "file")
    FILE_URI :: "file:///ws/main.fake"
    @(private = "file")
    OTHER :: "/ws/other.fake"
    @(private = "file")
    OTHER_URI :: "file:///ws/other.fake"
}

// A Server with no process behind it: a decoder reads only the negotiated
// encoding, the token legend and the documents it holds.
@(private = "file")
held_server :: proc(encoding := Encoding.Utf16) -> ^Server {
    s := new(Server, context.allocator)
    s.allocator = context.allocator
    s.docs = make([dynamic]^Document, context.allocator)
    s.caps.encoding = encoding
    return s
}

@(private = "file")
held_destroy :: proc(s: ^Server) {
    for doc in s.docs {
        document_destroy(doc)
        free(doc, s.allocator)
    }
    delete(s.docs)
    capabilities_destroy(&s.caps)
    free(s, s.allocator)
}

@(private = "file")
held_legend :: proc(s: ^Server, names: []string) {
    entries := make([]Token_Legend_Entry, len(names), s.allocator)
    for name, index in names {
        entries[index].kind, entries[index].valid = token_kind_of(name)
    }
    s.caps.token_legend = entries
    s.caps.allocator = s.allocator
}

@(private = "file")
request_for :: proc(kind: lang.Request_Kind, source: string, offset := 0) -> lang.Request {
    return lang.Request{kind = kind, path = FILE, ext = ".fake", source = source, offset = offset}
}

// Runs one reply through the real decoder, on the real Ask a worker builds.
@(private = "file")
decode_reply :: proc(s: ^Server, req: ^lang.Request, body: string) -> lang.Result {
    value, err := json.parse(
        transmute([]u8)body,
        spec = .JSON,
        parse_integers = true,
        allocator = context.temp_allocator,
    )
    if err != .None {
        return {}
    }
    ask := Ask {
        server = s,
        req    = req,
        uri    = uri_from_path(req.path, context.temp_allocator),
        lines  = line_index_build(req.source, s.caps.encoding, context.temp_allocator),
        texts  = make(map[string]string, allocator = context.temp_allocator),
        raws   = make(map[string]^Line_Index, allocator = context.temp_allocator),
    }
    res := lang.Result {
        kind = req.kind,
    }
    request_decode(&ask, value, &res)
    return res
}

// Frees exactly the fields these decoders fill, the way the Manager does on the
// main thread.
@(private = "file")
result_release :: proc(res: ^lang.Result) {
    delete(res.location.path)
    delete(res.hover.text)
    for entry in res.signature.entries {
        delete(entry.label)
    }
    delete(res.signature.entries)
    for symbol in res.symbols {
        delete(symbol.name)
        delete(symbol.kind)
        delete(symbol.signature)
        delete(symbol.path)
    }
    delete(res.symbols)
    for edit in res.edits {
        delete(edit.path)
        delete(edit.old_text)
        delete(edit.new_text)
    }
    delete(res.edits)
    for action in res.actions {
        delete(action.title)
        delete(action.kind)
        for edit in action.edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(action.edits)
    }
    delete(res.actions)
    delete(res.tokens)
    delete(res.report.scope)
    for item in res.report.items {
        delete(item.path)
        delete(item.message)
    }
    delete(res.report.items)
}

// One document the server already holds, the way server_document builds it.
@(private = "file")
held_document :: proc(s: ^Server, path, text: string, revision: u64) -> ^Document {
    doc := new(Document, s.allocator)
    document_init(doc, path, text, s.caps.encoding, s.allocator)
    doc.revision = revision
    append(&s.docs, doc)
    return doc
}

// Runs one pushed notification through the real decoder.
@(private = "file")
decode_push :: proc(s: ^Server, body: string) -> (lang.Result, bool) {
    value, err := json.parse(
        transmute([]u8)body,
        spec = .JSON,
        parse_integers = true,
        allocator = context.temp_allocator,
    )
    if err != .None {
        return {}, false
    }
    return decode_publish_diagnostics(s, value)
}

@(private = "file")
SOURCE :: "alpha beta\ngamma delta\n"

// A single Location is the jump itself, and its range gives both ends.
@(test)
test_decode_definition_location :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Definition, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"uri":"` + FILE_URI + `","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}}}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok, "a single location should resolve")
    testing.expect_value(t, res.location.path, FILE)
    testing.expect_value(t, res.location.start, 11)
    testing.expect_value(t, res.location.end, 16)
}

// A LocationLink names the target apart from the origin, and its selection range
// is the one to land on.
@(test)
test_decode_definition_location_link :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Definition, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"targetUri":"` +
        FILE_URI +
        `",` +
        `"targetRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":11}},` +
        `"targetSelectionRange":{"start":{"line":1,"character":6},"end":{"line":1,"character":11}}}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok, "a location link should resolve")
    testing.expect_value(t, res.location.start, 17)
    testing.expect_value(t, res.location.end, 22)
}

// Several hits are the candidate picker, which reads the rows find-usages reads.
@(test)
test_decode_definition_candidates :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Definition, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"uri":"` +
        FILE_URI +
        `","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}},` +
        `{"uri":"` +
        FILE_URI +
        `","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}}}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok, "two hits should fill the picker")
    testing.expect_value(t, len(res.symbols), 2)
    if len(res.symbols) != 2 {
        return
    }
    testing.expect_value(t, res.symbols[0].kind, "reference")
    testing.expect_value(t, res.symbols[0].signature, "alpha beta")
    testing.expect_value(t, res.symbols[0].line, 1)
    testing.expect_value(t, res.symbols[1].signature, "gamma delta")
    testing.expect_value(t, res.symbols[1].offset, 11)
    testing.expect_value(t, res.symbols[1].line, 2)
}

// A URI that names no file leaves nothing, rather than a jump to the top of one.
@(test)
test_decode_definition_refuses_a_foreign_uri :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Definition, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"uri":"jdt://contents/rt.jar","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}`,
    )
    defer result_release(&res)
    testing.expect(t, !res.ok, "a URI that is not a file should find nothing")
}

// MarkupContent, with the fences and backticks the popup cannot draw removed.
@(test)
test_decode_hover_markup :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Hover, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"contents":{"kind":"markdown","value":"` +
        "```c\\nint alpha(void)\\n```\\nThe `alpha` count." +
        `"},` +
        `"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, res.hover.text, "int alpha(void)\nThe alpha count.")
    testing.expect_value(t, res.hover.start, 0)
    testing.expect_value(t, res.hover.end, 5)
}

// MarkedString, alone and in an array, and a reply with no range of its own: the
// identifier under the caret is what was described.
@(test)
test_decode_hover_marked_strings :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Hover, SOURCE, 13) // inside "gamma"

    res := decode_reply(s, &req, `{"contents":["gamma: int",{"language":"c","value":"a counter"}]}`)
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, res.hover.text, "gamma: int\na counter")
    testing.expect_value(t, res.hover.start, 11)
    testing.expect_value(t, res.hover.end, 16)
}

// Hover with nothing in it is not a hover.
@(test)
test_decode_hover_empty :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Hover, SOURCE, 0)

    for body in ([]string{"null", "{}", `{"contents":""}`, `{"contents":[]}`, `{"contents":{"kind":"markdown"}}`}) {
        res := decode_reply(s, &req, body)
        testing.expectf(t, !res.ok, "%q should hover nothing", body)
        result_release(&res)
    }
}

// The DocumentSymbol tree flattens depth first, and selectionRange is the jump
// while range gives the line the declaration opens on.
@(test)
test_decode_document_symbols_tree :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Document_Symbols, SOURCE)

    res := decode_reply(
        s,
        &req,
        `[{"name":"Outer","kind":23,"detail":"struct Outer",` +
        `"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":11}},` +
        `"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},` +
        `"children":[{"name":"inner","kind":8,` +
        `"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":11}},` +
        `"selectionRange":{"start":{"line":1,"character":6},"end":{"line":1,"character":11}}}]}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.symbols), 2)
    if len(res.symbols) != 2 {
        return
    }
    testing.expect_value(t, res.symbols[0].name, "Outer")
    testing.expect_value(t, res.symbols[0].kind, "type")
    testing.expect_value(t, res.symbols[0].signature, "struct Outer")
    testing.expect_value(t, res.symbols[0].offset, 0)
    testing.expect_value(t, res.symbols[0].line, 1)
    testing.expect_value(t, res.symbols[1].name, "inner")
    testing.expect_value(t, res.symbols[1].kind, "field")
    // No detail: the declaration line stands in for it.
    testing.expect_value(t, res.symbols[1].signature, "gamma delta")
    testing.expect_value(t, res.symbols[1].offset, 17)
    testing.expect_value(t, res.symbols[1].line, 2)
}

// The flat SymbolInformation form carries its file in the entry itself.
@(test)
test_decode_document_symbols_flat :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Document_Symbols, SOURCE)

    res := decode_reply(
        s,
        &req,
        `[{"name":"alpha","kind":12,"location":{"uri":"` +
        FILE_URI +
        `",` +
        `"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.symbols), 1)
    if len(res.symbols) != 1 {
        return
    }
    testing.expect_value(t, res.symbols[0].kind, "function")
    testing.expect_value(t, res.symbols[0].path, FILE)
    testing.expect_value(t, res.symbols[0].offset, 0)
}

// Every usage carries the source line it sits on, and a hit in a second file the
// server also holds converts against that file's own text.
@(test)
test_decode_references_two_files :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    server_document(s, OTHER, "one\nalpha two\n", 1)
    req := request_for(.References, SOURCE, 0) // on "alpha"

    res := decode_reply(
        s,
        &req,
        `[{"uri":"` +
        OTHER_URI +
        `","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}}},` +
        `{"uri":"` +
        FILE_URI +
        `","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.symbols), 2)
    if len(res.symbols) != 2 {
        return
    }
    for symbol in res.symbols {
        testing.expect_value(t, symbol.name, "alpha")
        testing.expect_value(t, symbol.kind, "reference")
    }
    // Sorted by (path, offset), so the request's own file is not simply first.
    testing.expect(t, res.symbols[0].path <= res.symbols[1].path, "the rows are not sorted by path")
    for symbol in res.symbols {
        if symbol.path == FILE {
            testing.expect_value(t, symbol.offset, 0)
            testing.expect_value(t, symbol.signature, "alpha beta")
            testing.expect_value(t, symbol.line, 1)
        } else {
            testing.expect_value(t, symbol.offset, 4)
        }
    }
}

// A parameter label spelled as a substring of the signature label.
@(test)
test_decode_signature_help_substring :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Signature_Help, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"signatures":[{"label":"add(int a, int b)","parameters":[{"label":"int a"},{"label":"int b"}]}],` +
        `"activeSignature":0,"activeParameter":1}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.signature.entries), 1)
    if len(res.signature.entries) != 1 {
        return
    }
    testing.expect_value(t, res.signature.active, 0)
    testing.expect_value(t, res.signature.entries[0].label, "add(int a, int b)")
    testing.expect_value(t, res.signature.entries[0].active_start, 11)
    testing.expect_value(t, res.signature.entries[0].active_end, 16)
}

// The offset form counts UTF-16 units over the label, not bytes and not the
// document, so an astral character before the parameter moves the two apart.
@(test)
test_decode_signature_help_label_offsets :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Signature_Help, SOURCE, 0)

    // "add :: proc(𝔞: int, b: int)": the parameter starts at UTF-16 unit 12 and
    // byte 12, and ends at unit 19 and byte 21 — the astral rune costs two units
    // and four bytes.
    res := decode_reply(
        s,
        &req,
        `{"signatures":[{"label":"add :: proc(\ud835\udd1e: int, b: int)",` +
        `"parameters":[{"label":[12,19]},{"label":[21,27]}],"activeParameter":0}]}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.signature.entries), 1)
    if len(res.signature.entries) != 1 {
        return
    }
    testing.expect_value(t, res.signature.entries[0].active_start, 12)
    testing.expect_value(t, res.signature.entries[0].active_end, 21)
}

// An overload set is several entries, and activeSignature picks the one to
// emphasize. A signature's own activeParameter overrides the reply's.
@(test)
test_decode_signature_help_overloads :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Signature_Help, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"signatures":[` +
        `{"label":"add(int a)","parameters":[{"label":"int a"}]},` +
        `{"label":"add(int a, int b)","parameters":[{"label":"int a"},{"label":"int b"}],"activeParameter":1}` +
        `],"activeSignature":1,"activeParameter":0}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.signature.entries), 2)
    if len(res.signature.entries) != 2 {
        return
    }
    testing.expect_value(t, res.signature.active, 1)
    testing.expect_value(t, res.signature.entries[0].active_start, 4)
    testing.expect_value(t, res.signature.entries[1].active_start, 11)
}

// The CompletionList form, the padding some servers put on a label, and the
// snippet that must not be inserted as it stands.
@(test)
test_decode_completion_list :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"isIncomplete":true,"items":[` +
        `{"label":" alpha","kind":3,"detail":"int alpha(void)"},` +
        `{"label":"beta","kind":6,"insertText":"beta_impl"},` +
        `{"label":"gamma","kind":3,"insertText":"gamma($1)","insertTextFormat":2},` +
        `{"label":"Delta","kind":7}]}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.symbols), 4)
    if len(res.symbols) != 4 {
        return
    }
    testing.expect_value(t, res.symbols[0].name, "alpha")
    testing.expect_value(t, res.symbols[0].kind, "function")
    testing.expect_value(t, res.symbols[0].signature, "int alpha(void)")
    // insertText is what the server means to be typed.
    testing.expect_value(t, res.symbols[1].name, "beta_impl")
    testing.expect_value(t, res.symbols[1].kind, "var")
    // A snippet is refused: snippetSupport is advertised false.
    testing.expect_value(t, res.symbols[2].name, "gamma")
    testing.expect_value(t, res.symbols[3].kind, "type")
    testing.expect_value(t, res.symbols[3].signature, "Delta")
}

// The bare CompletionItem[] form decodes the same way.
@(test)
test_decode_completion_array :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 0)

    res := decode_reply(s, &req, `[{"label":"alpha","kind":21}]`)
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.symbols), 1)
    if len(res.symbols) == 1 {
        testing.expect_value(t, res.symbols[0].kind, "constant")
    }
}

// The delta rule: a new line resets the character, the same line adds to it, and
// a token type Thor drops leaves the grammar's color alone.
@(test)
test_decode_semantic_tokens :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_legend(s, {"variable", "function", "keyword"})
    req := request_for(.Semantic_Tokens, SOURCE)

    res := decode_reply(s, &req, `{"data":[0,0,5,0,0, 0,6,4,1,0, 1,0,5,2,0, 0,6,5,0,0]}`)
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.tokens), 3)
    if len(res.tokens) != 3 {
        return
    }
    testing.expect_value(t, res.tokens[0], lang.Semantic_Token{start = 0, end = 5, kind = .Local})
    testing.expect_value(t, res.tokens[1], lang.Semantic_Token{start = 6, end = 10, kind = .Procedure})
    // The `keyword` at line 1 is dropped; the next token on that line is not.
    testing.expect_value(t, res.tokens[2], lang.Semantic_Token{start = 17, end = 22, kind = .Local})
}

// A server that advertised no legend has no token indices to read, so the reply
// is not guessed at.
@(test)
test_decode_semantic_tokens_without_a_legend :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Semantic_Tokens, SOURCE)

    res := decode_reply(s, &req, `{"data":[0,0,5,0,0]}`)
    defer result_release(&res)
    testing.expect(t, !res.ok, "no legend means no tokens")
}

// A full reply carrying a resultId caches it, and the flat array it decoded,
// on the document — what turns the *next* request into a delta one.
@(test)
test_decode_semantic_tokens_caches_result_id :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_legend(s, {"variable", "function"})
    held_document(s, FILE, "", 0)
    req := request_for(.Semantic_Tokens, SOURCE)

    res := decode_reply(s, &req, `{"resultId":"r1","data":[0,0,5,0,0, 0,6,4,1,0]}`)
    defer result_release(&res)

    testing.expect(t, res.ok)
    id := server_semantic_result_id(s, FILE, context.temp_allocator)
    testing.expect_value(t, id, "r1")
    data := server_semantic_data(s, FILE, context.temp_allocator)
    testing.expect_value(t, len(data), 10)
}

// A delta reply's edits apply against the cached array from the previous
// fetch, and the merged, decoded result is the same shape a `full` reply of
// the same content would give.
@(test)
test_decode_semantic_tokens_delta :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_legend(s, {"variable", "function"})
    held_document(s, FILE, "", 0)
    req := request_for(.Semantic_Tokens, SOURCE)

    full := decode_reply(s, &req, `{"resultId":"r1","data":[0,0,5,0,0, 0,6,4,1,0]}`)
    result_release(&full)

    // Appends a third token — line 1, "gamma" — without touching the first two.
    delta := decode_reply(s, &req, `{"resultId":"r2","edits":[{"start":10,"deleteCount":0,"data":[1,0,5,0,0]}]}`)
    defer result_release(&delta)

    testing.expect(t, delta.ok)
    testing.expect_value(t, len(delta.tokens), 3)
    if len(delta.tokens) != 3 {
        return
    }
    testing.expect_value(t, delta.tokens[0], lang.Semantic_Token{start = 0, end = 5, kind = .Local})
    testing.expect_value(t, delta.tokens[1], lang.Semantic_Token{start = 6, end = 10, kind = .Procedure})
    testing.expect_value(t, delta.tokens[2], lang.Semantic_Token{start = 11, end = 16, kind = .Local})
    testing.expect_value(t, server_semantic_result_id(s, FILE, context.temp_allocator), "r2")
}

// A delta whose edit range falls outside the cached array (a restart changed
// what the server thinks it sent) answers nothing and drops the cache, so the
// next request asks for `full` again instead of feeding a bad array back into
// another delta.
@(test)
test_decode_semantic_tokens_delta_mismatch_clears_cache :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_legend(s, {"variable", "function"})
    held_document(s, FILE, "", 0)
    req := request_for(.Semantic_Tokens, SOURCE)

    full := decode_reply(s, &req, `{"resultId":"r1","data":[0,0,5,0,0, 0,6,4,1,0]}`)
    result_release(&full)

    bad := decode_reply(s, &req, `{"resultId":"r2","edits":[{"start":999,"deleteCount":0,"data":[]}]}`)
    defer result_release(&bad)

    testing.expect(t, !bad.ok, "an out-of-range edit must not produce tokens")
    testing.expect_value(t, server_semantic_result_id(s, FILE, context.temp_allocator), "")
}

// Every kind, given a reply of the wrong shape, finds nothing and leaks nothing.
@(test)
test_decode_refuses_a_bad_reply :: proc(t: ^testing.T) {
    Case :: struct {
        kind: lang.Request_Kind,
        body: string,
    }
    cases := []Case {
        {.Definition, "null"},
        {.Definition, "[]"},
        {.Definition, `{"uri":"` + FILE_URI + `"}`},
        {.Definition, `[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]`},
        {.Hover, "[]"},
        {.Hover, `{"contents":42}`},
        {.Document_Symbols, "null"},
        {.Document_Symbols, "[]"},
        {.Document_Symbols, `[{"kind":12}]`},
        {.Document_Symbols, `[{"name":"alpha"}]`},
        {.References, "null"},
        {.References, "[]"},
        {.References, `[{"uri":"` + FILE_URI + `"}]`},
        {.Signature_Help, "null"},
        {.Signature_Help, `{"signatures":[]}`},
        {.Signature_Help, `{"signatures":[{"documentation":"no label"}]}`},
        {.Completion, "null"},
        {.Completion, "[]"},
        {.Completion, `{"items":[]}`},
        {.Completion, `[{"kind":3}]`},
        {.Semantic_Tokens, "null"},
        {.Semantic_Tokens, `{"data":[]}`},
        {.Semantic_Tokens, `{"data":[0,0]}`},
    }

    for entry in cases {
        s := held_server()
        held_legend(s, {"variable"})
        req := request_for(entry.kind, SOURCE, 0)
        res := decode_reply(s, &req, entry.body)
        testing.expectf(t, !res.ok, "%v answered %q with a result", entry.kind, entry.body)
        result_release(&res)
        held_destroy(s)
    }
}

// A push against a document the server holds: 1-based line, 1-based byte column,
// and the editor revision that text came from.
@(test)
test_decode_publish_diagnostics :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_document(s, FILE, SOURCE, 7)

    res, decoded := decode_push(
        s,
        `{"uri":"` +
        FILE_URI +
        `","diagnostics":[` +
        `{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":10}},"severity":1,"message":"undefined"},` +
        `{"range":{"start":{"line":1,"character":6},"end":{"line":1,"character":11}},"severity":2,"message":"unused"}]}`,
    )
    defer result_release(&res)

    testing.expect(t, decoded, "the push was dropped")
    testing.expect(t, res.ok)
    testing.expect_value(t, res.kind, lang.Request_Kind.Diagnostics)
    testing.expect_value(t, res.revision, u64(7))
    testing.expect_value(t, res.report.scope, FILE)
    testing.expect_value(t, len(res.report.items), 2)
    if len(res.report.items) != 2 {
        return
    }
    testing.expect_value(t, res.report.items[0].path, FILE)
    testing.expect_value(t, res.report.items[0].line, 1)
    testing.expect_value(t, res.report.items[0].col, 7)
    testing.expect_value(t, res.report.items[0].severity, lang.Diagnostic_Severity.Error)
    testing.expect_value(t, res.report.items[0].message, "undefined")
    testing.expect_value(t, res.report.items[1].line, 2)
    testing.expect_value(t, res.report.items[1].col, 7)
    testing.expect_value(t, res.report.items[1].severity, lang.Diagnostic_Severity.Warning)
}

// A publish also caches each diagnostic verbatim on the Document, `code`
// included — the seam's own lang.Diagnostic drops it, but a codeAction request
// needs it back to get a server like basedpyright to offer a fix that depends on it.
@(test)
test_decode_publish_diagnostics_caches_verbatim :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    doc := held_document(s, FILE, SOURCE, 7)

    res, decoded := decode_push(
        s,
        `{"uri":"` +
        FILE_URI +
        `","diagnostics":[` +
        `{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":10}},"severity":1,"code":"reportMissingImports","message":"undefined"}]}`,
    )
    defer result_release(&res)

    testing.expect(t, decoded, "the push was dropped")
    testing.expect_value(t, len(doc.diagnostics), 1)
    if len(doc.diagnostics) != 1 {
        return
    }
    cached := doc.diagnostics[0]
    testing.expect_value(t, cached.start_line, 0)
    testing.expect_value(t, cached.start_char, 6)
    testing.expect_value(t, cached.end_line, 0)
    testing.expect_value(t, cached.end_char, 10)
    testing.expect(t, strings.contains(cached.json, `"code":"reportMissingImports"`), "the code field was dropped from the cache")

    // A second publish replaces the cache instead of appending to it.
    res2, decoded2 := decode_push(s, `{"uri":"` + FILE_URI + `","diagnostics":[]}`)
    defer result_release(&res2)
    testing.expect(t, decoded2)
    testing.expect_value(t, len(doc.diagnostics), 0)
}

// The protocol's four severities, as the two the editor draws. A diagnostic that
// named none is an error.
@(test)
test_decode_diagnostic_severities :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_document(s, FILE, SOURCE, 1)

    span :: `{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}`
    res, decoded := decode_push(
        s,
        `{"uri":"` +
        FILE_URI +
        `","diagnostics":[` +
        span +
        `,"severity":1,"message":"a"},` +
        span +
        `,"severity":2,"message":"b"},` +
        span +
        `,"severity":3,"message":"c"},` +
        span +
        `,"severity":4,"message":"d"},` +
        span +
        `,"message":"e"}]}`,
    )
    defer result_release(&res)

    testing.expect(t, decoded)
    want := [5]lang.Diagnostic_Severity{.Error, .Warning, .Warning, .Warning, .Error}
    testing.expect_value(t, len(res.report.items), len(want))
    if len(res.report.items) != len(want) {
        return
    }
    for severity, index in want {
        testing.expect_value(t, res.report.items[index].severity, severity)
    }
}

// An item with no message and one with no range are left out; the rest of the
// report still arrives.
@(test)
test_decode_diagnostic_drops_malformed_items :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_document(s, FILE, SOURCE, 1)

    res, decoded := decode_push(
        s,
        `{"uri":"` +
        FILE_URI +
        `","diagnostics":[` +
        `{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}},` +
        `{"message":"no range"},` +
        `42,` +
        `{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"kept"}]}`,
    )
    defer result_release(&res)

    testing.expect(t, decoded)
    testing.expect_value(t, len(res.report.items), 1)
    if len(res.report.items) != 1 {
        return
    }
    testing.expect_value(t, res.report.items[0].message, "kept")
}

// An empty array is the server saying the file is clean, which the editor needs to
// retire the squiggles it drew last time.
@(test)
test_decode_publish_diagnostics_empty_is_clean :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_document(s, FILE, SOURCE, 3)

    res, decoded := decode_push(s, `{"uri":"` + FILE_URI + `","diagnostics":[]}`)
    defer result_release(&res)

    testing.expect(t, decoded, "a clean file was dropped instead of reported")
    testing.expect(t, res.ok)
    testing.expect_value(t, res.report.scope, FILE)
    testing.expect_value(t, len(res.report.items), 0)
}

// A push nothing can be applied to: a file the editor never opened, a URI that
// names no file, and text the server has already been sent past.
@(test)
test_decode_publish_diagnostics_dropped :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    doc := held_document(s, FILE, SOURCE, 1)
    doc.version = 4

    item :: `,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"x"}]}`
    bodies := []string {
        `{"uri":"` + OTHER_URI + `"` + item,
        `{"uri":"http://example.com/main.fake"` + item,
        `{"uri":"` + FILE_URI + `","version":3` + item,
        `{"uri":"` + FILE_URI + `"}`,
        `{"diagnostics":[]}`,
    }
    for body in bodies {
        res, decoded := decode_push(s, body)
        testing.expectf(t, !decoded, "%q was decoded", body)
        result_release(&res)
    }

    // The version the server was last told about is the one that lands.
    res, decoded := decode_push(s, `{"uri":"` + FILE_URI + `","version":4` + item)
    defer result_release(&res)
    testing.expect(t, decoded, "the current version was dropped")
    testing.expect_value(t, len(res.report.items), 1)
}

// A pull report reads the same items, against the buffer the request carried.
@(test)
test_decode_pull_diagnostics :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Diagnostics, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"kind":"full","items":[` +
        `{"range":{"start":{"line":1,"character":6},"end":{"line":1,"character":11}},"severity":2,"message":"unused"}]}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, res.report.scope, FILE)
    testing.expect_value(t, len(res.report.items), 1)
    if len(res.report.items) != 1 {
        return
    }
    testing.expect_value(t, res.report.items[0].path, FILE)
    testing.expect_value(t, res.report.items[0].line, 2)
    testing.expect_value(t, res.report.items[0].col, 7)
    testing.expect_value(t, res.report.items[0].severity, lang.Diagnostic_Severity.Warning)

    // A full report with no items is the file being clean.
    clean := decode_reply(s, &req, `{"kind":"full","items":[]}`)
    defer result_release(&clean)
    testing.expect(t, clean.ok)
    testing.expect_value(t, len(clean.report.items), 0)
}

// A pull report also caches its items verbatim on the Document, the same as a
// push does, so either diagnostics source can feed a later codeAction request.
@(test)
test_decode_pull_diagnostics_caches_verbatim :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    doc := held_document(s, FILE, SOURCE, 1)
    req := request_for(.Diagnostics, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"kind":"full","items":[` +
        `{"range":{"start":{"line":1,"character":6},"end":{"line":1,"character":11}},"severity":2,"code":"unused-import","message":"unused"}]}`,
    )
    defer result_release(&res)

    testing.expect_value(t, len(doc.diagnostics), 1)
    if len(doc.diagnostics) != 1 {
        return
    }
    testing.expect(t, strings.contains(doc.diagnostics[0].json, `"code":"unused-import"`), "the code field was dropped from the cache")
}

// An "unchanged" report carries no items, so it answers nothing rather than
// retiring the diagnostics that are drawn.
@(test)
test_decode_pull_diagnostics_unchanged :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Diagnostics, SOURCE, 0)

    res := decode_reply(s, &req, `{"kind":"unchanged","resultId":"7"}`)
    defer result_release(&res)
    testing.expect(t, !res.ok, "an unchanged report must find nothing")
    testing.expect_value(t, len(res.report.items), 0)
}

// workspace/symbol answers the flat shape, in files the request never named.
@(test)
test_decode_workspace_symbols :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_document(s, OTHER, "one\ntwo\n", 1)
    req := request_for(.Workspace_Symbols, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"name":"alpha","kind":12,"location":{"uri":"` +
        FILE_URI +
        `","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}},` +
        `{"name":"two","kind":10,"detail":"an enum","location":{"uri":"` +
        OTHER_URI +
        `","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}}}},` +
        `{"name":"lazy","kind":12}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    // The third named no range at all, the shape a server that resolves lazily
    // sends; Thor never asked for that, so it is left out.
    testing.expect_value(t, len(res.symbols), 2)
    if len(res.symbols) != 2 {
        return
    }
    testing.expect_value(t, res.symbols[0].name, "alpha")
    testing.expect_value(t, res.symbols[0].kind, "function")
    testing.expect_value(t, res.symbols[0].path, FILE)
    testing.expect_value(t, res.symbols[0].offset, 0)
    testing.expect_value(t, res.symbols[1].name, "two")
    testing.expect_value(t, res.symbols[1].kind, "enum")
    testing.expect_value(t, res.symbols[1].path, OTHER)
    testing.expect_value(t, res.symbols[1].offset, 4)
    testing.expect_value(t, res.symbols[1].signature, "an enum")
}

// The `changes` map form, spanning the request's own file and one already open.
@(test)
test_decode_rename_changes_map :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_document(s, OTHER, "one\nalpha two\n", 1)
    req := request_for(.Rename, SOURCE, 0) // caret on "alpha"

    res := decode_reply(
        s,
        &req,
        `{"changes":{"` +
        FILE_URI +
        `":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"renamed"}],"` +
        OTHER_URI +
        `":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}},"newText":"renamed"}]}}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.edits), 2)
    if len(res.edits) != 2 {
        return
    }
    // Sorted ascending by (path, start); "main" sorts before "other" on both
    // platform spellings.
    testing.expect_value(t, res.edits[0].path, FILE)
    testing.expect_value(t, res.edits[1].path, OTHER)
    for edit in res.edits {
        testing.expect_value(t, edit.old_text, "alpha")
        testing.expect_value(t, edit.new_text, "renamed")
    }
}

// The `documentChanges` / TextDocumentEdit form.
@(test)
test_decode_rename_document_changes :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Rename, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"documentChanges":[{"textDocument":{"uri":"` +
        FILE_URI +
        `","version":1},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"renamed"}]}]}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.edits), 1)
    if len(res.edits) != 1 {
        return
    }
    testing.expect_value(t, res.edits[0].path, FILE)
    testing.expect_value(t, res.edits[0].old_text, "alpha")
    testing.expect_value(t, res.edits[0].new_text, "renamed")
}

// A CreateFile entry anywhere in documentChanges refuses the whole rename: the
// seam cannot express a resource operation.
@(test)
test_decode_rename_refuses_resource_operation :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Rename, SOURCE, 0)

    res := decode_reply(s, &req, `{"documentChanges":[{"kind":"create","uri":"` + OTHER_URI + `"}]}`)
    defer result_release(&res)

    testing.expect(t, !res.ok, "a resource operation must refuse the whole rename")
    testing.expect(t, res.edits == nil)
}

// A range in a file that is neither open nor readable on disk cannot have its
// old_text reconstructed, which refuses the whole rename rather than dropping
// just that one edit.
@(test)
test_decode_rename_refuses_unreadable_file :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Rename, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"changes":{"` +
        OTHER_URI +
        `":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"x"}]}}`,
    )
    defer result_release(&res)

    testing.expect(t, !res.ok, "an unreadable file must refuse the whole rename")
    testing.expect(t, res.edits == nil)
}

// A CodeAction with an inline `edit` is kept as-is, no resolve call needed.
@(test)
test_decode_code_actions_inline_edit_kept :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Code_Actions, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"title":"Add import","kind":"quickfix","edit":{"changes":{"` +
        FILE_URI +
        `":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"// x\n"}]}}}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.actions), 1)
    if len(res.actions) != 1 {
        return
    }
    testing.expect_value(t, res.actions[0].title, "Add import")
    testing.expect_value(t, res.actions[0].kind, "quickfix")
    testing.expect_value(t, len(res.actions[0].edits), 1)
    if len(res.actions[0].edits) != 1 {
        return
    }
    testing.expect_value(t, res.actions[0].edits[0].old_text, "")
    testing.expect_value(t, res.actions[0].edits[0].new_text, "// x\n")
}

// A bare Command and a `disabled` CodeAction both drop: Thor has no
// workspace/executeCommand path, and no UI for a disabled reason.
@(test)
test_decode_code_actions_drops_command_and_disabled :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Code_Actions, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"title":"Do thing","command":{"command":"foo","title":"Do thing"}},` +
        `{"title":"Disabled fix","disabled":{"reason":"nope"},"edit":{"changes":{"` +
        FILE_URI +
        `":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"x"}]}}}]`,
    )
    defer result_release(&res)

    testing.expect(t, !res.ok)
    testing.expect(t, res.actions == nil)
}

// An action with no inline `edit` and a server that never advertised
// codeActionProvider.resolveProvider is dropped without attempting a resolve
// call — caps.resolve_actions stays false on a fresh held_server.
@(test)
test_decode_code_actions_drops_unresolvable :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Code_Actions, SOURCE, 0)

    res := decode_reply(s, &req, `[{"title":"Extract","kind":"refactor.extract"}]`)
    defer result_release(&res)

    testing.expect(t, !res.ok)
    testing.expect(t, res.actions == nil)
}

// isPreferred actions sort first; server order is kept otherwise.
@(test)
test_decode_code_actions_preferred_first :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Code_Actions, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"title":"B","kind":"quickfix","edit":{"changes":{"` +
        FILE_URI +
        `":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":10}},"newText":"x"}]}}},` +
        `{"title":"A","kind":"quickfix","isPreferred":true,"edit":{"changes":{"` +
        FILE_URI +
        `":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"y"}]}}}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.actions), 2)
    if len(res.actions) != 2 {
        return
    }
    testing.expect_value(t, res.actions[0].title, "A")
    testing.expect_value(t, res.actions[1].title, "B")
}
