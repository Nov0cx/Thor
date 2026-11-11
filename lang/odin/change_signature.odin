// Change signature: a new parameter list for a procedure, with every call of it rewritten to match.
package odin

import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// One parameter name of a parameter list. Strings borrow the parsed source.
@(private = "file")
Sig_Param :: struct {
    name:        string, // without `$`
    name_offset: int,
    type_text:   string, // "" when the parameter has only a default
    default:     string, // "" when none
    variadic:    bool,
}

// The state of one change, shared with the reference visitor.
@(private = "file")
Sig_Change :: struct {
    rc:          ^Request_Context,
    name:        string,
    old:         []Sig_Param,
    new:         []Sig_Param,
    from_old:    []int, // per new parameter: its old index, -1 for a new one
    decl_offset: int,   // the name offset of the declaration in the buffer
    list_start:  int,   // the text between the parentheses of the declaration's parameter list
    list_end:    int,
    list_text:   string,
    edits:       [dynamic]File_Edit,
    allocator:   mem.Allocator, // outlives the temp guard of each scanned file
    reason:      string,
}

// The file-scope procedure of the buffer that the caret names, and its procedure literal.
@(private = "file")
target_proc :: proc(rc: ^Request_Context) -> (target: Ref_Target, lit: odinsyntax.Syntax_Node, ok: bool) {
    target = ref_target(rc)
    if target.kind != .Package_Item || target.path == "" || odinsema.path_key(target.path) != rc.live.key || !rename_allowed(rc, target) {
        return
    }
    for &item in rc.live.tree.items {
        if item.name_offset != target.decl || item.kind != .Proc || item.value_offset < 0 || item.in_foreign {
            continue
        }
        tok, found := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(item.value_offset), context.temp_allocator)
        if !found {
            return
        }
        for n := tok.parent; n != nil; n = n.parent {
            if n.green.kind == .Proc_Lit && int(n.offset) == item.value_offset {
                return target, n^, true
            }
        }
    }
    return
}

// The parameter list of a procedure literal.
@(private = "file")
lit_params :: proc(lit: ^odinsyntax.Syntax_Node) -> (odinsyntax.Param_List, bool) {
    pl, _        := odinsyntax.as_proc_lit(lit^)
    pt, has_type := odinsyntax.proc_lit_type(&pl)
    if !has_type {
        return {}, false
    }
    // The views borrow `pt`, so the list is rebuilt without its parent pointer.
    list, ok := odinsyntax.proc_type_params(&pt)
    if !ok {
        return {}, false
    }
    list.parent = nil
    return list, true
}

// Offers "Change signature" on a file-scope procedure of the buffer.
@(private)
change_signature_offer :: proc(rc: ^Request_Context, res: ^lang.Result) {
    _, lit, ok := target_proc(rc)
    if !ok {
        return
    }
    list, has_list := lit_params(&lit)
    if !has_list {
        return
    }
    if _, flat_ok := flatten_params(list); !flat_ok {
        return
    }
    sb   := strings.builder_make(context.temp_allocator)
    toks := make([dynamic]Label_Token, context.temp_allocator)
    write_label_tokens(&sb, odinsyntax.Syntax_Node(list), &toks)
    text := strings.to_string(sb)
    text = strings.trim_suffix(strings.trim_prefix(text, "("), ")")
    push_prompt_action(res, "Change signature", ACTION_CHANGE_SIGNATURE, "Parameters", text)
}

// One entry per parameter name of `list`. False when a parameter has no name.
@(private = "file")
flatten_params :: proc(list: odinsyntax.Param_List) -> ([]Sig_Param, bool) {
    out  := make([dynamic]Sig_Param, context.temp_allocator)
    list := list
    it   := odinsyntax.param_list_fields(&list)
    for fnode in odinsyntax.child_iter_next(&it) {
        field, _         := odinsyntax.as_field(fnode)
        names, has_names := odinsyntax.field_names(&field)
        if !has_names {
            return nil, false
        }
        p: Sig_Param
        if t, has_type := odinsyntax.field_type(&field); has_type {
            p.type_text = odinsyntax.node_text(t)
            p.variadic = t.green.kind == .Ellipsis_Type
        }
        if d, has_default := odinsyntax.field_default(&field); has_default {
            p.default = odinsyntax.node_text(d)
        }
        nit := odinsyntax.name_list_names(&names)
        for name in odinsyntax.child_iter_next(&nit) {
            q := p
            q.name = odinsyntax.node_text(name)
            q.name_offset = int(name.offset)
            if pt, is_poly := odinsyntax.as_poly_type(name); is_poly {
                ident, has_ident := odinsyntax.poly_type_name(&pt)
                if !has_ident {
                    return nil, false
                }
                q.name = odinsyntax.node_text(odinsyntax.Syntax_Node(ident))
                q.name_offset = int(ident.offset)
            }
            append(&out, q)
        }
    }
    return out[:], true
}

// The parameters of the parameter list `text`; "" as the reason when it parses.
@(private = "file")
parse_params :: proc(text: string) -> (params: []Sig_Param, parsed: odinsyntax.Parse, reason: string) {
    src := fmt.tprintf("package p\n_ :: proc(%s) {{}}\n", text)
    err: mem.Allocator_Error
    parsed, err = odinsyntax.parse(src, context.temp_allocator)
    if err != nil {
        return nil, {}, "out of memory"
    }
    if len(parsed.errors) > 0 {
        return nil, parsed, "not a parameter list"
    }
    lit, found := first_of_kind(odinsyntax.node_root(parsed.tree), .Proc_Lit)
    if !found {
        return nil, parsed, "not a parameter list"
    }
    list, has_list := lit_params(&lit)
    if !has_list {
        return nil, parsed, "not a parameter list"
    }
    flat, ok := flatten_params(list)
    if !ok {
        return nil, parsed, "every parameter needs a name"
    }
    return flat, parsed, ""
}

// The first node of `kind` at or under `n`, in source order.
@(private = "file")
first_of_kind :: proc(n: odinsyntax.Syntax_Node, kind: odinsyntax.Syntax_Kind) -> (odinsyntax.Syntax_Node, bool) {
    if n.green.kind == kind {
        found := n
        found.parent = nil
        return found, true
    }
    n  := n
    it := odinsyntax.child_iter(&n, {kinds = ALL_NODES})
    for c in odinsyntax.child_iter_next(&it) {
        if found, ok := first_of_kind(c, kind); ok {
            return found, true
        }
    }
    return {}, false
}

@(private = "file")
param_index :: proc(params: []Sig_Param, name: string) -> int {
    for p, i in params {
        if p.name == name {
            return i
        }
    }
    return -1
}

// The edits that give the procedure under the caret the parameter list `text` and rewrite its calls.
// Strings of the edits live in `allocator`.
@(private)
change_signature_edits :: proc(rc: ^Request_Context, text: string, allocator: mem.Allocator) -> ([]File_Edit, string) {
    target, lit, ok := target_proc(rc)
    if !ok {
        return nil, "the caret is not on a procedure of this file"
    }
    list, has_list := lit_params(&lit)
    if !has_list {
        return nil, "the procedure has no parameter list"
    }
    old, old_ok := flatten_params(list)
    if !old_ok {
        return nil, "every parameter needs a name"
    }
    new, parsed, reason := parse_params(text)
    defer odinsyntax.parse_destroy(&parsed, context.temp_allocator)
    if reason != "" {
        return nil, reason
    }
    from_old := make([]int, len(new), context.temp_allocator)
    for p, i in new {
        if param_index(new[:i], p.name) >= 0 {
            return nil, fmt.tprintf("'%s' is declared twice", p.name)
        }
        if p.variadic && i != len(new) - 1 {
            return nil, "only the last parameter can be variadic"
        }
        from_old[i] = param_index(old, p.name)
    }
    for p in old {
        if param_index(new, p.name) >= 0 {
            continue
        }
        uses, err := odinsema.local_references(rc.parsed, p.name_offset, context.temp_allocator)
        if err != nil {
            return nil, "out of memory"
        }
        for u in uses {
            if u != p.name_offset {
                return nil, fmt.tprintf("'%s' is used in the body", p.name)
            }
        }
    }
    ls, le := odinsyntax.node_range(odinsyntax.Syntax_Node(list))
    sc     := Sig_Change{
        rc = rc,
        name = target.name,
        old = old,
        new = new,
        from_old = from_old,
        decl_offset = target.decl,
        list_start = int(ls) + 1,
        list_end = int(le) - 1,
        list_text = strings.trim_space(text),
        edits = make([dynamic]File_Edit, allocator),
        allocator = allocator,
    }
    if !visit_references(rc, target, true, visit_sig_file, &sc) {
        if sc.reason != "" {
            return nil, sc.reason
        }
        return nil, "cancelled"
    }
    if sc.reason != "" {
        return nil, sc.reason
    }
    if len(sc.edits) == 0 {
        return nil, "nothing to change"
    }
    return sc.edits[:], ""
}

// Where a hit lies, as `file:line`.
@(private = "file")
hit_place :: proc(f: Ref_File, offset: int) -> string {
    line, _ := offset_line_col(f.lines, offset)
    return fmt.tprintf("%s:%d", filepath.base(f.path), line)
}

// Adds the edits of one file: the declaration's parameter list and each call's arguments.
@(private = "file")
visit_sig_file :: proc(data: rawptr, f: Ref_File) -> bool {
    sc        := cast(^Sig_Change)data
    in_buffer := odinsema.path_key(f.path) == sc.rc.live.key
    source    := ""
    root      := odinsyntax.node_root(f.parsed.tree)
    for offset in f.hits {
        tok, found := odinsyntax.node_token_at(root, u32(offset), context.temp_allocator)
        if !found || tok.parent == nil {
            continue
        }
        ident := tok.parent
        if ident.parent != nil && (ident.parent.green.kind == .Name_List || ident.parent.green.kind == .Poly_Type) {
            if !in_buffer || offset != sc.decl_offset {
                sc.reason = fmt.aprintf("'%s' is also declared at %s", sc.name, hit_place(f, offset), allocator = sc.allocator)
                return false
            }
            if strings.trim_space(f.source[sc.list_start:sc.list_end]) != sc.list_text {
                append_sig_edit(sc, f, &source, sc.list_start, sc.list_end, sc.list_text)
            }
            continue
        }
        call, is_call := callee_call_of(ident)
        if !is_call {
            sc.reason = fmt.aprintf("'%s' is used as a value at %s", sc.name, hit_place(f, offset), allocator = sc.allocator)
            return false
        }
        if !rewrite_call(sc, f, &source, call) {
            return false
        }
    }
    return true
}

// The call whose callee is `ident`, bare or as the field of `pkg.name`.
@(private = "file")
callee_call_of :: proc(ident: ^odinsyntax.Syntax_Node) -> (odinsyntax.Syntax_Node, bool) {
    callee := ident
    if p := ident.parent; p != nil && p.green.kind == .Selector_Expr {
        sel, _           := odinsyntax.as_selector_expr(p^)
        field, has_field := odinsyntax.selector_expr_field(&sel)
        if !has_field || field.offset != ident.offset {
            return {}, false
        }
        callee = p
    }
    parent := callee.parent
    if parent == nil || parent.green.kind != .Call_Expr {
        return {}, false
    }
    ce, _         := odinsyntax.as_call_expr(parent^)
    c, has_callee := odinsyntax.call_expr_callee(&ce)
    if !has_callee || c.offset != callee.offset || c.green != callee.green {
        return {}, false
    }
    return parent^, true
}

// Appends one edit of `f`; `source` is the copy of the file's text the edits of this file share.
@(private = "file")
append_sig_edit :: proc(sc: ^Sig_Change, f: Ref_File, source: ^string, start, end: int, text: string) {
    if source^ == "" {
        source^ = strings.clone(f.source, sc.allocator)
    }
    append(
        &sc.edits,
        File_Edit{path = strings.clone(f.path, sc.allocator), source = source^, start = start, end = end, text = strings.clone(text, sc.allocator)},
    )
}

// One argument of the rewritten call.
@(private = "file")
Sig_Arg :: struct {
    text:      string,
    name:      string,
    named:     bool,
    droppable: bool, // a default the new declaration also has
}

// Rewrites the arguments of `call` to the new parameter order.
@(private = "file")
rewrite_call :: proc(sc: ^Sig_Change, f: Ref_File, source: ^string, call: odinsyntax.Syntax_Node) -> bool {
    call           := call
    ce, _          := odinsyntax.as_call_expr(call)
    args, has_args := odinsyntax.call_expr_args(&ce)
    if !has_args {
        return true
    }
    as, ae := odinsyntax.node_range(odinsyntax.Syntax_Node(args))
    if ae - as < 2 || f.source[ae - 1] != ')' {
        sc.reason = fmt.aprintf("the call at %s is not closed", hit_place(f, int(call.offset)), allocator = sc.allocator)
        return false
    }
    old   := sc.old
    fixed := len(old)
    if fixed > 0 && old[fixed - 1].variadic {
        fixed -= 1
    }
    bound := make([]string, len(old), context.temp_allocator)
    named := make([]bool, len(old), context.temp_allocator)
    rest  := make([dynamic]string, context.temp_allocator)
    pos   := 0
    it    := odinsyntax.arg_list_args(&args)
    for a in odinsyntax.child_iter_next(&it) {
        if fv, is_named := odinsyntax.as_field_value(a); is_named {
            n, has_name  := odinsyntax.field_value_name(&fv)
            v, has_value := odinsyntax.field_value_value(&fv)
            idx          := param_index(old, odinsyntax.node_text(n))
            if !has_name || !has_value || idx < 0 {
                sc.reason = fmt.aprintf("the call at %s names an unknown parameter", hit_place(f, int(a.offset)), allocator = sc.allocator)
                return false
            }
            bound[idx], named[idx] = odinsyntax.node_text(v), true
            continue
        }
        if pos < fixed && a.green.kind != .Spread_Expr {
            bound[pos] = odinsyntax.node_text(a)
            pos += 1
        } else if fixed < len(old) {
            append(&rest, odinsyntax.node_text(a))
        } else {
            sc.reason = fmt.aprintf("the call at %s has too many arguments", hit_place(f, int(a.offset)), allocator = sc.allocator)
            return false
        }
    }
    for i in 0 ..< fixed {
        if bound[i] == "" && old[i].default == "" {
            sc.reason = fmt.aprintf("the call at %s passes several values from one call", hit_place(f, int(call.offset)), allocator = sc.allocator)
            return false
        }
    }

    out        := make([dynamic]Sig_Arg, context.temp_allocator)
    named_mode := false
    for p, i in sc.new {
        oi := sc.from_old[i]
        if p.variadic && oi >= 0 && !named[oi] {
            if named_mode && len(rest) > 0 {
                sc.reason = fmt.aprintf("the call at %s would pass variadic values after a named one", hit_place(f, int(call.offset)), allocator = sc.allocator)
                return false
            }
            for r in rest {
                append(&out, Sig_Arg{text = r})
            }
            continue
        }
        arg := Sig_Arg{name = p.name}
        switch {
        case oi >= 0 && bound[oi] != "":
            arg.text, arg.named = bound[oi], named[oi]
        case oi >= 0:
            arg.text, arg.droppable = old[oi].default, p.default != ""
        case p.default != "":
            arg.text, arg.droppable = p.default, true
        case p.variadic:
            continue
        case:
            arg.text = zero_text(p.type_text)
        }
        if arg.text == "" {
            continue
        }
        named_mode ||= arg.named
        if named_mode && arg.droppable {
            continue
        }
        arg.named = named_mode
        append(&out, arg)
    }
    for len(out) > 0 && out[len(out) - 1].droppable {
        pop(&out)
    }
    sb := strings.builder_make(context.temp_allocator)
    for a, i in out {
        if i > 0 {
            strings.write_string(&sb, ", ")
        }
        if a.named {
            strings.write_string(&sb, a.name)
            strings.write_string(&sb, " = ")
        }
        strings.write_string(&sb, a.text)
    }
    text := strings.to_string(sb)
    if text != strings.trim_space(f.source[as + 1:ae - 1]) {
        append_sig_edit(sc, f, source, int(as) + 1, int(ae) - 1, text)
    }
    return true
}

// The zero value a call passes for a new parameter with no default, read from its type text.
@(private = "file")
zero_text :: proc(type_text: string) -> string {
    t := strings.trim_space(type_text)
    switch t {
    case "bool", "b8", "b16", "b32", "b64":
        return "false"
    case "string", "cstring":
        return `""`
    case "rawptr", "any", "typeid", "uintptr":
        return "nil" if t != "uintptr" else "0"
    case "int", "uint", "rune", "byte":
        return "0"
    }
    if strings.has_prefix(t, "^") ||
        strings.has_prefix(t, "[]") ||
        strings.has_prefix(t, "[^]") ||
        strings.has_prefix(t, "[dynamic]") ||
        strings.has_prefix(t, "map[") ||
        strings.has_prefix(t, "proc") {
        return "nil"
    }
    if is_number_type(t) {
        return "0"
    }
    return "{}"
}

// True for the sized integer, float, complex and quaternion type names, endian forms included.
@(private = "file")
is_number_type :: proc(name: string) -> bool {
    t := strings.trim_suffix(strings.trim_suffix(name, "le"), "be")
    for prefix in ([]string{"complex", "quaternion", "i", "u", "f"}) {
        if !strings.has_prefix(t, prefix) || len(t) == len(prefix) {
            continue
        }
        for c in t[len(prefix):] {
            if c < '0' || c > '9' {
                return false
            }
        }
        return true
    }
    return false
}
