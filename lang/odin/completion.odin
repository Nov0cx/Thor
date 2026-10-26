// Completion: the members after `x.`, the enum members of an implicit `.`, and the names in scope
// for a bare identifier prefix, ranked by the type the caret expects.
package odin

import "core:fmt"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Most package-level values typed to rank them against the expected type.
@(private = "file")
EXPECTED_TYPED_MAX :: 64

// Keywords and basic type names offered for a bare prefix.
@(private = "file")
ODIN_KEYWORDS :: [?]string {
    "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context",
    "continue", "defer", "distinct", "do", "dynamic", "else", "enum",
    "fallthrough", "for", "foreign", "if", "import", "in", "map", "matrix",
    "not_in", "or_break", "or_continue", "or_else", "or_return", "package", "proc",
    "return", "struct", "switch", "transmute", "typeid", "union", "using", "when", "where",
    "bool", "b8", "b16", "b32", "b64",
    "int", "i8", "i16", "i32", "i64", "i128",
    "uint", "u8", "u16", "u32", "u64", "u128", "uintptr",
    "f16", "f32", "f64",
    "complex32", "complex64", "complex128",
    "quaternion64", "quaternion128", "quaternion256",
    "rune", "string", "cstring", "rawptr", "any", "byte",
    "true", "false", "nil",
}

// The group a candidate is listed in, first to last.
@(private = "file")
Tier :: enum u8 {
    Expected,   // its type is the one the caret expects
    Field_Name, // a field a composite literal does not set yet
    Member,
    Local,
    Package,
    Import,
    Universe,
}

// One candidate. Strings are temp-allocated or borrow the checker or the snapshot.
@(private = "file")
Candidate :: struct {
    label:  string,
    kind:   string,
    detail: string,
    insert: string,
    tier:   Tier,
    order:  int, // the declaration order of a member; 0 for the others
}

@(private = "file")
Completer :: struct {
    ctx:      ^Request_Context,
    c:        ^odinsema.Checker, // nil when the checker cannot start
    prefix:   string,
    expected: odinsema.Type_Id,
    items:    [dynamic]Candidate,
    seen:     map[string]struct{},
    typed:    int, // the declarations typed for the expected type
    arrow:    bool, // the members of `x->`: procedures only, the receiver is implicit
}

// Fills res.completions with the candidates for the word that ends at req.offset.
@(private)
completion :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    cm := Completer {
        ctx      = &ctx,
        expected = odinsema.INVALID_TYPE,
        items    = make([dynamic]Candidate, context.temp_allocator),
        seen     = make(map[string]struct{}, context.temp_allocator),
    }
    collect(&cm)
    if len(cm.items) == 0 || lang.request_cancelled(req) {
        return
    }
    slice.sort_by(cm.items[:], proc(a, b: Candidate) -> bool {
        if a.tier != b.tier {
            return a.tier < b.tier
        }
        if a.order != b.order {
            return a.order < b.order
        }
        return a.label < b.label
    })
    emit(&cm, res)
}

// Clones the candidates into res.completions in the order the editor lists them.
@(private = "file")
emit :: proc(cm: ^Completer, res: ^lang.Result) {
    out, merr := make([dynamic]lang.Completion_Item, 0, len(cm.items))
    if merr != nil {
        return
    }
    res.completions = out
    for cand, i in cm.items {
        item := lang.Completion_Item{start = -1, end = -1, preselect = i == 0 && cand.tier == .Expected}
        ok := [5]bool{}
        item.label, ok[0] = clone_ok(cand.label)
        item.kind, ok[1] = clone_ok(cand.kind)
        item.detail, ok[2] = clone_ok(cand.detail)
        item.insert, ok[3] = clone_ok(cand.insert)
        item.sort, ok[4] = clone_ok(fmt.tprintf("%05d", i))
        if slice.contains(ok[:], false) {
            completion_item_free(item)
            break
        }
        if _, aerr := append(&res.completions, item); aerr != nil {
            completion_item_free(item)
            break
        }
    }
    res.ok = len(res.completions) > 0
}

// A clone in context.allocator, and false when it fails.
@(private = "file")
clone_ok :: proc(s: string) -> (string, bool) {
    if s == "" {
        return "", true
    }
    out, err := strings.clone(s)
    return out, err == nil
}

@(private = "file")
completion_item_free :: proc(item: lang.Completion_Item) {
    delete(item.label)
    delete(item.kind)
    delete(item.detail)
    delete(item.insert)
    delete(item.sort)
}

// Collects the candidates for the context of the caret.
@(private = "file")
collect :: proc(cm: ^Completer) {
    src := cm.ctx.req.source
    off := clamp(cm.ctx.req.offset, 0, len(src))
    if in_literal(cm.ctx, off) {
        return
    }
    start := off
    for start > 0 && is_word_byte(src[start - 1]) {
        start -= 1
    }
    if start < off && src[start] >= '0' && src[start] <= '9' {
        return
    }
    cm.prefix = src[start:off]
    cm.c = request_checker(cm.ctx)
    if start >= 2 && src[start - 1] == '(' && src[start - 2] == '.' {
        assertion_completions(cm, start - 1)
        return
    }
    if start >= 2 && src[start - 1] == '>' && src[start - 2] == '-' {
        cm.arrow = true
        dot_completions(cm, start - 2)
        return
    }
    if start > 0 && src[start - 1] == '.' && (start < 2 || src[start - 2] != '.') {
        dot_completions(cm, start - 1)
        return
    }
    bare_completions(cm, start)
}

@(private = "file")
is_word_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b >= 0x80
}

// True when the caret at `off` is inside a comment, a string, a rune or, with `numbers`, a number literal.
@(private)
in_literal :: proc(ctx: ^Request_Context, off: int, numbers := true) -> bool {
    if off == 0 || ctx.parsed.tree == nil || ctx.parsed.tree.root == nil {
        return false
    }
    tok, ok := odinsyntax.node_token_at(odinsyntax.node_root(ctx.parsed.tree), u32(off - 1), context.temp_allocator)
    if !ok {
        return false
    }
    _, end := odinsyntax.token_range(tok)
    text := odinsyntax.syntax_token_text(tok)
    #partial switch tok.green.kind {
    case .Line_Comment, .File_Tag:
        return true
    case .Integer, .Float, .Imag:
        return numbers
    case .Block_Comment:
        return off < int(end) || len(text) < 4 || !strings.has_suffix(text, "*/")
    case .String, .Rune:
        return off < int(end) || len(text) < 2 || text[len(text) - 1] != text[0]
    }
    return false
}

// Adds a candidate that starts with the prefix and has a name not added yet.
@(private = "file")
add :: proc(cm: ^Completer, label, kind, detail: string, tier: Tier, order := 0, type := odinsema.INVALID_TYPE, insert := "") {
    if label == "" || label == "_" || !strings.has_prefix(label, cm.prefix) || label in cm.seen {
        return
    }
    cm.seen[label] = {}
    t := tier
    if type != odinsema.INVALID_TYPE && type == cm.expected {
        t = .Expected
    }
    append(&cm.items, Candidate{label = label, kind = kind, detail = detail, insert = insert, tier = t, order = order})
}

// The type a candidate shows; "" when it is not known.
@(private = "file")
type_detail :: proc(cm: ^Completer, type: odinsema.Type_Id) -> string {
    if cm.c == nil || type == odinsema.INVALID_TYPE {
        return ""
    }
    return odinsema.type_string(&cm.c.table, type, context.temp_allocator)
}

// The source text of the type expression at `offset` of the buffer; "" when there is none.
@(private = "file")
type_text :: proc(cm: ^Completer, offset: int) -> string {
    if cm.c == nil || offset < 0 {
        return ""
    }
    n, ok := odinsema.node_at(cm.c, cm.ctx.live.id, offset)
    if !ok {
        return ""
    }
    return strings.trim_space(odinsyntax.node_text(n))
}

// The candidates after the `.` at `dot`: the members of the operand, or of the enum an implicit selector expects.
@(private = "file")
dot_completions :: proc(cm: ^Completer, dot: int) {
    c := cm.c
    if c == nil {
        return
    }
    file := cm.ctx.live.id
    n, ok := odinsema.expr_under(c, file, dot)
    if !ok {
        return
    }
    #partial switch n.green.kind {
    case .Selector_Expr:
        sel, _ := odinsyntax.as_selector_expr(n)
        operand, has_operand := odinsyntax.selector_expr_operand(&sel)
        if !has_operand {
            return
        }
        op := odinsema.expr_type(c, file, operand)
        if op.mode == .Package {
            if !cm.arrow {
                add_package_names(cm, op.dir, false, .Member)
            }
            return
        }
        add_members(cm, odinsema.operand_members(c, op, context.temp_allocator))
    case .Implicit_Selector:
        if !cm.arrow {
            add_enum_choices(cm, odinsema.expected_type_at(c, file, dot), 0)
        }
    }
}

// The variants of the union a type assertion `x.(` at `paren` tests.
@(private = "file")
assertion_completions :: proc(cm: ^Completer, paren: int) {
    c := cm.c
    if c == nil {
        return
    }
    file := cm.ctx.live.id
    n, ok := odinsema.expr_under(c, file, paren)
    if !ok || n.green.kind != .Type_Assertion {
        return
    }
    ta, _ := odinsyntax.as_type_assertion(n)
    operand, has_operand := odinsyntax.type_assertion_operand(&ta)
    if !has_operand {
        return
    }
    op := odinsema.expr_type(c, file, operand)
    if op.mode != .Value && op.mode != .Const {
        return
    }
    u, is_union := odinsema.type_get(&c.table, odinsema.type_base(&c.table, op.type)).(odinsema.Union_Type)
    if !is_union {
        return
    }
    detail := type_detail(cm, op.type)
    for variant, i in u.variants {
        add(cm, type_detail(cm, variant), "type", detail, .Member, order = i)
    }
}

// Adds members that `x.` gives, in declaration order. After `x->` only the procedures.
@(private = "file")
add_members :: proc(cm: ^Completer, members: []odinsema.Member) {
    for m, i in members {
        kind := "field"
        detail := type_detail(cm, m.type)
        _, is_proc := proc_type_of(cm, m.type)
        if cm.arrow && !is_proc {
            continue
        }
        switch m.kind {
        case .Field:
        case .Enum_Member:
            kind = "enum_member"
        case .Proc:
            kind = "function"
        case .Package_Member:
            kind = "var"
            if m.has_symbol {
                if item := odinsema.checker_item(cm.c, m.symbol); item != nil {
                    kind = item_kind_name(item.kind)
                    detail = item.signature
                }
            }
        }
        add(cm, m.name, kind, detail, .Member, order = i)
    }
}

// Adds the members of the enum `t`, of the enum of a bit_set, or of the enum variants of a union.
@(private = "file")
add_enum_choices :: proc(cm: ^Completer, t: odinsema.Type_Id, depth: int) {
    c := cm.c
    if t == odinsema.INVALID_TYPE || depth > 4 {
        return
    }
    #partial switch v in odinsema.type_get(&c.table, odinsema.type_base(&c.table, t)) {
    case odinsema.Bit_Set_Type:
        add_enum_choices(cm, v.elem, depth + 1)
        return
    case odinsema.Pointer_Type:
        add_enum_choices(cm, v.elem, depth + 1)
        return
    case odinsema.Union_Type:
        for variant in v.variants {
            add_enum_choices(cm, variant, depth + 1)
        }
        return
    }
    add_members(cm, odinsema.enum_members(c, t, context.temp_allocator))
}

// The candidates for a bare identifier that starts at `start`.
@(private = "file")
bare_completions :: proc(cm: ^Completer, start: int) {
    ctx := cm.ctx
    if cm.c != nil && cm.prefix != "" {
        cm.expected = odinsema.expected_type_at(cm.c, ctx.live.id, start)
    }
    add_field_names(cm, start)
    add_locals(cm, start)
    if lang.request_cancelled(ctx.req) {
        return
    }
    if ctx.live.path != "" {
        add_package_names(cm, live_dir(ctx), true, .Package)
    }
    if !ctx.live.in_build {
        for &item, i in ctx.live.tree.items {
            if item.kind != .Import && item.kind != .Foreign_Import {
                add_item(cm, &item, odinsema.Symbol{ctx.live.id, i32(i), -1}, .Package)
            }
        }
    }
    for item in ctx.live.tree.items {
        if item.kind == .Import {
            add(cm, item.name, "namespace", item.signature, .Import)
        }
    }
    for kw in ODIN_KEYWORDS {
        add(cm, kw, "keyword", "", .Universe)
    }
    universe: [2]odinsema.Universe_Package
    n := universe_packages(ctx, universe[:], context.temp_allocator)
    for u in universe[:n] {
        add_package_names(cm, u.dir, false, .Universe, builtin_only = !u.all)
    }
}

// Adds the names a package at `dir` declares that the buffer can name: from its own package
// (`own`) all but the file-private ones of other files, else the public ones.
@(private = "file")
add_package_names :: proc(cm: ^Completer, dir: string, own: bool, tier: Tier, builtin_only := false) {
    view := request_package(cm.ctx, dir)
    if view == nil || view.scope == nil {
        return
    }
    live := cm.ctx.live.id
    for name, refs in view.scope.names {
        if !strings.has_prefix(name, cm.prefix) || name in cm.seen {
            continue
        }
        best: ^odinsema.Item
        sym: odinsema.Symbol
        for ref in refs {
            item := odinsema.package_item(view.sema_files, ref)
            id := view.files[ref.file]
            if !odinsema.package_ref_active(view.scope, ref) {
                continue
            }
            if own ? item.visibility == .File && id != live : item.visibility != .Public {
                continue
            }
            if builtin_only && !has_builtin_attribute(item) {
                continue
            }
            if best == nil || id == live {
                best, sym = item, odinsema.Symbol{id, i32(ref.item), -1}
            }
        }
        if best != nil {
            add_item(cm, best, sym, tier)
        }
    }
}

// The procedure type `t` is, through named and distinct types.
@(private = "file")
proc_type_of :: proc(cm: ^Completer, t: odinsema.Type_Id) -> (odinsema.Proc_Type, bool) {
    if cm.c == nil || t == odinsema.INVALID_TYPE {
        return {}, false
    }
    p, ok := odinsema.type_get(&cm.c.table, odinsema.type_base(&cm.c.table, t)).(odinsema.Proc_Type)
    return p, ok
}

// Adds a package-level declaration. A variable or constant is typed while the expected type is known.
@(private = "file")
add_item :: proc(cm: ^Completer, item: ^odinsema.Item, sym: odinsema.Symbol, tier: Tier) {
    if !strings.has_prefix(item.name, cm.prefix) || item.name in cm.seen {
        return
    }
    type := odinsema.INVALID_TYPE
    if cm.c != nil && cm.expected != odinsema.INVALID_TYPE && (item.kind == .Var || item.kind == .Const) && cm.typed < EXPECTED_TYPED_MAX {
        cm.typed += 1
        type = odinsema.decl_type(cm.c, sym)
    }
    add(cm, item.name, item_kind_name(item.kind), item.signature, tier, type = type)
}

// The kind name the editor colors a declaration by.
@(private = "file")
item_kind_name :: proc(kind: odinsema.Item_Kind) -> string {
    switch kind {
    case .Proc, .Proc_Group:
        return "function"
    case .Struct, .Union, .Bit_Set, .Bit_Field, .Type:
        return "type"
    case .Enum:
        return "enum"
    case .Const:
        return "constant"
    case .Var:
        return "var"
    case .Import, .Foreign_Import:
        return "namespace"
    case .Field:
        return "field"
    case .Enum_Member:
        return "enum_member"
    }
    return ""
}

// The kind name of a local declaration; "" for one completion does not offer.
@(private = "file")
local_kind_name :: proc(kind: odinsema.Decl_Kind) -> string {
    switch kind {
    case .Var, .Param, .Result, .Loop_Var, .Switch_Var:
        return "var"
    case .Const:
        return "constant"
    case .Proc:
        return "function"
    case .Type, .Poly:
        return "type"
    case .Import:
        return "namespace"
    case .Label:
    }
    return ""
}

@(private = "file")
hoisted_kind :: proc(kind: odinsema.Decl_Kind) -> bool {
    #partial switch kind {
    case .Const, .Type, .Proc, .Poly:
        return true
    }
    return false
}

// Adds the locals in reach at `start`, innermost first, and the fields a `using` brings into scope.
@(private = "file")
add_locals :: proc(cm: ^Completer, start: int) {
    ctx := cm.ctx
    m, merr := odinsema.scope_map_range(ctx.parsed, start, start, context.temp_allocator)
    if merr != nil {
        return
    }
    defer odinsema.scope_map_destroy(m, context.temp_allocator)
    inner := -1
    for s, i in m.scopes {
        if s.start <= start && start < s.end && (inner < 0 || s.start >= m.scopes[inner].start) {
            inner = i
        }
    }
    if inner < 0 {
        return
    }
    file := ctx.live.id
    depth := m.scopes[inner].proc_depth
    for s := inner; s >= 0; s = m.scopes[s].parent {
        for l in m.locals {
            if l.scope != s || l.name_offset == start {
                continue
            }
            kind := local_kind_name(l.kind)
            if kind == "" {
                continue
            }
            if !hoisted_kind(l.kind) && (l.name_offset > start || m.scopes[s].proc_depth < depth) {
                continue
            }
            if !l.is_using && (!strings.has_prefix(l.name, cm.prefix) || l.name in cm.seen) {
                continue
            }
            type := odinsema.INVALID_TYPE
            if cm.c != nil && (l.is_using || (cm.expected != odinsema.INVALID_TYPE && cm.typed < EXPECTED_TYPED_MAX)) {
                cm.typed += 1
                type = odinsema.decl_type(cm.c, odinsema.local_symbol(file, l.name_offset))
            }
            detail := type_detail(cm, type)
            if detail == "" {
                detail = type_text(cm, l.type_offset)
            }
            name := strings.clone(l.name, context.temp_allocator)
            add(cm, name, kind, detail, .Local, type = type)
            if l.is_using && cm.c != nil {
                add_using_fields(cm, odinsema.type_members(cm.c, type, context.temp_allocator))
            }
        }
        for u in m.usings {
            if u.scope == s && u.start < start && cm.c != nil {
                add_using_operand(cm, u.start)
            }
        }
    }
}

// Adds the fields `using` at `offset` brings into scope, or the names of a package it opens.
@(private = "file")
add_using_operand :: proc(cm: ^Completer, offset: int) {
    n, ok := odinsema.node_at(cm.c, cm.ctx.live.id, offset)
    if !ok {
        return
    }
    op := odinsema.expr_type(cm.c, cm.ctx.live.id, n)
    #partial switch op.mode {
    case .Package:
        add_package_names(cm, op.dir, false, .Local)
    case .Value, .Const:
        add_using_fields(cm, odinsema.type_members(cm.c, op.type, context.temp_allocator))
    }
}

@(private = "file")
add_using_fields :: proc(cm: ^Completer, members: []odinsema.Member) {
    for m in members {
        add(cm, m.name, "field", type_detail(cm, m.type), .Local, type = m.type)
    }
}

// Adds the fields of the struct literal the word at `start` is an element of that it does not set yet.
@(private = "file")
add_field_names :: proc(cm: ^Completer, start: int) {
    c := cm.c
    ctx := cm.ctx
    src := ctx.req.source
    if c == nil || ctx.parsed.tree == nil || ctx.parsed.tree.root == nil {
        return
    }
    b := start - 1
    for b >= 0 && (src[b] == ' ' || src[b] == '\t' || src[b] == '\r' || src[b] == '\n') {
        b -= 1
    }
    if b < 0 || (src[b] != '{' && src[b] != ',') {
        return
    }
    tok, ok := odinsyntax.node_token_at(odinsyntax.node_root(ctx.parsed.tree), u32(b), context.temp_allocator)
    if !ok || tok.parent == nil || tok.parent.green.kind != .Comp_Lit {
        return
    }
    lit_node := tok.parent^
    lit, _ := odinsyntax.as_comp_lit(lit_node)
    file := ctx.live.id
    type := odinsema.INVALID_TYPE
    if _, typed := odinsyntax.comp_lit_type(&lit); typed {
        type = odinsema.expr_type(c, file, lit_node).type
    } else {
        type = odinsema.expected_type_at(c, file, int(lit_node.offset))
    }
    #partial switch _ in odinsema.type_get(&c.table, odinsema.type_base(&c.table, type)) {
    case odinsema.Struct_Type, odinsema.Bit_Field_Type:
    case:
        return
    }
    set := make(map[string]struct{}, context.temp_allocator)
    it := odinsyntax.comp_lit_elems(&lit)
    for elem in odinsyntax.child_iter_next(&it) {
        fv, is_fv := odinsyntax.as_field_value(elem)
        if !is_fv {
            continue
        }
        if name, has_name := odinsyntax.field_value_name(&fv); has_name && name.green.kind == .Ident {
            set[odinsyntax.node_text(name)] = {}
        }
    }
    for m, i in odinsema.type_members(c, type, context.temp_allocator) {
        if m.kind != .Field || m.depth > 0 || m.name in set {
            continue
        }
        insert := strings.concatenate({m.name, " = "}, context.temp_allocator)
        add(cm, m.name, "field", type_detail(cm, m.type), .Field_Name, order = i, insert = insert)
    }
}
