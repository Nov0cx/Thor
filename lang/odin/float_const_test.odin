package odin

import "core:testing"

@(test)
test_live_float_constants :: proc(t: ^testing.T) {
    root := fixture(t, "live_float_constants", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
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
	_: int = 1e30 * 1e30 * 1e30 * 1e30 + 0.5
	_: u8 = 0h4072C00000000000 + 0.0
	_: int = 0h3FF8000000000000 + 1.0
	_: int = 1.5 /* note */ + 0.25
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(
        t,
        &res,
        src,
        {
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
            {"(0h4009000000000000)", "'(0h4009000000000000)' truncated to 'int', got 3.12499999999999999", 0},
            {"0h3FB999999999999A\n", "'0h3FB999999999999A' truncated to 'int', got 0.10000000000000000", 0},
            {"-0h3FF8000000000000", "'-0h3FF8000000000000' truncated to 'int', got -1.50000000000000000", 0},
            {"0h4072C00000000000", "'0h4072C00000000000' truncated to 'u8', got 300", 0},
            {
                "1e30 * 1e30 * 1e30 * 1e30 + 0.5",
                "'1e30 * 1e30 * 1e30 * 1e30 + 0.5' truncated to 'int', got 2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001.0/2",
                0,
            },
            {"0h4072C00000000000 + 0.0", "'0h4072C00000000000 + 0.0' truncated to 'u8', got 300", 0},
            {"0h3FF8000000000000 + 1.0", "'0h3FF8000000000000 + 1.0' truncated to 'int', got 2.50000000000000000", 0},
            {"1.5 /* note */ + 0.25", "'1.5 + 0.25' truncated to 'int', got 7.0/4", 0},
        },
    )
}

@(test)
test_live_float_texts :: proc(t: ^testing.T) {
    root := fixture(t, "live_float_texts", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
    defer engine_destroy(e)

    src := `package app

F :: 1.5
FF :: F
N :: -2.5
X :: 0h3FF8000000000000
Q :: 7 / 2
Q2 :: 7.0 / 2
H :: 300.0
BIG :: 1e39
ONE :: 1

take :: proc(a: int) {}

main :: proc() {
	_: int = 1.5 /* note */ + 0.25
	_: int = 1.5 // trailing
	_: int = 3.0/2
	_: int = -  1.5
	_: int = ( 1.5 )
	_: int = (1.5 /* x */ + 0.25)
	_: int = 1.5 /* a */ * /* b */ 2.5
	_: int = 1.5 +
		0.25
	_: int = 0h3FB999999999999A
	_: int = 0h3FD5555555555555
	_: int = 0h3FF199999999999A
	_: int = -0h3FB999999999999A
	_: int = 0h3FB999999999999A + 1.0
	_: int = 0h0000000000000001
	_: int = 0h3E43CE8908E75C1D
	_: int = 0h4132D687E4189375
	_: int = 0h3FC0000000000000
	_: int = 0h430C6BF526340004
	_: int = 0h3FB999999999999A + 0.2
	_: int = 0h3FD5555555555555 + 0h3FD5555555555555
	_: int = 0h3FB999999999999A / 3
	_: int = 0h4072C00000000000 / 7
	_: int = 0.1 + 0.2 + 0h0000000000000000
	_: int = 0h0000000000000000 + 0.1 + 0.2
	_: int = 0.1 + (0.2 + 0h0000000000000000)
	_: int = 0h4000000000000000 + 0.1 + 0.2
	_: int = 0.1 + 0.2 + 0h4000000000000000
	_: int = 1.0 / 3 / 3 + 0h0000000000000000
	_: int = 0h3FB999999999999A * 10.0
	_: int = F
	_: int = FF
	_: int = N
	_: int = X
	_: int = Q
	_: int = Q2
	_: int = (N)
	_: int = F + 1
	_: int = -F
	_: int = 0.1 + F
	_: int = Q + 0.5
	_: int = F * 2
	_: u8 = H
	_: u8 = H + 0.0
	_: u8 = ONE + 300.0
	_: f32 = BIG
	_: int = f32(1.5)
	_: int = f64(1.5)
	take(F)
	take(0.1 + F)
	LOC :: 2.5
	_: int = LOC
	_: int = LOC + F
	_: int = 7 / 2 + 0.25
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(
        t,
        &res,
        src,
        {
            {"1.5 /* note */ + 0.25", "'1.5 + 0.25' truncated to 'int', got 7.0/4", 0},
            {"1.5", "'1.5' truncated to 'int', got 3.0/2", 2},
            {"3.0/2", "'3.0 / 2' truncated to 'int', got 3.0/2", 0},
            {"-  1.5", "'-1.5' truncated to 'int', got -3.0/2", 0},
            {"( 1.5 )", "'(1.5)' truncated to 'int', got 3.0/2", 0},
            {"(1.5 /* x */ + 0.25)", "'(1.5 + 0.25)' truncated to 'int', got 7.0/4", 0},
            {"1.5 /* a */ * /* b */ 2.5", "'1.5 * 2.5' truncated to 'int', got 15.0/4", 0},
            {"1.5 +\n\t\t0.25", "'1.5 + 0.25' truncated to 'int', got 7.0/4", 0},
            {"0h3FB999999999999A", "'0h3FB999999999999A' truncated to 'int', got 0.10000000000000000", 0},
            {"0h3FD5555555555555", "'0h3FD5555555555555' truncated to 'int', got 0.33333333333333332", 0},
            {"0h3FF199999999999A", "'0h3FF199999999999A' truncated to 'int', got 1.10000000000000008", 0},
            {"-0h3FB999999999999A", "'-0h3FB999999999999A' truncated to 'int', got -0.10000000000000000", 0},
            {"0h3FB999999999999A + 1.0", "'0h3FB999999999999A + 1.0' truncated to 'int', got 1.10000000000000008", 0},
            {"0h0000000000000001", "'0h0000000000000001' truncated to 'int', got 0.00000000000000000", 0},
            {"0h3E43CE8908E75C1D", "'0h3E43CE8908E75C1D' truncated to 'int', got 0.00000000922324996", 0},
            {"0h4132D687E4189375", "'0h4132D687E4189375' truncated to 'int', got 1234567.89100000006146724", 0},
            {"0h3FC0000000000000", "'0h3FC0000000000000' truncated to 'int', got 0.12499999999999999", 0},
            {"0h430C6BF526340004", "'0h430C6BF526340004' truncated to 'int', got 1000000000000000.50000000000000000", 0},
            {"0h3FB999999999999A + 0.2", "'0h3FB999999999999A + 0.2' truncated to 'int', got 0.30000000000000005", 0},
            {"0h3FD5555555555555 + 0h3FD5555555555555", "'0h3FD5555555555555 + 0h3FD5555555555555' truncated to 'int', got 0.66666666666666665", 0},
            {"0h3FB999999999999A / 3", "'0h3FB999999999999A / 3' truncated to 'int', got 0.03333333333333333", 0},
            {"0h4072C00000000000 / 7", "'0h4072C00000000000 / 7' truncated to 'int', got 42.85714285714285405", 0},
            {"0.1 + 0.2 + 0h0000000000000000", "'0.1 + 0.2 + 0h0000000000000000' truncated to 'int', got 0.30000000000000000", 0},
            {"0h0000000000000000 + 0.1 + 0.2", "'0h0000000000000000 + 0.1 + 0.2' truncated to 'int', got 0.30000000000000005", 0},
            {"0.1 + (0.2 + 0h0000000000000000)", "'0.1 + (0.2 + 0h0000000000000000)' truncated to 'int', got 0.30000000000000005", 0},
            {"0h4000000000000000 + 0.1 + 0.2", "'0h4000000000000000 + 0.1 + 0.2' truncated to 'int', got 2.30000000000000027", 0},
            {"0.1 + 0.2 + 0h4000000000000000", "'0.1 + 0.2 + 0h4000000000000000' truncated to 'int', got 2.29999999999999981", 0},
            {"1.0 / 3 / 3 + 0h0000000000000000", "'1.0 / 3 / 3 + 0h0000000000000000' truncated to 'int', got 0.11111111111111109", 0},
            {"F", "'F' truncated to 'int', got 3.0/2", 19},
            {"FF", "'FF' truncated to 'int', got 3.0/2", 3},
            {"N", "'N' truncated to 'int', got -5.0/2", 2},
            {"X", "'X' truncated to 'int', got 1.50000000000000000", 1},
            {"Q2", "'Q2' truncated to 'int', got 7.0/2", 1},
            {"(N)", "'(N)' truncated to 'int', got -5.0/2", 0},
            {"F + 1", "'F + 1' truncated to 'int', got 5.0/2", 0},
            {"-F", "'-F' truncated to 'int', got -3.0/2", 0},
            {"0.1 + F", "'0.1 + F' truncated to 'int', got 8.0/5", 0},
            {"Q + 0.5", "'Q + 0.5' truncated to 'int', got 7.0/2", 0},
            {"H", "'H' truncated to 'u8', got 300", 1},
            {"H + 0.0", "'H + 0.0' truncated to 'u8', got 300", 0},
            {"ONE + 300.0", "'ONE + 300.0' truncated to 'u8', got 301", 0},
            {"BIG", "Cannot convert numeric value '1000000000000000000000000000000000000000' from 'BIG' to 'f32' from 'untyped integer'", 1},
            {"f32(1.5)", "Cannot assign value 'f32(1.5)' of type 'f32' to 'int' in a variable declaration", 0},
            {"f64(1.5)", "Cannot assign value 'f64(1.5)' of type 'f64' to 'int' in a variable declaration", 0},
            {"F)", "'F' truncated to 'int', got 3.0/2", 0},
            {"0.1 + F)", "'0.1 + F' truncated to 'int', got 8.0/5", 0},
            {"LOC", "'LOC' truncated to 'int', got 5.0/2", 1},
            {"7 / 2 + 0.25", "'7 / 2 + 0.25' truncated to 'int', got 13.0/4", 0},
        },
    )
}
