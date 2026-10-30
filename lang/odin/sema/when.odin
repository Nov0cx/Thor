package odinsema

import "core:mem"
import "core:strconv"
import "core:strings"

import odinsyntax "../syntax"

// The answer a `when` condition gives for a target. Unknown counts as true for visibility.
Tri :: enum u8 {
    Unknown,
    False,
    True,
}

// The operation of one node of a compiled `when` condition.
Cond_Op :: enum u8 {
    Unknown,   // an expression the evaluator does not read
    Bool,      // `true`, `false`
    Int,       // an integer literal
    String,    // a string literal
    Enum_Name, // `.Name`
    Ident,     // a constant: `ODIN_OS`, or a package constant, which stays unknown
    Not,       // !args[0]
    Neg,       // -args[0]
    And,
    Or,
    Eq,
    Not_Eq,
    Lt,
    Gt,
    Lt_Eq,
    Gt_Eq,
    In,
    Not_In,
    Set,       // `{.A, .B}`: args are the elements
    Config,    // `#config(text, args[0])`
    Defined,   // `#defined(text)`
    Size_Of,   // `size_of(text)`
}

// One node of a compiled `when` condition. It holds no target data, so the item tree stays target-independent.
Cond_Expr :: struct {
    op:    Cond_Op,
    value: i64,    // Bool: 0 or 1; Int: the value
    text:  string, // String, Enum_Name, Ident, Config, Defined, Size_Of: the name or the unquoted text
    args:  []int,  // indices into Item_Tree.conds
}

// A value met while a condition is evaluated.
@(private)
Cond_Value_Kind :: enum u8 {
    Unknown,
    Bool,
    Int,
    String,
    Name,
    Set,
}

@(private)
Cond_Value :: struct {
    kind: Cond_Value_Kind,
    i:    i64,    // Bool: 0 or 1
    s:    string, // String, Name
    expr: int,    // Set: the Cond_Expr that lists the elements
}

@(private = "file")
UNKNOWN_VALUE :: Cond_Value{}

// Compiles the condition `n` into `out` and gives the index of its root node.
@(private)
cond_compile :: proc(n: odinsyntax.Syntax_Node, alloc: mem.Allocator, out: ^[dynamic]Cond_Expr, err: ^mem.Allocator_Error) -> int {
    n := n
    e := Cond_Expr{op = .Unknown}
    #partial switch n.green.kind {
    case .Paren_Expr:
        p, _ := odinsyntax.as_paren_expr(n)
        if inner, ok := odinsyntax.paren_expr_expr(&p); ok {
            return cond_compile(inner, alloc, out, err)
        }
    case .Ident:
        name := odinsyntax.node_text(n)
        switch name {
        case "true":
            e = {op = .Bool, value = 1}
        case "false":
            e = {op = .Bool, value = 0}
        case:
            e = {op = .Ident, text = cond_clone(name, alloc, err)}
        }
    case .Literal:
        l, _ := odinsyntax.as_literal(n)
        tok, ok := odinsyntax.literal_token(&l)
        if !ok {
            break
        }
        text := odinsyntax.syntax_token_text(tok)
        #partial switch tok.green.kind {
        case .Integer:
            if v, vok := strconv.parse_i64(text); vok {
                e = {op = .Int, value = v}
            }
        case .String:
            if len(text) >= 2 && (text[0] == '`' || strings.index_byte(text, '\\') < 0) {
                e = {op = .String, text = cond_clone(unquote(text), alloc, err)}
            }
        }
    case .Implicit_Selector:
        s, _ := odinsyntax.as_implicit_selector(n)
        if field, ok := odinsyntax.implicit_selector_field(&s); ok {
            e = {op = .Enum_Name, text = cond_clone(odinsyntax.node_text(odinsyntax.Syntax_Node(field)), alloc, err)}
        }
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        op, ook := odinsyntax.unary_expr_op(&u)
        operand, aok := odinsyntax.unary_expr_operand(&u)
        if !ook || !aok {
            break
        }
        #partial switch op.green.kind {
        case .Not:
            e.op = .Not
        case .Sub:
            e.op = .Neg
        case:
            break
        }
        if e.op != .Unknown {
            e.args = cond_args(alloc, err, cond_compile(operand, alloc, out, err))
        }
    case .Binary_Expr:
        bin, _ := odinsyntax.as_binary_expr(n)
        op, ook := odinsyntax.binary_expr_op(&bin)
        lhs, lok := odinsyntax.binary_expr_lhs(&bin)
        rhs, rok := odinsyntax.binary_expr_rhs(&bin)
        if !ook || !lok || !rok {
            break
        }
        #partial switch op.green.kind {
        case .Cmp_And: e.op = .And
        case .Cmp_Or:  e.op = .Or
        case .Cmp_Eq:  e.op = .Eq
        case .Not_Eq:  e.op = .Not_Eq
        case .Lt:      e.op = .Lt
        case .Gt:      e.op = .Gt
        case .Lt_Eq:   e.op = .Lt_Eq
        case .Gt_Eq:   e.op = .Gt_Eq
        case .In:      e.op = .In
        case .Not_In:  e.op = .Not_In
        }
        if e.op != .Unknown {
            l := cond_compile(lhs, alloc, out, err)
            r := cond_compile(rhs, alloc, out, err)
            e.args = cond_args(alloc, err, l, r)
        }
    case .Comp_Lit:
        c, _ := odinsyntax.as_comp_lit(n)
        if _, typed := odinsyntax.comp_lit_type(&c); typed {
            break
        }
        elems := make([dynamic]int, alloc)
        it := odinsyntax.comp_lit_elems(&c)
        for elem in odinsyntax.child_iter_next(&it) {
            if _, aerr := append(&elems, cond_compile(elem, alloc, out, err)); aerr != nil && err^ == nil {
                err^ = aerr
            }
        }
        e = {op = .Set, args = elems[:]}
    case .Call_Expr:
        e = compile_call(n, alloc, out, err)
    }
    if _, aerr := append(out, e); aerr != nil {
        if err^ == nil {
            err^ = aerr
        }
        return -1
    }
    return len(out) - 1
}

// `#config(NAME, default)`, `#defined(NAME)` and `size_of(T)`; anything else is unknown.
@(private = "file")
compile_call :: proc(n: odinsyntax.Syntax_Node, alloc: mem.Allocator, out: ^[dynamic]Cond_Expr, err: ^mem.Allocator_Error) -> Cond_Expr {
    call, _ := odinsyntax.as_call_expr(n)
    callee, cok := odinsyntax.call_expr_callee(&call)
    list, lok := odinsyntax.call_expr_args(&call)
    if !cok || !lok {
        return {}
    }
    args: [3]odinsyntax.Syntax_Node
    count := 0
    it := odinsyntax.arg_list_args(&list)
    for arg in odinsyntax.child_iter_next(&it) {
        if count < len(args) {
            args[count] = arg
        }
        count += 1
    }
    name: string
    if d, ok := odinsyntax.as_directive(callee); ok {
        tok, nok := odinsyntax.directive_name(&d)
        if !nok {
            return {}
        }
        name = strings.concatenate({"#", odinsyntax.syntax_token_text(tok)}, context.temp_allocator)
    } else if callee.green.kind == .Ident {
        name = odinsyntax.node_text(callee)
    }
    switch {
    case name == "#config" && count == 2 && args[0].green.kind == .Ident:
        def := cond_compile(args[1], alloc, out, err)
        return {op = .Config, text = cond_clone(odinsyntax.node_text(args[0]), alloc, err), args = cond_args(alloc, err, def)}
    case name == "#defined" && count == 1 && args[0].green.kind == .Ident:
        return {op = .Defined, text = cond_clone(odinsyntax.node_text(args[0]), alloc, err)}
    case name == "size_of" && count == 1 && args[0].green.kind == .Ident:
        return {op = .Size_Of, text = cond_clone(odinsyntax.node_text(args[0]), alloc, err)}
    }
    return {}
}

@(private = "file")
cond_args :: proc(alloc: mem.Allocator, err: ^mem.Allocator_Error, args: ..int) -> []int {
    out, aerr := make([]int, len(args), alloc)
    if aerr != nil {
        if err^ == nil {
            err^ = aerr
        }
        return nil
    }
    copy(out, args)
    return out
}

@(private = "file")
cond_clone :: proc(s: string, alloc: mem.Allocator, err: ^mem.Allocator_Error) -> string {
    if s == "" {
        return ""
    }
    out, cerr := strings.clone(s, alloc)
    if cerr != nil && err^ == nil {
        err^ = cerr
    }
    return out
}

// What the condition of guard `guard` gives for `target` alone; a final `else` gives .True.
guard_condition :: proc(tree: ^Item_Tree, guard: int, target: Target) -> Tri {
    if tree == nil || guard < 0 || guard >= len(tree.guards) {
        return .True
    }
    g := tree.guards[guard]
    if g.expr < 0 {
        return g.cond == "" ? .True : .Unknown
    }
    return cond_eval(tree, g.expr, target)
}

// Whether guard `guard` holds for `target`: its own condition, every earlier branch of its chain and its parent.
// .True when all are known, .False when one decides it, else .Unknown. A guard of -1 gives .True.
guard_state :: proc(tree: ^Item_Tree, guard: int, target: Target) -> Tri {
    if tree == nil || guard < 0 || guard >= len(tree.guards) {
        return .True
    }
    state := Tri.True
    for g := guard; g >= 0 && g < len(tree.guards); g = tree.guards[g].parent {
        switch branch_state(tree, g, target) {
        case .False:
            return .False
        case .Unknown:
            state = .Unknown
        case .True:
        }
    }
    return state
}

// True when declarations under guard `guard` exist for `target`. An unknown condition counts as active.
guard_active :: proc(tree: ^Item_Tree, guard: int, target: Target) -> bool {
    return guard_state(tree, guard, target) != .False
}

// True when `item` of `tree` exists for `target`.
item_active :: proc(tree: ^Item_Tree, item: ^Item, target: Target) -> bool {
    return guard_active(tree, item.guard, target)
}

// The state of one branch of a chain, its parent not counted.
@(private = "file")
branch_state :: proc(tree: ^Item_Tree, guard: int, target: Target) -> Tri {
    state := guard_condition(tree, guard, target)
    if state == .False {
        return .False
    }
    for p := tree.guards[guard].previous; p >= 0 && p < len(tree.guards); p = tree.guards[p].previous {
        switch guard_condition(tree, p, target) {
        case .True:
            return .False
        case .Unknown:
            state = .Unknown
        case .False:
        }
    }
    return state
}

// What the `when` condition `n`, from any scope, gives for `target`. Names of the package stay unknown.
when_condition :: proc(n: odinsyntax.Syntax_Node, target: Target) -> Tri {
    conds := make([dynamic]Cond_Expr, context.temp_allocator)
    err: mem.Allocator_Error
    root := cond_compile(n, context.temp_allocator, &conds, &err)
    if err != nil {
        return .Unknown
    }
    tree := Item_Tree{conds = conds[:]}
    return cond_eval(&tree, root, target)
}

// The conjunction of two answers: .False when one is false, .True when both are true.
tri_and :: proc(a, b: Tri) -> Tri {
    if a == .False || b == .False {
        return .False
    }
    if a == .True && b == .True {
        return .True
    }
    return .Unknown
}

// The negation of an answer.
tri_not :: proc(a: Tri) -> Tri {
    switch a {
    case .True:    return .False
    case .False:   return .True
    case .Unknown:
    }
    return .Unknown
}

// What the compiled condition at `expr` gives for `target`.
cond_eval :: proc(tree: ^Item_Tree, expr: int, target: Target) -> Tri {
    v := eval(tree, expr, target)
    if v.kind != .Bool {
        return .Unknown
    }
    return v.i != 0 ? .True : .False
}

@(private = "file")
bool_value :: proc(b: bool) -> Cond_Value {
    return {kind = .Bool, i = b ? 1 : 0}
}

@(private = "file")
tri_value :: proc(t: Tri) -> Cond_Value {
    switch t {
    case .True:    return bool_value(true)
    case .False:   return bool_value(false)
    case .Unknown:
    }
    return UNKNOWN_VALUE
}

@(private = "file")
as_tri :: proc(v: Cond_Value) -> Tri {
    if v.kind != .Bool {
        return .Unknown
    }
    return v.i != 0 ? .True : .False
}

@(private = "file")
eval :: proc(tree: ^Item_Tree, expr: int, target: Target) -> Cond_Value {
    if expr < 0 || expr >= len(tree.conds) {
        return UNKNOWN_VALUE
    }
    e := tree.conds[expr]
    switch e.op {
    case .Unknown:
        return UNKNOWN_VALUE
    case .Bool:
        return bool_value(e.value != 0)
    case .Int:
        return {kind = .Int, i = e.value}
    case .String:
        return {kind = .String, s = e.text}
    case .Enum_Name:
        return {kind = .Name, s = e.text}
    case .Ident:
        return constant_value(e.text, target)
    case .Not:
        v := eval(tree, arg(e, 0), target)
        if v.kind != .Bool {
            return UNKNOWN_VALUE
        }
        return bool_value(v.i == 0)
    case .Neg:
        v := eval(tree, arg(e, 0), target)
        if v.kind != .Int {
            return UNKNOWN_VALUE
        }
        return {kind = .Int, i = -v.i}
    case .And:
        l := as_tri(eval(tree, arg(e, 0), target))
        if l == .False {
            return bool_value(false)
        }
        r := as_tri(eval(tree, arg(e, 1), target))
        if r == .False {
            return bool_value(false)
        }
        return tri_value(l == .True && r == .True ? .True : .Unknown)
    case .Or:
        l := as_tri(eval(tree, arg(e, 0), target))
        if l == .True {
            return bool_value(true)
        }
        r := as_tri(eval(tree, arg(e, 1), target))
        if r == .True {
            return bool_value(true)
        }
        return tri_value(l == .False && r == .False ? .False : .Unknown)
    case .Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
        return compare(e.op, eval(tree, arg(e, 0), target), eval(tree, arg(e, 1), target))
    case .In, .Not_In:
        v := eval(tree, arg(e, 0), target)
        set := eval(tree, arg(e, 1), target)
        if v.kind == .Unknown || set.kind != .Set {
            return UNKNOWN_VALUE
        }
        found := Tri.False
        for elem in tree.conds[set.expr].args {
            switch as_tri(compare(.Eq, v, eval(tree, elem, target))) {
            case .True:
                found = .True
            case .Unknown:
                if found == .False {
                    found = .Unknown
                }
            case .False:
            }
            if found == .True {
                break
            }
        }
        if e.op == .Not_In {
            switch found {
            case .True:    found = .False
            case .False:   found = .True
            case .Unknown:
            }
        }
        return tri_value(found)
    case .Set:
        return {kind = .Set, expr = expr}
    case .Config:
        if d, ok := target_define(target, e.text); ok {
            return define_value(d)
        }
        return eval(tree, arg(e, 0), target)
    case .Defined:
        if _, ok := target_define(target, e.text); ok {
            return bool_value(true)
        }
        if constant_value(e.text, target).kind != .Unknown {
            return bool_value(true)
        }
        return UNKNOWN_VALUE
    case .Size_Of:
        if size := type_size(e.text, target); size > 0 {
            return {kind = .Int, i = size}
        }
        return UNKNOWN_VALUE
    }
    return UNKNOWN_VALUE
}

@(private = "file")
arg :: proc(e: Cond_Expr, i: int) -> int {
    return i < len(e.args) ? e.args[i] : -1
}

@(private = "file")
compare :: proc(op: Cond_Op, l, r: Cond_Value) -> Cond_Value {
    if l.kind == .Unknown || l.kind != r.kind || l.kind == .Set {
        return UNKNOWN_VALUE
    }
    switch l.kind {
    case .Bool, .Name:
        if l.kind == .Name && l.s == "" {
            return UNKNOWN_VALUE
        }
        eq := l.kind == .Bool ? l.i == r.i : l.s == r.s
        #partial switch op {
        case .Eq:     return bool_value(eq)
        case .Not_Eq: return bool_value(!eq)
        }
    case .Int:
        #partial switch op {
        case .Eq:     return bool_value(l.i == r.i)
        case .Not_Eq: return bool_value(l.i != r.i)
        case .Lt:     return bool_value(l.i < r.i)
        case .Gt:     return bool_value(l.i > r.i)
        case .Lt_Eq:  return bool_value(l.i <= r.i)
        case .Gt_Eq:  return bool_value(l.i >= r.i)
        }
    case .String:
        #partial switch op {
        case .Eq:     return bool_value(l.s == r.s)
        case .Not_Eq: return bool_value(l.s != r.s)
        case .Lt:     return bool_value(l.s < r.s)
        case .Gt:     return bool_value(l.s > r.s)
        case .Lt_Eq:  return bool_value(l.s <= r.s)
        case .Gt_Eq:  return bool_value(l.s >= r.s)
        }
    case .Unknown, .Set:
    }
    return UNKNOWN_VALUE
}

@(private = "file")
define_value :: proc(d: Define_Value) -> Cond_Value {
    switch v in d {
    case bool:   return bool_value(v)
    case i64:    return {kind = .Int, i = v}
    case string: return {kind = .String, s = v}
    }
    return UNKNOWN_VALUE
}

// The value of a build constant for `target`. A define of an `ODIN_` name overrides it.
// ODIN_TEST is unknown unless defined: the editor shows test and non-test code.
@(private)
constant_value :: proc(name: string, target: Target) -> Cond_Value {
    if !strings.has_prefix(name, "ODIN_") {
        return UNKNOWN_VALUE
    }
    if d, ok := target_define(target, name); ok {
        return define_value(d)
    }
    switch name {
    case "ODIN_OS":
        if target.os == .Unknown {
            return UNKNOWN_VALUE
        }
        return {kind = .Name, s = OS_ENUM_NAMES[target.os]}
    case "ODIN_OS_STRING":
        if target.os == .Unknown {
            return UNKNOWN_VALUE
        }
        return {kind = .String, s = target_os_name(target.os)}
    case "ODIN_ARCH":
        if target.arch == .Unknown {
            return UNKNOWN_VALUE
        }
        return {kind = .Name, s = target_arch_name(target.arch)}
    case "ODIN_ARCH_STRING":
        if target.arch == .Unknown {
            return UNKNOWN_VALUE
        }
        return {kind = .String, s = target_arch_name(target.arch)}
    case "ODIN_ENDIAN":
        if target.arch == .Unknown {
            return UNKNOWN_VALUE
        }
        return {kind = .Name, s = "Little"}
    case "ODIN_ENDIAN_STRING":
        if target.arch == .Unknown {
            return UNKNOWN_VALUE
        }
        return {kind = .String, s = "little"}
    case "ODIN_DEBUG":
        return bool_value(target.debug)
    case "ODIN_NO_RTTI", "ODIN_DISABLE_ASSERT", "ODIN_NO_BOUNDS_CHECK", "ODIN_NO_TYPE_ASSERT",
         "ODIN_FOREIGN_ERROR_PROCEDURES", "ODIN_VALGRIND_SUPPORT", "ODIN_USE_SEPARATE_MODULES":
        return bool_value(false)
    case "ODIN_NO_CRT":
        #partial switch target.os {
        case .Unknown, .Freestanding, .JS, .WASI, .Orca:
            return UNKNOWN_VALUE
        }
        return bool_value(false)
    case "ODIN_WORD_SIZE":
        if size := type_size("int", target); size > 0 {
            return {kind = .Int, i = size}
        }
    }
    return UNKNOWN_VALUE
}

// The member names of `runtime.Odin_OS_Type` for each OS.
@(private = "file")
OS_ENUM_NAMES := [Target_OS]string {
    .Unknown      = "Unknown",
    .Windows      = "Windows",
    .Darwin       = "Darwin",
    .Linux        = "Linux",
    .FreeBSD      = "FreeBSD",
    .OpenBSD      = "OpenBSD",
    .NetBSD       = "NetBSD",
    .Haiku        = "Haiku",
    .WASI         = "WASI",
    .JS           = "JS",
    .Orca         = "Orca",
    .Freestanding = "Freestanding",
}

// The size of a basic type for `target`; 0 when not known.
@(private)
type_size :: proc(name: string, target: Target) -> i64 {
    switch name {
    case "bool", "b8", "i8", "u8":
        return 1
    case "b16", "i16", "u16", "i16le", "u16le", "i16be", "u16be", "f16", "f16le", "f16be":
        return 2
    case "b32", "i32", "u32", "i32le", "u32le", "i32be", "u32be", "f32", "f32le", "f32be", "rune", "complex32":
        return 4
    case "b64", "i64", "u64", "i64le", "u64le", "i64be", "u64be", "f64", "f64le", "f64be", "complex64", "quaternion64":
        return 8
    case "i128", "u128", "i128le", "u128le", "i128be", "u128be", "complex128", "quaternion128":
        return 16
    case "quaternion256":
        return 32
    }
    word, ptr: i64
    switch target.arch {
    case .amd64, .arm64, .riscv64:
        word, ptr = 8, 8
    case .wasm64p32:
        word, ptr = 8, 4
    case .i386, .arm32, .wasm32:
        word, ptr = 4, 4
    case .Unknown:
        return 0
    }
    switch name {
    case "int", "uint":
        return word
    case "rawptr", "uintptr", "cstring":
        return ptr
    case "typeid":
        return 8
    }
    return 0
}
