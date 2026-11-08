package odinsema

import "core:strconv"
import "core:strings"

import odinsyntax "../syntax"

// A float literal as written: `digits` x 10^exp10, with the sign apart.
@(private = "file")
Literal_Number :: struct {
    negative: bool,
    digits:   string, // no leading zeros, no point; "" for zero
    exp10:    int,    // the exponent after the point is moved right
    dotted:   bool,   // the text has a `.`
    float:    f64,
}

// What a float literal does to the type its place takes.
Literal_Fault :: enum u8 {
    None,
    Truncated, // a non-integral value, or an integral one the integer type cannot hold, into an integer type
    Overflow,  // a value the float type cannot hold, or an unpointed one the integer type cannot hold
}

Literal_Problem :: struct {
    fault:   Literal_Fault,
    got:     string, // the exact value as the compiler prints it, in the temp allocator
    integer: bool,   // the compiler names the literal an untyped integer
}

MAX_LITERAL_DIGITS :: 400

// The literal or negated literal `n` as a number; false for any other node, a spelling with white
// space, a hexadecimal float or a number too long to print.
@(private = "file")
literal_number :: proc(n: odinsyntax.Syntax_Node) -> (num: Literal_Number, ok: bool) {
    n := n
    node := n
    if n.green.kind == .Unary_Expr {
        u, _ := odinsyntax.as_unary_expr(n)
        op, has_op := odinsyntax.unary_expr_op(&u)
        operand, has_operand := odinsyntax.unary_expr_operand(&u)
        if !has_op || !has_operand || op.green.kind != .Sub {
            return {}, false
        }
        num.negative = true
        node = operand
    }
    if node.green.kind != .Literal {
        return {}, false
    }
    lit, _ := odinsyntax.as_literal(node)
    tok, has_tok := odinsyntax.literal_token(&lit)
    if !has_tok || tok.green.kind != .Float {
        return {}, false
    }
    text := odinsyntax.syntax_token_text(tok)
    if strings.has_prefix(text, "0h") || len(text) > MAX_LITERAL_DIGITS {
        return {}, false
    }
    if strings.contains_any(odinsyntax.node_text(n), " \t\r\n") {
        return {}, false
    }
    clean := make([dynamic]u8, 0, len(text), context.temp_allocator)
    for ch in transmute([]u8)text {
        if ch != '_' {
            append(&clean, ch)
        }
    }
    s := string(clean[:])
    mantissa := s
    exp := 0
    if e := strings.index_any(s, "eE"); e >= 0 {
        mantissa = s[:e]
        v, parsed := strconv.parse_int(s[e + 1:], 10)
        if !parsed || v > 1000 || v < -1000 {
            return {}, false
        }
        exp = v
    }
    whole, frac := mantissa, ""
    if dot := strings.index_byte(mantissa, '.'); dot >= 0 {
        whole, frac = mantissa[:dot], mantissa[dot + 1:]
        num.dotted = true
    }
    for ch in transmute([]u8)mantissa {
        if ch != '.' && (ch < '0' || ch > '9') {
            return {}, false
        }
    }
    joined := strings.concatenate({whole, frac}, context.temp_allocator)
    num.digits = strings.trim_left(joined, "0")
    num.exp10 = exp - len(frac)
    f, parsed := strconv.parse_f64(s)
    if !parsed && f == 0 {
        return {}, false
    }
    num.float = -f if num.negative else f
    return num, true
}

// The exact value of `num` as the compiler prints it: an integer, or `numerator.0/denominator`
// in lowest terms. Integral says which. False when the number is too long.
@(private = "file")
exact_text :: proc(num: Literal_Number) -> (text: string, integral: bool, ok: bool) {
    sign := "-" if num.negative && num.digits != "" else ""
    if num.digits == "" {
        return "0", true, true
    }
    if num.exp10 >= 0 {
        if len(num.digits) + num.exp10 > MAX_LITERAL_DIGITS + 10 {
            return "", false, false
        }
        zeros := strings.repeat("0", num.exp10, context.temp_allocator)
        return strings.concatenate({sign, num.digits, zeros}, context.temp_allocator), true, true
    }
    k := -num.exp10
    top := num.digits
    twos, fives := 0, 0
    for twos < k {
        q, rem := digits_div(top, 2)
        if rem != 0 {
            break
        }
        top = q
        twos += 1
    }
    for fives < k {
        q, rem := digits_div(top, 5)
        if rem != 0 {
            break
        }
        top = q
        fives += 1
    }
    bottom := "1"
    for _ in 0 ..< k - twos {
        bottom = digits_mul(bottom, 2)
    }
    for _ in 0 ..< k - fives {
        bottom = digits_mul(bottom, 5)
    }
    if bottom == "1" {
        return strings.concatenate({sign, top}, context.temp_allocator), true, true
    }
    return strings.concatenate({sign, top, ".0/", bottom}, context.temp_allocator), false, true
}

// The decimal string `s` divided by `d`, and the remainder.
@(private = "file")
digits_div :: proc(s: string, d: int) -> (string, int) {
    out := make([]u8, len(s), context.temp_allocator)
    rem := 0
    for i in 0 ..< len(s) {
        cur := rem * 10 + int(s[i] - '0')
        out[i] = u8(cur / d) + '0'
        rem = cur % d
    }
    return strings.trim_left(string(out), "0"), rem
}

// The decimal string `s` times `m`.
@(private = "file")
digits_mul :: proc(s: string, m: int) -> string {
    out := make([]u8, len(s) + 2, context.temp_allocator)
    carry := 0
    pos := len(out)
    for i := len(s) - 1; i >= 0; i -= 1 {
        cur := int(s[i] - '0') * m + carry
        pos -= 1
        out[pos] = u8(cur % 10) + '0'
        carry = cur / 10
    }
    for carry > 0 && pos > 0 {
        pos -= 1
        out[pos] = u8(carry % 10) + '0'
        carry /= 10
    }
    return string(out[pos:])
}

// The largest magnitude `kind` takes, as the compiler's cast to it rounds: the midpoint between
// its largest finite value and the next power of two.
@(private = "file")
float_limit :: proc(kind: Basic_Kind) -> (f64, bool) {
    #partial switch kind {
    case .F16: return 65520, true
    case .F32: return 340282356779733661637539395458142568448.0, true
    case .F64: return max(f64), true
    }
    return 0, false
}

// What the float literal `n` does to the place of type `to`, as the compiler words it. None for
// anything the checker cannot settle exactly: a computed value, a type with rules of its own.
literal_fault :: proc(c: ^Checker, to: Type_Id, op: Operand, n: odinsyntax.Syntax_Node) -> Literal_Problem {
    t := &c.table
    if to == INVALID_TYPE || op.mode != .Const {
        return {}
    }
    if u, untyped := type_get(t, op.type).(Untyped_Type); !untyped || u.kind != .Float {
        return {}
    }
    basic, is_basic := type_get(t, type_base(t, to)).(Basic_Type)
    if !is_basic {
        return {}
    }
    num, ok := literal_number(n)
    if !ok {
        return {}
    }
    text, integral, exact := exact_text(num)
    if !exact {
        return {}
    }
    if type_is_integer(t, to) {
        if !integral {
            return {fault = .Truncated, got = text}
        }
        if len(text) > 18 || num.digits == "" {
            return {}
        }
        v, parsed := strconv.parse_i64(text, 10)
        if !parsed {
            return {}
        }
        if _, _, bounded := integer_bounds(c, to); !bounded || integer_holds(c, to, v) {
            return {}
        }
        if num.dotted {
            return {fault = .Truncated, got = text}
        }
        return {fault = .Overflow, got = text, integer = true}
    }
    limit, is_float := float_limit(basic.kind)
    if !is_float {
        return {}
    }
    magnitude := abs(num.float)
    if basic.kind == .F64 {
        if magnitude <= max(f64) {
            return {}
        }
    } else if !(magnitude > limit * (1 + 1e-9)) {
        return {}
    }
    return {fault = .Overflow, got = text, integer = !num.dotted}
}

// The problem report for the float literal `n` put in a place of type `to`; false when there is none.
literal_type_problem :: proc(c: ^Checker, to: Type_Id, op: Operand, n: odinsyntax.Syntax_Node) -> (Type_Problem, bool) {
    lp := literal_fault(c, to, op, n)
    if lp.fault == .None {
        return {}, false
    }
    typed := op
    if lp.integer {
        typed.type = type_untyped(.Int)
    }
    return {value = n, op = typed, to = to, overflow = lp.fault == .Overflow, truncated = lp.fault == .Truncated, got = lp.got}, true
}
