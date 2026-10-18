// Polymorphic (`$T`) call-result inference: a call's result when the callee's
// declared result reuses one of its own polymorphic parameters. Text-based,
// same reason as typeref.odin's own signature readers — a cross-file callee's
// tree is already gone by the time its Def comes back, only the source text
// survives.
package odin

import "core:strings"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// A parameter's or a result's type text, peeled down to its leaf: how many `^`
// wrap it, and the container stack around that — the same grammar
// result_type_ref walks (`map[K]`, `bit_set[E]`, `[]`/`[N]`/`[dynamic]`,
// `#soa`), outermost first. Kept separate from result_type_ref, which resolves
// a concrete leaf eagerly at each step (bit_set returns early, map reads its
// key inline); this defers leaf handling to the caller instead, since the leaf
// may be a polymorphic name (`$T`, on a parameter) or a plain name (`T`, on a
// result) — two different questions the two callers ask of the same shape.
@(private)
Poly_Shape :: struct {
    pointers:   int,
    containers: [CONTAINER_DEPTH_LIMIT]Container_Layer, // outermost first
    depth:      int,
    generic:    bool, // the name is one argument of a generic type (`List($T)`)
    arg_slot:   int,  // which argument, when generic
}

// Walks `text`'s pointer and container prefixes into a Poly_Shape and returns
// what is left: the leaf text, with a trailing tail past it (a `where` clause,
// a foreign proc's `---`) dropped the same way result_type_ref's own default
// case drops one.
@(private)
peel_poly_shape :: proc(text: string) -> (shape: Poly_Shape, leaf: string, ok: bool) {
    pointers, layers, depth, l, _, pok := peel_containers(
        text,
        limit_pointers = true,
        stop_at_proc = false,
    )
    if !pok {
        return {}, "", false
    }
    return Poly_Shape{pointers = pointers, containers = layers, depth = depth}, l, true
}

// The arguments of a generic type leaf (`List(int, $T)`), each trimmed.
// Temp-allocated.
@(private)
generic_leaf_args :: proc(leaf: string) -> ([]string, bool) {
    open := strings.index_byte(leaf, '(')
    if open <= 0 || leaf[len(leaf) - 1] != ')' {
        return nil, false
    }
    if _, ok := plain_type_ref(strings.trim_space(leaf[:open])); !ok {
        return nil, false
    }
    parts := split_top_level(leaf[open + 1:len(leaf) - 1])
    for &part in parts {
        part = strings.trim_space(part)
    }
    return parts, true
}

// Where `name` sits among a generic leaf's arguments, written bare or as `$name`.
@(private)
generic_arg_slot :: proc(leaf, name: string) -> (int, bool) {
    args, ok := generic_leaf_args(leaf)
    if !ok {
        return 0, false
    }
    for arg, i in args {
        if strings.trim_prefix(arg, "$") == name {
            return i, true
        }
    }
    return 0, false
}

// A parameter's type text without its name, a variadic `..` marker or a
// default value — the same preprocessing param_type_ref applies before
// resolving a concrete type, needed here before peeling a possibly-`$`
// leaf instead.
@(private)
strip_param_decorations :: proc(text: string) -> string {
    s := strip_result_name(strings.trim_space(text))
    s = strings.trim_space(strings.trim_prefix(s, ".."))
    if eq := strings.index_byte(s, '='); eq >= 0 {
        s = strings.trim_space(s[:eq])
    }
    return s
}

// One polymorphic name a signature declares: its own name, the index of the
// parameter that binds it at a call site, and the shape (pointers/containers)
// wrapping it there.
@(private)
Poly_Binding :: struct {
    name:     string,
    index:    int,
    shape:    Poly_Shape,
    explicit: bool, // bound by the type written at its own `$T: typeid` slot
}

// Whether one parameter's text (`v: $T`, `xs: []$T`, `l: ^$T`) declares a bare
// `$Name`, optionally wrapped in pointers/containers — the inline generic
// shorthand, as against the explicit `$Name: typeid` form
// (explicit_poly_name), whose leading parameter's type is `typeid`, not `$T`.
@(private)
poly_param_shape :: proc(text: string) -> (name: string, shape: Poly_Shape, ok: bool) {
    peeled, leaf, sok := peel_poly_shape(strip_param_decorations(text))
    if !sok {
        return "", {}, false
    }
    if !strings.has_prefix(leaf, "$") {
        // `l: List($T)` binds T to the argument of the List the call passes.
        args, gok := generic_leaf_args(leaf)
        if !gok {
            return "", {}, false
        }
        for arg, i in args {
            if strings.has_prefix(arg, "$") && valid_identifier(arg[1:]) {
                peeled.generic = true
                peeled.arg_slot = i
                return arg[1:], peeled, true
            }
        }
        return "", {}, false
    }
    name = leaf[1:]
    if !valid_identifier(name) {
        return "", {}, false
    }
    return name, peeled, true
}

// Whether one parameter's text (`$T: typeid`, `$T: typeid/int`) declares a
// name as a polymorphic type parameter through the explicit form: the
// parameter's own *name* carries the `$`, and its type is `typeid` or
// `typeid/` followed by a specialization this proc does not read further —
// recognized as a valid binding site, never validated (see generics.odin's
// package doc and lang/ROADMAP.md for why constraint checking stays out of
// scope). A bare `$Name: SomeType` with no `typeid` is a compile-time *value*
// parameter (`$N: int`), not a type parameter, and is deliberately not
// matched here.
@(private)
explicit_poly_name :: proc(text: string) -> (string, bool) {
    colon := strings.index_byte(text, ':')
    if colon < 0 {
        return "", false
    }
    name := strings.trim_space(text[:colon])
    if !strings.has_prefix(name, "$") || !valid_identifier(name[1:]) {
        return "", false
    }
    typ := strings.trim_space(text[colon + 1:])
    if typ != "typeid" && !strings.has_prefix(typ, "typeid/") {
        return "", false
    }
    return name[1:], true
}

// Every polymorphic name `sig`'s parameter list declares, with the parameter
// index and shape that binds each one at a call site. A name declared by the
// explicit `$Name: typeid` form supplies no shape at its own parameter, so a
// second pass finds it from the first later parameter whose peeled leaf reads
// as that bare name, or as an argument of a generic type (`l: List(T)`) —
// exactly how Odin itself infers `$T: typeid` from a later parameter's usage
// when a caller passes no type argument explicitly. A declared name with no
// such usage is bound by the type the call writes at its own slot.
// Temp-allocated.
@(private)
polymorphic_params :: proc(sig: string) -> []Poly_Binding {
    inner, iok := after_paren_group(sig, want_inner = true)
    if !iok {
        return nil
    }
    parts := split_top_level(inner)

    bindings := make([dynamic]Poly_Binding, context.temp_allocator)
    for part, i in parts {
        if name, shape, pok := poly_param_shape(part); pok {
            append(&bindings, Poly_Binding{name = name, index = i, shape = shape})
        } else if explicit, eok := explicit_poly_name(part); eok {
            append(&bindings, Poly_Binding{name = explicit, index = i, explicit = true})
        }
    }

    for &b in bindings {
        if !b.explicit {
            continue
        }
        for part, i in parts {
            shape, leaf, sok := peel_poly_shape(strip_param_decorations(part))
            if !sok {
                continue
            }
            if leaf == b.name {
                b.index, b.shape, b.explicit = i, shape, false
                break
            }
            if slot, gok := generic_arg_slot(leaf, b.name); gok {
                shape.generic = true
                shape.arg_slot = slot
                b.index, b.shape, b.explicit = i, shape, false
                break
            }
        }
    }
    return bindings[:]
}

// Every polymorphic name `sig`'s parameter list declares, found by scanning its
// text for `$Name`. A lexical scan rather than a composition of poly_param_shape
// and explicit_poly_name, because those two read only the shapes they resolve a
// *binding* from: `map[$K]$V` peels to the leaf `$V` alone, `[$N]f32` holds its
// `$N` inside the brackets, and `List($T)` matches neither — each of which would
// leave a later `k: K` reading as an ordinary type named `K` and rejecting the
// member that declared it. A default value is cut first, so a `$` written in one
// is never collected. Temp-allocated.
@(private)
signature_poly_names :: proc(sig: string) -> []string {
    if !strings.contains(sig, "$") {
        return nil
    }
    inner, ok := after_paren_group(sig, want_inner = true)
    if !ok {
        return nil
    }
    names := make([dynamic]string, context.temp_allocator)
    for part in split_top_level(inner) {
        s := part
        if eq := strings.index_byte(s, '='); eq >= 0 {
            s = s[:eq]
        }
        for i in 0 ..< len(s) {
            if s[i] != '$' {
                continue
            }
            end := i + 1
            for end < len(s) && is_ident_byte(s[end]) {
                end += 1
            }
            if name := s[i + 1:end]; valid_identifier(name) {
                append(&names, name)
            }
        }
    }
    return names[:]
}

// Whether a parameter's text names a type this engine cannot pin down: it declares
// a polymorphic name itself, or it uses one the same signature declared. Such a
// slot is no evidence either way — never matched, never rejected. A constraint
// (`$T: typeid/Ordered`) is not read: only the binding site is recognized, so a
// constraint can cost narrowing but can never narrow wrongly.
@(private)
param_text_is_poly :: proc(text: string, poly: []string) -> bool {
    if len(poly) == 0 {
        return false
    }
    if strings.contains(text, "$") {
        return true
    }
    _, leaf, ok := peel_poly_shape(strip_param_decorations(text))
    if !ok {
        return false
    }
    for name in poly {
        if name == leaf {
            return true
        }
        if _, used := generic_arg_slot(leaf, name); used {
            return true
        }
    }
    return false
}

// Which of `bindings`, if any, parameter slot `index` uses, and what wraps it
// there — the parameter-list twin of result_poly_use, for narrowing a procedure
// group by an argument written against a `T` an earlier slot bound.
@(private)
param_poly_use :: proc(
    sig: string,
    bindings: []Poly_Binding,
    index: int,
) -> (
    shape: Poly_Shape,
    binding: Poly_Binding,
    ok: bool,
) {
    text, tok := signature_param_text(sig, index)
    if !tok {
        return {}, {}, false
    }
    leaf_shape, leaf, sok := peel_poly_shape(strip_param_decorations(text))
    if !sok {
        return {}, {}, false
    }
    for b in bindings {
        if b.name == leaf {
            return leaf_shape, b, true
        }
    }
    return {}, {}, false
}

// The type `binding` is bound to at this call: the argument filling its parameter
// slot, with the container layers that parameter wraps the name in unwrapped off,
// and for a generic parameter (`l: List($T)`) the matching argument of the type
// passed. An explicit `$T: typeid` slot names the type outright.
@(private)
poly_binding_value :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    call: ts.Node,
    binding: Poly_Binding,
    depth: int,
) -> (Type_Ref, bool) {
    arg := call_argument(call, binding.index)
    if ts.node_is_null(arg) {
        return {}, false
    }
    if binding.explicit {
        return expr_type_name(arg, req.source)
    }
    tr, ok := infer_expr_result(e, parser, root, req, arg, 0, depth + 1)
    if !ok {
        return {}, false
    }
    for _ in 0 ..< binding.shape.depth {
        elem, _, uok := unwrap_container(tr)
        if !uok {
            return {}, false
        }
        tr = elem
    }
    if !binding.shape.generic {
        return tr, true
    }
    if tr.type_args == "" {
        return {}, false
    }
    parts := split_top_level(tr.type_args)
    if binding.shape.arg_slot >= len(parts) {
        return {}, false
    }
    sub, sok := result_type_ref(strings.trim_space(parts[binding.shape.arg_slot]))
    if !sok {
        return {}, false
    }
    sub.origin = type_args_of(tr, req.path).origin
    return sub, true
}

// The type argument written at an explicit binding slot (`identity2(int, v)` for
// `proc($T: typeid, v: T)`). The argument there *names* a type rather than being a
// value of one, so it is read with expr_type_name instead of being inferred.
@(private)
explicit_type_argument :: proc(
    sig: string,
    source: string,
    call: ts.Node,
    index: int,
) -> (
    name: string,
    tr: Type_Ref,
    ok: bool,
) {
    text, tok := signature_param_text(sig, index)
    if !tok {
        return "", {}, false
    }
    bound, eok := explicit_poly_name(text)
    if !eok {
        return "", {}, false
    }
    arg := call_argument(call, index)
    if ts.node_is_null(arg) {
        return "", {}, false
    }
    named, nok := expr_type_name(arg, source)
    if !nok {
        return "", {}, false
    }
    return bound, named, true
}

// Which of `bindings`, if any, result slot `index` uses, and what wraps it
// there. Splits the (possibly tupled) result list the same way
// signature_result_type does, peels that slot's text, and matches its bare
// leaf against a known binding's name — a result never carries `$` itself,
// only reuses a name a parameter already bound.
@(private)
result_poly_use :: proc(
    sig: string,
    bindings: []Poly_Binding,
    index: int,
) -> (
    shape: Poly_Shape,
    binding: Poly_Binding,
    ok: bool,
) {
    text, tok := result_slot_text(sig, index)
    if !tok {
        return {}, {}, false
    }
    leaf_shape, leaf, sok := peel_poly_shape(text)
    if !sok {
        return {}, {}, false
    }
    for b in bindings {
        if b.name == leaf {
            return leaf_shape, b, true
        }
    }
    return {}, {}, false
}

// A call's result when the callee's result uses its own `$` parameters:
// `proc(v: $T) -> T`, containers on either side (`[]$T -> T`, `$T -> []T`), tuples
// of several names, `$T: typeid`, and generic types on either side (`l: List($T)`,
// `-> List(T)`). The bound argument's type is unwrapped by the parameter's layers
// and wrapped by the result's; pointers are skipped. Constraints are not checked.
// `path` is the callee's file.
@(private)
polymorphic_call_result :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    call: ts.Node,
    source, path: string,
    d: Def,
    index, depth: int,
) -> (Type_Ref, bool) {
    start := clamp(d.ident_start, 0, len(source))
    sig := source[start:clamp(d.decl_end, start, len(source))]
    if !strings.contains(sig, "$") {
        return {}, false
    }
    bindings := polymorphic_params(sig)
    if len(bindings) == 0 {
        return {}, false
    }
    result_shape, binding, rok := result_poly_use(sig, bindings, index)
    if !rok {
        return generic_call_result(e, parser, root, req, call, sig, path, bindings, index, depth)
    }
    arg_tr, aok := poly_binding_value(e, parser, root, req, call, binding, depth)
    if !aok {
        return {}, false
    }
    return wrap_layers(arg_tr, result_shape.containers[:result_shape.depth])
}

// The text of result slot `index` of `sig`, its name dropped.
@(private)
result_slot_text :: proc(sig: string, index: int) -> (string, bool) {
    after, aok := after_paren_group(sig)
    if !aok {
        return "", false
    }
    if brace := strings.index_byte(after, '{'); brace >= 0 {
        after = after[:brace]
    }
    arrow := strings.index(after, "->")
    if arrow < 0 {
        return "", false
    }
    results := strings.trim_space(after[arrow + 2:])
    if !strings.has_prefix(results, "(") {
        return results, index == 0
    }
    inner, rok := after_paren_group(results, want_inner = true)
    if !rok {
        return "", false
    }
    parts := split_top_level(inner)
    if index < 0 || index >= len(parts) {
        return "", false
    }
    return strip_result_name(strings.trim_space(parts[index])), true
}

// A call's result written as a generic type over the callee's own names
// (`-> List(T)`): the type with each name replaced by what the call binds it to.
// Fails when the result uses a name the call does not bind.
@(private = "file")
generic_call_result :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    call: ts.Node,
    sig, path: string,
    bindings: []Poly_Binding,
    index, depth: int,
) -> (Type_Ref, bool) {
    text, tok := result_slot_text(sig, index)
    if !tok {
        return {}, false
    }
    tr, rok := result_type_ref(text)
    if !rok || tr.type_args == "" {
        return {}, false
    }
    args := tr.type_args
    changed := false
    for b in bindings {
        if _, used := substitute_names(args, {b.name}, {""}); !used {
            continue
        }
        bound, bok := poly_binding_value(e, parser, root, req, call, b, depth)
        if !bok {
            return {}, false
        }
        args, _ = substitute_names(args, {b.name}, {type_ref_text(bound)})
        changed = true
    }
    if !changed {
        return {}, false
    }
    tr.type_args = args
    tr.origin = path
    tr.args_origin = req.path
    return tr, true
}
