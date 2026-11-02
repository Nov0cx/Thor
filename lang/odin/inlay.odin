// Inlay hints: the type of a `:=` name and the parameter name of a positional argument.
package odin

import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// How many nodes are walked between two cancel checks.
@(private = "file")
INLAY_CANCEL_STEP :: 1024

// The longest type label; a longer one is cut and ends in "…".
@(private = "file")
INLAY_TYPE_MAX :: 48

@(private = "file")
Inlay_Ctx :: struct {
    rc:         ^Request_Context,
    c:          ^odinsema.Checker,
    lo, hi:     int,
    types:      bool,
    parameters: bool,
    items:      map[int]int, // item index by name offset of the buffer's declarations
    hints:      [dynamic]lang.Inlay_Hint, // temp-allocated labels
    steps:      int,
    cancelled:  bool,
}

// Fills res.inlays with the hints of the buffer, or of [req.offset, req.end) when the request has a range.
@(private)
inlay_hints :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    types, parameters := config_inlays(e, req.workspace)
    if !types && !parameters {
        return
    }
    rc: Request_Context
    opened := request_open(e, req, &rc)
    defer request_close(&rc)
    if !opened || rc.parsed.tree == nil || rc.parsed.tree.root == nil {
        return
    }
    c := request_checker(&rc)
    if c == nil {
        return
    }
    ctx := Inlay_Ctx {
        rc         = &rc,
        c          = c,
        lo         = 0,
        hi         = len(req.source),
        types      = types,
        parameters = parameters,
        items      = make(map[int]int, len(rc.live.tree.items), context.temp_allocator),
        hints      = make([dynamic]lang.Inlay_Hint, context.temp_allocator),
    }
    if req.end > req.offset {
        ctx.lo, ctx.hi = clamp(req.offset, 0, len(req.source)), clamp(req.end, 0, len(req.source))
    }
    for item, i in rc.live.tree.items {
        ctx.items[item.name_offset] = i
    }
    inlay_walk(&ctx, odinsyntax.node_root(rc.parsed.tree))
    if ctx.cancelled || lang.request_cancelled(req) {
        return
    }
    slice.stable_sort_by(ctx.hints[:], proc(a, b: lang.Inlay_Hint) -> bool {
        return a.offset < b.offset
    })
    res.inlays = make([dynamic]lang.Inlay_Hint, 0, len(ctx.hints))
    for hint in ctx.hints {
        out := hint
        out.label = strings.clone(hint.label)
        append(&res.inlays, out)
    }
    res.ok = len(res.inlays) > 0
}

@(private = "file")
inlay_walk :: proc(ctx: ^Inlay_Ctx, n: odinsyntax.Syntax_Node) {
    if ctx.cancelled {
        return
    }
    ctx.steps += 1
    if ctx.steps % INLAY_CANCEL_STEP == 0 && lang.request_cancelled(ctx.rc.req) {
        ctx.cancelled = true
        return
    }
    start, end := odinsyntax.node_range(n)
    if int(end) < ctx.lo || int(start) > ctx.hi {
        return
    }
    n := n
    #partial switch n.green.kind {
    case .Value_Decl:
        if ctx.types {
            value_decl_hints(ctx, n)
        }
    case .Range_Stmt:
        if ctx.types {
            range_hints(ctx, n)
        }
    case .Call_Expr:
        if ctx.parameters {
            call_hints(ctx, n)
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        inlay_walk(ctx, child)
    }
}

// The type hints of a variable declaration with no written type.
@(private = "file")
value_decl_hints :: proc(ctx: ^Inlay_Ctx, n: odinsyntax.Syntax_Node) {
    if odinsema.is_constant_decl(n) {
        return
    }
    vd, _ := odinsyntax.as_value_decl(n)
    if _, typed := odinsyntax.value_decl_type(&vd); typed {
        return
    }
    names, has_names := odinsyntax.value_decl_names(&vd)
    values, has_values := odinsyntax.value_decl_values(&vd)
    if !has_names || !has_values {
        return
    }
    value_nodes := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
    vit := odinsyntax.expr_list_items(&values)
    for v in odinsyntax.child_iter_next(&vit) {
        append(&value_nodes, v)
    }
    i := 0
    nit := odinsyntax.name_list_names(&names)
    for name in odinsyntax.child_iter_next(&nit) {
        defer i += 1
        if name.green.kind != .Ident {
            continue
        }
        if len(value_nodes) == 1 && i == 0 && spells_type(ctx, value_nodes[0]) {
            continue
        }
        if len(value_nodes) > 1 && i < len(value_nodes) && spells_type(ctx, value_nodes[i]) {
            continue
        }
        type_hint(ctx, name)
    }
}

// The type hints of the variables of a range `for`.
@(private = "file")
range_hints :: proc(ctx: ^Inlay_Ctx, n: odinsyntax.Syntax_Node) {
    rs, _ := odinsyntax.as_range_stmt(n)
    vars, ok := odinsyntax.range_stmt_vars(&rs)
    if !ok {
        return
    }
    it := odinsyntax.expr_list_items(&vars)
    for v in odinsyntax.child_iter_next(&it) {
        if v.green.kind == .Ident {
            type_hint(ctx, v)
        }
    }
}

// Appends `: T` after the name `name` declares.
@(private = "file")
type_hint :: proc(ctx: ^Inlay_Ctx, name: odinsyntax.Syntax_Node) {
    text := odinsyntax.node_text(name)
    _, end := odinsyntax.node_range(name)
    if text == "_" || int(end) < ctx.lo || int(end) > ctx.hi {
        return
    }
    file := ctx.rc.live.id
    sym := odinsema.local_symbol(file, int(name.offset))
    if i, is_item := ctx.items[int(name.offset)]; is_item {
        sym = odinsema.Symbol{file = file, item = i32(i), child = -1}
    }
    type := odinsema.decl_type(ctx.c, sym)
    if type == odinsema.INVALID_TYPE {
        return
    }
    label := odinsema.type_string(&ctx.c.table, type, context.temp_allocator)
    if label == "" || label == "invalid" {
        return
    }
    if strings.rune_count(label) > INLAY_TYPE_MAX {
        cut := 0
        for _, at in label {
            if cut == INLAY_TYPE_MAX - 1 {
                label = strings.concatenate({label[:at], "…"}, context.temp_allocator)
                break
            }
            cut += 1
        }
    }
    append(&ctx.hints, lang.Inlay_Hint{
        offset = int(end),
        label  = strings.concatenate({": ", label}, context.temp_allocator),
        kind   = .Type,
    })
}

// Whether a value already spells its type: a typed literal, a conversion, a cast, `new(T)`, `make(T)` or a procedure literal.
@(private = "file")
spells_type :: proc(ctx: ^Inlay_Ctx, value: odinsyntax.Syntax_Node) -> bool {
    value := value
    #partial switch value.green.kind {
    case .Comp_Lit:
        lit, _ := odinsyntax.as_comp_lit(value)
        _, typed := odinsyntax.comp_lit_type(&lit)
        return typed
    case .Cast_Expr, .Auto_Cast_Expr, .Proc_Lit:
        return true
    case .Call_Expr:
        ce, _ := odinsyntax.as_call_expr(value)
        callee, ok := odinsyntax.call_expr_callee(&ce)
        if !ok {
            return false
        }
        name := odinsyntax.node_text(callee)
        if name == "new" || name == "make" || name == "new_clone" {
            return true
        }
        return odinsema.expr_type(ctx.c, ctx.rc.live.id, callee).mode == .Type
    }
    return false
}

// The parameter hints of the positional arguments of a call.
@(private = "file")
call_hints :: proc(ctx: ^Inlay_Ctx, call: odinsyntax.Syntax_Node) {
    ce, _ := odinsyntax.as_call_expr(call)
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return
    }
    arg_text := make(map[int]string, context.temp_allocator)
    count := 0
    it := odinsyntax.arg_list_args(&list)
    for arg in odinsyntax.child_iter_next(&it) {
        arg_text[int(arg.offset)] = odinsyntax.node_text(arg)
        count += 1
    }
    if count == 0 {
        return
    }
    callee_name := odinsyntax.node_text(callee)
    if dot := strings.last_index_any(callee_name, ".>"); dot >= 0 {
        callee_name = callee_name[dot + 1:]
    }
    params := odinsema.call_arg_params(ctx.c, ctx.rc.live.id, call, context.temp_allocator)
    for p in params {
        if !p.first || p.offset < ctx.lo || p.offset > ctx.hi {
            continue
        }
        if names_param(arg_text[p.offset], p.name) {
            continue
        }
        if count == 1 && (strings.has_suffix(callee_name, p.name) || strings.has_prefix(callee_name, p.name)) {
            continue
        }
        append(&ctx.hints, lang.Inlay_Hint{
            offset    = p.offset,
            label     = strings.concatenate({p.name, ":"}, context.temp_allocator),
            kind      = .Parameter,
            pad_right = true,
        })
    }
}

// Whether an argument already reads as its parameter: `name`, `&name`, `x.name` or `&x.name`.
@(private = "file")
names_param :: proc(arg, name: string) -> bool {
    text := strings.trim_prefix(strings.trim_space(arg), "&")
    if dot := strings.last_index_byte(text, '.'); dot >= 0 {
        text = text[dot + 1:]
    }
    return text == name
}
