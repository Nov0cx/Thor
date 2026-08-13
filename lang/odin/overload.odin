// Procedure groups: `sizes :: proc{sized_a, sized_b}`, Odin's one form of
// overloading. A group declares no parameters and has no body — it names other
// procedures — so a feature pointed at one has to reach through to the members.
// Signature help signs them; go-to-definition jumps to them.
package odin

import "core:os"
import "core:path/filepath"
import "core:strings"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// How many members of a procedure group are expanded. A cap rather than a limit
// anyone is expected to reach: the signature popup is drawn one line per entry
// above the caret, so a pathological group would otherwise cover the buffer it
// is meant to annotate.
@(private)
OVERLOAD_LIMIT :: 32

// Where one member of a procedure group is declared. Signature help reads the
// label, go-to-definition the jump target, and both need the same lookup — so
// both are filled in one pass. An unresolved member keeps an empty label.
@(private)
Member_Site :: struct {
    name:   string, // slices the re-parsed declaration snippet (job-lifetime)
    label:  string, // signature line, owned in context.allocator; "" until resolved
    path:   string, // the file it was found in (job-lifetime, cloned by the caller)
    line:   int,
    offset: int, // its declaring identifier
}

// Locates every member of a procedure group. A group's members are ordinary
// procedures declared in the group's own package, so they are looked up there:
// first in the live buffer when it belongs to that package (its on-disk copy may
// be stale, and a member being edited must still answer), then across the
// package directory. The directory pass matches *every* outstanding member
// against each file it parses rather than restarting per member — a group of
// five in a twenty-file package sits on the per-keystroke signature path, and one
// parse per member per file would be twenty-five of them.
//
// A member that resolves to nothing keeps an empty label; a member written
// qualified (`proc{foo, other.bar}`) is one of those, since the lookup here is
// package-local. `live_root` is the parsed request buffer, or a null node when
// the caller has none to offer.
@(private)
overload_sites :: proc(
    e: ^Engine,
    parser: ts.Parser,
    live_root: ts.Node,
    req: ^lang.Request,
    group_src, group_path: string,
    d: Def,
) -> []Member_Site {
    members := overload_members(parser, group_src, d)
    if len(members) == 0 {
        return nil
    }
    sites := make([]Member_Site, len(members), context.temp_allocator)
    for member, i in members {
        sites[i].name = member
    }

    dir := filepath.dir(group_path) // a slice of group_path, no allocation
    if !ts.node_is_null(live_root) && same_dir(dir, filepath.dir(req.path)) {
        defs := collect_defs(e, live_root, req.source)
        fill_member_sites(defs[:], req.source, req.path, sites)
    }
    // A group the toolchain declares is answered from the resident builtin cache
    // instead, which already holds its package: the directory here is
    // `base:runtime`, and re-reading it per request is not what `append(` should
    // cost while its arguments are typed.
    if sites_missing(sites) && !builtin_member_sites(e, parser, group_path, sites) {
        scan_package_members(e, parser, req, dir, sites)
    }
    return sites
}


// The call the caret's name heads, and the tree it is written in — what narrows
// a procedure group to the one member the call reaches. `node` is null when the
// name heads no call, which leaves every member standing.
@(private)
Call_Site :: struct {
    node: ts.Node, // call_expression
    root: ts.Node, // the request buffer, for inferring an argument's type
}

// The call `ident` heads, if it heads one. A qualified callee nests its call
// under the member_expression (`lib.scale(2)` is
// `member_expression(lib, call_expression(scale, 2))`), so the identifier is the
// call's own function either way.
@(private)
caret_call_site :: proc(root, ident: ts.Node) -> Call_Site {
    call := ts.node_parent(ident)
    if ts.node_is_null(call) || string(ts.node_type(call)) != "call_expression" {
        return {}
    }
    if !same_node(ts.node_child_by_field_name(call, "function"), ident) {
        return {}
    }
    return Call_Site{node = call, root = root}
}

// Go-to-definition on a procedure group. The group names other procedures rather
// than declaring a body, so landing on it leaves the caller one hop short of the
// code they asked for: the members are resolved instead, and the only one becomes
// the jump target while several become picker candidates.
//
// The call at the caret narrows those candidates — first by how many arguments
// are written, then by what they are — so a group whose members differ answers
// with the one member the call reaches. A pass that leaves nothing standing is
// ignored: a filter is evidence, never the last word, and what stays ambiguous
// is what the picker is for.
//
// Reports false when no member resolves, which leaves the caller's own answer —
// the group declaration — to stand.
@(private)
overload_definitions :: proc(
    e: ^Engine,
    parser: ts.Parser,
    live_root: ts.Node,
    req: ^lang.Request,
    group_src, group_path: string,
    d: Def,
    call: Call_Site,
    res: ^lang.Result,
) -> bool {
    sites := overload_sites(e, parser, live_root, req, group_src, group_path, d)
    keep := make([]bool, len(sites), context.temp_allocator)
    kept := 0
    for site, i in sites {
        keep[i] = site.label != ""
        kept += int(keep[i])
    }
    if kept == 0 {
        return false
    }

    if kept > 1 && !ts.node_is_null(call.node) {
        argc := call_arg_count(call.node, req.source)
        kept = narrow(keep, arity_fits(sites, argc, keep))
        if kept > 1 {
            kept = narrow(keep, types_fit(e, parser, req, call, sites, argc, keep))
        }
    }

    // One member left: it *is* the definition, so jump straight to it, exactly
    // as a call of an ordinary procedure would.
    if kept == 1 {
        for k, i in keep {
            if k {
                jump_to_member(sites, i, res)
                return true
            }
        }
    }

    for site, i in sites {
        if site.label == "" {
            continue
        }
        if !keep[i] {
            delete(site.label) // narrowed out: its label has no row to move into
            continue
        }
        append(&res.symbols, lang.Symbol {
            name      = strings.clone(site.name),
            kind      = strings.clone("function"),
            signature = site.label, // moved: already in the Manager's allocator
            path      = strings.clone(site.path),
            line      = site.line,
            offset    = site.offset,
        })
    }
    res.ok = true
    return true
}

// Drops from `keep` every member `fits` rejects, and reports how many are left.
// A pass that would leave none is dropped instead: an argument the engine reads
// wrongly must cost the user a picker, never the member they asked for.
@(private = "file")
narrow :: proc(keep, fits: []bool) -> (kept: int) {
    for f, i in fits {
        if keep[i] && f {
            kept += 1
        }
    }
    if kept == 0 {
        for k in keep {
            kept += int(k)
        }
        return
    }
    for f, i in fits {
        keep[i] &= f
    }
    return
}

// Which members can take a call of `argc` arguments, by parameter count alone —
// the strong signal, and the one that separates most groups (see arity_takes,
// which signature help picks its active entry with). Members already dropped are
// not read.
@(private = "file")
arity_fits :: proc(sites: []Member_Site, argc: int, keep: []bool) -> []bool {
    fits := make([]bool, len(sites), context.temp_allocator)
    for site, i in sites {
        if keep[i] {
            fits[i] = arity_takes(site.label, argc)
        }
    }
    return fits
}

// Which members every written argument fits by type. Each argument is matched
// against the parameter in its own slot, and only a positive mismatch rejects a
// member — an argument whose type does not infer says nothing about any of them.
// A call written with named arguments (`f(x = 1)`) is not read at all, since the
// slots are then not the order they are written in.
@(private = "file")
types_fit :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    call: Call_Site,
    sites: []Member_Site,
    argc: int,
    keep: []bool,
) -> []bool {
    fits := make([]bool, len(sites), context.temp_allocator)
    if call_has_named_argument(call.node) {
        return fits
    }
    for site, i in sites {
        if !keep[i] {
            continue
        }
        fits[i] = true
        for slot in 0 ..< argc {
            param, pok := signature_param_type(site.label, slot)
            if !pok {
                continue // a type the reader cannot spell out is no evidence
            }
            if !argument_fits(e, parser, req, call, slot, param) {
                fits[i] = false
                break
            }
        }
    }
    return fits
}

// Whether the argument in `slot` can be passed to a parameter of type `param`.
// True unless something is known about both sides and they disagree: an untyped
// literal is matched by the class of type it converts to, anything else by the
// type it infers to, and neither an unreadable argument nor an unreadable
// parameter rejects anything.
@(private = "file")
argument_fits :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    call: Call_Site,
    slot: int,
    param: Type_Ref,
) -> bool {
    arg := call_argument(call.node, slot)
    if ts.node_is_null(arg) || param.name == "any" || param.proc_sig != "" {
        return true
    }
    if class, is_literal := literal_class(arg); is_literal {
        // A container's name is its element's (`[]int` reads as int), which says
        // nothing about what a literal may be passed to, so it decides nothing.
        accepts, known := builtin_accepts(param.name)
        return !known || !type_is_bare(param) || class in accepts
    }
    inferred, iok := infer_expr_type(e, parser, call.root, req, arg)
    if !iok {
        return true
    }
    return type_refs_match(inferred, param)
}

// The `index`-th written argument of a call. The callee is the call's first
// named child, so the arguments follow it; a slot left empty (`f(1,|)`) has no
// node of its own. Package-visible: typeref.odin's polymorphic call-result
// substitution reaches the same argument by parameter slot.
@(private)
call_argument :: proc(call: ts.Node, index: int) -> ts.Node {
    i := u32(index) + 1
    if i >= ts.node_named_child_count(call) {
        return {}
    }
    return ts.node_named_child(call, i)
}

// Whether the call names any of its arguments (`f(x = 1)`), which puts them in
// an order the parameter slots do not follow. The `=` is an anonymous child of
// the call itself, so a default value inside a nested call is never read as one.
@(private = "file")
call_has_named_argument :: proc(call: ts.Node) -> bool {
    for i in 0 ..< ts.node_child_count(call) {
        if string(ts.node_type(ts.node_child(call, i))) == "=" {
            return true
        }
    }
    return false
}

// The class of value an untyped literal writes. Odin converts an untyped
// constant to whatever type it is passed to, so a literal argument fits by class
// rather than by one type name: `1` fits every numeric parameter.
@(private = "file")
Literal_Class :: enum {
    Number,
    Float,
    Text,
    Rune,
    Bool,
}

@(private = "file")
literal_class :: proc(arg: ts.Node) -> (Literal_Class, bool) {
    switch string(ts.node_type(arg)) {
    case "number":
        return .Number, true
    case "float":
        return .Float, true
    case "string":
        return .Text, true
    case "character":
        return .Rune, true
    case "boolean":
        return .Bool, true
    }
    return {}, false // `nil` included: it converts to most of what a type can be
}

// The literal classes a builtin type takes. A name that is not a builtin answers
// nothing and is taken as accepting everything, since a distinct type or an
// alias converts from the same literals the type under it does.
@(private = "file")
builtin_accepts :: proc(name: string) -> (bit_set[Literal_Class], bool) {
    switch name {
    case "int", "uint", "uintptr", "byte", "rune",
         "i8", "i16", "i32", "i64", "i128",
         "u8", "u16", "u32", "u64", "u128":
        return {.Number, .Rune}, true
    case "f16", "f32", "f64", "complex32", "complex64", "complex128":
        return {.Number, .Float}, true
    case "string", "cstring":
        return {.Text}, true
    case "bool", "b8", "b16", "b32", "b64":
        return {.Bool}, true
    case "rawptr":
        return {}, true
    }
    return {}, false
}

// Whether an argument of type `arg` fits a parameter of type `param`: the same
// name under the same containers. A package qualifier is compared only when both
// sides carry one — the same type is `Point` inside its package and `lib.Point`
// outside it — and a proc-typed side is not compared at all.
@(private = "file")
type_refs_match :: proc(arg, param: Type_Ref) -> bool {
    if arg.proc_sig != "" || param.proc_sig != "" {
        return true
    }
    if arg.name != param.name || arg.depth != param.depth {
        return false
    }
    if arg.pkg != "" && param.pkg != "" && arg.pkg != param.pkg {
        return false
    }
    for i in 0 ..< arg.depth {
        if arg.containers[i].kind != param.containers[i].kind {
            return false
        }
    }
    return true
}

// Answers with one member as the definition. A Location carries no signature, so
// every label the lookup built — the chosen one included — has no home and is
// released here.
@(private = "file")
jump_to_member :: proc(sites: []Member_Site, chosen: int, res: ^lang.Result) {
    for site in sites {
        if site.label != "" {
            delete(site.label)
        }
    }
    site := sites[chosen]
    res.location = lang.Location {
        path  = strings.clone(site.path),
        start = site.offset,
        end   = site.offset + len(site.name),
    }
    res.ok = true
}

// The member names of a procedure group, read off a re-parse of its declaration
// text. A re-parse rather than a walk of the original tree because there may not
// be one: a cross-file group's tree is freed by first_proc_in_file before this
// runs, and only its source survives. A textual split of the braces would have to
// model comments and line breaks the member list is allowed to carry, which the
// grammar already does. The snippet is prefixed with a package clause so it
// parses as the file it came from; the names slice into that prefixed copy, which
// lives on the worker's temp allocator for the rest of the job.
@(private)
overload_members :: proc(parser: ts.Parser, source: string, d: Def) -> []string {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := strings.concatenate({"package p\n", source[start:end]}, context.temp_allocator)

    tree := ts.parser_parse_string(parser, text)
    if tree == nil {
        return nil
    }
    defer ts.tree_delete(tree)

    group, found := find_node_type(ts.tree_root_node(tree), "overloaded_procedure_declaration")
    if !found {
        return nil
    }

    names := make([dynamic]string, context.temp_allocator)
    named := false // the group's own name is the first identifier, past any @(...)
    for i in 0 ..< ts.node_named_child_count(group) {
        c := ts.node_named_child(group, i)
        if !is_identifier(c) {
            continue // an attributes node before the name, or a qualified member
        }
        if !named {
            named = true
            continue
        }
        append(&names, ts.node_text(c, text))
        if len(names) >= OVERLOAD_LIMIT {
            break
        }
    }
    return names[:]
}

// First node of type `want` in a pre-order walk from `n`.
@(private = "file")
find_node_type :: proc(n: ts.Node, want: string) -> (ts.Node, bool) {
    if ts.node_is_null(n) {
        return {}, false
    }
    if string(ts.node_type(n)) == want {
        return n, true
    }
    for i in 0 ..< ts.node_child_count(n) {
        if found, ok := find_node_type(ts.node_child(n, i), want); ok {
            return found, ok
        }
    }
    return {}, false
}

// Fills the still-unresolved sites from the top-level procedures of `defs`,
// matched by name. A site already filled is left alone, so the first source
// consulted — the live buffer — wins over the stale copy on disk.
@(private)
fill_member_sites :: proc(defs: []Def, source, path: string, sites: []Member_Site) {
    for &site in sites {
        if site.label != "" {
            continue
        }
        for d in defs {
            if !d.top_level || d.kind != "function" || d.name != site.name {
                continue
            }
            site.label = signature_text(source, d) // cloned into the Manager's allocator
            site.path = path
            site.offset = d.ident_start
            site.line = strings.count(source[:clamp(d.ident_start, 0, len(source))], "\n") + 1
            break
        }
    }
}

// Fills the remaining members from the package directory `dir`, parsing each
// .odin file once and matching every outstanding member against it. The
// requesting file is skipped — its live text has already answered — and the walk
// stops as soon as nothing is outstanding. Cancellation is polled per file: this
// runs on the typing-driven signature path, where the next keystroke supersedes it.
@(private)
scan_package_members :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    dir: string,
    sites: []Member_Site,
) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    for info in infos {
        if lang.request_cancelled(req) {
            return
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == req.path {
            continue
        }
        src, sok := source_read(info.fullpath)
        if !sok {
            continue
        }
        tree := ts.parser_parse_string(parser, src)
        if tree == nil {
            continue
        }
        // info.fullpath is temp-allocated with `infos`, so it outlives the job's
        // last read of the site it is recorded in.
        fill_member_sites(collect_defs(e, ts.tree_root_node(tree), src)[:], src, info.fullpath, sites)
        ts.tree_delete(tree)
        if !sites_missing(sites) {
            return
        }
    }
}

// Whether any member is still unresolved — so the package scan knows to run at
// all, and when to stop.
@(private)
sites_missing :: proc(sites: []Member_Site) -> bool {
    for site in sites {
        if site.label == "" {
            return true
        }
    }
    return false
}
