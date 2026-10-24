package odinsema

import "core:strconv"
import "core:strings"

import odinsyntax "../syntax"

// The value of a constant expression. Integers are exact: a result that does not fit i64 is not known.
Const_Value :: union {
    i64,
    f64,
    string,
    bool,
    rune,
}

// The value of the constant expression `n` of `file`. False when it is not constant, not known,
// overflows or divides by zero. A string the evaluation makes is in the checker arena.
const_eval :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (Const_Value, bool) {
    n := n
    #partial switch n.green.kind {
    case .Literal:
        return literal_value(c, n)
    case .Paren_Expr:
        p, _ := odinsyntax.as_paren_expr(n)
        inner, ok := odinsyntax.paren_expr_expr(&p)
        if !ok {
            return nil, false
        }
        return const_eval(c, file, inner)
    case .Ident:
        name := odinsyntax.node_text(n)
        #reverse for m in c.enum_env {
            if m.name == name {
                return m.value, true
            }
        }
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        op, has_op := odinsyntax.unary_expr_op(&u)
        operand, has_operand := odinsyntax.unary_expr_operand(&u)
        if !has_op || !has_operand {
            return nil, false
        }
        v, ok := const_eval(c, file, operand)
        if !ok {
            return nil, false
        }
        return const_unary(op.green.kind, v)
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(n)
        op, has_op := odinsyntax.binary_expr_op(&b)
        lhs, has_lhs := odinsyntax.binary_expr_lhs(&b)
        rhs, has_rhs := odinsyntax.binary_expr_rhs(&b)
        if !has_op || !has_lhs || !has_rhs {
            return nil, false
        }
        if v, ok := enum_name_compare(c, file, op.green.kind, lhs, rhs); ok {
            return v, true
        }
        l, lok := const_eval(c, file, lhs)
        if !lok {
            return nil, false
        }
        r, rok := const_eval(c, file, rhs)
        if !rok {
            return nil, false
        }
        return const_binary(c, op.green.kind, l, r)
    case .Ternary_Expr:
        t, _ := odinsyntax.as_ternary_expr(n)
        return const_choose(c, file, odinsyntax.ternary_expr_cond(&t), odinsyntax.ternary_expr_then(&t), odinsyntax.ternary_expr_else_value(&t))
    case .Ternary_If_Expr:
        t, _ := odinsyntax.as_ternary_if_expr(n)
        return const_choose(c, file, odinsyntax.ternary_if_expr_cond(&t), odinsyntax.ternary_if_expr_then(&t), odinsyntax.ternary_if_expr_else_value(&t))
    case .Ternary_When_Expr:
        t, _ := odinsyntax.as_ternary_when_expr(n)
        return const_choose(c, file, odinsyntax.ternary_when_expr_cond(&t), odinsyntax.ternary_when_expr_then(&t), odinsyntax.ternary_when_expr_else_value(&t))
    case .Selector_Expr, .Call_Expr:
    case:
        return nil, false
    }
    op := expr_type(c, file, n)
    if op.mode != .Const || op.value == nil {
        return nil, false
    }
    return op.value, true
}

// `ODIN_OS == .Windows`: a build constant whose value is an enum member, against an implicit selector.
@(private = "file")
enum_name_compare :: proc(c: ^Checker, file: File_Id, op: odinsyntax.Token_Kind, lhs, rhs: odinsyntax.Syntax_Node) -> (Const_Value, bool) {
    if op != .Cmp_Eq && op != .Not_Eq {
        return nil, false
    }
    ident, member := lhs, rhs
    if ident.green.kind == .Implicit_Selector {
        ident, member = rhs, lhs
    }
    if ident.green.kind != .Ident || member.green.kind != .Implicit_Selector {
        return nil, false
    }
    name := odinsyntax.node_text(ident)
    if r := lookup_name(c, file, name, int(ident.offset)); r.kind != .Builtin {
        return nil, false
    }
    v := constant_value(name, c.snap.target)
    if v.kind != .Name {
        return nil, false
    }
    is, _ := odinsyntax.as_implicit_selector(member)
    field, ok := odinsyntax.implicit_selector_field(&is)
    if !ok {
        return nil, false
    }
    equal := odinsyntax.node_text(odinsyntax.Syntax_Node(field)) == v.s
    return op == .Cmp_Eq ? equal : !equal, true
}

// `cond ? then : other` with a constant condition.
@(private = "file")
const_choose :: proc(c: ^Checker, file: File_Id, cond: odinsyntax.Syntax_Node, has_cond: bool, then: odinsyntax.Syntax_Node, has_then: bool, other: odinsyntax.Syntax_Node, has_other: bool) -> (Const_Value, bool) {
    if !has_cond || !has_then || !has_other {
        return nil, false
    }
    v, ok := const_eval(c, file, cond)
    b, is_bool := v.(bool)
    if !ok || !is_bool {
        return nil, false
    }
    return const_eval(c, file, b ? then : other)
}

// The integer a constant holds: an integer or a rune.
const_to_i64 :: proc(v: Const_Value) -> (i64, bool) {
    #partial switch x in v {
    case i64:
        return x, true
    case rune:
        return i64(x), true
    }
    return 0, false
}

@(private = "file")
const_to_f64 :: proc(v: Const_Value) -> (f64, bool) {
    #partial switch x in v {
    case i64:
        return f64(x), true
    case rune:
        return f64(x), true
    case f64:
        return x, true
    }
    return 0, false
}

// The value of a literal token.
@(private = "file")
literal_value :: proc(c: ^Checker, n: odinsyntax.Syntax_Node) -> (Const_Value, bool) {
    lit, _ := odinsyntax.as_literal(n)
    tok, ok := odinsyntax.literal_token(&lit)
    if !ok {
        return nil, false
    }
    text := odinsyntax.syntax_token_text(tok)
    #partial switch tok.green.kind {
    case .Integer:
        v, iok := parse_integer(text)
        return v, iok
    case .Float:
        if strings.has_prefix(text, "0h") {
            return nil, false
        }
        clean, _ := strings.remove_all(text, "_", c.alloc)
        v, fok := strconv.parse_f64(clean)
        return v, fok
    case .Rune:
        if len(text) < 3 || text[0] != '\'' {
            return nil, false
        }
        r, _, tail, rok := strconv.unquote_char(text[1:], '\'')
        if !rok || tail != "'" {
            return nil, false
        }
        return r, true
    case .String:
        s, _, sok := strconv.unquote_string(text, c.alloc)
        if !sok {
            return nil, false
        }
        return s, true
    }
    return nil, false
}

// An integer literal with an optional base prefix and `_` separators; false when it does not fit i64.
@(private = "file")
parse_integer :: proc(text: string) -> (i64, bool) {
    s := text
    base: u64 = 10
    if len(s) > 2 && s[0] == '0' {
        switch s[1] {
        case 'b': base, s = 2, s[2:]
        case 'o': base, s = 8, s[2:]
        case 'd': base, s = 10, s[2:]
        case 'z': base, s = 12, s[2:]
        case 'x': base, s = 16, s[2:]
        }
    }
    value: u64
    digits := 0
    for ch in transmute([]u8)s {
        d: u64
        switch ch {
        case '_':
            continue
        case '0' ..= '9':
            d = u64(ch - '0')
        case 'a' ..= 'z':
            d = u64(ch - 'a') + 10
        case 'A' ..= 'Z':
            d = u64(ch - 'A') + 10
        case:
            return 0, false
        }
        if d >= base {
            return 0, false
        }
        if value > (u64(max(i64)) - d) / base {
            return 0, false
        }
        value = value * base + d
        digits += 1
    }
    return i64(value), digits > 0
}

@(private = "file")
const_unary :: proc(op: odinsyntax.Token_Kind, v: Const_Value) -> (Const_Value, bool) {
    #partial switch op {
    case .Add:
        #partial switch _ in v {
        case i64, f64, rune:
            return v, true
        }
    case .Sub:
        #partial switch x in v {
        case i64:
            if x == min(i64) {
                return nil, false
            }
            return -x, true
        case f64:
            return -x, true
        case rune:
            return -x, true
        }
    case .Xor:
        #partial switch x in v {
        case i64:
            return ~x, true
        case rune:
            return ~x, true
        }
    case .Not:
        if b, ok := v.(bool); ok {
            return !b, true
        }
    }
    return nil, false
}

@(private)
const_binary :: proc(c: ^Checker, op: odinsyntax.Token_Kind, l, r: Const_Value) -> (Const_Value, bool) {
    #partial switch op {
    case .Cmp_And, .Cmp_Or:
        lb, lok := l.(bool)
        rb, rok := r.(bool)
        if !lok || !rok {
            return nil, false
        }
        return op == .Cmp_And ? lb && rb : lb || rb, true
    case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
        return const_compare(op, l, r)
    }
    ls, l_string := l.(string)
    rs, r_string := r.(string)
    if l_string || r_string {
        if !l_string || !r_string || op != .Add {
            return nil, false
        }
        joined, err := strings.concatenate({ls, rs}, c.alloc)
        if err != nil {
            return nil, false
        }
        return joined, true
    }
    _, l_float := l.(f64)
    _, r_float := r.(f64)
    if l_float || r_float {
        a, aok := const_to_f64(l)
        b, bok := const_to_f64(r)
        if !aok || !bok {
            return nil, false
        }
        #partial switch op {
        case .Add: return a + b, true
        case .Sub: return a - b, true
        case .Mul: return a * b, true
        case .Quo:
            if b == 0 {
                return nil, false
            }
            return a / b, true
        }
        return nil, false
    }
    a, aok := const_to_i64(l)
    b, bok := const_to_i64(r)
    if !aok || !bok {
        return nil, false
    }
    v, ok := int_binary(op, a, b)
    if !ok {
        return nil, false
    }
    _, l_rune := l.(rune)
    _, r_rune := r.(rune)
    if l_rune || r_rune {
        if v < i64(min(i32)) || v > i64(max(i32)) {
            return nil, false
        }
        return rune(v), true
    }
    return v, true
}

// Integer arithmetic with Odin semantics: `/` and `%` truncate, `%%` floors; false on overflow or division by zero.
@(private = "file")
int_binary :: proc(op: odinsyntax.Token_Kind, a, b: i64) -> (i64, bool) {
    #partial switch op {
    case .Add:
        if (b > 0 && a > max(i64) - b) || (b < 0 && a < min(i64) - b) {
            return 0, false
        }
        return a + b, true
    case .Sub:
        if (b < 0 && a > max(i64) + b) || (b > 0 && a < min(i64) + b) {
            return 0, false
        }
        return a - b, true
    case .Mul:
        if a == 0 || b == 0 {
            return 0, true
        }
        if (a == -1 && b == min(i64)) || (b == -1 && a == min(i64)) {
            return 0, false
        }
        p := a * b
        if p / b != a {
            return 0, false
        }
        return p, true
    case .Quo:
        if b == 0 || (a == min(i64) && b == -1) {
            return 0, false
        }
        return a / b, true
    case .Mod:
        if b == 0 {
            return 0, false
        }
        if b == -1 {
            return 0, true
        }
        return a % b, true
    case .Mod_Mod:
        if b == 0 {
            return 0, false
        }
        if b == -1 {
            return 0, true
        }
        m := a % b
        if m != 0 && (m < 0) != (b < 0) {
            m += b
        }
        return m, true
    case .And:
        return a & b, true
    case .Or:
        return a | b, true
    case .Xor:
        return a ~ b, true
    case .And_Not:
        return a &~ b, true
    case .Shl:
        if b < 0 {
            return 0, false
        }
        if a == 0 {
            return 0, true
        }
        if b >= 63 {
            return 0, false
        }
        v := a << u64(b)
        if v >> u64(b) != a {
            return 0, false
        }
        return v, true
    case .Shr:
        if b < 0 {
            return 0, false
        }
        if b >= 64 {
            return a < 0 ? -1 : 0, true
        }
        return a >> u64(b), true
    }
    return 0, false
}

@(private = "file")
const_compare :: proc(op: odinsyntax.Token_Kind, l, r: Const_Value) -> (Const_Value, bool) {
    order: int
    #partial switch x in l {
    case string:
        y, ok := r.(string)
        if !ok {
            return nil, false
        }
        order = strings.compare(x, y)
    case bool:
        y, ok := r.(bool)
        if !ok || (op != .Cmp_Eq && op != .Not_Eq) {
            return nil, false
        }
        order = x == y ? 0 : 1
    case:
        _, l_float := l.(f64)
        _, r_float := r.(f64)
        if l_float || r_float {
            a, aok := const_to_f64(l)
            b, bok := const_to_f64(r)
            if !aok || !bok {
                return nil, false
            }
            order = a < b ? -1 : a > b ? 1 : 0
        } else {
            a, aok := const_to_i64(l)
            b, bok := const_to_i64(r)
            if !aok || !bok {
                return nil, false
            }
            order = a < b ? -1 : a > b ? 1 : 0
        }
    }
    #partial switch op {
    case .Cmp_Eq: return order == 0, true
    case .Not_Eq: return order != 0, true
    case .Lt:     return order < 0, true
    case .Gt:     return order > 0, true
    case .Lt_Eq:  return order <= 0, true
    case .Gt_Eq:  return order >= 0, true
    }
    return nil, false
}

// A constant converted to type `t`: `int(2.0)`, `f32(1)`, `rune(65)`. False when the conversion
// loses the value or `t` is not a basic type.
const_convert :: proc(c: ^Checker, t: Type_Id, v: Const_Value) -> (Const_Value, bool) {
    table := &c.table
    switch {
    case type_is_float(table, t):
        f, ok := const_to_f64(v)
        return f, ok
    case type_is_integer(table, t):
        if f, is_float := v.(f64); is_float {
            if f != f64(i64(f)) {
                return nil, false
            }
            if b, ok := type_get(table, type_base(table, t)).(Basic_Type); ok && b.kind == .Rune {
                return rune(i64(f)), true
            }
            return i64(f), true
        }
        i, ok := const_to_i64(v)
        if !ok {
            return nil, false
        }
        if b, bok := type_get(table, type_base(table, t)).(Basic_Type); bok && b.kind == .Rune {
            return rune(i), true
        }
        return i, true
    case type_is_string(table, t):
        s, ok := v.(string)
        return s, ok
    case type_is_boolean(table, t):
        b, ok := v.(bool)
        return b, ok
    }
    return nil, false
}
