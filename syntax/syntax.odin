// Tree-sitter backed parsing: parses a buffer for a grammar and runs its
// highlights query, producing non-overlapping spans tagged with the winning
// capture name. Mapping captures to colors is the caller's job, so this package
// stays free of any theme or role concept.
package syntax

import "base:runtime"
import "core:slice"
import "core:strings"

import "../treecache"
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
import ts_rust "../vendor/odin-tree-sitter/parsers/rust"
import ts_python "../vendor/odin-tree-sitter/parsers/python"
import ts_ruby "../vendor/odin-tree-sitter/parsers/ruby"
import ts_java "../vendor/odin-tree-sitter/parsers/java"
import ts_kotlin "../vendor/odin-tree-sitter/parsers/kotlin"
import ts_zig "../vendor/odin-tree-sitter/parsers/zig"
import ts_csharp "../vendor/odin-tree-sitter/parsers/c_sharp"
import ts_php "../vendor/odin-tree-sitter/parsers/php"
import ts_haskell "../vendor/odin-tree-sitter/parsers/haskell"
import ts_ocaml "../vendor/odin-tree-sitter/parsers/ocaml"

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

// Odin type aliases, appended to the vendored highlights query, which tags only
// the unmistakable right-hand sides and leaves `Vec :: Point`, `M :: map[K]V`
// and `C :: #type proc(...)` as plain variables. Later patterns win. A bare name
// is ambiguous with a constant alias, and the type reading wins. Kept here so
// re-vendoring the .scm cannot drop it.
@(private)
ODIN_ALIASES :: `
(const_declaration (identifier) @type "::"
  [(identifier) (member_expression) (map_type) (matrix_type) (type)])

(const_declaration "::" (identifier) @type)

(const_declaration "::" (member_expression (identifier) @namespace "." (identifier) @type))
`

Highlighter :: struct {
    parser:    ts.Parser,
    languages: map[string]Language_Entry,
    // Compiled queries, keyed by "<lang_id>\n<query source>"; keys are owned.
    // Keying on the source lets a plugin's own query live beside the built-in
    // one for the same grammar.
    queries:   map[string]ts.Query,
    // The highlights query in force per language, so the per-keystroke path
    // never rebuilds a key out of the multi-kilobyte query source. Keys are
    // owned, values borrowed from `queries`; an entry is dropped when an
    // override replaces the query.
    resolved:  map[string]ts.Query,
    // Highlights query a plugin supplied for a grammar, replacing the compiled-in
    // one. Keys and values are owned.
    overrides: map[string]string,
    lang_id:   string, // language currently set on the parser
    // Resident per-buffer trees, so a keystroke re-parses only the subtrees it
    // invalidated rather than the whole file. Highlighting and folding ask for
    // the same buffer back to back, and the second call re-parses nothing at
    // all — the source is unchanged.
    trees:     treecache.Cache,
}

highlighter_create :: proc() -> Highlighter {
    h: Highlighter
    h.parser = ts.parser_new()
    h.languages = make(map[string]Language_Entry)
    h.queries = make(map[string]ts.Query)
    h.resolved = make(map[string]ts.Query)
    h.overrides = make(map[string]string)
    treecache.init(&h.trees)
    h.languages["odin"] = Language_Entry{ts_odin.tree_sitter_odin(), ts_odin.HIGHLIGHTS + "\n" + ODIN_ALIASES}
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
    h.languages["rust"] = Language_Entry{ts_rust.tree_sitter_rust(), ts_rust.HIGHLIGHTS}
    h.languages["python"] = Language_Entry{ts_python.tree_sitter_python(), ts_python.HIGHLIGHTS}
    h.languages["ruby"] = Language_Entry{ts_ruby.tree_sitter_ruby(), ts_ruby.HIGHLIGHTS}
    h.languages["java"] = Language_Entry{ts_java.tree_sitter_java(), ts_java.HIGHLIGHTS}
    h.languages["kotlin"] = Language_Entry{ts_kotlin.tree_sitter_kotlin(), ts_kotlin.HIGHLIGHTS}
    h.languages["zig"] = Language_Entry{ts_zig.tree_sitter_zig(), ts_zig.HIGHLIGHTS}
    h.languages["c_sharp"] = Language_Entry{ts_csharp.tree_sitter_c_sharp(), ts_csharp.HIGHLIGHTS}
    h.languages["php"] = Language_Entry{ts_php.tree_sitter_php(), ts_php.HIGHLIGHTS}
    h.languages["haskell"] = Language_Entry{ts_haskell.tree_sitter_haskell(), ts_haskell.HIGHLIGHTS}
    h.languages["ocaml"] = Language_Entry{ts_ocaml.tree_sitter_ocaml(), ts_ocaml.HIGHLIGHTS}
    return h
}

highlighter_destroy :: proc(h: ^Highlighter) {
    for key, query in h.queries {
        ts.query_delete(query)
        delete(key)
    }
    delete(h.queries)
    for id in h.resolved {
        delete(id)
    }
    delete(h.resolved)
    for id, source in h.overrides {
        delete(id)
        delete(source)
    }
    delete(h.overrides)
    delete(h.languages)
    treecache.destroy(&h.trees)
    ts.parser_delete(h.parser)
}

// True when a grammar is compiled in for the id.
supports :: proc(h: ^Highlighter, lang_id: string) -> bool {
    return lang_id in h.languages
}

// Parses `source` with the named grammar and returns non-overlapping spans
// (ascending, using `allocator`), each tagged with its winning capture name.
// `path` names the buffer so the parse can reuse its resident tree (see
// parse_tree). Empty when the grammar is unknown or parsing fails.
highlight :: proc(h: ^Highlighter, path, source, lang_id: string, allocator := context.allocator) -> []Span {
    return highlight_range(h, path, source, lang_id, 0, max(int), allocator)
}

// Spans for the captures that intersect [range_start, range_end), the vehicle
// for coloring only what a pane shows. The tree stays whole-file, so a node that
// opens before the range — a block comment, a raw string — is still reported
// with its real extent; only the query is windowed. Cost follows the range, not
// the document, which is what keeps a large buffer's per-keystroke work bounded.
highlight_range :: proc(
    h: ^Highlighter,
    path, source, lang_id: string,
    range_start, range_end: int,
    allocator := context.allocator,
) -> []Span {
    entry, ok := h.languages[lang_id]
    if !ok {
        return nil
    }

    query := highlighter_query(h, lang_id, entry)
    if query == nil {
        return nil
    }

    tree := parse_tree(h, path, source, lang_id, entry)
    if tree == nil {
        return nil
    }
    defer ts.tree_delete(tree)

    root := ts.tree_root_node(tree)
    packages := package_names(root, source, lang_id)

    cursor := ts.query_cursor_new()
    defer ts.query_cursor_delete(cursor)
    lo := clamp(range_start, 0, len(source))
    hi := clamp(range_end, lo, len(source))
    if lo > 0 || hi < len(source) {
        ts.query_cursor_set_byte_range(cursor, u32(lo), u32(hi))
    }
    ts.query_cursor_exec(cursor, query, root)

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
            if capture_head(name) == "variable" && is_qualifier(c.node) && ts.node_text(c.node, source) in packages {
                name = "namespace"
            }
            start := int(ts.node_start_byte(c.node))
            end := int(ts.node_end_byte(c.node))
            if end > start && !is_ignored_capture(name) {
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
// node is skipped so the whole file is never a single fold. `path` names the
// buffer, as for `highlight` — folding runs right after it on the same source,
// so it reuses that very tree. Ascending by start line, using `allocator`; empty
// when the grammar is unknown or parsing fails.
fold_ranges :: proc(h: ^Highlighter, path, source, lang_id: string, allocator := context.allocator) -> []Fold_Range {
    entry, ok := h.languages[lang_id]
    if !ok {
        return nil
    }

    tree := parse_tree(h, path, source, lang_id, entry)
    if tree == nil {
        return nil
    }
    defer ts.tree_delete(tree)
    root := ts.tree_root_node(tree)

    // start line -> widest end line seen for a node starting there.
    ends := make(map[int]int, context.temp_allocator)
    // Cursor DFS over the root's descendants, pruned at every single-line node:
    // a node's extent contains its children's, so nothing under a node that sits
    // on one line can span two. That skips every token and leaf expression,
    // which is nearly the whole tree. The root itself is not a fold.
    cursor := ts.tree_cursor_new(root)
    defer ts.tree_cursor_delete(&cursor)
    depth := 0
    if ts.tree_cursor_goto_first_child(&cursor) {
        depth = 1
        walk: for {
            node := ts.tree_cursor_current_node(&cursor)
            sr := int(ts.node_start_point(node).row)
            er := int(ts.node_end_point(node).row)
            if er > sr {
                if cur, has := ends[sr]; !has || er > cur {
                    ends[sr] = er
                }
                if ts.tree_cursor_goto_first_child(&cursor) {
                    depth += 1
                    continue walk
                }
            }
            for {
                if ts.tree_cursor_goto_next_sibling(&cursor) {
                    continue walk
                }
                if !ts.tree_cursor_goto_parent(&cursor) {
                    break walk
                }
                depth -= 1
                if depth == 0 {
                    break walk
                }
            }
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

// The parse tree for `source`, off `path`'s resident tree when there is one:
// the cached source is diffed to one changed span and only the subtrees that
// span invalidated are rebuilt, so a keystroke costs a fraction of a whole-file
// parse and an unchanged source costs no parse at all. An empty `path` is a
// buffer with no stable identity — it parses whole and caches nothing.
//
// The caller owns the returned tree and must `tree_delete` it.
@(private)
parse_tree :: proc(h: ^Highlighter, path, source, lang_id: string, entry: Language_Entry) -> ts.Tree {
    if h.lang_id != lang_id {
        ts.parser_set_language(h.parser, entry.lang)
        h.lang_id = lang_id
    }
    if path == "" {
        return ts.parser_parse_string(h.parser, source)
    }
    return treecache.for_source(&h.trees, h.parser, path, lang_id, source)
}

// Package names an Odin file's imports bind: the alias when given, else the
// path's last segment (`import "core:mem"` -> "mem"). Odin's highlights query
// only tags a qualifier inside a type (`mem.Tracking_Allocator`), so without
// this the same package reads as a plain variable in `mem.foo(...)`. Empty for
// every other grammar. Uses the temp allocator.
// How far into a file package_names looks for imports. Generous for any real
// header, and what keeps the scan off the declaration count of a large buffer.
@(private)
IMPORT_SCAN_BYTES :: 64 * 1024

@(private)
package_names :: proc(root: ts.Node, source, lang_id: string) -> map[string]bool {
    if lang_id != "odin" {
        return nil
    }
    names := make(map[string]bool, context.temp_allocator)
    // A cursor walk, not an indexed one: node_named_child restarts from the
    // first child and node_next_named_sibling re-searches the parent, so both
    // cost the document's declaration count per step. A cursor steps in O(1).
    cursor := ts.tree_cursor_new(root)
    defer ts.tree_cursor_delete(&cursor)
    if !ts.tree_cursor_goto_first_child(&cursor) {
        return names
    }
    for {
        imp := ts.tree_cursor_current_node(&cursor)
        // Imports sit in a file's header. Walking every top-level declaration of
        // a multi-megabyte buffer to find them costs more than the highlight
        // itself, so the search stops past a header-sized prefix; an import
        // below that reads as a plain variable, which is only a color.
        if int(ts.node_start_byte(imp)) >= IMPORT_SCAN_BYTES {
            break
        }
        if ts.node_is_named(imp) && string(ts.node_type(imp)) == "import_declaration" {
            if alias := ts.node_child_by_field_name(imp, "alias"); !ts.node_is_null(alias) {
                names[ts.node_text(alias, source)] = true
            } else if path, ok := import_path(imp, source); ok {
                names[path_tail(path)] = true
            }
        }
        if !ts.tree_cursor_goto_next_sibling(&cursor) {
            break
        }
    }
    return names
}

// The unquoted path of an import_declaration, via its string_content child.
@(private)
import_path :: proc(imp: ts.Node, source: string) -> (string, bool) {
    for i in 0 ..< ts.node_named_child_count(imp) {
        str := ts.node_named_child(imp, i)
        if string(ts.node_type(str)) != "string" {
            continue
        }
        for j in 0 ..< ts.node_named_child_count(str) {
            if content := ts.node_named_child(str, j); string(ts.node_type(content)) == "string_content" {
                return ts.node_text(content, source), true
            }
        }
    }
    return "", false
}

// Last segment of an import path, after any collection prefix and any separator:
// "core:mem" -> "mem", "core:odin/parser" -> "parser", "../lang" -> "lang".
@(private)
path_tail :: proc(path: string) -> string {
    s := path
    if colon := strings.last_index_byte(s, ':'); colon >= 0 {
        s = s[colon + 1:]
    }
    if sep := max(strings.last_index_byte(s, '/'), strings.last_index_byte(s, '\\')); sep >= 0 {
        s = s[sep + 1:]
    }
    return s
}

// True when `node` is the left-hand side of a qualified reference (the `mem` in
// `mem.foo(...)` or `mem.Foo`).
@(private)
is_qualifier :: proc(node: ts.Node) -> bool {
    parent := ts.node_parent(node)
    if ts.node_is_null(parent) {
        return false
    }
    switch string(ts.node_type(parent)) {
    case "member_expression", "field_type":
        first := ts.node_named_child(parent, 0)
        return !ts.node_is_null(first) && ts.node_eq(first, node)
    }
    return false
}

@(private)
Capture :: struct {
    start:   int,
    end:     int,
    capture: string,
    pattern: int,
}

// Captures that must not colour text: @spell/@nospell/@conceal/@none drive other
// editor features, and captures whose name starts with "_" are private helpers a
// grammar's query uses only inside predicates. Skipping them keeps such a capture
// from shadowing the real highlight on the same node (it would otherwise win on a
// higher pattern index, e.g. tree-sitter-haskell's trailing `(comment) @spell`).
@(private)
is_ignored_capture :: proc(name: string) -> bool {
    switch name {
    case "spell", "nospell", "conceal", "none":
        return true
    }
    return len(name) > 0 && name[0] == '_'
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

// Evaluates a match's predicates, for a caller running its own query (see
// plugin's thor.ts). Same rule as highlighting: a predicate we can't evaluate
// fails.
predicates_ok :: proc(query: ts.Query, match: ts.Query_Match, source: string) -> bool {
    return predicates_satisfied(query, match, source)
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

// The highlights query for a language: the source a plugin supplied when there
// is one, else the query compiled in with the grammar. Answered from `resolved`
// after the first call, so the hot path costs one lookup on the language id.
@(private)
highlighter_query :: proc(h: ^Highlighter, lang_id: string, entry: Language_Entry) -> ts.Query {
    if cached, ok := h.resolved[lang_id]; ok {
        return cached
    }
    source := entry.highlights
    if override, ok := h.overrides[lang_id]; ok {
        source = override
    }
    query, _, err := query_for(h, lang_id, source)
    if err != .None {
        return nil
    }
    h.resolved[strings.clone(lang_id)] = query
    return query
}

// Compiles `source` against the grammar for `lang_id`, caching by both, so a
// plugin running the same query every keystroke pays for it once. A failed
// compile returns the byte offset the grammar rejected — the caller reports it;
// nothing here writes to the console.
query_for :: proc(h: ^Highlighter, lang_id, source: string) -> (query: ts.Query, offset: u32, err: ts.Query_Error) {
    entry, known := h.languages[lang_id]
    if !known {
        return nil, 0, .Language
    }

    key := strings.concatenate({lang_id, "\n", source}, context.temp_allocator)
    if cached, ok := h.queries[key]; ok {
        return cached, 0, .None
    }

    query, offset, err = ts.query_new(entry.lang, source)
    if err != .None {
        return nil, offset, err
    }
    h.queries[strings.clone(key)] = query
    return query, 0, .None
}

// Replaces the highlights query for `lang_id` with `source`. The query is
// compiled at once so a broken one is reported where it was declared rather
// than silently leaving a file uncolored; on failure nothing changes.
set_highlights :: proc(h: ^Highlighter, lang_id, source: string) -> (offset: u32, err: ts.Query_Error) {
    _, offset, err = query_for(h, lang_id, source)
    if err != .None {
        return offset, err
    }
    if key, _ := delete_key(&h.resolved, lang_id); key != "" {
        delete(key)
    }
    if existing, ok := h.overrides[lang_id]; ok {
        delete(existing)
        h.overrides[lang_id] = strings.clone(source)
        return 0, .None
    }
    h.overrides[strings.clone(lang_id)] = strings.clone(source)
    return 0, .None
}

// The compiled grammar for `lang_id`, for a caller that drives tree-sitter
// itself (the plugin `thor.ts` bindings).
language :: proc(h: ^Highlighter, lang_id: string) -> (ts.Language, bool) {
    entry, ok := h.languages[lang_id]
    if !ok {
        return nil, false
    }
    return entry.lang, true
}
