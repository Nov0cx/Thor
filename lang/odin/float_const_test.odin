package odin

import "core:testing"

@(test)
test_live_float_constants :: proc(t: ^testing.T) {
    root := fixture(t, "live_float_constants", {
        {".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`},
    })
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

main :: proc() {
	_: int = 3.0 / 2
	_: int = (1.5)
	_: int = (-1.25)
	_: int = -(0.75)
	_: int = 0.1 + 0.2
	_: int = 1.0 / 3
	_: int = 2.5 * 1.5
	_: int = (1.5 + 1.0) - 0.25
	_: u8 = 300.0 + 0.0
	_: u8 = (300.0)
	_: f32 = (1e39)
	_: int = 0h3FF8000000000000
	_: int = (0h4009000000000000)
	_: int = 0h3FB999999999999A
	_: int = -0h3FF8000000000000
	_: u8 = 0h4072C00000000000
	_: int = 4.0 / 2
	_: int = (1.5 * 2)
	_: int = (2.0)
	_: f64 = (1e300)
	_: f64 = 0h3FF8000000000000
	_: int = 1.0 / 0
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"3.0 / 2", "'3.0 / 2' truncated to 'int', got 3.0/2", 0},
        {"(1.5)", "'(1.5)' truncated to 'int', got 3.0/2", 0},
        {"(-1.25)", "'(-1.25)' truncated to 'int', got -5.0/4", 0},
        {"-(0.75)", "'-(0.75)' truncated to 'int', got -3.0/4", 0},
        {"0.1 + 0.2", "'0.1 + 0.2' truncated to 'int', got 3.0/10", 0},
        {"1.0 / 3", "'1.0 / 3' truncated to 'int', got 1.0/3", 0},
        {"2.5 * 1.5", "'2.5 * 1.5' truncated to 'int', got 15.0/4", 0},
        {"(1.5 + 1.0) - 0.25", "'(1.5 + 1.0) - 0.25' truncated to 'int', got 9.0/4", 0},
        {"300.0 + 0.0", "'300.0 + 0.0' truncated to 'u8', got 300", 0},
        {"(300.0)", "'(300.0)' truncated to 'u8', got 300", 0},
        {"(1e39)", "Cannot convert numeric value '1000000000000000000000000000000000000000' from '(1e39)' to 'f32' from 'untyped integer'", 0},
        {"0h3FF8000000000000\n", "'0h3FF8000000000000' truncated to 'int', got 1.50000000000000000", 0},
        {"(0h4009000000000000)", "'(0h4009000000000000)' truncated to 'int', got 3.12500000000000000", 0},
        {"-0h3FF8000000000000", "'-0h3FF8000000000000' truncated to 'int', got -1.50000000000000000", 0},
        {"0h4072C00000000000", "'0h4072C00000000000' truncated to 'u8', got 300", 0},
    })
}
