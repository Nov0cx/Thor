// Code actions: the fixes offered at the caret and the text each one produces.
// Assertions run against the applied source rather than raw edit ranges — what
// matters is the code the user ends up with.
package odin

import "core:strings"
import "core:testing"

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
