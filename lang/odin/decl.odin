// Locating the declaration a Type_Ref names — same file, an imported package or
// the workspace index — following `X :: Y` aliases and `using` embedding, and
// visiting it to extract a field, an enum member, or all of them.
package odin

import "core:os"
import "core:strings"
import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// Called with a located type declaration node (a `struct_declaration` or
// `enum_declaration`) and the source/path it lives in, to extract whatever a
// member operation needs (a field, an enum member, or every one of them).
@(private)
Decl_Visitor :: #type proc(decl: ts.Node, source, path: string, ctx: rawptr)

// What one lookup turned up: nothing, the declaration itself (already visited), or
// an `X :: Y` alias naming the type to look for instead.
@(private)
Decl_Hit :: enum {
    Missed,
    Visited,
    Alias,
}

// How many `X :: Y` hops are followed before giving up, so a cycle (`A :: B`,
// `B :: A`) can't loop.
@(private)
ALIAS_DEPTH_LIMIT :: 8

// Locates the type declaration named `tr` (of node type `decl_type`, e.g.
// "struct_declaration") and runs `visit` on it, returning whether one was found.
// A name that resolves to an alias (`Vec :: Point`, `Handle :: distinct Point`)
// is followed to what it stands for and looked up again from the top, since the
// underlying declaration can live in another file or package than the alias.
@(private)
visit_type_decl :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    tr: Type_Ref,
    decl_type, index_kind: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> bool {
    tr := tr
    for _ in 0 ..< ALIAS_DEPTH_LIMIT {
        next, hit := find_type_decl(e, parser, root, req, tr, decl_type, index_kind, visit, ctx)
        if hit != .Alias {
            return hit == .Visited
        }
        tr = next
    }
    return false
}

// One pass of visit_type_decl's lookup. Resolution order mirrors goto: the request
// file first (a declaration in the same package file wins), then — for a
// package-qualified type — the imported package's directory, otherwise the
// workspace index (a file whose top-level decls of kind `index_kind` declare the
// name). The first file that declares the name is terminal, whether it declares
// the type or an alias to it.
@(private)
find_type_decl :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    tr: Type_Ref,
    decl_type, index_kind: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> (Type_Ref, Decl_Hit) {
    // A container is not the type it holds: `xs: []Point` must be indexed or
    // ranged over before Point's fields are in reach, so every member operation
    // (field goto, hover, field/enum completion) stops here. A proc type names no
    // declaration at all — only calling it yields one.
    if !type_is_bare(tr) || tr.name == "" {
        return {}, .Missed
    }
    if alias, hit := probe_decl(root, req.source, req.path, tr.name, decl_type, visit, ctx); hit != .Missed {
        return alias, hit
    }
    if tr.pkg != "" {
        if raw, found := import_path(root, req.source, tr.pkg); found {
            if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                if alias, hit := visit_decl_in_dir(e, parser, dir, tr.name, req.path, decl_type, visit, ctx);
                   hit != .Missed {
                    return alias, hit
                }
            }
        }
        // The qualifier belongs to the file the type was *written* in (a callee's
        // `-> other.Point`, a cross-file struct's `using base: other.Base`), which
        // the requesting file need not import — or need not import under the same
        // alias. Resolve it against that file's own imports.
        if tr.origin != "" && tr.origin != req.path {
            return visit_qualified_in_origin(e, parser, req, tr, decl_type, visit, ctx)
        }
        return {}, .Missed
    }
    if req.workspace != "" {
        path, ok := "", false
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        // The requesting file's own package first, the whole workspace only when
        // it declares nothing of the name — an unqualified type names a type in
        // this package, never one in another (see index_package_dir).
        p, found := index_type_path(e, tr.name, req.path, index_kind, index_package_dir(e, req.path))
        if !found {
            p, found = index_type_path(e, tr.name, req.path, index_kind, "")
        }
        if found {
            path = strings.clone(p, context.temp_allocator)
            ok = true
        }
        sync.unlock(&e.index.mutex)
        if ok {
            return visit_decl_in_file(e, parser, path, tr.name, decl_type, visit, ctx)
        }
    }
    return {}, .Missed
}

// The indexed file declaring `name` as a type of `index_kind`, or — since an
// alias is a constant rather than a type declaration, so a name that only stands
// for a type is indexed under "constant" — as one of those. Confined to `dir`
// when one is given. Caller holds the mutex.
@(private = "file")
index_type_path :: proc(e: ^Engine, name, skip, index_kind, dir: string) -> (string, bool) {
    if p, ok := index_first_path(e, name, skip, index_kind, dir); ok {
        return p, true
    }
    return index_first_path(e, name, skip, "constant", dir)
}

// One parsed file's answer for `name`: the declaration itself (visited here), the
// type an alias stands for, or nothing.
@(private)
probe_decl :: proc(
    root: ts.Node,
    source, path, name, decl_type: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> (Type_Ref, Decl_Hit) {
    if decl, ok := locate_decl(root, source, name, decl_type); ok {
        visit(decl, source, path, ctx)
        return {}, .Visited
    }
    if alias, ok := locate_alias(root, source, name, path); ok {
        return alias, .Alias
    }
    return {}, .Missed
}

// The type an `X :: Y` alias stands for: a plain rename (`Vec :: Point`), a
// package-qualified one (`Vec :: other.Point`), or a `distinct` type, which is a
// separate type to the compiler but carries the same members. The target is cloned
// with `path` as its origin, so a qualifier written here resolves against this
// file's imports rather than the requesting file's. A constant that is not a type
// name (`MAX :: 100`) is not an alias, and neither is one of several names sharing
// a declaration (`A, B :: 1, 2`).
@(private)
locate_alias :: proc(root: ts.Node, source, name, path: string) -> (Type_Ref, bool) {
    decl, ok := locate_decl(root, source, name, "const_declaration")
    if !ok {
        return {}, false
    }
    base := decl_body_start(decl)
    if ts.node_named_child_count(decl) - base != 2 {
        return {}, false
    }
    value := ts.node_named_child(decl, base + 1)
    if string(ts.node_type(value)) == "distinct_type" {
        value = ts.node_named_child(value, 0)
    }
    if ts.node_is_null(value) {
        return {}, false
    }
    // A type name reads as a type after `distinct` and as an expression otherwise,
    // and the grammar spells `other.P` differently in the two positions.
    tr, tok := type_ref_from_node(value, source)
    if !tok {
        tr, tok = expr_type_name(value, source)
    }
    if !tok || (tr.name == name && tr.pkg == "") {
        return {}, false
    }
    return clone_type_ref(tr, path), true
}

// visit_type_decl for a package-qualified type whose qualifier is spelled in
// another file: re-parse that file, resolve `pkg` through *its* imports, and visit
// the declaration in the package that names. One extra parse, paid only when the
// requesting file's own imports came up empty.
@(private)
visit_qualified_in_origin :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    tr: Type_Ref,
    decl_type: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> (Type_Ref, Decl_Hit) {
    source, sok := source_read(tr.origin)
    if !sok {
        return {}, .Missed
    }

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return {}, .Missed
    }
    defer ts.tree_delete(tree)

    raw, found := import_path(ts.tree_root_node(tree), source, tr.pkg)
    if !found {
        return {}, .Missed
    }
    dir, dok := package_dir(e, raw, tr.origin, req.workspace)
    if !dok {
        return {}, .Missed
    }
    return visit_decl_in_dir(e, parser, dir, tr.name, req.path, decl_type, visit, ctx)
}

// visit_type_decl over one package directory's files (non-recursive — a package is
// a flat dir), skipping the requesting file whose live buffer was searched already.
@(private)
visit_decl_in_dir :: proc(
    e: ^Engine,
    parser: ts.Parser,
    dir, name, skip, decl_type: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> (Type_Ref, Decl_Hit) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return {}, .Missed
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return {}, .Missed
    }

    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == skip {
            continue
        }
        if alias, hit := visit_decl_in_file(e, parser, info.fullpath, name, decl_type, visit, ctx); hit != .Missed {
            return alias, hit
        }
    }
    return {}, .Missed
}

// visit_type_decl over one file: parse it (source is temp-allocated, job-lifetime,
// so anything the visitor keeps must clone or copy out before the tree is deleted).
@(private)
visit_decl_in_file :: proc(
    e: ^Engine,
    parser: ts.Parser,
    path, name, decl_type: string,
    visit: Decl_Visitor,
    ctx: rawptr,
) -> (Type_Ref, Decl_Hit) {
    source, sok := source_read(path)
    if !sok {
        return {}, .Missed
    }

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return {}, .Missed
    }
    defer ts.tree_delete(tree)

    // Whatever probe_decl reports slices `source` or is cloned into the temp
    // allocator, both of which outlive this tree.
    return probe_decl(ts.tree_root_node(tree), source, path, name, decl_type, visit, ctx)
}

// The top-level declaration of node type `decl_type` named `name`, if any. A type
// declaration's first named child is its identifier.
@(private)
locate_decl :: proc(root: ts.Node, source, name, decl_type: string) -> (ts.Node, bool) {
    for i in 0 ..< ts.node_named_child_count(root) {
        c := ts.node_named_child(root, i)
        if string(ts.node_type(c)) != decl_type {
            continue
        }
        if id := ts.node_named_child(c, decl_body_start(c)); is_identifier(id) && ts.node_text(id, source) == name {
            return c, true
        }
    }
    return {}, false
}

// The name a declaration declares — its identifier child, past any attributes.
// Empty when the node does not lead with one. Slices `source`.
@(private)
decl_name :: proc(decl: ts.Node, source: string) -> string {
    id := ts.node_named_child(decl, decl_body_start(decl))
    if !is_identifier(id) {
        return ""
    }
    return ts.node_text(id, source)
}

// Index of a declaration's first named child past its attributes: `@(private)`
// hangs an `attributes` node ahead of the name, shifting everything after it.
@(private)
decl_body_start :: proc(decl: ts.Node) -> u32 {
    first := ts.node_named_child(decl, 0)
    if !ts.node_is_null(first) && string(ts.node_type(first)) == "attributes" {
        return 1
    }
    return 0
}

// What a Decl_Visitor needs to resolve a *further* type declaration from inside
// the one it is visiting — an embedded `using` field's struct. `depth` caps the
// recursion, since two structs can embed each other.
@(private)
Embed_Env :: struct {
    e:      ^Engine,
    parser: ts.Parser,
    root:   ts.Node,
    req:    ^lang.Request,
    depth:  int,
}

// How deep `using` embedding is followed.
@(private)
EMBED_DEPTH_LIMIT :: 4

// Outputs of member_visitor: the located field's identifier and full-declaration
// byte ranges (into `src`), the field's own type (temp-cloned, for chaining), and
// whether the field was found. `src`/`path` are job-lifetime.
@(private)
Member_Ctx :: struct {
    field:       string,
    env:         Embed_Env,
    got:         bool,
    src:         string,
    path:        string,
    owner:       string, // the struct that declares the field — the one embedding lands on
    ident_start: int,
    ident_end:   int,
    decl_start:  int,
    decl_end:    int,
    field_type:  Type_Ref,
}

// Decl_Visitor that finds one named field. Records its identifier range (the
// jump target), its whole-declaration range (`x: int`, for hover) and its type
// (for a chained `a.b.c`). The type is cloned into scratch so it survives the
// parse tree's deletion in the cross-file case. A field the struct does not
// declare itself may still come from a struct it embeds with `using`.
@(private)
member_visitor :: proc(sd: ts.Node, source, path: string, ctx_raw: rawptr) {
    ctx := cast(^Member_Ctx) ctx_raw
    id, tn, fd, ok := struct_field(sd, source, ctx.field)
    if !ok {
        visit_embedded(sd, source, path, &ctx.env, member_visitor, ctx)
        return
    }
    ctx.got = true
    ctx.src = source
    ctx.path = path
    ctx.owner = decl_name(sd, source)
    ctx.ident_start = int(ts.node_start_byte(id))
    ctx.ident_end = int(ts.node_end_byte(id))
    ctx.decl_start = int(ts.node_start_byte(fd))
    ctx.decl_end = int(ts.node_end_byte(fd))
    if tr, tok := type_ref_from_node(tn, source); tok {
        ctx.field_type = clone_type_ref(tr, path)
    }
}

// Runs `visit` on every struct this one embeds with `using`, so an embedded
// struct's fields answer as if they were the outer struct's own. The embedded
// type is resolved the usual way (same file → imported package → workspace
// index), qualified against the file the embedding was written in.
@(private)
visit_embedded :: proc(
    sd: ts.Node,
    source, path: string,
    env: ^Embed_Env,
    visit: Decl_Visitor,
    ctx: rawptr,
) {
    if env.e == nil || env.depth >= EMBED_DEPTH_LIMIT {
        return
    }
    for i in 0 ..< ts.node_named_child_count(sd) {
        c := ts.node_named_child(sd, i)
        if string(ts.node_type(c)) != "field" || !field_is_using(c) {
            continue
        }
        count := ts.node_named_child_count(c)
        if count == 0 {
            continue
        }
        tn := ts.node_named_child(c, count - 1)
        if string(ts.node_type(tn)) != "type" {
            continue
        }
        tr, ok := type_ref_from_node(tn, source)
        if !ok {
            continue
        }
        tr = clone_type_ref(tr, path)
        env.depth += 1
        visit_type_decl(env.e, env.parser, env.root, env.req, tr, "struct_declaration", "type", visit, ctx)
        env.depth -= 1
    }
}

// Whether a struct field is embedded (`using base: Base`). The grammar keeps
// `using` as an anonymous token on the field.
@(private)
field_is_using :: proc(field: ts.Node) -> bool {
    for i in 0 ..< ts.node_child_count(field) {
        if string(ts.node_type(ts.node_child(field, i))) == "using" {
            return true
        }
    }
    return false
}

// A Type_Ref copied into scratch, tagged with the file it was read from, so it
// outlives the parse tree it came from and keeps its qualifier resolvable.
@(private)
clone_type_ref :: proc(tr: Type_Ref, path: string) -> Type_Ref {
    out := tr
    out.name = strings.clone(tr.name, context.temp_allocator)
    out.pkg = strings.clone(tr.pkg, context.temp_allocator)
    out.proc_sig = strings.clone(tr.proc_sig, context.temp_allocator)
    out.origin = strings.clone(path, context.temp_allocator)
    for i in 0 ..< out.depth {
        out.containers[i].key = strings.clone(tr.containers[i].key, context.temp_allocator)
        out.containers[i].key_pkg = strings.clone(tr.containers[i].key_pkg, context.temp_allocator)
    }
    return out
}

// The `field`-named member of a struct: its identifier node, its `(type ...)`
// node, and the whole `field` node. A single `field` can declare several names
// (`x, y: int`), so every identifier before the trailing type is checked.
@(private)
struct_field :: proc(sd: ts.Node, source, field: string) -> (ident, type_node, field_node: ts.Node, ok: bool) {
    for i in 0 ..< ts.node_named_child_count(sd) {
        c := ts.node_named_child(sd, i)
        if string(ts.node_type(c)) != "field" {
            continue
        }
        count := ts.node_named_child_count(c)
        if count < 2 {
            continue
        }
        tn := ts.node_named_child(c, count - 1)
        if string(ts.node_type(tn)) != "type" {
            continue
        }
        for j in 0 ..< count - 1 {
            id := ts.node_named_child(c, j)
            if is_identifier(id) && ts.node_text(id, source) == field {
                return id, tn, c, true
            }
        }
    }
    return {}, {}, {}, false
}

// Outputs of fields_visitor: the completion lang.Result to append to, the typed
// prefix filter and the de-dup set.
@(private)
Fields_Ctx :: struct {
    prefix: string,
    env:    Embed_Env,
    res:    ^lang.Result,
    seen:   ^map[string]bool,
}

// Decl_Visitor that offers every field matching the prefix as a completion
// candidate (`name: type`, kind "field"), including the fields of every struct
// this one embeds with `using`. Owned strings clone into the Manager's allocator
// (context.allocator here).
@(private)
fields_visitor :: proc(sd: ts.Node, source, path: string, ctx_raw: rawptr) {
    ctx := cast(^Fields_Ctx) ctx_raw
    defer visit_embedded(sd, source, path, &ctx.env, fields_visitor, ctx)
    for i in 0 ..< ts.node_named_child_count(sd) {
        c := ts.node_named_child(sd, i)
        if string(ts.node_type(c)) != "field" {
            continue
        }
        count := ts.node_named_child_count(c)
        if count < 2 {
            continue
        }
        for j in 0 ..< count - 1 {
            id := ts.node_named_child(c, j)
            if !is_identifier(id) {
                continue
            }
            fname := ts.node_text(id, source)
            if !completion_matches(fname, ctx.prefix) || fname in ctx.seen^ {
                continue
            }
            ctx.seen^[fname] = true
            append(&ctx.res.symbols, lang.Symbol {
                name      = strings.clone(fname),
                kind      = strings.clone("field"),
                signature = field_signature(source, c),
            })
        }
    }
}

// One field's `name: type` line, trimmed — a member-completion row's label.
// Cloned into context.allocator.
@(private)
field_signature :: proc(source: string, field_node: ts.Node) -> string {
    start := clamp(int(ts.node_start_byte(field_node)), 0, len(source))
    end := clamp(int(ts.node_end_byte(field_node)), start, len(source))
    text := source[start:end]
    if nl := strings.index_byte(text, '\n'); nl >= 0 {
        text = text[:nl]
    }
    return strings.clone(strings.trim_space(text))
}

// Outputs of enum_visitor: the completion lang.Result, the typed prefix filter and the
// de-dup set. Mirrors Fields_Ctx.
@(private)
Enum_Ctx :: struct {
    prefix: string,
    res:    ^lang.Result,
    seen:   ^map[string]bool,
}

// Decl_Visitor that offers an enum's members as implicit-selector completions
// (`a: Axis = .<here>`). The `.` is already typed, so the inserted text is the
// bare member name; kind "enum_member" colors the row. An enum's members are its
// identifier children after the first (the enum name).
@(private)
enum_visitor :: proc(ed: ts.Node, source, path: string, ctx_raw: rawptr) {
    ctx := cast(^Enum_Ctx) ctx_raw
    for i in 1 ..< ts.node_named_child_count(ed) {
        id := ts.node_named_child(ed, i)
        if !is_identifier(id) {
            continue
        }
        name := ts.node_text(id, source)
        if !completion_matches(name, ctx.prefix) || name in ctx.seen^ {
            continue
        }
        ctx.seen^[name] = true
        append(&ctx.res.symbols, lang.Symbol {
            name      = strings.clone(name),
            kind      = strings.clone("enum_member"),
            signature = strings.clone(name),
        })
    }
}

// Outputs of variants_visitor. Mirrors Enum_Ctx.
@(private)
Variants_Ctx :: struct {
    prefix: string,
    res:    ^lang.Result,
    seen:   ^map[string]bool,
}

// Decl_Visitor that offers a union's variants as type-assertion completions
// (`v.(<here>`). A variant is written out as a type, so the inserted text is its
// whole source text (`pkg.Thing`, `[]u8`) and kind is "type". A union's variants
// are its `type` children — the name identifier is not one.
@(private)
variants_visitor :: proc(ud: ts.Node, source, path: string, ctx_raw: rawptr) {
    ctx := cast(^Variants_Ctx) ctx_raw
    for i in 0 ..< ts.node_named_child_count(ud) {
        c := ts.node_named_child(ud, i)
        if string(ts.node_type(c)) != "type" {
            continue
        }
        name := ts.node_text(c, source)
        if !completion_matches(name, ctx.prefix) || name in ctx.seen^ {
            continue
        }
        ctx.seen^[name] = true
        append(&ctx.res.symbols, lang.Symbol {
            name      = strings.clone(name),
            kind      = strings.clone("type"),
            signature = strings.clone(name),
        })
    }
}
