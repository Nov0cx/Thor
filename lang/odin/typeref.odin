// Reading a Type_Ref out of written-down type syntax — a `(type ...)` node, or
// the text of a proc signature's parameter and result lists.
package odin

import "core:strings"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// Reads a `(type ...)` node (or a bare type construct) into a Type_Ref. Unwraps a
// pointer type (`^T` — Odin auto-derefs on `.`), reads a package-qualified `pkg.T`
// (a `field_type`), keeps a proc type's signature (a proc names no type, so only
// calling it yields one), and records the containers around a named element type:
// the grammar spells `[]T`, `[N]T` and `[dynamic]T` all as `array_type` (the
// element is the last named child), `map[K]V` as `map_type` (key then value) and
// `bit_set[E]` as `bit_set_type` (the element inside the brackets, before an
// optional `; backing`). A container's own members are nothing this engine models,
// so it must be indexed or ranged over before its element's fields resolve.
// Containers nest up to CONTAINER_DEPTH_LIMIT; anything else returns false.
@(private)
type_ref_from_node :: proc(node: ts.Node, source: string) -> (Type_Ref, bool) {
    n := node
    if string(ts.node_type(n)) == "type" {
        n = ts.node_named_child(n, 0)
    }
    if ts.node_is_null(n) {
        return {}, false
    }
    switch string(ts.node_type(n)) {
    case "identifier":
        return Type_Ref{name = ts.node_text(n, source)}, true
    case "pointer_type":
        return type_ref_from_node(ts.node_named_child(n, 0), source)
    case "procedure_type":
        return Type_Ref{proc_sig = ts.node_text(n, source)}, true
    case "field_type":
        a := ts.node_named_child(n, 0)
        b := ts.node_named_child(n, 1)
        if is_identifier(a) && is_identifier(b) {
            return Type_Ref{pkg = ts.node_text(a, source), name = ts.node_text(b, source)}, true
        }
    case "array_type":
        count := ts.node_named_child_count(n)
        if count == 0 {
            return {}, false
        }
        return contained_type(ts.node_named_child(n, count - 1), source, Container_Layer{kind = .Array})
    case "map_type":
        if ts.node_named_child_count(n) < 2 {
            return {}, false
        }
        layer := Container_Layer{kind = .Map}
        if key, kok := type_ref_from_node(ts.node_named_child(n, 0), source); kok && type_is_bare(key) {
            layer.key = key.name
            layer.key_pkg = key.pkg
        }
        return contained_type(ts.node_named_child(n, 1), source, layer)
    case "bit_set_type":
        // The element leads the brackets; a `; u8` backing type follows it as a
        // `type` child, which is not what the set holds.
        return contained_type(ts.node_named_child(n, 0), source, Container_Layer{kind = .Bit_Set})
    }
    return {}, false
}

// The element type of a container, tagged with the container that holds it.
@(private)
contained_type :: proc(node: ts.Node, source: string, layer: Container_Layer) -> (Type_Ref, bool) {
    tr, ok := type_ref_from_node(node, source)
    if !ok {
        return {}, false
    }
    return wrap_container(tr, layer)
}

// A type named in *expression* position (a composite literal's type, `new`'s
// argument): `Point` or `pkg.Point`. Unlike type_ref_from_node the qualified form
// arrives as a member expression here, since the grammar parses it as a value.
@(private)
expr_type_name :: proc(node: ts.Node, source: string) -> (Type_Ref, bool) {
    if ts.node_is_null(node) {
        return {}, false
    }
    if is_identifier(node) {
        return Type_Ref{name = ts.node_text(node, source)}, true
    }
    switch string(ts.node_type(node)) {
    case "member_expression", "field_type":
        a := ts.node_named_child(node, 0)
        b := ts.node_named_child(node, 1)
        if is_identifier(a) && is_identifier(b) {
            return Type_Ref{pkg = ts.node_text(a, source), name = ts.node_text(b, source)}, true
        }
    case "pointer_type", "unary_expression":
        return expr_type_name(ts.node_named_child(node, 0), source)
    case "array_type", "map_type":
        // A container literal (`[]Point{...}`) names a container type.
        return type_ref_from_node(node, source)
    }
    return {}, false
}

// Type a call evaluates to: resolve the callee the same three ways signature help
// does (same file, `pkg.fn(...)`, workspace index) and read the result type out of
// its signature. `index` picks a slot out of a multi-value return. `new`/`new_clone`
// are answered directly — they are builtins with no declaration to find, and their
// result is the allocated type (a pointer, which `.` auto-dereferences anyway).
//
// A package-qualified result (`-> pkg.Point`) is qualified by the *callee's*
// imports, so the result carries the callee's path and visit_type_decl falls back
// to resolving `pkg` there when the requesting file doesn't import it the same way.
@(private)
call_result_type :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    call: ts.Node,
    index, depth: int,
) -> (Type_Ref, bool) {
    fn := ts.node_child_by_field_name(call, "function")
    if ts.node_is_null(fn) {
        return {}, false
    }
    if is_identifier(fn) {
        switch ts.node_text(fn, req.source) {
        case "new", "new_clone":
            arg := ts.node_child_by_field_name(call, "argument")
            if string(ts.node_type(arg)) == "struct" {
                arg = ts.node_named_child(arg, 0) // new_clone(Point{...})
            }
            return expr_type_name(arg, req.source)
        }
    }

    src, path, d, found := resolve_call_target(e, parser, root, req, call, fn)
    if !found || d.kind != "function" {
        // `cb(v)` — a call of a proc-typed *value*. No declaration names it, so
        // the result is read out of the signature its own type carries.
        if tr, ok := infer_expr_type(e, parser, root, req, fn, depth); ok && tr.proc_sig != "" {
            return proc_value_result(tr, index)
        }
        // `Point(v)` — a conversion is spelled exactly like a call, and only the
        // declaration behind the name separates the two. With no procedure of that
        // name in reach the name is read as the type converted to; if it names
        // nothing either, the lookup behind the Type_Ref comes up empty just the
        // same. A conversion yields one value, so a later slot is not one.
        if index != 0 {
            return {}, false
        }
        return conversion_type_name(call, fn, req.source)
    }
    tr, ok := proc_result_type(src, d, index)
    if !ok {
        return {}, false
    }
    // The result type is spelled in the callee's file, so that file's imports are
    // what qualify it (`-> other.Point`).
    tr.origin = path
    return tr, true
}

// The type a call-shaped conversion names: `Point(v)`, or `pkg.Point(v)`, whose
// qualifier sits on the member expression the call hangs under — the same place
// resolve_call_target reads a package-qualified callee from.
@(private)
conversion_type_name :: proc(call, fn: ts.Node, source: string) -> (Type_Ref, bool) {
    tr, ok := expr_type_name(fn, source)
    if !ok {
        return {}, false
    }
    if parent := ts.node_parent(call); !ts.node_is_null(parent) &&
        string(ts.node_type(parent)) == "member_expression" {
        pkg := ts.node_named_child(parent, 0)
        if same_node(ts.node_named_child(parent, 1), call) && is_identifier(pkg) {
            tr.pkg = ts.node_text(pkg, source)
        }
    }
    return tr, true
}

// lang.Result type of a procedure declaration, read out of its signature text: what
// follows `->`, or the `index`-th entry of a parenthesized result list. Text-based
// because a cross-file callee's parse tree is already gone by the time its Def
// comes back — only the file's source outlives it. `source` is whatever buffer the
// Def slices, so the Type_Ref lives exactly as long as its Def does.
@(private)
proc_result_type :: proc(source: string, d: Def, index: int) -> (Type_Ref, bool) {
    start := clamp(d.ident_start, 0, len(source))
    return signature_result_type(source[start:clamp(d.decl_end, start, len(source))], index)
}

// proc_result_type over signature text alone — what a proc *type* carries, having
// no declaration to slice out of a file.
@(private)
signature_result_type :: proc(sig: string, index: int) -> (Type_Ref, bool) {
    // Skip the parameter list first, so neither a nested `proc() -> int` parameter
    // nor a default composite value (`x: Point = Point{}`) is mistaken for this
    // procedure's own result or body. What is left is `-> results` plus the body.
    after, ok := after_paren_group(sig)
    if !ok {
        return {}, false
    }
    if brace := strings.index_byte(after, '{'); brace >= 0 {
        after = after[:brace]
    }
    arrow := strings.index(after, "->")
    if arrow < 0 {
        return {}, false // no results at all
    }
    results := strings.trim_space(after[arrow + 2:])

    if strings.has_prefix(results, "(") {
        inner, iok := after_paren_group(results, want_inner = true)
        if !iok {
            return {}, false
        }
        parts := split_top_level(inner)
        if index < 0 || index >= len(parts) {
            return {}, false
        }
        return result_type_ref(parts[index])
    }
    if index != 0 {
        return {}, false // a single result can only fill slot 0
    }
    return result_type_ref(results)
}

// Declared type of a procedure's `index`-th parameter, read out of its signature
// text — the same route proc_result_type takes, for the same reason (a cross-file
// callee's tree is gone by the time its Def comes back). Grouped parameters
// (`a, b: Axis`) write the type once, on the last name of the group, so a slot
// with no `:` of its own borrows the next slot that has one. A variadic tail
// (`rest: ..int`) answers for every argument past the fixed parameters.
@(private)
proc_param_type :: proc(source: string, d: Def, index: int) -> (Type_Ref, bool) {
    start := clamp(d.ident_start, 0, len(source))
    sig := source[start:clamp(d.decl_end, start, len(source))]

    inner, ok := after_paren_group(sig, want_inner = true)
    if !ok || index < 0 {
        return {}, false
    }
    parts := split_top_level(inner)
    if len(parts) == 0 {
        return {}, false
    }
    i := index
    if i >= len(parts) {
        // Nothing but a variadic tail takes more arguments than it has parameters.
        if !strings.contains(parts[len(parts) - 1], "..") {
            return {}, false
        }
        i = len(parts) - 1
    }
    for i < len(parts) && !strings.contains(parts[i], ":") {
        i += 1
    }
    if i >= len(parts) {
        return {}, false
    }
    return param_type_ref(parts[i])
}

// One parameter's type text (`a: Axis`, `rest: ..int`, `c: int = 3`, an unnamed
// `proc(a: int)`) as a Type_Ref: the name, the variadic marker and any default
// value are stripped, and what is left goes through result_type_ref — pointers,
// containers and package qualifiers are spelled the same way in both positions.
@(private)
param_type_ref :: proc(text: string) -> (Type_Ref, bool) {
    s := strip_result_name(strings.trim_space(text))
    s = strings.trim_space(strings.trim_prefix(s, ".."))
    if eq := strings.index_byte(s, '='); eq >= 0 {
        s = s[:eq]
    }
    return result_type_ref(s)
}

// Splits `text` on its top-level commas (ignoring those nested in brackets), for
// a result list. Temp-allocated.
@(private)
split_top_level :: proc(text: string) -> []string {
    parts := make([dynamic]string, context.temp_allocator)
    depth := 0
    start := 0
    for i in 0 ..< len(text) {
        switch text[i] {
        case '(', '[', '{':
            depth += 1
        case ')', ']', '}':
            depth -= 1
        case ',':
            if depth == 0 {
                append(&parts, text[start:i])
                start = i + 1
            }
        }
    }
    append(&parts, text[start:])
    return parts[:]
}

// Splits `text` at its first balanced bracket group: the text after the group's
// closing bracket, or — with `want_inner` — the text between the brackets. Quoted
// strings are skipped so a bracket inside a default value or a calling convention
// can't unbalance the scan.
@(private)
after_paren_group :: proc(text: string, want_inner := false) -> (string, bool) {
    depth := 0
    open := -1
    quote: u8 = 0
    for i := 0; i < len(text); i += 1 {
        c := text[i]
        if quote != 0 {
            switch c {
            case '\\':
                i += 1
            case quote:
                quote = 0
            }
            continue
        }
        switch c {
        case '"', '\'', '`':
            quote = c
        case '(':
            depth += 1
            if open < 0 {
                open = i
            }
        case ')':
            depth -= 1
            if depth == 0 && open >= 0 {
                return want_inner ? text[open + 1:i] : text[i + 1:], true
            }
            if depth < 0 {
                return "", false
            }
        }
    }
    return "", false
}

// One result's type text (`Point`, `p: ^Point`, `pkg.Point`, `[]Point`,
// `map[string][]Point`, `bit_set[Axis]`, `proc() -> Point`) as a Type_Ref: a named
// result drops its name, a pointer is dereferenced (Odin auto-dereferences `.`), a
// proc type keeps its signature, and each leading `[…]`/`map[…]`/`bit_set[…]`
// becomes one container around the element type. Anything else — a generic `$T`,
// a struct written out in place — is rejected rather than guessed, matching
// type_ref_from_node's reach. Text-based because a cross-file callee's tree is
// gone by now.
@(private)
result_type_ref :: proc(text: string) -> (Type_Ref, bool) {
    s := strip_result_name(strings.trim_space(text))

    // Outermost first, since that is the order they are written in; the element
    // is wrapped in the reverse order, innermost first.
    layers: [CONTAINER_DEPTH_LIMIT]Container_Layer
    count := 0
    for {
        for strings.has_prefix(s, "^") {
            s = strings.trim_space(s[1:])
        }
        if is_proc_signature(s) {
            return wrap_layers(Type_Ref{proc_sig = s}, layers[:count])
        }
        layer: Container_Layer
        rest: string
        switch {
        case strings.has_prefix(s, "map["):
            inner, after, ok := bracket_group(s[3:])
            if !ok {
                return {}, false
            }
            layer = Container_Layer{kind = .Map}
            if key, kok := plain_type_ref(strings.trim_space(inner)); kok {
                layer.key = key.name
                layer.key_pkg = key.pkg
            }
            rest = after
        case strings.has_prefix(s, "bit_set["):
            // The set holds what is inside the brackets, and what follows them is
            // nothing — so a bit_set ends the walk rather than continuing it.
            inner, _, ok := bracket_group(s[7:])
            if !ok {
                return {}, false
            }
            if semi := strings.index_byte(inner, ';'); semi >= 0 {
                inner = inner[:semi] // `bit_set[Axis; u8]` — a backing type, not the element
            }
            elem, eok := plain_type_ref(strings.trim_space(inner))
            if !eok || count >= CONTAINER_DEPTH_LIMIT {
                return {}, false
            }
            layers[count] = Container_Layer{kind = .Bit_Set}
            count += 1
            return wrap_layers(elem, layers[:count])
        case strings.has_prefix(s, "["):
            _, after, ok := bracket_group(s)
            if !ok {
                return {}, false
            }
            layer = Container_Layer{kind = .Array}
            rest = after
        case:
            // A trailing tail (`Point ---` on a foreign proc, a comment) is not
            // part of the type; a container's brackets never hold a bare space.
            if space := strings.index_proc(s, strings.is_space); space >= 0 {
                s = s[:space]
            }
            tr, ok := plain_type_ref(s)
            if !ok {
                return {}, false
            }
            return wrap_layers(tr, layers[:count])
        }
        if count >= CONTAINER_DEPTH_LIMIT {
            return {}, false
        }
        layers[count] = layer
        count += 1
        s = strings.trim_space(rest)
    }
}

// `tr` wrapped in `layers`, which are ordered outermost first.
@(private = "file")
wrap_layers :: proc(tr: Type_Ref, layers: []Container_Layer) -> (Type_Ref, bool) {
    out := tr
    #reverse for layer in layers {
        ok: bool
        if out, ok = wrap_container(out, layer); !ok {
            return {}, false
        }
    }
    return out, true
}

// A named result or parameter without its name (`p: ^Point` → `^Point`). Only a
// colon ahead of every bracket separates a name — one inside `proc(a: int)`
// belongs to that signature.
@(private = "file")
strip_result_name :: proc(s: string) -> string {
    for i in 0 ..< len(s) {
        switch s[i] {
        case ':':
            return strings.trim_space(s[i + 1:])
        case '(', '[', '{':
            return s
        }
    }
    return s
}

// Whether the text spells a procedure type (`proc()`, `proc "c" (a: int)`) rather
// than naming one — the one type whose members are reached by calling it.
@(private = "file")
is_proc_signature :: proc(s: string) -> bool {
    if !strings.has_prefix(s, "proc") {
        return false
    }
    rest := s[4:]
    return rest == "" || rest[0] == '(' || rest[0] == ' ' || rest[0] == '"'
}

// A balanced `[...]` group at the head of `text` (a container's key, length or
// element): what it holds and what follows it. Nested brackets are counted, so
// `map[[2]int]Point` still lands on `Point`.
@(private)
bracket_group :: proc(text: string) -> (inner, rest: string, ok: bool) {
    if !strings.has_prefix(text, "[") {
        return "", "", false
    }
    depth := 0
    for i in 0 ..< len(text) {
        switch text[i] {
        case '[':
            depth += 1
        case ']':
            depth -= 1
            if depth == 0 {
                return text[1:i], text[i + 1:], true
            }
        }
    }
    return "", "", false
}

// A bare — optionally package-qualified — type name as a Type_Ref.
@(private)
plain_type_ref :: proc(s: string) -> (Type_Ref, bool) {
    if dot := strings.index_byte(s, '.'); dot >= 0 {
        if is_plain_name(s[:dot]) && is_plain_name(s[dot + 1:]) {
            return Type_Ref{pkg = s[:dot], name = s[dot + 1:]}, true
        }
        return {}, false
    }
    if !is_plain_name(s) {
        return {}, false
    }
    return Type_Ref{name = s}, true
}

// Whether `s` is a bare identifier — the only shape a nominal type name takes.
@(private)
is_plain_name :: proc(s: string) -> bool {
    if s == "" || (s[0] >= '0' && s[0] <= '9') {
        return false
    }
    for i in 0 ..< len(s) {
        if !is_ident_byte(s[i]) {
            return false
        }
    }
    return true
}
