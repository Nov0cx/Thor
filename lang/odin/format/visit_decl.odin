// The file entry point and the declaration kinds that can appear at file scope:
// value (var/const), import, and the two foreign forms.
package odinfmt

import "core:strings"

print_file :: proc(pr: ^Printer, root: Node) -> Doc {
    out: [dynamic]Doc

    prev_line := 0
    has_prev := false
    ks := kids(root)
    // A comment above a tag stays above it, so it does not become the package doc.
    for k in ks {
        if k.kind != .File_Tag {
            continue
        }
        line := start_line(pr, k)
        separator(pr, &out, prev_line, has_prev, line, true)
        append(&out, text(strings.trim_right(node_text(pr, k), " \t")))
        prev_line = line
        has_prev = true
    }

    if pkg, ok := find_kind(ks, .Package_Decl); ok {
        line := start_line(pr, pkg)
        if has_prev {
            // A build tag hugs the package clause by convention: exactly one
            // flat newline down to it (and to any comment strictly between),
            // never blank-line-preserved the way ordinary decls are.
            flush_before(pr, &out, prev_line, has_prev, line, true)
            append(&out, hard_line(0))
        } else {
            separator(pr, &out, prev_line, has_prev, line, true)
        }
        append(&out, text("package "))
        if name, name_ok := find_kind(kids(pkg), .Ident); name_ok {
            append(&out, text(node_text(pr, name)))
        }
        prev_line = end_line(pr, pkg)
        has_prev = true
    }

    prev_line, has_prev = print_stmt_list(pr, &out, stmt_kids(ks), prev_line, has_prev)
    flush_remaining(pr, &out, prev_line, has_prev)
    append(&out, hard_line(0)) // exactly one trailing newline

    return concat_dynamic(out)
}

// The statement nodes in `ks`.
@(private)
stmt_kids :: proc(ks: []Node) -> []Node {
    out := make([dynamic]Node, 0, len(ks))
    for k in ks {
        if is_stmt(k) {
            append(&out, k)
        }
    }
    return out[:]
}

@(private)
value_decl_op :: proc(has_type, is_mutable: bool) -> string {
    switch {
    case !has_type && is_mutable:
        return " := "
    case !has_type && !is_mutable:
        return " :: "
    case has_type && is_mutable:
        return " = "
    case:
        return " : "
    }
}

// The parts of a value declaration after its attributes and directives.
@(private)
Value_Decl_Parts :: struct {
    using_:  bool,
    names:   []Node,
    type:    Node,
    values:  []Node,
    mutable: bool,
}

@(private)
value_decl_parts :: proc(ks: []Node) -> (v: Value_Decl_Parts) {
    first_colon := tok_index(ks, .Colon)
    v.using_ = has_tok(ks, .Using)
    if names, ok := find_kind(ks, .Name_List); ok {
        v.names = expr_kids(kids(names))
    }
    if list, ok := find_kind(ks, .Expr_List); ok {
        v.values = expr_kids(kids(list))
    }
    if first_colon >= 0 {
        second := tok_index(ks, .Colon, first_colon + 1)
        eq := tok_index(ks, .Eq, first_colon + 1)
        stop := len(ks)
        if second >= 0 {
            stop = second
        }
        if eq >= 0 && eq < stop {
            stop = eq
        }
        v.type, _ = expr_in(ks, first_colon + 1, stop)
        v.mutable = second < 0
    }
    return
}

@(private)
print_value_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, d: Node, ks: []Node) {
    v := value_decl_parts(ks)
    if v.using_ {
        append(out, text("using "))
    }
    if cell := align_cell(pr, d); cell.head != 0 {
        names: [dynamic]Doc
        print_expr_list(pr, &names, v.names)
        append(out, align(cell.head, names[:]))
    } else {
        print_expr_list(pr, out, v.names)
    }
    has_type := is_node(v.type)
    if has_type {
        append(out, text(colon_sep(pr)))
        print_expr(pr, out, v.type)
    }
    if len(v.values) > 0 {
        append(out, text(value_decl_op(has_type, v.mutable)))
        print_expr_list(pr, out, v.values)
    } else if !has_type {
        append(out, text(":")) // degenerate but never drop content silently
    }
}

// The quoted path of an import, and its alias.
@(private)
import_parts :: proc(pr: ^Printer, ks: []Node) -> (alias, path: string) {
    for k in ks {
        if k.kind == .Ident {
            alias = node_text(pr, k)
        } else if is_tok(k, .String) {
            path = node_text(pr, k)
        }
    }
    return
}

@(private)
print_import_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    if has_tok(ks, .Using) {
        append(out, text("using "))
    }
    append(out, text("import "))
    alias, path := import_parts(pr, ks)
    if alias != "" {
        append(out, text(alias))
        append(out, text(" "))
    }
    append(out, text(path))
}

@(private)
print_foreign_block_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    append(out, text("foreign"))
    if lib, ok := find_kind(ks, .Ident); ok {
        append(out, text(" "))
        print_expr(pr, out, lib)
    }
    if block, ok := find_kind(ks, .Block); ok {
        print_block(pr, out, block, false)
    }
}

@(private)
print_foreign_import_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    append(out, text("foreign import "))
    if name, ok := find_kind(ks, .Ident); ok && (tok_index(ks, .Open_Brace) < 0 || name.start < ks[tok_index(ks, .Open_Brace)].start) {
        print_expr(pr, out, name)
        append(out, text(" "))
    }
    open := tok_index(ks, .Open_Brace)
    paths := make([dynamic]Node, 0, 2)
    for k, i in ks {
        if is_tok(k, .String) || (open >= 0 && i > open && is_expr(k)) {
            append(&paths, k)
        }
    }
    if len(paths) == 1 {
        append(out, text(node_text(pr, paths[0])))
        return
    }
    append(out, text("{"))
    for p, i in paths {
        if i > 0 {
            append(out, text(", "))
        }
        if is_node(p) {
            print_expr(pr, out, p)
        } else {
            append(out, text(node_text(pr, p)))
        }
    }
    append(out, text("}"))
}
