// The format strings of printf-style calls, read as `core:fmt` reads them (`api/fmt-verbs`).
package odinsema

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import odinsyntax "../syntax"

// The most arguments `fmt.wprintf` checks.
MAX_FORMAT_ARGS :: 64

// The names of the format parameter before a `..any` parameter.
@(private = "file")
FORMAT_PARAM_NAMES := [?]string{"fmt", "format", "fmt_str", "_fmt"}

Format_Step_Kind :: enum u8 {
    Verb,          // a verb takes `arg`
    Width,         // `*` takes `arg` as the width
    Precision,     // `.*` takes `arg` as the precision
    Missing,       // a verb or `*` with no argument left
    Bad_Index,     // `[n]` or `{n}` names no argument
    No_Verb,       // `%` at the end or before a space
    Missing_Brace, // `{` with no `}`
}

// One thing the format string asks of its arguments.
Format_Step :: struct {
    kind: Format_Step_Kind,
    at:   int,  // the byte of the format string where the directive starts
    arg:  int,  // Verb, Width, Precision: the argument index
    verb: rune, // Verb, Missing: the verb; '*' for a width or precision
}

// The steps of `format` for `arg_count` arguments, and the arguments no step takes. As `fmt.wprintf`
// does, a directive with no `[n]` takes the lowest argument not yet taken.
format_steps :: proc(format: string, arg_count: int, allocator := context.allocator) -> (steps: []Format_Step, unused: bit_set[0 ..< MAX_FORMAT_ARGS]) {
    out := make([dynamic]Format_Step, allocator)
    for k in 0 ..< min(arg_count, MAX_FORMAT_ARGS) {
        unused += {k}
    }
    end := len(format)
    i   := 0
    for i < end {
        for i < end && format[i] != '%' && format[i] != '{' && format[i] != '}' {
            i += 1
        }
        if i >= end {
            break
        }
        start := i
        ch    := format[i]
        i += 1
        if ch == '}' {
            if i < end && format[i] == '}' {
                i += 1
            }
            continue
        }
        if ch == '{' && i < end && format[i] == '{' {
            i += 1
            continue
        }
        if ch == '%' {
            if i < end && format[i] == '%' {
                i += 1
                continue
            }
            i = format_options(format, i, start, arg_count, &unused, &out)
            index, parsed, ok := format_arg_number(format, &i, arg_count)
            problem           := Format_Step_Kind.Verb
            if !ok {
                index, ok = first_unused(unused)
                if parsed {
                    problem, ok = .Bad_Index, false
                } else if !ok {
                    problem = .Missing
                }
            }
            if i >= end || format[i] == ' ' {
                append(&out, Format_Step{kind = .No_Verb, at = start})
                if i >= end {
                    break
                }
                continue
            }
            verb, w := utf8.decode_rune_in_string(format[i:])
            i += w
            if ok {
                unused -= {index}
                append(&out, Format_Step{kind = .Verb, at = start, arg = index, verb = verb})
            } else {
                append(&out, Format_Step{kind = problem, at = start, verb = verb})
            }
            continue
        }
        // `{n:options verb}`
        index, parsed, ok := 0, false, false
        if i < end && format[i] != '}' && format[i] != ':' {
            index, i, parsed = parse_digits(format, i)
            ok = parsed && index < arg_count
        }
        problem := Format_Step_Kind.Verb
        if !ok {
            index, ok = first_unused(unused)
            if parsed {
                problem, ok = .Bad_Index, false
            } else if !ok {
                problem = .Missing
            }
        }
        verb := 'v'
        if i < end && format[i] == ':' {
            i += 1
            i = format_options(format, i, start, arg_count, &unused, &out)
            if i >= end || format[i] == '}' {
                append(&out, Format_Step{kind = .No_Verb, at = start})
                if i >= end {
                    break
                }
                i += 1
                continue
            }
            w: int
            verb, w = utf8.decode_rune_in_string(format[i:])
            i += w
        }
        if i >= end {
            append(&out, Format_Step{kind = .Missing_Brace, at = start})
            break
        }
        brace, w := utf8.decode_rune_in_string(format[i:])
        i += w
        switch {
        case brace != '}':
            append(&out, Format_Step{kind = .Missing_Brace, at = start})
        case ok:
            unused -= {index}
            append(&out, Format_Step{kind = .Verb, at = start, arg = index, verb = verb})
        case:
            append(&out, Format_Step{kind = problem, at = start, verb = verb})
        }
    }
    return out[:], unused
}

// Reads the flags, width and precision of a directive from `i`; a `*` takes an argument.
@(private = "file")
format_options :: proc(format: string, i, start, arg_count: int, unused: ^bit_set[0 ..< MAX_FORMAT_ARGS], out: ^[dynamic]Format_Step) -> int {
    i   := i
    end := len(format)
    for i < end && strings.index_byte("+- #0", format[i]) >= 0 {
        i += 1
    }
    star :: proc(format: string, i: ^int, start, arg_count: int, kind: Format_Step_Kind, unused: ^bit_set[0 ..< MAX_FORMAT_ARGS], out: ^[dynamic]Format_Step) {
        i^ += 1
        index, _, ok := format_arg_number(format, i, arg_count)
        if !ok {
            index, ok = first_unused(unused^)
        }
        if !ok {
            append(out, Format_Step{kind = .Missing, at = start, verb = '*'})
            return
        }
        unused^ -= {index}
        append(out, Format_Step{kind = kind, at = start, arg = index, verb = '*'})
    }
    if i < end && format[i] == '*' {
        star(format, &i, start, arg_count, .Width, unused, out)
    } else {
        _, i, _ = parse_digits(format, i)
    }
    if i < end && format[i] == '.' {
        i += 1
        if i < end && format[i] == '*' {
            star(format, &i, start, arg_count, .Precision, unused, out)
        } else {
            _, i, _ = parse_digits(format, i)
        }
    }
    return i
}

// `[n]` at `i^`, as `fmt._arg_number` reads it: `parsed` when it is there, `ok` when `n` names an argument.
@(private = "file")
format_arg_number :: proc(format: string, i: ^int, arg_count: int) -> (index: int, parsed, ok: bool) {
    at := i^
    if at >= len(format) || format[at] != '[' {
        return
    }
    rest := format[at:]
    if len(rest) < 3 {
        i^ = at + 1
        return
    }
    for k in 1 ..< len(rest) {
        if rest[k] == ']' {
            value, next, digits := parse_digits(rest, 1)
            i^ = at + k + 1
            if !digits || next != k {
                return
            }
            return value, true, value < arg_count
        }
    }
    i^ = at + 1
    return
}

// The decimal number at `i`; false when there is no digit.
@(private = "file")
parse_digits :: proc(s: string, i: int) -> (value, next: int, ok: bool) {
    next = i
    for next < len(s) && s[next] >= '0' && s[next] <= '9' {
        value = value * 10 + int(s[next] - '0')
        next += 1
    }
    return value, next, next > i
}

@(private = "file")
first_unused :: proc(unused: bit_set[0 ..< MAX_FORMAT_ARGS]) -> (int, bool) {
    for k in unused {
        return k, true
    }
    return 0, false
}

Format_Problem_Kind :: enum u8 {
    Missing,
    Bad_Index,
    No_Verb,
    Missing_Brace,
    Bad_Width,
    Bad_Precision,
    Bad_Verb,
    Extra,
}

// A directive of a format string that `fmt` prints as `%!(...)`.
Format_Problem :: struct {
    kind:   Format_Problem_Kind,
    offset: int,
    verb:   rune,
    type:   Type_Id, // Bad_Verb, Bad_Width, Bad_Precision: the argument's type
    count:  int,     // Extra: the arguments no directive takes
}

// The problems of the constant format string of a call to a procedure that takes a format string
// and `..any` arguments. Empty when the format is not constant, an argument is spread (`..xs`) or
// the types are not known.
format_problems :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node, allocator := context.allocator) -> []Format_Problem {
    temp := scratch_begin(c)
    defer scratch_end(temp)
    p, args, slots, ok := call_slots(c, file, call)
    if !ok {
        return nil
    }
    k := format_param(c, p)
    if k < 0 {
        return nil
    }
    format_arg := -1
    values     := make([dynamic]Call_Arg, c.tmp)
    for a, i in args {
        switch slots[i] {
        case k:
            format_arg = i
        case k + 1:
            if a.spread {
                return nil
            }
            append(&values, a)
        }
    }
    if format_arg < 0 || len(values) > MAX_FORMAT_ARGS {
        return nil
    }
    fa                := args[format_arg]
    format, is_string := fa.op.value.(string)
    if fa.op.mode != .Const || !is_string {
        return nil
    }
    places := literal_places(fa.node, len(format), c.tmp)
    place :: proc(places: []int, node: odinsyntax.Syntax_Node, at: int) -> int {
        if places == nil {
            return int(node.offset)
        }
        return places[at]
    }
    steps, unused := format_steps(format, len(values), c.tmp)
    out           := make([dynamic]Format_Problem, allocator)
    for s in steps {
        at := place(places, fa.node, s.at)
        switch s.kind {
        case .Verb:
            type := values[s.arg].op.type
            if !verb_fits(&c.table, type, s.verb) {
                append(&out, Format_Problem{kind = .Bad_Verb, offset = at, verb = s.verb, type = type_default(&c.table, type)})
            }
        case .Width, .Precision:
            type := values[s.arg].op.type
            if !count_fits(&c.table, type) {
                kind := Format_Problem_Kind.Bad_Width if s.kind == .Width else .Bad_Precision
                append(&out, Format_Problem{kind = kind, offset = at, type = type_default(&c.table, type)})
            }
        case .Missing:
            append(&out, Format_Problem{kind = .Missing, offset = at, verb = s.verb})
        case .Bad_Index:
            append(&out, Format_Problem{kind = .Bad_Index, offset = at, verb = s.verb})
        case .No_Verb:
            append(&out, Format_Problem{kind = .No_Verb, offset = at})
        case .Missing_Brace:
            append(&out, Format_Problem{kind = .Missing_Brace, offset = at})
        }
    }
    if first, has := first_unused(unused); has {
        append(&out, Format_Problem{kind = .Extra, offset = int(values[first].node.offset), count = card(unused)})
    }
    return out[:]
}

// The index of the format parameter of `p`: a string named as `fmt` names it, right before a
// `..any` parameter. -1 when there is none.
@(private = "file")
format_param :: proc(c: ^Checker, p: Proc_Type) -> int {
    for k in 0 ..< len(p.params) - 1 {
        param, next := p.params[k], p.params[k + 1]
        if .Variadic not_in next.flags {
            continue
        }
        named := false
        for name in FORMAT_PARAM_NAMES {
            named ||= param.name == name
        }
        if !named {
            continue
        }
        s, is_basic := type_get(&c.table, type_base(&c.table, param.type)).(Basic_Type)
        a, is_any   := type_get(&c.table, type_base(&c.table, next.type)).(Basic_Type)
        if is_basic && s.kind == .String && is_any && a.kind == .Any {
            return k
        }
    }
    return -1
}

// The source offset of each byte of the value of `n`, and one past its end, for a string literal or
// a `+` of string literals. Nil for another expression or a value that does not have `length` bytes.
@(private = "file")
literal_places :: proc(n: odinsyntax.Syntax_Node, length: int, allocator: mem.Allocator) -> []int {
    out     := make([dynamic]int, 0, length + 1, allocator)
    end, ok := append_places(n, &out)
    if !ok || len(out) != length {
        return nil
    }
    append(&out, end)
    return out[:]
}

// Appends the places of the value bytes of `n`; `end` is the offset of its closing quote.
@(private = "file")
append_places :: proc(n: odinsyntax.Syntax_Node, out: ^[dynamic]int) -> (end: int, ok: bool) {
    #partial switch n.green.kind {
    case .Paren_Expr:
        p, _  := odinsyntax.as_paren_expr(n)
        inner := odinsyntax.paren_expr_expr(&p) or_return
        return append_places(inner, out)
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(n)
        op   := odinsyntax.binary_expr_op(&b) or_return
        if op.green.kind != .Add {
            return
        }
        lhs := odinsyntax.binary_expr_lhs(&b) or_return
        rhs := odinsyntax.binary_expr_rhs(&b) or_return
        append_places(lhs, out) or_return
        return append_places(rhs, out)
    case .Literal:
    case:
        return
    }
    lit, _ := odinsyntax.as_literal(n)
    tok    := odinsyntax.literal_token(&lit) or_return
    text   := odinsyntax.syntax_token_text(tok)
    if tok.green.kind != .String || len(text) < 2 {
        return
    }
    base := int(tok.offset)
    if text[0] == '`' {
        for k in 1 ..< len(text) - 1 {
            append(out, base + k)
        }
        return base + len(text) - 1, true
    }
    k := 1
    for k < len(text) - 1 {
        if text[k] != '\\' || k + 1 >= len(text) - 1 {
            append(out, base + k)
            k += 1
            continue
        }
        width, bytes := escape_size(text[k:])
        for _ in 0 ..< bytes {
            append(out, base + k)
        }
        k += width
    }
    return base + len(text) - 1, true
}

// The source length of the escape at the start of `s` and the bytes of value it gives.
@(private = "file")
escape_size :: proc(s: string) -> (width, bytes: int) {
    hex :: proc(s: string, n: int) -> (rune, bool) {
        if len(s) < n {
            return 0, false
        }
        r: rune
        for ch in transmute([]u8)s[:n] {
            d: rune
            switch ch {
            case '0' ..= '9':
                d = rune(ch - '0')
            case 'a' ..= 'f':
                d = rune(ch - 'a' + 10)
            case 'A' ..= 'F':
                d = rune(ch - 'A' + 10)
            case:
                return 0, false
            }
            r = r * 16 + d
        }
        return r, true
    }
    switch s[1] {
    case 'x':
        return min(4, len(s)), 1
    case '0' ..= '7':
        return min(4, len(s)), 1
    case 'u':
        r, ok := hex(s[2:], 4)
        return min(6, len(s)), ok ? utf8.rune_size(r) : 1
    case 'U':
        r, ok := hex(s[2:], 8)
        return min(10, len(s)), ok ? utf8.rune_size(r) : 1
    }
    return 2, 1
}

// True when `fmt` formats a value of type `id` with `verb`. An unknown type, an aggregate and a
// type `fmt` formats by its own rules take every verb.
@(private = "file")
verb_fits :: proc(t: ^Type_Table, id: Type_Id, verb: rune) -> bool {
    if verb == 'v' || verb == 'w' || verb == 'T' {
        return true
    }
    typed := type_default(t, id)
    if named, is_named := type_get(t, typed).(Named_Type); is_named && named.name == "Duration" && named.qualifier == "time" {
        return true
    }
    INTEGER_VERBS :: "bodizxXcrU"
    POINTER_VERBS :: "pbodizxX"
    #partial switch v in type_get(t, type_base(t, typed)) {
    case Basic_Type:
        #partial switch v.kind {
        case .Bool ..= .B64:
            return verb == 't'
        case .Int ..= .U128be:
            #partial switch v.kind {
            case .I128, .U128, .I128le, .U128le, .I128be, .U128be:
                return strings.contains_rune(INTEGER_VERBS, verb)
            }
            return strings.contains_rune(INTEGER_VERBS + "mM", verb)
        case .Rune:
            return strings.contains_rune(INTEGER_VERBS + "mMq", verb)
        case .F16 ..= .F64be:
            return strings.contains_rune("eEfFgGhH", verb)
        case .Complex32 ..= .Quaternion256:
            return strings.contains_rune("fFhH", verb)
        case .String, .Cstring:
            return strings.contains_rune("sqxX", verb)
        case .Rawptr:
            return strings.contains_rune(POINTER_VERBS, verb)
        }
    case Enum_Type:
        return strings.contains_rune("idsq", verb)
    case Pointer_Type:
        #partial switch _ in type_get(t, type_base(t, v.elem)) {
        case Basic_Type, Enum_Type, Pointer_Type, Multi_Pointer_Type, Proc_Type:
            return strings.contains_rune(POINTER_VERBS, verb)
        }
    }
    return true
}

// True when `fmt` reads a value of type `id` as a width or precision.
@(private = "file")
count_fits :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    #partial switch v in type_get(t, type_base(t, type_default(t, id))) {
    case Basic_Type:
        #partial switch v.kind {
        case .String, .Cstring, .String16, .Cstring16, .Rawptr, .Typeid:
            return false
        }
    case Pointer_Type, Multi_Pointer_Type, Slice_Type, Dynamic_Array_Type, Map_Type, Struct_Type:
        return false
    }
    return true
}

// The types `fmt.register_user_formatter` is given in a set of files.
User_Formatters :: struct {
    types: map[Type_Id]struct {},
    any:   bool, // a registration names a type the analysis cannot read: any named type may be formatted
}

// The registrations of user formatters in `files`. Only a file that names the procedure is read.
user_formatters :: proc(c: ^Checker, files: []File_Id, allocator := context.temp_allocator) -> User_Formatters {
    out := User_Formatters{types = make(map[Type_Id]struct {}, allocator)}
    for id in files {
        raw      := db_parse(c.snap, id)
        mentions := raw != nil && raw.tree != nil && strings.contains(raw.tree.text, "register_user_formatter")
        db_parse_release(c.snap, raw)
        if !mentions {
            continue
        }
        parsed := checker_parse(c, id)
        if parsed == nil || parsed.tree == nil {
            continue
        }
        scan_formatters(c, id, odinsyntax.node_root(parsed.tree), &out)
    }
    return out
}

// True when `type` has a user formatter among `formatters`, which takes any verb.
user_formatted :: proc(c: ^Checker, formatters: User_Formatters, type: Type_Id) -> bool {
    if type in formatters.types {
        return true
    }
    #partial switch _ in type_get(&c.table, type) {
    case Named_Type, Distinct_Type:
        return formatters.any
    }
    return false
}

// The declaration of a named or distinct type.
type_declaration :: proc(c: ^Checker, type: Type_Id) -> (Symbol, bool) {
    #partial switch v in type_get(&c.table, type) {
    case Named_Type:
        return v.symbol, true
    case Distinct_Type:
        return v.symbol, true
    }
    return {}, false
}

@(private = "file")
scan_formatters :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, out: ^User_Formatters) {
    n := n
    if n.green.kind == .Call_Expr {
        ce, _ := odinsyntax.as_call_expr(n)
        if callee, has := odinsyntax.call_expr_callee(&ce); has && strings.has_suffix(odinsyntax.node_text(callee), "register_user_formatter") {
            registered_type(c, file, ce, out)
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        scan_formatters(c, file, child, out)
    }
}

// Adds the type the first argument of the registration `call` names: `T`, `typeid_of(T)`,
// `type_info_of(T)` or `type_info_of(T).id`.
@(private = "file")
registered_type :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Call_Expr, out: ^User_Formatters) {
    call           := call
    list, has_list := odinsyntax.call_expr_args(&call)
    if !has_list {
        out.any = true
        return
    }
    it               := odinsyntax.arg_list_args(&list)
    first, has_first := odinsyntax.child_iter_next(&it)
    if !has_first {
        out.any = true
        return
    }
    n := strip_parens(first)
    if n.green.kind == .Selector_Expr {
        se, _                := odinsyntax.as_selector_expr(n)
        field, has_field     := odinsyntax.selector_expr_field(&se)
        operand, has_operand := odinsyntax.selector_expr_operand(&se)
        if has_field && has_operand && odinsyntax.node_text(odinsyntax.Syntax_Node(field)) == "id" {
            n = strip_parens(operand)
        }
    }
    if n.green.kind == .Call_Expr {
        inner, _           := odinsyntax.as_call_expr(n)
        callee, has_callee := odinsyntax.call_expr_callee(&inner)
        args, has_args     := odinsyntax.call_expr_args(&inner)
        text               := has_callee ? odinsyntax.node_text(callee) : ""
        if has_args && (text == "typeid_of" || text == "type_info_of") {
            arg_it := odinsyntax.arg_list_args(&args)
            if arg, has_arg := odinsyntax.child_iter_next(&arg_it); has_arg {
                n = arg
            }
        }
    }
    op := expr_type(c, file, n)
    if op.mode == .Type && op.type != INVALID_TYPE {
        out.types[op.type] = {}
        return
    }
    out.any = true
}
