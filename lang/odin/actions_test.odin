// Code actions: the fixes offered at the caret and the text each one produces.
// Assertions run against the applied source rather than raw edit ranges — what
// matters is the code the user ends up with.
package odin

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_remove_unused_import :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `strings` is imported but never named; `fmt` is used, so it stays.
    src := `package demo

import "core:fmt"
import "core:strings"

main :: proc() {
	fmt.println("hi")
}
`
    res := actions_at(e, src, "core:strings")
    defer free_actions(&res)

    testing.expect(t, res.ok, "expected an action on an unused import")
    action, found := find_action(&res, `Remove unused import "core:strings"`)
    testing.expect(t, found, "missing the remove-unused-import action")

    out := apply_action(src, action)
    testing.expect(t, !strings.contains(out, "core:strings"), "the unused import survived")
    testing.expect(t, strings.contains(out, `import "core:fmt"`), "the used import was removed too")
    testing.expect(t, !strings.contains(out, "\n\n\nmain"), "removing the line left a blank behind")
}

@(test)
test_used_import_is_not_offered :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import "core:fmt"

main :: proc() {
	fmt.println("hi")
}
`
    res := actions_at(e, src, "core:fmt")
    defer free_actions(&res)

    _, found := find_action(&res, `Remove unused import "core:fmt"`)
    testing.expect(t, !found, "a used import was offered for removal")
}

@(test)
test_blank_alias_import_is_kept :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `import _ "..."` is imported for its side effects, so it is never unused.
    src := `package demo

import _ "core:fmt"

main :: proc() {
}
`
    res := actions_at(e, src, "core:fmt")
    defer free_actions(&res)

    for action in res.actions {
        testing.expectf(t, !strings.contains(action.title, "unused"), "offered %q on a blank-alias import", action.title)
    }
}

@(test)
test_remove_all_unused_imports :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import "core:fmt"
import "core:strings"
import "core:os"

main :: proc() {
}
`
    res := actions_at(e, src, "main")
    defer free_actions(&res)

    action, found := find_action(&res, "Remove 3 unused imports")
    testing.expect(t, found, "missing the bulk removal action")
    testing.expectf(t, len(action.edits) == 3, "expected 3 edits, got %d", len(action.edits))

    out := apply_action(src, action)
    testing.expect(t, !strings.contains(out, "import"), "an import survived the bulk removal")
    testing.expect(t, strings.contains(out, "package demo"), "the package clause was damaged")
}

@(test)
test_add_missing_import :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `fmt` is qualified but never imported: offer the core collection's package.
    src := `package demo

main :: proc() {
	fmt.println("hi")
}
`
    res := actions_at(e, src, "fmt.println")
    defer free_actions(&res)

    action, found := find_action(&res, `Import "core:fmt"`)
    testing.expect(t, found, "missing the add-import action")

    out := apply_action(src, action)
    testing.expect(t, strings.contains(out, `import "core:fmt"`), "the import was not inserted")
    // It must land above the code that needs it, under the package clause.
    testing.expect(
        t,
        strings.index(out, "import") < strings.index(out, "main ::"),
        "the import was inserted below the code",
    )
}

@(test)
test_fix_diagnostic_widens_add_import :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

main :: proc() {
	fmt.println("hi")
}
`
    call := `fmt.println("hi")`
    call_start := strings.index(src, call)
    // A diagnostic can span more than the bare identifier (the whole call, as
    // a checker might report it) while still starting exactly on `fmt` — the
    // caret sits inside the string argument, nowhere identifier_at alone would
    // resolve, so only the diagnostic's own range can reach the fix.
    diagnostics := []lang.Diagnostic_Ref {
        {start = call_start, end = call_start + len(call), message = "'fmt' undeclared"},
    }
    res := actions_at(e, src, `"hi"`, diagnostics = diagnostics)
    defer free_actions(&res)

    action, found := find_action(&res, `Import "core:fmt"`)
    testing.expect(t, found, "the diagnostic-anchored fix did not widen past the caret's own token")

    out := apply_action(src, action)
    testing.expect(t, strings.contains(out, `import "core:fmt"`), "the import was not inserted")
}

@(test)
test_fix_diagnostic_ignores_unrelated_message :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

main :: proc() {
	fmt.println("hi")
}
`
    call := `fmt.println("hi")`
    call_start := strings.index(src, call)
    diagnostics := []lang.Diagnostic_Ref {
        {start = call_start, end = call_start + len(call), message = "expected ';'"},
    }
    res := actions_at(e, src, `"hi"`, diagnostics = diagnostics)
    defer free_actions(&res)

    _, found := find_action(&res, `Import "core:fmt"`)
    testing.expect(t, !found, "offered an import fix for a diagnostic that never named an undeclared identifier")
}

@(test)
test_add_import_spans_sibling_files :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `helper.odin` sits beside the requesting file, on disk, using `fmt`
    // without importing it too; the fix must widen to cover it. The requesting
    // file itself is never written — the index only ever sees its sibling.
    rel := "thor_lang_multi_import_ws"
    _ = os.make_directory(rel)
    abs, abs_err := filepath.abs(rel, context.temp_allocator)
    testing.expect(t, abs_err == nil, "could not absolutize the test workspace")
    defer os.remove(abs)

    helper_path := strings.concatenate({abs, "/helper.odin"}, context.temp_allocator)
    helper_src := "package demo\n\nhelper :: proc() {\n\tfmt.println(\"y\")\n}\n"
    _ = os.write_entire_file(helper_path, transmute([]byte) helper_src)
    defer os.remove(helper_path)

    main_path := strings.concatenate({abs, "/main.odin"}, context.temp_allocator)
    src := `package demo

main :: proc() {
	fmt.println("hi")
}
`
    res := actions_at(e, src, "fmt.println", workspace = abs, path = main_path)
    defer free_actions(&res)

    action, found := find_action(&res, `Import "core:fmt" in 2 files`)
    testing.expect(t, found, "missing the multi-file add-import action")
    testing.expectf(t, len(action.edits) == 2, "expected one edit per file, got %d", len(action.edits))

    saw_main, saw_helper := false, false
    for edit in action.edits {
        if path_equal(edit.path, main_path) {
            saw_main = true
        }
        if path_equal(edit.path, helper_path) {
            saw_helper = true
            testing.expect(t, strings.contains(edit.new_text, `import "core:fmt"`), "sibling edit did not add the import")
        }
    }
    testing.expect(t, saw_main, "missing the edit for the requesting file")
    testing.expect(t, saw_helper, "missing the edit for the sibling file")
}

@(test)
test_add_import_joins_existing_block :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import "core:os"

main :: proc() {
	fmt.println(os.args)
}
`
    res := actions_at(e, src, "fmt.println")
    defer free_actions(&res)

    action, found := find_action(&res, `Import "core:fmt"`)
    testing.expect(t, found, "missing the add-import action")

    out := apply_action(src, action)
    lines := strings.split_lines(out, context.temp_allocator)
    // The new import sits on the line after the existing one, not somewhere else.
    for line, i in lines {
        if strings.contains(line, `import "core:os"`) {
            testing.expectf(
                t,
                i + 1 < len(lines) && strings.contains(lines[i + 1], `import "core:fmt"`),
                "expected the new import directly below the existing block, got %q",
                i + 1 < len(lines) ? lines[i + 1] : "<eof>",
            )
        }
    }
}

@(test)
test_no_import_offered_when_already_imported :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import "core:fmt"

main :: proc() {
	fmt.println("hi")
}
`
    res := actions_at(e, src, "fmt.println")
    defer free_actions(&res)

    _, found := find_action(&res, `Import "core:fmt"`)
    testing.expect(t, !found, "offered an import the file already has")
}

@(test)
test_no_import_offered_for_a_value_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `p` is a local, so `p.x` is member access — not a package qualifier that
    // needs importing.
    src := `package demo

Point :: struct {
	x: int,
}

main :: proc() {
	p := Point{}
	p.x = 1
}
`
    res := actions_at(e, src, "p.x")
    defer free_actions(&res)

    for action in res.actions {
        testing.expectf(t, !strings.has_prefix(action.title, "Import"), "offered %q for a struct member", action.title)
    }
}

@(test)
test_fill_switch_cases :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
	Depth,
}

main :: proc() {
	a: Axis = .Horizontal
	switch a {
	case .Horizontal:
	}
}
`
    res := actions_at(e, src, "switch a")
    defer free_actions(&res)

    testing.expect(t, res.ok, "expected an action on an incomplete switch")
    action, found := find_action(&res, "Add 2 missing cases")
    testing.expect(t, found, "missing the fill-switch action")

    out := apply_action(src, action)
    testing.expect(t, strings.contains(out, "case .Vertical:"), "Vertical was not added")
    testing.expect(t, strings.contains(out, "case .Depth:"), "Depth was not added")
    // The existing case is untouched and the new ones share its indentation.
    testing.expect(t, strings.contains(out, "\tcase .Horizontal:\n"), "the existing case was disturbed")
    testing.expect(t, strings.contains(out, "\tcase .Vertical:\n"), "the new case is misindented")
    // They go inside the switch, above its closing brace.
    testing.expect(
        t,
        strings.index(out, "case .Depth:") < strings.index(out, "\n\t}"),
        "the new cases landed outside the switch",
    )
}

@(test)
test_fill_switch_counts_qualified_cases :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `Axis.Vertical` covers the member just as `.Vertical` does.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis = .Horizontal
	switch a {
	case .Horizontal:
	case Axis.Vertical:
	}
}
`
    res := actions_at(e, src, "switch a")
    defer free_actions(&res)

    for action in res.actions {
        testing.expectf(t, !strings.contains(action.title, "missing case"), "offered %q on a complete switch", action.title)
    }
}

@(test)
test_complete_switch_offers_nothing :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis = .Horizontal
	switch a {
	case .Horizontal:
	case .Vertical:
	}
}
`
    res := actions_at(e, src, "switch a")
    defer free_actions(&res)

    for action in res.actions {
        testing.expectf(t, !strings.contains(action.title, "missing"), "offered %q on a complete switch", action.title)
    }
}

@(test)
test_declare_variable_with_short_decl :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Nothing declares `count`, so `=` should have been `:=`.
    src := `package demo

main :: proc() {
	count = 1
	_ = count
}
`
    res := actions_at(e, src, "count = 1")
    defer free_actions(&res)

    testing.expect(t, res.ok, "expected an action on an undeclared assignment")
    action, found := find_action(&res, `Declare "count" with :=`)
    testing.expect(t, found, "missing the declare-variable action")

    out := apply_action(src, action)
    testing.expect(t, strings.contains(out, "count := 1"), "the assignment was not turned into a declaration")
}

@(test)
test_declare_variable_with_inferred_type :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `a + b` types as `int`, so the fix should name it instead of a bare `:=`.
    src := `package demo

main :: proc(a: int, b: int) {
	count = a + b
	_ = count
}
`
    res := actions_at(e, src, "count = a + b")
    defer free_actions(&res)

    testing.expect(t, res.ok, "expected an action on an undeclared assignment")
    action, found := find_action(&res, `Declare "count" as int`)
    testing.expect(t, found, "missing the typed declare-variable action")

    out := apply_action(src, action)
    testing.expect(t, strings.contains(out, "count: int := a + b"), "the assignment was not turned into a typed declaration")
}

@(test)
test_declare_variable_skips_declared_names :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

main :: proc() {
	count := 0
	count = 1
	_ = count
}
`
    res := actions_at(e, src, "count = 1")
    defer free_actions(&res)

    _, found := find_action(&res, `Declare "count" with :=`)
    testing.expect(t, !found, "offered a declaration for an already-declared name")
}

@(test)
test_declare_variable_skips_non_names :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `p.x` is a place, not a name — `:=` cannot declare it.
    src := `package demo

Point :: struct {
	x: int,
}

main :: proc() {
	p := Point{}
	p.x = 1
}
`
    res := actions_at(e, src, "p.x = 1")
    defer free_actions(&res)

    for action in res.actions {
        testing.expectf(t, !strings.has_prefix(action.title, "Declare"), "offered %q for a field assignment", action.title)
    }
}

@(test)
test_no_actions_on_clean_code :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import "core:fmt"

main :: proc() {
	fmt.println("hi")
}
`
    res := actions_at(e, src, "println")
    defer free_actions(&res)

    testing.expectf(t, !res.ok, "expected no actions, got %d", len(res.actions))
}
