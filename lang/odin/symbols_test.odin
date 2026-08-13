// Document and workspace symbol outlines, rename, and the symbol index's
// freshness across edits. The reference scan has its own file.
package odin

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import lang ".."

@(test)
test_document_symbols :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Top-level procs, a struct, an enum and a constant belong in the outline;
    // parameters, struct fields and locals do not. The package name is excluded.
    src := `package demo

Color :: enum {
	Red,
	Green,
}

Point :: struct {
	x: int,
	y: int,
}

MAX :: 100

add :: proc(a: int, b: int) -> int {
	sum := a + b
	return sum
}
`
    req := lang.Request{kind = .Document_Symbols, path = "buffer.odin", ext = ".odin", source = src}
    res := lang.Result{kind = .Document_Symbols}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected a document symbols result")

    // Exactly the four top-level declarations, in source order.
    names := make([dynamic]string, context.temp_allocator)
    for sym in res.symbols {
        append(&names, sym.name)
    }
    want := []string{"Color", "Point", "MAX", "add"}
    testing.expectf(t, len(names) == len(want), "symbol count: got %d %v, want %d", len(names), names[:], len(want))
    if len(names) == len(want) {
        for name, i in want {
            testing.expectf(t, names[i] == name, "symbol %d: got %q, want %q", i, names[i], name)
        }
    }

    // Each symbol's offset points at its declared identifier, and the signature
    // is the real Odin declaration line (name :: type), carrying its file/line.
    for sym in res.symbols {
        testing.expectf(
            t,
            strings.has_prefix(src[sym.offset:], sym.name),
            "symbol %q offset %d does not land on its name", sym.name, sym.offset,
        )
        testing.expectf(
            t,
            strings.has_prefix(sym.signature, sym.name),
            "symbol %q signature %q should start with the name", sym.name, sym.signature,
        )
        testing.expectf(t, sym.path == "buffer.odin", "symbol %q path: got %q", sym.name, sym.path)
        testing.expectf(t, sym.line > 0, "symbol %q line: got %d", sym.name, sym.line)
    }

    // The proc's signature is the real Odin type, not a "function" tag.
    for sym in res.symbols {
        if sym.name == "add" {
            testing.expectf(t, sym.signature == "add :: proc(a: int, b: int) -> int", "add signature: got %q", sym.signature)
        }
    }
}

@(test)
test_workspace_symbols :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Two packages under a workspace, each with a top-level symbol on disk, plus
    // the live buffer's own symbol. Workspace symbols must gather all three.
    root := "thor_lang_ws_syms"
    app := strings.concatenate({root, "/app"}, context.temp_allocator)
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(app)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/thing.odin"}, context.temp_allocator)
    lib_src := "package lib\n\nthing :: proc() {}\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)
    other := strings.concatenate({app, "/util.odin"}, context.temp_allocator)
    other_src := "package app\n\nUtil :: struct {}\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)

    // Declared dirs-first so LIFO removes the files before their directories.
    defer os.remove(root)
    defer os.remove(app)
    defer os.remove(lib)
    defer os.remove(lib_path)
    defer os.remove(other)

    // The live buffer (never written) contributes `live`; its path is skipped on disk.
    main_path := strings.concatenate({app, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nlive :: proc() {}\n"

    req := lang.Request {
        kind      = .Workspace_Symbols,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        workspace = root,
    }
    res := lang.Result{kind = .Workspace_Symbols}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected a workspace symbols result")

    has :: proc(res: ^lang.Result, name: string) -> bool {
        for sym in res.symbols {
            if sym.name == name {
                return true
            }
        }
        return false
    }
    testing.expect(t, has(&res, "thing"), "workspace symbols missing on-disk lib.thing")
    testing.expect(t, has(&res, "Util"), "workspace symbols missing on-disk app.Util")
    testing.expect(t, has(&res, "live"), "workspace symbols missing the live buffer's symbol")

    // Sorted by name: Util, live, thing (capitals sort before lowercase in ASCII).
    testing.expectf(t, len(res.symbols) == 3, "symbol count: got %d", len(res.symbols))
}

@(test)
test_rename_local_scope :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Rename inherits find-references' scoping: renaming `total` in `use` edits
    // the declaration and its two uses there, never `other`'s same-named local.
    src := `package demo

use :: proc() -> int {
	total := 1
	return total + total
}

other :: proc() -> int {
	total := 9
	return total
}
`
    res := rename_at(e, src, "total :=", "sum")
    defer free_edits(&res)

    testing.expect(t, res.ok, "expected rename edits for the local total")
    testing.expectf(t, len(res.edits) == 3, "local rename edit count: got %d", len(res.edits))

    use_end := strings.index(src, "other ::")
    for edit in res.edits {
        testing.expectf(t, src[edit.start:edit.end] == "total", "edit %d..%d not over the name", edit.start, edit.end)
        testing.expectf(t, edit.old_text == "total", "old_text: got %q", edit.old_text)
        testing.expectf(t, edit.new_text == "sum", "new_text: got %q", edit.new_text)
        testing.expectf(t, edit.start < use_end, "edit at %d leaked past use's body", edit.start)
    }

    // Applying the edits front-to-back must produce a buffer that renames only
    // `use`'s local — the shape the editor splices into a file.
    b := strings.builder_make(context.temp_allocator)
    last := 0
    for edit in res.edits {
        strings.write_string(&b, src[last:edit.start])
        strings.write_string(&b, edit.new_text)
        last = edit.end
    }
    strings.write_string(&b, src[last:])
    out := strings.to_string(b)
    testing.expect(t, strings.contains(out, "sum := 1"), "declaration not renamed")
    testing.expect(t, strings.contains(out, "return sum + sum"), "uses not renamed")
    testing.expect(t, strings.contains(out, "total := 9"), "other's local must not be renamed")
}

@(test)
test_rename_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A top-level symbol is renamed across the workspace: the live buffer's
    // declaration plus its call, and both calls in the sibling on disk.
    dir := "thor_lang_rename_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    other := strings.concatenate({dir, "/use.odin"}, context.temp_allocator)
    other_src := "package demo\n\nrun :: proc() {\n\t_ = helper()\n\t_ = helper()\n}\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)
    defer os.remove(other)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    res := rename_at(e, main_src, "helper ::", "assist", workspace = dir, path = main_path)
    defer free_edits(&res)

    testing.expect(t, res.ok, "expected cross-file rename edits")
    testing.expectf(t, len(res.edits) == 4, "cross-file rename edit count: got %d", len(res.edits))

    in_main, in_other := 0, 0
    for edit in res.edits {
        testing.expectf(t, edit.old_text == "helper", "old_text: got %q", edit.old_text)
        testing.expectf(t, edit.end - edit.start == len("helper"), "edit span: got %d", edit.end - edit.start)
        if strings.has_suffix(edit.path, "main.odin") {
            in_main += 1
            testing.expectf(t, main_src[edit.start:edit.end] == "helper", "buffer edit %d off the name", edit.start)
        }
        if strings.has_suffix(edit.path, "use.odin") {
            in_other += 1
            testing.expectf(t, other_src[edit.start:edit.end] == "helper", "sibling edit %d off the name", edit.start)
        }
    }
    testing.expectf(t, in_main == 2, "edits in main.odin: got %d", in_main)
    testing.expectf(t, in_other == 2, "edits in use.odin: got %d", in_other)

    // No file was touched: the engine only reports edits, the editor applies them.
    on_disk, rerr := os.read_entire_file(other, context.temp_allocator)
    testing.expect(t, rerr == nil, "sibling should still be readable")
    testing.expect(t, string(on_disk) == other_src, "the engine must not write files itself")
}

@(test)
test_rename_rejects_bad_names :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nuse :: proc() -> int {\n\ttotal := 1\n\treturn total\n}\n"

    for bad in ([?]string{"", "  ", "2fast", "has space", "with-dash", "proc", "int", "total"}) {
        res := rename_at(e, src, "total :=", bad)
        defer free_edits(&res)
        testing.expectf(t, !res.ok && len(res.edits) == 0, "%q should not be a rename target", bad)
    }

    // A leading underscore is a legal identifier and must be accepted.
    ok_res := rename_at(e, src, "total :=", "_total")
    defer free_edits(&ok_res)
    testing.expect(t, ok_res.ok, "_total should be a legal rename target")
}

@(test)
test_index_reflects_file_change :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A workspace whose only on-disk file declares `helper`. The first cross-file
    // goto builds the index; a later goto (same engine) must reflect an edit to
    // that file rather than serving the decls it parsed the first time.
    dir := "thor_lang_index_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    helper := strings.concatenate({dir, "/helper.odin"}, context.temp_allocator)
    v1_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 1\n}\n"
    _ = os.write_entire_file(helper, transmute([]byte)v1_src)
    defer os.remove(helper)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    // First query: builds the index and resolves across files.
    loc, ok := resolve_in_ws(e, main_path, main_src, "helper()", dir)
    defer delete(loc.path)
    testing.expect(t, ok, "expected to resolve helper on the first query")

    // Rewrite the file so `helper` becomes `renamed`; the size changes, so the
    // stat-based validation re-parses it on the next query.
    v2_src := "package demo\n\nrenamed :: proc() -> int {\n\treturn 1\n}\n"
    _ = os.write_entire_file(helper, transmute([]byte)v2_src)

    // The old name is gone from the index...
    stale_loc, still := resolve_in_ws(e, main_path, main_src, "helper()", dir)
    defer delete(stale_loc.path)
    testing.expect(t, !still, "helper should no longer resolve after the file changed")

    // ...and the new name resolves into the same file, proving the re-parse.
    new_src := "package demo\n\nmain :: proc() {\n\t_ = renamed()\n}\n"
    loc2, ok2 := resolve_in_ws(e, main_path, new_src, "renamed()", dir)
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected to resolve renamed after the file changed")
    if ok2 {
        testing.expect(t, strings.has_suffix(loc2.path, "helper.odin"), "renamed should resolve into helper.odin")
    }
}

// Workspace symbols answer only what matches req.query; an empty query still
// answers everything, which is the shape of the first, pre-typing dispatch.
@(test)
test_workspace_symbols_filters_on_query :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nAlpha :: proc() {}\nBeta :: proc() {}\nGamma :: proc() {}\n"

    all := workspace_symbols_for(e, src, "")
    defer free_symbols(&all)
    testing.expectf(t, len(all.symbols) == 3, "empty query must answer everything, got %d", len(all.symbols))

    hit := workspace_symbols_for(e, src, "bet")
    defer free_symbols(&hit)
    testing.expectf(t, len(hit.symbols) == 1, "expected only Beta, got %d", len(hit.symbols))
    if len(hit.symbols) == 1 {
        testing.expect_value(t, hit.symbols[0].name, "Beta")
    }

    none := workspace_symbols_for(e, src, "zzz")
    defer free_symbols(&none)
    testing.expectf(t, len(none.symbols) == 0, "a query nothing matches must answer nothing, got %d", len(none.symbols))
}

// Document symbols share collect_symbols_into and must stay unfiltered.
@(test)
test_document_symbols_ignore_query :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nAlpha :: proc() {}\nBeta :: proc() {}\n"
    req := lang.Request {
        kind   = .Document_Symbols,
        path   = "buffer.odin",
        ext    = ".odin",
        source = src,
        query  = "zzz",
    }
    res := lang.Result{kind = .Document_Symbols}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expectf(t, len(res.symbols) == 2, "an outline must ignore query, got %d", len(res.symbols))
}

@(private = "file")
workspace_symbols_for :: proc(e: ^Engine, source, query: string) -> lang.Result {
    req := lang.Request {
        kind   = .Workspace_Symbols,
        path   = "buffer.odin",
        ext    = ".odin",
        source = source,
        query  = query,
    }
    res := lang.Result{kind = .Workspace_Symbols}
    resolve(e, &req, &res)
    return res
}
