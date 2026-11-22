package lsp

import "core:encoding/json"
import "core:slice"
import "core:strings"

import lang ".."

// The most unresolved lenses one request resolves, each a round trip.
@(private)
LENS_RESOLVE_MAX :: 64

// The second step of a call or type hierarchy: asks for the callers or callees
// (supertypes or subtypes) of the first item the prepare reply named.
@(private)
decode_hierarchy :: proc(ask: ^Ask, prepared: json.Value, res: ^lang.Result) {
    items, ok := prepared.(json.Array)
    if !ok || len(items) == 0 {
        return
    }
    down := ask.req.query == "down"
    method: string
    if ask.req.kind == .Call_Hierarchy {
        method = down ? "callHierarchy/outgoingCalls" : "callHierarchy/incomingCalls"
    } else {
        method = down ? "typeHierarchy/subtypes" : "typeHierarchy/supertypes"
    }
    params     := strings.concatenate({`{"item":`, json_text(items[0], context.temp_allocator), `}`}, context.temp_allocator)
    value, err := conn_call(ask.conn, method, params, ask.deadline, ask.req.cancel)
    defer conn_free_value(ask.conn, value)
    if err != .None {
        return
    }
    list, lok := value.(json.Array)
    if !lok {
        return
    }
    for entry in list {
        target := entry
        if object, is_object := entry.(json.Object); is_object && ask.req.kind == .Call_Hierarchy {
            target = object[down ? "to" : "from"]
        }
        append_symbol(ask, target, res)
    }
    res.ok = len(res.symbols) > 0
}

// SelectionRange[] for the one position asked: the chain of `parent`s, innermost
// first. A parent that does not hold its child ends the chain.
@(private)
decode_selection_ranges :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
    list, ok := value.(json.Array)
    if !ok || len(list) == 0 {
        return
    }
    node := list[0]
    for depth := 0; depth < 256; depth += 1 {
        object, is_object := node.(json.Object)
        if !is_object {
            break
        }
        start_line, start_char, end_line, end_char, has_range := range_of(object["range"])
        if !has_range {
            break
        }
        span := lang.Text_Range{start = offset_from_position(&ask.lines, start_line, start_char), end = offset_from_position(&ask.lines, end_line, end_char)}
        if n := len(res.ranges); n > 0 {
            inner := res.ranges[n - 1]
            if span.start > inner.start || span.end < inner.end {
                break
            }
            if span == inner {
                node = object["parent"]
                continue
            }
        }
        append(&res.ranges, span)
        node = object["parent"]
    }
    res.ok = len(res.ranges) > 0
}

// CodeLens[]: one row per lens with a title. A lens with no command is resolved
// first when the server resolves lenses.
@(private)
decode_code_lenses :: proc(ask: ^Ask, value: json.Value, res: ^lang.Result) {
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
        title := lens_title(object)
        if title == "" && ask.server.caps.resolve_lenses && resolved < LENS_RESOLVE_MAX && !lang.request_cancelled(ask.req) {
            resolved += 1
            title = lens_resolve(ask, entry)
        }
        title = lens_plain(title)
        if title == "" {
            continue
        }
        append(
            &res.lenses,
            lang.Code_Lens_Item{
                start = offset_from_position(&ask.lines, start_line, start_char),
                end = offset_from_position(&ask.lines, end_line, end_char),
                title = strings.clone(title),
            },
        )
    }
    slice.stable_sort_by(res.lenses[:], proc(a, b: lang.Code_Lens_Item) -> bool {
        return a.start < b.start
    })
    res.ok = len(res.lenses) > 0
}

@(private = "file")
lens_title :: proc(object: json.Object) -> string {
    command, ok := object["command"].(json.Object)
    if !ok {
        return ""
    }
    title, tok := command["title"].(json.String)
    return tok ? string(title) : ""
}

// The title of one lens after codeLens/resolve, on the temp allocator; "" when it has none.
@(private = "file")
lens_resolve :: proc(ask: ^Ask, lens: json.Value) -> string {
    value, err := conn_call(ask.conn, "codeLens/resolve", json_text(lens, context.temp_allocator), ask.deadline, ask.req.cancel)
    defer conn_free_value(ask.conn, value)
    if err != .None {
        return ""
    }
    object, ok := value.(json.Object)
    if !ok {
        return ""
    }
    return strings.clone(lens_title(object), context.temp_allocator)
}

// `title` without its `$(icon)` markup, on the temp allocator.
@(private)
lens_plain :: proc(title: string) -> string {
    if !strings.contains(title, "$(") {
        return strings.trim_space(title)
    }
    out := make([dynamic]u8, 0, len(title), context.temp_allocator)
    for i := 0; i < len(title); i += 1 {
        if title[i] == '$' && i + 1 < len(title) && title[i + 1] == '(' {
            if close := strings.index_byte(title[i:], ')'); close > 0 {
                i += close
                continue
            }
        }
        append(&out, title[i])
    }
    return strings.trim_space(string(out[:]))
}
