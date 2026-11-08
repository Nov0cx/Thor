// Quick fixes for the lines of the compiler's own diagnostics.
package odin

import "core:fmt"
import "core:strings"

import lang ".."
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
        if d.severity != .Error {
            continue
        }
        if name, ok := message_name(d.message, PARAM_ASSIGN_PREFIX, PARAM_SUFFIX); ok {
            shadow_parameter_fix(rc, d.start, name, res)
        } else if name, ok = message_name(d.message, PARAM_ADDRESS_PREFIX, PARAM_SUFFIX); ok {
            shadow_parameter_fix(rc, d.start, name, res)
        } else if name, ok = message_name(d.message, REDECLARATION_PREFIX, REDECLARATION_SUFFIX); ok {
            redeclaration_fix(rc, d.start, name, res)
        }
    }
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
