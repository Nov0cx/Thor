// Live vet warnings: the checks of the compiler's `-vet` set.
package odin

import "core:fmt"

import lang ".."
import odinsema "sema"

// The vet ids by check.
@(private, rodata)
VET_CODES := [odinsema.Vet_Flag]string {
    .Unused_Variables = CODE_UNUSED_VAR,
    .Unused_Imports   = CODE_UNUSED_IMPORT,
    .Shadowing        = CODE_SHADOWING,
    .Using_Stmt       = CODE_USING_STMT,
    .When_Shadowing   = CODE_WHEN_SHADOWING,
}

// The `-vet` set less the checks whose id the workspace config turns off.
@(private)
workspace_vet_flags :: proc(e: ^Engine, workspace: string) -> odinsema.Vet_Flags {
    flags := odinsema.VET_DEFAULT
    severities := config_severities(e, workspace)
    for code, flag in VET_CODES {
        if setting, ok := severities[code]; ok && setting == .Off {
            flags -= {flag}
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
}

@(private = "file")
unused_imports :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, whens: []Branch, report: ^lang.Diagnostic_Report) {
    imports := odinsema.db_imports(&rc.snap, rc.live.id)
    unused, err := odinsema.vet_unused_imports(rc.live.tree, imports, m, branch_spans(whens, false), context.temp_allocator)
    if err != nil {
        return
    }
    for i in unused {
        imp := imports[i]
        report_error(rc, report, imp.name_offset, CODE_UNUSED_IMPORT, fmt.aprintf("'%s' declared but not used", imp.alias), .Warning)
    }
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
