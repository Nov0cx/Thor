// Shared tree and text helpers: writing a resolved declaration into a Result,
// walking to an ancestor node, reading selectors and imports, and mapping an
// import path to the package directory on disk.
package odin

import "core:os"
import "core:path/filepath"
import "core:strings"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// Reads a source file the way the editor holds it: CRLF collapsed to LF. The
// seam owns that byte space, so this is a wrapper — it exists to keep the call
// sites in this package short.
@(private)
source_read :: proc(path: string, allocator := context.temp_allocator) -> (string, bool) {
    return lang.source_read(path, allocator)
}

// Writes the resolved declaration into the result for the requested feature.
// Owned strings use context.allocator, which the worker set to the Manager's
// allocator, so they are freed on the main thread after the editor reads them.
@(private)
fill_result :: proc(res: ^lang.Result, req: ^lang.Request, path, source: string, d: Def, hover_start, hover_end: int) {
    #partial switch req.kind {
    case .Definition:
        res.location = lang.Location {
            path  = strings.clone(path),
            start = d.ident_start,
            end   = d.ident_end,
        }
        res.ok = true
    case .Hover:
        res.hover = lang.Hover_Info {
            text  = declaration_text(source, d),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
}

// One-line signature for a symbol-list row: `name :: type`, trimmed. Starts at
// the declared identifier (so any leading `@(...)` attribute is skipped) and
// stops at the body brace. `foo :: proc(x: int) -> int {` and `Point :: struct {`
// yield `foo :: proc(x: int) -> int` and `Point :: struct`. A signature written
// across several lines is flattened onto one, never cut — a truncated head like
// `foo :: proc(` has an unbalanced parameter group, which blinds every reader of
// this text (`param_arity`, `signature_param_text`, overload narrowing).
// Cloned into context.allocator.
@(private)
signature_text :: proc(source: string, d: Def) -> string {
    start := clamp(d.ident_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := source[start:end]

    // A procedure group's brace opens its member list, not a body, and the list
    // is the only thing the row has to say — cutting at the brace would leave
    // every group in the workspace showing the same `sizes :: proc`.
    if !d.overload {
        if brace := body_brace_index(text); brace >= 0 {
            text = text[:brace]
        }
    }
    return flatten_lines(text)
}

// Index of the brace that opens a body, or -1. Braces nested in a parameter list
// or an index expression belong to a default value (`x: Point = {}`) or a type,
// not a body, so only depth-zero braces count; string and rune literals are
// skipped whole.
@(private = "file")
body_brace_index :: proc(text: string) -> int {
    depth := 0
    i := 0
    for i < len(text) {
        switch text[i] {
        case '(', '[':
            depth += 1
        case ')', ']':
            depth -= 1
        case '{':
            if depth <= 0 {
                return i
            }
        case '"', '`', '\'':
            i = literal_end(text, i)
            continue
        }
        i += 1
    }
    return -1
}

// Index just past the string or rune literal that opens at `start`, or past the
// end of the text when it is never closed. Backslash escapes are honored, except
// in a raw (backquoted) string, which has none.
@(private = "file")
literal_end :: proc(text: string, start: int) -> int {
    quote := text[start]
    i := start + 1
    for i < len(text) {
        c := text[i]
        if c == '\\' && quote != '`' {
            i += 2
            continue
        }
        if c == quote {
            return i + 1
        }
        i += 1
    }
    return len(text)
}

// `text` with every run of whitespace collapsed to a single space, so a
// declaration written across several lines still fits a one-line row. Allocated
// in context.allocator, like the other text builders here.
@(private)
flatten_lines :: proc(text: string) -> string {
    b := strings.builder_make(context.allocator)
    space := false
    for i in 0 ..< len(text) {
        c := text[i]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
            space = true
            continue
        }
        if space && strings.builder_len(b) > 0 {
            strings.write_byte(&b, ' ')
        }
        space = false
        strings.write_byte(&b, c)
    }
    return strings.to_string(b)
}

// The full declaration text for a hover popup: the whole declaration node,
// trimmed, including any leading `@(...)` attribute (the grammar nests it as the
// declaration's first child, so decl_start already covers it). A procedure keeps
// only its signature — the body brace onward is dropped — while a type
// declaration (struct/enum/union/bit_field) or any other multi-line declaration
// is shown complete, across every line. Cloned into context.allocator.
@(private)
declaration_text :: proc(source: string, d: Def) -> string {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := source[start:end]

    // Procedures: show the signature, not the body. The first depth-zero `{` opens
    // the body, so cutting there keeps any attribute line and the
    // `name :: proc(...) -> ...` head. A procedure group is the exception — it has
    // no body, and the brace it does have holds the members, which are the whole
    // content of the declaration.
    if d.kind == "function" && !d.overload {
        if brace := body_brace_index(text); brace >= 0 {
            text = text[:brace]
        }
    }
    return strings.clone(strings.trim_space(text))
}

// Nearest ancestor whose node type equals `type`.
@(private)
ancestor_type :: proc(node: ts.Node, type: string) -> (ts.Node, bool) {
    n := ts.node_parent(node)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == type {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Nearest ancestor whose node type ends with `suffix` (e.g. "_declaration").
@(private)
ancestor_suffix :: proc(node: ts.Node, suffix: string) -> (ts.Node, bool) {
    n := ts.node_parent(node)
    for !ts.node_is_null(n) {
        if strings.has_suffix(string(ts.node_type(n)), suffix) {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// True when both nodes are non-null and cover the same byte range. tree-sitter
// Nodes are values, not pointers, so identity is compared by span.
@(private)
same_node :: proc(a, b: ts.Node) -> bool {
    return !ts.node_is_null(a) && !ts.node_is_null(b) &&
        ts.node_start_byte(a) == ts.node_start_byte(b) &&
        ts.node_end_byte(a) == ts.node_end_byte(b)
}

// If `ident` is part of a `pkg.member` selector, returns the package operand
// node and the member (symbol) node, whether the caret sits on either side.
// Handles the three grammar shapes this produces:
//   `pkg.lang.Symbol`      -> member_expression (identifier . identifier)
//   `pkg.fn(args)`    -> member_expression (identifier . call_expression)
//   `pkg.Type` (type) -> field_type        (identifier . identifier)
@(private)
selector_parts :: proc(ident: ts.Node) -> (pkg: ts.Node, member: ts.Node, ok: bool) {
    p := ts.node_parent(ident)
    if ts.node_is_null(p) {
        return {}, {}, false
    }
    pt := string(ts.node_type(p))

    if pt == "member_expression" || pt == "field_type" {
        a := ts.node_named_child(p, 0)
        b := ts.node_named_child(p, 1)
        if ts.node_is_null(a) || ts.node_is_null(b) {
            return {}, {}, false
        }
        // `pkg.fn(args)`: the member is the call's function identifier.
        if string(ts.node_type(b)) == "call_expression" {
            if fn := ts.node_child_by_field_name(b, "function"); !ts.node_is_null(fn) {
                b = fn
            }
        }
        return a, b, true
    }

    // Caret on `fn` in `pkg.fn(args)`: the identifier's parent is the call, whose
    // parent is the member_expression carrying the package operand.
    if pt == "call_expression" {
        gp := ts.node_parent(p)
        if !ts.node_is_null(gp) && string(ts.node_type(gp)) == "member_expression" {
            a := ts.node_named_child(gp, 0)
            if same_node(ts.node_named_child(gp, 1), p) {
                return a, ident, true
            }
        }
    }

    return {}, {}, false
}

// Import path (the collection-qualified or relative string) declared in `root`
// for the package named `pkg`, matching either an explicit alias or the name
// derived from the path's last segment.
@(private)
import_path :: proc(root: ts.Node, source: string, pkg: string) -> (string, bool) {
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        if name, raw, ok := import_name_and_path(child, source); ok && name == pkg {
            return raw, true
        }
    }
    return "", false
}

// Package name and path for one import_declaration. The name is the explicit
// alias when present, otherwise the path's last segment.
@(private)
import_name_and_path :: proc(imp: ts.Node, source: string) -> (name: string, raw: string, ok: bool) {
    raw, ok = import_string(imp, source)
    if !ok {
        return "", "", false
    }
    if alias := ts.node_child_by_field_name(imp, "alias"); !ts.node_is_null(alias) && is_identifier(alias) {
        return ts.node_text(alias, source), raw, true
    }
    return package_name_from_path(raw), raw, true
}

// The quoted path of an import_declaration, unquoted (via the string_content
// child, falling back to trimming the quote bytes).
@(private)
import_string :: proc(imp: ts.Node, source: string) -> (string, bool) {
    for i in 0 ..< ts.node_named_child_count(imp) {
        c := ts.node_named_child(imp, i)
        if string(ts.node_type(c)) != "string" {
            continue
        }
        return string_literal_text(c, source), true
    }
    return "", false
}

// The text inside a `string` node, without its quotes: the `string_content`
// child, falling back to trimming the quote bytes when the literal is empty and
// has none.
@(private)
string_literal_text :: proc(n: ts.Node, source: string) -> string {
    for i in 0 ..< ts.node_named_child_count(n) {
        sc := ts.node_named_child(n, i)
        if string(ts.node_type(sc)) == "string_content" {
            return ts.node_text(sc, source)
        }
    }
    t := ts.node_text(n, source)
    t = strings.trim_prefix(t, "\"")
    t = strings.trim_suffix(t, "\"")
    return t
}

// Last path segment of an import path, after any collection prefix and any
// slash: "core:fmt" -> "fmt", "core:odin/parser" -> "parser", "../lang" -> "lang".
@(private)
package_name_from_path :: proc(raw: string) -> string {
    s := raw
    if colon := strings.last_index_byte(s, ':'); colon >= 0 {
        s = s[colon + 1:]
    }
    if slash := strings.last_index_byte(s, '/'); slash >= 0 {
        s = s[slash + 1:]
    }
    if back := strings.last_index_byte(s, '\\'); back >= 0 {
        s = s[back + 1:]
    }
    return s
}

// Directory an import path points at. Relative paths resolve against the
// importing file's directory (fully in-workspace). `core:`/`vendor:`/`base:`
// collections resolve against ODIN_ROOT when the environment exposes it; any
// other collection is looked up in the workspace's `.thor/odin-analyzer.json`
// config, so a project's custom collections (`import "shared:foo"`) resolve.
// An unknown collection has no mapping. Returned dir is scratch-allocated.
@(private)
package_dir :: proc(e: ^Engine, raw: string, req_path: string, workspace: string) -> (string, bool) {
    if colon := strings.index_byte(raw, ':'); colon >= 0 {
        coll := raw[:colon]
        sub := raw[colon + 1:]
        if coll == "core" || coll == "vendor" || coll == "base" {
            root := odin_root()
            if root == "" {
                return "", false
            }
            joined, err := filepath.join({root, coll, sub}, context.temp_allocator)
            return joined, err == nil
        }
        if croot, ok := config_collection_dir(e, coll, workspace); ok {
            joined, err := filepath.join({croot, sub}, context.temp_allocator)
            return joined, err == nil
        }
        return "", false
    }

    base := filepath.dir(req_path)
    joined, jerr := filepath.join({base, raw}, context.temp_allocator)
    if jerr != nil {
        return "", false
    }
    cleaned, cerr := filepath.clean(joined, context.temp_allocator)
    if cerr != nil {
        return joined, true
    }
    return cleaned, true
}

// Odin's install root, so `core:`/`vendor:`/`base:` imports can be located. The
// ODIN_ROOT environment variable wins when set (lets a user point at a different
// toolchain); otherwise fall back to the compiler's own root, baked in at build
// time as the `ODIN_ROOT` constant — this is what makes the standard library
// resolve out of the box, with no environment set up.
@(private)
odin_root :: proc() -> string {
    if v, found := os.lookup_env("ODIN_ROOT", context.temp_allocator); found && v != "" {
        return v
    }
    return ODIN_ROOT
}
