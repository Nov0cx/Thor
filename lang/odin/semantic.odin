// Semantic classification: what each identifier in the buffer actually *is*,
// as against what its parse shape suggests. The grammar spells a parameter, a
// local, a package and an undeclared typo all as a bare `identifier` and its
// highlights query paints a use of any of them `@variable`, because nothing in
// the tree separates them — only resolution does, and the engine already
// resolves. This request hands that knowledge to the highlighter.
//
// Deliberately sparse. A token is emitted only where the analyzer knows more
// than the grammar does, so an identifier this file says nothing about keeps
// whatever colour the highlights query gave it. The positions the grammar
// already decides — a struct field, an enum member, an attribute, a label — are
// skipped outright rather than re-derived and risk overruling a correct colour
// with a worse one.
//
// Uses go-to-definition's own resolution (`resolve_local` over `collect_defs`),
// so a name's colour and the declaration Alt+Enter jumps to can never disagree.
package odin

import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// How many qualified selectors (`p.x`, `Axis.Vertical`) one semantic_tokens
// request will run member/enum resolution for. Each attempt can cost a
// visit_type_decl walk and, for a package-qualified type, a file read and
// parse — a field name like `x` can appear thousands of times in one large
// file, so past this the pass leaves the rest of them exactly as it always
// has: unclassified, left to the highlighter, rather than paying an unbounded
// cost per keystroke.
@(private)
SEMANTIC_MEMBER_LIMIT :: 512

@(private)
semantic_tokens :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    defs := collect_defs(e, root, req.source)
    by_name := group_defs_by_name(defs[:])

    imports := make(map[string]bool, 0, context.temp_allocator)
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        if name, _, ok := import_name_and_path(child, req.source); ok {
            imports[name] = true
        }
    }

    // Every name that counts as declared. Left empty when dimming is off, which
    // is why the classification below can consult it unconditionally.
    declared := make(map[string]bool, 0, context.temp_allocator)
    dim := dimming_allowed(e, parser, root, req, &declared)

    ctx := Semantic_Ctx {
        e             = e,
        parser        = parser,
        root          = root,
        req           = req,
        defs          = defs[:],
        by_name       = by_name,
        imports       = imports,
        declared      = declared,
        dim           = dim,
        member_budget = SEMANTIC_MEMBER_LIMIT,
        res           = res,
    }
    classify_node(&ctx, root)
    res.ok = len(res.tokens) > 0
}

@(private)
Semantic_Ctx :: struct {
    e:             ^Engine,
    parser:        ts.Parser,
    root:          ts.Node,
    req:           ^lang.Request,
    defs:          []Def,
    by_name:       map[string][dynamic]int,
    imports:       map[string]bool,
    declared:      map[string]bool,
    dim:           bool,
    member_budget: int,
    res:           ^lang.Result,
}

// Buckets `defs`' indices by name, so classify_identifier's per-identifier
// lookup need only scan the shadowing depth at one name rather than every
// definition in the file. Scoped to this request: the whole-file walk here is
// the one resolve_local call site whose cost is actually shaped like
// idents × defs; goto/hover/actions each make one or two lookups per request,
// where building this map would be pure overhead.
@(private)
group_defs_by_name :: proc(defs: []Def) -> map[string][dynamic]int {
    by_name := make(map[string][dynamic]int, 0, context.temp_allocator)
    for d, i in defs {
        arr, has := by_name[d.name]
        if !has {
            arr = make([dynamic]int, 0, context.temp_allocator)
        }
        append(&arr, i)
        by_name[d.name] = arr
    }
    return by_name
}

// resolve_local, narrowed to the bucket `by_name` already found for `name` —
// same visibility/shadowing rules (def_visible_at, def_better), just without
// the linear scan over every other name in the file.
@(private = "file")
resolve_local_grouped :: proc(by_name: map[string][dynamic]int, defs: []Def, name: string, offset: int) -> (Def, bool) {
    bucket, has := by_name[name]
    if !has {
        return {}, false
    }
    best: Def
    found := false
    for i in bucket {
        d := defs[i]
        if !def_visible_at(d, offset) {
            continue
        }
        if !found || def_better(d, best, offset) {
            best = d
            found = true
        }
    }
    return best, found
}

// Walks every identifier in the tree. Pre-order over children in source order,
// so identifiers are reached in ascending byte order and the token list comes
// out sorted with no sort — which is the ordering the seam promises the editor.
@(private)
classify_node :: proc(ctx: ^Semantic_Ctx, node: ts.Node) {
    if is_identifier(node) {
        classify_identifier(ctx, node)
        return
    }
    for i in 0 ..< ts.node_named_child_count(node) {
        classify_node(ctx, ts.node_named_child(node, i))
    }
}

@(private)
classify_identifier :: proc(ctx: ^Semantic_Ctx, node: ts.Node) {
    // A qualified selector's member (`Axis.Vertical`, `p.x`) is normally left
    // to the highlighter — semantic_skip below drops it like any other
    // grammar-obvious position. Tried first because it is additive: on a miss
    // it falls through to that same skip, so a failed enum/field resolution
    // reads as "unclassified", never as unresolved.
    if kind, ok := member_token_kind(ctx, node); ok {
        start := int(ts.node_start_byte(node))
        end := int(ts.node_end_byte(node))
        append(&ctx.res.tokens, lang.Semantic_Token{start, end, kind})
        return
    }
    if semantic_skip(node) {
        return
    }
    name := ts.node_text(node, ctx.req.source)
    start := int(ts.node_start_byte(node))
    end := int(ts.node_end_byte(node))

    if name in ctx.imports {
        append(&ctx.res.tokens, lang.Semantic_Token{start, end, .Package})
        return
    }

    // The declaration this name binds to here, by the same lexical rules goto
    // follows — including the declaring identifier itself, which def_visible_at
    // admits explicitly, so `x` in `x := 1` resolves to its own declaration
    // rather than reading as undeclared.
    if d, found := resolve_local_grouped(ctx.by_name, ctx.defs, name, start); found {
        if kind, ok := token_kind_for_def(d); ok {
            append(&ctx.res.tokens, lang.Semantic_Token{start, end, kind})
        }
        return
    }

    // Nothing in this file. Everything below is the unresolved check, and it only
    // runs where the whole-file guards said the question can be answered at all.
    if !ctx.dim || is_odin_keyword(name) || name in ctx.declared {
        return
    }
    append(&ctx.res.tokens, lang.Semantic_Token{start, end, .Unresolved})
}

// `.Enum_Member` for `Axis.Vertical`, `.Field` for `p.x` — the qualified
// selector shapes, where the operand is a real identifier this engine can
// type. An implicit selector (`.Vertical`, no operand at all) needs the far
// more expensive expected-type walk completion uses and is deliberately out of
// scope here: false on a miss, same as any other unhandled shape, so the
// caller falls through to the ordinary skip rather than reading it as
// unresolved.
@(private = "file")
member_token_kind :: proc(ctx: ^Semantic_Ctx, node: ts.Node) -> (lang.Token_Kind, bool) {
    subject := selector_subject(node)
    holder := ts.node_parent(subject)
    if ts.node_is_null(holder) {
        return {}, false
    }
    switch string(ts.node_type(holder)) {
    case "member_expression", "field_type":
    case:
        return {}, false
    }
    operand := ts.node_named_child(holder, 0)
    if ts.node_is_null(operand) || same_node(operand, subject) || !is_identifier(operand) {
        return {}, false // the operand itself, or an implicit selector with none at all
    }
    op_name := ts.node_text(operand, ctx.req.source)
    if op_name in ctx.imports {
        return {}, false // a package qualifier — left to the highlighter, not a field/member
    }
    if ctx.member_budget <= 0 {
        return {}, false // the rest of the file stays unclassified, not misclassified
    }
    ctx.member_budget -= 1
    member_name := ts.node_text(node, ctx.req.source)
    op_start := int(ts.node_start_byte(operand))

    if d, found := resolve_local_grouped(ctx.by_name, ctx.defs, op_name, op_start); found {
        if d.kind == "type" || d.kind == "enum" {
            tr := Type_Ref{name = op_name}
            if enum_has_member(ctx.e, ctx.parser, ctx.root, ctx.req, tr, member_name) {
                return .Enum_Member, true
            }
            return {}, false
        }
    }
    if _, ok := member_field_type(ctx.e, ctx.parser, ctx.root, ctx.req, operand, member_name, 0); ok {
        return .Field, true
    }
    return {}, false
}

// Whether `tr` names an enum declaring a member called `name`.
@(private = "file")
Enum_Member_Query :: struct {
    name:  string,
    found: bool,
}

@(private = "file")
enum_member_query_visitor :: proc(ed: ts.Node, source, path: string, ctx_raw: rawptr) {
    ctx := cast(^Enum_Member_Query) ctx_raw
    if ctx.found {
        return
    }
    for i in 1 ..< ts.node_named_child_count(ed) {
        id := ts.node_named_child(ed, i)
        if is_identifier(id) && ts.node_text(id, source) == ctx.name {
            ctx.found = true
            return
        }
    }
}

@(private = "file")
enum_has_member :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, tr: Type_Ref, name: string) -> bool {
    ctx := Enum_Member_Query{name = name}
    if !visit_type_decl(e, parser, root, req, tr, "enum_declaration", "enum", enum_member_query_visitor, &ctx) {
        return false
    }
    return ctx.found
}

// Positions where the grammar has already proved what the identifier is, so
// there is nothing to add and a token here could only overrule a correct colour
// with a worse one. Two groups: declarations whose own syntax names their kind
// (a struct field, an enum member, an attribute, a label, the package clause, an
// import alias), and the right-hand side of a selector — a field, a package
// symbol or an implicit enum member — which takes type inference to resolve and
// which the highlights query tags `@field` already.
@(private)
semantic_skip :: proc(node: ts.Node) -> bool {
    parent := ts.node_parent(node)
    if ts.node_is_null(parent) {
        return true
    }
    switch string(ts.node_type(parent)) {
    case "package_declaration",
         "import_declaration",
         "attribute",
         "tag",
         "label_statement",
         "using_statement",
         "foreign_block",
         "field",
         "struct_field",
         "polymorphic_parameters":
        return true
    case "enum_declaration":
        // The enum's own name reads like any other type declaration and stays
        // ours; everything after it is a member, which the grammar names.
        first := ts.node_named_child(parent, 0)
        return ts.node_is_null(first) || !same_node(first, node)
    }

    // `run(whole_line = true)` — a named argument, which the grammar lays out
    // flat inside the call: the name, an `=`, then the value. The name is the
    // callee's parameter, not anything in scope here, and the highlights query
    // tags it already. A positional argument has no `=` after it and stays ours.
    if string(ts.node_type(parent)) == "call_expression" {
        next := ts.node_next_sibling(node)
        if !ts.node_is_null(next) && string(ts.node_type(next)) == "=" {
            return true
        }
    }

    // The selector rule, on the node standing in for this identifier rather than
    // on the identifier itself: only a selector's operand is ours. `a.b.c` nests
    // left, so each inner operand is still the first child of its own selector
    // and stays classified.
    subject := selector_subject(node)
    holder := ts.node_parent(subject)
    if ts.node_is_null(holder) {
        return false
    }
    switch string(ts.node_type(holder)) {
    case "member_expression", "field_type":
        first := ts.node_named_child(holder, 0)
        if ts.node_is_null(first) || !same_node(first, subject) {
            return true
        }
        // An implicit enum selector (`.Vertical`) has no operand at all: its
        // member is the first child but starts past the dot the selector starts
        // at. The name lives in a type only inference finds, and the grammar
        // already spells it as a member.
        return ts.node_start_byte(subject) != ts.node_start_byte(holder)
    }
    return false
}

// The node the selector rule judges on `node`'s behalf. A called or indexed
// member sits inside the wrapper rather than beside the operand — `pkg.run(x)`
// parses as `(member_expression pkg (call_expression run …))` and `pkg.Rect{}`
// as `(member_expression pkg (struct Rect …))` — so the wrapper is what the
// selector holds, and asking about the bare identifier would find a parent that
// is no selector at all.
@(private)
selector_subject :: proc(node: ts.Node) -> ts.Node {
    n := node
    for {
        parent := ts.node_parent(n)
        if ts.node_is_null(parent) {
            return n
        }
        switch string(ts.node_type(parent)) {
        case "call_expression", "index_expression", "struct":
        case:
            return n
        }
        // Only the thing being called, indexed or braced stands in for the
        // wrapper; an argument, a subscript or a field value is an expression in
        // its own right.
        first := ts.node_named_child(parent, 0)
        if ts.node_is_null(first) || !same_node(first, n) {
            return n
        }
        n = parent
    }
}

// The token kind a resolved declaration lends its uses, and whether it says
// anything the grammar has not already said. A `::` constant is deliberately
// unclassified — it can stand for a value, a type or a procedure group, and the
// highlights query decides the cases that are decidable — and a package-level
// variable is left alone because `@variable` is exactly what it is.
@(private)
token_kind_for_def :: proc(d: Def) -> (lang.Token_Kind, bool) {
    switch d.kind {
    case "parameter":
        return .Parameter, true
    case "function":
        return .Procedure, true
    case "type", "enum":
        return .Type, true
    case "field":
        return .Field, true
    case "namespace":
        return .Package, true
    case "var":
        return .Local, !d.top_level
    }
    return {}, false
}

@(private)
is_odin_keyword :: proc(name: string) -> bool {
    for kw in ODIN_KEYWORDS {
        if kw == name {
            return true
        }
    }
    return false
}

// Whether an undeclared name in this file may be dimmed, filling `declared` with
// the names that count as resolved when it may.
//
// Every branch here fails open: the question is "can this file be judged at
// all", and any doubt answers no, because a wrongly dimmed identifier reads as
// an error the compiler never reported and is worse than no colour. Three ways
// to lose the right: no workspace to check against, a `using` (the one construct
// that injects names from a scope this engine does not follow), or an import
// that cannot be located — an unknown collection may bring in anything.
@(private)
dimming_allowed :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    declared: ^map[string]bool,
) -> bool {
    if req.workspace == "" {
        return false
    }
    if has_using(root) {
        return false
    }
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        raw, rok := import_string(child, req.source)
        if !rok {
            return false
        }
        if _, dok := package_dir(e, raw, req.path, req.workspace); !dok {
            return false
        }
    }

    // The implicit scope. Borrowed, not cloned: the cache outlives the request
    // and its keys are stable for the process.
    if !builtin_names(e, parser, declared) {
        return false
    }

    sync.lock(&e.index.mutex)
    index_sync(e, parser, req)
    any_file := index_declared_names(e, declared, context.temp_allocator)
    sync.unlock(&e.index.mutex)

    // An index holding no file at all has not proved anything is absent — the
    // walk was cancelled, or the workspace is not where the engine thinks.
    return any_file
}

// True when the file contains a `using` statement anywhere. Struct embedding
// (`using base: Base`) is a field rather than a statement and does not count:
// the engine does follow that one, so it costs no precision.
@(private)
has_using :: proc(node: ts.Node) -> bool {
    if string(ts.node_type(node)) == "using_statement" {
        return true
    }
    for i in 0 ..< ts.node_named_child_count(node) {
        if has_using(ts.node_named_child(node, i)) {
            return true
        }
    }
    return false
}
