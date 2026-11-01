package odin

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import lang ".."
import "../../shell"
import odinsema "sema"
import odinsyntax "syntax"

// The lines an oracle test writes to its report file.
@(private = "file", thread_local)
report: strings.Builder

// Appends one line to the report.
@(private = "file")
note :: proc(format: string, args: ..any) {
    fmt.sbprintf(&report, format, ..args)
    strings.write_byte(&report, '\n')
}

// Writes the report to `path` and logs where it is.
@(private = "file")
report_flush :: proc(path: string) {
    if os.write_entire_file(path, report.buf[:]) != nil {
        log.errorf("could not write %s", path)
    } else {
        log.infof("report: %s", path)
    }
    strings.builder_destroy(&report)
}

// Runs the tests that compare the live report with `odin check`. Off in CI.
LIVE_ORACLE :: #config(LIVE_ORACLE, false)
// Limits the oracle to the source directories that contain this text.
LIVE_ORACLE_ONLY :: #config(LIVE_ORACLE_ONLY, "")

ORACLE_ROOT :: "bin/test/oracle"
ORACLE_TIMEOUT :: 2 * time.Minute
// Most mutants per operator in one source directory.
ORACLE_PER_OP :: #config(LIVE_ORACLE_PER_OP, 8)
ORACLE_SEED :: #config(LIVE_ORACLE_SEED, 0x5eed_0d1)

@(private = "file")
Oracle_Op :: enum {
    Rename,
    Drop_Import,
    Misspell_Field,
    Extra_Arg,
    Drop_Arg,
    Wrong_Literal,
    Drop_Case,
    Drop_Return,
    Duplicate_Decl,
    Extra_Value,
    Dead_Stmt,
    Unused_Var,    // checked with -vet-unused-variables
    Shadow_Var,    // checked with -vet-shadowing
    Unused_Import, // checked with -vet-unused-imports
}

// The vet flag the compiler checks an operator with, and the id of the live item it gives.
@(private = "file")
op_vet :: proc(op: Oracle_Op) -> (flag: string, code: string) {
    #partial switch op {
    case .Unused_Var:    return "-vet-unused-variables", CODE_UNUSED_VAR
    case .Shadow_Var:    return "-vet-shadowing", CODE_SHADOWING
    case .Unused_Import: return "-vet-unused-imports", CODE_UNUSED_IMPORT
    }
    return "", ""
}

// True for a live item that is not an error of a compiler run with the flag of `op` alone.
@(private = "file")
not_compared :: proc(d: lang.Diagnostic, op: Oracle_Op) -> bool {
    _, code := op_vet(op)
    return d.lint || is_vet_code(d.code) && d.code != code
}

// One text edit of a valid file.
@(private = "file")
Mutation :: struct {
    op:         Oracle_Op,
    start, end: int,
    text:       string,
}

// A compiler diagnostic in the mutated file.
@(private = "file")
Oracle_Error :: struct {
    line:    int,
    message: string,
}

@(private = "file")
Op_Count :: struct {
    seeded, matched, silent: int,
    instance:                int, // every compiler error is in a polymorphic body, checked per instance
}

// A source directory and the directories it needs beside it, all relative to the repo root.
@(private = "file")
Oracle_Source :: struct {
    dir:  string,
    deps: []string,
}

// Repo packages the seeded suite mutates.
@(private = "file", rodata)
oracle_repo := []Oracle_Source {
    {dir = "vt"},
    {dir = "lang/odin/syntax"},
    {dir = "search"},
    {dir = "snippet"},
    {dir = "piecetable"},
    {dir = "lockfree"},
    {dir = "atomicfile"},
    {dir = "textedit", deps = {"piecetable"}},
}

// Odin root packages the seeded suite mutates.
@(private = "file", rodata)
oracle_core := []string {
    "core/strings",
    "core/slice",
    "core/path/slashpath",
    "core/encoding/json",
    "core/text/scanner",
    "core/container/small_array",
    "core/container/queue",
    "core/bytes",
    "core/unicode/utf8",
}

@(private = "file")
oracle_sources :: proc(allocator: mem.Allocator) -> []Oracle_Source {
    out := make([dynamic]Oracle_Source, allocator)
    append(&out, ..oracle_repo)
    root := odin_root_dir()
    for rel in oracle_core {
        append(&out, Oracle_Source{dir = path_join(allocator, root, rel)})
    }
    return out[:]
}

// The parts joined with `/`, which every platform's file API takes.
@(private = "file")
path_join :: proc(allocator: mem.Allocator, parts: ..string) -> string {
    return strings.join(parts, "/", allocator)
}

@(private = "file")
odin_root_dir :: proc() -> string {
    if v, found := os.lookup_env("ODIN_ROOT", context.temp_allocator); found && v != "" {
        return v
    }
    return ODIN_ROOT
}

// Where a source directory lands under ORACLE_ROOT: a repo path keeps its layout, an Odin root path goes under `odin/`.
@(private = "file")
oracle_dest :: proc(dir: string, allocator: mem.Allocator) -> string {
    if filepath.is_abs(dir) {
        if rel, err := filepath.rel(odin_root_dir(), dir, context.temp_allocator); err == nil && !strings.has_prefix(rel, "..") {
            return path_join(allocator, ORACLE_ROOT, "odin", rel)
        }
    }
    return path_join(allocator, ORACLE_ROOT, dir)
}

// Copies the `.odin` files of `src` that are not tests into `dst`, with LF line ends.
@(private = "file")
copy_package :: proc(src, dst: string) -> bool {
    files, err := odinsema.package_dir_files(src, context.temp_allocator)
    if err != nil {
        return false
    }
    if os.make_directory_all(dst) != nil {
        return false
    }
    for path in files {
        if strings.has_suffix(path, "_test.odin") {
            continue
        }
        data, ok := lang.source_read(path, context.temp_allocator)
        if !ok {
            return false
        }
        out := path_join(context.temp_allocator, dst, filepath.base(path))
        if os.write_entire_file(out, data) != nil {
            return false
        }
    }
    return true
}

// The errors `odin check` gives for the package in `dir`, and whether the compiler ran.
@(private = "file")
compiler_errors :: proc(dir: string, flags: ..string, allocator := context.temp_allocator) -> (errs: []Oracle_Error_At, ran: bool) {
    args := make([dynamic]string, context.temp_allocator)
    append(&args, "check", dir, "-no-entry-point", "-max-error-count:10000", "-terse-errors")
    for f in flags {
        if f != "" {
            append(&args, f)
        }
    }
    output, code, ok := shell.exec_status("odin", args[:], ".", ORACLE_TIMEOUT)
    defer delete(output)
    if !ok {
        return nil, false
    }
    out := make([dynamic]Oracle_Error_At, allocator)
    it := output
    for line in strings.split_lines_iterator(&it) {
        p, pok := parse_diagnostic_line(line)
        if !pok || p.severity != .Error {
            continue
        }
        append(&out, Oracle_Error_At{file = strings.clone(filepath.base(p.path), allocator), line = p.line, message = strings.clone(p.message, allocator)})
    }
    if code != 0 && len(out) == 0 {
        return nil, false
    }
    return out[:], true
}

@(private = "file")
Oracle_Error_At :: struct {
    file:    string,
    line:    int,
    message: string,
}

// The mutation sites of one file.
@(private = "file")
mutation_sites :: proc(src: string, out: ^[dynamic]Mutation) {
    parsed, err := odinsyntax.parse(src, context.temp_allocator)
    if err != nil || len(parsed.errors) > 0 {
        return
    }
    sites_walk(odinsyntax.node_root(parsed.tree), out)
}

// A block at the head of the body of `for v in x` that declares `v` again.
@(private = "file")
shadow_site :: proc(n: odinsyntax.Syntax_Node, out: ^[dynamic]Mutation) {
    r, _ := odinsyntax.as_range_stmt(n)
    vars, has_vars := odinsyntax.range_stmt_vars(&r)
    body, has_body := odinsyntax.range_stmt_body(&r)
    if !has_vars || !has_body || body.green.kind != .Block {
        return
    }
    it := odinsyntax.expr_list_items(&vars)
    first, ok := odinsyntax.child_iter_next(&it)
    if !ok || first.green.kind != .Ident || odinsyntax.node_text(first) == "_" {
        return
    }
    name := odinsyntax.node_text(first)
    at := int(body.offset) + 1
    append(out, Mutation{op = .Shadow_Var, start = at, end = at, text = fmt.tprintf(" {{ %s := 0; _ = %s }}; ", name, name)})
}

@(private = "file")
// Sites in a polymorphic procedure are left out: the compiler checks its body only per instance.
sites_walk :: proc(n: odinsyntax.Syntax_Node, out: ^[dynamic]Mutation) {
    n := n
    if poly_node(n) {
        return
    }
    start, end := odinsyntax.node_range(n)
    #partial switch n.green.kind {
    case .Package_Decl:
        append(out, Mutation{op = .Unused_Import, start = int(end), end = int(end), text = "\nimport zz_imp \"base:runtime\""})
    case .Import_Decl:
        if n.parent != nil && n.parent.green.kind == .Root {
            append(out, Mutation{op = .Drop_Import, start = int(start), end = int(end)})
        }
    case .Range_Stmt:
        shadow_site(n, out)
    case .Ident:
        if rename_site(n) {
            append(out, Mutation{op = .Rename, start = int(end), end = int(end), text = "_zq"})
        }
    case .Selector_Expr:
        sel, _ := odinsyntax.as_selector_expr(n)
        if field, ok := odinsyntax.selector_expr_field(&sel); ok {
            _, fend := odinsyntax.node_range(odinsyntax.Syntax_Node(field))
            append(out, Mutation{op = .Misspell_Field, start = int(fend), end = int(fend), text = "_zq"})
        }
    case .Call_Expr:
        call_sites(n, out)
    case .Literal:
        if literal_site(n) {
            append(out, Mutation{op = .Wrong_Literal, start = int(start), end = int(end), text = `"zq"`})
        }
    case .Switch_Stmt, .Type_Switch_Stmt:
        switch_site(n, out)
    case .Proc_Lit:
        return_site(n, out)
    case .Value_Decl:
        text := odinsyntax.node_text(n)
        if n.parent != nil && n.parent.green.kind == .Block && strings.contains(text, ":=") && !strings.contains(text, "\n") && !strings.has_prefix(text, "@") {
            append(out, Mutation{op = .Duplicate_Decl, start = int(end), end = int(end), text = strings.concatenate({"; ", text}, context.temp_allocator)})
        }
    case .Assign_Stmt:
        assign_site(n, out)
    case .Return_Stmt:
        if n.parent != nil && n.parent.green.kind == .Block {
            append(out, Mutation{op = .Dead_Stmt, start = int(end), end = int(end), text = "; _ = 0"})
            append(out, Mutation{op = .Unused_Var, start = int(start), end = int(start), text = "zz_unused := 0; "})
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        sites_walk(child, out)
    }
}

@(private = "file")
// A procedure or record with `$` parameters, which the compiler checks only per instance.
poly_node :: proc(n: odinsyntax.Syntax_Node) -> bool {
    #partial switch n.green.kind {
    case .Proc_Lit:
        pl, _ := odinsyntax.as_proc_lit(n)
        pt, ok := odinsyntax.proc_lit_type(&pl)
        return ok && strings.contains(odinsyntax.node_text(odinsyntax.Syntax_Node(pt)), "$")
    case .Struct_Type, .Union_Type:
        text := odinsyntax.node_text(n)
        if brace := strings.index_byte(text, '{'); brace >= 0 {
            text = text[:brace]
        }
        return strings.contains(text, "$")
    }
    return false
}

// A name read as a value: an operand, an argument or a callee.
@(private = "file")
rename_site :: proc(n: odinsyntax.Syntax_Node) -> bool {
    if n.parent == nil {
        return false
    }
    text := odinsyntax.node_text(n)
    if text == "_" || text == "nil" || text == "true" || text == "false" {
        return false
    }
    #partial switch n.parent.green.kind {
    case .Arg_List, .Binary_Expr, .Unary_Expr, .Paren_Expr, .Index_Expr, .Return_Stmt:
        return true
    case .Call_Expr:
        return n.offset == n.parent.offset
    case .Selector_Expr:
        return n.offset == n.parent.offset
    case .Expr_List:
        gp := n.parent.parent
        return gp != nil && (gp.green.kind == .Return_Stmt || gp.green.kind == .Assign_Stmt && n.parent.offset > gp.offset)
    }
    return false
}

// An integer literal or a bool written as an argument, an assigned value or a returned value.
@(private = "file")
literal_site :: proc(n: odinsyntax.Syntax_Node) -> bool {
    text := odinsyntax.node_text(n)
    if len(text) == 0 || text[0] < '0' || text[0] > '9' {
        return false
    }
    if n.parent == nil {
        return false
    }
    #partial switch n.parent.green.kind {
    case .Arg_List:
        return true
    case .Expr_List:
        gp := n.parent.parent
        return gp != nil && (gp.green.kind == .Return_Stmt || gp.green.kind == .Assign_Stmt && n.parent.offset > gp.offset)
    }
    return false
}

@(private = "file")
call_sites :: proc(n: odinsyntax.Syntax_Node, out: ^[dynamic]Mutation) {
    ce, _ := odinsyntax.as_call_expr(n)
    list, ok := odinsyntax.call_expr_args(&ce)
    if !ok {
        return
    }
    text := odinsyntax.node_text(odinsyntax.Syntax_Node(list))
    if !strings.has_suffix(text, ")") {
        return
    }
    args := make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator)
    it := odinsyntax.arg_list_args(&list)
    for a in odinsyntax.child_iter_next(&it) {
        append(&args, a)
    }
    _, lend := odinsyntax.node_range(odinsyntax.Syntax_Node(list))
    if len(args) == 0 {
        append(out, Mutation{op = .Extra_Arg, start = int(lend) - 1, end = int(lend) - 1, text = "0"})
        return
    }
    last := args[len(args) - 1]
    if last.green.kind == .Field_Value || last.green.kind == .Spread_Expr {
        return
    }
    _, aend := odinsyntax.node_range(last)
    append(out, Mutation{op = .Extra_Arg, start = int(aend), end = int(aend), text = ", 0"})
    from := int(last.offset)
    if len(args) > 1 {
        _, pend := odinsyntax.node_range(args[len(args) - 2])
        from = int(pend)
    }
    append(out, Mutation{op = .Drop_Arg, start = from, end = int(aend)})
}

@(private = "file")
switch_site :: proc(n: odinsyntax.Syntax_Node, out: ^[dynamic]Mutation) {
    if strings.has_prefix(odinsyntax.node_text(n), "#partial") {
        return
    }
    n := n
    body, ok := odinsyntax.find_child_node(&n, {kinds = {.Block}})
    if !ok {
        return
    }
    first: odinsyntax.Syntax_Node
    clauses := 0
    it := odinsyntax.child_iter(&body, {kinds = {.Case_Clause}})
    for clause in odinsyntax.child_iter_next(&it) {
        cl := odinsyntax.Case_Clause(clause)
        if _, has := odinsyntax.case_clause_values(&cl); !has {
            return
        }
        if clauses == 0 {
            first = clause
        }
        clauses += 1
    }
    if clauses < 2 {
        return
    }
    start, end := odinsyntax.node_range(first)
    append(out, Mutation{op = .Drop_Case, start = int(start), end = int(end)})
}

@(private = "file")
return_site :: proc(n: odinsyntax.Syntax_Node, out: ^[dynamic]Mutation) {
    pl, _ := odinsyntax.as_proc_lit(n)
    pt, ok := odinsyntax.proc_lit_type(&pl)
    if !ok {
        return
    }
    if _, has := odinsyntax.proc_type_results(&pt); !has {
        return
    }
    body, bok := odinsyntax.proc_lit_body(&pl)
    if !bok || body.green.kind != .Block {
        return
    }
    last: odinsyntax.Syntax_Node
    found := false
    blk := odinsyntax.Block(body)
    it := odinsyntax.block_stmts(&blk)
    for s in odinsyntax.child_iter_next(&it) {
        last = s
        found = true
    }
    if !found || last.green.kind != .Return_Stmt {
        return
    }
    start, end := odinsyntax.node_range(last)
    append(out, Mutation{op = .Drop_Return, start = int(start), end = int(end)})
}

@(private = "file")
assign_site :: proc(n: odinsyntax.Syntax_Node, out: ^[dynamic]Mutation) {
    as, _ := odinsyntax.as_assign_stmt(n)
    op, ok := odinsyntax.assign_stmt_op(&as)
    if !ok || odinsyntax.syntax_token_text(op) != "=" {
        return
    }
    lhs, lok := odinsyntax.assign_stmt_lhs(&as)
    rhs, rok := odinsyntax.assign_stmt_rhs(&as)
    if !lok || !rok {
        return
    }
    count :: proc(l: ^odinsyntax.Expr_List) -> int {
        k := 0
        it := odinsyntax.expr_list_items(l)
        for _ in odinsyntax.child_iter_next(&it) {
            k += 1
        }
        return k
    }
    if count(&lhs) != 1 || count(&rhs) != 1 {
        return
    }
    _, end := odinsyntax.node_range(odinsyntax.Syntax_Node(rhs))
    append(out, Mutation{op = .Extra_Value, start = int(end), end = int(end), text = ", 0"})
}

@(private = "file")
apply_mutation :: proc(src: string, m: Mutation) -> string {
    return strings.concatenate({src[:m.start], m.text, src[m.end:]}, context.temp_allocator)
}

@(private = "file")
line_of :: proc(src: string, offset: int) -> int {
    return strings.count(src[:offset], "\n") + 1
}

@(private = "file")
line_text :: proc(src: string, line: int) -> string {
    it := src
    k := 0
    for l in strings.split_lines_iterator(&it) {
        k += 1
        if k == line {
            return strings.trim_space(l)
        }
    }
    return ""
}

@(private = "file")
oracle_only :: proc(dir: string) -> bool {
    return LIVE_ORACLE_ONLY == "" || strings.contains(dir, LIVE_ORACLE_ONLY)
}

// The line ranges of the polymorphic procedures of `src`, which the compiler checks only per instance.
@(private = "file")
poly_ranges :: proc(src: string) -> [][2]int {
    parsed, err := odinsyntax.parse(src, context.temp_allocator)
    if err != nil {
        return nil
    }
    out := make([dynamic][2]int, context.temp_allocator)
    walk :: proc(n: odinsyntax.Syntax_Node, src: string, out: ^[dynamic][2]int) {
        n := n
        if poly_node(n) {
            start, end := odinsyntax.node_range(n)
            append(out, [2]int{line_of(src, int(start)), line_of(src, int(end))})
            return
        }
        it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
        for child in odinsyntax.child_iter_next(&it) {
            walk(child, src, out)
        }
    }
    walk(odinsyntax.node_root(parsed.tree), src, &out)
    return out[:]
}

@(private = "file")
in_ranges :: proc(ranges: [][2]int, line: int) -> bool {
    for r in ranges {
        if line >= r[0] && line <= r[1] {
            return true
        }
    }
    return false
}

// Checks one mutant with the compiler and the live report and counts the outcome.
@(private = "file")
run_mutant :: proc(t: ^testing.T, e: ^Engine, dest, path, src: string, m: Mutation, counts: ^[Oracle_Op]Op_Count, false_errors: ^int) {
    mutated := apply_mutation(src, m)
    if os.write_entire_file(path, mutated) != nil {
        testing.expectf(t, false, "%s: could not write", path)
        return
    }
    flag, _ := op_vet(m.op)
    errs, ran := compiler_errors(dest, flag)
    res := live_check(e, mutated, ORACLE_ROOT, path)
    defer free_live(&res)
    if os.write_entire_file(path, src) != nil {
        testing.fail_now(t, "could not restore a mutated file")
    }
    if !ran {
        note("NO RUN %v %s:%d `%s`", m.op, path, line_of(mutated, m.start), line_text(mutated, line_of(mutated, m.start)))
        return
    }
    name := filepath.base(path)
    first := -1
    lines := make(map[int]string, context.temp_allocator)
    messages := make(map[string]bool, context.temp_allocator)
    for x in errs {
        messages[strings.trim_space(x.message)] = true
        if x.file != name {
            continue
        }
        if first < 0 {
            first = x.line
        }
        if x.line not_in lines {
            lines[x.line] = x.message
        }
    }
    poly := poly_ranges(mutated)
    for d in res.report.items {
        if not_compared(d, m.op) {
            continue
        }
        // The compiler skips an expression whose operand an earlier error made invalid.
        if d.line not_in lines && d.message not_in messages && !in_ranges(poly, d.line) {
            false_errors^ += 1
            note("FALSE %v %s:%d `%s`: %s", m.op, path, d.line, line_text(mutated, d.line), d.message)
        }
    }
    if first < 0 {
        counts[m.op].silent += 1
        return
    }
    in_instance := true
    for line in lines {
        if !in_ranges(poly, line) {
            in_instance = false
        }
    }
    if in_instance {
        counts[m.op].instance += 1
        note("INSTANCE %v %s:%d (edit on %d) `%s`: %s", m.op, path, first, line_of(mutated, m.start), line_text(mutated, first), lines[first])
        return
    }
    counts[m.op].seeded += 1
    for d in res.report.items {
        if !not_compared(d, m.op) && d.line in lines {
            counts[m.op].matched += 1
            return
        }
    }
    native := len(res.report.items) > 0 ? res.report.items[0].message : "-"
    note("MISS %v %s:%d (edit on %d) `%s`: %s | native: %s", m.op, path, first, line_of(mutated, m.start), line_text(mutated, first), lines[first], native)
}

// Mutated valid files: the live report finds the error `odin check` finds, on its line, and no other.
@(test)
test_oracle_seeded :: proc(t: ^testing.T) {
    when !LIVE_ORACLE {
        log.info("skipped: needs -define:LIVE_ORACLE=true")
        return
    }
    _ = os.remove_all(ORACLE_ROOT)
    e := engine_create()
    defer engine_destroy(e)
    rng := rand.create(ORACLE_SEED)
    gen := rand.default_random_generator(&rng)
    arena: virtual.Arena
    if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) {
        return
    }
    defer virtual.arena_destroy(&arena)
    keep := virtual.arena_allocator(&arena)

    counts: [Oracle_Op]Op_Count
    false_errors := 0
    for source in oracle_sources(keep) {
        free_all(context.temp_allocator)
        if !oracle_only(source.dir) {
            continue
        }
        dest := oracle_dest(source.dir, keep)
        ok := copy_package(source.dir, dest)
        for dep in source.deps {
            ok = ok && copy_package(dep, oracle_dest(dep, context.temp_allocator))
        }
        if !testing.expectf(t, ok, "%s: could not copy", source.dir) {
            continue
        }
        if base, ran := compiler_errors(dest); !ran || len(base) > 0 {
            note("%s: skipped, the copy does not check clean (%d errors)", source.dir, len(base))
            continue
        }
        files, err := odinsema.package_dir_files(dest, context.temp_allocator)
        if !testing.expectf(t, err == nil, "%s: could not list", dest) {
            continue
        }
        // The copy as it is must give no live error.
        for path in files {
            src, rok := lang.source_read(path, context.temp_allocator)
            if !rok {
                continue
            }
            res := live_check(e, src, ORACLE_ROOT, path)
            poly := poly_ranges(src)
            for d in res.report.items {
                if !d.lint && !is_vet_code(d.code) && !in_ranges(poly, d.line) {
                    false_errors += 1
                    note("FALSE baseline %s:%d `%s`: %s", path, d.line, line_text(src, d.line), d.message)
                }
            }
            free_live(&res)
        }

        // Every site of the package by operator, then a fixed-seed sample of each.
        Site :: struct {
            path: string,
            src:  string,
            m:    Mutation,
        }
        by_op: [Oracle_Op][dynamic]Site
        for &list in by_op {
            list = make([dynamic]Site, context.temp_allocator)
        }
        for path in files {
            src, rok := lang.source_read(path, context.temp_allocator)
            if !rok {
                continue
            }
            raw, _ := os.read_entire_file(path, context.temp_allocator)
            if len(raw) != len(src) {
                continue // CRLF: offsets of the buffer and the disk file differ
            }
            sites := make([dynamic]Mutation, context.temp_allocator)
            mutation_sites(src, &sites)
            for m in sites {
                append(&by_op[m.op], Site{path, src, m})
            }
        }
        chosen := make([dynamic]Site, keep)
        for &list in by_op {
            rand.shuffle(list[:], gen)
            for site in list[:min(len(list), ORACLE_PER_OP)] {
                m := site.m
                m.text = strings.clone(m.text, keep)
                append(&chosen, Site{strings.clone(site.path, keep), strings.clone(site.src, keep), m})
            }
        }
        free_all(context.temp_allocator)
        for site in chosen {
            run_mutant(t, e, dest, site.path, site.src, site.m, &counts, &false_errors)
            free_all(context.temp_allocator)
        }
    }

    seeded, matched := 0, 0
    for c, op in counts {
        seeded += c.seeded
        matched += c.matched
        note("%-15v seeded %3d matched %3d (%5.1f%%) compiler silent %3d, in an instance %d", op, c.seeded, c.matched, 100 * f64(c.matched) / f64(max(c.seeded, 1)), c.silent, c.instance)
    }
    rate := 100 * f64(matched) / f64(max(seeded, 1))
    note("total: seeded %d matched %d (%.1f%%), false errors %d", seeded, matched, rate, false_errors)
    report_flush("bin/test/oracle_seeded.txt")
    testing.expect(t, seeded > 0, "no seeded error")
    testing.expectf(t, matched == seeded, "matched %.1f%%, want every seeded error", rate)
    testing.expect_value(t, false_errors, 0)
}

// Every package under base, core and vendor that `odin check` accepts gives no live error.
@(test)
test_oracle_clean_corpus :: proc(t: ^testing.T) {
    when !LIVE_ORACLE {
        log.info("skipped: needs -define:LIVE_ORACLE=true")
        return
    }
    arena: virtual.Arena
    if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) {
        return
    }
    defer virtual.arena_destroy(&arena)
    keep := virtual.arena_allocator(&arena)

    root := strings.clone(odin_root_dir(), keep)
    dirs := make([dynamic]string, keep)
    for top in ([]string{"base", "core", "vendor"}) {
        package_dirs(path_join(context.temp_allocator, root, top), &dirs, keep)
    }
    slice.sort(dirs[:])
    free_all(context.temp_allocator)

    e := engine_create()
    defer engine_destroy(e)
    target := odinsema.target_host()
    target.tests = false
    packages, files_checked, skipped, found, in_poly, lints, lines := 0, 0, 0, 0, 0, 0, 0
    vet_matched, vet_false, vet_missed := 0, 0, 0
    by_message := make(map[string]int, keep)
    for dir in dirs {
        if !oracle_only(dir) {
            continue
        }
        errs, ran := compiler_errors(dir)
        if !ran || len(errs) > 0 {
            skipped += 1
            free_all(context.temp_allocator)
            continue
        }
        packages += 1
        // What `-vet` adds to a clean package is its vet output, by file and line.
        vet_errs, vet_ran := compiler_errors(dir, "-vet", allocator = keep)
        vet_lines := make(map[Vet_Key]string, keep)
        if vet_ran {
            for x in vet_errs {
                vet_lines[Vet_Key{x.file, x.line}] = x.message
            }
        }
        vet_seen := make(map[Vet_Key]bool, keep)
        vet_dirs := make(map[string]string, keep) // file name -> path
        files, err := odinsema.package_dir_files(dir, keep)
        if err != nil {
            continue
        }
        for path in files {
            defer free_all(context.temp_allocator)
            if strings.has_suffix(path, "_test.odin") {
                continue
            }
            src, ok := lang.source_read(path, context.temp_allocator)
            if !ok {
                continue
            }
            parsed, perr := odinsyntax.parse(src, context.temp_allocator)
            if perr != nil {
                continue
            }
            items, ierr := odinsema.item_tree(parsed, context.temp_allocator)
            if ierr != nil {
                continue
            }
            in_build := odinsema.file_in_build(path, items.tags, target)
            odinsema.item_tree_destroy(items, context.temp_allocator)
            if !in_build {
                continue
            }
            res := live_check(e, src, root, path)
            defer free_live(&res)
            files_checked += 1
            lines += strings.count(src, "\n")
            poly := poly_ranges(src)
            for d in res.report.items {
                if is_vet_code(d.code) && d.code != CODE_DEAD_STORE {
                    key := Vet_Key{strings.clone(filepath.base(path), keep), d.line}
                    if key in vet_lines {
                        vet_matched += 1
                        vet_seen[key] = true
                    } else {
                        vet_false += 1
                        note("VET FALSE %s:%d:%d: %s", path, d.line, d.col, d.message)
                    }
                    continue
                }
                // A lint the compiler does not make: counted for the false-positive audit.
                if d.lint {
                    lints += 1
                    note("LINT %s:%d:%d: %s", path, d.line, d.col, d.message)
                    continue
                }
                // The compiler checks a polymorphic body only per instance, so it is silent there.
                if in_ranges(poly, d.line) {
                    in_poly += 1
                    note("POLY %s:%d:%d: %s", path, d.line, d.col, d.message)
                    continue
                }
                found += 1
                note("%s:%d:%d: %s", path, d.line, d.col, d.message)
                key := d.message
                if i := strings.index_byte(key, '\''); i >= 0 {
                    key = key[:i]
                }
                if key not_in by_message {
                    key = strings.clone(key, keep)
                }
                by_message[key] += 1
            }
            vet_dirs[strings.clone(filepath.base(path), keep)] = strings.clone(path, keep)
        }
        for key, message in vet_lines {
            // A file out of the build is not checked live.
            if vet_seen[key] || key.file not_in vet_dirs {
                continue
            }
            vet_missed += 1
            note("VET MISS %s:%d: %s", vet_dirs[key.file], key.line, message)
        }
    }
    for msg, n in by_message {
        note("%4d x %s", n, msg)
    }
    note("corpus: %d packages clean under odin check (%d skipped), %d files checked, %d live errors, %d in polymorphic bodies", packages, skipped, files_checked, found, in_poly)
    note("lints: %d over %d lines", lints, lines)
    note("vet: %d matched, %d false, %d missed", vet_matched, vet_false, vet_missed)
    report_flush("bin/test/oracle_corpus.txt")
    testing.expect(t, packages > 0, "no package checked")
    testing.expect_value(t, found, 0)
    testing.expect_value(t, vet_false, 0)
}

// A compiler line by file name and line.
@(private = "file")
Vet_Key :: struct {
    file: string,
    line: int,
}

// Appends every directory under `dir` that holds an `.odin` file.
@(private = "file")
package_dirs :: proc(dir: string, out: ^[dynamic]string, allocator: mem.Allocator) {
    handle, err := os.open(dir)
    if err != nil {
        return
    }
    defer os.close(handle)
    infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if rerr != nil {
        return
    }
    has_odin := false
    for info in infos {
        if info.type == .Directory {
            if info.name != "testdata" && !strings.has_prefix(info.name, ".") {
                package_dirs(strings.clone(info.fullpath, context.temp_allocator), out, allocator)
            }
        } else if strings.has_suffix(info.name, ".odin") {
            has_odin = true
        }
    }
    if has_odin {
        append(out, strings.clone(dir, allocator))
    }
}

