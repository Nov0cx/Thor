// Language injections: a range of one grammar's tree highlighted by another
// grammar, as a grammar's injections query names it.
package syntax

import "core:log"
import "core:strings"

import ts "../vendor/odin-tree-sitter"

// The most injected ranges one highlight call parses.
@(private)
MAX_INJECTIONS :: 128

// The grammar id a short language name in an injection query stands for.
@(private)
injection_alias :: proc(name: string) -> string {
    switch name {
    case "js", "jsx", "mjs":
        return "javascript"
    case "ts":
        return "typescript"
    case "py", "python3":
        return "python"
    case "rb":
        return "ruby"
    case "rs":
        return "rust"
    case "c++", "cxx", "cc":
        return "cpp"
    case "h":
        return "c"
    case "cs", "csharp":
        return "c_sharp"
    case "golang":
        return "go"
    case "hs":
        return "haskell"
    case "ml":
        return "ocaml"
    case "kt":
        return "kotlin"
    case "lisp":
        return "commonlisp"
    case "tf", "terraform":
        return "hcl"
    case "bzl":
        return "starlark"
    case "pas":
        return "pascal"
    }
    return ""
}

// The grammar id an injection's language name stands for, when it is compiled in.
@(private)
injection_grammar :: proc(h: ^Highlighter, name: string) -> (string, bool) {
    lower := strings.to_lower(strings.trim_space(name), context.temp_allocator)
    if lower in h.languages {
        return lower, true
    }
    if id := injection_alias(lower); id != "" && id in h.languages {
        return id, true
    }
    return "", false
}

// The injections query in force for `lang_id`: a plugin's override, else the
// compiled-in one. "" when the grammar has none.
@(private)
injections_source :: proc(h: ^Highlighter, lang_id: string) -> string {
    if source, ok := h.injection_overrides[lang_id]; ok {
        return source
    }
    return h.injections[lang_id]
}

// Replaces the injections query of `lang_id` with `source`. A query that does
// not compile is refused with the offset the grammar rejected.
set_injections :: proc(h: ^Highlighter, lang_id, source: string) -> (offset: u32, err: ts.Query_Error) {
    _, offset, err = query_for(h, lang_id, source)
    if err != .None {
        return offset, err
    }
    if old, ok := h.injection_overrides[lang_id]; ok {
        delete(old)
        h.injection_overrides[lang_id] = strings.clone(source)
        return 0, .None
    }
    h.injection_overrides[strings.clone(lang_id)] = strings.clone(source)
    return 0, .None
}

// Adds the captures of every injection in [lo, hi) of the tree under `root` to
// `caps`, each at depth 1 so it wins over the host capture it covers. One level
// only: an injected range is not searched for injections of its own.
@(private)
inject :: proc(h: ^Highlighter, source, lang_id: string, lo, hi: int, root: ts.Node, caps: ^[dynamic]Capture) {
    query_source := injections_source(h, lang_id)
    if query_source == "" {
        return
    }
    query, offset, err := query_for(h, lang_id, query_source)
    if err != .None {
        key := strings.concatenate({"injections of ", lang_id}, context.temp_allocator)
        if key not_in h.reported {
            h.reported[strings.clone(key)] = true
            log.warnf("syntax: the %s query does not compile: %v at byte %d", key, err, offset)
        }
        return
    }

    cursor := ts.query_cursor_new()
    defer ts.query_cursor_delete(cursor)
    if lo > 0 || hi < len(source) {
        ts.query_cursor_set_byte_range(cursor, u32(lo), u32(hi))
    }
    ts.query_cursor_exec(cursor, query, root)

    count := 0
    for match in ts.query_cursor_next_match(cursor) {
        props: Match_Props
        if !predicates_satisfied(h, query, match, source, &props) {
            continue
        }
        content: ts.Node
        found := false
        name  := props.injection_lang
        for i in 0 ..< int(match.capture_count) {
            c := match.captures[i]
            switch ts.query_capture_name_for_id(query, c.index) {
            case "injection.content":
                content, found = c.node, true
            case "injection.language":
                name = ts.node_text(c.node, source)
            }
        }
        if !found || name == "" {
            continue
        }
        child, known := injection_grammar(h, name)
        if !known {
            continue
        }
        if count >= MAX_INJECTIONS {
            break
        }
        count += 1
        inject_range(h, source, child, content, props.include_children, lo, hi, caps)
    }
}

// Parses the text of `content` with the grammar `child` and adds the captures of
// its highlights query inside [lo, hi). Without `include_children` the child
// nodes of `content` are left out of the parse, as tree-sitter defines it.
@(private)
inject_range :: proc(h: ^Highlighter, source, child: string, content: ts.Node, include_children: bool, lo, hi: int, caps: ^[dynamic]Capture) {
    entry := h.languages[child]
    query := highlighter_query(h, child, entry)
    if query == nil {
        return
    }
    start, end := int(ts.node_start_byte(content)), int(ts.node_end_byte(content))
    if end <= start {
        return
    }

    ranges := make([dynamic]ts.Range, context.temp_allocator)
    at_byte, at_point := u32(start), ts.node_start_point(content)
    if !include_children {
        for i in 0 ..< ts.node_child_count(content) {
            kid := ts.node_child(content, i)
            if ts.node_start_byte(kid) > at_byte {
                append(&ranges, ts.Range{at_point, ts.node_start_point(kid), at_byte, ts.node_start_byte(kid)})
            }
            at_byte, at_point = ts.node_end_byte(kid), ts.node_end_point(kid)
        }
    }
    if u32(end) > at_byte {
        append(&ranges, ts.Range{at_point, ts.node_end_point(content), at_byte, u32(end)})
    }
    if len(ranges) == 0 {
        return
    }

    if h.inject_lang_id != child {
        ts.parser_set_language(h.inject_parser, entry.lang)
        h.inject_lang_id = child
    }
    if !ts.parser_set_included_ranges(h.inject_parser, ranges[:]) {
        return
    }
    tree := ts.parser_parse_string(h.inject_parser, source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)

    clip_lo, clip_hi := max(lo, start), min(hi, end)
    if clip_hi <= clip_lo {
        return
    }
    cursor := ts.query_cursor_new()
    defer ts.query_cursor_delete(cursor)
    ts.query_cursor_set_byte_range(cursor, u32(clip_lo), u32(clip_hi))
    ts.query_cursor_exec(cursor, query, ts.tree_root_node(tree))
    for match in ts.query_cursor_next_match(cursor) {
        props: Match_Props
        if !predicates_satisfied(h, query, match, source, &props) {
            continue
        }
        for i in 0 ..< int(match.capture_count) {
            c    := match.captures[i]
            name := ts.query_capture_name_for_id(query, c.index)
            s    := max(int(ts.node_start_byte(c.node)), start)
            e    := min(int(ts.node_end_byte(c.node)), end)
            if e > s && !is_ignored_capture(name) {
                append(caps, Capture{s, e, name, int(match.pattern_index), props.priority, 1, child})
            }
        }
    }
}
