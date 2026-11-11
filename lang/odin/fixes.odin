// Quick fixes that complete code: struct literal fields and `or_return`.
package odin

import "core:fmt"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Adds the fields the innermost struct literal around the caret does not name.
@(private)
struct_field_fixes :: proc(rc: ^Request_Context, caret: Caret, res: ^lang.Result) {
    c := request_checker(rc)
    if c == nil {
        return
    }
    tok, ok := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(caret.offset), context.temp_allocator)
    if !ok {
        return
    }
    for n := tok.parent; n != nil; n = n.parent {
        if n.green.kind == .Comp_Lit {
            fill_struct_literal(rc, c, n^, res)
            return
        }
    }
}

@(private = "file")
fill_struct_literal :: proc(rc: ^Request_Context, c: ^odinsema.Checker, lit: odinsyntax.Syntax_Node, res: ^lang.Result) {
    src           := rc.req.source
    lit           := lit
    t             := odinsema.literal_type(c, rc.live.id, lit)
    st, is_struct := odinsema.type_get(&c.table, odinsema.type_base(&c.table, t)).(odinsema.Struct_Type)
    if !is_struct || .Raw_Union in st.flags {
        return
    }
    named        := make([dynamic]string, context.temp_allocator)
    last_end     := -1
    first_offset := -1
    cl           := odinsyntax.Comp_Lit(lit)
    it           := odinsyntax.comp_lit_elems(&cl)
    for elem in odinsyntax.child_iter_next(&it) {
        elem := elem
        if elem.green.kind != .Field_Value {
            return
        }
        fv := odinsyntax.Field_Value(elem)
        if name, has := odinsyntax.field_value_name(&fv); has {
            append(&named, odinsyntax.node_text(name))
        }
        _, end := odinsyntax.node_range(elem)
        last_end = int(end)
        if first_offset < 0 {
            first_offset = int(elem.offset)
        }
    }
    open, has_open   := odinsyntax.find_child_token(&lit, {tokens = {.Open_Brace}})
    close, has_close := odinsyntax.find_child_token(&lit, {tokens = {.Close_Brace}, last = true})
    if !has_open || !has_close {
        return
    }
    missing := make([dynamic]string, context.temp_allocator)
    for f in st.fields {
        if f.name == "" || f.name == "_" || slice.contains(named[:], f.name) {
            continue
        }
        zero, zok := odinsema.zero_value(c, rc.live.id, f.type)
        if !zok {
            return
        }
        append(&missing, fmt.tprintf("%s = %s", f.name, zero))
    }
    if len(missing) == 0 {
        return
    }
    title := fmt.tprintf("Add missing field: %s", st_field_name(missing[0])) if len(missing) == 1 else fmt.tprintf("Add %d missing fields", len(missing))
    at    := int(close.offset)
    multi := strings.contains(src[int(open.offset):at], "\n")
    if multi && strings.trim_space(src[line_start(src, at):at]) == "" {
        indent := line_indent(src, first_offset) if first_offset >= 0 else strings.concatenate(
            {line_indent(src, at), indent_unit(rc.req)},
            context.temp_allocator,
        )
        sb     := strings.builder_make(context.temp_allocator)
        for m in missing {
            fmt.sbprintf(&sb, "%s%s,\n", indent, m)
        }
        specs := make([dynamic]Edit_Spec, context.temp_allocator)
        if last_end >= 0 && !strings.has_prefix(strings.trim_left_space(src[last_end:at]), ",") {
            append(&specs, Edit_Spec{last_end, last_end, ","})
        }
        ls := line_start(src, at)
        append(&specs, Edit_Spec{ls, ls, strings.to_string(sb)})
        push_action(res, rc.req, title, ..specs[:])
        return
    }
    text := strings.join(missing[:], ", ", context.temp_allocator)
    if last_end >= 0 {
        rest := strings.trim_space(src[last_end:at])
        if rest == "," {
            push_action(
                res,
                rc.req,
                title,
                Edit_Spec{last_end + strings.index_byte(src[last_end:at], ',') + 1, at, strings.concatenate({" ", text}, context.temp_allocator)},
            )
            return
        }
        push_action(res, rc.req, title, Edit_Spec{last_end, last_end, strings.concatenate({", ", text}, context.temp_allocator)})
        return
    }
    push_action(res, rc.req, title, Edit_Spec{int(open.offset) + 1, at, text})
}

// The field name of a `name = value` entry.
@(private = "file")
st_field_name :: proc(entry: string) -> string {
    if i := strings.index(entry, " = "); i >= 0 {
        return entry[:i]
    }
    return entry
}

// Adds `or_return` to a call on the caret's lines whose last value an assignment has no place for,
// when the procedure around it can return that value.
@(private)
or_return_fixes :: proc(rc: ^Request_Context, caret: Caret, res: ^lang.Result) {
    c := request_checker(rc)
    if c == nil {
        return
    }
    tok, ok := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(caret.offset), context.temp_allocator)
    if !ok {
        return
    }
    for n := tok.parent; n != nil; n = n.parent {
        if n.green.kind != .Assign_Stmt && n.green.kind != .Value_Decl {
            continue
        }
        _, places, values, mismatch := odinsema.assign_count(c, rc.live.id, n^)
        if !mismatch || values != places + 1 {
            return
        }
        call, found := single_value(n^)
        if !found || call.green.kind != .Call_Expr || !odinsema.or_return_fits(c, rc.live.id, call) {
            return
        }
        _, end := odinsyntax.node_range(call)
        push_action(res, rc.req, "Add or_return", Edit_Spec{int(end), int(end), " or_return"})
        return
    }
}

// The one value of an assignment or variable declaration.
@(private = "file")
single_value :: proc(stmt: odinsyntax.Syntax_Node) -> (odinsyntax.Syntax_Node, bool) {
    list: odinsyntax.Expr_List
    has: bool
    if stmt.green.kind == .Assign_Stmt {
        as, _ := odinsyntax.as_assign_stmt(stmt)
        list, has = odinsyntax.assign_stmt_rhs(&as)
    } else {
        vd, _ := odinsyntax.as_value_decl(stmt)
        list, has = odinsyntax.value_decl_values(&vd)
    }
    if !has {
        return {}, false
    }
    value: odinsyntax.Syntax_Node
    count := 0
    it    := odinsyntax.expr_list_items(&list)
    for v in odinsyntax.child_iter_next(&it) {
        value = v
        count += 1
    }
    return value, count == 1
}
