package odin

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import lang ".."

// Run from the repository root: odin test lang/odin

// The settings-driven admin gate: on by default, and handles claims nothing
// once it's turned off — the same "found nothing" contract lang.Manager
// enforces for a declined kind.
@(test)
test_engine_admin_gate :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    testing.expect(t, handles(e, ".odin"), "an enabled engine must claim .odin")
    testing.expect(t, !handles(e, ".txt"))

    engine_set_enabled(e, false)
    testing.expect(t, !handles(e, ".odin"), "a disabled engine must claim nothing")

    engine_set_enabled(e, true)
    testing.expect(t, handles(e, ".odin"), "re-enabling must let the engine claim .odin again")
}

// The per-kind gate: implemented kinds are on by default, and turning one off
// answers false for that kind alone.
@(test)
test_engine_feature_gate :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    testing.expect(t, supports(e, ".odin", .Format))
    testing.expect(t, supports(e, ".odin", .Diagnostics))

    engine_set_features(e, lang.FEATURES_ALL - {.Format})
    testing.expect(t, !supports(e, ".odin", .Format), "the declined kind must answer false")
    testing.expect(t, supports(e, ".odin", .Diagnostics), "an untouched kind must still be answered")

    engine_set_features(e, lang.FEATURES_ALL)
    testing.expect(t, supports(e, ".odin", .Format), "restoring the gate must let the kind through again")
}

// Kinds outside IMPLEMENTED are declined.
@(test)
test_engine_declines_unimplemented :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    testing.expect(t, supports(e, ".odin", .Format_Range))
    testing.expect(t, supports(e, ".odin", .Format_On_Type))
    testing.expect(t, supports(e, ".odin", .Hover))
    testing.expect(t, supports(e, ".odin", .Completion))
    testing.expect(t, supports(e, ".odin", .Signature_Help))
    testing.expect(t, supports(e, ".odin", .Semantic_Tokens))
    for kind in lang.Request_Kind {
        if kind not_in IMPLEMENTED {
            testing.expectf(t, !supports(e, ".odin", kind), "%v must be declined", kind)
        }
    }
}

@(private = "file")
free_symbols :: proc(res: ^lang.Result) {
    for sym in res.symbols {
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(sym.path)
    }
    delete(res.symbols)
}

@(private = "file")
symbol_names :: proc(res: ^lang.Result) -> []string {
    names := make([dynamic]string, context.temp_allocator)
    for sym in res.symbols {
        append(&names, sym.name)
    }
    return names[:]
}

// The outline lists each declaration in source order, its fields and members after it.
@(test)
test_document_symbols :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import "core:fmt"

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
    names := symbol_names(&res)
    want := []string{"Color", "Red", "Green", "Point", "x", "y", "MAX", "add"}
    kinds := []string{"enum", "enum_member", "enum_member", "type", "field", "field", "constant", "function"}
    testing.expectf(t, len(names) == len(want), "got %v, want %v", names, want)
    if len(names) != len(want) {
        return
    }
    for sym, i in res.symbols {
        testing.expect_value(t, sym.name, want[i])
        testing.expect_value(t, sym.kind, kinds[i])
        testing.expectf(t, strings.has_prefix(src[sym.offset:], sym.name), "%q offset %d misses its name", sym.name, sym.offset)
        testing.expectf(t, strings.has_prefix(sym.signature, sym.name), "%q signature %q", sym.name, sym.signature)
        testing.expect_value(t, sym.path, "buffer.odin")
    }
    testing.expect_value(t, res.symbols[0].line, 5)
    testing.expect_value(t, res.symbols[7].signature, "add :: proc(a: int, b: int) -> int")
    testing.expect_value(t, res.symbols[7].line, 17)
}

// The outline lists the procedures and types declared in a procedure body after that procedure.
@(test)
test_document_symbols_nested :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

outer :: proc() {
	Local :: struct {
		a: int,
	}
	inner :: proc() {
		deepest :: proc() -> int {
			return 1
		}
	}
	x := 1
}

last :: proc() {}
`
    req := lang.Request{kind = .Document_Symbols, path = "buffer.odin", ext = ".odin", source = src}
    res := lang.Result{kind = .Document_Symbols}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected a document symbols result")
    names := symbol_names(&res)
    want := []string{"outer", "Local", "a", "inner", "deepest", "last"}
    kinds := []string{"function", "type", "field", "function", "function", "function"}
    testing.expectf(t, slice.equal(names, want), "got %v, want %v", names, want)
    if len(names) != len(want) {
        return
    }
    for sym, i in res.symbols {
        testing.expect_value(t, sym.kind, kinds[i])
        testing.expectf(t, strings.has_prefix(src[sym.offset:], sym.name), "%q offset %d misses its name", sym.name, sym.offset)
    }
    testing.expect_value(t, res.symbols[4].signature, "deepest :: proc() -> int")
    testing.expect_value(t, res.symbols[4].line, 8)
}

// Workspace symbols: a declaration under a known-false `when` comes last and is marked inactive.
@(test)
test_workspace_symbols_inactive :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := "thor_lang_ws_inactive"
    _ = os.remove_all(root)
    defer os.remove_all(root)
    testing.expect_value(t, os.make_directory(root), nil)
    host_os := ODIN_OS == .Windows ? "Windows" : ODIN_OS == .Darwin ? "Darwin" : "Linux"
    other_os := ODIN_OS == .Windows ? "Linux" : "Windows"
    disk := strings.concatenate({"package app\n\nwhen ODIN_OS == .", other_os, " {\n\tapple :: proc() {}\n}\n\nzebra :: proc() {}\n"}, context.temp_allocator)
    disk_path := strings.concatenate({root, "/disk.odin"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(disk_path, transmute([]byte)disk), nil)

    req := lang.Request {
        kind      = .Workspace_Symbols,
        path      = strings.concatenate({root, "/live.odin"}, context.temp_allocator),
        ext       = ".odin",
        source    = strings.concatenate({"package app\n\nwhen ODIN_OS == .", host_os, " {\n\tbanana :: 1\n} else {\n\tcherry :: 2\n}\n"}, context.temp_allocator),
        workspace = root,
    }
    res := lang.Result{kind = .Workspace_Symbols}
    resolve(e, &req, &res)
    defer free_symbols(&res)
    testing.expect(t, res.ok, "expected a workspace symbols result")
    names := symbol_names(&res)
    want := []string{"banana", "zebra", "apple", "cherry"}
    testing.expectf(t, slice.equal(names, want), "got %v, want %v", names, want)
    if len(names) != len(want) {
        return
    }
    testing.expect_value(t, res.symbols[0].signature, "banana :: 1")
    testing.expect_value(t, res.symbols[1].signature, "zebra :: proc()")
    testing.expect_value(t, res.symbols[2].signature, "apple :: proc() (inactive)")
    testing.expect_value(t, res.symbols[3].signature, "cherry :: 2 (inactive)")
}

// Workspace symbols: the live buffer, the files on disk in the host build, filtered by the query.
@(test)
test_workspace_symbols :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := "thor_lang_ws_syms"
    _ = os.remove_all(root)
    defer os.remove_all(root)
    app := strings.concatenate({root, "/app"}, context.temp_allocator)
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    hidden := strings.concatenate({root, "/.git"}, context.temp_allocator)
    for dir in ([]string{root, app, lib, hidden}) {
        testing.expect_value(t, os.make_directory(dir), nil)
    }
    // A file of another OS is out of the host build.
    other_os := ODIN_OS == .Windows ? "linux" : "windows"
    files := [][2]string {
        {strings.concatenate({lib, "/thing.odin"}, context.temp_allocator), "package lib\n\nthing :: proc() {}\n"},
        {strings.concatenate({app, "/util.odin"}, context.temp_allocator), "package app\n\nUtil :: struct { inner: int }\n"},
        {strings.concatenate({app, "/main.odin"}, context.temp_allocator), "package app\n\nstale :: proc() {}\n"},
        {fmt.tprintf("%s/os_%s.odin", app, other_os), "package app\n\nforeign_os :: proc() {}\n"},
        {strings.concatenate({hidden, "/skip.odin"}, context.temp_allocator), "package skip\n\nskipped :: 1\n"},
    }
    for f in files {
        testing.expect_value(t, os.write_entire_file(f[0], transmute([]byte)f[1]), nil)
    }

    // The live buffer stands in for main.odin on disk.
    req := lang.Request {
        kind      = .Workspace_Symbols,
        path      = files[2][0],
        ext       = ".odin",
        source    = "package app\n\nlive :: proc() {}\n",
        workspace = root,
    }
    res := lang.Result{kind = .Workspace_Symbols}
    resolve(e, &req, &res)
    testing.expect(t, res.ok, "expected a workspace symbols result")
    names := symbol_names(&res)
    want := []string{"Util", "live", "thing"}
    testing.expectf(t, slice.equal(names, want), "got %v, want %v", names, want)
    free_symbols(&res)

    // The query keeps the names that hold its letters in order, case-insensitive.
    req.query = "tg"
    res = lang.Result{kind = .Workspace_Symbols}
    resolve(e, &req, &res)
    names = symbol_names(&res)
    testing.expectf(t, slice.equal(names, []string{"thing"}), "query tg: got %v", names)
    free_symbols(&res)

    // A changed file is read again.
    testing.expect_value(t, os.write_entire_file(files[0][0], transmute([]byte)string("package lib\n\nthing_two :: proc() {}\n")), nil)
    req.query = "thing"
    res = lang.Result{kind = .Workspace_Symbols}
    resolve(e, &req, &res)
    names = symbol_names(&res)
    testing.expectf(t, slice.equal(names, []string{"thing_two"}), "after the edit: got %v", names)
    free_symbols(&res)
}
