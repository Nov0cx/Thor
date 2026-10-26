// Signature help: the signature of the innermost call that holds the caret, with the parameter
// the caret is on, and one signature per member of a procedure group.
package odin

import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Most members of a procedure group listed.
@(private = "file")
SIGNATURE_MEMBERS_MAX :: 32

// A parameter of a signature label.
@(private = "file")
Sig_Param :: struct {
    name:        string, // "" when unnamed; without the `$` of a polymorphic name
    start:       int,    // [start, end) in the label
    end:         int,
    variadic:    bool,
    has_default: bool,
}

// One signature. Strings are temp-allocated.
@(private = "file")
Sig_Entry :: struct {
    label:  string,
    params: [dynamic]Sig_Param,
    type:   odinsema.Type_Id,
}

// The call that holds the caret.
@(private = "file")
Call_Site :: struct {
    call:   odinsyntax.Syntax_Node,
    callee: odinsyntax.Syntax_Node,
    slot:   int,    // the argument the caret is in, counted from 0
    slots:  int,    // the argument slots written; a trailing comma opens one
    named:  string, // the name of the named argument the caret is in; "" when positional
    method: bool,   // `x->f(`: the receiver is the first parameter
}

// A non-trivia token of a label source and where it lands in the label.
@(private = "file")
Label_Token :: struct {
    src_start, src_end: int,
    out_start, out_end: int,
}

// Fills res.signature with the signatures of the call that holds req.offset.
@(private)
signature_help :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened || ctx.parsed.tree == nil || ctx.parsed.tree.root == nil {
        return
    }
    off := clamp(req.offset, 0, len(req.source))
    if in_literal(&ctx, off, numbers = false) {
        return
    }
    site, found := call_at(&ctx, off)
    if !found {
        return
    }
    c := request_checker(&ctx)
    if c == nil {
        return
    }
    entries := make([dynamic]Sig_Entry, context.temp_allocator)
    collect_entries(&ctx, c, site, &entries)
    if len(entries) == 0 || lang.request_cancelled(req) {
        return
    }
    active := active_entry(c, ctx.live.id, site, entries[:])
    emit_signature(entries[:], active, site, res)
}

// Clones the entries into res.signature.
@(private = "file")
emit_signature :: proc(entries: []Sig_Entry, active: int, site: Call_Site, res: ^lang.Result) {
    out, merr := make([dynamic]lang.Signature_Entry, 0, len(entries))
    if merr != nil {
        return
    }
    for entry in entries {
        label, err := strings.clone(entry.label)
        if err != nil {
            break
        }
        start, end := active_range(entry, site)
        if _, aerr := append(&out, lang.Signature_Entry{label = label, active_start = start, active_end = end}); aerr != nil {
            delete(label)
            break
        }
    }
    if len(out) == 0 {
        delete(out)
        return
    }
    res.signature = lang.Signature_Info{entries = out, active = clamp(active, 0, len(out) - 1)}
    res.ok = true
}

// The innermost call whose parentheses hold `off`. An unclosed call holds the text to its end.
@(private = "file")
call_at :: proc(ctx: ^Request_Context, off: int) -> (Call_Site, bool) {
    root := odinsyntax.node_root(ctx.parsed.tree)
    for probe in ([2]int{off, off - 1}) {
        if probe < 0 {
            continue
        }
        tok, ok := odinsyntax.node_token_at(root, u32(probe), context.temp_allocator)
        if !ok {
            continue
        }
        for p := tok.parent; p != nil; p = p.parent {
            if p.green.kind != .Arg_List || p.parent == nil || p.parent.green.kind != .Call_Expr {
                continue
            }
            if site, inside := site_of(p^, p.parent^, off); inside {
                return site, true
            }
        }
    }
    return {}, false
}

// The call site of `list`, the argument list of `call`; false when `off` is not inside its parentheses.
@(private = "file")
site_of :: proc(list, call: odinsyntax.Syntax_Node, off: int) -> (Call_Site, bool) {
    open_end, close_start := -1, -1
    _, list_end := odinsyntax.node_range(list)
    pos := int(list.offset)
    for child in odinsyntax.green_children(list.green) {
        child_len := int(odinsyntax.element_len(child))
        if tok, is_token := odinsyntax.element_token(child); is_token {
            #partial switch tok.kind {
            case .Open_Paren:
                if open_end < 0 {
                    open_end = pos + child_len
                }
            case .Close_Paren:
                close_start = pos
            }
        }
        pos += child_len
    }
    if open_end < 0 || off < open_end {
        return {}, false
    }
    if close_start >= 0 ? off > close_start : off > int(list_end) {
        return {}, false
    }
    ce, _ := odinsyntax.as_call_expr(call)
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    if !has_callee {
        return {}, false
    }
    site := Call_Site{call = call, callee = callee}
    if sel, is_sel := odinsyntax.as_selector_expr(callee); is_sel {
        _, site.method = odinsyntax.selector_expr_arrow(&sel)
    }
    commas := 0
    has_arg := false
    pos = int(list.offset)
    for child in odinsyntax.green_children(list.green) {
        child_len := int(odinsyntax.element_len(child))
        defer pos += child_len
        if tok, is_token := odinsyntax.element_token(child); is_token {
            if tok.kind == .Comma {
                commas += 1
                if pos + child_len <= off {
                    site.slot += 1
                }
            }
            continue
        }
        n, _ := odinsyntax.element_node(child)
        if n.kind == .Error {
            continue
        }
        has_arg = true
        if commas == site.slot && n.kind == .Field_Value {
            fv, _ := odinsyntax.as_field_value(odinsyntax.Syntax_Node{n, u32(pos), nil, list.tree})
            if name, ok := odinsyntax.field_value_name(&fv); ok && name.green.kind == .Ident {
                site.named = odinsyntax.node_text(name)
            }
        }
    }
    if has_arg || commas > 0 {
        site.slots = commas + 1
    }
    return site, true
}

// The signatures the callee of `site` stands for.
@(private = "file")
collect_entries :: proc(ctx: ^Request_Context, c: ^odinsema.Checker, site: Call_Site, out: ^[dynamic]Sig_Entry) {
    file := ctx.live.id
    fn := odinsema.expr_type(c, file, site.callee)
    name := callee_name(site.callee)
    #partial switch fn.mode {
    case .Builtin:
        if fn.has_symbol && fn.symbol.item >= 0 {
            add_entry(c, fn, name, out)
        }
    case .Value, .Const:
        base := odinsema.type_base(&c.table, fn.type)
        #partial switch g in odinsema.type_get(&c.table, base) {
        case odinsema.Proc_Type:
            add_entry(c, fn, name, out)
        case odinsema.Proc_Group_Type:
            group_entries(c, fn, g, out)
        }
    case .Type:
        type_entry(c, fn, strings.trim_space(odinsyntax.node_text(site.callee)), out)
    }
}

// Adds the entry of a call of the type `fn`: `List($T: typeid, $N: int)` for a polymorphic record,
// else the conversion `T(value)`.
@(private = "file")
type_entry :: proc(c: ^odinsema.Checker, fn: odinsema.Operand, name: string, out: ^[dynamic]Sig_Entry) {
    if fn.type == odinsema.INVALID_TYPE || name == "" {
        return
    }
    entry := Sig_Entry{params = make([dynamic]Sig_Param, context.temp_allocator), type = fn.type}
    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, name)
    params: []odinsema.Proc_Param
    file: odinsema.File_Id
    offset := -1
    #partial switch r in odinsema.type_get(&c.table, odinsema.type_base(&c.table, fn.type)) {
    case odinsema.Struct_Type:
        params, file, offset = r.params, r.file, r.offset
    case odinsema.Union_Type:
        params, file, offset = r.params, r.file, r.offset
    }
    if len(params) == 0 {
        strings.write_string(&sb, "(")
        start := strings.builder_len(sb)
        strings.write_string(&sb, "value")
        append(&entry.params, Sig_Param{name = "value", start = start, end = strings.builder_len(sb)})
        strings.write_string(&sb, ")")
        entry.label = strings.to_string(sb)
        append(out, entry)
        return
    }
    if list, found := record_params_at(c, file, offset); found {
        toks := make([dynamic]Label_Token, context.temp_allocator)
        write_label_tokens(&sb, odinsyntax.Syntax_Node(list), &toks)
        list_params(list, toks[:], &entry)
        if len(entry.params) == len(params) {
            entry.label = strings.to_string(sb)
            append(out, entry)
            return
        }
        clear(&entry.params)
        strings.builder_reset(&sb)
        strings.write_string(&sb, name)
    }
    strings.write_byte(&sb, '(')
    for param, i in params {
        if i > 0 {
            strings.write_string(&sb, ", ")
        }
        start := strings.builder_len(sb)
        write_param(&sb, c, param, false)
        append(&entry.params, Sig_Param{
            name        = strings.trim_prefix(param.name, "$"),
            start       = start,
            end         = strings.builder_len(sb),
            has_default = param.has_default,
        })
    }
    strings.write_byte(&sb, ')')
    entry.label = strings.to_string(sb)
    append(out, entry)
}

// The polymorphic parameter list of the struct or union type node at `offset` of `file`.
@(private = "file")
record_params_at :: proc(c: ^odinsema.Checker, file: odinsema.File_Id, offset: int) -> (odinsyntax.Param_List, bool) {
    if offset < 0 {
        return {}, false
    }
    n, ok := odinsema.node_at(c, file, offset)
    if !ok {
        return {}, false
    }
    if st, is_struct := odinsyntax.as_struct_type(n); is_struct {
        return odinsyntax.struct_type_params(&st)
    }
    if ut, is_union := odinsyntax.as_union_type(n); is_union {
        return odinsyntax.union_type_params(&ut)
    }
    return {}, false
}

// The name a callee is written with: the identifier, or the field of a selector. "" for another expression.
@(private = "file")
callee_name :: proc(callee: odinsyntax.Syntax_Node) -> string {
    #partial switch callee.green.kind {
    case .Ident:
        return odinsyntax.node_text(callee)
    case .Selector_Expr:
        sel, _ := odinsyntax.as_selector_expr(callee)
        if field, ok := odinsyntax.selector_expr_field(&sel); ok {
            return odinsyntax.node_text(odinsyntax.Syntax_Node(field))
        }
    }
    return ""
}

// One entry per member of the group `fn`. A member the checker cannot read is left out.
@(private = "file")
group_entries :: proc(c: ^odinsema.Checker, fn: odinsema.Operand, g: odinsema.Proc_Group_Type, out: ^[dynamic]Sig_Entry) {
    item: ^odinsema.Item
    if fn.has_symbol {
        item = odinsema.checker_item(c, fn.symbol)
    }
    if item != nil && item.kind == .Proc_Group {
        for m in item.members {
            if len(out) == SIGNATURE_MEMBERS_MAX {
                break
            }
            n, ok := odinsema.expr_under(c, fn.symbol.file, m.offset)
            if !ok {
                continue
            }
            op := odinsema.expr_type(c, fn.symbol.file, n)
            if _, is_proc := odinsema.type_get(&c.table, odinsema.type_base(&c.table, op.type)).(odinsema.Proc_Type); is_proc {
                add_entry(c, op, m.name, out)
            }
        }
        if len(out) > 0 {
            return
        }
    }
    if fn.has_symbol && fn.symbol.item == odinsema.LOCAL_ITEM {
        local_group_entries(c, fn.symbol, out)
        if len(out) > 0 {
            return
        }
    }
    for m in g.members {
        if len(out) == SIGNATURE_MEMBERS_MAX {
            break
        }
        add_entry(c, odinsema.Operand{mode = .Value, type = m}, "", out)
    }
}

// One entry per member of the procedure group the local `sym` declares.
@(private = "file")
local_group_entries :: proc(c: ^odinsema.Checker, sym: odinsema.Symbol, out: ^[dynamic]Sig_Entry) {
    l, ok := odinsema.local_at(c, sym.file, int(sym.child))
    if !ok || l.value_offset < 0 {
        return
    }
    n, found := odinsema.node_at(c, sym.file, l.value_offset)
    if !found {
        return
    }
    group, is_group := odinsyntax.as_proc_group(n)
    if !is_group {
        return
    }
    it := odinsyntax.proc_group_members(&group)
    for m in odinsyntax.child_iter_next(&it) {
        if len(out) == SIGNATURE_MEMBERS_MAX {
            break
        }
        op := odinsema.expr_type(c, sym.file, m)
        if _, is_proc := odinsema.type_get(&c.table, odinsema.type_base(&c.table, op.type)).(odinsema.Proc_Type); is_proc {
            add_entry(c, op, callee_name(m), out)
        }
    }
}

// Adds the signature of the procedure `op`: from the source of its declaration, else from its type.
@(private = "file")
add_entry :: proc(c: ^odinsema.Checker, op: odinsema.Operand, name: string, out: ^[dynamic]Sig_Entry) {
    entry := Sig_Entry{params = make([dynamic]Sig_Param, context.temp_allocator), type = op.type}
    if op.has_symbol && source_label(c, op.symbol, name, &entry) {
        append(out, entry)
        return
    }
    p, is_proc := odinsema.type_get(&c.table, odinsema.type_base(&c.table, op.type)).(odinsema.Proc_Type)
    if !is_proc {
        return
    }
    type_label(c, p, name, &entry)
    append(out, entry)
}

// Fills `entry` from the procedure type written at the declaration `sym`; false when there is none.
@(private = "file")
source_label :: proc(c: ^odinsema.Checker, sym: odinsema.Symbol, fallback: string, entry: ^Sig_Entry) -> bool {
    name := fallback
    sep := ": "
    type_offset, value_offset := -1, -1
    if sym.item == odinsema.LOCAL_ITEM {
        l, ok := odinsema.local_at(c, sym.file, int(sym.child))
        if !ok {
            return false
        }
        name = l.name
        if l.kind == .Proc || l.kind == .Const {
            sep = " :: "
        }
        type_offset, value_offset = l.type_offset, l.value_offset
    } else {
        item := odinsema.checker_item(c, sym)
        if item == nil {
            return false
        }
        name = item.name
        if item.kind == .Proc || item.kind == .Const {
            sep = " :: "
        }
        type_offset, value_offset = item.type_offset, item.value_offset
    }
    pt, found := proc_type_at(c, sym.file, type_offset)
    if !found {
        pt, found = proc_type_at(c, sym.file, value_offset)
    }
    if !found {
        return false
    }
    sb := strings.builder_make(context.temp_allocator)
    if name != "" {
        strings.write_string(&sb, name)
        strings.write_string(&sb, sep)
    }
    toks := make([dynamic]Label_Token, context.temp_allocator)
    write_label_tokens(&sb, pt, &toks)
    entry.label = strings.to_string(sb)
    source_params(pt, toks[:], entry)
    return true
}

// The procedure type of the expression at `offset` of `file`, through a literal and a directive.
@(private = "file")
proc_type_at :: proc(c: ^odinsema.Checker, file: odinsema.File_Id, offset: int) -> (odinsyntax.Syntax_Node, bool) {
    if offset < 0 {
        return {}, false
    }
    n, ok := odinsema.node_at(c, file, offset)
    for ok {
        #partial switch n.green.kind {
        case .Proc_Type:
            return n, true
        case .Proc_Lit:
            pl, _ := odinsyntax.as_proc_lit(n)
            pt, has_type := odinsyntax.proc_lit_type(&pl)
            n, ok = odinsyntax.Syntax_Node(pt), has_type
        case .Tag_Expr:
            te, _ := odinsyntax.as_tag_expr(n)
            n, ok = odinsyntax.tag_expr_expr(&te)
        case:
            return {}, false
        }
    }
    return {}, false
}

// A non-trivia token of a label source.
@(private = "file")
Raw_Token :: struct {
    kind:  odinsyntax.Token_Kind,
    start: int,
    end:   int,
    space: bool, // trivia comes before it
}

// Appends the non-trivia tokens of `g`, which starts at `offset`.
@(private = "file")
collect_tokens :: proc(g: ^odinsyntax.Green_Node, offset: int, raw: ^[dynamic]Raw_Token, space: ^bool) {
    pos := offset
    for child in odinsyntax.green_children(g) {
        child_len := int(odinsyntax.element_len(child))
        defer pos += child_len
        if inner, is_node := odinsyntax.element_node(child); is_node {
            collect_tokens(inner, pos, raw, space)
            continue
        }
        tok, _ := odinsyntax.element_token(child)
        if odinsyntax.token_is_trivia(tok.kind) {
            space^ = true
            continue
        }
        if child_len == 0 {
            continue
        }
        append(raw, Raw_Token{kind = tok.kind, start = pos, end = pos + child_len, space = space^})
        space^ = false
    }
}

// Writes the tokens of `n` on one line: comments dropped, each run of trivia one space, no space
// inside parentheses and no comma before a closing one.
@(private = "file")
write_label_tokens :: proc(sb: ^strings.Builder, n: odinsyntax.Syntax_Node, out: ^[dynamic]Label_Token) {
    raw := make([dynamic]Raw_Token, context.temp_allocator)
    space := false
    collect_tokens(n.green, int(n.offset), &raw, &space)
    text := n.tree.text
    prev := odinsyntax.Token_Kind.Error
    for r, i in raw {
        if r.kind == .Comma && i + 1 < len(raw) && raw[i + 1].kind == .Close_Paren {
            continue
        }
        if r.space && i > 0 && prev != .Open_Paren && r.kind != .Close_Paren {
            strings.write_byte(sb, ' ')
        }
        start := strings.builder_len(sb^)
        strings.write_string(sb, text[r.start:r.end])
        append(out, Label_Token{src_start = r.start, src_end = r.end, out_start = start, out_end = strings.builder_len(sb^)})
        prev = r.kind
    }
}

// The label range of the source range [start, end); false when no label token lies in it.
@(private = "file")
label_range :: proc(toks: []Label_Token, start, end: int) -> (lo, hi: int, ok: bool) {
    lo, hi = -1, -1
    for t in toks {
        if t.src_start >= start && t.src_end <= end {
            if lo < 0 {
                lo = t.out_start
            }
            hi = t.out_end
        }
    }
    return lo, hi, lo >= 0
}

// Reads the parameters of the procedure type node `pt` into `entry`.
@(private = "file")
source_params :: proc(pt: odinsyntax.Syntax_Node, toks: []Label_Token, entry: ^Sig_Entry) {
    ptv, _ := odinsyntax.as_proc_type(pt)
    list, ok := odinsyntax.proc_type_params(&ptv)
    if ok {
        list_params(list, toks, entry)
    }
}

// Reads the fields of the parameter list `list` into `entry`. A field with several names gives one
// parameter per name; the last name also covers the type.
@(private = "file")
list_params :: proc(list: odinsyntax.Param_List, toks: []Label_Token, entry: ^Sig_Entry) {
    list := list
    it := odinsyntax.param_list_fields(&list)
    for fnode in odinsyntax.child_iter_next(&it) {
        field, _ := odinsyntax.as_field(fnode)
        fstart, fend := odinsyntax.node_range(fnode)
        variadic := false
        if t, has_type := odinsyntax.field_type(&field); has_type {
            variadic = t.green.kind == .Ellipsis_Type
        }
        _, has_default := odinsyntax.field_default(&field)
        _, has_colon := odinsyntax.find_child_token((^odinsyntax.Syntax_Node)(&field), {tokens = {.Colon}})
        names, has_names := odinsyntax.field_names(&field)
        if !has_colon || !has_names {
            lo, hi, found := label_range(toks, int(fstart), int(fend))
            if found {
                append(&entry.params, Sig_Param{start = lo, end = hi, variadic = variadic, has_default = has_default})
            }
            continue
        }
        name_nodes := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
        nit := odinsyntax.name_list_names(&names)
        for nn in odinsyntax.child_iter_next(&nit) {
            append(&name_nodes, nn)
        }
        for nn, k in name_nodes {
            nstart, nend := odinsyntax.node_range(nn)
            last := k == len(name_nodes) - 1
            lo, hi, found := label_range(toks, int(nstart), last ? int(fend) : int(nend))
            if !found {
                continue
            }
            append(&entry.params, Sig_Param{
                name        = strings.trim_prefix(strings.trim_space(odinsyntax.node_text(nn)), "$"),
                start       = lo,
                end         = hi,
                variadic    = variadic,
                has_default = has_default,
            })
        }
    }
}

// Fills `entry` from the procedure type `p`: `name: proc(a: int, b: string) -> bool`.
@(private = "file")
type_label :: proc(c: ^odinsema.Checker, p: odinsema.Proc_Type, name: string, entry: ^Sig_Entry) {
    sb := strings.builder_make(context.temp_allocator)
    if name != "" {
        strings.write_string(&sb, name)
        strings.write_string(&sb, ": ")
    }
    strings.write_string(&sb, "proc")
    if p.convention != "" && p.convention != "odin" {
        strings.write_string(&sb, " \"")
        strings.write_string(&sb, p.convention)
        strings.write_string(&sb, "\" ")
    }
    strings.write_byte(&sb, '(')
    for param, i in p.params {
        if i > 0 {
            strings.write_string(&sb, ", ")
        }
        start := strings.builder_len(sb)
        variadic := .Variadic in param.flags || .C_Vararg in param.flags
        write_param(&sb, c, param, variadic)
        append(&entry.params, Sig_Param{
            name        = strings.trim_prefix(param.name, "$"),
            start       = start,
            end         = strings.builder_len(sb),
            variadic    = variadic,
            has_default = param.has_default,
        })
    }
    strings.write_byte(&sb, ')')
    switch {
    case p.diverging:
        strings.write_string(&sb, " -> !")
    case len(p.results) == 1 && p.results[0].name == "":
        strings.write_string(&sb, " -> ")
        write_param(&sb, c, p.results[0], false)
    case len(p.results) > 0:
        strings.write_string(&sb, " -> (")
        for r, i in p.results {
            if i > 0 {
                strings.write_string(&sb, ", ")
            }
            write_param(&sb, c, r, false)
        }
        strings.write_byte(&sb, ')')
    }
    entry.label = strings.to_string(sb)
}

// `name: T = default`, `name := default`, `..T` or `T`.
@(private = "file")
write_param :: proc(sb: ^strings.Builder, c: ^odinsema.Checker, param: odinsema.Proc_Param, variadic: bool) {
    if param.name != "" {
        strings.write_string(sb, param.name)
        if param.inferred {
            strings.write_string(sb, " := ")
            strings.write_string(sb, param.default)
            return
        }
        strings.write_string(sb, ": ")
    }
    if variadic {
        strings.write_string(sb, "..")
    }
    strings.write_string(sb, odinsema.type_string(&c.table, param.type, context.temp_allocator))
    if param.has_default {
        strings.write_string(sb, " = ")
        strings.write_string(sb, param.default)
    }
}

// The entry the call picks: the group member the checker chooses for the arguments, else the first
// that takes as many arguments as are written, else the first that takes them when more are added.
@(private = "file")
active_entry :: proc(c: ^odinsema.Checker, file: odinsema.File_Id, site: Call_Site, entries: []Sig_Entry) -> int {
    if len(entries) < 2 {
        return 0
    }
    n := site.slots + (site.method ? 1 : 0)
    if chosen := odinsema.call_group_member(c, file, site.call); chosen != odinsema.INVALID_TYPE {
        for entry, i in entries {
            if entry.type == chosen && takes_more(entry, n) {
                return i
            }
        }
    }
    for entry, i in entries {
        if takes_more(entry, n) && required_params(entry) <= n {
            return i
        }
    }
    for entry, i in entries {
        if takes_more(entry, n) {
            return i
        }
    }
    return 0
}

// True when `entry` takes `n` arguments.
@(private = "file")
takes_more :: proc(entry: Sig_Entry, n: int) -> bool {
    return n <= len(entry.params) || (len(entry.params) > 0 && entry.params[len(entry.params) - 1].variadic)
}

// The parameters a call must write.
@(private = "file")
required_params :: proc(entry: Sig_Entry) -> int {
    count := 0
    for p in entry.params {
        if !p.has_default && !p.variadic {
            count += 1
        }
    }
    return count
}

// The label range of the parameter the caret is on; empty when there is none.
@(private = "file")
active_range :: proc(entry: Sig_Entry, site: Call_Site) -> (start, end: int) {
    k := -1
    if site.named != "" {
        for p, i in entry.params {
            if p.name == site.named {
                k = i
                break
            }
        }
    } else {
        k = site.slot + (site.method ? 1 : 0)
        if k >= len(entry.params) {
            k = len(entry.params) > 0 && entry.params[len(entry.params) - 1].variadic ? len(entry.params) - 1 : -1
        }
    }
    if k < 0 {
        return 0, 0
    }
    return entry.params[k].start, entry.params[k].end
}
