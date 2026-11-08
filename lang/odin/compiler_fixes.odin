// Quick fixes for the lines of the compiler's own diagnostics.
package odin

import "core:fmt"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

@(private = "file")
PARAM_ASSIGN_PREFIX :: "Cannot assign to '"

@(private = "file")
PARAM_ADDRESS_PREFIX :: "Cannot take the pointer address of '"

@(private = "file")
PARAM_SUFFIX :: "' which is a procedure parameter"

@(private = "file")
REDECLARATION_PREFIX :: "Redeclaration of '"

@(private = "file")
REDECLARATION_SUFFIX :: "' in this scope"

@(private = "file")
UNNEEDED_SEMICOLON :: "Found unneeded semicolon"

// Removes the semicolon the compiler names, with the blanks before it.
@(private = "file")
semicolon_fix :: proc(rc: ^Request_Context, offset: int, res: ^lang.Result) {
    src := rc.req.source
    if src[offset] != ';' {
        return
    }
    from := offset
    for from > 0 && (src[from - 1] == ' ' || src[from - 1] == '\t') {
        from -= 1
    }
    push_action(res, rc.req, "Remove the unneeded semicolon", Edit_Spec{from, offset + 1, ""})
}

@(private = "file")
MISSING_COMMA :: "Expected a comma, got a newline"

// Inserts the comma after the last token before the newline the compiler names.
@(private = "file")
comma_fix :: proc(rc: ^Request_Context, offset: int, res: ^lang.Result) {
    toks := odinsyntax.lex_all(rc.req.source, context.temp_allocator)
    for j := len(toks) - 1; j >= 0; j -= 1 {
        tok := toks[j]
        if int(tok.offset) >= offset {
            continue
        }
        #partial switch tok.kind {
        case .Whitespace, .Line_Comment, .Block_Comment, .Line_Continuation, .Newline:
            continue
        case .Comma, .Open_Brace, .Open_Paren, .Semicolon:
            return
        }
        at := int(tok.offset + tok.len)
        push_action(res, rc.req, "Add the missing trailing comma", Edit_Spec{at, at, ","})
        return
    }
}

@(private = "file")
UNNEEDED_CAST :: "Unneeded cast of '"

@(private = "file")
UNNEEDED_TRANSMUTE :: "Unneeded transmute of '"

// Replaces the conversion the compiler names with its operand. A cast is named at its operand, a
// transmute at its keyword.
@(private = "file")
unneeded_cast_fix :: proc(rc: ^Request_Context, offset: int, is_transmute: bool, res: ^lang.Result) {
    tok, found := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(offset), context.temp_allocator)
    if !found {
        return
    }
    for n := tok.parent; n != nil; n = n.parent {
        ce, is_cast := odinsyntax.as_cast_expr(n^)
        if !is_cast {
            continue
        }
        keyword := odinsyntax.cast_expr_keyword(&ce) or_continue
        operand := odinsyntax.cast_expr_operand(&ce) or_continue
        at := is_transmute ? int(n.offset) : int(operand.offset)
        if at != offset || (keyword.green.kind == .Transmute) != is_transmute {
            continue
        }
        text := operand_text(operand)
        if !atomic_expr(operand.green.kind) {
            text = strings.concatenate({"(", text, ")"}, context.temp_allocator)
        } else if operand.green.kind == .Paren_Expr {
            pe := odinsyntax.Paren_Expr(operand)
            if inner, has := odinsyntax.paren_expr_expr(&pe); has && atomic_expr(inner.green.kind) && inner.green.kind != .Comp_Lit {
                text = operand_text(inner)
            }
        }
        what := is_transmute ? "transmute" : "cast"
        push_action(res, rc.req, fmt.tprintf("Remove the unneeded %s", what), Edit_Spec{int(n.offset), int(n.offset) + len(operand_text(n^)), text})
        return
    }
}

// The text of `n` without the blanks after it.
@(private = "file")
operand_text :: proc(n: odinsyntax.Syntax_Node) -> string {
    return strings.trim_right_space(odinsyntax.node_text(n))
}

// True when an expression of `kind` needs no parentheses to stand where a cast stood.
@(private = "file")
atomic_expr :: proc(kind: odinsyntax.Syntax_Kind) -> bool {
    #partial switch kind {
    case .Ident, .Literal, .Context_Expr, .Paren_Expr, .Selector_Expr, .Implicit_Selector, .Selector_Call_Expr, .Index_Expr, .Matrix_Index_Expr, .Slice_Expr, .Deref_Expr, .Call_Expr, .Comp_Lit, .Cast_Expr, .Auto_Cast_Expr:
        return true
    }
    return false
}

// Offers a fix for each error of the request's diagnostics that the compiler words in a known way.
@(private)
compiler_fixes :: proc(rc: ^Request_Context, res: ^lang.Result) {
    for d in rc.req.diagnostics {
        if d.start < 0 || d.start >= len(rc.req.source) {
            continue
        }
        if d.message == UNNEEDED_SEMICOLON {
            semicolon_fix(rc, d.start, res)
            continue
        }
        if d.message == MISSING_COMMA {
            comma_fix(rc, d.start, res)
            continue
        }
        if strings.has_prefix(d.message, UNNEEDED_CAST) {
            unneeded_cast_fix(rc, d.start, false, res)
            continue
        }
        if strings.has_prefix(d.message, UNNEEDED_TRANSMUTE) {
            unneeded_cast_fix(rc, d.start, true, res)
            continue
        }
        if d.severity != .Error {
            continue
        }
        if name, ok := message_name(d.message, PARAM_ASSIGN_PREFIX, PARAM_SUFFIX); ok {
            shadow_parameter_fix(rc, d.start, name, res)
        } else if name, ok = message_name(d.message, PARAM_ADDRESS_PREFIX, PARAM_SUFFIX); ok {
            shadow_parameter_fix(rc, d.start, name, res)
        } else if name, ok = message_name(d.message, REDECLARATION_PREFIX, REDECLARATION_SUFFIX); ok {
            redeclaration_fix(rc, d.start, name, res)
        } else if message_quotes(d.message, PARAM_ASSIGN_PREFIX) || message_quotes(d.message, PARAM_ADDRESS_PREFIX) {
            immutable_fix(rc, d.start, res)
        }
    }
}

// True when `message` is `prefix`, a quoted text and nothing after the closing quote.
@(private = "file")
message_quotes :: proc(message, prefix: string) -> bool {
    return strings.has_prefix(message, prefix) && len(message) > len(prefix) + 1 && message[len(message) - 1] == '\''
}

// Declares the `for ... in` or `switch ... in` variable at `offset` with `&`, where the compiler accepts it.
// The compiler gives the hint `'x' is immutable, declare it as '&x'` on a snippet line, so the type tells.
@(private = "file")
immutable_fix :: proc(rc: ^Request_Context, offset: int, res: ^lang.Result) {
    src := rc.req.source
    at := offset
    if src[at] == '&' {
        at += 1
        for at < len(src) && (src[at] == ' ' || src[at] == '\t') {
            at += 1
        }
    }
    root := odinsyntax.node_root(rc.parsed.tree)
    tok, found := odinsyntax.node_token_at(root, u32(at), context.temp_allocator)
    if !found || tok.green.kind != .Ident || int(tok.offset) != at {
        return
    }
    c := request_checker(rc)
    if c == nil {
        return
    }
    file := rc.live.id
    name := odinsyntax.syntax_token_text(tok)
    r := odinsema.lookup_name(c, file, name, at)
    l := r.local
    if r.kind != .Local || (l.kind != .Loop_Var && l.kind != .Switch_Var) {
        return
    }
    decl := l.name_offset
    if decl <= 0 || decl >= len(src) || src[decl - 1] == '&' {
        return
    }
    decl_tok, has_decl := odinsyntax.node_token_at(root, u32(decl), context.temp_allocator)
    if !has_decl || int(decl_tok.offset) != decl {
        return
    }
    stmt := decl_tok.parent
    for stmt != nil && stmt.green.kind != .Range_Stmt && stmt.green.kind != .Type_Switch_Stmt {
        stmt = stmt.parent
    }
    if stmt == nil {
        return
    }
    ok := false
    if stmt.green.kind == .Type_Switch_Stmt {
        ts, _ := odinsyntax.as_type_switch_stmt(stmt^)
        subject, has := odinsyntax.type_switch_stmt_subject(&ts)
        ok = has && addressable(c, file, subject)
    } else {
        rs, _ := odinsyntax.as_range_stmt(stmt^)
        iterated, has := odinsyntax.range_stmt_expr(&rs)
        ok = has && element_addressable(c, file, iterated, l.value_index)
    }
    if !ok {
        return
    }
    push_action(res, rc.req, fmt.tprintf("Declare '%s' as '&%s' to make it mutable", name, name), Edit_Spec{decl, decl, "&"})
}

// True when the `index`th variable of a `for ... in iterated` can be declared with `&`.
@(private = "file")
element_addressable :: proc(c: ^odinsema.Checker, file: odinsema.File_Id, iterated: odinsyntax.Syntax_Node, index: int) -> bool {
    t := &c.table
    base := odinsema.type_base(t, odinsema.expr_type(c, file, iterated).type)
    #partial switch v in odinsema.type_get(t, base) {
    case odinsema.Slice_Type, odinsema.Dynamic_Array_Type:
        return index == 0
    case odinsema.Map_Type:
        return index == 1
    case odinsema.Array_Type, odinsema.Enumerated_Array_Type:
        return index == 0 && addressable(c, file, iterated)
    case odinsema.Pointer_Type:
        #partial switch _ in odinsema.type_get(t, odinsema.type_base(t, v.elem)) {
        case odinsema.Array_Type, odinsema.Enumerated_Array_Type:
            return index == 0
        }
    }
    return false
}

// True when `n` names storage the compiler can take the address of. False when not sure.
@(private = "file")
addressable :: proc(c: ^odinsema.Checker, file: odinsema.File_Id, n: odinsyntax.Syntax_Node) -> bool {
    n := n
    t := &c.table
    #partial switch n.green.kind {
    case .Paren_Expr:
        pe := odinsyntax.Paren_Expr(n)
        inner := odinsyntax.paren_expr_expr(&pe) or_return
        return addressable(c, file, inner)
    case .Deref_Expr:
        return true
    case .Ident:
        r := odinsema.lookup_name(c, file, odinsyntax.node_text(n), int(n.offset))
        switch r.kind {
        case .Local:
            return r.local.kind == .Var || r.local.kind == .Result
        case .Item:
            return odinsema.expr_type(c, file, n).mode == .Value
        case .None, .Import, .Basic, .Builtin:
        }
    case .Selector_Expr:
        se := odinsyntax.Selector_Expr(n)
        operand := odinsyntax.selector_expr_operand(&se) or_return
        if _, is_ptr := odinsema.type_get(t, odinsema.type_base(t, odinsema.expr_type(c, file, operand).type)).(odinsema.Pointer_Type); is_ptr {
            return true
        }
        return addressable(c, file, operand)
    case .Index_Expr:
        ie := odinsyntax.Index_Expr(n)
        operand := odinsyntax.index_expr_operand(&ie) or_return
        #partial switch _ in odinsema.type_get(t, odinsema.type_base(t, odinsema.expr_type(c, file, operand).type)) {
        case odinsema.Slice_Type, odinsema.Dynamic_Array_Type, odinsema.Multi_Pointer_Type, odinsema.Pointer_Type:
            return true
        case odinsema.Array_Type, odinsema.Enumerated_Array_Type:
            return addressable(c, file, operand)
        }
    }
    return false
}

// The name between `prefix` and `suffix` when `message` is exactly that sentence.
@(private = "file")
message_name :: proc(message, prefix, suffix: string) -> (string, bool) {
    if !strings.has_prefix(message, prefix) {
        return "", false
    }
    rest := message[len(prefix):]
    end := strings.index_byte(rest, '\'')
    if end <= 0 || !strings.has_prefix(rest[end:], suffix) {
        return "", false
    }
    return rest[:end], true
}

// The procedure literal around `offset` and its `{` token, when `name` is one of its parameters
// and the body opens a new line.
@(private = "file")
param_body :: proc(rc: ^Request_Context, offset: int, name: string) -> (open: odinsyntax.Syntax_Token, body: odinsyntax.Syntax_Node, ok: bool) {
    tok, found := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(offset), context.temp_allocator)
    if !found {
        return
    }
    for n := tok.parent; n != nil; n = n.parent {
        if n.green.kind != .Proc_Lit {
            continue
        }
        pl, _ := odinsyntax.as_proc_lit(n^)
        pt := odinsyntax.proc_lit_type(&pl) or_return
        params := odinsyntax.proc_type_params(&pt) or_return
        has_param := false
        fields := odinsyntax.param_list_fields(&params)
        for field in odinsyntax.child_iter_next(&fields) {
            f, is_field := odinsyntax.as_field(field)
            if !is_field {
                continue
            }
            names := odinsyntax.field_names(&f) or_continue
            it := odinsyntax.name_list_names(&names)
            for param in odinsyntax.child_iter_next(&it) {
                has_param ||= odinsyntax.node_text(param) == name
            }
        }
        body = odinsyntax.proc_lit_body(&pl) or_return
        if !has_param {
            return
        }
        block := body
        open = odinsyntax.find_child_token(&block, {tokens = {.Open_Brace}}) or_return
        src := rc.req.source
        after := int(open.offset) + 1
        if strings.trim_space(src[after:line_end(src, after)]) != "" {
            return
        }
        return open, body, true
    }
    return
}

// Declares a copy of the parameter as the first statement of the body.
@(private = "file")
shadow_parameter_fix :: proc(rc: ^Request_Context, offset: int, name: string, res: ^lang.Result) {
    open, body, ok := param_body(rc, offset, name)
    if !ok {
        return
    }
    src := rc.req.source
    block := body
    indent := ""
    if first, has := odinsyntax.find_child_node(&block, {kinds = ~odinsyntax.Kind_Set{}}); has {
        indent = line_indent(src, int(first.offset))
    } else {
        indent = strings.concatenate({line_indent(src, int(open.offset)), indent_unit(rc.req)}, context.temp_allocator)
    }
    at := int(open.offset) + 1
    push_action(res, rc.req, fmt.tprintf("Copy parameter '%s' into a local variable", name), Edit_Spec{at, at, fmt.tprintf("\n%s%s := %s", indent, name, name)})
}

// Turns the `name := value` that declares the name again into the assignment `name = value`.
@(private = "file")
redeclaration_fix :: proc(rc: ^Request_Context, offset: int, name: string, res: ^lang.Result) {
    root := odinsyntax.node_root(rc.parsed.tree)
    tok, found := odinsyntax.node_token_at(root, u32(offset), context.temp_allocator)
    if !found || !strings.has_prefix(rc.req.source[offset:], name) {
        return
    }
    list := tok.parent
    for list != nil && list.green.kind != .Name_List {
        list = list.parent
    }
    if list == nil || list.parent == nil || list.parent.green.kind != .Value_Decl {
        return
    }
    nl := odinsyntax.Name_List(list^)
    count := 0
    it := odinsyntax.name_list_names(&nl)
    for _ in odinsyntax.child_iter_next(&it) {
        count += 1
    }
    decl := list.parent
    v, _ := odinsyntax.as_value_decl(decl^)
    values, has_values := odinsyntax.value_decl_values(&v)
    if count != 1 || !has_values || !inside_procedure(decl) {
        return
    }
    src := rc.req.source
    from := offset + len(name)
    to := int(values.offset)
    if from > to || strings.trim_space(src[from:to]) != ":=" {
        return
    }
    push_action(res, rc.req, fmt.tprintf("Assign to the existing '%s' instead of declaring it again", name), Edit_Spec{from, to, " = "})
}

// True when `n` has a procedure literal around it.
@(private = "file")
inside_procedure :: proc(n: ^odinsyntax.Syntax_Node) -> bool {
    for p := n.parent; p != nil; p = p.parent {
        if p.green.kind == .Proc_Lit {
            return true
        }
    }
    return false
}
