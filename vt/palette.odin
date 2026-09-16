package vt

// The xterm 256-colour palette: sixteen system colours, a 6x6x6 cube and a
// 24-step grey ramp. The host overwrites the first sixteen with the theme's own
// so terminal colours follow the editor, and OSC 4 can move any of them.
palette_default :: proc() -> [256][3]u8 {
    p: [256][3]u8

    system := [16][3]u8 {
        {0x00, 0x00, 0x00},
        {0xcd, 0x00, 0x00},
        {0x00, 0xcd, 0x00},
        {0xcd, 0xcd, 0x00},
        {0x00, 0x00, 0xee},
        {0xcd, 0x00, 0xcd},
        {0x00, 0xcd, 0xcd},
        {0xe5, 0xe5, 0xe5},
        {0x7f, 0x7f, 0x7f},
        {0xff, 0x00, 0x00},
        {0x00, 0xff, 0x00},
        {0xff, 0xff, 0x00},
        {0x5c, 0x5c, 0xff},
        {0xff, 0x00, 0xff},
        {0x00, 0xff, 0xff},
        {0xff, 0xff, 0xff},
    }
    for c, i in system {
        p[i] = c
    }

    steps := [6]u8{0, 0x5f, 0x87, 0xaf, 0xd7, 0xff}
    i := 16
    for r in 0 ..< 6 {
        for g in 0 ..< 6 {
            for b in 0 ..< 6 {
                p[i] = {steps[r], steps[g], steps[b]}
                i += 1
            }
        }
    }
    for step in 0 ..< 24 {
        level := u8(8 + step * 10)
        p[232 + step] = {level, level, level}
    }
    return p
}

// Parses an X11 colour specification: "#rgb", "#rrggbb", "#rrrgggbbb",
// "#rrrrggggbbbb" or "rgb:rr/gg/bb" with one to four digits a channel.
parse_color_spec :: proc(spec: string) -> ([3]u8, bool) {
    text := spec
    if len(text) > 4 && (text[:4] == "rgb:" || text[:4] == "RGB:") {
        return parse_rgb_slashed(text[4:])
    }
    if len(text) < 4 || text[0] != '#' {
        return {}, false
    }
    digits := text[1:]
    if len(digits) % 3 != 0 || len(digits) > 12 {
        return {}, false
    }
    width := len(digits) / 3
    out: [3]u8
    for i in 0 ..< 3 {
        value, ok := parse_hex(digits[i * width:][:width])
        if !ok {
            return {}, false
        }
        out[i] = scale_channel(value, width)
    }
    return out, true
}

@(private = "file")
parse_rgb_slashed :: proc(text: string) -> ([3]u8, bool) {
    out: [3]u8
    rest := text
    for i in 0 ..< 3 {
        end := len(rest)
        for j in 0 ..< len(rest) {
            if rest[j] == '/' {
                end = j
                break
            }
        }
        if end == 0 || end > 4 {
            return {}, false
        }
        value, ok := parse_hex(rest[:end])
        if !ok {
            return {}, false
        }
        out[i] = scale_channel(value, end)
        if i < 2 {
            if end >= len(rest) {
                return {}, false
            }
            rest = rest[end + 1:]
        }
    }
    return out, true
}

// Widens a channel of `width` hex digits to eight bits, the way X11 does.
@(private = "file")
scale_channel :: proc(value: int, width: int) -> u8 {
    switch width {
    case 1:
        return u8(value * 17)
    case 2:
        return u8(value)
    case 3:
        return u8(value >> 4)
    case 4:
        return u8(value >> 8)
    }
    return 0
}

@(private = "file")
parse_hex :: proc(text: string) -> (int, bool) {
    if len(text) == 0 {
        return 0, false
    }
    value := 0
    for c in transmute([]u8) text {
        digit: int
        switch {
        case c >= '0' && c <= '9':
            digit = int(c - '0')
        case c >= 'a' && c <= 'f':
            digit = int(c - 'a') + 10
        case c >= 'A' && c <= 'F':
            digit = int(c - 'A') + 10
        case:
            return 0, false
        }
        value = value * 16 + digit
    }
    return value, true
}
