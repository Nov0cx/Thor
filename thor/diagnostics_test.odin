package thor

import "core:testing"

import "../lang"
import "../textedit"

// The editor's half of the diagnostics path: mapping a compiler position onto a
// span of the live buffer, and deciding which reports describe it. The `odin
// check` run and its output parsing live behind the language seam (see
// lang/odin/check_test.odin). Run from the repository root: odin test thor

@(test)
test_token_end_covers_identifier :: proc(t: ^testing.T) {
    text := "foo := bar\n"
    // Start on the 'b' of "bar": extends across the whole identifier.
    testing.expect_value(t, diagnostic_token_end(text, 7), 10)
    // Start on a non-identifier (the ':'): a short bounded span, at least one byte.
    end := diagnostic_token_end(text, 4)
    testing.expect(t, end > 4, "non-identifier still underlines something")
    testing.expect(t, end <= 10, "underline stops at the newline")
}

// A report's scope is a package directory (a compiler) or a single file (a
// language server), and both must find the files they cover.
@(test)
test_scope_covers_file_and_directory :: proc(t: ^testing.T) {
    testing.expect(t, scope_covers("D:/w/pkg/a.odin", "D:/w/pkg"), "a directory scope covers the files in it")
    testing.expect(t, scope_covers("D:/w/pkg/a.odin", "D:/w/pkg/"), "a trailing separator is tolerated")
    testing.expect(t, scope_covers("D:/w/pkg/a.odin", "D:\\w\\pkg"), "the separators are normalized")
    testing.expect(t, scope_covers("D:/w/pkg/a.odin", "D:/w/pkg/a.odin"), "a file scope covers that file")
    testing.expect(t, !scope_covers("D:/w/pkg/a.odin", "D:/w/pkg/b.odin"), "a file scope covers no other file")
    testing.expect(t, !scope_covers("D:/w/pkg/sub/a.odin", "D:/w/pkg"), "a directory scope stops at its own level")
    testing.expect(t, !scope_covers("D:/w/pkg/a.odin", ""), "an empty scope covers nothing")
}

// Builds a loaded file holding `text`, saved at its current revision.
@(private = "file")
diag_file :: proc(path, text: string) -> ^Open_File {
    file := new(Open_File)
    file.path = path
    file.loaded = true
    textedit.init(&file.state)
    textedit.set_text(&file.state, text)
    file.saved_revision = file.state.revision
    return file
}

@(private = "file")
diag_file_destroy :: proc(file: ^Open_File) {
    thor_clear_file_diagnostics(file)
    delete(file.diagnostics)
    textedit.destroy(&file.state)
    free(file)
}

// A report against the live buffer applies even while the buffer is dirty: the
// producer measured the text the editor sent it, not the file on disk.
@(test)
test_report_applies_to_unsaved_buffer :: proc(t: ^testing.T) {
    thor: Thor
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    file := diag_file("D:/w/pkg/a.odin", "foo := bar\n")
    defer diag_file_destroy(file)
    append(&thor.open_files, file)

    // An edit takes the buffer away from disk; the report names the new revision.
    textedit.insert_text(&file.state, "x")
    testing.expect(t, file.state.revision != file.saved_revision, "the buffer should read as dirty")

    res := lang.Result {
        kind     = .Diagnostics,
        ok       = true,
        revision = file.state.revision,
    }
    res.report.scope = "D:/w/pkg/a.odin"
    res.report.items = make([dynamic]lang.Diagnostic)
    defer delete(res.report.items)
    // The insert landed at the caret, so "bar" starts one column further along.
    append(&res.report.items, lang.Diagnostic{path = "D:/w/pkg/a.odin", line = 1, col = 9, message = "bad"})

    thor_apply_diagnostics(&thor, &res)
    testing.expectf(t, len(file.diagnostics) == 1, "expected the pushed diagnostic (got %d)", len(file.diagnostics))
    testing.expect_value(t, file.diagnostics[0].start, 8)
    testing.expect_value(t, file.diagnostics[0].end, 11)
}

// A report measured against an older revision is dropped once the buffer has
// moved away from disk: its positions no longer line up.
@(test)
test_stale_report_skips_dirty_buffer :: proc(t: ^testing.T) {
    thor: Thor
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    file := diag_file("D:/w/pkg/a.odin", "foo := bar\n")
    defer diag_file_destroy(file)
    append(&thor.open_files, file)

    stale := file.state.revision
    textedit.insert_text(&file.state, "x")

    res := lang.Result {
        kind     = .Diagnostics,
        ok       = true,
        revision = stale,
    }
    res.report.scope = "D:/w/pkg"
    res.report.items = make([dynamic]lang.Diagnostic)
    defer delete(res.report.items)
    append(&res.report.items, lang.Diagnostic{path = "D:/w/pkg/a.odin", line = 1, col = 8, message = "bad"})

    thor_apply_diagnostics(&thor, &res)
    testing.expectf(t, len(file.diagnostics) == 0, "a stale report must not mark a dirty buffer (got %d)", len(file.diagnostics))
}

// A file-scoped report clears that file's old squiggles and leaves every other
// file's alone — the case a directory-only compare never reached.
@(test)
test_file_scoped_report_clears_only_its_file :: proc(t: ^testing.T) {
    thor: Thor
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    a := diag_file("D:/w/pkg/a.odin", "foo := bar\n")
    b := diag_file("D:/w/pkg/b.odin", "foo := bar\n")
    defer diag_file_destroy(a)
    defer diag_file_destroy(b)
    append(&thor.open_files, a)
    append(&thor.open_files, b)

    for file in thor.open_files {
        res := lang.Result{kind = .Diagnostics, ok = true, revision = file.state.revision}
        res.report.scope = file.path
        res.report.items = make([dynamic]lang.Diagnostic)
        defer delete(res.report.items)
        append(&res.report.items, lang.Diagnostic{path = file.path, line = 1, col = 8, message = "bad"})
        thor_apply_diagnostics(&thor, &res)
    }
    testing.expect(t, len(a.diagnostics) == 1 && len(b.diagnostics) == 1, "each file should hold its own diagnostic")

    // A clean report for `a` alone retires its squiggles and keeps `b`'s.
    clean := lang.Result{kind = .Diagnostics, ok = true, revision = a.state.revision}
    clean.report.scope = a.path
    thor_apply_diagnostics(&thor, &clean)
    testing.expectf(t, len(a.diagnostics) == 0, "the scoped file's diagnostics should be retired (got %d)", len(a.diagnostics))
    testing.expectf(t, len(b.diagnostics) == 1, "another file's diagnostics must survive (got %d)", len(b.diagnostics))
}
