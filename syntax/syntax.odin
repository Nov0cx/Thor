// Tree-sitter backed parsing: parses a buffer for a grammar and runs its
// highlights query, producing non-overlapping spans tagged with the winning
// capture name. Mapping captures to colors is the caller's job, so this package
// stays free of any theme or role concept.
package syntax

import "base:runtime"
import "core:slice"
import "core:strings"

import ts "../vendor/odin-tree-sitter"
import ts_c "../vendor/odin-tree-sitter/parsers/c"
import ts_cpp "../vendor/odin-tree-sitter/parsers/cpp"
import ts_go "../vendor/odin-tree-sitter/parsers/go"
import ts_jai "../vendor/odin-tree-sitter/parsers/jai"
import ts_js "../vendor/odin-tree-sitter/parsers/javascript"
import ts_lua "../vendor/odin-tree-sitter/parsers/lua"
import ts_odin "../vendor/odin-tree-sitter/parsers/odin"
import ts_ts "../vendor/odin-tree-sitter/parsers/typescript"
import ts_tsx "../vendor/odin-tree-sitter/parsers/tsx"

// A resolved highlight span. `capture` is the tree-sitter capture name that won
// this byte range (e.g. "keyword.return", "type.builtin", "function.call").
Span :: struct {
    start:   int,
    end:     int,
    capture: string,
}

@(private)
Language_Entry :: struct {
    lang:       ts.Language,
    highlights: string,
}

Highlighter :: struct {
    parser:    ts.Parser,
    languages: map[string]Language_Entry,
    queries:   map[string]ts.Query,
    lang_id:   string, // language currently set on the parser
}

highlighter_create :: proc() -> Highlighter {
    h: Highlighter
    h.parser = ts.parser_new()
    h.languages = make(map[string]Language_Entry)
    h.queries = make(map[string]ts.Query)
    h.languages["odin"] = Language_Entry{ts_odin.tree_sitter_odin(), ts_odin.HIGHLIGHTS}
    h.languages["lua"] = Language_Entry{ts_lua.tree_sitter_lua(), ts_lua.HIGHLIGHTS}
    h.languages["c"] = Language_Entry{ts_c.tree_sitter_c(), ts_c.HIGHLIGHTS}
    h.languages["cpp"] = Language_Entry{ts_cpp.tree_sitter_cpp(), ts_cpp.HIGHLIGHTS}
    h.languages["go"] = Language_Entry{ts_go.tree_sitter_go(), ts_go.HIGHLIGHTS}
    h.languages["jai"] = Language_Entry{ts_jai.tree_sitter_jai(), ts_jai.HIGHLIGHTS}
    // The JS/TS grammars share a highlights base: the typescript and tsx queries
    // only add type/keyword rules and rely on the javascript query for the rest,
    // so the base is prepended (later patterns win, letting the specific queries
    // override). tsx and js also need the JSX rules, which typescript must omit
    // since its grammar has no JSX nodes (an unknown node type fails the query).
    h.languages["javascript"] = Language_Entry{ts_js.tree_sitter_javascript(), ts_js.HIGHLIGHTS + "\n" + ts_js.HIGHLIGHTS_JSX}
    h.languages["typescript"] = Language_Entry{ts_ts.tree_sitter_typescript(), ts_js.HIGHLIGHTS + "\n" + ts_ts.HIGHLIGHTS}
    h.languages["tsx"] = Language_Entry{ts_tsx.tree_sitter_tsx(), ts_js.HIGHLIGHTS + "\n" + ts_js.HIGHLIGHTS_JSX + "\n" + ts_tsx.HIGHLIGHTS}
    return h
}

highlighter_destroy :: proc(h: ^Highlighter) {
    for _, query in h.queries {
        ts.query_delete(query)
    }
    delete(h.queries)
    delete(h.languages)
    ts.parser_delete(h.parser)
}

// True when a grammar is compiled in for the id.
supports :: proc(h: ^Highlighter, lang_id: string) -> bool {
    return lang_id in h.languages
}

// Parses `source` with the named grammar and returns non-overlapping spans
// (ascending, using `allocator`), each tagged with its winning capture name.
// Empty when the grammar is unknown or parsing fails.
highlight :: proc(h: ^Highlighter, source: string, lang_id: string, allocator := context.allocator) -> []Span {
    entry, ok := h.languages[lang_id]
    if !ok {
        return nil
    }
    if h.lang_id != lang_id {
        ts.parser_set_language(h.parser, entry.lang)
        h.lang_id = lang_id
    }

    query := highlighter_query(h, lang_id, entry)
    if query == nil {
        return nil
    }

    tree := ts.parser_parse_string(h.parser, source)
    if tree == nil {
        return nil
    }
    defer ts.tree_delete(tree)

    cursor := ts.query_cursor_new()
    defer ts.query_cursor_delete(cursor)
    ts.query_cursor_exec(cursor, query, ts.tree_root_node(tree))

    // Collect every satisfied capture; resolve_spans breaks overlaps by
    // precedence so specific captures override the broad @variable rule.
    caps := make([dynamic]Capture, context.temp_allocator)
    for match in ts.query_cursor_next_match(cursor) {
        if !predicates_satisfied(query, match, source) {
            continue
        }
        for i in 0 ..< int(match.capture_count) {
            c := match.captures[i]
            name := ts.query_capture_name_for_id(query, c.index)
            start := int(ts.node_start_byte(c.node))
            end := int(ts.node_end_byte(c.node))
            if end > start {
                append(&caps, Capture{start, end, name, int(match.pattern_index)})
            }
        }
    }
    return resolve_spans(caps[:], allocator)
}

// A foldable region, in 0-based logical line numbers. `start_line` stays visible
// (it holds the opening token, e.g. `{`); folding hides start_line+1 .. end_line.
Fold_Range :: struct {
    start_line: int,
    end_line:   int,
}

// Parses `source` and derives foldable line ranges from the syntax tree: any
// node spanning more than one line is a candidate, keeping the widest region per
// starting line (so `foo :: proc(...) {` and its `block` fold as one). Grammar-
// agnostic — every compiled language folds with no per-language rules. The root
// node is skipped so the whole file is never a single fold. Ascending by start
// line, using `allocator`; empty when the grammar is unknown or parsing fails.
fold_ranges :: proc(h: ^Highlighter, source: string, lang_id: string, allocator := context.allocator) -> []Fold_Range {
    entry, ok := h.languages[lang_id]
    if !ok {
        return nil
    }
    if h.lang_id != lang_id {
        ts.parser_set_language(h.parser, entry.lang)
        h.lang_id = lang_id
    }

    tree := ts.parser_parse_string(h.parser, source)
    if tree == nil {
        return nil
    }
    defer ts.tree_delete(tree)
    root := ts.tree_root_node(tree)

    // start line -> widest end line seen for a node starting there.
    ends := make(map[int]int, context.temp_allocator)
    stack := make([dynamic]ts.Node, context.temp_allocator)
    append(&stack, root)
    for len(stack) > 0 {
        node := pop(&stack)
        if !ts.node_eq(node, root) {
            sr := int(ts.node_start_point(node).row)
            er := int(ts.node_end_point(node).row)
            if er > sr {
                if cur, has := ends[sr]; !has || er > cur {
                    ends[sr] = er
                }
            }
        }
        for i in 0 ..< ts.node_child_count(node) {
            append(&stack, ts.node_child(node, i))
        }
    }

    out := make([dynamic]Fold_Range, 0, len(ends), allocator)
    for sr, er in ends {
        append(&out, Fold_Range{sr, er})
    }
    slice.sort_by(out[:], proc(a, b: Fold_Range) -> bool {
        return a.start_line < b.start_line
    })
    return out[:]
}

@(private)
Capture :: struct {
    start:   int,
    end:     int,
    capture: string,
    pattern: int,
}

// Leading component of a capture name ("type.builtin" -> "type").
@(private)
capture_head :: proc(name: string) -> string {
    if dot := strings.index_byte(name, '.'); dot >= 0 {
        return name[:dot]
    }
    return name
}

// Flattens overlapping captures into ascending, non-overlapping, merged spans.
// A scanline picks, for each interval, the covering capture with the highest
// pattern index (ties broken by the smaller range).
@(private)
resolve_spans :: proc(caps: []Capture, allocator: runtime.Allocator) -> []Span {
    if len(caps) == 0 {
        return nil
    }

    Event :: struct {
        pos:   int,
        start: bool,
        cap:   int,
    }
    events := make([dynamic]Event, 0, len(caps) * 2, context.temp_allocator)
    for c, idx in caps {
        append(&events, Event{c.start, true, idx})
        append(&events, Event{c.end, false, idx})
    }
    slice.sort_by(events[:], proc(a, b: Event) -> bool {return a.pos < b.pos})

    spans := make([dynamic]Span, allocator)
    active := make([dynamic]int, context.temp_allocator)
    i := 0
    prev := events[0].pos
    for i < len(events) {
        pos := events[i].pos
        if pos > prev && len(active) > 0 {
            best := active[0]
            for a in active[1:] {
                if better_capture(caps[a], caps[best]) {
                    best = a
                }
            }
            emit_span(&spans, prev, pos, caps[best].capture)
        }
        for i < len(events) && events[i].pos == pos {
            e := events[i]
            if e.start {
                append(&active, e.cap)
            } else {
                for idx in 0 ..< len(active) {
                    if active[idx] == e.cap {
                        unordered_remove(&active, idx)
                        break
                    }
                }
            }
            i += 1
        }
        prev = pos
    }
    return spans[:]
}

@(private)
better_capture :: proc(a, b: Capture) -> bool {
    // A named parameter is captured as both @parameter and @type inside a
    // procedure_type; keep it a parameter regardless of pattern order.
    ah, bh := capture_head(a.capture), capture_head(b.capture)
    if ah == "parameter" && bh == "type" {
        return true
    }
    if ah == "type" && bh == "parameter" {
        return false
    }
    if a.pattern != b.pattern {
        return a.pattern > b.pattern
    }
    return (a.end - a.start) < (b.end - b.start)
}

@(private)
emit_span :: proc(spans: ^[dynamic]Span, start, end: int, capture: string) {
    if len(spans) > 0 {
        last := &spans[len(spans) - 1]
        if last.capture == capture && last.end == start {
            last.end = end
            return
        }
    }
    append(spans, Span{start, end, capture})
}

// Evaluates a pattern's predicates. Handles the common filtering predicates
// (#eq?/#any-of? and negations); #set! and other directives pass through. Any
// predicate we can't evaluate fails conservatively so it can't mis-highlight.
@(private)
predicates_satisfied :: proc(query: ts.Query, match: ts.Query_Match, source: string) -> bool {
    steps := ts.query_predicates_for_pattern(query, u32(match.pattern_index))
    i := 0
    for i < len(steps) {
        op := ts.query_string_value_for_id(query, steps[i].value_id)
        args := make([dynamic]string, context.temp_allocator)
        j := i + 1
        for j < len(steps) && steps[j].type != .Done {
            step := steps[j]
            if step.type == .Capture {
                append(&args, capture_text(query, match, step.value_id, source))
            } else {
                append(&args, ts.query_string_value_for_id(query, step.value_id))
            }
            j += 1
        }
        i = j + 1

        if strings.has_suffix(op, "!") {
            continue // directive (#set!, #make-range! ...), not a filter
        }
        if !eval_predicate(op, args[:]) {
            return false
        }
    }
    return true
}

@(private)
eval_predicate :: proc(op: string, args: []string) -> bool {
    switch op {
    case "eq?":
        return len(args) >= 2 && args[0] == args[1]
    case "not-eq?":
        return len(args) >= 2 && args[0] != args[1]
    case "any-of?":
        return len(args) >= 1 && slice.contains(args[1:], args[0])
    case "not-any-of?":
        return len(args) >= 1 && !slice.contains(args[1:], args[0])
    }
    return false // unhandled filter (#match?/#lua-match?/#has-parent? ...)
}

@(private)
capture_text :: proc(query: ts.Query, match: ts.Query_Match, capture_id: u32, source: string) -> string {
    for i in 0 ..< int(match.capture_count) {
        c := match.captures[i]
        if c.index == capture_id {
            return ts.node_text(c.node, source)
        }
    }
    return ""
}

@(private)
highlighter_query :: proc(h: ^Highlighter, lang_id: string, entry: Language_Entry) -> ts.Query {
    if query, ok := h.queries[lang_id]; ok {
        return query
    }
    query, _, err := ts.query_new(entry.lang, entry.highlights)
    if err != .None {
        return nil
    }
    h.queries[lang_id] = query
    return query
}
