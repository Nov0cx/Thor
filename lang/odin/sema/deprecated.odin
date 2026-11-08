// Uses of declarations marked `@(deprecated)` (`api/deprecated`).
package odinsema

import odinsyntax "../syntax"

// The offset and name of the identifier of `expr`, a bare name or a selector, when it names a
// declaration with a `deprecated` attribute, and the message of the attribute.
deprecated_use :: proc(c: ^Checker, file: File_Id, expr: odinsyntax.Syntax_Node) -> (offset: int, name, message: string, ok: bool) {
    expr := expr
    ident: odinsyntax.Syntax_Node
    #partial switch expr.green.kind {
    case .Ident:
        ident = expr
    case .Selector_Expr:
        sel, _ := odinsyntax.as_selector_expr(expr)
        field := odinsyntax.selector_expr_field(&sel) or_return
        ident = odinsyntax.Syntax_Node(field)
    case:
        return
    }
    op := expr_type(c, file, expr)
    if op.mode == .Invalid || !op.has_symbol {
        return
    }
    item := checker_item(c, op.symbol)
    if item == nil {
        return
    }
    for a in item.attributes {
        if a.name == "deprecated" {
            return int(ident.offset), odinsyntax.node_text(ident), unquote(a.value), true
        }
    }
    return
}
