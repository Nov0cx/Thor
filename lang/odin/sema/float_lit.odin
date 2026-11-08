package odinsema

import "core:fmt"
import "core:math"
import "core:math/big"
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
    hex:      bool,   // a `0h` literal: the compiler prints the f64 with 17 decimals
    rat:      bool,   // an exact fraction from an expression; `rat_text` is its print
    rat_text: string,
    rat_integral: bool,
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

// `n` without parentheses and negations, and whether the value is negated.
@(private = "file")
strip_signs :: proc(n: odinsyntax.Syntax_Node) -> (node: odinsyntax.Syntax_Node, negative: bool) {
    node = n
    for _ in 0 ..< 32 {
        #partial switch node.green.kind {
        case .Paren_Expr:
            p, _ := odinsyntax.as_paren_expr(node)
            inner, has := odinsyntax.paren_expr_expr(&p)
            if !has {
                return node, negative
            }
            node = inner
        case .Unary_Expr:
            u, _ := odinsyntax.as_unary_expr(node)
            op, has_op := odinsyntax.unary_expr_op(&u)
            operand, has_operand := odinsyntax.unary_expr_operand(&u)
            if !has_op || !has_operand || op.green.kind != .Sub {
                return node, negative
            }
            negative = !negative
            node = operand
        case:
            return node, negative
        }
    }
    return node, negative
}

// The float expression `n` as a number: a literal, or a sum, difference, product or quotient of
// them, with parentheses and negations. False for any other node, a spelling with a comment, or a number too long to print.
@(private = "file")
literal_number :: proc(n: odinsyntax.Syntax_Node) -> (num: Literal_Number, ok: bool) {
    context.allocator = context.temp_allocator
    node, negative := strip_signs(n)
    text := odinsyntax.node_text(n)
    if strings.contains(text, "/*") || strings.contains(text, "//") {
        return {}, false
    }
    if node.green.kind == .Binary_Expr {
        r, rok := rational_of(node, 0)
        if !rok || !r.dotted {
            return {}, false
        }
        if negative {
            neg, nok := rat_neg(r)
            if !nok {
                return {}, false
            }
            r = neg
        }
        return rational_number(r)
    }
    if node.green.kind != .Literal {
        return {}, false
    }
    // A plain literal or a negated one is kept to its tight spelling.
    if n.green.kind != .Paren_Expr && strings.contains_any(text, " \t\r\n") {
        return {}, false
    }
    leaf, lok := literal_leaf(node)
    if !lok {
        return {}, false
    }
    if negative {
        leaf.negative = true
        leaf.float = -leaf.float
    }
    return leaf, true
}

// The float literal node `node` as digits and an exponent.
@(private = "file")
literal_leaf :: proc(node: odinsyntax.Syntax_Node) -> (num: Literal_Number, ok: bool) {
    lit, _ := odinsyntax.as_literal(node)
    tok, has_tok := odinsyntax.literal_token(&lit)
    if !has_tok || tok.green.kind != .Float {
        return {}, false
    }
    text := odinsyntax.syntax_token_text(tok)
    if len(text) > MAX_LITERAL_DIGITS {
        return {}, false
    }
    if strings.has_prefix(text, "0h") {
        digits := text[2:]
        if len(digits) != 16 {
            return {}, false
        }
        bits, parsed := strconv.parse_u64_of_base(digits, 16)
        if !parsed {
            return {}, false
        }
        return {hex = true, dotted = true, float = transmute(f64)bits}, true
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
    num.float = f
    return num, true
}

// The most bits a numerator or denominator may take before the value is left unsettled.
RAT_MAX_BITS :: 4096

// An exact fraction; `den` is positive and `num` / `den` is in lowest terms.
@(private = "file")
Rational :: struct {
    num, den: big.Int,
    dotted:   bool, // a float literal is part of it
    hexfrac:  bool, // a hexadecimal float with a fraction is part of it
}

@(private = "file")
big_from :: proc(v: i64) -> (r: big.Int, ok: bool) {
    err := big.int_set_from_integer(&r, v)
    return r, err == nil
}

@(private = "file")
big_parse :: proc(text: string) -> (r: big.Int, ok: bool) {
    err := big.int_atoi(&r, text)
    return r, err == nil
}

@(private = "file")
big_mul :: proc(a, b: big.Int) -> (r: big.Int, ok: bool) {
    a, b := a, b
    err := big.int_mul(&r, &a, &b)
    return r, err == nil
}

@(private = "file")
big_add :: proc(a, b: big.Int) -> (r: big.Int, ok: bool) {
    a, b := a, b
    err := big.int_add(&r, &a, &b)
    return r, err == nil
}

@(private = "file")
big_neg :: proc(a: big.Int) -> (r: big.Int, ok: bool) {
    a := a
    err := big.int_neg(&r, &a)
    return r, err == nil
}

@(private = "file")
big_abs :: proc(a: big.Int) -> (r: big.Int, ok: bool) {
    a := a
    err := big.int_abs(&r, &a)
    return r, err == nil
}

@(private = "file")
big_div :: proc(a, b: big.Int) -> (r: big.Int, ok: bool) {
    a, b := a, b
    err := big.int_div(&r, &a, &b)
    return r, err == nil
}

@(private = "file")
big_shl :: proc(a: big.Int, bits: int) -> (r: big.Int, ok: bool) {
    a := a
    err := big.int_shl(&r, &a, bits)
    return r, err == nil
}

@(private = "file")
big_bits :: proc(a: big.Int) -> int {
    a := a
    n, err := big.count_bits(&a)
    return n if err == nil else max(int)
}

@(private = "file")
big_sign :: proc(a: big.Int) -> (negative, zero: bool, ok: bool) {
    a := a
    z, zerr := big.int_is_zero(&a)
    n, nerr := big.int_is_negative(&a)
    return n, z, zerr == nil && nerr == nil
}

@(private = "file")
big_text :: proc(a: big.Int) -> (string, bool) {
    a := a
    s, err := big.int_itoa_string(&a)
    return s, err == nil
}

@(private = "file")
rat_make :: proc(num, den: big.Int, dotted, hexfrac: bool) -> (Rational, bool) {
    _, dzero, dok := big_sign(den)
    if !dok || dzero {
        return {}, false
    }
    num, den := num, den
    if dneg, _, _ := big_sign(den); dneg {
        n, nok := big_neg(num)
        d, dnok := big_neg(den)
        if !nok || !dnok {
            return {}, false
        }
        num, den = n, d
    }
    mag, mok := big_abs(num)
    if !mok {
        return {}, false
    }
    g: big.Int
    if big.int_gcd(&g, &mag, &den) != nil {
        return {}, false
    }
    if big_bits(g) > 1 {
        n, nok := big_div(num, g)
        d, dnok := big_div(den, g)
        if !nok || !dnok {
            return {}, false
        }
        num, den = n, d
    }
    if big_bits(num) > RAT_MAX_BITS || big_bits(den) > RAT_MAX_BITS {
        return {}, false
    }
    return {num = num, den = den, dotted = dotted, hexfrac = hexfrac}, true
}

@(private = "file")
rat_neg :: proc(r: Rational) -> (out: Rational, ok: bool) {
    n, nok := big_neg(r.num)
    out = r
    out.num = n
    return out, nok
}

// The value of the constant expression `n` made of numbers, parentheses, negation and `+ - * /`.
@(private = "file")
rational_of :: proc(n: odinsyntax.Syntax_Node, depth: int) -> (r: Rational, ok: bool) {
    if depth > 32 {
        return {}, false
    }
    node, negative := strip_signs(n)
    r, ok = rational_node(node, depth)
    if ok && negative {
        r, ok = rat_neg(r)
    }
    return r, ok
}

// The exact value of the finite f64 `f`.
@(private = "file")
rat_of_f64 :: proc(f: f64) -> (Rational, bool) {
    if f != f || abs(f) > max(f64) {
        return {}, false
    }
    one, ook := big_from(1)
    if !ook {
        return {}, false
    }
    if f == 0 {
        zero, zok := big_from(0)
        if !zok {
            return {}, false
        }
        return rat_make(zero, one, true, false)
    }
    frac, exp := math.frexp(abs(f))
    mant := i64(frac * (1 << 53))
    exp -= 53
    m, mok := big_from(mant if f > 0 else -mant)
    if !mok {
        return {}, false
    }
    if exp >= 0 {
        num, nok := big_shl(m, exp)
        if !nok {
            return {}, false
        }
        return rat_make(num, one, true, false)
    }
    den, dok := big_shl(one, -exp)
    if !dok {
        return {}, false
    }
    return rat_make(m, den, true, true)
}

@(private = "file")
rational_node :: proc(node: odinsyntax.Syntax_Node, depth: int) -> (Rational, bool) {
    #partial switch node.green.kind {
    case .Literal:
        lit, _ := odinsyntax.as_literal(node)
        tok, has_tok := odinsyntax.literal_token(&lit)
        if !has_tok {
            return {}, false
        }
        text := odinsyntax.syntax_token_text(tok)
        one, ook := big_from(1)
        if !ook {
            return {}, false
        }
        if tok.green.kind == .Integer {
            clean, _ := strings.remove_all(text, "_", context.temp_allocator)
            v, parsed := strconv.parse_i64_maybe_prefixed(clean)
            if !parsed {
                return {}, false
            }
            num, nok := big_from(v)
            if !nok {
                return {}, false
            }
            return rat_make(num, one, false, false)
        }
        leaf, lok := literal_leaf(node)
        if !lok {
            return {}, false
        }
        if leaf.hex {
            return rat_of_f64(leaf.float)
        }
        if leaf.exp10 > 1000 || leaf.exp10 < -1000 {
            return {}, false
        }
        mant := big.Int{}
        if leaf.digits != "" {
            parsed: bool
            mant, parsed = big_parse(leaf.digits)
            if !parsed {
                return {}, false
            }
        } else {
            zero, zok := big_from(0)
            if !zok {
                return {}, false
            }
            mant = zero
        }
        scale_text := strings.concatenate({"1", strings.repeat("0", abs(leaf.exp10), context.temp_allocator)}, context.temp_allocator)
        scale, sok := big_parse(scale_text)
        if !sok {
            return {}, false
        }
        if leaf.exp10 >= 0 {
            m, mok := big_mul(mant, scale)
            if !mok {
                return {}, false
            }
            return rat_make(m, one, leaf.dotted, false)
        }
        return rat_make(mant, scale, leaf.dotted, false)
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(node)
        lhs, has_lhs := odinsyntax.binary_expr_lhs(&b)
        op, has_op := odinsyntax.binary_expr_op(&b)
        rhs, has_rhs := odinsyntax.binary_expr_rhs(&b)
        if !has_lhs || !has_op || !has_rhs {
            return {}, false
        }
        a, aok := rational_of(lhs, depth + 1)
        c, cok := rational_of(rhs, depth + 1)
        if !aok || !cok {
            return {}, false
        }
        dotted := a.dotted || c.dotted
        hexfrac := a.hexfrac || c.hexfrac
        #partial switch op.green.kind {
        case .Add, .Sub:
            if op.green.kind == .Sub {
                neg, nok := rat_neg(c)
                if !nok {
                    return {}, false
                }
                c = neg
            }
            x, xok := big_mul(a.num, c.den)
            y, yok := big_mul(c.num, a.den)
            d, dok := big_mul(a.den, c.den)
            if !xok || !yok || !dok {
                return {}, false
            }
            s, sok := big_add(x, y)
            if !sok {
                return {}, false
            }
            return rat_make(s, d, dotted, hexfrac)
        case .Mul:
            x, xok := big_mul(a.num, c.num)
            d, dok := big_mul(a.den, c.den)
            if !xok || !dok {
                return {}, false
            }
            return rat_make(x, d, dotted, hexfrac)
        case .Quo:
            if _, zero, sok := big_sign(c.num); !sok || zero {
                return {}, false
            }
            x, xok := big_mul(a.num, c.den)
            d, dok := big_mul(a.den, c.num)
            if !xok || !dok {
                return {}, false
            }
            return rat_make(x, d, dotted, hexfrac)
        }
    }
    return {}, false
}

// The f64 nearest the fraction `r`, infinite beyond the range.
@(private = "file")
rat_f64 :: proc(r: Rational) -> (f64, bool) {
    neg, _, sok := big_sign(r.num)
    mag, mok := big_abs(r.num)
    if !sok || !mok {
        return 0, false
    }
    shifted, shok := big_shl(mag, 64)
    if !shok {
        return 0, false
    }
    q, qok := big_div(shifted, r.den)
    if !qok {
        return 0, false
    }
    f := math.inf_f64(1)
    if big_bits(q) <= 1100 {
        text, tok := big_text(q)
        if !tok {
            return 0, false
        }
        parsed: bool
        f, parsed = strconv.parse_f64(text)
        if !parsed && f == 0 {
            return 0, false
        }
        f = math.ldexp(f, -64)
    }
    return -f if neg else f, true
}

// A `Literal_Number` that prints the fraction `r`. False for a fraction the compiler prints from
// a hexadecimal float, which is not reproduced.
@(private = "file")
rational_number :: proc(r: Rational) -> (num: Literal_Number, ok: bool) {
    negative, zero, sok := big_sign(r.num)
    mag, mok := big_abs(r.num)
    one, ook := big_from(1)
    if !sok || !mok || !ook {
        return {}, false
    }
    den := r.den
    cmp, cerr := big.int_compare(&one, &den)
    if cerr != nil {
        return {}, false
    }
    integral := cmp == 0 || zero
    if r.hexfrac && !integral {
        return {}, false
    }
    digits, dok := big_text(mag)
    if !dok {
        return {}, false
    }
    f, fok := rat_f64(r)
    if !fok {
        return {}, false
    }
    sign := "-" if negative else ""
    num.negative = negative
    num.digits = "" if zero else digits
    num.dotted = true
    num.float = f
    num.rat = true
    num.rat_integral = integral
    if zero {
        num.rat_text = "0"
    } else if integral {
        num.rat_text = strings.concatenate({sign, digits}, context.temp_allocator)
    } else {
        den, den_ok := big_text(r.den)
        if !den_ok {
            return {}, false
        }
        num.rat_text = strings.concatenate({sign, digits, ".0/", den}, context.temp_allocator)
    }
    return num, true
}

// The exact value of `num` as the compiler prints it: an integer, or `numerator.0/denominator`
// in lowest terms. Integral says which. False when the number is too long.
@(private = "file")
exact_text :: proc(num: Literal_Number) -> (text: string, integral: bool, ok: bool) {
    if num.rat {
        return num.rat_text, num.rat_integral, true
    }
    if num.hex {
        f := num.float
        if f != f || abs(f) >= 1e18 {
            return "", false, false
        }
        if f == f64(i64(f)) {
            return fmt.tprintf("%d", i64(f)), true, true
        }
        // The compiler rounds a longer fraction by its own arithmetic; only an exact one is printed.
        scaled := f * 131072
        if scaled != f64(i64(scaled)) {
            return "", false, false
        }
        return fmt.tprintf("%.17f", f), false, true
    }
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
        if len(text) > 18 || num.digits == "" && !num.hex {
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
    if !is_float || num.hex {
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
