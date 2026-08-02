// Semantic classification: what each identifier in the buffer actually *is*,
// as against what its parse shape suggests. The grammar spells a parameter, a
// local, a package and an undeclared typo all as a bare `identifier` and its
// highlights query paints a use of any of them `@variable`, because nothing in
// the tree separates them — only resolution does, and the engine already
// resolves. This request hands that knowledge to the highlighter.
//
// Deliberately sparse. A token is emitted only where the analyzer knows more
// than the grammar does, so an identifier this file says nothing about keeps
// whatever colour the highlights query gave it. The positions the grammar
// already decides — a struct field, an enum member, an attribute, a label — are
// skipped outright rather than re-derived and risk overruling a correct colour
// with a worse one.
//
// Uses go-to-definition's own resolution (`resolve_local` over `collect_defs`),
// so a name's colour and the declaration Alt+Enter jumps to can never disagree.
package odin

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// The implicit scope every Odin file compiles against, read off the toolchain
// rather than hardcoded: the builtin set moves with the compiler, and a list
// baked in here would silently rot into false "undeclared" reports the next time
// the language gains a builtin. `ok` false means the toolchain could not be read
// at all, which disables dimming rather than guessing.
@(private)
Builtin_Cache :: struct {
    names: map[string]bool, // engine-owned keys, alive for the process
    built: bool,
    ok:    bool,
    alloc: runtime.Allocator,
}

// The packages whose top-level declarations are in scope with no import. Every
// name they export is allowed, which over-permits slightly — `base:runtime` also
// exports types a program must name explicitly — but over-permitting only ever
// costs a missed dim, where under-permitting flags correct code.
@(private)
BUILTIN_PACKAGES :: [?]string{"base:builtin", "base:runtime"}

@(private)
semantic_tokens :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    defs := collect_defs(e, root, req.source)

    imports := make(map[string]bool, 0, context.temp_allocator)
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        if name, _, ok := import_name_and_path(child, req.source); ok {
            imports[name] = true
        }
    }

    // Every name that counts as declared. Left empty when dimming is off, which
    // is why the classification below can consult it unconditionally.
    declared := make(map[string]bool, 0, context.temp_allocator)
    dim := dimming_allowed(e, parser, root, req, &declared)

    ctx := Semantic_Ctx {
        req      = req,
        defs     = defs[:],
        imports  = imports,
        declared = declared,
        dim      = dim,
        res      = res,
    }
    classify_node(&ctx, root)
    res.ok = len(res.tokens) > 0
}

@(private)
Semantic_Ctx :: struct {
    req:      ^lang.Request,
    defs:     []Def,
    imports:  map[string]bool,
    declared: map[string]bool,
    dim:      bool,
    res:      ^lang.Result,
}

// Walks every identifier in the tree. Pre-order over children in source order,
// so identifiers are reached in ascending byte order and the token list comes
// out sorted with no sort — which is the ordering the seam promises the editor.
@(private)
classify_node :: proc(ctx: ^Semantic_Ctx, node: ts.Node) {
    if is_identifier(node) {
        classify_identifier(ctx, node)
        return
    }
    for i in 0 ..< ts.node_named_child_count(node) {
        classify_node(ctx, ts.node_named_child(node, i))
    }
}

@(private)
classify_identifier :: proc(ctx: ^Semantic_Ctx, node: ts.Node) {
    if semantic_skip(node) {
        return
    }
    name := ts.node_text(node, ctx.req.source)
    start := int(ts.node_start_byte(node))
    end := int(ts.node_end_byte(node))

    if name in ctx.imports {
        append(&ctx.res.tokens, lang.Semantic_Token{start, end, .Package})
        return
    }

    // The declaration this name binds to here, by the same lexical rules goto
    // follows — including the declaring identifier itself, which def_visible_at
    // admits explicitly, so `x` in `x := 1` resolves to its own declaration
    // rather than reading as undeclared.
    if d, found := resolve_local(ctx.defs, name, start); found {
        if kind, ok := token_kind_for_def(d); ok {
            append(&ctx.res.tokens, lang.Semantic_Token{start, end, kind})
        }
        return
    }

    // Nothing in this file. Everything below is the unresolved check, and it only
    // runs where the whole-file guards said the question can be answered at all.
    if !ctx.dim || is_odin_keyword(name) || name in ctx.declared {
        return
    }
    append(&ctx.res.tokens, lang.Semantic_Token{start, end, .Unresolved})
}

// Positions where the grammar has already proved what the identifier is, so
// there is nothing to add and a token here could only overrule a correct colour
// with a worse one. Two groups: declarations whose own syntax names their kind
// (a struct field, an enum member, an attribute, a label, the package clause, an
// import alias), and the right-hand side of a selector, which names a field or a
// package symbol and takes type inference to resolve — the highlights query
// tags it `@field` already.
@(private)
semantic_skip :: proc(node: ts.Node) -> bool {
    parent := ts.node_parent(node)
    if ts.node_is_null(parent) {
        return true
    }
    switch string(ts.node_type(parent)) {
    case "package_declaration",
         "import_declaration",
         "attribute",
         "tag",
         "label_statement",
         "using_statement",
         "foreign_block",
         "field",
         "struct_field",
         "polymorphic_parameters":
        return true
    case "enum_declaration":
        // The enum's own name reads like any other type declaration and stays
        // ours; everything after it is a member, which the grammar names.
        first := ts.node_named_child(parent, 0)
        return ts.node_is_null(first) || !same_node(first, node)
    case "member_expression", "field_type":
        // Only the operand is ours; `a.b.c` nests left, so each inner operand is
        // still the first child of its own selector and stays classified.
        first := ts.node_named_child(parent, 0)
        return ts.node_is_null(first) || !same_node(first, node)
    }
    return false
}

// The token kind a resolved declaration lends its uses, and whether it says
// anything the grammar has not already said. A `::` constant is deliberately
// unclassified — it can stand for a value, a type or a procedure group, and the
// highlights query decides the cases that are decidable — and a package-level
// variable is left alone because `@variable` is exactly what it is.
@(private)
token_kind_for_def :: proc(d: Def) -> (lang.Token_Kind, bool) {
    switch d.kind {
    case "parameter":
        return .Parameter, true
    case "function":
        return .Procedure, true
    case "type", "enum":
        return .Type, true
    case "field":
        return .Field, true
    case "namespace":
        return .Package, true
    case "var":
        return .Local, !d.top_level
    }
    return {}, false
}

@(private)
is_odin_keyword :: proc(name: string) -> bool {
    for kw in ODIN_KEYWORDS {
        if kw == name {
            return true
        }
    }
    return false
}

// Whether an undeclared name in this file may be dimmed, filling `declared` with
// the names that count as resolved when it may.
//
// Every branch here fails open: the question is "can this file be judged at
// all", and any doubt answers no, because a wrongly dimmed identifier reads as
// an error the compiler never reported and is worse than no colour. Three ways
// to lose the right: no workspace to check against, a `using` (the one construct
// that injects names from a scope this engine does not follow), or an import
// that cannot be located — an unknown collection may bring in anything.
@(private)
dimming_allowed :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    declared: ^map[string]bool,
) -> bool {
    if req.workspace == "" {
        return false
    }
    if has_using(root) {
        return false
    }
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        raw, rok := import_string(child, req.source)
        if !rok {
            return false
        }
        if _, dok := package_dir(e, raw, req.path, req.workspace); !dok {
            return false
        }
    }

    // The implicit scope. Borrowed, not cloned: the cache outlives the request
    // and its keys are stable for the process.
    if !builtin_names(e, parser, declared) {
        return false
    }

    sync.lock(&e.index.mutex)
    index_sync(e, parser, req)
    any_file := index_declared_names(e, declared, context.temp_allocator)
    sync.unlock(&e.index.mutex)

    // An index holding no file at all has not proved anything is absent — the
    // walk was cancelled, or the workspace is not where the engine thinks.
    return any_file
}

// True when the file contains a `using` statement anywhere. Struct embedding
// (`using base: Base`) is a field rather than a statement and does not count:
// the engine does follow that one, so it costs no precision.
@(private)
has_using :: proc(node: ts.Node) -> bool {
    if string(ts.node_type(node)) == "using_statement" {
        return true
    }
    for i in 0 ..< ts.node_named_child_count(node) {
        if has_using(ts.node_named_child(node, i)) {
            return true
        }
    }
    return false
}

// Adds the implicit scope's names to `declared`, building the cache on first
// call. False when the toolchain could not be read, which takes dimming with it.
// Keys are inserted borrowed — they belong to the engine and outlive the map.
@(private)
builtin_names :: proc(e: ^Engine, parser: ts.Parser, declared: ^map[string]bool) -> bool {
    sync.lock(&e.builtin_mutex)
    defer sync.unlock(&e.builtin_mutex)

    if !e.builtins.built {
        build_builtin_cache(e, parser)
        e.builtins.built = true
    }
    if !e.builtins.ok {
        return false
    }
    for name in e.builtins.names {
        declared[name] = true
    }
    return true
}

// Reads every top-level declaration out of the builtin packages under ODIN_ROOT.
// Runs once per process, on whichever worker asks first; the caller holds
// builtin_mutex. `ok` stays false unless a package was actually read, so a
// missing or unreadable toolchain disables dimming instead of emptying the scope.
@(private)
build_builtin_cache :: proc(e: ^Engine, parser: ts.Parser) {
    context.allocator = e.builtins.alloc
    e.builtins.names = make(map[string]bool)

    for pkg in BUILTIN_PACKAGES {
        // No requesting file and no workspace: a `base:` path resolves off
        // ODIN_ROOT alone, so neither is consulted.
        dir, dok := package_dir(e, pkg, "", "")
        if !dok {
            continue
        }
        if collect_dir_decl_names(e, parser, dir, &e.builtins.names) {
            e.builtins.ok = true
        }
    }
}

// Adds the top-level declaration names of every `.odin` file directly in `dir`
// to `out`, cloning each into `out`'s owner. Reports whether a file was read.
@(private)
collect_dir_decl_names :: proc(e: ^Engine, parser: ts.Parser, dir: string, out: ^map[string]bool) -> bool {
    handle, oerr := os.open(dir)
    if oerr != nil {
        return false
    }
    defer os.close(handle)

    infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if rerr != nil {
        return false
    }

    read_any := false
    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if strings.has_suffix(info.name, "_test.odin") {
            continue
        }
        data, derr := os.read_entire_file(info.fullpath, context.temp_allocator)
        if derr != nil {
            continue
        }
        source := string(data)
        tree := ts.parser_parse_string(parser, source)
        if tree == nil {
            continue
        }
        defer ts.tree_delete(tree)
        read_any = true

        for d in collect_defs(e, ts.tree_root_node(tree), source) {
            if !d.top_level || d.name == "" {
                continue
            }
            if d.name not_in out {
                out[strings.clone(d.name)] = true
            }
        }
    }
    return read_any
}

@(private)
builtins_clear :: proc(e: ^Engine) {
    for name in e.builtins.names {
        delete(name, e.builtins.alloc)
    }
    delete(e.builtins.names)
    e.builtins.names = {}
    e.builtins.built = false
    e.builtins.ok = false
}
