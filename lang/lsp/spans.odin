package lsp

import "core:encoding/json"
import "core:slice"
import "core:strings"

import lang ".."

// The most unresolved links one request resolves, each a round trip.
@(private)
LINK_RESOLVE_MAX :: 64

// FoldingRange[]: each range from the start of its first line to the start of its last.
@(private)
decode_folding_ranges :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    list, ok := value.(json.Array)
    if !ok {
        return
    }
    for entry in list {
        object, is_object := entry.(json.Object)
        if !is_object {
            continue
        }
        start_line, sok := number(object["startLine"])
        end_line, eok   := number(object["endLine"])
        if !sok || !eok || end_line <= start_line {
            continue
        }
        start_char, _ := number(object["startCharacter"])
        append(
            &res.ranges,
            lang.Text_Range{
                start = offset_from_position(&ask.lines, int(start_line), int(start_char)),
                end = offset_from_position(&ask.lines, int(end_line), 0),
            },
        )
    }
    slice.stable_sort_by(res.ranges[:], proc(a, b: lang.Text_Range) -> bool {
        return a.start < b.start
    })
    res.ok = len(res.ranges) > 0
}

// DocumentLink[]: a `file:` target becomes its path, an http(s) one stays a URL, and any
// other scheme is dropped. A link with no target is resolved first when the server resolves links.
@(private)
decode_document_links :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    list, ok := value.(json.Array)
    if !ok {
        return
    }
    resolved := 0
    for entry in list {
        object, is_object := entry.(json.Object)
        if !is_object {
            continue
        }
        start_line, start_char, end_line, end_char, has_range := range_of(object["range"])
        if !has_range {
            continue
        }
        target, has_target := object["target"].(json.String)
        text               := string(target)
        if !has_target && ask.server.caps.resolve_links && resolved < LINK_RESOLVE_MAX && !lang.request_cancelled(ask.req) {
            resolved += 1
            text = link_resolve(ask, entry)
        }
        target_text, kept := link_target(text)
        if !kept {
            continue
        }
        append(
            &res.links,
            lang.Document_Link_Item{
                start = offset_from_position(&ask.lines, start_line, start_char),
                end = offset_from_position(&ask.lines, end_line, end_char),
                target = strings.clone(target_text),
            },
        )
    }
    slice.stable_sort_by(res.links[:], proc(a, b: lang.Document_Link_Item) -> bool {
        return a.start < b.start
    })
    res.ok = len(res.links) > 0
}

// What a link opens: the path of a `file:` URI, or an http(s) URL as it is. On the temp allocator.
@(private)
link_target :: proc(uri: string) -> (string, bool) {
    if strings.has_prefix(uri, "file:") {
        // A `#L10` fragment names a line the host does not read.
        return uri_to_path(uri, context.temp_allocator)
    }
    if strings.has_prefix(uri, "https://") || strings.has_prefix(uri, "http://") {
        return uri, true
    }
    return "", false
}

// The target of one link after documentLink/resolve, on the temp allocator; "" when it has none.
@(private = "file")
link_resolve :: proc(ask: ^Ask, link: json.Value) -> string {
    value, err := conn_call(ask.conn, "documentLink/resolve", json_text(link, context.temp_allocator), ask.deadline, ask.req.cancel)
    defer conn_free_value(ask.conn, value)
    if err != .None {
        return ""
    }
    object, ok := value.(json.Object)
    if !ok {
        return ""
    }
    target, tok := object["target"].(json.String)
    return tok ? strings.clone(string(target), context.temp_allocator) : ""
}

// LinkedEditingRanges: the spans one edit changes together. A null reply is no span.
@(private)
decode_linked_editing :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    object, ok := value.(json.Object)
    if !ok {
        return
    }
    list, lok := object["ranges"].(json.Array)
    if !lok {
        return
    }
    for entry in list {
        start_line, start_char, end_line, end_char, has_range := range_of(entry)
        if !has_range {
            continue
        }
        append(
            &res.ranges,
            lang.Text_Range{start = offset_from_position(&ask.lines, start_line, start_char), end = offset_from_position(&ask.lines, end_line, end_char)},
        )
    }
    res.ok = len(res.ranges) > 1
}
