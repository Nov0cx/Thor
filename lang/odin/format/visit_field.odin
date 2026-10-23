// Field and bit-field field printing, plus the brace-delimited-list builders
// for the three item shapes structs, unions (and enums), and bit_fields hand
// the visitor: fields, bare expressions, and bit-field fields respectively.
// Mirrors print_brace_body in visit_stmt.odin, which does the same for
// statement lists.
package odinfmt

// The parts of a field.
@(private)
Field_Parts :: struct {
    using_:     bool,
    directives: []Node,
    names:      []Node,
    type:       Node,
    default:    Node,
    tag:        string,
}

@(private)
field_parts :: proc(pr: ^Printer, f: Node) -> (p: Field_Parts) {
    ks := kids(f)
    directives := make([dynamic]Node, 0, 1)
    colon := tok_index(ks, .Colon)
    eq := tok_index(ks, .Eq)
    // A directive before the name or the type is a flag; after them it is a value.
    flags_done := false
    for k, i in ks {
        switch {
        case is_tok(k, .Colon), is_tok(k, .Eq):
            flags_done = true
        case is_tok(k, .Using):
            p.using_ = true
        case is_tok(k, .String):
            p.tag = node_text(pr, k)
        case k.kind == .Directive && !flags_done:
            append(&directives, k)
        case k.kind == .Name_List:
            flags_done = true
            p.names = expr_kids(kids(k))
        case is_expr(k):
            flags_done = true
            if eq >= 0 && i > eq {
                p.default = k
            } else if colon < 0 || i > colon {
                p.type = k
            }
        }
    }
    p.directives = directives[:]
    return
}

@(private)
field_has_names :: proc(f: Node) -> bool {
    _, ok := find_kind(kids(f), .Name_List)
    return ok
}

// A field. With a head cell from the pre-pass the name side is padded so the
// types line up; with none the output is the plain form. The `using` and
// `#no_alias` prefixes belong inside the cell: one that starts past the indent
// column is padded relative to the wrong place.
@(private)
print_field :: proc(pr: ^Printer, out: ^[dynamic]Doc, f: Node) {
    cell := align_cell(pr, f)
    p := field_parts(pr, f)

    head: [dynamic]Doc
    if p.using_ {
        append(&head, text("using "))
    }
    for d in p.directives {
        print_expr(pr, &head, d)
        append(&head, text(" "))
    }
    has_names := len(p.names) > 0
    if has_names {
        print_expr_list(pr, &head, p.names)
    }

    in_cell, after_cell := colon_split(pr)
    has_type := is_node(p.type)
    has_colon := has_names && has_type
    if has_colon {
        append(&head, text(in_cell))
    }

    type_doc: [dynamic]Doc
    if has_type {
        print_expr(pr, &type_doc, p.type)
    }

    if cell.head != 0 {
        append(out, align(cell.head, head[:]))
    } else {
        append(out, ..head[:])
    }
    if has_colon {
        append(out, text(after_cell))
    }
    append(out, ..type_doc[:])

    if is_node(p.default) {
        if has_type {
            append(out, text(" = "))
        } else {
            append(out, text(" := "))
        }
        print_expr(pr, out, p.default)
    }
    if p.tag != "" {
        append(out, text(" "))
        append(out, text(p.tag))
    }
}

// The fields as a wrappable group — the parameter-list shape, where a signature
// too long for character_width takes one parameter per line. `close_offset` is
// where the list ends: a comment before it is in the list.
@(private)
append_field_list_group :: proc(pr: ^Printer, out: ^[dynamic]Doc, open, close: string, fields: []Node, close_offset: int) {
    items := make([dynamic]List_Item, 0, len(fields))
    for f, i in fields {
        item := List_Item {leading = take_comments_before(pr, f.start)}
        field: [dynamic]Doc
        print_field(pr, &field, f)
        item.doc = concat(field[:])
        next := i + 1 < len(fields) ? fields[i + 1].start : close_offset
        item.trailing = take_trailing(pr, end_line(pr, f), next)
        append(&items, item)
    }
    append_list_group(pr, out, open, close, items[:], take_comments_before(pr, close_offset))
}

@(private)
print_field_list :: proc(pr: ^Printer, out: ^[dynamic]Doc, fields: []Node) {
    for f, i in fields {
        if i > 0 {
            append(out, text(", "))
        }
        print_field(pr, out, f)
    }
}

// Whether a field has the `name: type` shape a head cell needs. A bare embedded
// type (`using Foo`), a field with no name and one with no type have no colon
// to align to.
@(private)
field_alignable :: proc(pr: ^Printer, f: Node) -> bool {
    p := field_parts(pr, f)
    return is_node(p.type) && len(p.names) > 0
}

// One head id per maximal run of two or more alignable fields on adjacent
// lines. Runs are decided here, before a single field is emitted, so a
// separator that later appends a comment cannot change one mid-flight; a lone
// field gets no id, since padding a cell to its own width does nothing.
@(private)
assign_field_align_ids :: proc(pr: ^Printer, fields: []Node) {
    if !pr.opts.align_struct_fields {
        return
    }
    for i := 0; i < len(fields); {
        if !field_alignable(pr, fields[i]) {
            i += 1
            continue
        }
        end := i + 1
        for end < len(fields) &&
            field_alignable(pr, fields[end]) &&
            same_align_run(pr, end_line(pr, fields[end - 1]), start_line(pr, fields[end])) {
            end += 1
        }
        if end - i >= 2 {
            id := next_align(pr)
            for f in fields[i:end] {
                cell := pr.align_ids[align_key(f)]
                cell.head = id
                pr.align_ids[align_key(f)] = cell
            }
        }
        i = end
    }
}

// One field per line, comma-terminated — the struct body shape.
@(private)
print_field_brace_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, open_line, close_line: int, fields: []Node) {
    assign_field_align_ids(pr, fields)
    append(out, text("{"))
    if len(fields) == 0 {
        body: [dynamic]Doc
        flush_before(pr, &body, 0, false, close_line, true)
        append_brace_close(out, body[:])
        return
    }
    body: [dynamic]Doc
    first_line := start_line(pr, fields[0])
    prev_line, has_prev := flush_before(pr, &body, open_line, true, first_line, true)
    append(&body, hard_line(0))
    for f, i in fields {
        if i > 0 {
            separator(pr, &body, prev_line, has_prev, start_line(pr, f), true)
        }
        field_doc: [dynamic]Doc
        print_field(pr, &field_doc, f)
        for d in field_doc {
            append(&body, d)
        }
        append(&body, text(","))
        prev_line = end_line(pr, f)
        has_prev = true
    }
    flush_before(pr, &body, prev_line, has_prev, close_line, true)
    append_brace_close(out, body[:])
}

// One head id per maximal run of two or more adjacent `name = value` elements,
// so their `=` line up. Bare enum members and union variants have no field to
// pad and end a run. Shared by enum bodies and multi-line composite literals.
@(private)
assign_field_value_align_ids :: proc(pr: ^Printer, exprs: []Node) {
    if !pr.opts.align_struct_values {
        return
    }
    for i := 0; i < len(exprs); {
        if !is_flat_field_value(pr, exprs[i]) {
            i += 1
            continue
        }
        end := i + 1
        for end < len(exprs) &&
            is_flat_field_value(pr, exprs[end]) &&
            same_align_run(pr, end_line(pr, exprs[end - 1]), start_line(pr, exprs[end])) {
            end += 1
        }
        if end - i >= 2 {
            id := next_align(pr)
            for ex in exprs[i:end] {
                cell := pr.align_ids[align_key(ex)]
                cell.head = id
                pr.align_ids[align_key(ex)] = cell
            }
        }
        i = end
    }
}

// A `name = value` element whose name stays on one line, so its cell is
// paddable.
@(private)
is_flat_field_value :: proc(pr: ^Printer, ex: Node) -> bool {
    if ex.kind != .Field_Value {
        return false
    }
    ks := kids(ex)
    eq := tok_index(ks, .Eq)
    name, ok := expr_in(ks, 0, eq < 0 ? len(ks) : eq)
    return ok && start_line(pr, name) == end_line(pr, name)
}

// One bare expression per line, comma-terminated — union variants and enum
// fields.
@(private)
print_expr_brace_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, close_line: int, exprs: []Node) {
    assign_field_value_align_ids(pr, exprs)
    append(out, text("{"))
    if len(exprs) == 0 {
        body: [dynamic]Doc
        flush_before(pr, &body, 0, false, close_line, true)
        append_brace_close(out, body[:])
        return
    }
    body: [dynamic]Doc
    prev_line, has_prev := flush_before(pr, &body, 0, false, start_line(pr, exprs[0]), true)
    append(&body, hard_line(0))
    for ex, i in exprs {
        if i > 0 {
            separator(pr, &body, prev_line, has_prev, start_line(pr, ex), true)
        }
        elem_doc: [dynamic]Doc
        print_expr(pr, &elem_doc, ex)
        for d in elem_doc {
            append(&body, d)
        }
        append(&body, text(","))
        prev_line = end_line(pr, ex)
        has_prev = true
    }
    flush_before(pr, &body, prev_line, has_prev, close_line, true)
    append_brace_close(out, body[:])
}

// Common tail of every brace-body builder: an empty body collapses to "}"
// with no indent/newline of its own, otherwise the body sits on its own
// indented lines with the closing brace on a fresh line.
@(private)
append_brace_close :: proc(out: ^[dynamic]Doc, body: []Doc) {
    if len(body) == 0 {
        append(out, text("}"))
        return
    }
    append(out, indent(body))
    append(out, hard_line(0))
    append(out, text("}"))
}

@(private)
print_bit_field_field :: proc(pr: ^Printer, out: ^[dynamic]Doc, f: Node) {
    cell := align_cell(pr, f)
    in_cell, after_cell := colon_split(pr)
    ks := kids(f)
    colon := tok_index(ks, .Colon)
    bar := tok_index(ks, .Or)

    head: [dynamic]Doc
    if name, ok := expr_in(ks, 0, colon < 0 ? len(ks) : colon); ok {
        print_expr(pr, &head, name)
    }
    append(&head, text(in_cell))
    if cell.head != 0 {
        append(out, align(cell.head, head[:]))
    } else {
        append(out, ..head[:])
    }
    append(out, text(after_cell))

    type_doc: [dynamic]Doc
    if t, ok := expr_in(ks, colon + 1, bar < 0 ? len(ks) : bar); ok {
        print_expr(pr, &type_doc, t)
    }
    if cell.value != 0 {
        append(out, align(cell.value, type_doc[:]))
    } else {
        append(out, ..type_doc[:])
    }

    append(out, text(" | "))
    if bar >= 0 {
        if bits, ok := expr_in(ks, bar + 1, len(ks)); ok {
            print_expr(pr, out, bits)
        }
    }
    if i := tok_index(ks, .String); i >= 0 {
        append(out, text(" "))
        append(out, text(node_text(pr, ks[i])))
    }
}

// A bit-field field is always `name: type | bits`, so every member of a run is
// alignable: the head cell lines up the types, the value cell the `|`.
@(private)
assign_bit_field_align_ids :: proc(pr: ^Printer, fields: []Node) {
    if !pr.opts.align_struct_fields && !pr.opts.align_struct_values {
        return
    }
    for i := 0; i < len(fields); {
        end := i + 1
        for end < len(fields) && same_align_run(pr, end_line(pr, fields[end - 1]), start_line(pr, fields[end])) {
            end += 1
        }
        if end - i >= 2 {
            head_id := pr.opts.align_struct_fields ? next_align(pr) : 0
            value_id := pr.opts.align_struct_values ? next_align(pr) : 0
            for f in fields[i:end] {
                pr.align_ids[align_key(f)] = Align_Cell{head = head_id, value = value_id}
            }
        }
        i = end
    }
}

@(private)
print_bit_field_brace_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, close_line: int, fields: []Node) {
    assign_bit_field_align_ids(pr, fields)
    append(out, text("{"))
    if len(fields) == 0 {
        body: [dynamic]Doc
        flush_before(pr, &body, 0, false, close_line, true)
        append_brace_close(out, body[:])
        return
    }
    body: [dynamic]Doc
    prev_line, has_prev := flush_before(pr, &body, 0, false, start_line(pr, fields[0]), true)
    append(&body, hard_line(0))
    for f, i in fields {
        if i > 0 {
            separator(pr, &body, prev_line, has_prev, start_line(pr, f), true)
        }
        field_doc: [dynamic]Doc
        print_bit_field_field(pr, &field_doc, f)
        for d in field_doc {
            append(&body, d)
        }
        append(&body, text(","))
        prev_line = end_line(pr, f)
        has_prev = true
    }
    flush_before(pr, &body, prev_line, has_prev, close_line, true)
    append_brace_close(out, body[:])
}

@(private)
print_where :: proc(pr: ^Printer, out: ^[dynamic]Doc, clause: Node) {
    constraints := expr_kids(kids(clause))
    if len(constraints) == 0 {
        return
    }
    append(out, text(" where "))
    print_expr_list(pr, out, constraints)
}
