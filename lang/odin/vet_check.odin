// Live vet warnings: the checks of the compiler's `-vet` set.
package odin

import "core:fmt"
import "core:mem"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// The vet ids by check.
@(private, rodata)
VET_CODES := [odinsema.Vet_Flag]string {
    .Unused_Variables = CODE_UNUSED_VAR,
    .Unused_Imports   = CODE_UNUSED_IMPORT,
    .Shadowing        = CODE_SHADOWING,
    .Using_Stmt       = CODE_USING_STMT,
    .When_Shadowing   = CODE_WHEN_SHADOWING,
    .Cast             = CODE_CAST,
    .Unused_Procedures = CODE_UNUSED_PROC,
    .Style            = CODE_STYLE,
    .Semicolon        = CODE_SEMICOLON,
    .Tabs             = CODE_TABS,
}

// The `-vet` set less the checks whose id the workspace config turns off, plus the opt-in checks whose
// id it sets to anything but off.
@(private)
workspace_vet_flags :: proc(e: ^Engine, workspace: string) -> odinsema.Vet_Flags {
    flags := odinsema.VET_DEFAULT
    severities := config_severities(e, workspace)
    for code, flag in VET_CODES {
        setting, ok := severities[code]
        switch {
        case ok && setting == .Off:
            flags -= {flag}
        case ok && flag in odinsema.VET_OPT_IN:
            flags += {flag}
        }
    }
    return flags
}

// The checks that apply to the request's buffer: the workspace set with its `#+vet` tags.
@(private)
live_vet_flags :: proc(rc: ^Request_Context) -> odinsema.Vet_Flags {
    return odinsema.file_vet_flags(rc.live.tree, workspace_vet_flags(rc.e, rc.req.workspace))
}

// Appends the vet warnings that need no types: unused imports, shadowing and declarations in a
// file-scope `when` that shadow a builtin.
@(private)
vet_diagnostics :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, whens: []Branch, report: ^lang.Diagnostic_Report) {
    if !rc.live.in_build {
        return
    }
    flags := live_vet_flags(rc)
    if .Unused_Imports in flags {
        unused_imports(rc, m, whens, report)
    }
    if .Shadowing in flags {
        shadowing(rc, m, whens, report)
    }
    if .When_Shadowing in flags {
        when_shadowing(rc, whens, report)
    }
    syntax_vet(rc, flags, report)
    if .Unused_Procedures in flags {
        unused_procedures(rc, whens, report)
    }
}

// Reports the file-scope procedures that no identifier of their package names.
@(private = "file")
unused_procedures :: proc(rc: ^Request_Context, whens: []Branch, report: ^lang.Diagnostic_Report) {
    view := request_package(rc, live_dir(rc))
    if view == nil || rc.live.tree == nil {
        return
    }
    cands, err := odinsema.vet_unused_candidates(rc.live.tree, context.temp_allocator)
    if err != nil || len(cands) == 0 {
        return
    }
    names := make(map[string]int, len(cands), context.temp_allocator)
    decls := make([dynamic]int, context.temp_allocator)
    for i in cands {
        item := rc.live.tree.items[i]
        names[item.name] = i
        append(&decls, item.name_offset)
    }
    used := make(map[string]struct{}, len(cands), context.temp_allocator)
    if odinsema.vet_note_names(rc.parsed.tree.text, names, &used, decls[:]) != nil {
        return
    }
    for id in view.files {
        if id == rc.live.id {
            continue
        }
        if odinsema.snapshot_cancelled(&rc.snap) {
            return
        }
        parsed := odinsema.db_parse(&rc.snap, id)
        if parsed == nil {
            // A file that cannot be read may name the procedure.
            return
        }
        failed := odinsema.vet_note_names(parsed.tree.text, names, &used, nil) != nil
        odinsema.db_parse_release(&rc.snap, parsed)
        if failed {
            return
        }
    }
    for i in cands {
        item := rc.live.tree.items[i]
        if item.name in used || in_untaken_branch(whens, item.name_offset) {
            continue
        }
        report_error(rc, report, item.name_offset, CODE_UNUSED_PROC, fmt.aprintf("'%s' declared but not used", item.name), .Warning)
    }
}

// Appends the vet warnings of the syntax: unneeded semicolons, indentation with spaces and a missing
// trailing comma.
@(private = "file")
syntax_vet :: proc(rc: ^Request_Context, flags: odinsema.Vet_Flags, report: ^lang.Diagnostic_Report) {
    if .Semicolon in flags {
        report_offsets(rc, odinsema.vet_semicolons, CODE_SEMICOLON, "Found unneeded semicolon", report)
    }
    if .Tabs in flags {
        report_offsets(rc, odinsema.vet_tabs, CODE_TABS, "With '-vet-tabs', tabs must be used for indentation", report)
    }
    if .Style in flags {
        report_offsets(rc, odinsema.vet_style, CODE_STYLE, "Expected a comma, got a newline", report)
    }
}

@(private = "file")
report_offsets :: proc(rc: ^Request_Context, find: proc(parsed: odinsyntax.Parse, allocator := context.allocator) -> (out: [dynamic]int, err: mem.Allocator_Error), code, message: string, report: ^lang.Diagnostic_Report) {
    offsets, err := find(rc.parsed, context.temp_allocator)
    if err != nil {
        return
    }
    for at in offsets {
        report_error(rc, report, at, code, strings.clone(message), .Warning)
    }
}

@(private = "file")
unused_imports :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, whens: []Branch, report: ^lang.Diagnostic_Report) {
    imports := odinsema.db_imports(&rc.snap, rc.live.id)
    dead := branch_spans(whens, false)
    unused, err := odinsema.vet_unused_imports(rc.live.tree, imports, m, dead, context.temp_allocator)
    if err != nil {
        return
    }
    unused = poly_unused_imports(rc, m, imports, dead, unused)
    for i in unused {
        imp := imports[i]
        report_error(rc, report, imp.name_offset, CODE_UNUSED_IMPORT, fmt.aprintf("'%s' declared but not used", imp.alias), .Warning)
    }
}

// The unused imports when the polymorphic bodies the package does not instantiate are left out,
// as the compiler checks such a body only per instance. `unused` when no import is used only there.
@(private = "file")
poly_unused_imports :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, imports: []odinsema.File_Import, dead: []odinsema.Offset_Span, unused: [dynamic]int) -> [dynamic]int {
    own, err := odinsema.poly_file(rc.parsed, context.temp_allocator)
    if err != nil || len(own.bodies) == 0 {
        return unused
    }
    all := make([dynamic]odinsema.Offset_Span, context.temp_allocator)
    append(&all, ..dead)
    for b in own.bodies {
        append(&all, b.span)
    }
    most, merr := odinsema.vet_unused_imports(rc.live.tree, imports, m, all[:], context.temp_allocator)
    if merr != nil || len(most) == len(unused) {
        return unused
    }
    view := request_package(rc, live_dir(rc))
    if view == nil {
        return unused
    }
    files := make([dynamic]odinsema.Poly_File, context.temp_allocator)
    // The names of a Poly_File borrow its parse, so each parse stays pinned to the end.
    pinned := make([dynamic]^odinsyntax.Parse, context.temp_allocator)
    defer for p in pinned {
        odinsema.db_parse_release(&rc.snap, p)
    }
    live := -1
    for id in view.files {
        if odinsema.snapshot_cancelled(&rc.snap) {
            return unused
        }
        if id == rc.live.id {
            live = len(files)
            append(&files, own)
            continue
        }
        if !odinsema.db_in_build(&rc.snap, id) {
            continue
        }
        parsed := odinsema.db_parse(&rc.snap, id)
        if parsed == nil {
            // A file that cannot be read may hold the instance.
            return unused
        }
        append(&pinned, parsed)
        f, ferr := odinsema.poly_file(parsed^, context.temp_allocator)
        if ferr != nil {
            return unused
        }
        append(&files, f)
    }
    if live < 0 {
        live = len(files)
        append(&files, own)
    }
    spans, serr := odinsema.poly_uninstantiated(files[:], context.temp_allocator)
    if serr != nil || len(spans[live]) == 0 {
        return unused
    }
    resize(&all, len(dead))
    append(&all, ..spans[live])
    out, oerr := odinsema.vet_unused_imports(rc.live.tree, imports, m, all[:], context.temp_allocator)
    if oerr != nil {
        return unused
    }
    return out
}

@(private = "file")
shadowing :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, whens: []Branch, report: ^lang.Diagnostic_Report) {
    shadows, err := odinsema.vet_shadowing(m, rc.parsed, rc.live.tree, branch_spans(whens, true), context.temp_allocator)
    if err != nil {
        return
    }
    c := request_checker(rc)
    if c == nil {
        return
    }
    for s in shadows {
        if !same_type(c, rc.live.id, s) {
            continue
        }
        line, _ := offset_line_col(rc.live.lines, s.shadowed)
        report_error(rc, report, s.offset, CODE_SHADOWING, fmt.aprintf("Declaration of '%s' shadows declaration at line %d", s.name, line), .Warning)
    }
    usings, uerr := odinsema.vet_using_shadowing(c, rc.live.id, m, rc.parsed, rc.live.tree, branch_spans(whens, true), context.temp_allocator)
    if uerr != nil {
        return
    }
    for s in usings {
        line, _ := offset_line_col(rc.live.lines, s.shadowed)
        report_error(rc, report, s.offset, CODE_SHADOWING, fmt.aprintf("Declaration of '%s' from 'using' shadows declaration at line %d", s.field, line), .Warning)
    }
}

// True when the shadowing variable has the type of the one it shadows, the one case the compiler
// reports. A type-switch variable has the type of each case clause.
@(private = "file")
same_type :: proc(c: ^odinsema.Checker, file: odinsema.File_Id, s: odinsema.Vet_Shadow) -> bool {
    own: []odinsema.Type_Id
    if s.kind == .Switch_Var {
        own = odinsema.switch_var_types(c, file, s.offset, -1, context.temp_allocator)
    } else {
        own = one_type(odinsema.decl_type(c, odinsema.local_symbol(file, s.offset)))
    }
    other: []odinsema.Type_Id
    switch {
    case s.item >= 0:
        other = one_type(odinsema.decl_type(c, odinsema.Symbol{file = file, item = i32(s.item), child = -1}))
    case s.shadowed_kind == .Switch_Var:
        other = odinsema.switch_var_types(c, file, s.shadowed, s.offset, context.temp_allocator)
    case:
        other = one_type(odinsema.decl_type(c, odinsema.local_symbol(file, s.shadowed)))
    }
    for a in own {
        for b in other {
            if a != odinsema.INVALID_TYPE && a == b {
                return true
            }
        }
    }
    return false
}

@(private = "file")
one_type :: proc(t: odinsema.Type_Id) -> []odinsema.Type_Id {
    out := make([]odinsema.Type_Id, 1, context.temp_allocator)
    out[0] = t
    return out
}

@(private = "file")
when_shadowing :: proc(rc: ^Request_Context, whens: []Branch, report: ^lang.Diagnostic_Report) {
    for item in rc.live.tree.items {
        if item.guard < 0 || item.name == "_" || item.kind == .Import || item.kind == .Foreign_Import || in_untaken_branch(whens, item.name_offset) {
            continue
        }
        cands := make([dynamic]Def_Candidate, context.temp_allocator)
        if builtin_candidates(rc, item.name, &cands) == "" {
            continue
        }
        report_error(rc, report, item.name_offset, CODE_WHEN_SHADOWING, fmt.aprintf("Declaration of '%s' within a global 'when' shadows the builtin '%s'", item.name, item.name), .Warning)
    }
}

// The ranges of the `when` branches the target surely does not take, or with `unsure` also the ones
// it may not take.
@(private)
branch_spans :: proc(whens: []Branch, unsure: bool) -> []odinsema.Offset_Span {
    out := make([dynamic]odinsema.Offset_Span, context.temp_allocator)
    for w in whens {
        if w.state == .False || (unsure && w.state != .True) {
            append(&out, odinsema.Offset_Span{w.start, w.end})
        }
    }
    return out[:]
}
