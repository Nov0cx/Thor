// Completion, including the expected-type inference that lets a leading `.`
// offer an enum's members.
package odin

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// The type expected at `offset` — the `.` of an implicit selector — so the enum
// it selects from can be found. A lone `.` is not an expression, so the tree the
// request carries is derailed in exactly the spot that matters; when the walk
// over it comes up empty the file is re-parsed with a filler identifier spliced
// in after the dot, which puts the selector back into a well-formed expression.
// The splice only adds bytes after the dot and every name the walk reads lies
// before it, so both parses see the same text where it counts.
@(private)
expected_type_at :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    offset: int,
) -> (Type_Ref, bool) {
    if tr, ok := expected_type_in_tree(e, parser, root, req, offset); ok {
        return tr, true
    }
    src := req.source
    at := clamp(offset + 1, 0, len(src))
    repaired := strings.concatenate({src[:at], SELECTOR_FILLER, src[at:]}, context.temp_allocator)
    tree := ts.parser_parse_string(parser, repaired)
    defer ts.tree_delete(tree)
    fixed := req^
    fixed.source = repaired
    // The Type_Ref slices `repaired`, which outlives the request; visit_type_decl
    // matches it by name, so it never touches this tree again.
    return expected_type_in_tree(e, parser, ts.tree_root_node(tree), &fixed, offset)
}

// Identifier spliced in after a bare `.` to make the surrounding expression parse.
@(private)
SELECTOR_FILLER :: "_"

// expected_type_at over one parse: walks up from the dot to the nearest construct
// that pins the type down — a `var_declaration`'s annotated type, the left-hand
// variable of an `assignment_statement`, the named field of a composite literal,
// the parameter a call argument fills, the other side of a comparison, the value
// a `switch` is over, or the enclosing procedure's result. The innermost one wins,
// so `f(P{axis = .})` answers with the field's type, not the parameter's.
@(private)
expected_type_in_tree :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    offset: int,
) -> (Type_Ref, bool) {
    source := req.source
    off := u32(clamp(offset, 0, len(source)))
    n := ts.node_named_descendant_for_byte_range(root, off, off)
    for !ts.node_is_null(n) {
        switch string(ts.node_type(n)) {
        case "var_declaration":
            for i in 0 ..< ts.node_named_child_count(n) {
                c := ts.node_named_child(n, i)
                if string(ts.node_type(c)) == "type" {
                    return type_ref_from_node(c, source)
                }
            }
            return {}, false
        case "assignment_statement":
            lhs := ts.node_named_child(n, 0)
            if is_identifier(lhs) {
                return binding_type_ref(e, parser, root, req, ts.node_text(lhs, source), int(ts.node_start_byte(lhs)))
            }
            return {}, false
        case "struct_field":
            // `Point{axis = .}` — the literal names its struct, the struct names
            // the field's type. A positional field carries no name to look up.
            name := ts.node_named_child(n, 0)
            lit := ts.node_parent(n)
            if !is_identifier(name) || ts.node_is_null(lit) {
                return {}, false
            }
            tr, ok := composite_type_name(lit, source)
            if !ok {
                return {}, false
            }
            ctx := Member_Ctx {
                field = ts.node_text(name, source),
                env = Embed_Env{e = e, parser = parser, root = root, req = req},
            }
            if !visit_type_decl(e, parser, root, req, tr, "struct_declaration", "type", member_visitor, &ctx) || !ctx.got {
                return {}, false
            }
            return ctx.field_type, true
        case "call_expression":
            // `f(1, .)` — the parameter this argument fills, by position.
            fn := ts.node_child_by_field_name(n, "function")
            if ts.node_is_null(fn) {
                return {}, false
            }
            src, path, d, found := resolve_call_target(e, parser, root, req, n, fn)
            if !found || d.kind != "function" {
                return {}, false
            }
            tr, ok := proc_param_type(src, d, call_active_param(n, offset))
            if !ok {
                return {}, false
            }
            // Spelled in the callee's file, so that file's imports qualify it.
            tr.origin = path
            return tr, true
        case "binary_expression":
            // `dir == .` — the other operand carries the type both sides share.
            other := ts.node_child_by_field_name(n, "left")
            if !ts.node_is_null(other) && int(ts.node_end_byte(other)) > offset {
                other = ts.node_child_by_field_name(n, "right")
            }
            if ts.node_is_null(other) {
                return {}, false
            }
            return infer_expr_type(e, parser, root, req, other)
        case "switch_case":
            // `case .:` — the value being switched over.
            sw := ts.node_parent(n)
            if ts.node_is_null(sw) {
                return {}, false
            }
            cond := ts.node_child_by_field_name(sw, "condition")
            if ts.node_is_null(cond) {
                return {}, false
            }
            return infer_expr_type(e, parser, root, req, cond)
        case "return_statement":
            // `return .` — the enclosing procedure's result, in this slot.
            return enclosing_result_type(n, source, offset)
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// lang.Result type of the procedure a `return` sits in, picking the slot the returned
// expression at `offset` occupies. A parenthesized result list is a `tuple_type`
// whose entries may be named (`-> (a: Axis, ok: bool)`); a lone result is the
// procedure's one `type` child.
@(private)
enclosing_result_type :: proc(ret: ts.Node, source: string, offset: int) -> (Type_Ref, bool) {
    slot := 0
    for i in 0 ..< ts.node_named_child_count(ret) {
        if int(ts.node_end_byte(ts.node_named_child(ret, i))) < offset {
            slot += 1
        }
    }
    proc_node := ts.node_parent(ret)
    for !ts.node_is_null(proc_node) && string(ts.node_type(proc_node)) != "procedure" {
        proc_node = ts.node_parent(proc_node)
    }
    if ts.node_is_null(proc_node) {
        return {}, false
    }
    results: ts.Node
    for i in 0 ..< ts.node_named_child_count(proc_node) {
        c := ts.node_named_child(proc_node, i)
        if string(ts.node_type(c)) == "type" {
            results = c
            break
        }
    }
    if ts.node_is_null(results) {
        return {}, false
    }
    inner := ts.node_named_child(results, 0)
    if !ts.node_is_null(inner) && string(ts.node_type(inner)) == "tuple_type" {
        entry := ts.node_named_child(inner, u32(slot))
        if ts.node_is_null(entry) {
            return {}, false
        }
        if string(ts.node_type(entry)) == "named_type" {
            entry = ts.node_named_child(entry, ts.node_named_child_count(entry) - 1)
        }
        return type_ref_from_node(entry, source)
    }
    if slot != 0 {
        return {}, false
    }
    return type_ref_from_node(results, source)
}

// Trimmed text of a byte range, cloned into context.allocator — a member hover's
// field declaration (`x: int`).
@(private)
declaration_text_range :: proc(source: string, start, end: int) -> string {
    s := clamp(start, 0, len(source))
    e := clamp(end, s, len(source))
    return strings.clone(strings.trim_space(source[s:e]))
}

// Odin keywords and builtin types offered as completion candidates alongside the
// resolved identifiers.
@(private)
ODIN_KEYWORDS :: [?]string {
    "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context",
    "continue", "defer", "distinct", "do", "dynamic", "else", "enum",
    "fallthrough", "for", "foreign", "if", "import", "in", "map", "matrix",
    "not_in", "or_else", "or_return", "package", "proc", "return", "struct",
    "switch", "transmute", "typeid", "union", "using", "when", "where",
    "bool", "b8", "b16", "b32", "b64",
    "int", "i8", "i16", "i32", "i64", "i128",
    "uint", "u8", "u16", "u32", "u64", "u128", "uintptr",
    "f16", "f32", "f64",
    "complex32", "complex64", "complex128",
    "quaternion64", "quaternion128", "quaternion256",
    "rune", "string", "cstring", "rawptr", "any", "byte",
    "true", "false", "nil",
}

// Bytes that make up an Odin identifier, for finding the partial word the caret
// is completing.
@(private)
is_word_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b >= 0x80
}

// Code completion for the partial identifier before the caret. Two contexts:
// after `pkg.` (the operand names an imported package) it lists that package's
// top-level declarations; otherwise it offers the identifiers in scope — locals
// and parameters visible at the caret, this file's and this package's top-level
// declarations, the imported package names, and the Odin keywords and builtin
// types. All filtered by the typed prefix (case-sensitive) and de-duplicated by
// name. After a `.` it offers the operand's struct fields instead, inferring the
// operand's type the same way member access does — the operand being whatever
// expression ends at the dot, not just the word before it.
@(private)
complete :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    src := req.source
    off := clamp(req.offset, 0, len(src))

    // The partial word being completed: the run of identifier bytes before the caret.
    start := off
    for start > 0 && is_word_byte(src[start - 1]) {
        start -= 1
    }
    prefix := src[start:off]

    // A `.` before the typed word is a selector: either on an operand (a package
    // or a value) or on nothing at all (an implicit enum selector).
    if start > 0 && src[start - 1] == '.' {
        dot := start - 1
        before := dot > 0 ? src[dot - 1] : 0 // the char just before the dot
        if is_word_byte(before) || before == ')' || before == ']' {
            complete_selector(e, parser, root, req, dot, prefix, res)
        } else if tr, tok := expected_type_at(e, parser, root, req, dot); tok {
            // Leading `.<prefix>` with no operand: an implicit enum selector
            // (`x: Axis = .`). If the expected type is an enum, offer its members.
            seen := make(map[string]bool, 0, context.temp_allocator)
            ctx := Enum_Ctx{prefix = prefix, res = res, seen = &seen}
            visit_type_decl(e, parser, root, req, tr, "enum_declaration", "enum", enum_visitor, &ctx)
        }
        finish_completion(res)
        return
    }

    seen := make(map[string]bool, 0, context.temp_allocator)

    // In-scope locals and parameters, plus this file's top-level declarations
    // (collect_defs yields both).
    defs := collect_defs(e, root, src)
    for d in defs {
        if !completion_def_ok(d, off) || !completion_matches(d.name, prefix) {
            continue
        }
        add_completion(res, src, d, &seen)
    }

    // This package's sibling files (an Odin package is one flat directory): their
    // top-level declarations are visible here unqualified.
    if req.path != "" {
        complete_dir_toplevel(e, parser, req, filepath.dir(req.path), prefix, req.path, res, &seen)
    }

    // Imported package names are completable identifiers too (`widgets`, `fmt`) —
    // the operand you then qualify with `.` — though they're not declarations
    // collect_defs yields.
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        if name, _, iok := import_name_and_path(child, src); iok && completion_matches(name, prefix) && name not_in seen {
            seen[name] = true
            append(&res.symbols, lang.Symbol {
                name      = strings.clone(name),
                kind      = strings.clone("namespace"),
                signature = strings.clone(name),
            })
        }
    }

    // Keywords and builtin types.
    for kw in ODIN_KEYWORDS {
        if completion_matches(kw, prefix) && kw not_in seen {
            seen[kw] = true
            append(&res.symbols, lang.Symbol {
                name      = strings.clone(kw),
                kind      = strings.clone("keyword"),
                signature = strings.clone(kw),
            })
        }
    }

    finish_completion(res)
}

// Candidates for `operand.<prefix>`, where `dot` is the selector's `.`. A bare
// operand naming an imported package lists that package's top-level symbols;
// anything else is a value, and its struct fields are offered.
@(private)
complete_selector :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    dot: int,
    prefix: string,
    res: ^lang.Result,
) {
    src := req.source
    word := dot
    for word > 0 && is_word_byte(src[word - 1]) {
        word -= 1
    }
    // A word preceded by another `.` is a field, never a package name.
    if word < dot && (word == 0 || src[word - 1] != '.') {
        if raw, found := import_path(root, src, src[word:dot]); found {
            if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                seen := make(map[string]bool, 0, context.temp_allocator)
                complete_dir_toplevel(e, parser, req, dir, prefix, "", res, &seen)
            }
            return
        }
    }
    tr, tok := operand_type_at(e, parser, root, req, dot)
    if !tok {
        return
    }
    seen := make(map[string]bool, 0, context.temp_allocator)
    ctx := Fields_Ctx {
        prefix = prefix,
        env    = Embed_Env{e = e, parser = parser, root = root, req = req},
        res    = res,
        seen   = &seen,
    }
    visit_type_decl(e, parser, root, req, tr, "struct_declaration", "type", fields_visitor, &ctx)
}

// Type of the expression left of the `.` at `dot`. A dot with a name after it is
// already a well-formed selector and is read off the tree the request carries. A
// dangling one is not: the grammar reaches past the line end for the member it is
// missing, which glues the next statement onto the selector and leaves no node
// spelling the operand alone. That case is repaired first, with the same filler
// identifier an implicit selector uses.
@(private)
operand_type_at :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    dot: int,
) -> (Type_Ref, bool) {
    src := req.source
    if dot + 1 < len(src) && is_word_byte(src[dot + 1]) {
        if tr, ok := operand_type_in_tree(e, parser, root, req, dot); ok {
            return tr, true
        }
    }
    at := clamp(dot + 1, 0, len(src))
    repaired := strings.concatenate({src[:at], SELECTOR_FILLER, src[at:]}, context.temp_allocator)
    tree := ts.parser_parse_string(parser, repaired)
    defer ts.tree_delete(tree)
    fixed := req^
    fixed.source = repaired
    // The Type_Ref slices `repaired`, which outlives the request; visit_type_decl
    // matches it by name, so it never touches this tree again.
    return operand_type_in_tree(e, parser, ts.tree_root_node(tree), &fixed, dot)
}

// operand_type_at over one parse. The operand is the *largest* expression ending
// at the dot — `a.b.` selects on the member expression `a.b`, not on `b` — so the
// walk starts at the innermost node covering the byte before the dot and climbs.
// The first climb reaches the dot: the innermost node there can end short of it
// (`xs[0].` lands on the `0`, two levels under the index expression that ends at
// the dot). From there it keeps climbing only while the parent is another
// expression ending in the same place, so it never walks out into the statement.
@(private)
operand_type_in_tree :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    dot: int,
) -> (Type_Ref, bool) {
    if dot <= 0 || dot > len(req.source) {
        return {}, false
    }
    at := u32(dot - 1)
    n := ts.node_named_descendant_for_byte_range(root, at, at)
    for !ts.node_is_null(n) && ts.node_end_byte(n) < u32(dot) {
        n = ts.node_parent(n)
    }
    if ts.node_is_null(n) || ts.node_end_byte(n) != u32(dot) {
        return {}, false
    }
    for {
        p := ts.node_parent(n)
        if ts.node_is_null(p) || ts.node_end_byte(p) != u32(dot) || !is_operand_expr(p) {
            break
        }
        n = p
    }
    return infer_expr_type(e, parser, root, req, n)
}

// Expression shapes infer_expr_type can type, and so the ones worth climbing to
// when looking for a selector's operand. Everything else — a statement, a broken
// parse's ERROR node — ends the climb, so the operand is never widened past the
// expression it belongs to.
@(private)
is_operand_expr :: proc(n: ts.Node) -> bool {
    switch string(ts.node_type(n)) {
    case "member_expression", "index_expression", "slice_expression",
         "call_expression", "unary_expression", "cast_expression", "struct":
        return true
    }
    return false
}

// Whether a declaration belongs in the general completion list: an in-scope
// local or parameter (visible at the caret), or any file-scope declaration.
// Struct fields, the package/import namespace and labels are excluded — a field
// is only reachable through an instance, which needs type inference.
@(private)
completion_def_ok :: proc(d: Def, off: int) -> bool {
    switch d.kind {
    case "field", "namespace", "label", "":
        return false
    }
    return def_visible_at(d, off)
}

// Case-sensitive prefix match; an empty prefix matches everything.
@(private)
completion_matches :: proc(name, prefix: string) -> bool {
    return strings.has_prefix(name, prefix)
}

// Appends a completion candidate for `d`, de-duplicated by name. The label is the
// declaration line for a top-level symbol, or just the name for a local/param.
// Owned strings clone into context.allocator (the Manager's).
@(private)
add_completion :: proc(res: ^lang.Result, source: string, d: Def, seen: ^map[string]bool) {
    if d.name in seen^ {
        return
    }
    seen^[d.name] = true
    label := d.top_level ? signature_text(source, d) : strings.clone(d.name)
    append(&res.symbols, lang.Symbol {
        name      = strings.clone(d.name),
        kind      = strings.clone(d.kind),
        signature = label,
    })
}

// Appends one directory's top-level declarations (its .odin files, non-recursive
// — an Odin package is a flat dir) whose names match `prefix`, skipping `skip`
// (the requesting file, whose live buffer was scanned already).
//
// Served from the resident symbol index when the directory is inside the indexed
// workspace, which is the per-keystroke case: completion fires while typing, and
// re-reading and re-parsing every sibling file for each keystroke was the last
// consumer still doing that. The index sync only re-parses files whose stat moved,
// so a burst of keystrokes costs a readdir walk instead of a package of parses.
// A directory outside the index — a `core:`/`vendor:` package, a collection —
// still reads off disk.
@(private)
complete_dir_toplevel :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    dir, prefix, skip: string,
    res: ^lang.Result,
    seen: ^map[string]bool,
) {
    if req.workspace != "" {
        indexed := false
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        if !lang.request_cancelled(req) {
            indexed = index_dir_completions(e, dir, prefix, skip, res, seen)
        }
        sync.unlock(&e.index.mutex)
        if indexed || lang.request_cancelled(req) {
            return
        }
    }
    complete_dir_scan(e, parser, req, dir, prefix, skip, res, seen)
}

// The off-disk half of complete_dir_toplevel: reads and parses each .odin file in
// `dir`. Used for packages the index doesn't cover.
@(private)
complete_dir_scan :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    dir, prefix, skip: string,
    res: ^lang.Result,
    seen: ^map[string]bool,
) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    for info in infos {
        // The keystroke that asked for these candidates is already stale — the
        // next one has its own request, and this parse would be thrown away.
        if lang.request_cancelled(req) {
            return
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == skip {
            continue
        }
        data, rerr := os.read_entire_file(info.fullpath, context.temp_allocator)
        if rerr != nil {
            continue
        }
        source := string(data)
        tree := ts.parser_parse_string(parser, source)
        if tree == nil {
            continue
        }
        defs := collect_defs(e, ts.tree_root_node(tree), source)
        for d in defs {
            if d.top_level && symbol_kind_shown(d.kind) && completion_matches(d.name, prefix) {
                add_completion(res, source, d, seen)
            }
        }
        ts.tree_delete(tree)
    }
}

// Sorts completion candidates by name for a stable list and flags the result ok
// when any matched.
@(private)
finish_completion :: proc(res: ^lang.Result) {
    slice.sort_by(res.symbols[:], proc(a, b: lang.Symbol) -> bool {
        return a.name < b.name
    })
    res.ok = len(res.symbols) > 0
}

// Byte range, within a signature line, of the `active`-th parameter — used to
// emphasize the argument the caret is on. Splits the first parenthesized group
// (the parameter list; a `-> (a, b)` return tuple comes after and is never
// reached) on top-level commas, tracking bracket depth so a comma inside a nested
// type (`b: proc(x: int)`, `c: [dynamic]int`) doesn't split a parameter. Returns
// an empty range when `active` is past the last parameter.
@(private)
active_param_span :: proc(label: string, active: int) -> (int, int) {
    open := strings.index_byte(label, '(')
    if open < 0 {
        return 0, 0
    }
    depth := 0
    idx := 0
    param_start := open + 1
    for i := open; i < len(label); i += 1 {
        switch label[i] {
        case '(', '[', '{':
            depth += 1
        case ')', ']', '}':
            depth -= 1
            if depth == 0 {
                if idx == active {
                    return trim_span(label, param_start, i)
                }
                return 0, 0
            }
        case ',':
            if depth == 1 {
                if idx == active {
                    return trim_span(label, param_start, i)
                }
                idx += 1
                param_start = i + 1
            }
        }
    }
    return 0, 0
}

// Shrinks [start, end) past leading and trailing ASCII spaces/tabs.
@(private)
trim_span :: proc(label: string, start, end: int) -> (int, int) {
    s, e := start, end
    for s < e && (label[s] == ' ' || label[s] == '\t') {
        s += 1
    }
    for e > s && (label[e - 1] == ' ' || label[e - 1] == '\t') {
        e -= 1
    }
    return s, e
}

// LOCALS capture suffixes that belong in a document outline. Excludes
// "parameter"/"field" (nested), "namespace" (package name and import aliases)
// and "" (labels).
@(private)
symbol_kind_shown :: proc(kind: string) -> bool {
    switch kind {
    case "function", "type", "enum", "constant", "var":
        return true
    }
    return false
}
