// Package-wide lookups: scanning a package directory for a declaration, and
// rendering the documentation page for the package under the caret.
package odin

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// Scans one package directory (all its .odin files, non-recursively — an Odin
// package is a single flat directory) for a matching top-level declaration.
@(private)
scan_package :: proc(
    e: ^Engine,
    parser: ts.Parser,
    dir: string,
    req: ^lang.Request,
    name: string,
    hover_start, hover_end: int,
    res: ^lang.Result,
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
        if res.ok {
            return
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        scan_file(e, parser, info.fullpath, req, name, hover_start, hover_end, res)
    }
}

// Caret on the package operand itself (`pkg` in `pkg.lang.Symbol`): "go to package".
// Definition jumps to the head of the file named like the package (the `foo.odin`
// entry file in package `foo`, the usual convention). When no such file exists it
// falls back to the .odin file whose name is fuzzily closest to the package name
// (a prefix like `foo_windows.odin` beats an unrelated `zebra.odin`), so the
// caret still lands on the most package-like file rather than reporting nothing.
// Hover shows the import path.
@(private)
open_package :: proc(dir, raw: string, req: ^lang.Request, res: ^lang.Result, hover_start, hover_end: int) {
    #partial switch req.kind {
    case .Definition:
        handle, open_err := os.open(dir)
        if open_err != nil {
            return
        }
        defer os.close(handle)
        infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
        if read_err != nil {
            return
        }
        pkg := filepath.base(dir)
        want := strings.concatenate({pkg, ".odin"}, context.temp_allocator)
        best_name := "" // the fuzzily-closest .odin file, the fallback target
        best_path := ""
        best_score := 0
        for info in infos {
            if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
                continue
            }
            if info.name == want {
                res.location = lang.Location{path = strings.clone(info.fullpath), start = 0, end = 0}
                res.ok = true
                return
            }
            // Higher score is closer; ties break lexicographically for a stable pick.
            s := pkg_file_score(strings.trim_suffix(info.name, ".odin"), pkg)
            if best_name == "" || s > best_score || (s == best_score && info.name < best_name) {
                best_name = info.name
                best_path = info.fullpath
                best_score = s
            }
        }
        // No `foo.odin`: land on the closest file so navigation still works.
        if best_path != "" {
            res.location = lang.Location{path = strings.clone(best_path), start = 0, end = 0}
            res.ok = true
        }
    case .Hover:
        text := strings.concatenate({"import \"", raw, "\""}, context.temp_allocator)
        res.hover = lang.Hover_Info {
            text  = strings.clone(text),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
}

// Renders a documentation page for the package the caret refers to. The package
// is resolved from the caret (an import line, a `pkg.lang.Symbol` operand, or a bare
// identifier naming an imported package) and, failing that, falls back to the
// file's own package directory — so F3 anywhere in an Odin file shows something.
@(private)
package_doc :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    // Neither branch hands back an owned string: package_dir_under_caret is
    // scratch-allocated and filepath.dir is a slice of req.path.
    dir, ok := package_dir_under_caret(e, root, req)
    owned_dir := ""
    if !ok {
        if req.path == "" {
            return
        }
        // No package under the caret: document the file's own package.
        owned_dir = filepath.dir(req.path)
        dir = owned_dir
    }
    defer if owned_dir != "" {
        delete(owned_dir)
    }
    render_package_doc(e, parser, req, dir, res)
}

// Resolves the package directory the caret refers to, the same three ways the
// goto flow does (an import declaration, a `pkg.lang.Symbol` operand, a bare package
// name), reusing package_dir so collections and relative paths resolve alike.
@(private)
package_dir_under_caret :: proc(e: ^Engine, root: ts.Node, req: ^lang.Request) -> (string, bool) {
    if imp, in_import := enclosing_import(root, req.source, req.offset); in_import {
        if raw, rok := import_string(imp, req.source); rok {
            return package_dir(e, raw, req.path, req.workspace)
        }
        return "", false
    }
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return "", false
    }
    // `pkg.lang.Symbol`: the operand names an imported package.
    if op_node, _, is_sel := selector_parts(ident); is_sel && is_identifier(op_node) {
        pkg := ts.node_text(op_node, req.source)
        if raw, found := import_path(root, req.source, pkg); found {
            return package_dir(e, raw, req.path, req.workspace)
        }
    }
    // A bare identifier that names an imported package (its alias by itself).
    name := ts.node_text(ident, req.source)
    if raw, found := import_path(root, req.source, name); found {
        return package_dir(e, raw, req.path, req.workspace)
    }
    return "", false
}

// One rendered entry in a package doc page: the declaration name (the sort key),
// its Odin signature (goes in a ```odin fence), and the cleaned doc-comment prose
// (the `//`-stripped comment above it). All slices/temp strings that outlive the
// source through the job's temp allocator.
@(private)
Doc_Entry :: struct {
    name:      string,
    signature: string,
    doc:       string,
}

// Fence and section delimiters mirroring how OLS assembles its hover
// documentation: a signature in a ```odin code block, then a `---` rule, then the
// doc-comment prose. See build_markup_content in ols/src/server/documentation.odin.
@(private)
DOC_FENCE_OPEN :: "```odin\n"
@(private)
DOC_FENCE_CLOSE :: "\n```\n"
@(private)
DOC_SECTION_RULE :: "\n---\n\n"

// Builds a Markdown documentation page for one package directory, rendered the
// way OLS shows documentation: every public top-level declaration across the
// package's .odin files (an Odin package is one flat directory), each as a
// ```odin-fenced signature followed by its cleaned doc-comment prose, sorted by
// name. Fills res.doc; ok when the package had at least one public symbol.
@(private)
render_package_doc :: proc(e: ^Engine, parser: ts.Parser, req: ^lang.Request, dir: string, res: ^lang.Result) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)
    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    entries := make([dynamic]Doc_Entry, context.temp_allocator)
    pkg_name := ""
    pkg_doc := ""
    for info in infos {
        if lang.request_cancelled(req) {
            return // a half-rendered page is worse than none
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        // Test files pad the package with @(test) procs that aren't API surface.
        if strings.has_suffix(info.name, "_test.odin") {
            continue
        }
        data, rerr := os.read_entire_file(info.fullpath, context.temp_allocator)
        if rerr != nil {
            continue
        }
        source := string(data)
        if pkg_name == "" {
            if n, off, nok := package_clause(source); nok {
                pkg_name = n
                pkg_doc = doc_prose_above(source, off) // the comment above `package X`
            }
        }
        tree := ts.parser_parse_string(parser, source)
        if tree == nil {
            continue
        }
        defs := collect_defs(e, ts.tree_root_node(tree), source)
        for d in defs {
            if !d.top_level || !symbol_kind_shown(d.kind) || !decl_is_public(source, d) {
                continue
            }
            append(&entries, Doc_Entry {
                name      = d.name,
                signature = decl_doc_text(source, d),
                doc       = doc_prose_above(source, d.decl_start),
            })
        }
        ts.tree_delete(tree)
    }

    if pkg_name == "" {
        pkg_name = filepath.base(dir)
    }
    slice.sort_by(entries[:], proc(a, b: Doc_Entry) -> bool {
        return a.name < b.name
    })

    page := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&page, "# package %s\n\n", pkg_name)
    fmt.sbprintf(&page, "`%s` — %d symbol%s\n", dir, len(entries), len(entries) == 1 ? "" : "s")
    if pkg_doc != "" {
        fmt.sbprintf(&page, "\n%s\n", pkg_doc)
    }
    for entry in entries {
        fmt.sbprintf(&page, "\n## %s\n\n", entry.name)
        strings.write_string(&page, DOC_FENCE_OPEN)
        strings.write_string(&page, entry.signature)
        strings.write_string(&page, DOC_FENCE_CLOSE)
        if entry.doc != "" {
            strings.write_string(&page, DOC_SECTION_RULE)
            strings.write_string(&page, entry.doc)
            strings.write_byte(&page, '\n')
        }
    }

    res.doc = lang.Doc_Info {
        title = strings.concatenate({"package ", pkg_name}),
        path  = strings.clone(dir),
        text  = strings.clone(strings.to_string(page)),
    }
    res.ok = len(entries) > 0
}

// The name and line offset of a file's `package X` clause, scanning lines until
// it finds one (blank lines and comments precede it). The offset is the start of
// the package line, so doc_prose_above reads the package's own doc comment.
@(private)
package_clause :: proc(source: string) -> (name: string, offset: int, ok: bool) {
    i := 0
    for i < len(source) {
        line_start := i
        line_end := i
        for line_end < len(source) && source[line_end] != '\n' {
            line_end += 1
        }
        t := strings.trim_space(source[line_start:line_end])
        if strings.has_prefix(t, "package") && len(t) > 7 && (t[7] == ' ' || t[7] == '\t') {
            rest := strings.trim_left_space(t[7:])
            end := 0
            for end < len(rest) && is_ident_byte(rest[end]) {
                end += 1
            }
            if end > 0 {
                return rest[:end], line_start, true
            }
        }
        i = line_end + 1
    }
    return "", 0, false
}

// True when the declaration is package-public: no `@(private)` (in any form)
// among the attributes the declaration carries before its identifier.
@(private)
decl_is_public :: proc(source: string, d: Def) -> bool {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.ident_start, start, len(source))
    return !strings.contains(source[start:end], "private")
}

// The doc comment directly above the line at `offset`, cleaned into prose the way
// OLS's get_comment does: the contiguous run of `//` lines above it, each with its
// `//` (and one following space) stripped and joined by newlines. Stops at a blank
// or non-comment line. "" when there is no comment. Temp-allocated.
@(private)
doc_prose_above :: proc(source: string, offset: int) -> string {
    decl_line := line_start_before(source, offset)
    block_start := decl_line
    for block_start > 0 {
        prev_line := line_start_before(source, block_start - 1)
        line := source[prev_line:block_start - 1] // excludes the '\n' at block_start-1
        if strings.has_prefix(strings.trim_left_space(line), "//") {
            block_start = prev_line
        } else {
            break
        }
    }
    if block_start >= decl_line {
        return ""
    }

    b := strings.builder_make(context.temp_allocator)
    first := true
    it := source[block_start:decl_line]
    for raw in strings.split_lines_iterator(&it) {
        t := strings.trim_left_space(raw)
        if !strings.has_prefix(t, "//") {
            continue // the trailing empty split, or a stray non-comment line
        }
        t = t[2:]                             // strip the `//`
        t = strings.trim_prefix(t, " ")       // and the one conventional space after it
        if !first {
            strings.write_byte(&b, '\n')
        }
        strings.write_string(&b, t)
        first = false
    }
    return strings.to_string(b)
}

// Start byte of the line containing byte `i` (the byte after the preceding '\n').
@(private)
line_start_before :: proc(source: string, i: int) -> int {
    j := clamp(i, 0, len(source))
    for j > 0 && source[j - 1] != '\n' {
        j -= 1
    }
    return j
}

// The declaration text shown on a doc page: the whole declaration (including any
// leading `@(...)` attribute), with a procedure's body dropped after the opening
// brace, trimmed. A slice into `source` (no allocation) so it can be appended to
// the page builder, which copies it.
@(private)
decl_doc_text :: proc(source: string, d: Def) -> string {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := source[start:end]
    if d.kind == "function" {
        if brace := strings.index_byte(text, '{'); brace >= 0 {
            text = text[:brace]
        }
    }
    return strings.trim_space(text)
}

// True for bytes that may appear in an Odin identifier.
@(private)
is_ident_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

// Fuzzy closeness of a file stem to the package name, higher is closer. A shared
// prefix and contiguous runs score highest, and a full subsequence match adds a
// bonus; when the package name isn't even a subsequence the shared-prefix length
// still orders the candidates, so the package-operand fallback always lands on
// the most package-like file (`foo_windows` over `zebra` for package `foo`).
@(private)
pkg_file_score :: proc(stem, pkg: string) -> int {
    score := 0

    n := min(len(stem), len(pkg))
    prefix := 0
    for prefix < n && ascii_lower(stem[prefix]) == ascii_lower(pkg[prefix]) {
        prefix += 1
    }
    score += prefix * 8

    // Subsequence of pkg within stem, rewarding contiguous runs.
    qi := 0
    streak := 0
    for i in 0 ..< len(stem) {
        if qi >= len(pkg) {
            break
        }
        if ascii_lower(stem[i]) == ascii_lower(pkg[qi]) {
            score += 2 + streak
            streak += 1
            qi += 1
        } else {
            streak = 0
        }
    }
    if qi == len(pkg) {
        score += 20 // the whole package name is present in order
    }

    score -= abs(len(stem) - len(pkg)) / 4 // prefer a similar length
    return score
}

@(private)
ascii_lower :: proc(b: u8) -> u8 {
    return b >= 'A' && b <= 'Z' ? b + 32 : b
}
