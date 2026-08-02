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
    if sites_missing(sites) {
        scan_package_members(e, parser, req, dir, sites)
    }
    return sites
}

// Whether two paths name the same directory. The spellings reach here from
// different places — the request carries the path its file was opened with, a
// cross-file group the one the workspace walk produced — so an equal pair is
// taken at its word and anything else is compared absolute. Only the live
// buffer's package membership rides on this: a false negative costs the unsaved
// edits in that one file, never a wrong answer.
@(private = "file")
same_dir :: proc(a, b: string) -> bool {
    if a == b {
        return true
    }
    aa, aerr := filepath.abs(a, context.temp_allocator)
    bb, berr := filepath.abs(b, context.temp_allocator)
    if aerr != nil || berr != nil {
        return false
    }
    when ODIN_OS == .Windows {
        return strings.equal_fold(aa, bb) // the filesystem doesn't care about case
    } else {
        return aa == bb
    }
}

// Go-to-definition on a procedure group. The group names other procedures rather
// than declaring a body, so landing on it leaves the caller one hop short of the
// code they asked for: the members are resolved instead, and the only one becomes
// the jump target while several become picker candidates — the arguments that
// would choose between them belong to a call, and goto has no call to read.
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
    res: ^lang.Result,
) -> bool {
    sites := overload_sites(e, parser, live_root, req, group_src, group_path, d)
    found := 0
    for site in sites {
        if site.label != "" {
            found += 1
        }
    }
    if found == 0 {
        return false
    }

    // One member: it *is* the definition, so jump straight to it, exactly as a
    // call of an ordinary procedure would. The location carries no signature, so
    // the label the lookup built has no home and is released here.
    if found == 1 {
        for site in sites {
            if site.label == "" {
                continue
            }
            delete(site.label)
            res.location = lang.Location {
                path  = strings.clone(site.path),
                start = site.offset,
                end   = site.offset + len(site.name),
            }
            res.ok = true
            return true
        }
    }

    for site in sites {
        if site.label == "" {
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
        data, rerr := os.read_entire_file(info.fullpath, context.temp_allocator)
        if rerr != nil {
            continue
        }
        src := string(data)
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
