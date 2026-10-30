package odin

import "core:testing"

@(test)
test_live_call_arguments :: proc(t: ^testing.T) {
    root := fixture(t, "live_call_arguments", {
        {".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`},
        {"app/q/q.odin", "package q\n\nclone :: proc(s: string, n := 1, m := 2) -> string { return s }\n"},
    })
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "q"

f :: proc(a: int, b: int) {}
g :: proc(a: int, b := 2) {}
two :: proc() -> (int, int) { return 1, 2 }
group :: proc{f, g}

Obj :: struct { call: proc(o: ^Obj, k: int) }

main :: proc() {
	f(1)
	f(1, 2, 3)
	g(1, c = 3)
	g(a = 1, a = 2)
	g(a = 1, 2)
	_ = q.clone("a", 1, 2, 3)
	o: ^Obj
	o->call(1, 2)
	f(two())
	g(b = 1, a = 2)
	group(1)
	when ODIN_OS == .Linux {
		f(1)
	}
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"f(1)", "Parameter 'b' of type 'int' is missing in procedure call", 0},
        {"f(1, 2, 3)", "Too many arguments for 'f', expected 2 arguments, got 3", 0},
        {"c = 3", "No parameter named 'c' for this procedure type", 0},
        {"a = 2", "Duplicate parameter 'a' in procedure call", 0},
        {"2)\n\t_ = q", "Non-named parameter is not allowed to follow named parameter i.e. 'field = value' in a procedure call", 0},
        {"q.clone", "Too many arguments for 'q.clone', expected 1..=3 arguments, got 4", 0},
        {"o->call", "Too many arguments for 'o->call', expected 2 arguments, got 3", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_ARITY || d.code == CODE_NAMED, "a call error carries a call id")
    }
}

// An undeclared name leaves the body errors out.
@(test)
test_live_body_after_names :: proc(t: ^testing.T) {
    root := fixture(t, "live_body_after_names", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nf :: proc(a: int) {}\n\nmain :: proc() {\n\tf()\n\t_ = zork\n}\n"
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {{"zork", "Undeclared name: zork", 0}})
}
