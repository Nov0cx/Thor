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
    Auto_Import, // a package the buffer does not import yet
}

// One candidate. Strings are temp-allocated or borrow the checker or the snapshot.
@(private = "file")
Candidate :: struct {
    label:       string,
    kind:        string,
    detail:      string,
    insert:      string,
    snippet:     string, // a snippet template that replaces `insert`; "" when none
    import_path: string, // the import the candidate adds to the buffer; "" when none
    tier:        Tier,
    order:       int, // the declaration order of a member; 0 for the others
}

@(private = "file")
Completer :: struct {
    ctx:       ^Request_Context,
    c:         ^odinsema.Checker, // nil when the checker cannot start
    prefix:    string,
    expected:  odinsema.Type_Id,
    items:     [dynamic]Candidate,
    seen:      map[string]struct{},
    typed:     int, // the declarations typed for the expected type
    snippets:  bool, // a procedure candidate inserts a call snippet
    arrow:     bool, // the members of `x->`: procedures only, the receiver is implicit
    importing: string, // the import every candidate added now carries; "" when none
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
        if cand.snippet != "" && ok[3] {
            delete(item.insert)
            item.insert, ok[3] = clone_ok(cand.snippet)
            item.snippet = true
        }
        if cand.import_path != "" && !slice.contains(ok[:], false) {
            ok[0] = add_import_edit(cm, &item, cand.import_path)
        }
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
    for edit in item.extra_edits {
        delete(edit.path)
        delete(edit.old_text)
        delete(edit.new_text)
    }
    delete(item.extra_edits)
}

// Gives `item` the edit that adds `import "<path>"` to the buffer: after its last import, else
// after its package clause with a blank line. False when it cannot allocate.
@(private = "file")
add_import_edit :: proc(cm: ^Completer, item: ^lang.Completion_Item, import_path: string) -> bool {
    src := cm.ctx.req.source
    at := -1
    text: string
    for imp in cm.ctx.live.tree.items {
        if imp.kind == .Import && imp.end > at {
            at = imp.end
        }
    }
    if at >= 0 {
        text = fmt.tprintf("\nimport \"%s\"", import_path)
    } else {
        at = len(src)
        if p := cm.ctx.live.tree.package_offset; p >= 0 {
            if nl := strings.index_byte(src[min(p, len(src)):], '\n'); nl >= 0 {
                at = p + nl
            }
        }
        text = fmt.tprintf("\n\nimport \"%s\"", import_path)
    }
    at = clamp(at, 0, len(src))
    path, pok := clone_ok(cm.ctx.req.path)
    new_text, tok := clone_ok(text)
    edits, merr := make([dynamic]lang.Text_Edit, 0, 1)
    if !pok || !tok || merr != nil {
        delete(path)
        delete(new_text)
        delete(edits)
        return false
    }
    append(&edits, lang.Text_Edit{path = path, start = at, end = at, new_text = new_text})
    item.extra_edits = edits
    return true
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
    end := off
    for end < len(src) && is_word_byte(src[end]) {
        end += 1
    }
    cm.snippets = (end >= len(src) || src[end] != '(') && config_snippets(cm.ctx.e, cm.ctx.req.workspace)
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
add :: proc(cm: ^Completer, label, kind, detail: string, tier: Tier, order := 0, type := odinsema.INVALID_TYPE, insert := "", snippet := "") {
    if label == "" || label == "_" || !strings.has_prefix(label, cm.prefix) || label in cm.seen {
        return
    }
    cm.seen[label] = {}
    t := tier
    if type != odinsema.INVALID_TYPE && type == cm.expected {
        t = .Expected
    }
    append(&cm.items, Candidate{label = label, kind = kind, detail = detail, insert = insert, snippet = snippet, import_path = cm.importing, tier = t, order = order})
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
        if op.mode == .Invalid && !cm.arrow && operand.green.kind == .Ident {
            unbound_alias_names(cm, odinsyntax.node_text(operand), int(operand.offset))
            return
        }
        add_members(cm, odinsema.operand_members(c, op, context.temp_allocator))
    case .Implicit_Selector:
        if !cm.arrow {
            add_enum_choices(cm, odinsema.expected_type_at(c, file, dot), 0)
        }
    }
}

// The public names of the known packages called `alias` of the best rank when nothing binds `alias`
// at `offset`, shallowest first; a name two of them declare comes from the first. Each carries the
// import that binds it.
@(private = "file")
unbound_alias_names :: proc(cm: ^Completer, alias: string, offset: int) {
    if odinsema.lookup_name(cm.c, cm.ctx.live.id, alias, offset).kind != .None {
        return
    }
    best := -1
    for p in importable_packages(cm) {
        if p.name != alias || (best >= 0 && p.rank != best) {
            continue
        }
        best = p.rank
        cm.importing = p.import_path
        add_package_names(cm, p.dir, false, .Member)
    }
    cm.importing = ""
}

// The known packages the buffer does not import yet, without its own package.
@(private = "file")
importable_packages :: proc(cm: ^Completer) -> []Known_Package {
    ctx := cm.ctx
    all := known_packages(ctx.e, ctx.req.workspace)
    imports := odinsema.db_imports(&ctx.snap, ctx.live.id)
    own := ctx.live.path != "" ? live_dir(ctx) : ""
    out := make([dynamic]Known_Package, 0, len(all), context.temp_allocator)
    next: for p in all {
        if own != "" && same_dir(p.dir, own) {
            continue
        }
        for imp in imports {
            if imp.path == p.import_path || (imp.dir != "" && same_dir(imp.dir, p.dir)) {
                continue next
            }
        }
        append(&out, p)
    }
    return out[:]
}

// Adds the packages the buffer does not import yet whose name starts with the prefix, each with
// the import it needs. The first package of a name wins: core before vendor.
@(private = "file")
add_auto_imports :: proc(cm: ^Completer) {
    if cm.prefix == "" {
        return
    }
    for p in importable_packages(cm) {
        if !strings.has_prefix(p.name, cm.prefix) || p.name in cm.seen {
            continue
        }
        cm.importing = p.import_path
        add(cm, p.name, "namespace", fmt.tprintf("import \"%s\"", p.import_path), .Auto_Import)
        cm.importing = ""
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
        p, is_proc := proc_type_of(cm, m.type)
        if cm.arrow && !is_proc {
            continue
        }
        snip := ""
        if is_proc && cm.snippets {
            snip = proc_snippet(cm, m.name, p, skip_first = cm.arrow)
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
        add(cm, m.name, kind, detail, .Member, order = i, snippet = snip)
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
    if !lang.request_cancelled(ctx.req) {
        add_auto_imports(cm)
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

// Adds a package-level declaration. A variable, constant or procedure is typed while the expected
// type is known; a procedure ranks by its one result.
@(private = "file")
add_item :: proc(cm: ^Completer, item: ^odinsema.Item, sym: odinsema.Symbol, tier: Tier) {
    if !strings.has_prefix(item.name, cm.prefix) || item.name in cm.seen {
        return
    }
    is_proc := item.kind == .Proc || item.kind == .Proc_Group
    type := odinsema.INVALID_TYPE
    if cm.c != nil && cm.expected != odinsema.INVALID_TYPE && (item.kind == .Var || item.kind == .Const || is_proc) && cm.typed < EXPECTED_TYPED_MAX {
        cm.typed += 1
        type = odinsema.decl_type(cm.c, sym)
    }
    snip := ""
    if is_proc && cm.snippets && (type == odinsema.INVALID_TYPE || type != cm.expected) {
        snip = item.kind == .Proc ? signature_snippet(item.name, item.signature) : group_snippet(item.name)
    }
    if is_proc {
        type = proc_rank_type(cm, type)
    }
    add(cm, item.name, item_kind_name(item.kind), item.signature, tier, type = type, snippet = snip)
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

// The type a procedure of type `t` ranks by: `t` when the caret expects it, else its one result.
@(private = "file")
proc_rank_type :: proc(cm: ^Completer, t: odinsema.Type_Id) -> odinsema.Type_Id {
    if t == odinsema.INVALID_TYPE || t == cm.expected {
        return t
    }
    if p, ok := proc_type_of(cm, t); ok && len(p.results) == 1 {
        return p.results[0].type
    }
    return odinsema.INVALID_TYPE
}

// Writes `s` into a snippet template with `$`, `}` and `\` escaped.
@(private = "file")
write_snippet_text :: proc(sb: ^strings.Builder, s: string) {
    for i in 0 ..< len(s) {
        if s[i] == '$' || s[i] == '}' || s[i] == '\\' {
            strings.write_byte(sb, '\\')
        }
        strings.write_byte(sb, s[i])
    }
}

// The call snippet `name(${1:a}, ${2:b})$0` for the placeholders `params`. With none it is
// `name()$0`, or `name($0)` when the procedure takes optional parameters.
@(private = "file")
call_snippet :: proc(name: string, params: []string, optional: bool) -> string {
    sb := strings.builder_make(context.temp_allocator)
    write_snippet_text(&sb, name)
    if len(params) == 0 {
        strings.write_string(&sb, optional ? "($0)" : "()$0")
        return strings.to_string(sb)
    }
    strings.write_byte(&sb, '(')
    for p, i in params {
        if i > 0 {
            strings.write_string(&sb, ", ")
        }
        fmt.sbprintf(&sb, "${{%d:", i + 1)
        write_snippet_text(&sb, p)
        strings.write_byte(&sb, '}')
    }
    strings.write_string(&sb, ")$0")
    return strings.to_string(sb)
}

// The call snippet of a procedure group, whose parameters depend on the member a call picks.
@(private = "file")
group_snippet :: proc(name: string) -> string {
    return call_snippet(name, nil, true)
}

// The call snippet for the procedure type `p`; `skip_first` drops the receiver of `x->`.
// Parameters with a default value get no stop.
@(private = "file")
proc_snippet :: proc(cm: ^Completer, name: string, p: odinsema.Proc_Type, skip_first := false) -> string {
    params := make([dynamic]string, 0, len(p.params), context.temp_allocator)
    optional := false
    for param, i in p.params {
        if skip_first && i == 0 {
            continue
        }
        if param.has_default {
            optional = true
            continue
        }
        label := strings.trim_prefix(param.name, "$")
        if label == "" {
            label = type_detail(cm, param.type)
        }
        append(&params, label)
    }
    return call_snippet(name, params[:], optional)
}

// The call snippet read from a declaration head like `add :: proc(a, b: int, c := 1) -> int`; ""
// when the head is not a procedure literal.
@(private)
signature_snippet :: proc(name, signature: string) -> string {
    sep := strings.index(signature, "::")
    if sep < 0 {
        return ""
    }
    rest := signature[sep + 2:]
    at := strings.index(rest, "proc")
    if at < 0 {
        return ""
    }
    rest = rest[at + 4:]
    open := strings.index_byte(rest, '(')
    if open < 0 {
        return ""
    }
    // Only a calling convention may stand between `proc` and its parameters.
    if between := strings.trim_space(rest[:open]); between != "" && (len(between) < 2 || between[0] != '"' || between[len(between) - 1] != '"') {
        return ""
    }
    pieces := make([dynamic]string, context.temp_allocator)
    depth := 0
    piece_start := open + 1
    close := -1
    in_string: u8 = 0
    scan: for i := open + 1; i < len(rest); i += 1 {
        ch := rest[i]
        if in_string != 0 {
            if ch == '\\' && in_string == '"' {
                i += 1
            } else if ch == in_string {
                in_string = 0
            }
            continue
        }
        switch ch {
        case '"', '`', '\'':
            in_string = ch
        case '(', '[', '{':
            depth += 1
        case ')', ']', '}':
            if depth == 0 {
                close = i
                break scan
            }
            depth -= 1
        case ',':
            if depth == 0 {
                append(&pieces, strings.trim_space(rest[piece_start:i]))
                piece_start = i + 1
            }
        }
    }
    if close < 0 {
        return ""
    }
    if last := strings.trim_space(rest[piece_start:close]); last != "" {
        append(&pieces, last)
    }
    named := false
    for piece in pieces {
        if top_level_byte(piece, ':') >= 0 {
            named = true
            break
        }
    }
    params := make([dynamic]string, 0, len(pieces), context.temp_allocator)
    optional := false
    for piece, i in pieces {
        if !named {
            append(&params, piece)
            continue
        }
        // A name without a type shares the type and the default of the next named field.
        field := piece
        colon := top_level_byte(field, ':')
        for k := i + 1; colon < 0 && k < len(pieces); k += 1 {
            field = pieces[k]
            colon = top_level_byte(field, ':')
        }
        if colon >= 0 && top_level_byte(field[colon:], '=') >= 0 {
            optional = true
            continue
        }
        head := piece
        if c := top_level_byte(piece, ':'); c >= 0 {
            head = piece[:c]
        }
        head = strings.trim_space(head)
        if space := strings.last_index_any(head, " \t"); space >= 0 {
            head = head[space + 1:]
        }
        head = strings.trim_prefix(head, "$")
        if head != "" {
            append(&params, head)
        }
    }
    return call_snippet(name, params[:], optional)
}

// The index of the first `b` in `s` outside brackets; -1 when there is none.
@(private = "file")
top_level_byte :: proc(s: string, b: u8) -> int {
    depth := 0
    for i in 0 ..< len(s) {
        switch s[i] {
        case '(', '[', '{':
            depth += 1
        case ')', ']', '}':
            depth -= 1
        case:
            if s[i] == b && depth == 0 {
                return i
            }
        }
    }
    return -1
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
            is_proc := l.kind == .Proc
            if cm.c != nil && (l.is_using || is_proc || (cm.expected != odinsema.INVALID_TYPE && cm.typed < EXPECTED_TYPED_MAX)) {
                cm.typed += 1
                type = odinsema.decl_type(cm.c, odinsema.local_symbol(file, l.name_offset))
            }
            detail := type_detail(cm, type)
            if detail == "" {
                detail = type_text(cm, l.type_offset)
            }
            name := strings.clone(l.name, context.temp_allocator)
            rank := type
            snip := ""
            if is_proc {
                rank = proc_rank_type(cm, type)
                if p, ok := proc_type_of(cm, type); ok && cm.snippets && type != cm.expected {
                    snip = proc_snippet(cm, name, p)
                }
            }
            add(cm, name, kind, detail, .Local, type = rank, snippet = snip)
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
