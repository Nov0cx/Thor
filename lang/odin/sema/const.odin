package odinsema

import "core:math/big"
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
    Wide_Int,
}

// An integer outside i64 whose magnitude fits u128; one that fits i64 is an i64 instead.
Wide_Int :: struct {
    neg: bool,
    mag: u128,
}

// The constant for a signed magnitude: an i64 when it fits.
wide_value :: proc(neg: bool, mag: u128) -> Const_Value {
    if !neg && mag <= u128(max(i64)) {
        return i64(mag)
    }
    if neg && mag <= u128(max(i64)) + 1 {
        return i64(-i128(mag))
    }
    return Wide_Int{neg, mag}
}

// A signed magnitude in decimal.
wide_text :: proc(neg: bool, mag: u128, allocator := context.allocator) -> string {
    buf: [41]u8
    i := len(buf)
    m := mag
    for {
        i -= 1
        buf[i] = u8('0' + m % 10)
        m /= 10
        if m == 0 {
            break
        }
    }
    if neg {
        i -= 1
        buf[i] = '-'
    }
    return strings.clone(string(buf[i:]), allocator)
}

// The sign and magnitude of an integer constant; false for any other value.
wide_parts :: proc(v: Const_Value) -> (neg: bool, mag: u128, ok: bool) {
    #partial switch x in v {
    case i64:
        return x < 0, x < 0 ? u128(-i128(x)) : u128(x), true
    case Wide_Int:
        return x.neg, x.mag, true
    }
    return false, 0, false
}

// The value of the constant expression `n` of `file`. False when it is not constant, not known,
// overflows or divides by zero. A string the evaluation makes is in the checker arena.
const_eval :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (Const_Value, bool) {
    n := n
    #partial switch n.green.kind {
    case .Literal:
        return literal_value(c, n)
    case .Paren_Expr:
        p, _      := odinsyntax.as_paren_expr(n)
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
        u, _                 := odinsyntax.as_unary_expr(n)
        op, has_op           := odinsyntax.unary_expr_op(&u)
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
        b, _         := odinsyntax.as_binary_expr(n)
        op, has_op   := odinsyntax.binary_expr_op(&b)
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
        // `&&` and `||` stop at a left side that decides them.
        if b, is_bool := l.(bool); is_bool && (op.green.kind == .Cmp_And && !b || op.green.kind == .Cmp_Or && b) {
            return b, true
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
    case .Call_Expr:
        if v, ok := feature_call(c, file, n); ok {
            return v, true
        }
    case .Selector_Expr:
    case:
        return nil, false
    }
    op := expr_type(c, file, n)
    if op.mode != .Const || op.value == nil {
        return nil, false
    }
    return op.value, true
}

// `intrinsics.has_target_feature("f")` for the snapshot's target.
@(private = "file")
feature_call :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (Const_Value, bool) {
    ce, _              := odinsyntax.as_call_expr(n)
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list     := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return nil, false
    }
    sel, is_sel := odinsyntax.as_selector_expr(callee)
    if !is_sel {
        return nil, false
    }
    field, has_field     := odinsyntax.selector_expr_field(&sel)
    operand, has_operand := odinsyntax.selector_expr_operand(&sel)
    if !has_field || !has_operand || odinsyntax.node_text(odinsyntax.Syntax_Node(field)) != "has_target_feature" {
        return nil, false
    }
    pkg := expr_type(c, file, operand)
    if pkg.mode != .Package {
        return nil, false
    }
    dir, _ := strings.replace_all(pkg.dir, "\\", "/", context.temp_allocator)
    if !strings.has_suffix(strings.trim_right(dir, "/"), "base/intrinsics") {
        return nil, false
    }
    it           := odinsyntax.arg_list_args(&list)
    arg, has_arg := odinsyntax.child_iter_next(&it)
    if _, more := odinsyntax.child_iter_next(&it); !has_arg || more {
        return nil, false
    }
    v, ok               := const_eval(c, file, arg)
    features, is_string := v.(string)
    if !ok || !is_string {
        return nil, false
    }
    #partial switch target_has_features(features, c.snap.target) {
    case .True:
        return true, true
    case .False:
        return false, true
    }
    return nil, false
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
    is, _     := odinsyntax.as_implicit_selector(member)
    field, ok := odinsyntax.implicit_selector_field(&is)
    if !ok {
        return nil, false
    }
    equal := odinsyntax.node_text(odinsyntax.Syntax_Node(field)) == v.s
    return op == .Cmp_Eq ? equal : !equal, true
}

// `cond ? then : other` with a constant condition.
@(private = "file")
const_choose :: proc(
    c: ^Checker,
    file: File_Id,
    cond: odinsyntax.Syntax_Node,
    has_cond: bool,
    then: odinsyntax.Syntax_Node,
    has_then: bool,
    other: odinsyntax.Syntax_Node,
    has_other: bool,
) -> (Const_Value, bool) {
    if !has_cond || !has_then || !has_other {
        return nil, false
    }
    v, ok      := const_eval(c, file, cond)
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
@(private)
literal_value :: proc(c: ^Checker, n: odinsyntax.Syntax_Node) -> (Const_Value, bool) {
    lit, _  := odinsyntax.as_literal(n)
    tok, ok := odinsyntax.literal_token(&lit)
    if !ok {
        return nil, false
    }
    text := odinsyntax.syntax_token_text(tok)
    #partial switch tok.green.kind {
    case .Integer:
        return parse_integer(text)
    case .Float:
        if strings.has_prefix(text, "0h") {
            // 0h is the raw bits of a 16-digit f64 (8 for f32, 4 for f16 are left alone).
            if len(text) != 18 {
                return nil, false
            }
            bits, parsed := strconv.parse_u64_of_base(text[2:], 16)
            f            := transmute(f64)bits
            if !parsed || f != f || abs(f) > max(f64) {
                return nil, false
            }
            return f, true
        }
        clean, _ := strings.remove_all(text, "_", c.alloc)
        v, fok   := strconv.parse_f64(clean)
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

// An integer literal with an optional base prefix and `_` separators; false when it does not fit u128.
@(private = "file")
parse_integer :: proc(text: string) -> (Const_Value, bool) {
    s := text
    base: u128 = 10
    if len(s) > 2 && s[0] == '0' {
        switch s[1] {
        case 'b':
            base, s = 2, s[2:]
        case 'o':
            base, s = 8, s[2:]
        case 'd':
            base, s = 10, s[2:]
        case 'z':
            base, s = 12, s[2:]
        case 'x':
            base, s = 16, s[2:]
        }
    }
    value: u128
    digits := 0
    for ch in transmute([]u8)s {
        d: u128
        switch ch {
        case '_':
            continue
        case '0' ..= '9':
            d = u128(ch - '0')
        case 'a' ..= 'z':
            d = u128(ch - 'a') + 10
        case 'A' ..= 'Z':
            d = u128(ch - 'A') + 10
        case:
            return nil, false
        }
        if d >= base {
            return nil, false
        }
        if value > (max(u128) - d) / base {
            return nil, false
        }
        value = value * base + d
        digits += 1
    }
    if digits == 0 {
        return nil, false
    }
    return wide_value(false, value), true
}

@(private)
const_unary :: proc(op: odinsyntax.Token_Kind, v: Const_Value) -> (Const_Value, bool) {
    #partial switch op {
    case .Add:
        #partial switch _ in v {
        case i64, f64, rune, Wide_Int:
            return v, true
        }
    case .Sub:
        #partial switch x in v {
        case i64:
            if x == min(i64) {
                return Wide_Int{false, u128(max(i64)) + 1}, true
            }
            return -x, true
        case Wide_Int:
            return wide_value(!x.neg, x.mag), true
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
        case .Add:
            return a + b, true
        case .Sub:
            return a - b, true
        case .Mul:
            return a * b, true
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

// `+ - * / <<` of two integers exactly, as decimal text in `allocator`, and whether integer type `t`
// holds the result. False on division by zero, a negative shift count or one over 1024.
const_wide_binary :: proc(c: ^Checker, t: Type_Id, op: odinsyntax.Token_Kind, a, b: Wide_Int, allocator := context.allocator) -> (
    text: string,
    fits: bool,
    ok: bool,
) {
    if op == .Quo {
        if b.mag == 0 {
            return "", false, false
        }
        mag := a.mag / b.mag
        neg := a.neg != b.neg && mag != 0
        return wide_text(neg, mag, allocator), wide_holds(c, t, neg, mag), true
    }
    if op == .Shl && (b.neg && b.mag != 0 || b.mag > 1024) {
        return "", false, false
    }
    x, y, r, m: big.Int
    defer big.int_destroy(&x, &y, &r, &m)
    if !wide_to_big(&x, a) || !wide_to_big(&y, b) {
        return "", false, false
    }
    err: big.Error
    #partial switch op {
    case .Add:
        err = big.int_add(&r, &x, &y)
    case .Sub:
        err = big.int_sub(&r, &x, &y)
    case .Mul:
        err = big.int_mul(&r, &x, &y)
    case .Shl:
        err = big.int_shl(&r, &x, int(b.mag))
    case:
        return "", false, false
    }
    if err != nil {
        return "", false, false
    }
    s, serr := big.int_itoa_string(&r, 10, false, allocator)
    if serr != nil {
        return "", false, false
    }
    if big.int_abs(&m, &r) != nil {
        return s, false, true
    }
    mag, gerr := big.int_get(&m, u128)
    if gerr != nil {
        return s, false, true
    }
    neg := r.sign == .Negative && mag != 0
    return s, wide_holds(c, t, neg, mag), true
}

@(private = "file")
wide_to_big :: proc(dest: ^big.Int, w: Wide_Int) -> bool {
    if big.int_set_from_integer(dest, w.mag) != nil {
        return false
    }
    return !w.neg || w.mag == 0 || big.int_neg(dest, dest) == nil
}

// True when the integer type `t` holds the signed magnitude; true when its width is unknown.
wide_holds :: proc(c: ^Checker, t: Type_Id, neg: bool, mag: u128) -> bool {
    b, is_basic := type_get(&c.table, type_base(&c.table, t)).(Basic_Type)
    if !is_basic || !type_is_integer(&c.table, t) {
        return true
    }
    bits := 8 * basic_size(b.kind, c.snap.target)
    if bits <= 0 || bits > 128 {
        return true
    }
    if basic_unsigned(c, t) {
        return (!neg || mag == 0) && (bits >= 128 || mag < u128(1) << u128(bits))
    }
    limit := u128(1) << u128(bits - 1)
    return neg ? mag <= limit : mag < limit
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
    case .Cmp_Eq:
        return order == 0, true
    case .Not_Eq:
        return order != 0, true
    case .Lt:
        return order < 0, true
    case .Gt:
        return order > 0, true
    case .Lt_Eq:
        return order <= 0, true
    case .Gt_Eq:
        return order >= 0, true
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
        if w, is_wide := v.(Wide_Int); is_wide {
            return w, true
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
