package vt

// The byte-at-a-time escape parser: the DEC ANSI state machine with UTF-8
// decoding in the ground state. Every state change is local, so a sequence split
// across two reads off the pipe resumes exactly where it stopped.

Parser_State :: enum u8 {
    Ground,
    Escape,
    Escape_Inter,
    Csi_Entry,
    Csi_Param,
    Csi_Inter,
    Csi_Ignore,
    Osc,
    Dcs_Entry,
    Dcs_Param,
    Dcs_Inter,
    Dcs_Pass,
    Dcs_Ignore,
    Str_Ignore, // SOS, PM and APC, which nothing here acts on
}

// The numeric arguments of a CSI or DCS sequence. A `:` argument marks the slot
// as a sub-argument of the one before it, which is how SGR spells a direct
// colour and an underline style.
Params :: struct {
    v:   [MAX_PARAMS]int,
    sub: [MAX_PARAMS]bool,
    n:   int,
    // An argument was left out, so the whole sequence is ignored.
    overflow: bool,
}

// Argument `index`, or `fallback` when it is absent or empty. An omitted
// argument is stored as -1, since 0 is a value in its own right.
@(private)
param :: proc(p: Params, index: int, fallback: int) -> int {
    if index >= p.n || p.v[index] < 0 {
        return fallback
    }
    return p.v[index]
}

@(private)
params_reset :: proc(t: ^Term) {
    t.params = {}
    t.private = 0
    t.inter_n = 0
    t.inter = {}
}

@(private)
param_digit :: proc(t: ^Term, b: u8) {
    if t.params.n == 0 {
        t.params.n = 1
        t.params.v[0] = 0
    }
    i := t.params.n - 1
    if t.params.v[i] < 0 {
        t.params.v[i] = 0
    }
    // 65535 is the largest an argument may be; past it the value sticks rather
    // than wrapping into something the dispatcher would act on.
    t.params.v[i] = min(t.params.v[i] * 10 + int(b - '0'), 65535)
}

@(private)
param_next :: proc(t: ^Term, sub: bool) {
    if t.params.n == 0 {
        t.params.n = 1
        t.params.v[0] = -1
    }
    if t.params.n >= MAX_PARAMS {
        t.params.overflow = true
        return
    }
    t.params.v[t.params.n] = -1
    t.params.sub[t.params.n] = sub
    t.params.n += 1
}

@(private)
inter_collect :: proc(t: ^Term, b: u8) {
    if t.inter_n < len(t.inter) {
        t.inter[t.inter_n] = b
    }
    t.inter_n += 1
}

// Feeds shell output through the parser. Bytes are consumed whole: a multi-byte
// rune or an escape sequence cut by the end of `data` resumes on the next call.
term_feed :: proc(t: ^Term, data: []u8) {
    for b in data {
        feed_byte(t, b)
    }
}

// The same with a string, which is what a host that prints its own lines has.
term_feed_string :: proc(t: ^Term, text: string) {
    term_feed(t, transmute([]u8) text)
}

@(private = "file")
feed_byte :: proc(t: ^Term, b: u8) {
    switch t.state {
    case .Ground:
        ground_byte(t, b)
    case .Escape:
        escape_byte(t, b)
    case .Escape_Inter:
        escape_inter_byte(t, b)
    case .Csi_Entry, .Csi_Param, .Csi_Inter, .Csi_Ignore:
        csi_byte(t, b)
    case .Osc:
        osc_byte(t, b)
    case .Dcs_Entry, .Dcs_Param, .Dcs_Inter:
        dcs_byte(t, b)
    case .Dcs_Pass, .Dcs_Ignore:
        dcs_pass_byte(t, b)
    case .Str_Ignore:
        str_ignore_byte(t, b)
    }
}

// True for the C0 controls that act wherever they arrive, including in the
// middle of a sequence.
@(private = "file")
is_c0_execute :: proc(b: u8) -> bool {
    return b <= 0x17 || b == 0x19 || (b >= 0x1c && b <= 0x1f)
}

@(private = "file")
ground_byte :: proc(t: ^Term, b: u8) {
    if t.utf8_need > 0 {
        utf8_continue(t, b)
        return
    }
    switch {
    case is_c0_execute(b):
        execute(t, b)
    case b == 0x18 || b == 0x1a: // CAN, SUB
        t.state = .Ground
    case b == 0x1b:
        params_reset(t)
        t.state = .Escape
    case b == 0x7f: // DEL is never printed
    case b < 0x80:
        print_rune(t, rune(b))
    case:
        utf8_start(t, b)
    }
}

// ---- UTF-8 -------------------------------------------------------------------

@(private = "file")
utf8_start :: proc(t: ^Term, b: u8) {
    switch {
    case b >= 0xf0 && b <= 0xf4:
        t.utf8_need = 3
    case b >= 0xe0 && b <= 0xef:
        t.utf8_need = 2
    case b >= 0xc2 && b <= 0xdf:
        t.utf8_need = 1
    case:
        // A stray continuation byte or an over-long lead: one replacement, and
        // the stream carries on at the next byte.
        print_rune(t, 0xfffd)
        return
    }
    t.utf8[0] = b
    t.utf8_len = 1
}

@(private = "file")
utf8_continue :: proc(t: ^Term, b: u8) {
    if b < 0x80 || b > 0xbf {
        // The sequence was cut short; the byte that cut it is re-read as itself.
        t.utf8_need, t.utf8_len = 0, 0
        print_rune(t, 0xfffd)
        ground_byte(t, b)
        return
    }
    t.utf8[t.utf8_len] = b
    t.utf8_len += 1
    t.utf8_need -= 1
    if t.utf8_need > 0 {
        return
    }
    print_rune(t, utf8_decode(t.utf8[:t.utf8_len]))
    t.utf8_len = 0
}

@(private = "file")
utf8_decode :: proc(bytes: []u8) -> rune {
    r: rune
    switch len(bytes) {
    case 2:
        r = rune(bytes[0] & 0x1f) << 6 | rune(bytes[1] & 0x3f)
    case 3:
        r = rune(bytes[0] & 0x0f) << 12 | rune(bytes[1] & 0x3f) << 6 | rune(bytes[2] & 0x3f)
    case 4:
        r =
            rune(bytes[0] & 0x07) << 18 |
            rune(bytes[1] & 0x3f) << 12 |
            rune(bytes[2] & 0x3f) << 6 |
            rune(bytes[3] & 0x3f)
    case:
        return 0xfffd
    }
    // Surrogates and out-of-range code points never reach a cell.
    if r > 0x10ffff || (r >= 0xd800 && r <= 0xdfff) {
        return 0xfffd
    }
    return r
}

@(private = "file")
print_rune :: proc(t: ^Term, r: rune) {
    put_rune(t, r)
    if !rune_is_combining(r) {
        t.last_rune = r
    }
}

// ---- escape ------------------------------------------------------------------

@(private = "file")
escape_byte :: proc(t: ^Term, b: u8) {
    switch {
    case is_c0_execute(b):
        execute(t, b)
    case b == 0x1b:
        params_reset(t)
    case b == 0x18 || b == 0x1a:
        t.state = .Ground
    case b == '[':
        params_reset(t)
        t.state = .Csi_Entry
    case b == ']':
        clear(&t.osc)
        t.state = .Osc
    case b == 'P':
        params_reset(t)
        t.state = .Dcs_Entry
    case b == 'X' || b == '^' || b == '_':
        t.state = .Str_Ignore
    case b >= 0x20 && b <= 0x2f:
        inter_collect(t, b)
        t.state = .Escape_Inter
    case b >= 0x30 && b <= 0x7e:
        esc_dispatch(t, b)
        t.state = .Ground
    case:
        t.state = .Ground
    }
}

@(private = "file")
escape_inter_byte :: proc(t: ^Term, b: u8) {
    switch {
    case is_c0_execute(b):
        execute(t, b)
    case b >= 0x20 && b <= 0x2f:
        inter_collect(t, b)
    case b >= 0x30 && b <= 0x7e:
        esc_dispatch(t, b)
        t.state = .Ground
    case:
        t.state = .Ground
    }
}

// ---- CSI ---------------------------------------------------------------------

@(private = "file")
csi_byte :: proc(t: ^Term, b: u8) {
    if is_c0_execute(b) {
        execute(t, b)
        return
    }
    if b == 0x1b {
        params_reset(t)
        t.state = .Escape
        return
    }
    if b == 0x18 || b == 0x1a {
        t.state = .Ground
        return
    }
    if b == 0x7f {
        return
    }

    if t.state == .Csi_Ignore {
        if b >= 0x40 && b <= 0x7e {
            t.state = .Ground
        }
        return
    }

    switch {
    case b >= 0x30 && b <= 0x39:
        if t.state == .Csi_Inter {
            t.state = .Csi_Ignore
            return
        }
        param_digit(t, b)
        t.state = .Csi_Param
    case b == ';' || b == ':':
        if t.state == .Csi_Inter {
            t.state = .Csi_Ignore
            return
        }
        param_next(t, b == ':')
        t.state = .Csi_Param
    case b >= 0x3c && b <= 0x3f:
        if t.state != .Csi_Entry {
            t.state = .Csi_Ignore
            return
        }
        t.private = b
    case b >= 0x20 && b <= 0x2f:
        inter_collect(t, b)
        t.state = .Csi_Inter
    case b >= 0x40 && b <= 0x7e:
        if !t.params.overflow && t.inter_n <= len(t.inter) {
            csi_dispatch(t, b)
        }
        t.state = .Ground
    case:
        t.state = .Csi_Ignore
    }
}

// ---- OSC ---------------------------------------------------------------------

@(private = "file")
osc_byte :: proc(t: ^Term, b: u8) {
    switch {
    case b == 0x07: // BEL ends the string
        osc_dispatch(t, string(t.osc[:]))
        t.state = .Ground
    case b == 0x1b:
        // ESC ends the string too; the ST backslash behind it dispatches to
        // nothing, and anything else is the sequence that follows.
        osc_dispatch(t, string(t.osc[:]))
        params_reset(t)
        t.state = .Escape
    case b == 0x18 || b == 0x1a:
        t.state = .Ground
    case b < 0x20:
        // Other controls are not part of an OSC string.
    case:
        if len(t.osc) < MAX_OSC {
            append(&t.osc, b)
        }
    }
}

// ---- DCS ---------------------------------------------------------------------

@(private = "file")
dcs_byte :: proc(t: ^Term, b: u8) {
    switch {
    case b == 0x1b:
        params_reset(t)
        t.state = .Escape
    case b >= 0x30 && b <= 0x39:
        param_digit(t, b)
        t.state = .Dcs_Param
    case b == ';' || b == ':':
        param_next(t, b == ':')
        t.state = .Dcs_Param
    case b >= 0x3c && b <= 0x3f:
        t.private = b
        t.state = .Dcs_Param
    case b >= 0x20 && b <= 0x2f:
        inter_collect(t, b)
        t.state = .Dcs_Inter
    case b >= 0x40 && b <= 0x7e:
        t.dcs_final = b
        clear(&t.osc)
        t.state = .Dcs_Pass
    case:
        t.state = .Dcs_Ignore
    }
}

@(private = "file")
dcs_pass_byte :: proc(t: ^Term, b: u8) {
    switch {
    case b == 0x1b:
        if t.state == .Dcs_Pass {
            dcs_dispatch(t, string(t.osc[:]))
        }
        params_reset(t)
        t.state = .Escape
    case b == 0x18 || b == 0x1a:
        t.state = .Ground
    case t.state == .Dcs_Pass && len(t.osc) < MAX_OSC:
        append(&t.osc, b)
    }
}

@(private = "file")
str_ignore_byte :: proc(t: ^Term, b: u8) {
    switch b {
    case 0x1b:
        params_reset(t)
        t.state = .Escape
    case 0x18, 0x1a:
        t.state = .Ground
    }
}

// ---- C0 ----------------------------------------------------------------------

@(private = "file")
execute :: proc(t: ^Term, b: u8) {
    switch b {
    case 0x07: // BEL
        t.bell += 1
    case 0x08: // BS
        cursor_left(t, 1)
    case 0x09: // HT
        put_tab(t, 1)
    case 0x0a, 0x0b, 0x0c: // LF, VT, FF
        line_feed(t)
        if t.newline_mode {
            carriage_return(t)
        }
    case 0x0d: // CR
        carriage_return(t)
    case 0x0e: // SO: GL takes G1
        t.gl = 1
    case 0x0f: // SI: GL takes G0
        t.gl = 0
    }
}
