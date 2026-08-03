// Shared drivers for the engine tests: they call resolve directly, off the
// Manager's worker pool, so an analysis is exercised without threads.
package odin

import "core:os"
import "core:strings"

import lang ".."

// Resolves the identifier at the first occurrence of `needle` in `source` and
// returns the definition byte range the engine points at. Drives resolve
// directly (no threads) so the analysis is tested in isolation.
@(private)
resolve_def :: proc(e: ^Engine, source, needle: string, workspace := "") -> (lang.Location, bool) {
    at := strings.index(source, needle)
    if at < 0 {
        return {}, false
    }
    req := lang.Request {
        kind      = .Definition,
        path      = "buffer.odin",
        ext       = ".odin",
        source    = source,
        offset    = at,
        workspace = workspace,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    return res.location, res.ok
}

// Runs a Definition request at the first occurrence of `needle` and returns the
// whole result. Unlike resolve_def it keeps res.symbols, which is where a
// procedure group's members come back.
@(private)
definition_at :: proc(e: ^Engine, source, needle: string, workspace := "", path := "buffer.odin") -> lang.Result {
    req := lang.Request {
        kind      = .Definition,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = strings.index(source, needle),
        workspace = workspace,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    return res
}

// Frees a Definition result in either shape it comes back in: a lone jump target
// owns its path, a candidate set owns its rows.
@(private)
free_definition :: proc(res: ^lang.Result) {
    free_symbols(res)
    delete(res.location.path)
}

// Frees a symbol result's owned strings (the engine clones into context.allocator).
@(private)
free_symbols :: proc(res: ^lang.Result) {
    for sym in res.symbols {
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(sym.path)
    }
    delete(res.symbols)
}

@(private)
free_edits :: proc(res: ^lang.Result) {
    for edit in res.edits {
        delete(edit.path)
        delete(edit.old_text)
        delete(edit.new_text)
    }
    delete(res.edits)
}

// Runs a Rename request at the first occurrence of `needle` in `source`.
@(private)
rename_at :: proc(
    e: ^Engine,
    source, needle, new_name: string,
    workspace := "",
    path := "buffer.odin",
) -> lang.Result {
    req := lang.Request {
        kind      = .Rename,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = strings.index(source, needle),
        workspace = workspace,
        new_name  = new_name,
    }
    res := lang.Result{kind = .Rename}
    resolve(e, &req, &res)
    return res
}

// Runs a Code_Actions request at the first occurrence of `needle` in `source`.
@(private)
actions_at :: proc(e: ^Engine, source, needle: string, workspace := "", path := "buffer.odin") -> lang.Result {
    req := lang.Request {
        kind      = .Code_Actions,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = strings.index(source, needle),
        workspace = workspace,
    }
    res := lang.Result{kind = .Code_Actions}
    resolve(e, &req, &res)
    return res
}

@(private)
free_actions :: proc(res: ^lang.Result) {
    for action in res.actions {
        delete(action.title)
        delete(action.kind)
        for edit in action.edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(action.edits)
    }
    delete(res.actions)
}

// The offered action titled `title`, so a test names the fix it means rather than
// indexing into the offer order.
@(private)
find_action :: proc(res: ^lang.Result, title: string) -> (lang.Code_Action, bool) {
    for action in res.actions {
        if action.title == title {
            return action, true
        }
    }
    return {}, false
}

// `source` with an action's edits applied — back to front, so each edit's offsets
// still describe the text when its turn comes. Lets a test assert on the code the
// user would end up with instead of on raw ranges.
@(private)
apply_action :: proc(source: string, action: lang.Code_Action) -> string {
    out := strings.clone(source, context.temp_allocator)
    #reverse for edit in action.edits {
        out = strings.concatenate({out[:edit.start], edit.new_text, out[edit.end:]}, context.temp_allocator)
    }
    return out
}

// Reads the name-bearing slice at a reference symbol's offset from its file, so a
// test can assert the jump lands on the identifier. Buffer files (never written)
// won't read back; those are covered by the same-file assertions instead.
@(private)
src_at :: proc(sym: lang.Symbol) -> string {
    source, ok := source_read(sym.path)
    if !ok {
        return "helper" // buffer-only file; skip the on-disk check
    }
    return source[clamp(sym.offset, 0, len(source)):]
}

// Runs a Signature_Help request at `at` and returns the resolved signature.
@(private)
sig_help :: proc(e: ^Engine, source: string, at: int, workspace := "", path := "buffer.odin") -> (lang.Signature_Info, bool) {
    req := lang.Request {
        kind      = .Signature_Help,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = at,
        workspace = workspace,
    }
    res := lang.Result{kind = .Signature_Help}
    resolve(e, &req, &res)
    return res.signature, res.ok
}

// Frees a signature result. These tests build the Request by hand, so nothing
// calls the Manager's job_free for them and the entries are theirs to release.
@(private)
sig_free :: proc(sig: lang.Signature_Info) {
    for entry in sig.entries {
        delete(entry.label)
    }
    delete(sig.entries)
}

// The label of the entry the backend marked active and the text of the active
// parameter within it, so a test can assert both in one place. Empty strings when
// there is no entry or the entry reported no parameter span.
@(private)
sig_active :: proc(sig: lang.Signature_Info) -> (label, param: string) {
    if sig.active < 0 || sig.active >= len(sig.entries) {
        return "", ""
    }
    entry := sig.entries[sig.active]
    if entry.active_end <= entry.active_start || entry.active_end > len(entry.label) {
        return entry.label, ""
    }
    return entry.label, entry.label[entry.active_start:entry.active_end]
}

// True when some entry of the signature result carries `label`.
@(private)
sig_has :: proc(sig: lang.Signature_Info, label: string) -> bool {
    for entry in sig.entries {
        if entry.label == label {
            return true
        }
    }
    return false
}

// True when the completion result offers a candidate named `name`.
@(private)
has_completion :: proc(res: ^lang.Result, name: string) -> bool {
    for sym in res.symbols {
        if sym.name == name {
            return true
        }
    }
    return false
}

// Like resolve_def but with a caller-chosen file path, so a cross-file test can
// place the live buffer somewhere the symbol index will (correctly) exclude.
@(private)
resolve_in_ws :: proc(e: ^Engine, path, source, needle, workspace: string) -> (lang.Location, bool) {
    at := strings.index(source, needle)
    if at < 0 {
        return {}, false
    }
    req := lang.Request{kind = .Definition, path = path, ext = ".odin", source = source, offset = at, workspace = workspace}
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    return res.location, res.ok
}

// Resolves the definition at an absolute byte offset (member-access tests need
// the caret on the member of a `value.field`, not the first textual match).
@(private)
resolve_offset :: proc(e: ^Engine, source: string, at: int, workspace := "", path := "buffer.odin") -> (lang.Location, bool) {
    req := lang.Request{kind = .Definition, path = path, ext = ".odin", source = source, offset = at, workspace = workspace}
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    return res.location, res.ok
}

// Runs a completion request just past `needle` and returns the result, for the
// implicit-selector contexts (the caret sits right after the `.`).
@(private)
selector_completions :: proc(e: ^Engine, src, needle: string, res: ^lang.Result) {
    at := strings.index(src, needle) + len(needle)
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res^ = lang.Result{kind = .Completion}
    resolve(e, &req, res)
}
