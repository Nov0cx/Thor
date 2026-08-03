// Code actions: the fixes offered at the caret, each carrying the edits that
// apply it. Every producer here answers from what the engine already knows — the
// file's import table, its lexical scope, the enum locator behind implicit
// selectors — and none of them writes a file: an action returns Text_Edits and
// the host applies them, so a fix is one undo entry the user can take back.
package odin

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// How deep a collection is searched for a package directory. Two levels covers
// the standard library's nesting (`core:path/filepath`, `core:odin/parser`)
// without walking the whole tree for a name that isn't there.
@(private = "file")
COLLECTION_DEPTH :: 2

// Import paths offered for one unresolved package name. A name that matches in
// several collections is genuinely ambiguous and the user picks, but the list
// stops here rather than growing without bound.
@(private = "file")
IMPORT_CANDIDATE_LIMIT :: 8

// Every fix available at the caret, in the order they are offered: the
// caret-specific ones first, whole-file cleanup last. `res.ok` reports whether
// anything was found, so the host can tell "nothing applies here" from a request
// that never ran.
@(private)
code_actions :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    action_add_import(e, parser, root, req, res)
    action_fill_switch_cases(e, parser, root, req, res)
    action_declare_variable(e, parser, root, req, res)
    action_remove_unused_imports(root, req, res)
    res.ok = len(res.actions) > 0
}

// One replacement a producer wants, before it becomes a Text_Edit: `old_text` is
// not carried because it is always the source under the range, which push_action
// slices for itself.
@(private = "file")
Edit_Spec :: struct {
    start, end: int,
    new_text:   string,
}

// Appends an action whose edits all land in the request file — every producer
// here is single-file. Owned strings clone into context.allocator (the
// Manager's), and each edit records the bytes it matched so the host can verify
// the range before touching a buffer that has moved on.
@(private = "file")
push_action :: proc(res: ^lang.Result, req: ^lang.Request, title, kind: string, specs: ..Edit_Spec) {
    if len(specs) == 0 {
        return
    }
    action := lang.Code_Action {
        title = strings.clone(title),
        kind  = strings.clone(kind),
    }
    for spec in specs {
        start := clamp(spec.start, 0, len(req.source))
        end := clamp(spec.end, start, len(req.source))
        append(&action.edits, lang.Text_Edit {
            path     = strings.clone(req.path),
            start    = start,
            end      = end,
            old_text = strings.clone(req.source[start:end]),
            new_text = strings.clone(spec.new_text),
        })
    }
    append(&res.actions, action)
}

// ---------------------------------------------------------------------------
// Add missing import
// ---------------------------------------------------------------------------

// `fmt.println` with no `import "core:fmt"` above it: offer the import lines that
// would resolve the qualifier. Only a *qualified* use asks for this — a bare
// identifier names no package, so there is nothing to look up — and a qualifier
// that already resolves (an import, or a local shadowing it, as in a struct
// value's `v.field`) is left alone.
@(private = "file")
action_add_import :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    op, _, is_sel := selector_parts(ident)
    if !is_sel || !is_identifier(op) {
        return
    }
    pkg := ts.node_text(op, req.source)
    if _, imported := import_path(root, req.source, pkg); imported {
        return
    }
    // A value of that name in scope means the selector is member access, not a
    // package qualifier.
    defs := collect_defs(e, root, req.source)
    if _, shadowed := resolve_local(defs[:], pkg, int(ts.node_start_byte(op))); shadowed {
        return
    }

    anchor, prefix, aok := import_anchor(root, req.source)
    if !aok {
        return
    }
    for path in import_candidates(e, parser, req, pkg) {
        line := fmt.tprintf("%simport \"%s\"\n", prefix, path)
        title := fmt.tprintf("Import \"%s\"", path)
        push_action(res, req, title, "quickfix", Edit_Spec{start = anchor, end = anchor, new_text = line})
    }
}

// Import paths that would make `pkg` resolve: the three built-in collections
// first (searched under ODIN_ROOT), then any collection the workspace config
// declares, then a directory in the workspace holding Odin files — which imports
// by a path relative to the requesting file. Temp-allocated.
@(private = "file")
import_candidates :: proc(e: ^Engine, parser: ts.Parser, req: ^lang.Request, pkg: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)

    if root := odin_root(); root != "" {
        for coll in ([?]string{"core", "vendor", "base"}) {
            dir, jerr := filepath.join({root, coll}, context.temp_allocator)
            if jerr != nil {
                continue
            }
            if sub, found := find_package_dir(dir, pkg, COLLECTION_DEPTH); found {
                append(&out, fmt.tprintf("%s:%s", coll, sub))
            }
        }
    }

    for coll in config_collection_names(e, req.workspace) {
        dir, ok := config_collection_dir(e, coll, req.workspace)
        if !ok {
            continue
        }
        if sub, found := find_package_dir(dir, pkg, COLLECTION_DEPTH); found {
            append(&out, fmt.tprintf("%s:%s", coll, sub))
        }
    }

    if rel, found := workspace_package_path(req, pkg); found {
        append(&out, rel)
    }

    if len(out) > IMPORT_CANDIDATE_LIMIT {
        return out[:IMPORT_CANDIDATE_LIMIT]
    }
    return out[:]
}

// The sub-path (slash-separated, as an import spells it) of a directory named
// `pkg` under `dir`, searched breadth-first so a shallower match wins: `core` has
// both `sync` and `sys/...`, and the top-level package is the one meant.
@(private = "file")
find_package_dir :: proc(dir, pkg: string, depth: int) -> (string, bool) {
    if depth <= 0 {
        return "", false
    }
    handle, open_err := os.open(dir)
    if open_err != nil {
        return "", false
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return "", false
    }

    for info in infos {
        if info.type == .Directory && info.name == pkg {
            return info.name, true
        }
    }
    for info in infos {
        if info.type != .Directory || strings.has_prefix(info.name, ".") {
            continue
        }
        if sub, found := find_package_dir(info.fullpath, pkg, depth - 1); found {
            return fmt.tprintf("%s/%s", info.name, sub), true
        }
    }
    return "", false
}

// Import path for a workspace directory named `pkg`, relative to the requesting
// file's own directory — the spelling a relative import needs. The index already
// knows every Odin file in the workspace, so the directory is found without a
// walk of its own; separators are normalized to `/`, which is what an import
// path uses on every platform.
@(private = "file")
workspace_package_path :: proc(req: ^lang.Request, pkg: string) -> (string, bool) {
    if req.workspace == "" || req.path == "" {
        return "", false
    }
    dir, found := find_package_dir(req.workspace, pkg, SCAN_DEPTH_LIMIT)
    if !found {
        return "", false
    }
    target, jerr := filepath.join({req.workspace, dir}, context.temp_allocator)
    if jerr != nil {
        return "", false
    }
    if !dir_has_odin_files(target) {
        return "", false // a directory, but not a package
    }
    rel, rerr := filepath.rel(filepath.dir(req.path), target, context.temp_allocator)
    if rerr != nil {
        return "", false
    }
    slashed, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
    if !strings.has_prefix(slashed, ".") {
        slashed = fmt.tprintf("./%s", slashed)
    }
    return slashed, true
}

// True when `dir` holds at least one `.odin` file — what separates a package
// directory from a directory that merely has the right name.
@(private = "file")
dir_has_odin_files :: proc(dir: string) -> bool {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return false
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return false
    }
    for info in infos {
        if info.type != .Directory && strings.has_suffix(info.name, ".odin") {
            return true
        }
    }
    return false
}

// Where a new import line goes: the line after the last existing import, or —
// when the file has none — the line after the package clause, with `prefix`
// carrying the blank line that separates the two. False when the file has no
// package clause to anchor against, which is not a file this engine can fix.
@(private = "file")
import_anchor :: proc(root: ts.Node, source: string) -> (offset: int, prefix: string, ok: bool) {
    last := -1
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) == "import_declaration" {
            last = int(ts.node_end_byte(child))
        }
    }

    anchor := 0
    pre := ""
    if last >= 0 {
        _, line_end := line_bounds(source, last)
        anchor = min(line_end + 1, len(source))
    } else {
        _, poff, pok := package_clause(source)
        if !pok {
            return 0, "", false
        }
        _, line_end := line_bounds(source, poff)
        anchor = min(line_end + 1, len(source))
        pre = "\n" // keep the imports a blank line clear of the package clause
    }
    // Landing at EOF on a file with no final newline would splice the import onto
    // the last line; open one first.
    if anchor == len(source) && len(source) > 0 && source[len(source) - 1] != '\n' {
        pre = strings.concatenate({"\n", pre}, context.temp_allocator)
    }
    return anchor, pre, true
}

// ---------------------------------------------------------------------------
// Remove unused imports
// ---------------------------------------------------------------------------

// Imports the file never names. Offers the one under the caret on its own, and
// the whole set together — skipping the bulk action when it would duplicate the
// single one, so a file with exactly one dead import that the caret sits on
// gets one row rather than two.
@(private = "file")
action_remove_unused_imports :: proc(root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    unused := unused_imports(root, req.source)
    if len(unused) == 0 {
        return
    }

    caret_hit := -1
    for imp, i in unused {
        if req.offset >= int(ts.node_start_byte(imp)) && req.offset <= int(ts.node_end_byte(imp)) {
            caret_hit = i
            break
        }
    }
    if caret_hit >= 0 {
        raw, _ := import_string(unused[caret_hit], req.source)
        title := fmt.tprintf("Remove unused import \"%s\"", raw)
        push_action(res, req, title, "quickfix", line_deletion(req.source, unused[caret_hit]))
    }
    if caret_hit >= 0 && len(unused) == 1 {
        return
    }

    // Tree order, so the edits come out ascending by offset — the ordering the
    // seam promises an applier.
    specs := make([dynamic]Edit_Spec, context.temp_allocator)
    for imp in unused {
        append(&specs, line_deletion(req.source, imp))
    }
    title := len(unused) == 1 ? "Remove 1 unused import" : fmt.tprintf("Remove %d unused imports", len(unused))
    push_action(res, req, title, "quickfix", ..specs[:])
}

// The import declarations whose package name never appears as an identifier
// outside the import block. A `_` alias is deliberate — the package is imported
// for its side effects, not to be named — so it is never reported.
@(private = "file")
unused_imports :: proc(root: ts.Node, source: string) -> []ts.Node {
    used := make(map[string]bool, 0, context.temp_allocator)
    collect_used_names(root, source, &used)

    out := make([dynamic]ts.Node, context.temp_allocator)
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        name, _, ok := import_name_and_path(child, source)
        if !ok || name == "_" || name in used {
            continue
        }
        append(&out, child)
    }
    return out[:]
}

// Every identifier named anywhere but inside an import declaration — the import's
// own alias must not count as a use of itself.
@(private = "file")
collect_used_names :: proc(node: ts.Node, source: string, used: ^map[string]bool) {
    if string(ts.node_type(node)) == "import_declaration" {
        return
    }
    if is_identifier(node) {
        used^[ts.node_text(node, source)] = true
    }
    for i in 0 ..< ts.node_child_count(node) {
        collect_used_names(ts.node_child(node, i), source, used)
    }
}

// The edit that deletes the whole line `node` sits on, its newline included, so
// removing an import leaves no blank line behind.
@(private = "file")
line_deletion :: proc(source: string, node: ts.Node) -> Edit_Spec {
    line_start, line_end := line_bounds(source, int(ts.node_start_byte(node)))
    return Edit_Spec{start = line_start, end = min(line_end + 1, len(source)), new_text = ""}
}

// ---------------------------------------------------------------------------
// Fill switch cases
// ---------------------------------------------------------------------------

// A `switch` over an enum that does not name every member: offer the missing
// `case` arms. A type switch is left alone — its cases name union variants, not
// enum members — as is a switch whose operand type cannot be inferred.
@(private = "file")
action_fill_switch_cases :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    sw, ok := enclosing_switch(root, req.source, req.offset)
    if !ok {
        return
    }
    if _, _, is_type_switch := type_switch_parts(sw); is_type_switch {
        return
    }
    cond := ts.node_child_by_field_name(sw, "condition")
    if ts.node_is_null(cond) {
        return // `switch { case a > b: }` switches over no value
    }
    tr, tok := infer_expr_type(e, parser, root, req, cond)
    if !tok || !type_is_bare(tr) {
        return
    }

    members := make([dynamic]string, context.temp_allocator)
    if !visit_type_decl(e, parser, root, req, tr, "enum_declaration", "enum", members_visitor, &members) {
        return
    }
    if len(members) == 0 {
        return
    }

    covered := make(map[string]bool, 0, context.temp_allocator)
    collect_covered_cases(sw, req.source, &covered)
    missing := make([dynamic]string, context.temp_allocator)
    for name in members {
        if name not_in covered {
            append(&missing, name)
        }
    }
    if len(missing) == 0 {
        return
    }

    brace := switch_close_brace(sw)
    if ts.node_is_null(brace) {
        return
    }
    line_start, _ := line_bounds(req.source, int(ts.node_start_byte(brace)))
    indent := case_indent(sw, req.source)

    b := strings.builder_make(context.temp_allocator)
    for name in missing {
        fmt.sbprintf(&b, "%scase .%s:\n", indent, name)
    }
    title := len(missing) == 1 \
        ? fmt.tprintf("Add missing case .%s", missing[0]) \
        : fmt.tprintf("Add %d missing cases", len(missing))
    push_action(
        res,
        req,
        title,
        "quickfix",
        Edit_Spec{start = line_start, end = line_start, new_text = strings.to_string(b)},
    )
}

// Decl_Visitor collecting an enum's member names, which are its identifier
// children after the first (the enum's own name). The names slice the visited
// file's source, which outlives the visit.
@(private = "file")
members_visitor :: proc(ed: ts.Node, source, path: string, ctx_raw: rawptr) {
    out := cast(^[dynamic]string) ctx_raw
    for i in 1 ..< ts.node_named_child_count(ed) {
        id := ts.node_named_child(ed, i)
        if is_identifier(id) {
            append(out, strings.clone(ts.node_text(id, source), context.temp_allocator))
        }
    }
}

// Nearest switch_statement enclosing `offset`, so the caret can sit anywhere in
// the switch — its head, a case body, the closing brace — and still fill it.
@(private = "file")
enclosing_switch :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    n := ts.node_named_descendant_for_byte_range(root, off, off)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == "switch_statement" {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// The enum members a switch already names. Read off the case text rather than the
// tree because the two spellings — the implicit `.Vertical` and the qualified
// `Axis.Vertical` — parse differently but agree on everything after the last dot.
@(private = "file")
collect_covered_cases :: proc(sw: ts.Node, source: string, covered: ^map[string]bool) {
    for i in 0 ..< ts.node_named_child_count(sw) {
        c := ts.node_named_child(sw, i)
        if string(ts.node_type(c)) != "switch_case" {
            continue
        }
        for j in 0 ..< ts.node_named_child_count(c) {
            if string(ts.node_field_name_for_named_child(c, u32(j))) != "condition" {
                continue
            }
            text := strings.trim_space(ts.node_text(ts.node_named_child(c, j), source))
            if dot := strings.last_index_byte(text, '.'); dot >= 0 {
                text = text[dot + 1:]
            }
            if text != "" {
                covered^[text] = true
            }
        }
    }
}

// The switch's closing brace — its last `}` child, which is where new cases go in
// front of.
@(private = "file")
switch_close_brace :: proc(sw: ts.Node) -> ts.Node {
    count := ts.node_child_count(sw)
    for i := count; i > 0; i -= 1 {
        c := ts.node_child(sw, i - 1)
        if string(ts.node_type(c)) == "}" {
            return c
        }
    }
    return {}
}

// Indentation for a case arm: whatever the existing cases use, so a filled switch
// matches the file rather than this engine's opinion. With no case to copy, one
// tab past the switch's own line — Odin's convention, and what the rest of this
// codebase is written in.
@(private = "file")
case_indent :: proc(sw: ts.Node, source: string) -> string {
    for i in 0 ..< ts.node_named_child_count(sw) {
        c := ts.node_named_child(sw, i)
        if string(ts.node_type(c)) == "switch_case" {
            line_start, _ := line_bounds(source, int(ts.node_start_byte(c)))
            return line_indent(source, line_start)
        }
    }
    line_start, _ := line_bounds(source, int(ts.node_start_byte(sw)))
    return strings.concatenate({line_indent(source, line_start), "\t"}, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Declare variable
// ---------------------------------------------------------------------------

// `count = 1` where nothing declares `count`: offer turning the assignment into
// the `:=` short declaration it was meant to be. Deliberately the only shape
// offered — inserting a declaration above would have to name a type, and until
// the inference layer can compute one there is no correct text to insert.
@(private = "file")
action_declare_variable :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    assign, has := ancestor_type(ident, "assignment_statement")
    if !has {
        return
    }
    targets, op, aok := plain_assignment_parts(assign, req.source)
    if !aok {
        return
    }

    // The caret must be on one of the assigned names, not somewhere in the value.
    on_target := false
    for t in targets {
        if same_node(t, ident) {
            on_target = true
            break
        }
    }
    if !on_target {
        return
    }

    defs := collect_defs(e, root, req.source)
    undeclared := make([dynamic]string, context.temp_allocator)
    for t in targets {
        name := ts.node_text(t, req.source)
        if name == "_" {
            continue
        }
        if _, found := resolve_local(defs[:], name, int(ts.node_start_byte(t))); found {
            continue
        }
        if declared_in_package(e, parser, req, name) {
            continue
        }
        append(&undeclared, name)
    }
    if len(undeclared) == 0 {
        return
    }

    title := len(undeclared) == 1 \
        ? fmt.tprintf("Declare %q with :=", undeclared[0]) \
        : fmt.tprintf("Declare %d names with :=", len(undeclared))
    push_action(
        res,
        req,
        title,
        "quickfix",
        Edit_Spec{start = int(ts.node_start_byte(op)), end = int(ts.node_end_byte(op)), new_text = ":="},
    )
}

// The assigned names and the `=` token of a plain assignment, false for anything
// `:=` cannot replace: an existing short declaration, a compound assignment
// (`x += 1`), or a target that is not a bare name (`m[k] = v`, `p.x = 1`) — Odin
// declares names, not places.
@(private = "file")
plain_assignment_parts :: proc(assign: ts.Node, source: string) -> (targets: []ts.Node, op: ts.Node, ok: bool) {
    names := make([dynamic]ts.Node, context.temp_allocator)
    for i in 0 ..< ts.node_child_count(assign) {
        c := ts.node_child(assign, i)
        switch string(ts.node_type(c)) {
        case "identifier":
            append(&names, c)
            continue
        case ",":
            continue
        case "=":
            if len(names) == 0 {
                return nil, {}, false
            }
            return names[:], c, true
        }
        return nil, {}, false // `:=`, `+=`, or a target that is not a bare name
    }
    return nil, {}, false
}

// True when `name` is declared at package scope in a sibling file. The caret's
// own file is already covered by collect_defs, so this is only about the rest of
// the package — a package-level variable assigned from another file is a legal
// assignment and must not be offered a declaration.
@(private = "file")
declared_in_package :: proc(e: ^Engine, parser: ts.Parser, req: ^lang.Request, name: string) -> bool {
    if req.workspace == "" {
        return false
    }
    sync.lock(&e.index.mutex)
    defer sync.unlock(&e.index.mutex)
    index_sync(e, parser, req)
    // Scoped in the query rather than checked after it: the workspace-wide first
    // hit is the lexicographically smallest path, so a name declared both here
    // and in some earlier-sorting package used to read as "not in this package"
    // and offer a declaration for an assignment that was already legal.
    _, found := index_first_path(e, name, req.path, "", index_package_dir(e, req.path))
    return found
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

// The line containing `offset`, as `[start, end)` with `end` at the newline (or
// at the end of the source, for a final line without one).
@(private = "file")
line_bounds :: proc(source: string, offset: int) -> (start: int, end: int) {
    off := clamp(offset, 0, len(source))
    start = off
    for start > 0 && source[start - 1] != '\n' {
        start -= 1
    }
    end = off
    for end < len(source) && source[end] != '\n' {
        end += 1
    }
    return
}

// The whitespace a line opens with, sliced from the source.
@(private = "file")
line_indent :: proc(source: string, line_start: int) -> string {
    i := clamp(line_start, 0, len(source))
    for i < len(source) && (source[i] == ' ' || source[i] == '\t') {
        i += 1
    }
    return source[clamp(line_start, 0, len(source)):i]
}
