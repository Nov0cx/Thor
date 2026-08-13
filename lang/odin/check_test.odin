package odin

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import lang ".."
import "../../shell"

// Parsing of `odin check` output lines into diagnostics, plus one end-to-end run
// against the real compiler. From the repository root: odin test lang/odin

@(test)
test_parse_error_line :: proc(t: ^testing.T) {
    // A Windows absolute path (note the drive-letter colon, which the parser must
    // not mistake for the line:col colon).
    line := `D:\thor\thor\thor.odin(42:9) Error: 'foo' undeclared`
    p, ok := parse_diagnostic_line(line)
    testing.expect(t, ok, "should parse an error line")
    testing.expect_value(t, p.path, `D:\thor\thor\thor.odin`)
    testing.expect_value(t, p.line, 42)
    testing.expect_value(t, p.col, 9)
    testing.expect(t, p.severity == lang.Diagnostic_Severity.Error, "severity should be error")
    testing.expect_value(t, p.message, "'foo' undeclared")
}

@(test)
test_parse_warning_and_syntax :: proc(t: ^testing.T) {
    w, wok := parse_diagnostic_line(`pkg/file.odin(3:1) Warning: unused import`)
    testing.expect(t, wok, "should parse a warning line")
    testing.expect(t, w.severity == lang.Diagnostic_Severity.Warning, "severity should be warning")

    s, sok := parse_diagnostic_line(`pkg/file.odin(10:20) Syntax Error: expected ';'`)
    testing.expect(t, sok, "should parse a syntax error line")
    testing.expect(t, s.severity == lang.Diagnostic_Severity.Error, "syntax error maps to error")
    testing.expect_value(t, s.message, "expected ';'")
}

@(test)
test_parse_rejects_non_diagnostics :: proc(t: ^testing.T) {
    // A source-snippet line the compiler prints under a diagnostic: has a "(i:j)"
    // shape but no .odin path prefix and no level word.
    _, ok1 := parse_diagnostic_line("\t\tx := arr(1:2)")
    testing.expect(t, !ok1, "snippet line must not parse")

    // A path without .odin suffix is rejected outright.
    _, ok2 := parse_diagnostic_line("notes.txt(1:1) Error: nope")
    testing.expect(t, !ok2, "non-.odin path must not parse")

    // Blank and summary lines.
    _, ok3 := parse_diagnostic_line("")
    testing.expect(t, !ok3, "blank line must not parse")
}

@(test)
test_parse_trims_carriage_return :: proc(t: ^testing.T) {
    p, ok := parse_diagnostic_line("a.odin(1:1) Error: bad\r")
    testing.expect(t, ok, "should parse despite trailing CR")
    testing.expect_value(t, p.message, "bad")
}

// The whole path against the real toolchain: a package with one deliberate error
// is written to disk, resolve routes the Diagnostics request to the checker, and
// the report names that file with the error's position. Skipped when the
// compiler is not on PATH — this one drives it rather than a stub.
@(test)
test_check_reports_package_error :: proc(t: ^testing.T) {
    root, ok := temp_package(t, "thor_lang_check_ws")
    if !ok {
        return
    }
    defer os.remove(root)

    path, _ := filepath.join({root, "broken.odin"}, context.temp_allocator)
    // `nope` is undeclared, on line 4.
    src := "package broken\n\nbad :: proc() -> int {\n\treturn nope\n}\n"
    if err := os.write_entire_file(path, transmute([]byte) src); err != nil {
        testing.fail_now(t, "could not write the test package")
    }
    defer os.remove(path)

    if !odin_on_path(root) {
        log.info("odin is not on PATH; skipping the compiler check test")
        return
    }

    e := engine_create()
    defer engine_destroy(e)

    req := lang.Request{kind = .Diagnostics, path = path, ext = ".odin", workspace = root}
    res := lang.Result{kind = .Diagnostics}
    resolve(e, &req, &res)
    defer free_report(&res)

    testing.expect(t, res.ok, "the check should have run")
    testing.expect_value(t, res.report.scope, root)
    if !testing.expectf(t, len(res.report.items) == 1, "expected one diagnostic, got %d", len(res.report.items)) {
        return
    }
    d := res.report.items[0]
    testing.expect(t, d.severity == lang.Diagnostic_Severity.Error, "undeclared identifier is an error")
    testing.expect_value(t, d.line, 4)
    testing.expectf(t, strings.equal_fold(d.path, path), "path: got %q, want %q", d.path, path)
    testing.expectf(t, strings.contains(d.message, "nope"), "message should name the symbol: %q", d.message)
}

// An empty check of the same package must come back ok with no items — that is
// how the editor learns a file it flagged is clean again.
@(test)
test_check_reports_clean_package :: proc(t: ^testing.T) {
    root, ok := temp_package(t, "thor_lang_clean_ws")
    if !ok {
        return
    }
    defer os.remove(root)

    path, _ := filepath.join({root, "fine.odin"}, context.temp_allocator)
    src := "package fine\n\ngood :: proc() -> int {\n\treturn 1\n}\n"
    if err := os.write_entire_file(path, transmute([]byte) src); err != nil {
        testing.fail_now(t, "could not write the test package")
    }
    defer os.remove(path)

    if !odin_on_path(root) {
        log.info("odin is not on PATH; skipping the compiler check test")
        return
    }

    e := engine_create()
    defer engine_destroy(e)

    req := lang.Request{kind = .Diagnostics, path = path, ext = ".odin", workspace = root}
    res := lang.Result{kind = .Diagnostics}
    resolve(e, &req, &res)
    defer free_report(&res)

    testing.expect(t, res.ok, "the check should have run")
    testing.expectf(t, len(res.report.items) == 0, "a clean package reports nothing, got %d", len(res.report.items))
}

// A package that imports through a workspace-declared collection checks clean:
// the config's collections reach the compiler as `-collection:` flags. Without
// them `import "shared:foo"` is a syntax error, and that one line buries every
// real diagnostic in the package.
@(test)
test_check_passes_config_collections :: proc(t: ^testing.T) {
    root, ok := temp_package(t, "thor_lang_collcheck_ws")
    if !ok {
        return
    }
    libs, _ := filepath.join({root, "libs"}, context.temp_allocator)
    foo, _ := filepath.join({libs, "foo"}, context.temp_allocator)
    cfg_dir, _ := filepath.join({root, ".thor"}, context.temp_allocator)
    app, _ := filepath.join({root, "app"}, context.temp_allocator)
    _ = os.make_directory(libs)
    _ = os.make_directory(foo)
    _ = os.make_directory(cfg_dir)
    _ = os.make_directory(app)
    defer os.remove(root)
    defer os.remove(libs)
    defer os.remove(foo)
    defer os.remove(cfg_dir)
    defer os.remove(app)

    foo_path, _ := filepath.join({foo, "foo.odin"}, context.temp_allocator)
    cfg_path, _ := filepath.join({cfg_dir, "odin-analyzer.json"}, context.temp_allocator)
    app_path, _ := filepath.join({app, "app.odin"}, context.temp_allocator)
    defer os.remove(foo_path)
    defer os.remove(cfg_path)
    defer os.remove(app_path)

    files := [?]struct {
        path: string,
        src:  string,
    } {
        {foo_path, "package foo\n\nbar :: proc() -> int {\n\treturn 1\n}\n"},
        {cfg_path, "{ \"collections\": [ { \"name\": \"shared\", \"path\": \"libs\" } ] }\n"},
        {app_path, "package app\n\nimport \"shared:foo\"\n\nuse :: proc() -> int {\n\treturn foo.bar()\n}\n"},
    }
    for f in files {
        if err := os.write_entire_file(f.path, transmute([]byte)f.src); err != nil {
            testing.fail_now(t, "could not write the test workspace")
        }
    }

    if !odin_on_path(root) {
        log.info("odin is not on PATH; skipping the compiler check test")
        return
    }

    e := engine_create()
    defer engine_destroy(e)

    req := lang.Request{kind = .Diagnostics, path = app_path, ext = ".odin", workspace = root}
    res := lang.Result{kind = .Diagnostics}
    resolve(e, &req, &res)
    defer free_report(&res)

    testing.expect(t, res.ok, "the check should have run")
    for d in res.report.items {
        testing.expectf(t, false, "unexpected diagnostic: %s(%d:%d) %s", d.path, d.line, d.col, d.message)
    }
}

// A run that fails without printing one parseable diagnostic answers ok=false,
// so the editor keeps the squiggles it has. An empty directory stands in for the
// real case, a compiler that is not on PATH: the compiler refuses both the same
// way, with a message that is no diagnostic.
@(test)
test_check_failed_run_reports_not_ok :: proc(t: ^testing.T) {
    root, ok := temp_package(t, "thor_lang_norun_ws")
    if !ok {
        return
    }
    defer os.remove(root)

    if !odin_on_path(root) {
        log.info("odin is not on PATH; skipping the compiler check test")
        return
    }

    e := engine_create()
    defer engine_destroy(e)

    // The file does not exist, and its directory holds no .odin file at all.
    path, _ := filepath.join({root, "ghost.odin"}, context.temp_allocator)
    req := lang.Request{kind = .Diagnostics, path = path, ext = ".odin", workspace = root}
    res := lang.Result{kind = .Diagnostics}
    resolve(e, &req, &res)
    defer free_report(&res)

    testing.expect(t, !res.ok, "a run that reached no compiler must not report a clean package")
    testing.expect_value(t, res.report.scope, "")
    testing.expect_value(t, len(res.report.items), 0)
}

// Creates an empty package directory under the working directory and returns its
// absolute path.
@(private = "file")
temp_package :: proc(t: ^testing.T, name: string) -> (string, bool) {
    cwd, err := os.get_working_directory(context.temp_allocator)
    if err != nil {
        testing.fail_now(t, "could not read the working directory")
    }
    root, jerr := filepath.join({cwd, name}, context.temp_allocator)
    if jerr != nil {
        testing.fail_now(t, "could not build the test package path")
    }
    _ = os.make_directory(root)
    return root, true
}

// True when `odin` runs from `cwd`. A missing compiler leaves the shell to
// report it, which is a failed exit rather than a failed run.
@(private = "file")
odin_on_path :: proc(cwd: string) -> bool {
    out, code, ran := shell.run_status("odin version", cwd)
    defer delete(out)
    return ran && code == 0
}

// Frees a diagnostics result's owned strings (the checker clones into
// context.allocator; the Manager's job_free does this in the real flow).
@(private = "file")
free_report :: proc(res: ^lang.Result) {
    delete(res.report.scope)
    for d in res.report.items {
        delete(d.path)
        delete(d.message)
    }
    delete(res.report.items)
}
