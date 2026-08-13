// The request entry point and lexical scope resolution: parse the buffer,
// classify what the caret sits on, and answer from the innermost visible
// declaration, widening to the package directory and then the workspace.
package odin

import "core:os"
import "core:strings"
import "core:sync"

import lang ".."
import "../../treecache"
import ts "../../vendor/odin-tree-sitter"

// How far a top-level declaration reaches, set by its visibility attribute. A
// local carries `.Public`, which costs nothing: nothing outside its own scope
// sees it in any case.
@(private)
Visibility :: enum u8 {
    Public,  // no attribute: the whole workspace, through an import
    Package, // `@(private)` / `@(private = "package")`: the declaring directory
    File,    // `@(private = "file")`: the declaring file alone
}

// A declaration found in a parsed tree: the identifier being declared, the byte
// range of the scope it is visible in, and the enclosing declaration node used
// for hover text.
@(private)
Def :: struct {
    name:         string, // slice into the parsed source
    ident_start:  int,
    ident_end:    int,
    kind:         string, // LOCALS capture suffix: "function", "type", "var", ...
    scope_start:  int,
    scope_end:    int,
    visible_from: int, // order-dependent local: first offset past its declaration
    top_level:    bool, // no enclosing block: visible across the whole file/package
    decl_start:   int,
    decl_end:     int,
    visibility:   Visibility, // top-level only; a local is always .Public
    // `sizes :: proc{sized_a, sized_b}` — a procedure group, not a procedure. It
    // declares no parameters of its own, so anything that shows a signature has
    // to show the members instead; the brace opens that list rather than a body.
    overload:     bool,
}

// Whether a declaration of `vis` can be named from *another* file — one beside
// it in its package when `same_package`, one in an importing package otherwise.
// The question every cross-file scan asks, and the only place visibility is
// interpreted: a file-private declaration reaches no other file at all, and a
// package-private one only its own directory. A declaration's own file never
// asks, since lexical resolution answers there first.
@(private)
def_reaches :: proc(vis: Visibility, same_package: bool) -> bool {
    switch vis {
    case .Public:
        return true
    case .Package:
        return same_package
    case .File:
        return false
    }
    return true
}

@(private)
resolve :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {
    e := cast(^Engine) data
    // Superseded before the worker even got scheduled — common for the
    // per-keystroke kinds, where the thread often starts after the next edit.
    if lang.request_cancelled(req) {
        return
    }

    // Diagnostics ask the compiler about the package on disk: no caret, no
    // LOCALS query, and no buffer snapshot to key the tree cache on — it carries
    // none, so parsing here would evict this path's resident tree for an empty
    // one. It answers before any of the parse setup below.
    if req.kind == .Diagnostics {
        check_package(e, req, res)
        return
    }

    // Formatting parses with core:odin/parser, not the tree-sitter grammar:
    // no caret, no LOCALS query, and no resident tree to key off — like
    // Diagnostics, it answers before any of the tree-sitter setup below, so
    // it never evicts this path's cached tree for a parse it doesn't need.
    #partial switch req.kind {
    case .Format:
        format_document(e, req, res, 0, len(req.source))
        return
    case .Format_Range:
        format_document(e, req, res, req.offset, req.end)
        return
    case .Format_On_Type:
        lo, hi := line_bounds(req.source, req.offset)
        format_document(e, req, res, lo, hi)
        return
    }

    if e.locals == nil {
        return
    }

    // One parser per call (parsers are not shareable across threads); reused for
    // the request buffer and every workspace file the cross-file scan visits.
    parser := ts.parser_new()
    defer ts.parser_delete(parser)
    ts.parser_set_language(parser, e.language)

    // The request buffer is parsed incrementally off the resident tree for this
    // path; the workspace files the cross-file scans visit are stat-gated
    // instead and parsed whole.
    tree := treecache.for_source(&e.trees, parser, req.path, "odin", req.source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)
    root := ts.tree_root_node(tree)

    // Respect the workspace's ols.json feature toggles: a disabled feature
    // answers nothing (hover / document symbols / references have OLS gates; the
    // other kinds are always on).
    if !config_allows(e, req.workspace, req.kind) {
        return
    }

    // Document symbols need no caret: enumerate the whole file and return.
    if req.kind == .Document_Symbols {
        collect_document_symbols(e, root, req.source, req.path, res)
        return
    }

    // Semantic tokens classify the whole buffer rather than one caret position,
    // so like document symbols they answer straight off the tree.
    if req.kind == .Semantic_Tokens {
        semantic_tokens(e, parser, root, req, res)
        return
    }

    // Workspace symbols enumerate every top-level declaration across the tree,
    // starting from the live buffer (unsaved edits) then every sibling file.
    if req.kind == .Workspace_Symbols {
        collect_workspace_symbols(e, parser, root, req, res)
        return
    }

    // References need the identifier under the caret, but not the import/selector
    // resolution the goto flow runs — they gather every occurrence of the name.
    if req.kind == .References {
        collect_references(e, parser, root, req, res)
        return
    }

    // Rename reuses that same occurrence scan and turns each hit into an edit,
    // so it shares references' reach and its caret handling.
    if req.kind == .Rename {
        rename(e, parser, root, req, res)
        return
    }

    // Signature help works off the caret's position inside a call's argument
    // list, not an identifier under it, so it resolves the call before the
    // identifier/import goto logic below.
    if req.kind == .Signature_Help {
        signature_help(e, parser, root, req, res)
        return
    }

    // Completion works off the partial word before the caret (which may not yet
    // parse to an identifier), so it runs before the identifier/import goto logic.
    if req.kind == .Completion {
        complete(e, parser, root, req, res)
        return
    }

    // Code actions offer fixes at the caret rather than resolving what sits under
    // it, so they run their own producers instead of the goto logic below.
    if req.kind == .Code_Actions {
        code_actions(e, parser, root, req, res)
        return
    }

    // Package docs render a whole package, resolved from the caret (an import,
    // a `pkg.lang.Symbol` operand, a bare package name) or, failing that, the file's
    // own package. Its own resolution, so it runs before the goto logic below.
    if req.kind == .Package_Doc {
        package_doc(e, parser, root, req, res)
        return
    }

    // Caret on an import declaration itself (its alias or its quoted path):
    // resolve to the imported package. Handled before identifier_at because the
    // path string is not an identifier, so a caret resting on it would otherwise
    // fail outright.
    if imp, in_import := enclosing_import(root, req.source, req.offset); in_import {
        if raw, rok := import_string(imp, req.source); rok {
            if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                anchor_start := int(ts.node_start_byte(imp))
                anchor_end := int(ts.node_end_byte(imp))
                open_package(dir, raw, req, res, anchor_start, anchor_end)
            }
        }
        return
    }

    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        // Hover only: the caret sits on an operator, a cast's parens or
        // `or_else`'s keyword — nothing identifier_at reaches. Falls back to a
        // computed-type hover for the smallest enclosing expression
        // infer_expr_result can type; a bare identifier always resolves above
        // instead, since identifier_at succeeding is what skips this entirely.
        if req.kind == .Hover {
            hover_expr(e, parser, root, req, res)
        }
        return
    }
    name := ts.node_text(ident, req.source)
    hover_start := int(ts.node_start_byte(ident))
    hover_end := int(ts.node_end_byte(ident))
    // The call the caret's name heads, if it heads one. Only a procedure group
    // reads it: its members differ by what they take, so the arguments already
    // written are what chooses between them.
    call := caret_call_site(root, ident)

    // 0) Selector `operand.member`. Two resolutions, in order:
    //    a) Package-qualified `pkg.lang.Symbol`: when the operand names an imported
    //       package, the symbol lives in that package's directory, so resolve
    //       there and never fall through to the flat scan (which ignores package
    //       boundaries and could match a same-named symbol elsewhere).
    //    b) Value member `value.field`: infer the operand's static type and
    //       resolve the field in that struct (see resolve_member).
    if op_node, member_ident, is_sel := selector_parts(ident); is_sel {
        caret_on_member := same_node(ident, member_ident)
        if is_identifier(op_node) {
            pkg := ts.node_text(op_node, req.source)
            if raw, found := import_path(root, req.source, pkg); found {
                if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                    if caret_on_member {
                        scan_package(e, parser, dir, req, name, hover_start, hover_end, call, res)
                    } else {
                        open_package(dir, raw, req, res, hover_start, hover_end)
                    }
                }
                return
            }
        }
        // Value member access, only with the caret on the member. Falls through
        // to the flat scan when the type can't be inferred (no struct in reach).
        if caret_on_member && resolve_member(e, parser, root, req, op_node, name, hover_start, hover_end, res) {
            return
        }
    }

    // 1) Same file: lexical resolution via the LOCALS query.
    defs := collect_defs(e, root, req.source)
    d, found := resolve_local(defs[:], name, req.offset)

    // 1b) A field a `using` opened into this scope, named bare. A binding keeps
    //     its own declaration, but a field matched on name alone does not: it
    //     belongs to whichever struct declared it, while the `using` names the
    //     one that is open here.
    if !found || d.kind == "field" {
        if resolve_using_member(e, parser, root, req, name, hover_start, hover_end, res) {
            return
        }
    }

    if found {
        // A procedure group names other procedures instead of declaring a body,
        // so a jump to it lands one hop short of the code that was asked for.
        if req.kind == .Definition && d.overload &&
           overload_definitions(e, parser, root, req, req.source, req.path, d, call, res) {
            return
        }
        fill_result(res, req, req.path, req.source, d, hover_start, hover_end)
        return
    }

    // 2) Workspace: scan sibling files for a matching top-level declaration.
    //    Hover wants the first hit; go-to-definition gathers every match so an
    //    ambiguous name (declared in several packages) offers a picker.
    if req.workspace != "" {
        if req.kind == .Definition {
            resolve_definition_workspace(e, parser, root, req, name, call, res)
        } else {
            scan_workspace(e, parser, req, name, hover_start, hover_end, call, res)
        }
    }

    // 3) The implicit scope: `len`, `append`, `make` and the rest of what the
    //    toolchain declares into every file with no import. Last, so a package
    //    declaring a name of its own shadows the builtin, as the compiler has it.
    if !res.ok {
        resolve_builtin(e, parser, req, name, hover_start, hover_end, call, res)
    }
}

// Smallest identifier node covering `offset`, also probing offset-1 so a caret
// resting just after an identifier still resolves it.
@(private)
identifier_at :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    if n := ts.node_named_descendant_for_byte_range(root, off, off); is_identifier(n) {
        return n, true
    }
    if offset > 0 {
        p := off - 1
        if n := ts.node_named_descendant_for_byte_range(root, p, p); is_identifier(n) {
            return n, true
        }
    }
    return {}, false
}

// A computed-type hover for the smallest expression around `req.offset` that
// infer_expr_result can type, once identifier_at has already failed — so this
// only ever fires on an operator, a cast's parens or `or_else`'s keyword, never
// on a bare identifier (which resolves through the declaration-text path
// above instead). Renders with type_ref_text rather than a declaration slice,
// since there is no single declaration an expression like `a + b` stands for.
@(private)
hover_expr :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    expr, eok := hoverable_expr_at(root, req.source, req.offset)
    if !eok {
        return
    }
    tr, tok := infer_expr_result(e, parser, root, req, expr, 0, 0)
    if !tok {
        return
    }
    res.hover = lang.Hover_Info {
        text  = strings.clone(type_ref_text(tr)),
        start = int(ts.node_start_byte(expr)),
        end   = int(ts.node_end_byte(expr)),
    }
    res.ok = true
}

// Smallest node covering `offset` (also probing offset-1, matching
// identifier_at) whose type is one infer_expr_result has a case for, climbing
// out of narrower wrappers the same way selector_subject does for a different
// consumer. `or_else` needs no case of its own here — ts-probe confirmed it
// parses as a binary_expression, with `or_else` as the operator token.
@(private)
hoverable_expr_at :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    n := ts.node_named_descendant_for_byte_range(root, off, off)
    if ts.node_is_null(n) && offset > 0 {
        p := off - 1
        n = ts.node_named_descendant_for_byte_range(root, p, p)
    }
    for !ts.node_is_null(n) {
        switch string(ts.node_type(n)) {
        case "binary_expression", "in_expression", "cast_expression",
             "call_expression", "member_expression", "index_expression",
             "slice_expression", "unary_expression":
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Nearest import_declaration enclosing `offset`, so a caret anywhere on an
// import line (its alias identifier or its quoted path) resolves to the package.
@(private)
enclosing_import :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    n := ts.node_named_descendant_for_byte_range(root, off, off)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == "import_declaration" {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

@(private)
is_identifier :: proc(n: ts.Node) -> bool {
    return !ts.node_is_null(n) && string(ts.node_type(n)) == "identifier"
}

// Runs the LOCALS query over `root` and records every @definition.* capture with
// the scope it is visible in.
@(private)
collect_defs :: proc(e: ^Engine, root: ts.Node, source: string) -> [dynamic]Def {
    defs := make([dynamic]Def, context.temp_allocator)

    cursor := ts.query_cursor_new()
    defer ts.query_cursor_delete(cursor)
    ts.query_cursor_exec(cursor, e.locals, root)

    for match in ts.query_cursor_next_match(cursor) {
        for i in 0 ..< int(match.capture_count) {
            c := match.captures[i]
            cname := ts.query_capture_name_for_id(e.locals, c.index)
            if !strings.has_prefix(cname, "definition") {
                continue
            }

            ident := c.node
            d: Def
            d.name = ts.node_text(ident, source)
            d.ident_start = int(ts.node_start_byte(ident))
            d.ident_end = int(ts.node_end_byte(ident))
            d.kind = strings.has_prefix(cname, "definition.") ? cname[len("definition."):] : ""
            d.scope_start = 0
            d.scope_end = len(source)

            // Scope: a parameter is visible in its whole procedure; anything
            // else in its enclosing block or control-flow statement, and when it
            // has neither it is top-level and visible file-wide (procs, structs,
            // enums, package-level consts).
            if d.kind == "parameter" {
                if pd, has := ancestor_type(ident, "procedure_declaration"); has {
                    d.scope_start = int(ts.node_start_byte(pd))
                    d.scope_end = int(ts.node_end_byte(pd))
                } else {
                    d.top_level = true
                }
            } else {
                scope_def(&d, ident)
            }

            if decl, has := ancestor_suffix(ident, "_declaration"); has {
                d.decl_start = int(ts.node_start_byte(decl))
                d.decl_end = int(ts.node_end_byte(decl))
                if d.top_level {
                    d.visibility = decl_visibility(decl, source)
                }
            } else {
                d.decl_start = d.ident_start
                d.decl_end = d.ident_end
            }

            // A local variable is the one order-dependent capture: `::` consts,
            // types and procedures are visible throughout their scope, a `:=`
            // only past its own declaration.
            if d.kind == "var" && !d.top_level {
                d.visible_from = d.decl_end
            }

            append(&defs, d)
        }
    }

    // The vendored LOCALS query captures none of the value declarations this
    // grammar actually produces, so they are collected directly.
    collect_value_decls(root, source, &defs)
    return defs
}

// The scope a declaration at `node` lives in: the nearest enclosing block, or
// the control-flow statement itself when the declaration is one of its clauses
// (`if v, ok := m[k]; ok`, `for i := 0; i < n; i += 1`) — those bindings die
// with the statement instead of leaking into the surrounding block.
@(private)
enclosing_scope :: proc(node: ts.Node) -> (ts.Node, bool) {
    n := ts.node_parent(node)
    for !ts.node_is_null(n) {
        switch string(ts.node_type(n)) {
        case "block", "if_statement", "for_statement", "switch_statement", "when_statement":
            if !file_scope_when(n) {
                return n, true
            }
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Whether `n` is a scope node belonging to a `when` written at file scope. Such
// a `when` declares into the package rather than into a scope of its own —
// base:runtime wraps `delete_key` and the rest of the map builtins in
// `when MAP_ENABLED`, and they are package-level all the same.
@(private)
file_scope_when :: proc(n: ts.Node) -> bool {
    w := n
    for !ts.node_is_null(w) {
        switch string(ts.node_type(w)) {
        case "block", "when_statement":
            w = ts.node_parent(w)
            continue
        case "source_file":
            return true
        }
        return false
    }
    return false
}

// Fills `d`'s visible range from the scope enclosing `node`, marking it
// top-level when there is none.
@(private)
scope_def :: proc(d: ^Def, node: ts.Node) {
    if scope, has := enclosing_scope(node); has {
        d.scope_start = int(ts.node_start_byte(scope))
        d.scope_end = int(ts.node_end_byte(scope))
    } else {
        d.top_level = true
    }
}

// Adds the value declarations the LOCALS query misses: `name := value` short
// declarations (this grammar parses them as an `assignment_statement`, not the
// `variable_declaration` the query looks for), typed `name: T = value`
// declarations, and `for name in expr` loop variables.
@(private)
collect_value_decls :: proc(node: ts.Node, source: string, defs: ^[dynamic]Def) {
    switch string(ts.node_type(node)) {
    case "assignment_statement":
        // Walk the leading children: identifiers (and commas for `a, b := ...`)
        // up to the operator. A `:=` there makes those identifiers definitions;
        // a plain `=` reassignment declares nothing.
        lead := make([dynamic]ts.Node, context.temp_allocator)
        is_decl := false
        scan: for i in 0 ..< ts.node_child_count(node) {
            c := ts.node_child(node, i)
            switch string(ts.node_type(c)) {
            case "identifier":
                append(&lead, c)
                continue
            case ",":
                continue
            case ":=":
                is_decl = true
            }
            break scan
        }
        if is_decl {
            for ident in lead {
                append_value_def(defs, ident, node, source, ordered = true)
            }
        }
    case "var_declaration":
        // `a, b: T = x, y` — the names precede the `(type ...)` child, mirroring
        // named_decl_type. A file-scope one is a package variable, which is
        // order-independent and shows up in the symbol list.
        for i in 0 ..< ts.node_named_child_count(node) {
            c := ts.node_named_child(node, i)
            if !is_identifier(c) {
                break // the type: everything past it is the initializer
            }
            append_value_def(defs, c, node, source, ordered = true)
        }
    case "for_statement":
        // A range loop's variables (`for k, v in m`) are bare identifier
        // children before `in`; the three-clause form has an initializer
        // statement there instead, which the assignment_statement case covers.
        // A by-reference variable (`for &cursor in cursors`) arrives wrapped in
        // the `&`, and declares the name just the same.
        for i in 0 ..< ts.node_child_count(node) {
            c := ts.node_child(node, i)
            if string(ts.node_type(c)) == "in" {
                break
            }
            if string(ts.node_type(c)) == "unary_expression" {
                c = ts.node_named_child(c, 0)
            }
            if is_identifier(c) {
                append_value_def(defs, c, node, source, ordered = false)
            }
        }
    case "switch_statement":
        // `switch v in u` declares `v`, which the LOCALS query captures nowhere.
        // It is seen by the whole switch, like a loop variable.
        if ident, _, ok := type_switch_parts(node); ok {
            append_value_def(defs, ident, node, source, ordered = false)
        }
    case "overloaded_procedure_declaration":
        // `make :: proc{make_slice, make_map}` — its own node type, which the
        // LOCALS query has no rule for, so the group's name would go undeclared
        // while the procedures it gathers are declared normally. The first
        // identifier is the group; the rest are references to its members. An
        // `@(builtin)` in front puts an `attributes` child before it, so the
        // first *identifier* is the name rather than the first named child.
        for i in 0 ..< ts.node_named_child_count(node) {
            c := ts.node_named_child(node, i)
            if !is_identifier(c) {
                continue
            }
            d := Def {
                name        = ts.node_text(c, source),
                ident_start = int(ts.node_start_byte(c)),
                ident_end   = int(ts.node_end_byte(c)),
                kind        = "function",
                decl_start  = int(ts.node_start_byte(node)),
                decl_end    = int(ts.node_end_byte(node)),
                overload    = true,
            }
            scope_def(&d, c)
            if d.top_level {
                d.visibility = decl_visibility(node, source)
            }
            append(defs, d)
            break
        }
    case "named_type":
        // `-> (track, thumb: rl.Rectangle, ok: bool)` — a procedure's named
        // results, which the LOCALS query has no rule for either. Like the
        // parameters they sit beside, the names precede the `(type ...)` child
        // and are visible throughout the procedure: assignable in its body and
        // returnable bare. A real one always sits inside the parens of a
        // `tuple_type` — a bare, unparenthesized `-> T,` immediately followed by
        // more `name: type` fields parses as this same node with no parens
        // around it, a grammar ambiguity that would otherwise leak the next
        // struct field's name (and its own return type) as fake top-level
        // definitions.
        if pt := ts.node_parent(node); !ts.node_is_null(pt) && string(ts.node_type(pt)) == "tuple_type" {
            for i in 0 ..< ts.node_named_child_count(node) {
                c := ts.node_named_child(node, i)
                if !is_identifier(c) {
                    break // the type: everything past it belongs to it
                }
                append_result_def(defs, c, node, source)
            }
        }
    }

    for i in 0 ..< ts.node_child_count(node) {
        collect_value_decls(ts.node_child(node, i), source, defs)
    }
}

// Records `ident` as a variable declared by `decl`. An `ordered` declaration is
// order-dependent — visible only past the declaration it sits in, so a use
// above it still binds whatever it shadows — while a loop variable is seen by
// its whole loop.
@(private)
append_value_def :: proc(defs: ^[dynamic]Def, ident, decl: ts.Node, source: string, ordered: bool) {
    d := Def {
        name        = ts.node_text(ident, source),
        ident_start = int(ts.node_start_byte(ident)),
        ident_end   = int(ts.node_end_byte(ident)),
        kind        = "var",
        decl_start  = int(ts.node_start_byte(decl)),
        decl_end    = int(ts.node_end_byte(decl)),
    }
    scope_def(&d, ident)
    if ordered && !d.top_level {
        d.visible_from = d.decl_end
    }
    if d.top_level {
        d.visibility = decl_visibility(decl, source)
    }
    append(defs, d)
}

// Records `ident` as one of `decl`'s named results, scoped the way collect_defs
// scopes a parameter: over the whole procedure, since the body both assigns to
// it and returns it.
@(private)
append_result_def :: proc(defs: ^[dynamic]Def, ident, decl: ts.Node, source: string) {
    d := Def {
        name        = ts.node_text(ident, source),
        ident_start = int(ts.node_start_byte(ident)),
        ident_end   = int(ts.node_end_byte(ident)),
        kind        = "parameter",
        decl_start  = int(ts.node_start_byte(decl)),
        decl_end    = int(ts.node_end_byte(decl)),
        scope_end   = len(source),
    }
    if pd, has := ancestor_type(ident, "procedure_declaration"); has {
        d.scope_start = int(ts.node_start_byte(pd))
        d.scope_end = int(ts.node_end_byte(pd))
    } else {
        d.top_level = true // a bare procedure type: nothing to scope it to
    }
    append(defs, d)
}

// Whether `d` can be named at `offset`: a file-scope declaration anywhere in the
// file, a local only inside its scope and — when order-dependent — only past its
// own declaration. Its declaring identifier always qualifies, so go-to-definition
// and find-usages on the declaration itself still find it.
@(private)
def_visible_at :: proc(d: Def, offset: int) -> bool {
    if d.top_level {
        return true
    }
    if offset < d.scope_start || offset > d.scope_end {
        return false
    }
    return offset >= d.visible_from || (offset >= d.ident_start && offset <= d.ident_end)
}

// Picks the visible declaration of `name` nearest `offset`: a local shadows a
// file-scope symbol, an inner block shadows an outer, and the last declaration
// before the use shadows the ones above it.
@(private)
resolve_local :: proc(defs: []Def, name: string, offset: int) -> (Def, bool) {
    best: Def
    found := false
    for d in defs {
        if d.name != name || !def_visible_at(d, offset) {
            continue
        }
        if !found || def_better(d, best, offset) {
            best = d
            found = true
        }
    }
    return best, found
}

@(private)
def_better :: proc(a, b: Def, offset: int) -> bool {
    // The caret on a declared name resolves to that very declaration.
    a_self := offset >= a.ident_start && offset <= a.ident_end
    if a_self != (offset >= b.ident_start && offset <= b.ident_end) {
        return a_self
    }
    if a.top_level != b.top_level {
        return !a.top_level // a local shadows a file-scope symbol
    }
    if !a.top_level {
        aw := a.scope_end - a.scope_start
        bw := b.scope_end - b.scope_start
        if aw != bw {
            return aw < bw // the tighter (inner) scope wins
        }
        if a.visible_from != b.visible_from {
            return a.visible_from > b.visible_from // within a scope, the latest one
        }
    }
    return abs(a.ident_start - offset) < abs(b.ident_start - offset)
}

// Finds the file declaring `name` via the symbol index, then re-parses just that
// one file to fill `res` (hover wants the full declaration text, which the index
// doesn't keep). The live buffer (req.path) was already searched with its unsaved
// edits, so it is excluded. Package first, then the whole workspace — the same
// two-phase reach go-to-definition uses, explained at index_package_dir. Syncs
// the index under its mutex first.
@(private)
scan_workspace :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    name: string,
    hover_start, hover_end: int,
    call: Call_Site,
    res: ^lang.Result,
) {
    path, ok := "", false
    same_package := true
    sync.lock(&e.index.mutex)
    index_sync(e, parser, req)
    p, found := index_first_path(e, name, req.path, "", index_package_dir(e, req.path), true)
    if !found {
        p, found = index_first_path(e, name, req.path, "", "", false)
        same_package = false
    }
    if found {
        path = strings.clone(p, context.temp_allocator) // survives the unlock
        ok = true
    }
    sync.unlock(&e.index.mutex)

    if ok {
        scan_file(e, parser, path, req, name, hover_start, hover_end, call, same_package, res)
    }
}

// `same_package` says whether `path` sits beside the requesting file, which is
// what decides if a `@(private)` declaration there is in reach.
@(private)
scan_file :: proc(
    e: ^Engine,
    parser: ts.Parser,
    path: string,
    req: ^lang.Request,
    name: string,
    hover_start, hover_end: int,
    call: Call_Site,
    same_package: bool,
    res: ^lang.Result,
) {
    source, sok := source_read(path)
    if !sok {
        return
    }

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)

    defs := collect_defs(e, ts.tree_root_node(tree), source)
    for d in defs {
        if d.top_level && d.name == name && def_reaches(d.visibility, same_package) {
            // A group reached through `pkg.sizes`: its members live in that same
            // package, so the live buffer has nothing to add and no root is
            // passed. Definition only — hover shows the group's member list, and
            // that is already what it should say.
            if req.kind == .Definition && d.overload &&
               overload_definitions(e, parser, {}, req, source, path, d, call, res) {
                return
            }
            fill_result(res, req, path, source, d, hover_start, hover_end)
            return
        }
    }
}

// Go-to-definition's cross-file scan. Gathers the top-level declarations named
// `name` into res.symbols; unlike scan_workspace (first hit wins, used by hover)
// it never stops early within a scope, since a name can be declared more than
// once and the user should choose. A single hit collapses back to res.location
// (the direct-jump path the caller already handles); two or more stay as
// candidates for a picker. The scope is the requesting file's own package first
// and the whole workspace only after — see index_package_dir.
@(private)
resolve_definition_workspace :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    name: string,
    call: Call_Site,
    res: ^lang.Result,
) {
    sync.lock(&e.index.mutex)
    index_sync(e, parser, req)
    group := index_find_defs(e, name, req.path, index_package_dir(e, req.path), true, res)
    if len(res.symbols) == 0 {
        group = index_find_defs(e, name, req.path, "", false, res)
    }
    sync.unlock(&e.index.mutex)
    switch len(res.symbols) {
    case 0:
        // Unresolved: res.ok stays false so the caller reports "no definition".
    case 1:
        // The one match is a procedure group: reach through to its members, the
        // same as the same-file path does.
        if group && expand_index_group(e, parser, root, req, name, call, res) {
            return
        }
        // Single definition: collapse to the location a direct jump uses, moving
        // the (Manager-owned) path into it and freeing the row's other strings.
        sym := res.symbols[0]
        res.location = lang.Location{path = sym.path, start = sym.offset, end = sym.offset + len(sym.name)}
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(res.symbols)
        res.symbols = nil
        res.ok = true
    case:
        // Ambiguous: leave the candidates in res.symbols for the picker.
        res.ok = true
    }
}

// Replaces a lone indexed procedure-group match with its members. The index
// records that a declaration is a group but not what it gathers — only its
// signature line — so the file it points at is re-parsed for the group's Def and
// the members are resolved from there. Reports false when that file no longer
// declares the group (the index had gone stale) or no member resolves, leaving
// the group itself to answer.
@(private = "file")
expand_index_group :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    name: string,
    call: Call_Site,
    res: ^lang.Result,
) -> bool {
    sym := res.symbols[0]
    // The row is one index_find_defs already judged in reach, so this re-parse
    // only has to find it again.
    src, path, d, ok := first_proc_in_file(e, parser, sym.path, name, true)
    if !ok || !d.overload {
        return false
    }

    // Built aside so a group whose members all fail to resolve leaves res as it
    // found it, with the group row still standing.
    members := lang.Result{kind = .Definition}
    if !overload_definitions(e, parser, root, req, src, path, d, call, &members) {
        return false
    }

    delete(sym.name)
    delete(sym.kind)
    delete(sym.signature)
    delete(sym.path)
    delete(res.symbols)
    res.symbols = members.symbols
    res.location = members.location
    res.ok = true
    return true
}
