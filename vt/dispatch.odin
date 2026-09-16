package vt

import "core:encoding/base64"
import "core:fmt"
import "core:strconv"
import "core:strings"

// What each finished sequence does. The parser only recognises shapes; every
// meaning lives here.

// The answer to a primary device attributes request: a VT220 that speaks ANSI
// colour, which is what a program tests before it sends colour.
@(private = "file")
DA1 :: "\x1b[?62;1;2;6;22c"

// ---- ESC ---------------------------------------------------------------------

@(private)
esc_dispatch :: proc(t: ^Term, final: u8) {
    if t.inter_n > 0 {
        esc_with_intermediate(t, final)
        return
    }
    switch final {
    case 'D': // IND
        line_feed(t)
    case 'E': // NEL
        next_line(t)
    case 'H': // HTS
        if t.cur.x < len(t.tabs) {
            t.tabs[t.cur.x] = true
        }
    case 'M': // RI
        reverse_index(t)
    case 'N': // SS2
        t.single_shift = 2
    case 'O': // SS3
        t.single_shift = 3
    case 'Z': // DECID, the old spelling of DA
        reply(t, DA1)
    case 'c': // RIS
        term_reset(t)
    case '7': // DECSC
        save_cursor(t)
    case '8': // DECRC
        restore_cursor(t)
    case '=': // DECKPAM
        t.app_keypad = true
    case '>': // DECKPNM
        t.app_keypad = false
    case 'n': // LS2
        t.gl = 2
    case 'o': // LS3
        t.gl = 3
    case '~': // LS1R
        t.gr = 1
    case '}': // LS2R
        t.gr = 2
    case '|': // LS3R
        t.gr = 3
    case '\\': // ST, the end of a string that was already dispatched
    }
}

@(private = "file")
esc_with_intermediate :: proc(t: ^Term, final: u8) {
    switch t.inter[0] {
    case '(', ')', '*', '+': // SCS: designate G0 to G3
        slot := int(t.inter[0] - '(')
        set: Charset
        switch final {
        case '0':
            set = .Dec_Graphics
        case 'A':
            set = .Uk
        case:
            set = .Ascii
        }
        t.charsets[slot] = set
    case '#':
        // DECALN; the double-width and double-height line controls are read and
        // dropped, since every row here is one height.
        if final == '8' {
            screen_align_test(t)
        }
    case '%': // Character set selection; the stream is always UTF-8.
    case ' ': // S7C1T and S8C1T: replies stay seven-bit either way.
    }
}

// ---- CSI ---------------------------------------------------------------------

@(private)
csi_dispatch :: proc(t: ^Term, final: u8) {
    p := t.params

    // The private-marker sequences are a language of their own.
    if t.private == '?' {
        csi_private(t, final)
        return
    }
    if t.private == '>' {
        switch final {
        case 'c': // Secondary device attributes: a VT220 at version 10.
            reply(t, "\x1b[>1;10;0c")
        case 'm', 'n', 'q': // modifyOtherKeys and the version report
        }
        return
    }
    if t.private == '=' {
        return // Tertiary attributes and keyboard selects, none of them acted on.
    }

    if t.inter_n > 0 {
        csi_with_intermediate(t, final)
        return
    }

    switch final {
    case '@': // ICH
        insert_chars(t, param(p, 0, 1))
    case 'A': // CUU
        cursor_up(t, param(p, 0, 1))
    case 'B', 'e': // CUD, VPR
        cursor_down(t, param(p, 0, 1))
    case 'C', 'a': // CUF, HPR
        cursor_right(t, param(p, 0, 1))
    case 'D': // CUB
        cursor_left(t, param(p, 0, 1))
    case 'E': // CNL
        cursor_down(t, param(p, 0, 1))
        carriage_return(t)
    case 'F': // CPL
        cursor_up(t, param(p, 0, 1))
        carriage_return(t)
    case 'G', '`': // CHA, HPA
        cursor_move(t, param(p, 0, 1) - 1, t.origin ? t.cur.y - t.top : t.cur.y)
    case 'H', 'f': // CUP, HVP
        cursor_move(t, param(p, 1, 1) - 1, param(p, 0, 1) - 1)
    case 'I': // CHT
        put_tab(t, param(p, 0, 1))
    case 'J': // ED
        erase_display(t, param(p, 0, 0))
    case 'K': // EL
        erase_line(t, param(p, 0, 0))
    case 'L': // IL
        insert_lines(t, param(p, 0, 1))
    case 'M': // DL
        delete_lines(t, param(p, 0, 1))
    case 'P': // DCH
        delete_chars(t, param(p, 0, 1))
    case 'S': // SU
        scroll_up(t, param(p, 0, 1))
    case 'T': // SD
        scroll_down(t, param(p, 0, 1))
    case 'X': // ECH
        erase_chars(t, param(p, 0, 1))
    case 'Z': // CBT
        put_backtab(t, param(p, 0, 1))
    case 'b': // REP
        repeat_last(t, t.last_rune, param(p, 0, 1))
    case 'c': // DA
        reply(t, DA1)
    case 'd': // VPA
        cursor_move(t, t.cur.x, param(p, 0, 1) - 1)
    case 'g': // TBC
        csi_tab_clear(t, param(p, 0, 0))
    case 'h': // SM
        csi_set_mode(t, true)
    case 'l': // RM
        csi_set_mode(t, false)
    case 'm': // SGR
        sgr(t, p)
    case 'n': // DSR
        csi_device_status(t, param(p, 0, 0))
    case 'r': // DECSTBM
        csi_set_region(t, param(p, 0, 1), param(p, 1, t.rows))
    case 's': // SCOSC
        save_cursor(t)
    case 't': // XTWINOPS
        csi_window_op(t, p)
    case 'u': // SCORC
        restore_cursor(t)
    }
}

@(private = "file")
csi_with_intermediate :: proc(t: ^Term, final: u8) {
    p := t.params
    switch t.inter[0] {
    case ' ':
        if final == 'q' { // DECSCUSR
            csi_cursor_style(t, param(p, 0, 1))
        }
    case '"':
        switch final {
        case 'q': // DECSCA: whether an erase may take these cells
            if param(p, 0, 0) == 1 {
                t.cur.pen.attrs += {.Protected}
            } else {
                t.cur.pen.attrs -= {.Protected}
            }
        case 'p': // DECSCL: the level is fixed
        }
    case '!':
        if final == 'p' { // DECSTR
            term_soft_reset(t)
        }
    case '$':
        if final == 'p' { // DECRQM, ANSI modes
            csi_report_mode(t, param(p, 0, 0), false)
        }
    }
}

@(private = "file")
csi_private :: proc(t: ^Term, final: u8) {
    p := t.params
    switch final {
    case 'h':
        for i in 0 ..< max(p.n, 1) {
            dec_mode(t, param(p, i, 0), true)
        }
    case 'l':
        for i in 0 ..< max(p.n, 1) {
            dec_mode(t, param(p, i, 0), false)
        }
    case 'J': // DECSED, taken as ED: a protected cell is rare and this keeps one rule
        erase_display(t, param(p, 0, 0))
    case 'K': // DECSEL
        erase_line(t, param(p, 0, 0))
    case 'n': // DEC device status
        if param(p, 0, 0) == 6 {
            y := t.origin ? t.cur.y - t.top : t.cur.y
            reply(t, fmt.tprintf("\x1b[?%d;%d;1R", y + 1, t.cur.x + 1))
        }
    case 'c': // DA with a private marker: the same answer
        reply(t, DA1)
    case 'p': // DECRQM, DEC private modes
        if t.inter_n > 0 && t.inter[0] == '$' {
            csi_report_mode(t, param(p, 0, 0), true)
        }
    case 'q': // DECSCA and friends behind a private marker
    case 'S': // XTSMGRAPHICS: no sixel support to report
    }
}

@(private = "file")
csi_tab_clear :: proc(t: ^Term, mode: int) {
    switch mode {
    case 0:
        if t.cur.x < len(t.tabs) {
            t.tabs[t.cur.x] = false
        }
    case 3, 5:
        for i in 0 ..< len(t.tabs) {
            t.tabs[i] = false
        }
    }
}

@(private = "file")
csi_set_region :: proc(t: ^Term, top, bottom: int) {
    top := clamp(top - 1, 0, t.rows - 1)
    bottom := clamp(bottom - 1, 0, t.rows - 1)
    // A region of fewer than two rows is refused, which is what leaves a
    // terminal scrolling whole-screen after a bad request.
    if bottom <= top {
        top, bottom = 0, t.rows - 1
    }
    t.top, t.bottom = top, bottom
    cursor_move(t, 0, 0)
}

@(private = "file")
csi_cursor_style :: proc(t: ^Term, style: int) {
    switch style {
    case 0, 1:
        t.cursor_style, t.cursor_blink = .Block, true
    case 2:
        t.cursor_style, t.cursor_blink = .Block, false
    case 3:
        t.cursor_style, t.cursor_blink = .Underline, true
    case 4:
        t.cursor_style, t.cursor_blink = .Underline, false
    case 5:
        t.cursor_style, t.cursor_blink = .Bar, true
    case 6:
        t.cursor_style, t.cursor_blink = .Bar, false
    }
}

@(private = "file")
csi_device_status :: proc(t: ^Term, request: int) {
    switch request {
    case 5: // Terminal status: always fine
        reply(t, "\x1b[0n")
    case 6: // Cursor position
        y := t.origin ? t.cur.y - t.top : t.cur.y
        reply(t, fmt.tprintf("\x1b[%d;%dR", y + 1, t.cur.x + 1))
    }
}

@(private = "file")
csi_window_op :: proc(t: ^Term, p: Params) {
    switch param(p, 0, 0) {
    case 11: // Window state: never iconified
        reply(t, "\x1b[1t")
    case 13: // Window position, which a panel inside an editor has none of
        reply(t, "\x1b[3;0;0t")
    case 14: // Text area in pixels
        reply(t, fmt.tprintf("\x1b[4;%d;%dt", t.rows * t.cell_h, t.cols * t.cell_w))
    case 16: // Cell size in pixels
        reply(t, fmt.tprintf("\x1b[6;%d;%dt", t.cell_h, t.cell_w))
    case 18, 19: // Text area and screen in characters
        reply(t, fmt.tprintf("\x1b[8;%d;%dt", t.rows, t.cols))
    case 20: // Icon label
        reply(t, fmt.tprintf("\x1b]L%s\x1b\\", t.icon_title))
    case 21: // Window title
        reply(t, fmt.tprintf("\x1b]l%s\x1b\\", t.title))
    case 22: // Push the title
        if len(t.title_stack) < 16 {
            append(&t.title_stack, strings.clone(t.title, t.allocator))
        }
    case 23: // Pop the title
        if len(t.title_stack) > 0 {
            top := pop(&t.title_stack)
            set_title(t, top)
            delete(top, t.allocator)
        }
    }
}

// ---- modes -------------------------------------------------------------------

@(private = "file")
csi_set_mode :: proc(t: ^Term, on: bool) {
    p := t.params
    for i in 0 ..< max(p.n, 1) {
        switch param(p, i, 0) {
        case 4: // IRM
            t.insert = on
        case 20: // LNM
            t.newline_mode = on
        }
    }
}

@(private = "file")
dec_mode :: proc(t: ^Term, mode: int, on: bool) {
    switch mode {
    case 1: // DECCKM
        t.app_cursor = on
    case 3: // DECCOLM: the width is the panel's, but the screen still clears
        erase_display(t, 2)
        cursor_move(t, 0, 0)
        t.top, t.bottom = 0, t.rows - 1
    case 5: // DECSCNM
        t.reverse_video = on
    case 6: // DECOM
        t.origin = on
        cursor_move(t, 0, 0)
    case 7: // DECAWM
        t.autowrap = on
    case 9: // X10 mouse
        t.mouse_track = on ? .X10 : .Off
    case 12: // Cursor blink
        t.cursor_blink = on
    case 25: // DECTCEM
        t.cursor_visible = on
    case 45: // Reverse wrap
        t.reverse_wrap = on
    case 47:
        set_alt_screen(t, on, false, false)
    case 66: // DECNKM
        t.app_keypad = on
    case 1000:
        t.mouse_track = on ? .Normal : .Off
    case 1002:
        t.mouse_track = on ? .Button : .Off
    case 1003:
        t.mouse_track = on ? .Any : .Off
    case 1004:
        t.focus_events = on
    case 1005:
        t.mouse_encoding = on ? .Utf8 : .X10
    case 1006, 1016: // SGR, and SGR in pixels which reports the same cells
        t.mouse_encoding = on ? .Sgr : .X10
    case 1015:
        t.mouse_encoding = on ? .Urxvt : .X10
    case 1047:
        set_alt_screen(t, on, false, on)
    case 1048:
        if on {
            save_cursor(t)
        } else {
            restore_cursor(t)
        }
    case 1049:
        set_alt_screen(t, on, true, on)
    case 2004:
        t.bracketed_paste = on
    case 2026:
        t.sync_output = on
    }
}

// DECRQM: 1 says the mode is set, 2 that it is reset, 0 that it is not one this
// terminal knows.
@(private = "file")
csi_report_mode :: proc(t: ^Term, mode: int, private: bool) {
    state, known := mode_state(t, mode, private)
    value := 0
    if known {
        value = state ? 1 : 2
    }
    if private {
        reply(t, fmt.tprintf("\x1b[?%d;%d$y", mode, value))
    } else {
        reply(t, fmt.tprintf("\x1b[%d;%d$y", mode, value))
    }
}

@(private = "file")
mode_state :: proc(t: ^Term, mode: int, private: bool) -> (bool, bool) {
    if !private {
        switch mode {
        case 4:
            return t.insert, true
        case 20:
            return t.newline_mode, true
        }
        return false, false
    }
    switch mode {
    case 1:
        return t.app_cursor, true
    case 5:
        return t.reverse_video, true
    case 6:
        return t.origin, true
    case 7:
        return t.autowrap, true
    case 9:
        return t.mouse_track == .X10, true
    case 12:
        return t.cursor_blink, true
    case 25:
        return t.cursor_visible, true
    case 45:
        return t.reverse_wrap, true
    case 47, 1047, 1049:
        return t.alt_active, true
    case 66:
        return t.app_keypad, true
    case 1000:
        return t.mouse_track == .Normal, true
    case 1002:
        return t.mouse_track == .Button, true
    case 1003:
        return t.mouse_track == .Any, true
    case 1004:
        return t.focus_events, true
    case 1006:
        return t.mouse_encoding == .Sgr, true
    case 2004:
        return t.bracketed_paste, true
    case 2026:
        return t.sync_output, true
    }
    return false, false
}

// ---- SGR ---------------------------------------------------------------------

@(private = "file")
sgr :: proc(t: ^Term, p: Params) {
    if p.n == 0 {
        t.cur.pen = {link = t.cur.pen.link}
        return
    }
    pen := &t.cur.pen
    for i := 0; i < p.n; i += 1 {
        // A sub-argument is read by the argument that owns it.
        if p.sub[i] {
            continue
        }
        code := param(p, i, 0)
        switch code {
        case 0:
            pen^ = {link = pen.link}
        case 1:
            pen.attrs += {.Bold}
        case 2:
            pen.attrs += {.Dim}
        case 3:
            pen.attrs += {.Italic}
        case 4:
            pen.underline = sgr_underline(p, i)
        case 5:
            pen.attrs += {.Blink}
        case 6:
            pen.attrs += {.Fast_Blink}
        case 7:
            pen.attrs += {.Reverse}
        case 8:
            pen.attrs += {.Hidden}
        case 9:
            pen.attrs += {.Strike}
        case 21:
            pen.underline = .Double
        case 22:
            pen.attrs -= {.Bold, .Dim}
        case 23:
            pen.attrs -= {.Italic}
        case 24:
            pen.underline = .None
        case 25:
            pen.attrs -= {.Blink, .Fast_Blink}
        case 27:
            pen.attrs -= {.Reverse}
        case 28:
            pen.attrs -= {.Hidden}
        case 29:
            pen.attrs -= {.Strike}
        case 38:
            pen.fg = sgr_color(p, &i, pen.fg)
        case 39:
            pen.fg = {}
        case 48:
            pen.bg = sgr_color(p, &i, pen.bg)
        case 49:
            pen.bg = {}
        case 53:
            pen.attrs += {.Overline}
        case 55:
            pen.attrs -= {.Overline}
        case 58:
            pen.ul = sgr_color(p, &i, pen.ul)
        case 59:
            pen.ul = {}
        case 30 ..= 37:
            pen.fg = color_indexed(code - 30)
        case 40 ..= 47:
            pen.bg = color_indexed(code - 40)
        case 90 ..= 97:
            pen.fg = color_indexed(code - 90 + 8)
        case 100 ..= 107:
            pen.bg = color_indexed(code - 100 + 8)
        }
    }
}

// The style a `4:n` sub-argument asks for. A plain 4 is a single underline.
@(private = "file")
sgr_underline :: proc(p: Params, index: int) -> Underline {
    if index + 1 >= p.n || !p.sub[index + 1] {
        return .Single
    }
    switch param(p, index + 1, 1) {
    case 0:
        return .None
    case 1:
        return .Single
    case 2:
        return .Double
    case 3:
        return .Curly
    case 4:
        return .Dotted
    case 5:
        return .Dashed
    }
    return .Single
}

// Reads the extended colour behind 38, 48 or 58, in either spelling: the
// semicolon form consumes the arguments that follow, the colon form reads the
// sub-arguments of this one. `index` is left on the last argument taken.
@(private = "file")
sgr_color :: proc(p: Params, index: ^int, fallback: Color) -> Color {
    i := index^
    // The run of sub-arguments that belongs to this argument.
    last := i
    for last + 1 < p.n && p.sub[last + 1] {
        last += 1
    }

    if last > i {
        index^ = last
        switch param(p, i + 1, 0) {
        case 5:
            return color_indexed(param(p, i + 2, 0))
        case 2:
            // 38:2:<space>:r:g:b carries a colour space that is not used here,
            // and 38:2:r:g:b leaves it out.
            base := last - i >= 5 ? i + 3 : i + 2
            return color_rgb(
                u8(clamp(param(p, base, 0), 0, 255)),
                u8(clamp(param(p, base + 1, 0), 0, 255)),
                u8(clamp(param(p, base + 2, 0), 0, 255)),
            )
        }
        return fallback
    }

    switch param(p, i + 1, 0) {
    case 5:
        if i + 2 >= p.n {
            return fallback
        }
        index^ = i + 2
        return color_indexed(param(p, i + 2, 0))
    case 2:
        if i + 4 >= p.n {
            return fallback
        }
        index^ = i + 4
        return color_rgb(
            u8(clamp(param(p, i + 2, 0), 0, 255)),
            u8(clamp(param(p, i + 3, 0), 0, 255)),
            u8(clamp(param(p, i + 4, 0), 0, 255)),
        )
    }
    return fallback
}

// ---- OSC ---------------------------------------------------------------------

@(private)
osc_dispatch :: proc(t: ^Term, text: string) {
    if text == "" {
        return
    }
    command, rest := osc_split(text)
    switch command {
    case 0:
        set_title(t, rest)
        set_icon_title(t, rest)
    case 1:
        set_icon_title(t, rest)
    case 2:
        set_title(t, rest)
    case 4:
        osc_palette(t, rest)
    case 7:
        osc_cwd(t, rest)
    case 8:
        osc_hyperlink(t, rest)
    case 10:
        osc_dynamic_color(t, 10, &t.default_fg, rest)
    case 11:
        osc_dynamic_color(t, 11, &t.default_bg, rest)
    case 12:
        osc_dynamic_color(t, 12, &t.cursor_color, rest)
    case 52:
        osc_clipboard(t, rest)
    case 104:
        osc_reset_palette(t, rest)
    case 110:
        t.default_fg = {}
    case 111:
        t.default_bg = {}
    case 112:
        t.cursor_color = {}
    case 133:
        osc_shell_mark(t, rest)
    }
}

// Splits "4;1;#ff0000" into 4 and "1;#ff0000". A string with no numeric command
// reports -1, which nothing acts on.
@(private = "file")
osc_split :: proc(text: string) -> (int, string) {
    end := strings.index_byte(text, ';')
    head := end < 0 ? text : text[:end]
    rest := end < 0 ? "" : text[end + 1:]
    command, ok := strconv.parse_int(head)
    if !ok {
        return -1, rest
    }
    return command, rest
}

@(private = "file")
set_title :: proc(t: ^Term, text: string) {
    delete(t.title, t.allocator)
    t.title = strings.clone(text, t.allocator)
}

@(private = "file")
set_icon_title :: proc(t: ^Term, text: string) {
    delete(t.icon_title, t.allocator)
    t.icon_title = strings.clone(text, t.allocator)
}

// OSC 4: index;spec pairs, where a spec of "?" asks for the colour instead.
@(private = "file")
osc_palette :: proc(t: ^Term, rest: string) {
    fields := strings.split(rest, ";", context.temp_allocator)
    for i := 0; i + 1 < len(fields); i += 2 {
        index, ok := strconv.parse_int(fields[i])
        if !ok || index < 0 || index > 255 {
            continue
        }
        spec := fields[i + 1]
        if spec == "?" {
            c := t.palette[index]
            reply(
                t,
                fmt.tprintf(
                    "\x1b]4;%d;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\\",
                    index, c[0], c[0], c[1], c[1], c[2], c[2],
                ),
            )
            continue
        }
        if rgb, parsed := parse_color_spec(spec); parsed {
            t.palette[index] = rgb
        }
    }
}

// OSC 104: the entries named go back to the built-in palette, all of them when
// none is named.
@(private = "file")
osc_reset_palette :: proc(t: ^Term, rest: string) {
    if rest == "" {
        t.palette = t.default_palette
        return
    }
    for field in strings.split(rest, ";", context.temp_allocator) {
        if index, ok := strconv.parse_int(field); ok && index >= 0 && index <= 255 {
            t.palette[index] = t.default_palette[index]
        }
    }
}

// OSC 10, 11 and 12: set the colour, or answer with it when the spec is "?".
@(private = "file")
osc_dynamic_color :: proc(t: ^Term, command: int, slot: ^[3]u8, spec: string) {
    if spec == "?" {
        c := slot^
        reply(
            t,
            fmt.tprintf(
                "\x1b]%d;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\\",
                command, c[0], c[0], c[1], c[1], c[2], c[2],
            ),
        )
        return
    }
    if rgb, ok := parse_color_spec(spec); ok {
        slot^ = rgb
    }
}

// OSC 7: the shell reporting where it is, as file://host/path.
@(private = "file")
osc_cwd :: proc(t: ^Term, uri: string) {
    path := uri
    if strings.has_prefix(path, "file://") {
        path = path[len("file://"):]
        if slash := strings.index_byte(path, '/'); slash >= 0 {
            path = path[slash:]
        }
    }
    decoded := percent_decode(path, context.temp_allocator)
    // A Windows path arrives as /C:/dir; the leading slash is not part of it.
    if len(decoded) > 2 && decoded[0] == '/' && decoded[2] == ':' {
        decoded = decoded[1:]
    }
    delete(t.cwd, t.allocator)
    t.cwd = strings.clone(decoded, t.allocator)
}

// OSC 8: params;uri. An empty URI ends the run of linked cells.
@(private = "file")
osc_hyperlink :: proc(t: ^Term, rest: string) {
    end := strings.index_byte(rest, ';')
    uri := end < 0 ? "" : rest[end + 1:]
    if uri == "" {
        t.cur.pen.link = 0
        return
    }
    if len(t.links) >= MAX_LINKS {
        t.cur.pen.link = 0
        return
    }
    append(&t.links, strings.clone(uri, t.allocator))
    t.cur.pen.link = u32(len(t.links) - 1)
}

// OSC 52: targets;base64. A query is not answered — the clipboard is the user's
// to give, not a program's to read.
@(private = "file")
osc_clipboard :: proc(t: ^Term, rest: string) {
    end := strings.index_byte(rest, ';')
    if end < 0 {
        return
    }
    payload := rest[end + 1:]
    if payload == "" || payload == "?" {
        return
    }
    decoded, err := base64.decode(payload, allocator = context.temp_allocator)
    if err != nil {
        return
    }
    delete(t.clipboard, t.allocator)
    t.clipboard = strings.clone(string(decoded), t.allocator)
    t.clipboard_ready = true
}

// OSC 133: the shell integration marks. Only the command end carries anything
// the editor acts on, and only its status.
@(private = "file")
osc_shell_mark :: proc(t: ^Term, rest: string) {
    if rest == "" {
        return
    }
    if rest[0] != 'D' {
        return
    }
    t.command_end = {}
    if len(rest) > 2 && rest[1] == ';' {
        if code, ok := strconv.parse_int(rest[2:]); ok {
            t.command_end = {code = code, known = true}
        }
    }
    t.command_end_ready = true
}

@(private = "file")
percent_decode :: proc(text: string, allocator := context.allocator) -> string {
    if !strings.contains(text, "%") {
        return strings.clone(text, allocator)
    }
    builder := strings.builder_make(allocator)
    for i := 0; i < len(text); {
        if text[i] == '%' && i + 2 < len(text) {
            if value, ok := strconv.parse_int(text[i + 1:][:2], 16); ok {
                strings.write_byte(&builder, u8(value))
                i += 3
                continue
            }
        }
        strings.write_byte(&builder, text[i])
        i += 1
    }
    return strings.to_string(builder)
}

// ---- DCS ---------------------------------------------------------------------

// Only DECRQSS is answered: a program asks how a setting stands and gets it
// back. Everything else, sixel included, is read and dropped.
@(private)
dcs_dispatch :: proc(t: ^Term, payload: string) {
    if t.dcs_final != 'q' || t.inter_n == 0 || t.inter[0] != '$' {
        return
    }
    switch payload {
    case "m": // SGR
        reply(t, "\x1bP1$r0m\x1b\\")
    case "r": // DECSTBM
        reply(t, fmt.tprintf("\x1bP1$r%d;%dr\x1b\\", t.top + 1, t.bottom + 1))
    case " q": // DECSCUSR
        style := 1
        switch t.cursor_style {
        case .Block:
            style = t.cursor_blink ? 1 : 2
        case .Underline:
            style = t.cursor_blink ? 3 : 4
        case .Bar:
            style = t.cursor_blink ? 5 : 6
        }
        reply(t, fmt.tprintf("\x1bP1$r%d q\x1b\\", style))
    case:
        reply(t, "\x1bP0$r\x1b\\")
    }
}
