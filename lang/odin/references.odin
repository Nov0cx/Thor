// Find-usages: not the occurrences that share a spelling, the ones that bind to
// the same declaration. The caret's name resolves to a `Ref_Target` and every
// occurrence is judged against it — a local by goto's own lexical rules (an
// inner redeclaration is a different variable), a package symbol by the package
// declaring it (bare there, qualified elsewhere), a field by the struct
// declaring it (`a.x` and `b.x` are two fields).
//
// Exclusion needs proof, inclusion does not: rename runs this scan, and a usage
// it drops is code left broken. A `using` in reach, an operand whose type does
// not infer, a name that resolves nowhere — each falls back to the flat name
// match this used to be.
//
// The declaration is the one occurrence the two consumers disagree about: it is
// not a use of itself, but a rename that skipped it would leave it behind. The
// scan finds it either way and drops it only for `.References`.
package odin

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// What the name under the caret turned out to be, which is what decides whether
// another occurrence of it is the same thing.
@(private)
Ref_Kind :: enum {
    Any,     // resolved to nothing: every occurrence of the name, as before
    Local,   // a local or a parameter: one declaration, in one file
    Package, // a top-level declaration: bare in its package, qualified outside it
    Field,   // a struct field: member position on a value of that struct
}

@(private)
Ref_Target :: struct {
    name:       string,
    kind:       Ref_Kind,
    decl_start: int,       // Local: the declaring identifier, so a shadowing one is not it
    dir:        string,    // Package: the declaring package's directory, temp-owned
    own_pkg:    bool,      // Package: the request file is one of that package's own
    owner:      Field_Site, // Field
}

// The struct a field belongs to: its name and the package directory declaring
// it, which two structs of one name cannot share. With the field name the scan
// is already keyed on, that identifies the field — separating `Point.x` from
// `Rect.x`, and (through `using` embedding and `X :: Y` aliases) letting an outer
// struct answer with the inner one's identity.
//
// Not the declaring identifier's file and offset, which is the obvious identity
// and the wrong one: the same field is at one offset in an unsaved buffer and
// another in the on-disk copy other files resolve through.
@(private)
Field_Site :: struct {
    owner: string,
    dir:   string,
}

// Where an identifier sits, which decides what it can possibly name. The grammar
// spells most of these the same way (a bare `identifier`), so the position is
// read off the parent rather than the node.
@(private)
Ref_Pos :: enum {
    Value,      // a bare name standing for something in scope
    Member,     // the `b` of `a.b`
    Field_Decl, // the name of a struct field's declaration
    Field_Init, // the `x` of `T{x = 1}` — names a field of T
    Named_Arg,  // the `x` of `f(x = 1)` — names a parameter of f
    Ignored,    // a package clause, an import alias, an attribute, a label
}

// How many operand types one scan will infer before it stops proving and starts
// accepting. Each inference can cost a file read and a parse, and a field name
// like `x` can appear thousands of times in a workspace; past this the scan
// keeps the occurrences it can no longer judge rather than dropping them.
@(private)
REF_INFER_LIMIT :: 512

// One file's worth of scan state: the tree being walked and everything the
// target needs to judge an occurrence in it.
@(private)
Ref_Scan :: struct {
    e:          ^Engine,
    parser:     ts.Parser,
    root:       ts.Node,
    req:        ^lang.Request, // describes *this* file: its source and its path
    target:     ^Ref_Target,
    buffer:     bool,     // this is the live request buffer, not a workspace file
    defs:       []Def,    // Package/Local: this file's declarations, fields dropped
    qualifiers: map[string]bool, // Package: import aliases here naming the target package
    in_package: bool,     // Package: this file belongs to the target's package
    opaque:     bool,     // a `using` in reach: fall back to matching the name
    skip_decl:  bool,     // find-usages: the declaration is not one of its own uses
    sites:      map[string]Field_Site_Hit, // Field: inferred operand types, per file
    budget:     ^int,
    res:        ^lang.Result,
}

@(private)
Field_Site_Hit :: struct {
    site: Field_Site,
    ok:   bool,
}

// Gathers every occurrence of the identifier under the caret ("find usages").
// The caret's name is resolved once (ref_target) and every candidate is then
// bound-checked against it; the files searched are the live buffer plus, for
// anything not confined to one scope, the workspace files the symbol index says
// mention the name (the rest cannot contain a usage). Each occurrence becomes a
// lang.Symbol carrying its file, line, offset and the source line it sits on for
// a code-context preview — every occurrence but the declaration, which is a use
// of the symbol only to rename (see the note at the head of this file).
@(private)
collect_references :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    name := ts.node_text(ident, req.source)
    target := ref_target(e, parser, root, req, ident, name)
    budget := REF_INFER_LIMIT

    ref_scan_tree(e, parser, root, req, &target, true, &budget, res)

    // A local lives and dies in one scope of one file; everything else can be
    // named from another file in its package, or from any file importing it.
    if target.kind != .Local && req.workspace != "" {
        paths := make([dynamic]string, context.temp_allocator)
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        index_ref_files(e, name, req.path, &paths)
        sync.unlock(&e.index.mutex)
        for path in paths {
            if lang.request_cancelled(req) {
                return
            }
            ref_scan_file(e, parser, path, req, &target, &budget, res)
        }
    }

    slice.sort_by(res.symbols[:], proc(a, b: lang.Symbol) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    res.ok = len(res.symbols) > 0
}

// What the caret's identifier names, which is what the rest of the scan matches
// against. Every branch that cannot establish a binding answers `.Any`, the flat
// name match this scan used to be.
@(private)
ref_target :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    ident: ts.Node,
    name: string,
) -> Ref_Target {
    pos, operand := ref_position(ident)
    switch pos {
    case .Field_Decl:
        // The declaration itself: the struct around it is what every use has to
        // resolve to. A field of a union or a bit_field has no struct to name.
        if site, ok := enclosing_struct_site(ident, req); ok {
            return Ref_Target{name = name, kind = .Field, owner = site}
        }
    case .Field_Init:
        // `T{name = 1}` names a field of T, the same as `v.name` does.
        if lit, has := ancestor_type(ident, "struct"); has {
            if site, ok := literal_field_site(e, parser, root, req, lit, name); ok {
                return Ref_Target{name = name, kind = .Field, owner = site}
            }
        }
    case .Member:
        if ts.node_is_null(operand) {
            break // an implicit enum selector (`.Vertical`): nothing to resolve
        }
        // `pkg.name` — the symbol belongs to that package wherever it is written,
        // so the package it names is the whole target.
        if is_identifier(operand) {
            if raw, found := import_path(root, req.source, ts.node_text(operand, req.source)); found {
                if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                    return Ref_Target {
                        name = name,
                        kind = .Package,
                        dir = strings.clone(dir, context.temp_allocator),
                    }
                }
                break // an unknown collection: the package cannot be located
            }
        }
        // `value.name` — a field of whatever struct the operand's type is.
        if site, ok := operand_field_site(e, parser, root, req, operand, name); ok {
            return Ref_Target{name = name, kind = .Field, owner = site}
        }
    case .Value:
        return ref_value_target(e, parser, root, req, name)
    case .Named_Arg, .Ignored:
    }
    return Ref_Target{name = name, kind = .Any}
}

// The target for a bare name: the declaration it binds to here, or — when this
// file declares nothing of the name — the package that does.
@(private = "file")
ref_value_target :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    name: string,
) -> Ref_Target {
    defs := ref_defs(e, root, req.source)
    d, found := resolve_local(defs, name, req.offset)
    if found && !d.top_level {
        return Ref_Target{name = name, kind = .Local, decl_start = d.ident_start}
    }
    // An import alias or the package clause: what it names is a directory, not a
    // declaration this scan can bind occurrences to.
    if found && d.kind == "namespace" {
        return Ref_Target{name = name, kind = .Any}
    }

    dir, declared := ref_own_package(e, parser, req, name)
    if found || declared {
        return Ref_Target{name = name, kind = .Package, dir = dir, own_pkg = true}
    }
    // Neither this file nor its package declares it: a builtin, a stdlib name
    // brought in by a `using`, or a typo. Nothing to bind to, so nothing is
    // excluded either.
    return Ref_Target{name = name, kind = .Any}
}

// The requesting file's package directory, and whether that package declares
// `name` in some file other than the request's own. Takes the index mutex.
@(private = "file")
ref_own_package :: proc(e: ^Engine, parser: ts.Parser, req: ^lang.Request, name: string) -> (dir: string, declares: bool) {
    if req.workspace == "" {
        // Nothing outside the buffer is searched, so the directory is never used
        // to place another file — only the buffer's own membership matters.
        return filepath.dir(req.path), false
    }
    sync.lock(&e.index.mutex)
    index_sync(e, parser, req)
    d := index_package_dir(e, req.path)
    _, found := index_first_path(e, name, req.path, "", d)
    dir = strings.clone(d, context.temp_allocator) // survives the unlock
    sync.unlock(&e.index.mutex)
    return dir, found
}

// This file's declarations with the struct fields dropped. A field is captured
// by the LOCALS query and sits in no block, so it lands in `collect_defs` as a
// file-scope declaration — which it is not: a field is named through a value of
// its struct, never bare, and leaving it in would let an unrelated field decide
// what a bare name binds to.
@(private = "file")
ref_defs :: proc(e: ^Engine, root: ts.Node, source: string) -> []Def {
    all := collect_defs(e, root, source)
    out := make([dynamic]Def, 0, len(all), context.temp_allocator)
    for d in all {
        if d.kind != "field" {
            append(&out, d)
        }
    }
    return out[:]
}

// Walks one parsed file, appending the occurrences that bind to the target.
// `req` describes the tree being walked (its source and path), so the type
// inference a field target needs resolves against the right file.
@(private = "file")
ref_scan_tree :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    target: ^Ref_Target,
    buffer: bool,
    budget: ^int,
    res: ^lang.Result,
) {
    scan := Ref_Scan {
        e         = e,
        parser    = parser,
        root      = root,
        req       = req,
        target    = target,
        buffer    = buffer,
        skip_decl = req.kind == .References,
        budget    = budget,
        res       = res,
    }
    ref_prepare(&scan)
    ref_walk(&scan, root)
}

// Re-parses one workspace file and scans it. Called only for files the index
// flagged as mentioning the name.
@(private = "file")
ref_scan_file :: proc(
    e: ^Engine,
    parser: ts.Parser,
    path: string,
    req: ^lang.Request,
    target: ^Ref_Target,
    budget: ^int,
    res: ^lang.Result,
) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return
    }
    source := string(data)

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)

    // The request as this file sees it: same workspace and cancellation flag, its
    // own source and path, so every lookup below resolves against this file's
    // scopes and imports rather than the buffer's.
    sub := req^
    sub.source = source
    sub.path = path
    sub.offset = 0
    ref_scan_tree(e, parser, ts.tree_root_node(tree), &sub, target, false, budget, res)
}

// Works out, once per file, everything the target needs to judge an occurrence
// in it: whether the file is beyond the engine's reach, which of its declarations
// could shadow the name, whether it belongs to the target's package, and which of
// its import aliases name that package.
@(private = "file")
ref_prepare :: proc(s: ^Ref_Scan) {
    s.sites = make(map[string]Field_Site_Hit, 0, context.temp_allocator)
    if s.target.kind == .Any {
        return
    }
    // A `using` injects names from a scope the engine does not follow, so nothing
    // about a name in this file can be proved. Written `using import` does not
    // even parse, hence the textual half of the test.
    s.opaque = has_using(s.root) || strings.contains(s.req.source, "using import")
    if s.opaque {
        return
    }

    #partial switch s.target.kind {
    case .Local:
        s.defs = ref_defs(s.e, s.root, s.req.source)
    case .Package:
        s.defs = ref_defs(s.e, s.root, s.req.source)
        s.in_package = s.buffer ? s.target.own_pkg : path_in_dir(s.req.path, s.target.dir)
        s.qualifiers = make(map[string]bool, 0, context.temp_allocator)
        ref_collect_qualifiers(s)
    }
}

// Records every import alias in this file that resolves to the target's package
// directory — the qualifiers a use of the symbol has to be written behind here.
@(private = "file")
ref_collect_qualifiers :: proc(s: ^Ref_Scan) {
    for i in 0 ..< ts.node_named_child_count(s.root) {
        child := ts.node_named_child(s.root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        name, raw, ok := import_name_and_path(child, s.req.source)
        if !ok {
            continue
        }
        if dir, dok := package_dir(s.e, raw, s.req.path, s.req.workspace); dok && same_dir(dir, s.target.dir) {
            s.qualifiers[name] = true
        }
    }
}

// Every identifier in the subtree, in source order. An identifier node has no
// identifier children, so a match ends the descent.
@(private = "file")
ref_walk :: proc(s: ^Ref_Scan, node: ts.Node) {
    if is_identifier(node) {
        if ts.node_text(node, s.req.source) == s.target.name {
            if binds, decl := ref_binds(s, node); binds && !(decl && s.skip_decl) {
                ref_append(s, node)
            }
        }
        return
    }
    for i in 0 ..< ts.node_child_count(node) {
        ref_walk(s, ts.node_child(node, i))
    }
}

// Whether this occurrence of the name binds to the target, and whether it is the
// declaration of it rather than a use — which find-usages drops and rename keeps.
@(private = "file")
ref_binds :: proc(s: ^Ref_Scan, node: ts.Node) -> (binds: bool, decl: bool) {
    if s.target.kind == .Any || s.opaque {
        // Nothing was proved about the name, so nothing here is known to be its
        // declaration either; every occurrence stands.
        return true, false
    }
    start := int(ts.node_start_byte(node))
    pos, operand := ref_position(node)
    switch s.target.kind {
    case .Local:
        // The same lexical resolution goto runs, at this offset: a redeclaration
        // in an inner block answers with itself, and is therefore not this one.
        if pos != .Value {
            return false, false
        }
        d, found := resolve_local(s.defs, s.target.name, start)
        return found && d.ident_start == s.target.decl_start, start == s.target.decl_start
    case .Package:
        #partial switch pos {
        case .Value:
            // A bare name reaches a package-level declaration only from inside
            // that package, and only where nothing nearer shadows it.
            if !s.in_package {
                return false, false
            }
            d, found := resolve_local(s.defs, s.target.name, start)
            if found && (!d.top_level || d.kind == "namespace") {
                return false, false
            }
            // Its own declaring identifier — in whichever of the package's files
            // it is written; procedure groups make that more than one.
            return true, found && d.ident_start == start
        case .Member:
            // Outside the package the symbol is reachable only behind a qualifier
            // naming it; inside, a `v.name` is a field of some value instead.
            qualified :=
                !ts.node_is_null(operand) && is_identifier(operand) &&
                ts.node_text(operand, s.req.source) in s.qualifiers
            return qualified, false
        }
        return false, false
    case .Field:
        #partial switch pos {
        case .Field_Decl:
            site, ok := enclosing_struct_site(node, s.req)
            return ok && ref_site_equal(site, s.target.owner), true
        case .Member:
            if ts.node_is_null(operand) {
                return false, false // `.name` is an enum member, not a field of anything
            }
            return ref_field_matches(s, operand), false
        case .Field_Init:
            lit, has := ancestor_type(node, "struct")
            if !has {
                return true, false
            }
            site, ok := literal_field_site(s.e, s.parser, s.root, s.req, lit, s.target.name)
            return !ok || ref_site_equal(site, s.target.owner), false
        }
        return false, false
    case .Any:
        return true, false
    }
    return true, false
}

// Whether `operand.name` reaches the field the target is. An operand whose type
// does not infer, or a struct the engine cannot locate, leaves the occurrence
// unproven — and therefore kept.
@(private = "file")
ref_field_matches :: proc(s: ^Ref_Scan, operand: ts.Node) -> bool {
    site, ok := ref_operand_site(s, operand)
    if !ok {
        return true
    }
    return ref_site_equal(site, s.target.owner)
}

// operand_field_site with a per-file memo: one file names the same value in the
// same block over and over, and each miss costs an inference plus, across
// packages, a read and a parse of the file declaring the struct.
@(private = "file")
ref_operand_site :: proc(s: ^Ref_Scan, operand: ts.Node) -> (Field_Site, bool) {
    key, keyed := ref_operand_key(s, operand)
    if keyed {
        if hit, seen := s.sites[key]; seen {
            return hit.site, hit.ok
        }
    }
    site, ok := Field_Site{}, false
    if s.budget^ > 0 {
        s.budget^ -= 1
        site, ok = operand_field_site(s.e, s.parser, s.root, s.req, operand, s.target.name)
    }
    if keyed {
        s.sites[key] = Field_Site_Hit{site = site, ok = ok}
    }
    return site, ok
}

// Memo key for an operand: the name it is written as, in the block it is written
// in — which is what its type is resolved from. Only a bare identifier is keyed;
// a compound operand (`a.b.c`, `f().x`) is inferred each time.
@(private = "file")
ref_operand_key :: proc(s: ^Ref_Scan, operand: ts.Node) -> (string, bool) {
    if !is_identifier(operand) {
        return "", false
    }
    scope := 0
    if block, has := enclosing_scope(operand); has {
        scope = int(ts.node_start_byte(block))
    }
    return fmt.tprintf("%d|%s", scope, ts.node_text(operand, s.req.source)), true
}

// The declaring site of the `field` member of the struct `operand` evaluates to.
@(private)
operand_field_site :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    operand: ts.Node,
    field: string,
) -> (Field_Site, bool) {
    tr, ok := infer_expr_type(e, parser, root, req, operand)
    if !ok {
        return {}, false
    }
    return field_site(e, parser, root, req, tr, field)
}

// The declaring site of the `field` member of a composite literal's type
// (`T{field = 1}`). A qualified literal (`pkg.T{...}`) keeps the `pkg` outside
// the literal node, so the qualifier is read off the selector around it.
@(private = "file")
literal_field_site :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    lit: ts.Node,
    field: string,
) -> (Field_Site, bool) {
    tr, ok := composite_type_name(lit, req.source)
    if !ok {
        return {}, false
    }
    if tr.pkg == "" {
        holder := ts.node_parent(lit)
        if !ts.node_is_null(holder) && string(ts.node_type(holder)) == "member_expression" {
            qualifier := ts.node_named_child(holder, 0)
            if is_identifier(qualifier) && !same_node(qualifier, lit) {
                tr.pkg = ts.node_text(qualifier, req.source)
            }
        }
    }
    return field_site(e, parser, root, req, tr, field)
}

// Locates the struct `tr` names and, in it, the declaration of `field` — through
// an alias and through any struct embedded with `using`, so the answer is the
// struct the field is really declared by. Cloned into scratch: the tree and the
// source it was read from are gone by the time the caller compares it.
@(private = "file")
field_site :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    tr: Type_Ref,
    field: string,
) -> (Field_Site, bool) {
    ctx := Member_Ctx {
        field = field,
        env = Embed_Env{e = e, parser = parser, root = root, req = req},
    }
    if !visit_type_decl(e, parser, root, req, tr, "struct_declaration", "type", member_visitor, &ctx) || !ctx.got {
        return {}, false
    }
    if ctx.owner == "" {
        return {}, false
    }
    return ref_site(ctx.owner, ctx.path), true
}

// The struct declaration a field's own declaration sits in, as a site.
@(private = "file")
enclosing_struct_site :: proc(ident: ts.Node, req: ^lang.Request) -> (Field_Site, bool) {
    sd, has := ancestor_type(ident, "struct_declaration")
    if !has {
        return {}, false
    }
    owner := decl_name(sd, req.source)
    if owner == "" {
        return {}, false
    }
    return ref_site(owner, req.path), true
}

// A site from the struct's name and the file declaring it, both copied into
// scratch so neither borrows a parse that is about to be thrown away.
@(private = "file")
ref_site :: proc(owner, path: string) -> Field_Site {
    return Field_Site {
        owner = strings.clone(owner, context.temp_allocator),
        dir = strings.clone(filepath.dir(path), context.temp_allocator),
    }
}

@(private = "file")
ref_site_equal :: proc(a, b: Field_Site) -> bool {
    return a.owner == b.owner && same_dir(a.dir, b.dir)
}

// Whether two directories are the same one, comparing the spellings first and
// their absolute forms (a syscall) only when that fails. The spellings come from
// different producers — an index key, a request path, an import joined onto one
// — and a mismatch here fails *closed*, dropping a usage, so it is worth a
// second try.
@(private = "file")
same_dir :: proc(a, b: string) -> bool {
    if path_equal(a, b) {
        return true
    }
    abs_a, err_a := filepath.abs(a, context.temp_allocator)
    abs_b, err_b := filepath.abs(b, context.temp_allocator)
    return err_a == nil && err_b == nil && path_equal(abs_a, abs_b)
}

// Where an identifier sits, and — for a member — the operand it is a member of
// (null for an implicit enum selector, which has none).
@(private)
ref_position :: proc(node: ts.Node) -> (Ref_Pos, ts.Node) {
    parent := ts.node_parent(node)
    if ts.node_is_null(parent) {
        return .Ignored, {}
    }
    switch string(ts.node_type(parent)) {
    case "package_declaration",
         "import_declaration",
         "attribute",
         "tag",
         "label_statement",
         "using_statement",
         "foreign_block",
         "polymorphic_parameters":
        return .Ignored, {}
    case "field":
        // A struct field's declaration: the names precede the `(type ...)` child,
        // which holds every identifier that is not one of them.
        return .Field_Decl, {}
    case "struct_field":
        // `T{name = value}`: the leading identifier names the field, the rest is
        // the value assigned to it.
        if same_node(ts.node_named_child(parent, 0), node) {
            return .Field_Init, {}
        }
    case "enum_declaration":
        // The enum's own name is a declaration like any other; everything after
        // it is a member, which is named through the enum rather than bare.
        if !same_node(ts.node_named_child(parent, 0), node) {
            return .Ignored, {}
        }
    case "call_expression":
        // `f(name = 1)` — a named argument, laid out flat inside the call. The
        // name is the callee's parameter, not anything in scope here.
        next := ts.node_next_sibling(node)
        if !ts.node_is_null(next) && string(ts.node_type(next)) == "=" {
            return .Named_Arg, {}
        }
    }

    // The selector test runs on the node standing in for this identifier — a
    // called, indexed or braced member sits inside its wrapper rather than beside
    // the operand (`pkg.run(x)`, `pkg.Rect{}`).
    subject := selector_subject(node)
    holder := ts.node_parent(subject)
    if ts.node_is_null(holder) {
        return .Value, {}
    }
    switch string(ts.node_type(holder)) {
    case "member_expression", "field_type":
        first := ts.node_named_child(holder, 0)
        if ts.node_is_null(first) || !same_node(first, subject) {
            return .Member, first
        }
        // An implicit enum selector (`.Vertical`) is its holder's first child too,
        // but starts past the dot the holder starts at.
        if ts.node_start_byte(subject) != ts.node_start_byte(holder) {
            return .Member, {}
        }
    }
    return .Value, {}
}

// Appends one occurrence as a reference row: the source line it sits on is the
// preview, path/line/offset the jump target. Owned strings use context.allocator
// (the Manager's).
@(private = "file")
ref_append :: proc(s: ^Ref_Scan, node: ts.Node) {
    start := int(ts.node_start_byte(node))
    append(&s.res.symbols, lang.Symbol {
        name      = strings.clone(s.target.name),
        kind      = strings.clone("reference"),
        signature = source_line(s.req.source, start),
        path      = strings.clone(s.req.path),
        line      = strings.count(s.req.source[:clamp(start, 0, len(s.req.source))], "\n") + 1,
        offset    = start,
    })
}

// The whole source line `offset` falls on, trimmed — a reference row's code
// preview. Cloned into context.allocator.
@(private)
source_line :: proc(source: string, offset: int) -> string {
    lo := clamp(offset, 0, len(source))
    start := strings.last_index_byte(source[:lo], '\n') + 1 // -1 + 1 == 0 for the first line
    end := len(source)
    if nl := strings.index_byte(source[lo:], '\n'); nl >= 0 {
        end = lo + nl
    }
    return strings.clone(strings.trim_space(source[start:end]))
}

// Whether two paths name the same file, by the same normalization path_in_dir
// uses: either separator reads as `/`, and on Windows case does not distinguish.
// The comparison is otherwise literal — the spellings being compared come from
// the same producer in every case that matters.
@(private)
path_equal :: proc(a, b: string) -> bool {
    if len(a) != len(b) {
        return false
    }
    for i in 0 ..< len(a) {
        if path_byte(a[i]) != path_byte(b[i]) {
            return false
        }
    }
    return true
}
