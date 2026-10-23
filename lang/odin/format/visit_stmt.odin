// Statement and declaration printing, plus the brace-delimited-list machinery
// blocks, switches and asm bodies build on.
package odinfmt

import "core:slice"
import "core:strings"

@(private)
Item_Printer :: #type proc(pr: ^Printer, out: ^[dynamic]Doc, item: Node)

// Prints "{ ...items... }", one item per line via `printer`, preserving
// blank-line gaps and interleaved comments; `extra_indent` adds one more
// indent level around each item (indent_cases, for switch case bodies).
@(private)
print_brace_body :: proc(
    pr: ^Printer,
    out: ^[dynamic]Doc,
    open_line, close_line: int,
    stmts: []Node,
    printer: Item_Printer,
    extra_indent: bool,
) {
    assign_decl_align_ids(pr, stmts)
    append(out, text("{"))
    body: [dynamic]Doc
    prev_line := open_line
    has_prev := true
    for stmt in stmts {
        separator(pr, &body, prev_line, has_prev, start_line(pr, stmt), true)
        item: [dynamic]Doc
        printer(pr, &item, stmt)
        if extra_indent {
            append(&body, indent(item[:]))
        } else {
            for d in item {
                append(&body, d)
            }
        }
        prev_line = end_line(pr, stmt)
        has_prev = true
    }
    flush_before(pr, &body, prev_line, has_prev, close_line, true)
    if len(body) == 0 {
        append(out, text("}"))
        return
    }
    append(out, indent(body[:]))
    append(out, hard_line(0))
    append(out, text("}"))
}

@(private)
print_stmt_item :: proc(pr: ^Printer, out: ^[dynamic]Doc, item: Node) {
    print_stmt(pr, out, item)
}

// The lines of the braces of a block, and the statements between them.
@(private)
block_parts :: proc(pr: ^Printer, block: Node) -> (open_line, close_line: int, stmts: []Node) {
    ks := kids(block)
    open_line = start_line(pr, block)
    close_line = end_line(pr, block)
    if i := tok_index(ks, .Open_Brace); i >= 0 {
        open_line = start_line(pr, ks[i])
    }
    if i := tok_index(ks, .Close_Brace); i >= 0 {
        close_line = start_line(pr, ks[i])
    }
    return open_line, close_line, stmt_kids(ks)
}

@(private)
print_block :: proc(pr: ^Printer, out: ^[dynamic]Doc, block: Node, is_proc_body: bool) {
    print_brace_lead(pr, out, is_proc_body)
    print_block_braces(pr, out, block)
}

// The block from its `{`, with nothing before it.
@(private)
print_block_braces :: proc(pr: ^Printer, out: ^[dynamic]Doc, block: Node) {
    open_line, close_line, stmts := block_parts(pr, block)
    if print_one_line_block(pr, out, open_line, close_line, stmts) {
        return
    }
    print_brace_body(pr, out, open_line, close_line, stmts, print_stmt_item, false)
}

// `{ stmt }` for a block the source already wrote on one line, under
// space_single_line_blocks. Decided from the source alone, never from a width
// measurement, so a second format sees the same one-line source and makes the
// same choice. The option never collapses a block the source spread over lines
// — it only declines to expand one.
@(private)
print_one_line_block :: proc(pr: ^Printer, out: ^[dynamic]Doc, open_line, close_line: int, stmts: []Node) -> bool {
    if !pr.opts.space_single_line_blocks || open_line != close_line || len(stmts) != 1 {
        return false
    }
    // A comment inside would need a separator, and a separator emits a line.
    for cg in pr.comments[pr.comment_idx:] {
        if cg.line > close_line {
            break
        }
        if cg.line >= open_line {
            return false
        }
    }

    item: [dynamic]Doc
    print_stmt(pr, &item, stmts[0])
    if _, flat := measure_flat_children(item[:], &pr.opts); !flat {
        return false
    }
    append(out, text("{ "))
    append(out, ..item[:])
    append(out, text(" }"))
    return true
}

// A statement/proc body: a `do stmt` shorthand (kept unless convert_do),
// a real block, or — defensively — some other stmt kind.
@(private)
print_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, body: Node, is_proc_body: bool) {
    if !is_node(body) {
        return
    }
    #partial switch body.kind {
    case .Block:
        print_block(pr, out, body, is_proc_body)
        return
    case .Do_Body:
        ks := kids(body)
        stmts := stmt_kids(ks)
        if !pr.opts.convert_do {
            append(out, text(" do "))
            if len(stmts) > 0 {
                print_stmt(pr, out, stmts[0])
            }
            return
        }
        open_line := start_line(pr, body)
        close_line := end_line(pr, body)
        print_brace_lead(pr, out, is_proc_body)
        if print_one_line_block(pr, out, open_line, close_line, stmts) {
            return
        }
        print_brace_body(pr, out, open_line, close_line, stmts, print_stmt_item, false)
        return
    }
    append(out, text(" "))
    print_stmt(pr, out, body)
}

@(private)
print_else :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    at := tok_index(ks, .Else)
    if at < 0 || at + 1 >= len(ks) {
        return
    }
    else_stmt := ks[at + 1]
    if else_own_line(pr) {
        append(out, hard_line(0))
    } else {
        append(out, text(" "))
    }
    append(out, text("else"))
    if else_stmt.kind == .If_Stmt || else_stmt.kind == .When_Stmt {
        append(out, text(" "))
        print_stmt(pr, out, else_stmt)
        return
    }
    print_body(pr, out, else_stmt, false)
}

// The end of the maximal run of import declarations starting at `i` that is
// safe to reorder: consecutive plain imports, one per line with no blank line
// between them, and no comment on any line the run covers. A comment inside pins
// every member — flush_trailing attaches a trailing comment by line, so moving
// the import it belongs to would re-attach it to a different one. Returns `i`
// when nothing at `i` is sortable.
//
// That restriction is also what keeps the comment cursor happy: every separator
// inside such a run is exactly hard_line(0), so the run prints its own newlines
// and never advances pr.comment_idx out of source order.
@(private)
import_run_end :: proc(pr: ^Printer, stmts: []Node, i: int) -> int {
    end := i
    for end < len(stmts) {
        if !plain_import(stmts[end]) {
            break
        }
        // Adjacent lines only: a comment line between ends a sortable run.
        if end > i && start_line(pr, stmts[end]) != end_line(pr, stmts[end - 1]) + 1 {
            break
        }
        end += 1
    }
    if end - i < 2 {
        return i
    }
    // A trailing comment on one of the run's lines pins it too.
    first_line := start_line(pr, stmts[i])
    last_line := end_line(pr, stmts[end - 1])
    for cg in pr.comments[pr.comment_idx:] {
        if cg.line < first_line {
            continue
        }
        if cg.line > last_line {
            break
        }
        return i
    }
    return end
}

@(private)
plain_import :: proc(stmt: Node) -> bool {
    if stmt.kind != .Import_Decl {
        return false
    }
    for k in kids(stmt) {
        if k.kind == .Attribute || is_tok(k, .Using) {
            return false
        }
    }
    return true
}

// Collection-qualified paths (base:, core:, vendor:) sort before local ones, so
// the conventional block shape survives a sort of a run that mixes them — a
// plain lexical sort would pull "../x" to the front.
@(private)
import_rank :: proc(path: string) -> int {
    if strings.contains(path, ":") {
        return 0
    }
    return 1
}

// One import of a sortable run, with the keys it sorts by.
@(private)
Sorted_Import :: struct {
    node:  Node,
    path:  string,
    alias: string,
}

@(private)
import_less :: proc(a, b: Sorted_Import) -> bool {
    if ra, rb := import_rank(a.path), import_rank(b.path); ra != rb {
        return ra < rb
    }
    if a.path != b.path {
        return a.path < b.path
    }
    return a.alias < b.alias
}

// Prints every element of `stmts` in source order, as top-level-flat siblings
// (each preceded by the comment/blank-line separator, no braces of its own —
// the caller supplies those). Returns the line/has-prev state to continue
// from, so a caller can flush trailing comments afterward.
@(private)
print_stmt_list :: proc(
    pr: ^Printer,
    out: ^[dynamic]Doc,
    stmts: []Node,
    prev_line: int,
    has_prev: bool,
) -> (
    last_line: int,
    had_prev: bool,
) {
    assign_decl_align_ids(pr, stmts)
    last_line = prev_line
    had_prev = has_prev
    for i := 0; i < len(stmts); {
        stmt := stmts[i]
        if pr.opts.sort_imports {
            if end := import_run_end(pr, stmts, i); end > i {
                run := make([]Sorted_Import, end - i)
                for member, n in stmts[i:end] {
                    alias, path := import_parts(pr, kids(member))
                    run[n] = Sorted_Import{member, strings.trim(path, `"`), alias}
                }
                slice.sort_by(run, import_less)
                separator(pr, out, last_line, had_prev, start_line(pr, stmt), true)
                for member, n in run {
                    if n > 0 {
                        append(out, hard_line(0))
                    }
                    print_stmt(pr, out, member.node)
                }
                // The run's last *source* line, not the last printed one, so
                // the next declaration's blank-line gap measures exactly as it
                // would have unsorted.
                last_line = end_line(pr, stmts[end - 1])
                had_prev = true
                i = end
                continue
            }
        }
        separator(pr, out, last_line, had_prev, start_line(pr, stmt), true)
        print_stmt(pr, out, stmt)
        last_line = end_line(pr, stmt)
        had_prev = true
        i += 1
    }
    return
}

// Which alignment run a `Name :: value` declaration may join. A type
// declaration and a plain constant are different shapes and never share one, so
// `Foo :: struct {` next to `MAX :: 64` aligns neither against the other.
@(private)
Const_Run_Kind :: enum {
    None,
    Type_Decl, // align_struct_declarations
    Constant,  // align_constant_definitions
}

// An attributed or `using` declaration is left out: it emits its attributes and
// a hard line before the name, so its cell would not start at the run's column.
@(private)
const_run_kind :: proc(stmt: Node) -> Const_Run_Kind {
    if stmt.kind != .Value_Decl {
        return .None
    }
    ks := kids(stmt)
    if len(ks) == 0 || ks[0].kind != .Name_List {
        return .None
    }
    v := value_decl_parts(ks)
    if v.mutable || v.using_ || is_node(v.type) || len(v.values) != 1 || len(v.names) == 0 {
        return .None
    }
    #partial switch v.values[0].kind {
    case .Struct_Type, .Union_Type, .Enum_Type, .Bit_Field_Type:
        return .Type_Decl
    }
    return .Constant
}

// One head id per maximal run of two or more same-kind declarations on adjacent
// lines, so their `::` line up. Called by both sibling walkers, so a run inside
// a block aligns exactly like one at file scope.
@(private)
assign_decl_align_ids :: proc(pr: ^Printer, stmts: []Node) {
    if !pr.opts.align_constant_definitions && !pr.opts.align_struct_declarations {
        return
    }
    for i := 0; i < len(stmts); {
        kind := const_run_kind(stmts[i])
        wanted := kind == .Type_Decl ? pr.opts.align_struct_declarations : pr.opts.align_constant_definitions
        if kind == .None || !wanted {
            i += 1
            continue
        }
        end := i + 1
        for end < len(stmts) &&
            const_run_kind(stmts[end]) == kind &&
            same_align_run(pr, end_line(pr, stmts[end - 1]), start_line(pr, stmts[end])) {
            end += 1
        }
        if end - i >= 2 {
            id := next_align(pr)
            for stmt in stmts[i:end] {
                pr.align_ids[align_key(stmt)] = Align_Cell{head = id}
            }
        }
        i = end
    }
}

@(private)
print_case_item :: proc(pr: ^Printer, out: ^[dynamic]Doc, item: Node) {
    print_case_clause(pr, out, item)
}

@(private)
print_case_clause :: proc(pr: ^Printer, out: ^[dynamic]Doc, cc: Node) {
    ks := kids(cc)
    append(out, text("case"))
    colon := tok_index(ks, .Colon)
    if list, ok := find_kind(ks, .Expr_List); ok && (colon < 0 || list.start < ks[colon].start) {
        values := expr_kids(kids(list))
        if len(values) > 0 {
            // Too long for character_width, the list breaks after each comma before
            // any item breaks inside itself.
            append(out, text(" "))
            head: [dynamic]Doc
            print_expr(pr, &head, values[0])
            rest: [dynamic]Doc
            for e in values[1:] {
                append(&rest, text(","))
                append(&rest, line())
                print_expr(pr, &rest, e)
            }
            append(&head, indent(rest[:]))
            append(out, group(head[:]))
        }
    }
    append(out, text(":"))
    body := stmt_kids(ks[colon + 1:]) if colon >= 0 else []Node{}
    if len(body) == 0 {
        return
    }
    if pr.opts.inline_single_stmt_case && len(body) == 1 && body[0].kind != .Block {
        append(out, text(" "))
        print_stmt(pr, out, body[0])
        return
    }
    out_body: [dynamic]Doc
    // No flush here: the enclosing print_brace_body bounds any trailing
    // comment against the next case (or the switch's close) on its own next
    // separator call — flushing here would consume comments belonging to it.
    // Counted from the colon: a wrapped case list ends on a later line than `case`.
    head_line := start_line(pr, ks[colon])
    print_stmt_list(pr, &out_body, body, head_line, true)
    append(out, indent(out_body[:]))
}

@(private)
print_switch_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    block, ok := find_kind(ks, .Block)
    if !ok {
        append(out, text(" {}"))
        return
    }
    bks := kids(block)
    clauses := make([dynamic]Node, 0, len(bks))
    for k in bks {
        if k.kind == .Case_Clause {
            append(&clauses, k)
        }
    }
    open_line, close_line, _ := block_parts(pr, block)
    print_brace_lead(pr, out, false, len(clauses) == 0)
    print_brace_body(pr, out, open_line, close_line, clauses[:], print_case_item, pr.opts.indent_cases)
}

// The simple statement before the first `;` of a header, if any.
@(private)
header_init :: proc(ks: []Node) -> Node {
    semi := tok_index(ks, .Semicolon)
    if semi < 0 {
        return {}
    }
    for k in ks[:semi] {
        if is_node(k) && (k.kind == .Value_Decl || k.kind == .Assign_Stmt || k.kind == .Expr_Stmt) {
            return k
        }
    }
    return {}
}

// The body of a control statement: its last Block or Do_Body.
@(private)
stmt_body :: proc(ks: []Node, before := -1) -> Node {
    stop := before < 0 ? len(ks) : before
    body: Node
    for k in ks[:stop] {
        if k.kind == .Block || k.kind == .Do_Body {
            body = k
        }
    }
    return body
}

print_stmt :: proc(pr: ^Printer, out: ^[dynamic]Doc, stmt: Node) {
    if !is_node(stmt) || pr.too_deep {
        return
    }
    pr.depth += 1
    defer pr.depth -= 1
    if pr.depth > MAX_DEPTH {
        pr.too_deep = true
        return
    }
    all := kids(stmt)
    ks, after_label := print_stmt_prefix(pr, out, all)
    if after_label && stmt.kind != .Block {
        append(out, text(" "))
    }
    #partial switch stmt.kind {
    case .Expr_Stmt:
        for k in ks {
            if is_expr(k) {
                print_expr(pr, out, k)
            }
        }

    case .Assign_Stmt:
        lists := make([dynamic]Node, 0, 2)
        op := ""
        for k in ks {
            if k.kind == .Expr_List {
                append(&lists, k)
            } else if !is_node(k) && op == "" {
                op = node_text(pr, k)
            }
        }
        if len(lists) > 0 {
            print_expr_list(pr, out, expr_kids(kids(lists[0])))
        }
        append(out, text(" "))
        append(out, text(op))
        append(out, text(" "))
        if len(lists) > 1 {
            print_expr_list(pr, out, expr_kids(kids(lists[1])))
        }

    case .Block:
        if after_label {
            print_block(pr, out, stmt, false)
        } else {
            print_block_braces(pr, out, stmt)
        }

    case .If_Stmt:
        append(out, text("if "))
        if init := header_init(ks); is_node(init) {
            print_stmt(pr, out, init)
            append(out, text("; "))
        }
        else_at := tok_index(ks, .Else)
        stop := else_at < 0 ? len(ks) : else_at
        semi := tok_index(ks, .Semicolon)
        if cond, ok := expr_in(ks, semi + 1, stop); ok {
            print_expr(pr, out, cond)
        }
        print_body(pr, out, stmt_body(ks, else_at), false)
        print_else(pr, out, ks)

    case .When_Stmt:
        append(out, text("when "))
        else_at := tok_index(ks, .Else)
        stop := else_at < 0 ? len(ks) : else_at
        if cond, ok := expr_in(ks, 0, stop); ok {
            print_expr(pr, out, cond)
        }
        print_body(pr, out, stmt_body(ks, else_at), false)
        print_else(pr, out, ks)

    case .Return_Stmt:
        append(out, text("return"))
        if list, ok := find_kind(ks, .Expr_List); ok {
            values := expr_kids(kids(list))
            if len(values) > 0 {
                append(out, text(" "))
                print_expr_list(pr, out, values)
            }
        }

    case .Defer_Stmt:
        append(out, text("defer "))
        for k in ks {
            if is_stmt(k) {
                print_stmt(pr, out, k)
                break
            }
        }

    case .For_Stmt:
        print_for_stmt(pr, out, ks)

    case .Range_Stmt:
        append(out, text("for "))
        in_at := tok_index(ks, .In)
        if list, ok := find_kind(ks, .Expr_List); ok && (in_at < 0 || list.start < ks[in_at].start) {
            print_expr_list(pr, out, expr_kids(kids(list)))
        }
        append(out, text(" in "))
        if in_at >= 0 {
            if e, ok := expr_in(ks, in_at + 1, len(ks)); ok {
                print_expr(pr, out, e)
            }
        }
        print_body(pr, out, stmt_body(ks), false)

    case .Switch_Stmt:
        append(out, text("switch"))
        init := header_init(ks)
        semi := tok_index(ks, .Semicolon)
        tag, has_tag := expr_in(ks, semi + 1, len(ks))
        if is_node(init) || has_tag {
            append(out, text(" "))
            if is_node(init) {
                print_stmt(pr, out, init)
                append(out, text("; "))
            }
            if has_tag {
                print_expr(pr, out, tag)
            }
        }
        print_switch_body(pr, out, ks)

    case .Type_Switch_Stmt:
        append(out, text("switch "))
        if list, ok := find_kind(ks, .Expr_List); ok {
            print_expr_list(pr, out, expr_kids(kids(list)))
        }
        append(out, text(" in "))
        if in_at := tok_index(ks, .In); in_at >= 0 {
            if e, ok := expr_in(ks, in_at + 1, len(ks)); ok {
                print_expr(pr, out, e)
            }
        }
        print_switch_body(pr, out, ks)

    case .Case_Clause:
        print_case_clause(pr, out, stmt)

    case .Branch_Stmt:
        for k in ks {
            if !is_node(k) {
                append(out, text(node_text(pr, k)))
            } else if k.kind == .Ident {
                append(out, text(" "))
                print_expr(pr, out, k)
            }
        }

    case .Using_Stmt:
        append(out, text("using "))
        if list, ok := find_kind(ks, .Expr_List); ok {
            print_expr_list(pr, out, expr_kids(kids(list)))
        }

    case .Asm_Instruction:
        print_asm_instruction(pr, out, ks)

    case .Asm_Label_Decl:
        print_asm_label_decl(pr, out, ks)

    case .Asm_Directive:
        print_asm_directive(pr, out, ks)

    case .Value_Decl:
        print_value_decl(pr, out, stmt, ks)

    case .Import_Decl:
        print_import_decl(pr, out, ks)

    case .Foreign_Block:
        print_foreign_block_decl(pr, out, ks)

    case .Foreign_Import_Decl:
        print_foreign_import_decl(pr, out, ks)
    }
}

@(private)
print_for_stmt :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    append(out, text("for"))
    first := tok_index(ks, .Semicolon)
    init, cond, post: Node
    if first < 0 {
        cond, _ = expr_in(ks, 0, len(ks))
    } else {
        init = header_init(ks)
        second := tok_index(ks, .Semicolon, first + 1)
        stop := second < 0 ? len(ks) : second
        cond, _ = expr_in(ks, first + 1, stop)
        if second >= 0 {
            for k in ks[second + 1:] {
                if k.kind == .Value_Decl || k.kind == .Assign_Stmt || k.kind == .Expr_Stmt {
                    post = k
                    break
                }
            }
        }
    }
    switch {
    case !is_node(init) && !is_node(cond) && !is_node(post):
    case !is_node(init) && !is_node(post) && is_node(cond):
        append(out, text(" "))
        print_expr(pr, out, cond)
    case:
        append(out, text(" "))
        if is_node(init) {
            print_stmt(pr, out, init)
        }
        append(out, text("; "))
        if is_node(cond) {
            print_expr(pr, out, cond)
        }
        append(out, text("; "))
        if is_node(post) {
            print_stmt(pr, out, post)
        }
    }
    print_body(pr, out, stmt_body(ks), false)
}
