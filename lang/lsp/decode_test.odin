package lsp

import "core:encoding/json"
import "core:path/filepath"
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

// The Ask a worker builds for `req`, for the paths that read it directly.
@(private = "file")
ask_for :: proc(s: ^Server, req: ^lang.Request) -> Ask {
    return Ask {
        server = s,
        req    = req,
        uri    = uri_from_path(req.path, context.temp_allocator),
        lines  = line_index_build(req.source, s.caps.encoding, context.temp_allocator),
        texts  = make(map[string]string, allocator = context.temp_allocator),
        raws   = make(map[string]^Line_Index, allocator = context.temp_allocator),
    }
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
    delete(res.doc.title)
    delete(res.doc.path)
    delete(res.doc.text)
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
    for op in res.resource_ops {
        delete(op.path)
        delete(op.new_path)
    }
    delete(res.resource_ops)
    for action in res.actions {
        delete(action.title)
        delete(action.kind)
        delete(action.command)
        delete(action.arguments)
        for edit in action.edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(action.edits)
        for op in action.resource_ops {
            delete(op.path)
            delete(op.new_path)
        }
        delete(action.resource_ops)
    }
    delete(res.actions)
    for item in res.completions {
        delete(item.label)
        delete(item.kind)
        delete(item.detail)
        delete(item.insert)
        delete(item.filter)
        delete(item.sort)
        delete(item.command)
        delete(item.arguments)
        delete(item.raw)
        for edit in item.extra_edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(item.extra_edits)
    }
    delete(res.completions)
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

// Package_Doc reads the same reply shapes as hover, but keeps the Markdown
// intact rather than flattening it — the opposite of test_decode_hover_markup.
@(test)
test_decode_package_doc_keeps_markdown :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Package_Doc, SOURCE, 0) // caret on "alpha"

    res := decode_reply(
        s,
        &req,
        `{"contents":{"kind":"markdown","value":"` +
        "# package fmt\\n\\n```odin\\nprintln :: proc(args: ..any)\\n```" +
        `"}}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect(t, strings.contains(res.doc.text, "```"), "markdown fencing must survive")
    testing.expect(t, strings.contains(res.doc.text, "# package fmt"))
    testing.expect_value(t, res.doc.title, "package alpha")
}

// A reply with nothing to show is not a package doc, same as hover.
@(test)
test_decode_package_doc_empty :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Package_Doc, SOURCE, 0)

    for body in ([]string{"null", "{}", `{"contents":""}`, `{"contents":[]}`}) {
        res := decode_reply(s, &req, body)
        testing.expectf(t, !res.ok, "%q should doc nothing", body)
        result_release(&res)
    }
}

// A hover reply names no directory of its own; the request's own file stands
// in for "the package directory the page was built from".
@(test)
test_decode_package_doc_path_is_request_dir :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Package_Doc, SOURCE, 0)

    res := decode_reply(s, &req, `{"contents":"some text"}`)
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, res.doc.path, filepath.dir(FILE))
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
// snippet that arrives as a template rather than as the text to type.
@(test)
test_decode_completion_list :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"isIncomplete":true,"items":[` +
        `{"label":" alpha","kind":3,"detail":"int alpha(void)","sortText":"0"},` +
        `{"label":"beta","kind":6,"insertText":"beta_impl","sortText":"1"},` +
        `{"label":"gamma","kind":3,"insertText":"gamma($1)","insertTextFormat":2,"sortText":"2"},` +
        `{"label":"Delta","kind":7,"sortText":"3"}]}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect(t, res.incomplete, "isIncomplete says the list must be asked for again")
    testing.expect_value(t, len(res.completions), 4)
    if len(res.completions) != 4 {
        return
    }
    testing.expect_value(t, res.completions[0].label, "alpha")
    testing.expect_value(t, res.completions[0].kind, "function")
    testing.expect_value(t, res.completions[0].detail, "int alpha(void)")
    // insertText is what the server means to be typed.
    testing.expect_value(t, res.completions[1].insert, "beta_impl")
    testing.expect_value(t, res.completions[1].kind, "var")
    // A snippet keeps its placeholders and says so; the editor expands it.
    testing.expect_value(t, res.completions[2].insert, "gamma($1)")
    testing.expect(t, res.completions[2].snippet, "insertTextFormat 2 is a template")
    testing.expect_value(t, res.completions[3].kind, "type")
    testing.expect_value(t, res.completions[3].detail, "Delta")
    // No range of its own leaves the editor to replace the word being typed.
    testing.expect_value(t, res.completions[0].start, -1)
    testing.expect_value(t, res.completions[0].end, -1)
}

// The bare CompletionItem[] form decodes the same way, and a list that does not
// say otherwise is complete — the editor may narrow it as the word grows.
@(test)
test_decode_completion_array :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 0)

    res := decode_reply(s, &req, `[{"label":"alpha","kind":21}]`)
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect(t, !res.incomplete, "an array carries no isIncomplete, so the list is whole")
    testing.expect_value(t, len(res.completions), 1)
    if len(res.completions) == 1 {
        testing.expect_value(t, res.completions[0].kind, "constant")
    }
}

// sortText is the order the server wants, not the order it sent; a candidate
// without one sorts by its label.
@(test)
test_decode_completion_sorts_by_sort_text :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"label":"zeta","sortText":"0001"},` +
        `{"label":"alpha","sortText":"0002"},` +
        `{"label":"beta","sortText":"0003"}]`,
    )
    defer result_release(&res)

    testing.expect_value(t, len(res.completions), 3)
    if len(res.completions) != 3 {
        return
    }
    testing.expect_value(t, res.completions[0].label, "zeta")
    testing.expect_value(t, res.completions[1].label, "alpha")
    testing.expect_value(t, res.completions[2].label, "beta")
}

// textEdit names its own text and the byte range it replaces; filterText is what
// the editor matches the typed word against when the label is spelled otherwise.
@(test)
test_decode_completion_text_edit :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 5)

    res := decode_reply(
        s,
        &req,
        `[{"label":"alphabet","filterText":"alpha",` +
        `"textEdit":{"newText":"alphabet",` +
        `"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}}]`,
    )
    defer result_release(&res)

    testing.expect_value(t, len(res.completions), 1)
    if len(res.completions) != 1 {
        return
    }
    testing.expect_value(t, res.completions[0].insert, "alphabet")
    testing.expect_value(t, res.completions[0].filter, "alpha")
    testing.expect_value(t, res.completions[0].start, 0)
    testing.expect_value(t, res.completions[0].end, 5)
}

// An InsertReplaceEdit takes its `replace` range: insertReplaceSupport is never
// advertised, so a server that sends one anyway means the wider of the two.
@(test)
test_decode_completion_insert_replace_edit :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 5)

    res := decode_reply(
        s,
        &req,
        `[{"label":"alphabet","textEdit":{"newText":"alphabet",` +
        `"insert":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},` +
        `"replace":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}}]`,
    )
    defer result_release(&res)

    testing.expect_value(t, len(res.completions), 1)
    if len(res.completions) == 1 {
        testing.expect_value(t, res.completions[0].end, 5)
    }
}

// A range that does not resolve leaves the candidate with none rather than one
// that points at the wrong bytes; insertText still stands.
@(test)
test_decode_completion_refuses_a_bad_text_edit :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 5)

    res := decode_reply(
        s,
        &req,
        `[{"label":"alpha","insertText":"alpha_impl",` +
        `"textEdit":{"newText":"alphabet",` +
        `"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":0}}}}]`,
    )
    defer result_release(&res)

    testing.expect_value(t, len(res.completions), 1)
    if len(res.completions) != 1 {
        return
    }
    testing.expect_value(t, res.completions[0].insert, "alpha_impl")
    testing.expect_value(t, res.completions[0].start, -1)
}

// additionalTextEdits are the changes elsewhere a candidate needs — an import
// line — and carry the bytes they matched so the applier can verify them. A
// command rides through as the raw JSON the server sent.
@(test)
test_decode_completion_additional_edits_and_command :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 5)

    res := decode_reply(
        s,
        &req,
        `[{"label":"alpha","additionalTextEdits":[` +
        `{"newText":"import x\n","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}],` +
        `"command":{"command":"editor.action.triggerSuggest","arguments":[1,"two"]}}]`,
    )
    defer result_release(&res)

    testing.expect_value(t, len(res.completions), 1)
    if len(res.completions) != 1 {
        return
    }
    item := res.completions[0]
    testing.expect_value(t, len(item.extra_edits), 1)
    if len(item.extra_edits) == 1 {
        testing.expect_value(t, item.extra_edits[0].start, 0)
        testing.expect_value(t, item.extra_edits[0].end, 5)
        testing.expect_value(t, item.extra_edits[0].old_text, "alpha")
        testing.expect_value(t, item.extra_edits[0].new_text, "import x\n")
    }
    testing.expect_value(t, item.command, "editor.action.triggerSuggest")
    testing.expect_value(t, item.arguments, `[1,"two"]`)
}

// A server that does not resolve gets no candidate re-serialized for it: the raw
// JSON exists only to be echoed back on completionItem/resolve.
@(test)
test_decode_completion_keeps_raw_only_when_resolvable :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Completion, SOURCE, 0)

    plain := decode_reply(s, &req, `[{"label":"alpha","data":{"id":7}}]`)
    defer result_release(&plain)
    testing.expect_value(t, len(plain.completions), 1)
    if len(plain.completions) == 1 {
        testing.expect_value(t, plain.completions[0].raw, "")
    }

    s.caps.resolve_items = true
    kept := decode_reply(s, &req, `[{"label":"alpha","data":{"id":7}}]`)
    defer result_release(&kept)
    testing.expect_value(t, len(kept.completions), 1)
    if len(kept.completions) == 1 {
        testing.expect(t, kept.completions[0].raw != "", "a resolving server needs the item back")
    }
}

// completionItem/resolve answers the same candidate with the parts the server
// deferred filled in; only those parts are read, since the text has already
// landed by then.
@(test)
test_decode_resolve_completion :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Resolve_Completion, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `{"label":"alpha","detail":"int alpha(void)","additionalTextEdits":[` +
        `{"newText":"import x\n","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}]}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.completions), 1)
    if len(res.completions) == 1 {
        testing.expect_value(t, len(res.completions[0].extra_edits), 1)
    }
}

// A resolve that filled nothing in is not a result: there is nothing to apply,
// and ok=false is what the seam reads as "found nothing".
@(test)
test_decode_resolve_completion_without_edits :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Resolve_Completion, SOURCE, 0)

    res := decode_reply(s, &req, `{"label":"alpha","detail":"int alpha(void)"}`)
    defer result_release(&res)

    testing.expect(t, !res.ok)
    testing.expect_value(t, len(res.completions), 0)
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

// A RenameFile entry is decoded into resource_ops; on its own (no content
// edits) it is still a valid, non-empty rename result.
@(test)
test_decode_rename_keeps_resource_operation :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Rename, SOURCE, 0)

    res := decode_reply(
        s, &req,
        `{"documentChanges":[{"kind":"rename","oldUri":"` + FILE_URI + `","newUri":"` + OTHER_URI + `"}]}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok, "a resource operation alone must be a valid rename")
    testing.expect_value(t, len(res.resource_ops), 1)
    if len(res.resource_ops) != 1 {
        return
    }
    testing.expect_value(t, res.resource_ops[0].kind, lang.Resource_Op_Kind.Rename)
    testing.expect_value(t, res.resource_ops[0].path, FILE)
    testing.expect_value(t, res.resource_ops[0].new_path, OTHER)
}

// A CreateFile for a new file followed by a TextDocumentEdit that populates
// it: both the resource op and the text edit survive in the same result.
@(test)
test_decode_rename_mixed_create_and_edit :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    held_document(s, OTHER, "", 1) // the file the create op is about to make
    req := request_for(.Rename, SOURCE, 0)

    res := decode_reply(
        s, &req,
        `{"documentChanges":[` +
        `{"kind":"create","uri":"` + OTHER_URI + `"},` +
        `{"textDocument":{"uri":"` + OTHER_URI + `","version":null},` +
        `"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"x"}]}]}`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.resource_ops), 1)
    testing.expect_value(t, len(res.edits), 1)
    if len(res.resource_ops) != 1 || len(res.edits) != 1 {
        return
    }
    testing.expect_value(t, res.resource_ops[0].kind, lang.Resource_Op_Kind.Create)
    testing.expect_value(t, res.resource_ops[0].path, OTHER)
    testing.expect_value(t, res.edits[0].path, OTHER)
}

// A `kind` this package cannot model (not create/rename/delete) still refuses
// the whole set, the same as any other malformed entry.
@(test)
test_decode_resource_op_unknown_kind_refuses :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Rename, SOURCE, 0)

    res := decode_reply(s, &req, `{"documentChanges":[{"kind":"unknown","uri":"` + OTHER_URI + `"}]}`)
    defer result_release(&res)

    testing.expect(t, !res.ok, "an unmodeled resource-op kind must refuse the whole rename")
    testing.expect(t, res.edits == nil)
    testing.expect(t, res.resource_ops == nil)
}

// A rename entry missing newUri cannot be applied and refuses the whole set.
@(test)
test_decode_resource_op_malformed_rename_refuses :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Rename, SOURCE, 0)

    res := decode_reply(s, &req, `{"documentChanges":[{"kind":"rename","oldUri":"` + FILE_URI + `"}]}`)
    defer result_release(&res)

    testing.expect(t, !res.ok, "a rename with no newUri must refuse the whole set")
    testing.expect(t, res.resource_ops == nil)
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

// A bare Command is kept, with its arguments verbatim: picking it dispatches
// Execute_Command. A `disabled` CodeAction still drops — there is no UI for a
// disabled reason.
@(test)
test_decode_code_actions_keeps_command_drops_disabled :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Code_Actions, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"title":"Do thing","command":{"command":"foo","title":"Do thing","arguments":[1,"two"]}},` +
        `{"title":"Disabled fix","disabled":{"reason":"nope"},"edit":{"changes":{"` +
        FILE_URI +
        `":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"x"}]}}}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.actions), 1)
    if len(res.actions) != 1 {
        return
    }
    testing.expect_value(t, res.actions[0].title, "Do thing")
    testing.expect_value(t, res.actions[0].command, "foo")
    testing.expect_value(t, res.actions[0].arguments, `[1,"two"]`)
    testing.expect_value(t, len(res.actions[0].edits), 0)
}

// workspace/executeCommand names no document: the command and its arguments,
// passed through as the raw JSON the offer carried.
@(test)
test_execute_command_params :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Execute_Command, SOURCE, 0)
    req.command = "foo"
    req.command_args = `[1,"two"]`

    ask := ask_for(s, &req)
    params := request_params(&ask)
    testing.expect_value(t, params, `{"command":"foo","arguments":[1,"two"]}`)
}

// A command with no arguments sends none, rather than an empty array.
@(test)
test_execute_command_params_without_arguments :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Execute_Command, SOURCE, 0)
    req.command = "foo"

    ask := ask_for(s, &req)
    params := request_params(&ask)
    testing.expect_value(t, params, `{"command":"foo"}`)
}

// A code action whose only payload is a CreateFile resource op (no text
// edits) still survives the zero-edits drop check.
@(test)
test_decode_code_actions_keeps_create :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Code_Actions, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"title":"New file","kind":"refactor","edit":{"documentChanges":[` +
        `{"kind":"create","uri":"` + OTHER_URI + `"}]}}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.actions), 1)
    if len(res.actions) != 1 {
        return
    }
    testing.expect_value(t, len(res.actions[0].edits), 0)
    testing.expect_value(t, len(res.actions[0].resource_ops), 1)
    if len(res.actions[0].resource_ops) != 1 {
        return
    }
    testing.expect_value(t, res.actions[0].resource_ops[0].kind, lang.Resource_Op_Kind.Create)
    testing.expect_value(t, res.actions[0].resource_ops[0].path, OTHER)
}

// An action with no inline `edit` and a server that never advertised
// codeActionProvider.resolveProvider is dropped without attempting a resolve
// call — caps.resolve_actions stays false on a fresh held_server. It names no
// command either, so there is nothing left it could do.
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

// Format / Format_Range / Format_On_Type share decode_format. A single
// TextEdit spanning the whole file (the common shape: gofmt, rustfmt) is
// re-diffed against the request's own source into the minimal span the one
// changed line actually needs, not applied verbatim.
@(test)
test_decode_format_whole_file_edit_reduced_to_minimal_span :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Format, SOURCE, 0)

    res := decode_reply(
        s,
        &req,
        `[{"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}},` +
        `"newText":"alpha beta\nGAMMA delta\n"}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.edits), 1)
    if len(res.edits) != 1 {
        return
    }
    testing.expect_value(t, res.edits[0].start, 11)
    testing.expect_value(t, res.edits[0].end, len(SOURCE))
    testing.expect_value(t, res.edits[0].old_text, "gamma delta\n")
    testing.expect_value(t, res.edits[0].new_text, "GAMMA delta\n")
}

// Several independent TextEdits (rangeFormatting's more common shape) survive
// as separate edits when an unchanged line separates them — the diff has
// common ground to split the hunks on. Two changed lines with nothing
// unchanged between them collapse into one span instead (diff_spans' own
// minimality contract, exercised in lang/diff_test.odin).
@(test)
test_decode_format_multiple_edits :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    source := "one\ntwo\nthree\nfour\nfive\n"
    req := request_for(.Format_Range, source, 0)

    res := decode_reply(
        s,
        &req,
        `[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"newText":"TWO"},` +
        `{"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":4}},"newText":"FOUR"}]`,
    )
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, len(res.edits), 2)
    if len(res.edits) != 2 {
        return
    }
    testing.expect_value(t, res.edits[0].old_text, "two\n")
    testing.expect_value(t, res.edits[0].new_text, "TWO\n")
    testing.expect_value(t, res.edits[1].old_text, "four\n")
    testing.expect_value(t, res.edits[1].new_text, "FOUR\n")
}

// An empty array and a null reply both mean "nothing to change" — ok must
// stay true, since thor_apply_format reads !ok as "fix syntax errors first".
@(test)
test_decode_format_empty_and_null_are_ok :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)

    empty_req := request_for(.Format, SOURCE, 0)
    empty := decode_reply(s, &empty_req, `[]`)
    defer result_release(&empty)
    testing.expect(t, empty.ok)
    testing.expect_value(t, len(empty.edits), 0)

    null_req := request_for(.Format_On_Type, SOURCE, 0)
    null_res := decode_reply(s, &null_req, `null`)
    defer result_release(&null_res)
    testing.expect(t, null_res.ok)
    testing.expect_value(t, len(null_res.edits), 0)
}

// A reply that answers neither an array nor null leaves ok false rather than
// guessing.
@(test)
test_decode_format_non_array_refused :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Format, SOURCE, 0)

    res := decode_reply(s, &req, `{"unexpected":true}`)
    defer result_release(&res)

    testing.expect(t, !res.ok)
    testing.expect_value(t, len(res.edits), 0)
}

// An edit with no "range" or no "newText" refuses the whole reply rather than
// applying the rest and silently dropping the malformed one.
@(test)
test_decode_format_malformed_edit_refused :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    req := request_for(.Format, SOURCE, 0)

    res := decode_reply(s, &req, `[{"newText":"x"}]`)
    defer result_release(&res)

    testing.expect(t, !res.ok)
    testing.expect_value(t, len(res.edits), 0)
}

// LSP forbids overlapping edits in one reply; decode_format refuses the whole
// batch rather than guessing an application order.
@(test)
test_decode_format_overlapping_edits_refused :: proc(t: ^testing.T) {
    s := held_server()
    defer held_destroy(s)
    source := "one\ntwo\nthree\n"
    req := request_for(.Format, source, 0)

    res := decode_reply(
        s,
        &req,
        `[{"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":3}},"newText":"X"},` +
        `{"range":{"start":{"line":0,"character":2},"end":{"line":2,"character":0}},"newText":"Y"}]`,
    )
    defer result_release(&res)

    testing.expect(t, !res.ok)
    testing.expect_value(t, len(res.edits), 0)
}
