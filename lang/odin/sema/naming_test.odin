package odinsema

import "core:strings"
import "core:testing"

import odinsyntax "../syntax"

@(test)
test_name_has_style :: proc(t: ^testing.T) {
    testing.expect(t, name_has_style("open_file", .Snake_Case))
    testing.expect(t, name_has_style("vec2", .Snake_Case))
    testing.expect(t, !name_has_style("openFile", .Snake_Case))
    testing.expect(t, !name_has_style("Open_file", .Snake_Case))
    testing.expect(t, name_has_style("Open_File", .Ada_Case))
    testing.expect(t, name_has_style("HTTP_Client", .Ada_Case))
    testing.expect(t, name_has_style("Vector2", .Ada_Case))
    testing.expect(t, !name_has_style("OpenFile", .Ada_Case))
    testing.expect(t, !name_has_style("open_File", .Ada_Case))
    testing.expect(t, name_has_style("MAX_PANES", .Screaming_Snake_Case))
    testing.expect(t, !name_has_style("Max_Panes", .Screaming_Snake_Case))
    testing.expect(t, name_has_style("größe", .Snake_Case))
}

// The names `src` breaks the default rules with, joined by spaces.
@(private = "file")
broken_names :: proc(t: ^testing.T, src: string, rules := DEFAULT_NAMING_RULES) -> string {
    parsed, err := odinsyntax.parse(src)
    if !testing.expect_value(t, err, nil) {
        return ""
    }
    defer odinsyntax.parse_destroy(&parsed)
    names := make([dynamic]string, context.temp_allocator)
    collect_naming(odinsyntax.node_root(parsed.tree), rules, &names)
    return strings.join(names[:], " ", context.temp_allocator)
}

@(private = "file")
collect_naming :: proc(n: odinsyntax.Syntax_Node, rules: Naming_Rules, names: ^[dynamic]string) {
    n := n
    for p in naming_problems(n, rules, context.temp_allocator) {
        append(names, p.name)
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        collect_naming(child, rules, names)
    }
}

@(test)
test_naming_declarations :: proc(t: ^testing.T) {
    src := `package demo

Good_Type :: struct {
	good_field: int,
	badField:   int,
}
badType :: struct {}
Color :: enum { Red, green, OpenBSD }
Not_Proc :: proc() {}
good_proc :: proc(good_param: int, badParam: int) -> (resultValue: int) {
	good_var := 1
	badVar := 2
	for loopVar in 0 ..< 3 {}
	return
}
MAX_SIZE :: 4
Max_Size :: 4
max_size :: 4
maxSize :: 4
TABLE := [?]int{1}
alias :: good_proc
_private :: 1
x :: 1
`
    testing.expect_value(t, broken_names(t, src), "badField badType OpenBSD Not_Proc badParam resultValue badVar loopVar maxSize")
}

@(test)
test_naming_skips :: proc(t: ^testing.T) {
    src := `package demo

foreign import lib "lib.lib"

foreign lib {
	SDL_Init :: proc(flags: u32) -> int ---
}

@(link_name = "Odd")
oddName :: proc() {}

Callback :: proc(Foo)
Generic :: struct($T: typeid) {}
`
    testing.expect_value(t, broken_names(t, src), "")
}

@(test)
test_naming_rules :: proc(t: ^testing.T) {
    src   := `package demo

BadType :: struct { badField: int }
badProc :: proc() {}
`
    rules := DEFAULT_NAMING_RULES
    rules.type = {}
    rules.variable = {.Ada_Case}
    testing.expect_value(t, broken_names(t, src, rules), "badField badProc")
}
