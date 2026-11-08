package odinsema

// What a bare `name` at `offset` of `file` names through a `using` in reach: a field of a `using`
// local or parameter or of a `using` statement operand, a member of an enum type a `using`
// statement names, or a declaration of a package it names. The nearest scope wins, and in one
// scope the last `using` before `offset`. False when no `using` gives the name, or a local named
// `name` is in a nearer scope.
using_lookup :: proc(c: ^Checker, file: File_Id, name: string, offset: int) -> (Operand, bool) {
    if name == "" || name == "_" || offset < 0 {
        return {}, false
    }
    m := scope_map_at(c, file, offset)
    if m == nil || !m.has_using {
        return {}, false
    }
    inner := innermost_scope(m, offset)
    if inner < 0 {
        return {}, false
    }
    depth := m.scopes[inner].proc_depth
    for s := inner; s >= 0; s = m.scopes[s].parent {
        if local_in_scope(m, s, name, offset, depth) {
            return {}, false
        }
        if m.scopes[s].proc_depth < depth {
            continue
        }
        below := max(int)
        for {
            pos, entry, local := last_using(m, s, offset, below)
            if pos < 0 {
                break
            }
            below = pos
            op: Operand
            if local >= 0 {
                op = using_member(c, {mode = .Value, type = decl_type(c, local_symbol(file, m.locals[local].name_offset))}, name)
            } else if n, ok := node_at(c, file, m.usings[entry].start); ok {
                op = using_member(c, expr_type(c, file, n), name)
            }
            if op.mode != .Invalid {
                return op, true
            }
        }
    }
    return {}, false
}

// The declaration the bare identifier at `offset` of `file` names through a `using`.
using_symbol :: proc(c: ^Checker, file: File_Id, offset: int) -> (Symbol, bool) {
    m := scope_map_at(c, file, offset)
    if m == nil || !m.has_using {
        return {}, false
    }
    ref, found := ref_at(m, offset)
    if !found || ref.is_decl || (ref.kind != .Free && ref.kind != .Local) {
        return {}, false
    }
    op, ok := using_lookup(c, file, ref.name, ref.start)
    return op.symbol, ok && op.has_symbol
}

// The innermost scope of `m` that holds `offset`; -1 when none does.
@(private = "file")
innermost_scope :: proc(m: ^Scope_Map, offset: int) -> int {
    inner := -1
    for s, i in m.scopes {
        if s.start <= offset && offset < s.end && (inner < 0 || s.start >= m.scopes[inner].start) {
            inner = i
        }
    }
    return inner
}

// True when scope `s` declares a local `name` that is in reach at `offset`.
@(private = "file")
local_in_scope :: proc(m: ^Scope_Map, s: int, name: string, offset, depth: int) -> bool {
    for l in m.locals {
        if l.scope != s || l.name != name || l.kind == .Label {
            continue
        }
        if !hoisted(l.kind) && (l.name_offset > offset || m.scopes[s].proc_depth < depth) {
            continue
        }
        return true
    }
    return false
}

// The last `using` of scope `s` that is in reach at `offset` and starts before `below`: its
// position and the index of its entry or of its local, the other -1. Position -1 when none.
@(private = "file")
last_using :: proc(m: ^Scope_Map, s, offset, below: int) -> (pos, entry, local: int) {
    pos, entry, local = -1, -1, -1
    for e, i in m.usings {
        if e.scope == s && e.end <= offset && e.start < below && e.start > pos {
            pos, entry, local = e.start, i, -1
        }
    }
    for l, i in m.locals {
        if l.scope == s && l.is_using && l.name_offset < offset && l.name_offset < below && l.name_offset > pos {
            pos, entry, local = l.name_offset, -1, i
        }
    }
    return
}

// The member `name` that `using` of an operand brings into scope.
@(private = "file")
using_member :: proc(c: ^Checker, op: Operand, name: string) -> Operand {
    #partial switch op.mode {
    case .Value, .Const:
        hit, ok := find_field(c, op.type, name)
        if !ok {
            return {}
        }
        out := Operand{mode = .Value, type = hit.type}
        if hit.name_offset >= 0 {
            out.symbol = field_symbol(c, hit.file, hit.name_offset)
            out.has_symbol = true
        }
        return out
    case .Type:
        if e, is_enum := type_get(&c.table, type_base(&c.table, op.type)).(Enum_Type); is_enum {
            for m in e.members {
                if m.name == name {
                    return member_operand(c, op.type, e.file, m)
                }
            }
        }
    case .Package:
        if sym, ok := member_lookup(c, op.dir, name, NO_FILE, true); ok {
            return item_operand(c, sym)
        }
    }
    return {}
}
