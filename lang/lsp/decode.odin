// Reading a server's reply into the seam's payloads, one decoder per request
// kind. Every offset that leaves this file is a byte offset over LF-collapsed
// source: a position in the request's own file converts against the text that was
// sent, and a position in a file the editor never opened converts against the raw
// bytes on disk and is then moved into LF space.
//
// A shape the decoder does not know leaves res.ok false. Owned strings use
// context.allocator, which is the Manager's on a worker.
package lsp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import lang ".."

@(private)
request_decode :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    #partial switch ask.req.kind {
    case .Definition:
        decode_definition(ask, value, res)
    case .Hover:
        decode_hover(ask, value, res)
    case .Document_Symbols, .Workspace_Symbols:
        decode_document_symbols(ask, value, res)
    case .References:
        decode_references(ask, value, res)
    case .Signature_Help:
        decode_signature_help(ask, value, res)
    case .Completion:
        decode_completion(ask, value, res)
    case .Diagnostics:
        decode_pull_diagnostics(ask, value, res)
    case .Semantic_Tokens:
        decode_semantic_tokens(ask, value, res)
    case .Rename:
        decode_rename(ask, value, res)
    case .Code_Actions:
        decode_code_actions(ask, value, res)
    }
}

// One place a definition reply named.
@(private)
Target :: struct {
    uri:        string,
    line:       int,
    character:  int,
    end_line:   int,
    end_char:   int,
}

// `Location`, `LocationLink` and an array of either. One target is the jump; more
// than one is the candidate picker, which reads the same rows find-usages does.
@(private)
decode_definition :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    targets := make([dynamic]Target, context.temp_allocator)
    collect_targets(value, &targets)
    if len(targets) == 0 {
        return
    }

    if len(targets) == 1 {
        path, start, end, ok := resolve_target(ask, targets[0])
        if !ok {
            return
        }
        res.location = lang.Location {
            path  = strings.clone(path),
            start = start,
            end   = end,
        }
        res.ok = true
        return
    }

    res.symbols = make([dynamic]lang.Symbol)
    for target in targets {
        path, start, _, ok := resolve_target(ask, target)
        if !ok {
            continue
        }
        text, read := ask_source(ask, path)
        append(
            &res.symbols,
            lang.Symbol {
                name = strings.clone(filepath.base(path)),
                kind = strings.clone("reference"),
                signature = read ? source_line_at(text, start) : strings.clone(""),
                path = strings.clone(path),
                line = read ? line_number_at(text, start) : target.line + 1,
                offset = start,
            },
        )
    }
    res.ok = len(res.symbols) > 0
}

// `MarkupContent`, `MarkedString` and an array of either, drawn as plain text.
// A server that named no range gets the identifier under the caret instead, so
// the popup still underlines what it described.
@(private)
decode_hover :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    object, is_object := value.(json.Object)
    if !is_object {
        return
    }
    text := hover_text(object["contents"])
    if text == "" {
        return
    }

    start, end := identifier_span(ask.req.source, ask.req.offset)
    if start_line, start_char, end_line, end_char, ok := range_of(object["range"]); ok {
        start = offset_from_position(&ask.lines, start_line, start_char)
        end = offset_from_position(&ask.lines, end_line, end_char)
    }
    res.hover = lang.Hover_Info {
        text  = strings.clone(text),
        start = start,
        end   = end,
    }
    res.ok = true
}

// `DocumentSymbol[]` (a tree) or `SymbolInformation[]` (flat). Both, flattened
// depth first so the outline keeps the file's reading order. `workspace/symbol`
// decodes here too: it answers the flat shape, in files this request never named.
@(private)
decode_document_symbols :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    items, is_array := value.(json.Array)
    if !is_array || len(items) == 0 {
        return
    }
    res.symbols = make([dynamic]lang.Symbol)
    for item in items {
        append_symbol(ask, item, res)
    }
    res.ok = len(res.symbols) > 0
}

// `Location[]`, one row per usage with the source line it sits on as its preview.
// Sorted by (path, offset), the order the picker walks.
@(private)
decode_references :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    items, is_array := value.(json.Array)
    if !is_array || len(items) == 0 {
        return
    }
    start, end := identifier_span(ask.req.source, ask.req.offset)
    name := ask.req.source[start:end]

    res.symbols = make([dynamic]lang.Symbol)
    for item in items {
        object, is_object := item.(json.Object)
        if !is_object {
            continue
        }
        uri, has_uri := object["uri"].(json.String)
        start_line, start_char, end_line, end_char, has_range := range_of(object["range"])
        if !has_uri || !has_range {
            continue
        }
        path, at, _, ok := resolve_range(ask, string(uri), start_line, start_char, end_line, end_char)
        if !ok {
            continue
        }
        text, read := ask_source(ask, path)
        append(
            &res.symbols,
            lang.Symbol {
                name = strings.clone(name),
                kind = strings.clone("reference"),
                signature = read ? source_line_at(text, at) : strings.clone(""),
                path = strings.clone(path),
                line = read ? line_number_at(text, at) : start_line + 1,
                offset = at,
            },
        )
    }
    slice.sort_by(res.symbols[:], proc(a, b: lang.Symbol) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    res.ok = len(res.symbols) > 0
}

// `SignatureInformation[]`. An overload set is several entries, which is the same
// shape an Odin procedure group answers with.
@(private)
decode_signature_help :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    object, is_object := value.(json.Object)
    if !is_object {
        return
    }
    signatures, is_array := object["signatures"].(json.Array)
    if !is_array || len(signatures) == 0 {
        return
    }
    active_signature, _ := number(object["activeSignature"])
    active_parameter, has_active := number(object["activeParameter"])

    res.signature.entries = make([dynamic]lang.Signature_Entry)
    for item in signatures {
        entry, ok := signature_entry(item, has_active ? int(active_parameter) : -1)
        if !ok {
            continue
        }
        append(&res.signature.entries, entry)
    }
    if len(res.signature.entries) == 0 {
        return
    }
    res.signature.active = clamp(int(active_signature), 0, len(res.signature.entries) - 1)
    res.ok = true
}

// `CompletionList` or `CompletionItem[]`. `textEdit`, `additionalTextEdits`,
// `command` and `isIncomplete` are dropped: the popup inserts one word at the
// caret and filters the list itself.
@(private)
decode_completion :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    items, is_array := value.(json.Array)
    if !is_array {
        list, is_list := value.(json.Object)
        if !is_list {
            return
        }
        items, is_array = list["items"].(json.Array)
        if !is_array {
            return
        }
    }
    if len(items) == 0 {
        return
    }

    res.symbols = make([dynamic]lang.Symbol)
    for item in items {
        object, is_object := item.(json.Object)
        if !is_object {
            continue
        }
        label, has_label := object["label"].(json.String)
        if !has_label {
            continue
        }
        // Some servers pad a label to align the list; the inserted word must not
        // carry that padding.
        name := strings.trim_space(string(label))
        // insertText is what the server means to be typed. A snippet is refused:
        // snippetSupport is advertised false, so its placeholders would be typed
        // out as they are.
        format, has_format := number(object["insertTextFormat"])
        if insert, has_insert := object["insertText"].(json.String); has_insert && (!has_format || format == 1) {
            name = string(insert)
        }
        if name == "" {
            continue
        }
        kind, _ := number(object["kind"])
        detail, _ := object["detail"].(json.String)
        append(
            &res.symbols,
            lang.Symbol {
                name = strings.clone(name),
                kind = strings.clone(completion_kind_name(int(kind))),
                signature = strings.clone(detail == "" ? strings.trim_space(string(label)) : string(detail)),
            },
        )
    }
    res.ok = len(res.symbols) > 0
}

// `RelatedFullDocumentDiagnosticReport`. An "unchanged" report is refused: no
// `previousResultId` is ever sent, so a server has nothing to compare against and
// the reply carries no items to read. `relatedDocuments` is dropped — the report
// covers the file that was asked about.
@(private)
decode_pull_diagnostics :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    object, is_object := value.(json.Object)
    if !is_object {
        return
    }
    if kind, has_kind := object["kind"].(json.String); has_kind && kind != "full" {
        return
    }
    items, is_array := object["items"].(json.Array)
    if !is_array {
        return
    }
    // An empty report means the file is clean, which the editor must be told to
    // retire the squiggles it drew last time.
    res.report.scope = strings.clone(ask.req.path)
    res.report.items = make([dynamic]lang.Diagnostic)
    for item in items {
        diagnostic, decoded := decode_one_diagnostic(&ask.lines, ask.req.path, item)
        if !decoded {
            continue
        }
        append(&res.report.items, diagnostic)
    }
    res.ok = true
}

// `textDocument/publishDiagnostics`, the one result no request asked for. A file
// the editor never opened and a publish for text the server has already been sent
// past are both dropped. Pump thread; the caller must hold neither lock.
@(private)
decode_publish_diagnostics :: proc(s: ^Server, params: json.Value) -> (lang.Result, bool) {
    object, is_object := params.(json.Object)
    if !is_object {
        return {}, false
    }
    uri, has_uri := object["uri"].(json.String)
    items, is_array := object["diagnostics"].(json.Array)
    if !has_uri || !is_array {
        return {}, false
    }
    path, is_file := uri_to_path(string(uri), context.temp_allocator)
    if !is_file {
        return {}, false
    }

    sync.guard(&s.docs_mutex)
    doc, held := server_find(s, path)
    if !held {
        return {}, false
    }
    // A newer didChange has its own publish coming, and its positions count over
    // text this one never saw.
    if version, has_version := number(object["version"]); has_version && version != doc.version {
        return {}, false
    }

    res := lang.Result {
        kind     = .Diagnostics,
        ok       = true,
        revision = doc.revision,
    }
    res.report.scope = strings.clone(doc.path)
    res.report.items = make([dynamic]lang.Diagnostic)
    for item in items {
        diagnostic, decoded := decode_one_diagnostic(&doc.lines, doc.path, item)
        if !decoded {
            continue
        }
        append(&res.report.items, diagnostic)
    }
    return res, true
}

// `$/progress`, a `WorkDoneProgress` value: `{token, value: {kind, title?,
// message?, percentage?}}`. "begin" and "report" produce a message ("message",
// falling back to "title", with "(N%)" appended when given); "end" produces
// `done = true` with an empty message, so the editor clears its indicator
// instead of showing a blank one. Pump thread, no lock held.
@(private)
decode_progress :: proc(params: json.Value) -> (lang.Result, bool) {
    object, is_object := params.(json.Object)
    if !is_object {
        return {}, false
    }
    value, has_value := object["value"].(json.Object)
    if !has_value {
        return {}, false
    }
    kind, has_kind := value["kind"].(json.String)
    if !has_kind {
        return {}, false
    }
    res := lang.Result {
        kind = .Progress,
        ok   = true,
    }
    switch string(kind) {
    case "end":
        res.progress.done = true
        return res, true
    case "begin", "report":
        message := ""
        if m, has_m := value["message"].(json.String); has_m {
            message = string(m)
        } else if t, has_t := value["title"].(json.String); has_t {
            message = string(t)
        }
        if pct, has_pct := number(value["percentage"]); has_pct {
            message = message == "" ? fmt.tprintf("%d%%", pct) : fmt.tprintf("%s (%d%%)", message, pct)
        }
        res.progress.message = strings.clone(message)
        return res, true
    }
    return {}, false
}

// One `Diagnostic`, as the 1-based line and byte column the seam reports. The
// protocol's four severities coarsen to two: only Error stays one, and a
// diagnostic that named no severity is read as an error.
@(private)
decode_one_diagnostic :: proc(lines: ^Line_Index, path: string, value: json.Value) -> (lang.Diagnostic, bool) {
    object, is_object := value.(json.Object)
    if !is_object {
        return {}, false
    }
    message, has_message := object["message"].(json.String)
    start_line, start_char, _, _, has_range := range_of(object["range"])
    if !has_message || !has_range {
        return {}, false
    }
    severity := lang.Diagnostic_Severity.Error
    if level, has_level := number(object["severity"]); has_level && level != 1 {
        severity = .Warning
    }

    offset := offset_from_position(lines, start_line, start_char)
    line := clamp(start_line, 0, len(lines.starts) - 1)
    return lang.Diagnostic {
            path = strings.clone(path),
            line = line + 1,
            col = offset - lines.starts[line] + 1,
            severity = severity,
            message = strings.clone(string(message)),
        },
        true
}

// The delta-encoded 5-tuples of `textDocument/semanticTokens/full`, or a
// `.../full/delta` reply's edits applied against the cached array from the
// previous fetch, read against the legend the server advertised. Output is
// ascending and non-overlapping: the editor merges it with the grammar's
// spans using one forward-only cursor.
//
// The reply's own resultId and flat integer array are cached on the Document
// (server_store_semantic) so the *next* request for this file can ask for a
// delta instead of the whole list — resolved entirely inside this package:
// what leaves it (`res.tokens`) is always the same full, absolute list it
// always was, delta or not.
@(private)
decode_semantic_tokens :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    object, is_object := value.(json.Object)
    if !is_object {
        return
    }
    legend := ask.server.caps.token_legend
    if len(legend) == 0 {
        return
    }

    result_id := ""
    if id, iok := object["resultId"].(json.String); iok {
        result_id = string(id)
    }

    data: []i64
    if edits, eok := object["edits"].(json.Array); eok {
        prev := server_semantic_data(ask.server, ask.req.path, context.temp_allocator)
        merged, ok := apply_semantic_edits(prev, edits, context.temp_allocator)
        if !ok {
            server_clear_semantic(ask.server, ask.req.path)
            return
        }
        data = merged
    } else if raw, dok := object["data"].(json.Array); dok {
        data = decode_int_array(raw, context.temp_allocator)
    } else {
        return
    }

    if result_id != "" {
        server_store_semantic(ask.server, ask.req.path, data, result_id)
    }

    res.tokens = make([dynamic]lang.Semantic_Token)
    line, character := 0, 0
    for index := 0; index + 4 < len(data); index += 5 {
        delta_line, delta_char := data[index], data[index + 1]
        length, entry := data[index + 2], data[index + 3]
        if delta_line > 0 {
            line += int(delta_line)
            character = int(delta_char)
        } else {
            character += int(delta_char)
        }
        if entry < 0 || int(entry) >= len(legend) || !legend[entry].valid {
            continue
        }
        start := offset_from_position(&ask.lines, line, character)
        end := offset_from_position(&ask.lines, line, character + int(length))
        if end <= start {
            continue
        }
        if len(res.tokens) > 0 && start < res.tokens[len(res.tokens) - 1].end {
            continue
        }
        append(&res.tokens, lang.Semantic_Token{start = start, end = end, kind = legend[entry].kind})
    }
    res.ok = len(res.tokens) > 0
}

// Reads a JSON array of whole numbers into an int64 slice; a non-number entry
// truncates the read there rather than mixing a short array with garbage.
@(private)
decode_int_array :: proc(arr: json.Array, allocator := context.allocator) -> []i64 {
    out := make([dynamic]i64, 0, len(arr), allocator)
    for v in arr {
        n, ok := number(v)
        if !ok {
            break
        }
        append(&out, n)
    }
    return out[:]
}

// Applies a SemanticTokensDelta's edits to the previous flat token array, each
// edit's start/deleteCount read against the array as the edit *before* it left
// it — the sequence the protocol defines, so out-of-order or overlapping
// interpretations never arise. False on any edit whose range falls outside the
// array at that point, which means the cached array and the server's edits
// have desynchronised and neither can be trusted further.
@(private)
apply_semantic_edits :: proc(prev: []i64, edits: json.Array, allocator := context.allocator) -> ([]i64, bool) {
    result := make([dynamic]i64, len(prev), allocator)
    copy(result[:], prev)
    for e in edits {
        obj, ook := e.(json.Object)
        if !ook {
            delete(result)
            return nil, false
        }
        start, sok := number(obj["start"])
        count, cok := number(obj["deleteCount"])
        if !sok || !cok || start < 0 || count < 0 {
            delete(result)
            return nil, false
        }
        at, dc := int(start), int(count)
        if at > len(result) || at + dc > len(result) {
            delete(result)
            return nil, false
        }
        insert: []i64
        if raw, dok := obj["data"].(json.Array); dok {
            insert = decode_int_array(raw, context.temp_allocator)
        }
        remove_range(&result, at, at + dc)
        inject_at(&result, at, ..insert)
    }
    return result[:], true
}

// `WorkspaceEdit` from textDocument/rename. Sorted ascending by (path, start),
// the order thor_apply_edits walks each file back-to-front by.
@(private)
decode_rename :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    res.edits = make([dynamic]lang.Text_Edit)
    if !decode_workspace_edit(ask, value, &res.edits) {
        delete(res.edits)
        res.edits = nil
        return
    }
    slice.sort_by(res.edits[:], proc(a, b: lang.Text_Edit) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.start < b.start
    })
    res.ok = len(res.edits) > 0
}

// `(Command | CodeAction)[]`. An item with no `edit` gets codeAction/resolve
// called eagerly, on this same worker; one that still has none afterward — a
// bare Command, or a CodeAction a server declined to resolve — is dropped,
// since Thor has no workspace/executeCommand path. isPreferred actions sort
// first; server order is kept otherwise.
@(private)
decode_code_actions :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    items, is_array := value.(json.Array)
    if !is_array || len(items) == 0 {
        return
    }

    preferred := make([dynamic]lang.Code_Action, context.temp_allocator)
    rest := make([dynamic]lang.Code_Action, context.temp_allocator)
    for item in items {
        object, is_object := item.(json.Object)
        title, has_title := object["title"].(json.String)
        if !is_object || !has_title {
            continue
        }
        if _, disabled := object["disabled"]; disabled {
            continue
        }
        action := lang.Code_Action {
            title = strings.clone(string(title)),
            kind  = strings.clone(action_kind_of(object["kind"])),
            edits = make([dynamic]lang.Text_Edit),
        }
        if !decode_action_edit(ask, object, &action.edits) || len(action.edits) == 0 {
            delete(action.title)
            delete(action.kind)
            delete(action.edits)
            continue
        }
        slice.sort_by(action.edits[:], proc(a, b: lang.Text_Edit) -> bool {
            if a.path != b.path {
                return a.path < b.path
            }
            return a.start < b.start
        })
        if flag, fok := object["isPreferred"].(json.Boolean); fok && bool(flag) {
            append(&preferred, action)
        } else {
            append(&rest, action)
        }
    }

    if len(preferred) == 0 && len(rest) == 0 {
        return
    }
    res.actions = make([dynamic]lang.Code_Action, 0, len(preferred) + len(rest))
    append(&res.actions, ..preferred[:])
    append(&res.actions, ..rest[:])
    res.ok = len(res.actions) > 0
}

// The edit for one code action: inline if present, otherwise fetched with
// codeAction/resolve on this worker's own connection — the shared conn_lock
// covers the whole request, so a second call here is safe.
@(private)
decode_action_edit :: proc(ask: ^Ask, object: json.Object, out: ^[dynamic]lang.Text_Edit) -> bool {
    if edit, has_edit := object["edit"]; has_edit {
        if _, is_null := edit.(json.Null); !is_null {
            return decode_workspace_edit(ask, edit, out)
        }
    }
    if !ask.server.caps.resolve_actions {
        return false
    }
    params := json_text(object, context.temp_allocator)
    if params == "" {
        return false
    }
    value, err := conn_call(ask.conn, "codeAction/resolve", params, DEADLINE_INTERACTIVE, ask.req.cancel)
    defer conn_free_value(ask.conn, value)
    if err != .None {
        return false
    }
    resolved, is_object := value.(json.Object)
    if !is_object {
        return false
    }
    edit, has_edit := resolved["edit"]
    if !has_edit {
        return false
    }
    return decode_workspace_edit(ask, edit, out)
}

// The LSP CodeActionKind ("quickfix", "refactor.extract", "source.fixAll") onto
// the two colors thor_action_color recognizes. Anything else, including a
// missing kind, falls back to its neutral default.
@(private)
action_kind_of :: proc(value: json.Value) -> string {
    kind, is_string := value.(json.String)
    if !is_string {
        return ""
    }
    text := string(kind)
    if strings.has_prefix(text, "quickfix") {
        return "quickfix"
    }
    if strings.has_prefix(text, "refactor") {
        return "refactor"
    }
    return ""
}

// Decodes a WorkspaceEdit into `out`, one lang.Text_Edit per range, old_text
// read from the current file contents through resolve_range + ask_source.
// False refuses the whole edit: a resource operation (CreateFile / RenameFile /
// DeleteFile) was present, or a range, path or file could not be verified.
// Edits already appended are freed before returning false, so a caller never
// has to track how far decoding got.
@(private)
decode_workspace_edit :: proc(ask: ^Ask, value: json.Value, out: ^[dynamic]lang.Text_Edit) -> bool {
    object, is_object := value.(json.Object)
    if !is_object {
        return false
    }
    start := len(out^)
    ok := true
    if changes, has := object["documentChanges"].(json.Array); has {
        ok = decode_document_changes(ask, changes, out)
    } else if changes, has := object["changes"].(json.Object); has {
        ok = decode_changes_map(ask, changes, out)
    }
    if !ok {
        for edit in out[start:] {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        resize(out, start)
        return false
    }
    return true
}

// `documentChanges`: TextDocumentEdit items, or a resource operation that
// refuses the whole set — the seam cannot express creating, renaming or
// deleting a file, and a half-applied rename breaks a build silently.
@(private)
decode_document_changes :: proc(ask: ^Ask, items: json.Array, out: ^[dynamic]lang.Text_Edit) -> bool {
    for item in items {
        object, is_object := item.(json.Object)
        if !is_object {
            return false
        }
        if _, is_resource_op := object["kind"]; is_resource_op {
            return false
        }
        doc, has_doc := object["textDocument"].(json.Object)
        uri, has_uri := doc["uri"].(json.String)
        edits, has_edits := object["edits"].(json.Array)
        if !has_doc || !has_uri || !has_edits {
            return false
        }
        if !decode_text_edits(ask, string(uri), edits, out) {
            return false
        }
    }
    return true
}

// `changes`: a plain uri -> TextEdit[] map, the shape a server without
// documentChanges support answers with.
@(private)
decode_changes_map :: proc(ask: ^Ask, changes: json.Object, out: ^[dynamic]lang.Text_Edit) -> bool {
    for uri, value in changes {
        edits, has_edits := value.(json.Array)
        if !has_edits {
            return false
        }
        if !decode_text_edits(ask, uri, edits, out) {
            return false
        }
    }
    return true
}

// One file's TextEdit / AnnotatedTextEdit array. annotationId is read by
// nothing and ignored — it names a change-annotation label Thor has no UI for.
@(private)
decode_text_edits :: proc(ask: ^Ask, uri: string, items: json.Array, out: ^[dynamic]lang.Text_Edit) -> bool {
    for item in items {
        object, is_object := item.(json.Object)
        if !is_object {
            return false
        }
        new_text, has_text := object["newText"].(json.String)
        start_line, start_char, end_line, end_char, has_range := range_of(object["range"])
        if !has_text || !has_range {
            return false
        }
        if !append_text_edit(ask, uri, start_line, start_char, end_line, end_char, string(new_text), out) {
            return false
        }
    }
    return true
}

// One Text_Edit: the range resolved to a path and byte offsets, old_text read
// from the file's current contents so thor_apply_edits can verify it. False on
// an inverted range, an unresolved path, or a file that could not be read.
@(private)
append_text_edit :: proc(
    ask: ^Ask,
    uri: string,
    start_line, start_char, end_line, end_char: int,
    new_text: string,
    out: ^[dynamic]lang.Text_Edit,
) -> bool {
    path, start, end, ok := resolve_range(ask, uri, start_line, start_char, end_line, end_char)
    if !ok || start > end {
        return false
    }
    text, read := ask_source(ask, path)
    if !read || start < 0 || end > len(text) {
        return false
    }
    append(out, lang.Text_Edit {
        path     = strings.clone(path),
        start    = start,
        end      = end,
        old_text = strings.clone(text[start:end]),
        new_text = strings.clone(new_text),
    })
    return true
}

// One DocumentSymbol or SymbolInformation, and then the children of the first.
@(private)
append_symbol :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    object, is_object := value.(json.Object)
    if !is_object {
        return
    }
    name, has_name := object["name"].(json.String)
    if !has_name {
        return
    }
    kind, _ := number(object["kind"])
    detail, _ := object["detail"].(json.String)

    path: string
    offset, line: int
    placed := false
    if location, is_flat := object["location"].(json.Object); is_flat {
        // SymbolInformation: one range for the whole declaration, in a file that
        // need not be the one that was asked about.
        uri, has_uri := location["uri"].(json.String)
        start_line, start_char, end_line, end_char, has_range := range_of(location["range"])
        if has_uri && has_range {
            path, offset, _, placed = resolve_range(ask, string(uri), start_line, start_char, end_line, end_char)
            line = start_line + 1
        }
    } else {
        // DocumentSymbol: `range` covers the declaration and `selectionRange` the
        // name inside it, which is where the jump lands.
        span, has_span := object["selectionRange"]
        if !has_span {
            span = object["range"]
        }
        if start_line, start_char, _, _, has_range := range_of(span); has_range {
            path = ask.req.path
            offset = offset_from_position(&ask.lines, start_line, start_char)
            line = start_line + 1
            placed = true
        }
        if start_line, _, _, _, has_range := range_of(object["range"]); has_range {
            line = start_line + 1
        }
    }

    if placed {
        append(
            &res.symbols,
            lang.Symbol {
                name = strings.clone(string(name)),
                kind = strings.clone(symbol_kind_name(int(kind))),
                signature = symbol_signature(ask, string(detail), path, offset),
                path = strings.clone(path),
                line = line,
                offset = offset,
            },
        )
    }

    children, has_children := object["children"].(json.Array)
    if !has_children {
        return
    }
    for child in children {
        append_symbol(ask, child, res)
    }
}

// The row's second line: what the server called the symbol, and the declaration
// line itself when it called it nothing.
@(private)
symbol_signature :: proc(ask: ^Ask, detail, path: string, offset: int) -> string {
    if detail != "" {
        return strings.clone(detail)
    }
    text, read := ask_source(ask, path)
    if !read {
        return strings.clone("")
    }
    return source_line_at(text, offset)
}

// One SignatureInformation. `fallback_active` is the reply's own active parameter,
// which a signature may override, and -1 when the reply named none.
@(private)
signature_entry :: proc(value: json.Value, fallback_active: int) -> (lang.Signature_Entry, bool) {
    object, is_object := value.(json.Object)
    if !is_object {
        return {}, false
    }
    label, has_label := object["label"].(json.String)
    if !has_label {
        return {}, false
    }
    entry := lang.Signature_Entry {
        label = strings.clone(string(label)),
    }

    active := fallback_active
    if own, has_own := number(object["activeParameter"]); has_own {
        active = int(own)
    }
    parameters, has_parameters := object["parameters"].(json.Array)
    if !has_parameters || active < 0 || active >= len(parameters) {
        return entry, true
    }
    entry.active_start, entry.active_end = parameter_span(string(label), parameters[active])
    return entry, true
}

// The byte range of one parameter inside its signature label. The protocol spells
// it either as a substring of the label or as a [start, end) pair counted in
// UTF-16 units over the label — not over the document, so the document's index
// cannot answer it.
@(private)
parameter_span :: proc(label: string, value: json.Value) -> (start, end: int) {
    object, is_object := value.(json.Object)
    if !is_object {
        return 0, 0
    }
    marker, has_marker := object["label"]
    if !has_marker {
        return 0, 0
    }
    if text, is_text := marker.(json.String); is_text {
        at := strings.index(label, string(text))
        if at < 0 {
            return 0, 0
        }
        return at, at + len(text)
    }
    pair, is_pair := marker.(json.Array)
    if !is_pair || len(pair) != 2 {
        return 0, 0
    }
    first, has_first := number(pair[0])
    second, has_second := number(pair[1])
    if !has_first || !has_second {
        return 0, 0
    }
    return utf16_offset(label, int(first)), utf16_offset(label, int(second))
}

// Every target a definition reply named, in the order it named them.
@(private)
collect_targets :: proc(value: json.Value, out: ^[dynamic]Target) {
    #partial switch item in value {
    case json.Array:
        for entry in item {
            collect_targets(entry, out)
        }
    case json.Object:
        if target, ok := target_of(item); ok {
            append(out, target)
        }
    }
}

// A Location or a LocationLink. A link names the target file apart from the span
// in the file the request came from, so its own keys are read first.
@(private)
target_of :: proc(object: json.Object) -> (Target, bool) {
    span: json.Value
    has_span: bool
    uri, has_uri := object["targetUri"].(json.String)
    if has_uri {
        span, has_span = object["targetSelectionRange"]
        if !has_span {
            span, has_span = object["targetRange"]
        }
    } else {
        uri, has_uri = object["uri"].(json.String)
        span, has_span = object["range"]
    }
    if !has_uri || !has_span {
        return {}, false
    }
    start_line, start_char, end_line, end_char, ok := range_of(span)
    if !ok {
        return {}, false
    }
    return Target {
            uri = string(uri),
            line = start_line,
            character = start_char,
            end_line = end_line,
            end_char = end_char,
        },
        true
}

@(private)
resolve_target :: proc(ask: ^Ask, target: Target) -> (string, int, int, bool) {
    return resolve_range(ask, target.uri, target.line, target.character, target.end_line, target.end_char)
}

// The path and the LF-space byte range a server's URI and positions name. Three
// sources, in the order they are exact: the request's own buffer, a document this
// server already holds, and the file on disk. Only the last needs the CRLF step —
// the server read those bytes itself, so its characters count over them.
@(private)
resolve_range :: proc(
    ask: ^Ask,
    uri: string,
    start_line, start_char, end_line, end_char: int,
) -> (
    path: string,
    start, end: int,
    ok: bool,
) {
    named, is_file := uri_to_path(uri, context.temp_allocator)
    if !is_file {
        return "", 0, 0, false
    }
    if path_equal(named, ask.req.path) {
        return named,
            offset_from_position(&ask.lines, start_line, start_char),
            offset_from_position(&ask.lines, end_line, end_char),
            true
    }
    if open_start, open_end, held := server_range_in_open(ask.server, named, start_line, start_char, end_line, end_char);
       held {
        return named, open_start, open_end, true
    }
    index := ask_raw_index(ask, named)
    if index == nil {
        return "", 0, 0, false
    }
    return named,
        lf_offset(index, offset_from_position(index, start_line, start_char)),
        lf_offset(index, offset_from_position(index, end_line, end_char)),
        true
}

// The (line, character) of a Position object.
@(private)
position_of :: proc(value: json.Value) -> (line, character: int, ok: bool) {
    object, is_object := value.(json.Object)
    if !is_object {
        return 0, 0, false
    }
    at_line, has_line := number(object["line"])
    at_char, has_char := number(object["character"])
    if !has_line || !has_char {
        return 0, 0, false
    }
    return int(at_line), int(at_char), true
}

// The two ends of a Range object.
@(private)
range_of :: proc(value: json.Value) -> (start_line, start_char, end_line, end_char: int, ok: bool) {
    object, is_object := value.(json.Object)
    if !is_object {
        return 0, 0, 0, 0, false
    }
    from_line, from_char, has_start := position_of(object["start"])
    to_line, to_char, has_end := position_of(object["end"])
    if !has_start || !has_end {
        return 0, 0, 0, 0, false
    }
    return from_line, from_char, to_line, to_char, true
}

// Every hover shape as one string. The parts are joined by a blank line, the way
// a server that sent them as an array meant them to read.
@(private)
hover_text :: proc(value: json.Value) -> string {
    out := make([dynamic]u8, context.temp_allocator)
    hover_append(&out, value)
    return plain_text(string(out[:]))
}

@(private)
hover_append :: proc(out: ^[dynamic]u8, value: json.Value) {
    #partial switch item in value {
    case json.String:
        hover_separate(out)
        append(out, string(item))
    case json.Array:
        for entry in item {
            hover_append(out, entry)
        }
    case json.Object:
        // MarkupContent and the object form of MarkedString both carry "value".
        text, has_text := item["value"].(json.String)
        if !has_text {
            return
        }
        hover_separate(out)
        append(out, string(text))
    }
}

@(private)
hover_separate :: proc(out: ^[dynamic]u8) {
    if len(out) > 0 {
        append(out, "\n")
    }
}

// Markdown as the popup draws it. The popup is a text box, so a fence line would
// be drawn as three characters and a backtick as one.
@(private)
plain_text :: proc(text: string) -> string {
    out := make([dynamic]u8, context.temp_allocator)
    rest := text
    for len(rest) > 0 {
        line := rest
        if at := strings.index_byte(rest, '\n'); at >= 0 {
            line = rest[:at]
            rest = rest[at + 1:]
        } else {
            rest = ""
        }
        if strings.has_prefix(strings.trim_space(line), "```") {
            continue
        }
        if len(out) > 0 {
            append(&out, "\n")
        }
        for index in 0 ..< len(line) {
            if line[index] != '`' {
                append(&out, line[index])
            }
        }
    }
    return strings.trim_space(string(out[:]))
}

// The identifier around `offset`, for a reply that named no range of its own.
@(private)
identifier_span :: proc(source: string, offset: int) -> (start, end: int) {
    at := clamp(offset, 0, len(source))
    start = at
    for start > 0 && identifier_byte(source[start - 1]) {
        start -= 1
    }
    end = at
    for end < len(source) && identifier_byte(source[end]) {
        end += 1
    }
    return start, end
}

// Every byte above ASCII counts: an identifier in a language Thor has no lexer
// for may hold one, and a span that stopped there would split a rune.
@(private)
identifier_byte :: proc(char: u8) -> bool {
    switch char {
    case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_':
        return true
    }
    return char >= 0x80
}

// The source line an offset falls on, trimmed — a picker row's code preview.
@(private)
source_line_at :: proc(text: string, offset: int) -> string {
    at := clamp(offset, 0, len(text))
    start := strings.last_index_byte(text[:at], '\n') + 1 // -1 + 1 == 0 for the first line
    end := len(text)
    if next := strings.index_byte(text[at:], '\n'); next >= 0 {
        end = at + next
    }
    return strings.clone(strings.trim_space(text[start:end]))
}

// The 1-based line an offset falls on.
@(private)
line_number_at :: proc(text: string, offset: int) -> int {
    return strings.count(text[:clamp(offset, 0, len(text))], "\n") + 1
}

// LSP SymbolKind -> the kind names the picker tints by.
@(private)
symbol_kind_name :: proc(kind: int) -> string {
    switch kind {
    case 6, 9, 12:
        return "function" // Method, Constructor, Function
    case 5, 11, 23, 26:
        return "type" // Class, Interface, Struct, TypeParameter
    case 10:
        return "enum"
    case 22:
        return "enum_member"
    case 14:
        return "constant"
    case 2, 3, 4:
        return "namespace" // Module, Namespace, Package
    case 7, 8:
        return "field" // Property, Field
    }
    return "var"
}

// LSP CompletionItemKind -> the same names, which drive the row color.
@(private)
completion_kind_name :: proc(kind: int) -> string {
    switch kind {
    case 2, 3, 4:
        return "function" // Method, Function, Constructor
    case 7, 8, 22, 25:
        return "type" // Class, Interface, Struct, TypeParameter
    case 13:
        return "enum"
    case 20:
        return "enum_member"
    case 21:
        return "constant"
    case 14:
        return "keyword"
    case 9:
        return "namespace" // Module
    case 5, 10:
        return "field" // Field, Property
    }
    return "var"
}

@(private)
clone_temp :: proc(text: string) -> string {
    return strings.clone(text, context.temp_allocator)
}

// The bytes of a file exactly as they are on disk, CRLF intact. Deliberately not
// lang.source_read: a server that read this file counted its characters over
// these bytes.
@(private)
read_raw :: proc(path: string) -> (string, bool) {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        return "", false
    }
    return string(data), true
}
