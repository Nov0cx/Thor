// Type-aware member access (`value.field`).
//
// The engine has no general type system, but the most common selector — a field
// of a struct-typed value — is resolvable with a narrow, name-based inference:
// find the operand's declaration, read its struct type, locate that struct (same
// file, an imported package, or the workspace index) and match the field. The
// type comes from a written-down declaration (`p: Point`, a parameter) or, for a
// `:=` binding, from its initializer — a composite literal, an aliased value, or
// the declared result type of the procedure it calls (`p := make_point()`, which
// resolves the callee the same three ways signature help does). Chained access
// (`a.b.c`) recurses through each struct's field type, and a pointer type is
// transparently dereferenced (Odin auto-derefs `.`). A struct embedded with
// `using` answers for its fields as if they were the outer struct's own, and a
// container (`[]T`, `[N]T`, `[dynamic]T`, `map[K]V`, `bit_set[T]`) resolves to
// its element once it is indexed, sliced or ranged over — never before, since a
// container is not the type it holds, except for the two members an array offers
// itself (container.odin). Containers nest, so `map[string][]Point` takes two of
// those steps. A proc-typed value carries its signature, so calling it yields its
// declared result. Anything else (an un-narrowed union, a builtin) doesn't
// resolve, and the caller falls back to the flat name scan.
//
// This file infers a type from an expression; typeref.odin reads one out of a
// written-down type, and decl.odin locates the declaration it names.
package odin

import "core:strings"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// What a type holds when it is not the named type itself: `[]Point`, `[4]Point`
// and `[dynamic]Point` are arrays of it, `map[string]Point` maps to it, and
// `bit_set[Axis]` is a set of it. Element access (`xs[i]`) and a range loop
// (`for p in xs`) strip one level off.
@(private)
Container :: enum {
    Array,
    Map,
    Bit_Set,
}

// One level of container around an element type, plus — for a map — the type it
// is keyed by, so `for k in m` and `m[.Member]` know what a key is. Only a plain
// (optionally qualified) key name is tracked; `map[[2]int]V` records none.
// `length`, `dyn` and `soa` describe an array: how a fixed one is written and
// how many components it swizzles, and whether it holds one array per field of
// its element (see container.odin).
@(private)
Container_Layer :: struct {
    kind:    Container,
    key:     string,
    key_pkg: string,
    length:  int,  // `[4]T` — 0 for a slice, a dynamic array and a named count
    dyn:     bool, // `[dynamic]T`
    soa:     bool, // `#soa[]T`
}

// How many container levels are modelled: `map[string][]Point` is two, and
// nesting deeper than this is not inferred rather than inferred wrongly. The
// levels are a fixed array on every Type_Ref, so this is a size as much as a
// guard.
@(private)
CONTAINER_DEPTH_LIMIT :: 8

// A named type reference: the type name plus an optional package qualifier
// (`pkg` in `p: pkg.Point`), the containers wrapped around it (innermost first —
// the name is then the *element* type, a map's value), the signature of a
// proc-typed value (whose `name` is empty, since a proc type names nothing), and
// the file the reference was read from, so a qualifier written in another file
// resolves against *that* file's imports. Strings slice the source they were read
// from unless explicitly cloned, so a Type_Ref that must outlive a parse is
// temp-cloned.
@(private)
Type_Ref :: struct {
    name:       string,
    pkg:        string,
    proc_sig:   string,
    containers: [CONTAINER_DEPTH_LIMIT]Container_Layer,
    depth:      int,
    origin:     string,
}

// Whether the reference names a type outright, rather than a container of one.
// Every member operation stops at a container: `xs: []Point` must be indexed or
// ranged over before Point's fields are in reach.
@(private)
type_is_bare :: proc(tr: Type_Ref) -> bool {
    return tr.depth == 0
}

// The outermost container around the element type — the one an index or a range
// loop strips.
@(private)
outer_container :: proc(tr: Type_Ref) -> (Container_Layer, bool) {
    if tr.depth == 0 {
        return {}, false
    }
    return tr.containers[tr.depth - 1], true
}

// `tr` wrapped in one more container. Fails past CONTAINER_DEPTH_LIMIT.
@(private)
wrap_container :: proc(tr: Type_Ref, layer: Container_Layer) -> (Type_Ref, bool) {
    if tr.depth >= CONTAINER_DEPTH_LIMIT {
        return {}, false
    }
    out := tr
    out.containers[out.depth] = layer
    out.depth += 1
    return out, true
}

// `tr` with its outermost container stripped: what indexing, slicing into, or
// ranging over the value yields.
@(private)
unwrap_container :: proc(tr: Type_Ref) -> (Type_Ref, Container_Layer, bool) {
    layer, ok := outer_container(tr)
    if !ok {
        return {}, {}, false
    }
    out := tr
    out.depth -= 1
    return out, layer, true
}

// The element every container level holds, whatever the nesting: what a literal
// of `[]Axis` or `bit_set[Axis]` selects a member from.
@(private)
element_type :: proc(tr: Type_Ref) -> Type_Ref {
    out := tr
    out.depth = 0
    return out
}

// The type a map is keyed by, as a reference of its own, qualified by the file
// the map type was written in.
@(private)
map_key_type :: proc(tr: Type_Ref, layer: Container_Layer) -> (Type_Ref, bool) {
    if layer.kind != .Map || layer.key == "" {
        return {}, false
    }
    return Type_Ref{name = layer.key, pkg = layer.key_pkg, origin = tr.origin}, true
}

// A value binding's declared type and the scope it is visible in, so the nearest
// visible declaration of a name can be chosen (mirroring resolve_local). A `:=`
// binding writes no type down, so it carries its initializer expression instead
// (`expr`) and the type is inferred on demand; `result_index` is the slot this
// name takes in a multi-value call (`v, ok := f()`).
@(private)
Binding :: struct {
    tr:           Type_Ref,
    expr:         ts.Node, // valid when has_expr: the `:=` right-hand side
    has_expr:     bool,
    is_range:     bool, // `expr` is a `for x in expr` operand: bind its element
    result_index: int,
    scope_start:  int,
    scope_end:    int,
    visible_from: int, // order-dependent binding: first offset past its declaration
    top_level:    bool,
    pos:          int,
}

// How far the inference recursion may go. Field chains, aliased bindings and call
// results all recurse, and a self-referential declaration (`x := x`, or two
// bindings naming each other) would otherwise never bottom out.
@(private)
INFER_DEPTH_LIMIT :: 8

// Resolves `value.field`: infers the operand's struct type, finds that struct and
// its field, and fills the go-to-definition location or hover text. Returns
// whether it resolved (false when the operand's type isn't an in-reach struct, so
// the caller can fall through). `operand` is the expression left of the dot — a
// bare identifier or a nested `a.b` member access.
@(private)
resolve_member :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    operand: ts.Node,
    field: string,
    hover_start, hover_end: int,
    res: ^lang.Result,
) -> bool {
    tr, ok := infer_expr_type(e, parser, root, req, operand)
    if !ok {
        return false
    }
    // A container answers for its own members first, since the struct lookup
    // below stops at one: a fixed array swizzles, an `#soa` array holds one array
    // per field of its element.
    if !type_is_bare(tr) {
        return resolve_container_member(e, parser, root, req, tr, field, hover_start, hover_end, res)
    }
    ctx := Member_Ctx {
        field = field,
        env = Embed_Env{e = e, parser = parser, root = root, req = req},
    }
    if !visit_type_decl(e, parser, root, req, tr, "struct_declaration", "type", member_visitor, &ctx) || !ctx.got {
        return false
    }
    #partial switch req.kind {
    case .Definition:
        res.location = lang.Location {
            path  = strings.clone(ctx.path),
            start = ctx.ident_start,
            end   = ctx.ident_end,
        }
        res.ok = true
    case .Hover:
        res.hover = lang.Hover_Info {
            text  = declaration_text_range(ctx.src, ctx.decl_start, ctx.decl_end),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
    return res.ok
}

// Static type of an expression node, for member access. A bare identifier resolves
// through its value binding, a nested `a.b` recurses (type of `a`, then the type of
// its `b` field), a composite literal names its own type, and a call resolves to
// its procedure's result type. Anything else is not inferred.
@(private)
infer_expr_type :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    node: ts.Node,
    depth := 0,
) -> (Type_Ref, bool) {
    return infer_expr_result(e, parser, root, req, node, 0, depth)
}

// infer_expr_type with a result slot: `index` picks one type out of a call's
// multi-value return (`v, ok := f()` binds `ok` to slot 1). Every other expression
// shape has a single type, so the index is ignored there.
@(private)
infer_expr_result :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    node: ts.Node,
    index, depth: int,
) -> (Type_Ref, bool) {
    if depth > INFER_DEPTH_LIMIT || ts.node_is_null(node) {
        return {}, false
    }
    if is_identifier(node) {
        name := ts.node_text(node, req.source)
        return binding_type_ref(e, parser, root, req, name, int(ts.node_start_byte(node)), depth + 1)
    }
    switch string(ts.node_type(node)) {
    case "member_expression":
        op := ts.node_named_child(node, 0)
        member := ts.node_named_child(node, 1)
        if ts.node_is_null(op) || ts.node_is_null(member) {
            return {}, false
        }
        // `pkg.fn(...)`: the grammar nests the call under the member expression, so
        // the call — which resolves the package itself — is what has the type. A
        // proc-typed *field* (`c.on(1)`) wears the same shape, and only the
        // operand's type separates the two: a package operand types as nothing.
        if string(ts.node_type(member)) == "call_expression" {
            fn := ts.node_child_by_field_name(member, "function")
            if is_identifier(fn) && !operand_names_import(root, req.source, op) {
                ftype, fok := member_field_type(e, parser, root, req, op, ts.node_text(fn, req.source), depth)
                if fok && ftype.proc_sig != "" {
                    return proc_value_result(ftype, index)
                }
            }
            return call_result_type(e, parser, root, req, member, index, depth + 1)
        }
        // `u.(Point)` is an assertion, not a field: the grammar spells the asserted
        // type as a parenthesized expression where a member name would be. The
        // value reads as that type — the second result of `v, ok := u.(Point)` is a
        // bool, which has nothing to reach through.
        if string(ts.node_type(member)) == "parenthesized_expression" {
            if index != 0 {
                return {}, false
            }
            return expr_type_name(ts.node_named_child(member, 0), req.source)
        }
        if !is_identifier(member) {
            return {}, false
        }
        return member_field_type(e, parser, root, req, op, ts.node_text(member, req.source), depth)
    case "struct":
        // A composite literal (`Point{...}`, `[]Point{...}`) names the type it
        // builds. The grammar drops a container literal's brackets from the named
        // children, so the type is read off the text before the brace.
        return composite_type_name(node, req.source)
    case "call_expression":
        return call_result_type(e, parser, root, req, node, index, depth + 1)
    case "index_expression":
        // `xs[i]` is one element of its container — a map's value, one level off
        // a nested container. A bit_set is not indexed, only tested with `in`.
        op, ok := infer_expr_result(e, parser, root, req, ts.node_named_child(node, 0), 0, depth + 1)
        if !ok {
            return {}, false
        }
        elem, layer, uok := unwrap_container(op)
        if !uok || layer.kind == .Bit_Set {
            return {}, false
        }
        return elem, true
    case "slice_expression":
        // `xs[1:3]` is another container of the same element type.
        op, ok := infer_expr_result(e, parser, root, req, ts.node_named_child(node, 0), 0, depth + 1)
        if !ok {
            return {}, false
        }
        if layer, lok := outer_container(op); !lok || layer.kind != .Array {
            return {}, false
        }
        return op, true
    case "unary_expression":
        // `&xs[0]` — `.` dereferences, so the pointer is transparent.
        return infer_expr_result(e, parser, root, req, ts.node_named_child(node, 0), index, depth + 1)
    case "cast_expression":
        // `cast(Point)v` and `transmute(Point)v` both take the type in the
        // parens, which the grammar hangs off the expression as its own `type`
        // node. `auto_cast v` is the same node without one, and what it converts
        // to is decided by where it sits rather than by the expression, so it is
        // not inferred.
        target := ts.node_named_child(node, 0)
        if string(ts.node_type(target)) != "type" {
            return {}, false
        }
        return type_ref_from_node(target, req.source)
    }
    return {}, false
}

// Whether the operand of a selector is an imported package rather than a value —
// the one thing that tells `pkg.fn(...)` from a call of a struct's proc field,
// which the grammar spells identically. Answered before the field lookup, so the
// common qualified call pays no inference for a struct it does not have.
@(private)
operand_names_import :: proc(root: ts.Node, source: string, operand: ts.Node) -> bool {
    if !is_identifier(operand) {
        return false
    }
    _, found := import_path(root, source, ts.node_text(operand, source))
    return found
}

// Type of `operand.field`: the operand's type located, then its named field's —
// or, over a container, the member the container itself offers (container.odin).
// The shared step behind a chained access (`a.b.c`) and a call of a proc-typed
// field (`c.on(1)`).
@(private)
member_field_type :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    operand: ts.Node,
    field: string,
    depth: int,
) -> (Type_Ref, bool) {
    inner, ok := infer_expr_result(e, parser, root, req, operand, 0, depth + 1)
    if !ok {
        return {}, false
    }
    if !type_is_bare(inner) {
        return container_member_type(e, parser, root, req, inner, field)
    }
    ctx := Member_Ctx {
        field = field,
        env = Embed_Env{e = e, parser = parser, root = root, req = req},
    }
    if !visit_type_decl(e, parser, root, req, inner, "struct_declaration", "type", member_visitor, &ctx) || !ctx.got {
        return {}, false
    }
    return ctx.field_type, true
}

// Type a call of a proc-typed *value* evaluates to: the `index`-th result read
// out of the signature the value carries. A proc type declares no procedure to
// look up, so the signature text is all there is — which is exactly what
// proc_result_type reads a cross-file callee's result from.
@(private)
proc_value_result :: proc(tr: Type_Ref, index: int) -> (Type_Ref, bool) {
    if tr.proc_sig == "" {
        return {}, false
    }
    out, ok := signature_result_type(tr.proc_sig, index)
    if !ok {
        return {}, false
    }
    // Spelled in the file the proc type was written in, so that file's imports
    // qualify it (`on: proc() -> other.Point`).
    out.origin = tr.origin
    return out, true
}

// The type a composite literal builds, read from its text up to the opening brace
// (`Point`, `pkg.Point`, `[]Point`, `map[string]Point`) — the grammar keeps a
// container literal's `[]` as anonymous tokens, so the named children alone can't
// tell `[]Point{}` from `Point{}`.
@(private)
composite_type_name :: proc(node: ts.Node, source: string) -> (Type_Ref, bool) {
    text := ts.node_text(node, source)
    if brace := strings.index_byte(text, '{'); brace >= 0 {
        text = text[:brace]
    }
    return result_type_ref(strings.trim_space(text))
}

// Type of the value named `name` visible at `offset`: the nearest enclosing
// binding — a parameter, a typed `var` declaration, or a `:=` short declaration
// whose initializer's type is inferred (a composite literal, a call's result, or
// another binding it aliases). A local shadows a file-scope binding, an inner
// scope shadows an outer, a later declaration shadows an earlier — like
// resolve_local.
@(private)
binding_type_ref :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    name: string,
    offset: int,
    depth := 0,
) -> (Type_Ref, bool) {
    binds := make([dynamic]Binding, context.temp_allocator)
    collect_bindings(root, req.source, name, &binds)

    best: Binding
    found := false
    for b in binds {
        if !b.top_level && (offset < b.scope_start || offset > b.scope_end || offset < b.visible_from) {
            continue
        }
        if !found || binding_better(b, best, offset) {
            best = b
            found = true
        }
    }
    if !found {
        // A name no binding declares may still be a field a `using` opened here.
        return using_member_type(e, parser, root, req, name, offset, depth)
    }
    if best.is_range {
        return range_var_type(e, parser, root, req, best.expr, best.result_index, depth + 1)
    }
    if best.has_expr {
        return infer_expr_result(e, parser, root, req, best.expr, best.result_index, depth + 1)
    }
    return best.tr, true
}

// Type of the `index`-th variable of `for a, b in expr`: over an array the first
// is the element and the second its integer index, over a map the first is the
// key and the second the value, over a bit_set the first is the member and the
// second nothing. An integer index is no type this engine models, so only the
// slots that name one answer.
@(private)
range_var_type :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    expr: ts.Node,
    index, depth: int,
) -> (Type_Ref, bool) {
    tr, ok := infer_expr_result(e, parser, root, req, expr, 0, depth)
    if !ok {
        return {}, false
    }
    elem, layer, uok := unwrap_container(tr)
    if !uok {
        return {}, false
    }
    switch layer.kind {
    case .Array, .Bit_Set:
        if index != 0 {
            return {}, false
        }
    case .Map:
        if index == 0 {
            return map_key_type(tr, layer)
        }
        if index != 1 {
            return {}, false
        }
    }
    return elem, true
}

@(private)
binding_better :: proc(a, b: Binding, offset: int) -> bool {
    if a.top_level != b.top_level {
        return !a.top_level
    }
    if !a.top_level {
        aw := a.scope_end - a.scope_start
        bw := b.scope_end - b.scope_start
        if aw != bw {
            return aw < bw
        }
        if a.visible_from != b.visible_from {
            return a.visible_from > b.visible_from
        }
    }
    return abs(a.pos - offset) < abs(b.pos - offset)
}

// Walks the tree gathering every binding of `name`: parameters and typed `var`
// declarations (their `(type ...)` child) and `name := value` short declarations
// (the initializer, whose type is inferred later). Each carries the scope it is
// visible in — a parameter its procedure, a local the part of its block that
// follows the declaration, otherwise file-wide.
@(private)
collect_bindings :: proc(node: ts.Node, source, name: string, out: ^[dynamic]Binding) {
    switch string(ts.node_type(node)) {
    case "parameter", "default_parameter":
        if tr, ok := named_decl_type(node, source, name); ok {
            b := Binding{tr = tr, pos = int(ts.node_start_byte(node))}
            if pd, has := ancestor_type(node, "procedure_declaration"); has {
                b.scope_start = int(ts.node_start_byte(pd))
                b.scope_end = int(ts.node_end_byte(pd))
            } else {
                b.top_level = true
            }
            append(out, b)
        }
    case "var_declaration":
        if tr, ok := named_decl_type(node, source, name); ok {
            append(out, scoped_binding(node, Binding{tr = tr}))
        }
    case "assignment_statement":
        if b, ok := short_decl_binding(node, source, name); ok {
            append(out, scoped_binding(node, b))
        }
    case "for_statement":
        if b, ok := range_binding(node, source, name); ok {
            append(out, b)
        }
    case "switch_statement":
        type_switch_bindings(node, source, name, out)
    }
    for i in 0 ..< ts.node_child_count(node) {
        collect_bindings(ts.node_child(node, i), source, name, out)
    }
}

// The variable a type switch binds and the value it switches over: `switch v in u`
// spells both as an `in_expression` condition, the variable first. The three-clause
// `switch x := e; x` has an assignment_statement there instead and declares nothing
// of its own here — collect_value_decls and collect_bindings already read that
// through their assignment_statement cases.
@(private)
type_switch_parts :: proc(node: ts.Node) -> (ident, operand: ts.Node, ok: bool) {
    for i in 0 ..< ts.node_named_child_count(node) {
        c := ts.node_named_child(node, i)
        if string(ts.node_type(c)) != "in_expression" {
            continue
        }
        a := ts.node_named_child(c, 0)
        b := ts.node_named_child(c, 1)
        if is_identifier(a) && !ts.node_is_null(b) {
            return a, b, true
        }
        break
    }
    return {}, {}, false
}

// The bindings a type switch gives its variable: `switch v in u { case Circle: }`
// reads `v` as a Circle inside that case and as something else in the next, so
// each case contributes its own binding scoped to itself. A case listing several
// types (`case Circle, Square:`) leaves the variable as the union, and the default
// case narrows nothing — neither names one type, so neither binds. The union
// itself is never consulted: the case says what the value is there.
@(private)
type_switch_bindings :: proc(node: ts.Node, source, name: string, out: ^[dynamic]Binding) {
    ident, _, ok := type_switch_parts(node)
    if !ok || ts.node_text(ident, source) != name {
        return
    }
    for i in 0 ..< ts.node_named_child_count(node) {
        c := ts.node_named_child(node, i)
        if string(ts.node_type(c)) != "switch_case" {
            continue
        }
        cond, single := lone_case_condition(c)
        if !single {
            continue
        }
        // A case names a type the way a declaration does (`^Circle`) or the way an
        // expression does (`lib.Circle`) depending on the shape, and a value switch's
        // `case 1:` is neither — which is how a case that narrows nothing is skipped.
        tr, tok := type_ref_from_node(cond, source)
        if !tok {
            tr, tok = expr_type_name(cond, source)
        }
        if !tok {
            continue
        }
        append(
            out,
            Binding {
                tr = tr,
                pos = int(ts.node_start_byte(c)),
                scope_start = int(ts.node_start_byte(c)),
                scope_end = int(ts.node_end_byte(c)),
            },
        )
    }
}

// The single `condition:` child of a switch case, false when it has none (the
// default `case:`) or more than one (`case A, B:`). The conditions lead the case;
// the statements after them are its body.
@(private)
lone_case_condition :: proc(node: ts.Node) -> (ts.Node, bool) {
    cond: ts.Node
    count := 0
    for i in 0 ..< ts.node_named_child_count(node) {
        if string(ts.node_field_name_for_named_child(node, u32(i))) != "condition" {
            continue
        }
        cond = ts.node_named_child(node, i)
        count += 1
    }
    return cond, count == 1
}

// `b` scoped to the block or control-flow statement enclosing its declaration,
// or file-wide when there is none. A `:=`/`var` binding is order-dependent, so
// it only takes effect past its own declaration — which is what lets `x := x`
// read the outer `x` rather than itself.
@(private)
scoped_binding :: proc(node: ts.Node, b: Binding) -> Binding {
    out := b
    out.pos = int(ts.node_start_byte(node))
    if scope, has := enclosing_scope(node); has {
        out.scope_start = int(ts.node_start_byte(scope))
        out.scope_end = int(ts.node_end_byte(scope))
        out.visible_from = int(ts.node_end_byte(node))
    } else {
        out.top_level = true
    }
    return out
}

// Type of a `name`-declaring node whose shape is `ident... : type [= value]`
// (a parameter or a `var` declaration). Names precede the `type` child; a
// trailing initializer value is ignored (the walk stops at the type).
@(private)
named_decl_type :: proc(node: ts.Node, source, name: string) -> (Type_Ref, bool) {
    matched := false
    for i in 0 ..< ts.node_named_child_count(node) {
        c := ts.node_named_child(node, i)
        switch string(ts.node_type(c)) {
        case "identifier":
            if ts.node_text(c, source) == name {
                matched = true
            }
        case "type":
            if !matched {
                return {}, false
            }
            return type_ref_from_node(c, source)
        }
    }
    return {}, false
}

// The binding `name` gets from a `:=` short declaration (a `=` reassignment is not
// a declaration and is ignored). The declared names are the identifier children
// before the `:=` token, the initializers the expressions after it, so the
// expression this name binds to is either its positional partner (`a, b := x, y`)
// or — when one call feeds several names — the call plus the result slot to take
// (`v, ok := f()`). The type of that expression is inferred on demand.
@(private)
short_decl_binding :: proc(node: ts.Node, source, name: string) -> (Binding, bool) {
    is_decl := false
    names := 0
    matched := -1
    rhs := make([dynamic]ts.Node, context.temp_allocator)

    for i in 0 ..< ts.node_child_count(node) {
        c := ts.node_child(node, i)
        if string(ts.node_type(c)) == ":=" {
            is_decl = true
            continue
        }
        if !ts.node_is_named(c) {
            continue // the commas separating names and initializers
        }
        if !is_decl {
            if is_identifier(c) {
                if ts.node_text(c, source) == name {
                    matched = names
                }
                names += 1
            }
            continue
        }
        append(&rhs, c)
    }
    if !is_decl || matched < 0 || len(rhs) == 0 {
        return {}, false
    }

    switch {
    case len(rhs) == names:
        return Binding{expr = rhs[matched], has_expr = true}, true
    case len(rhs) == 1:
        // One expression for several names: a multi-value call, one result each.
        return Binding{expr = rhs[0], has_expr = true, result_index = matched}, true
    }
    return {}, false
}

// The binding `name` gets from a range loop (`for value in expr`, `for k, v in
// expr`). Only the range form declares variables — the three-clause form's
// `i := 0` is an assignment_statement collect_bindings already handles — so the
// `in` token is what identifies it. The variables are the identifier children
// before `in`, the ranged expression the first named child after it; the element
// type is inferred on demand. A loop variable is visible only inside its loop, so
// the binding is scoped to the statement rather than the enclosing block.
@(private)
range_binding :: proc(node: ts.Node, source, name: string) -> (Binding, bool) {
    vars := 0
    matched := -1
    seen_in := false
    expr: ts.Node

    for i in 0 ..< ts.node_child_count(node) {
        c := ts.node_child(node, i)
        if string(ts.node_type(c)) == "in" {
            seen_in = true
            continue
        }
        if !ts.node_is_named(c) {
            continue
        }
        if !seen_in {
            // `for &p in xs` wraps the variable, and the three-clause form's
            // first child is a statement — neither is a bare loop variable.
            if is_identifier(c) {
                if ts.node_text(c, source) == name {
                    matched = vars
                }
            }
            vars += 1
            continue
        }
        expr = c
        break
    }
    if !seen_in || matched < 0 || ts.node_is_null(expr) {
        return {}, false
    }
    return Binding {
            expr = expr,
            has_expr = true,
            is_range = true,
            result_index = matched,
            pos = int(ts.node_start_byte(node)),
            scope_start = int(ts.node_start_byte(node)),
            scope_end = int(ts.node_end_byte(node)),
        },
        true
}
