// Small shared helpers used by both the statement and expression visitors:
// comma-separated lists, attributes, and the brace_style/convert_do rules
// that decide how a block attaches to the construct in front of it.
package odinfmt

@(private)
print_expr_list :: proc(pr: ^Printer, out: ^[dynamic]Doc, exprs: []Node) {
    for e, i in exprs {
        if i > 0 {
            append(out, text(", "))
        }
        print_expr(pr, out, e)
    }
}

// One element of a bracketed list, with the comments written around it.
@(private)
List_Item :: struct {
    doc:      Doc,
    leading:  []Doc, // comment groups before the item, each on its own line
    trailing: []Doc, // comment groups after the item on its last line
}

// Emits `items` inside `open`/`close` as a group: hugged on one line when it
// fits character_width, otherwise one item per line at one extra indent with
// Odin's trailing comma. The indent is what makes the continuation lines hang —
// a Doc_Line writes the *current* indent level — and the closing soft_line sits
// outside it so the bracket returns to the opening level. `tail` is the comment
// groups after the last item, before `close`.
//
// An item with a forced line break in it (a proc literal, an already multi-line
// composite literal) falls back to the flat ", "-joined form: such an argument
// hugs its call by convention, and grouping would break the list around it.
// A list with a comment in it is one item per line, each comment where it was
// written.
@(private)
append_list_group :: proc(pr: ^Printer, out: ^[dynamic]Doc, open, close: string, items: []List_Item, tail: []Doc = nil) {
    append(out, text(open))
    if len(items) == 0 && len(tail) == 0 {
        append(out, text(close))
        return
    }
    commented := len(tail) > 0
    for it in items {
        if len(it.leading) > 0 || len(it.trailing) > 0 {
            commented = true
        }
    }
    if commented {
        body: [dynamic]Doc
        for it in items {
            append(&body, hard_line(0))
            for c in it.leading {
                append(&body, c)
                append(&body, hard_line(0))
            }
            append(&body, it.doc)
            append(&body, text(","))
            for c in it.trailing {
                append(&body, text("  "))
                append(&body, c)
            }
        }
        for c in tail {
            append(&body, hard_line(0))
            append(&body, c)
        }
        append(out, indent(body[:]))
        append(out, hard_line(0))
        append(out, text(close))
        return
    }
    for it in items {
        if _, flat := measure_flat(it.doc, &pr.opts); !flat {
            for other, i in items {
                if i > 0 {
                    append(out, text(", "))
                }
                append(out, other.doc)
            }
            append(out, text(close))
            return
        }
    }

    trailing: [dynamic]Doc
    append(&trailing, text(","))

    body: [dynamic]Doc
    append(&body, soft_line())
    for it, i in items {
        if i > 0 {
            append(&body, text(","))
            append(&body, line())
        }
        append(&body, it.doc)
    }
    append(&body, if_break(nil, trailing[:]))

    grouped: [dynamic]Doc
    append(&grouped, indent(body[:]))
    append(&grouped, soft_line())
    append(&grouped, text(close))
    append(out, group(grouped[:]))
}

// `@(elem, elem)`; `@name` takes the parentheses too.
@(private)
print_attribute :: proc(pr: ^Printer, out: ^[dynamic]Doc, a: Node) {
    ks := kids(a)
    elems := expr_kids(ks)
    append(out, text("@("))
    print_expr_list(pr, out, elems)
    append(out, text(")"))
}

// The attributes, check directives and label in front of a statement, in source
// order. Returns the children after them; after_label is true when the label was
// printed last and the statement owes it the space after its colon.
@(private)
print_stmt_prefix :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) -> (rest: []Node, after_label: bool) {
    for k, i in ks {
        #partial switch k.kind {
        case .Attribute:
            print_attribute(pr, out, k)
            append(out, hard_line(0))
        case .Directive:
            if after_label {
                append(out, text(" "))
                after_label = false
            }
            print_expr(pr, out, k)
            append(out, text(" "))
        case .Arg_List:
            // The arguments of `#unroll(...)`, which hug the directive.
            if len(out) > 0 {
                pop(out)
            }
            print_arg_list(pr, out, k)
            append(out, text(" "))
        case .Label:
            if name, ok := find_kind(kids(k), .Ident); ok {
                print_expr(pr, out, name)
            }
            append(out, text(":"))
            after_label = true
        case:
            return ks[i:], after_label
        }
    }
    return nil, after_label
}

// Whether a block's opening brace sits on its own line: Allman always does,
// K&R only for a procedure body, _1TBS/Stroustrup never.
@(private)
brace_own_line :: proc(pr: ^Printer, is_proc_body: bool) -> bool {
    switch pr.opts.brace_style {
    case ._1TBS, .Stroustrup:
        return false
    case .Allman:
        return true
    case .K_And_R:
        return is_proc_body
    }
    return false
}

// What goes between a construct and the `{` of its body: a line break when
// brace_style puts the brace on its own line, else a space. An empty body
// keeps `{}` on the line.
@(private)
print_brace_lead :: proc(pr: ^Printer, out: ^[dynamic]Doc, is_proc_body: bool, empty := false) {
    if !empty && brace_own_line(pr, is_proc_body) {
        append(out, hard_line(0))
    } else {
        append(out, text(" "))
    }
}

// Whether `else` starts a new line after the closing brace (Allman and
// Stroustrup) or continues it (`} else {`, _1TBS and K&R).
@(private)
else_own_line :: proc(pr: ^Printer) -> bool {
    return pr.opts.brace_style == .Allman || pr.opts.brace_style == .Stroustrup
}

@(private)
colon_sep :: proc(pr: ^Printer) -> string {
    if pr.opts.spaces_around_colons {
        return " : "
    }
    return ": "
}

// colon_sep, split into the part that belongs inside an alignment cell and the
// part that follows the pad; in_cell + after_cell is colon_sep(pr) always. With
// spaces_around_colons the pad sits before the " : ", so colons and types both
// line up; without it the pad sits after the ":", since a space before a colon
// is what that option is off to avoid.
@(private)
colon_split :: proc(pr: ^Printer) -> (in_cell, after_cell: string) {
    if pr.opts.spaces_around_colons {
        return "", " : "
    }
    return ":", " "
}
