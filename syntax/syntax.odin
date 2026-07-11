// Tree-sitter backed syntax highlighting. Parses a buffer for a language and
// runs its highlights query, producing non-overlapping colored spans keyed by
// a small Token_Kind set that the UI maps to theme colors.
package syntax

import "core:strings"

import ts "../vendor/odin-tree-sitter"
import ts_odin "../vendor/odin-tree-sitter/parsers/odin"

Token_Kind :: enum {
    Default,
    Keyword,
    Function,
    Type,
    Constant,
    Number,
    String,
    Comment,
    Operator,
    Punctuation,
    Namespace,
    Parameter,
    Field,
    Variable,
    Attribute,
    Label,
    Preproc,
}

Span :: struct {
    start: int,
    end:   int,
    kind:  Token_Kind,
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

// True when highlighting is available for the language id.
supports :: proc(h: ^Highlighter, lang_id: string) -> bool {
    return lang_id in h.languages
}

// Parses `source` and returns non-overlapping highlight spans (ascending, using
// `allocator`). Empty when the language is unknown or parsing fails.
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

    spans := make([dynamic]Span, allocator)
    // First capture at each position wins; nested captures that start before the
    // last emitted end are skipped, giving clean non-overlapping spans.
    last_end := 0
    for match, cap_idx in ts.query_cursor_next_capture(cursor) {
        if len(ts.query_predicates_for_pattern(query, u32(match.pattern_index))) > 0 {
            continue // unevaluated predicate (#match?/#eq?) — skip to avoid false positives
        }
        cap := match.captures[cap_idx]
        start := int(ts.node_start_byte(cap.node))
        end := int(ts.node_end_byte(cap.node))
        if start < last_end || end <= start {
            continue
        }
        kind := kind_for_capture(ts.query_capture_name_for_id(query, cap.index))
        if kind == .Default {
            continue
        }
        append(&spans, Span{start, end, kind})
        last_end = end
    }
    return spans[:]
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

// Maps an nvim-treesitter capture name (e.g. "keyword.return", "type.builtin")
// to a Token_Kind by its leading component.
@(private)
kind_for_capture :: proc(name: string) -> Token_Kind {
    head := name
    if dot := strings.index_byte(name, '.'); dot >= 0 {
        head = name[:dot]
    }
    switch head {
    case "keyword", "conditional", "repeat", "include", "storageclass", "exception":
        return .Keyword
    case "function", "method", "constructor":
        return .Function
    case "type":
        return .Type
    case "constant", "boolean", "character":
        return .Constant
    case "number", "float":
        return .Number
    case "string":
        return .String
    case "comment":
        return .Comment
    case "operator":
        return .Operator
    case "punctuation":
        return .Punctuation
    case "namespace", "module":
        return .Namespace
    case "parameter":
        return .Parameter
    case "field", "property":
        return .Field
    case "variable":
        return .Variable
    case "attribute":
        return .Attribute
    case "label":
        return .Label
    case "preproc", "define", "macro":
        return .Preproc
    }
    return .Default
}
