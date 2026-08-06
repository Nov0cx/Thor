package ui

import "core:slice"
import "core:unicode/utf8"

import hb "../vendor/odin-harfbuzz/harfbuzz"

// One shaping run: a maximal span of one script and one bidi level.
Shape_Run :: struct {
    start:  int, // byte range in the line
    end:    int,
    script: hb.script_t,
    level:  u8, // even is left to right, odd is right to left
}

// The base direction of every line. A right-to-left run still reads right to
// left, but the line itself starts on the left, which is what keeps the gutter,
// the indentation and the caret geometry in place.
@(private = "file")
BASE_CLASS :: Bidi_Class.Left

// The bidi classes the resolver keeps apart. The Unicode set folds into these
// four. Explicit embedding controls and isolates are not supported.
@(private = "file")
Bidi_Class :: enum u8 {
    Neutral,
    Left,
    Right,
    Number,
}

@(private = "file")
Char_Info :: struct {
    offset: int, // byte offset in the line
    class:  Bidi_Class,
    script: hb.script_t,
    level:  u8,
}

// HarfBuzz Unicode tables, used for the script of one rune.
@(private = "file")
unicode_funcs: ^hb.unicode_funcs_t

// Splits one line into shaping runs, in visual order. The result lives in the
// temp allocator, so it dies with the frame that made it.
shape_itemize :: proc(line: string, allocator := context.temp_allocator) -> []Shape_Run {
    if line == "" {
        return nil
    }
    // An ASCII line is one left-to-right Latin run, which skips the scan.
    if is_ascii(line) {
        runs := make([]Shape_Run, 1, allocator)
        runs[0] = Shape_Run {start = 0, end = len(line), script = .SCRIPT_LATIN}
        return runs
    }

    // One rune per byte is the worst case, so the scan allocates once.
    chars := make([dynamic]Char_Info, 0, len(line), allocator)
    classify(line, &chars)
    resolve_levels(chars[:])
    resolve_scripts(chars[:])

    runs := make([dynamic]Shape_Run, 0, 8, allocator)
    build_runs(line, chars[:], &runs)
    reorder_runs(runs[:])
    return runs[:]
}

@(private = "file")
is_ascii :: proc(line: string) -> bool {
    for i in 0 ..< len(line) {
        if line[i] >= 0x80 {
            return false
        }
    }
    return true
}

@(private = "file")
classify :: proc(line: string, chars: ^[dynamic]Char_Info) {
    if unicode_funcs == nil {
        unicode_funcs = hb.unicode_funcs_get_default()
    }

    offset := 0
    for offset < len(line) {
        r, size := utf8.decode_rune_in_string(line[offset:])
        if size == 0 {
            size = 1
        }
        script := rune_script(r)
        append(chars, Char_Info {offset = offset, class = rune_class(r, script), script = script})
        offset += size
    }
}

@(private = "file")
rune_script :: proc(r: rune) -> hb.script_t {
    if r < 0x80 {
        if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
            return .SCRIPT_LATIN
        }
        return .SCRIPT_COMMON
    }
    return hb.unicode_script(unicode_funcs, cast(hb.codepoint_t) r)
}

// A script a run can shape with. The other three attach to a neighbour.
@(private = "file")
script_is_real :: proc(script: hb.script_t) -> bool {
    #partial switch script {
    case .SCRIPT_COMMON, .SCRIPT_INHERITED, .SCRIPT_UNKNOWN, .SCRIPT_INVALID:
        return false
    }
    return true
}

@(private = "file")
rune_class :: proc(r: rune, script: hb.script_t) -> Bidi_Class {
    // Digits keep their own direction inside right-to-left text, so they come
    // before the script test: the Arabic ones carry an Arabic script.
    switch {
    case r >= '0' && r <= '9':
        return .Number
    case r >= 0x0660 && r <= 0x0669: // Arabic-Indic
        return .Number
    case r >= 0x06F0 && r <= 0x06F9: // extended Arabic-Indic
        return .Number
    }
    if !script_is_real(script) {
        return .Neutral
    }
    if hb.script_get_horizontal_direction(script) == .DIRECTION_RTL {
        return .Right
    }
    return .Left
}

// Rule W7 and rules N1/N2 folded together, then the levels of rule I1: a number
// after left-to-right text joins it, a neutral span takes the direction it sits
// between, and everything else takes the base direction.
@(private = "file")
resolve_levels :: proc(chars: []Char_Info) {
    last_strong := BASE_CLASS
    for &ch in chars {
        #partial switch ch.class {
        case .Left, .Right:
            last_strong = ch.class
        case .Number:
            if last_strong == .Left {
                ch.class = .Left
            }
        }
    }

    i := 0
    for i < len(chars) {
        if chars[i].class != .Neutral {
            i += 1
            continue
        }
        j := i
        for j < len(chars) && chars[j].class == .Neutral {
            j += 1
        }
        // Both line ends count as the base direction (sos and eos).
        before := i > 0 ? strong_side(chars[i - 1].class) : BASE_CLASS
        after := j < len(chars) ? strong_side(chars[j].class) : BASE_CLASS
        resolved := before == after ? before : BASE_CLASS
        for k in i ..< j {
            chars[k].class = resolved
        }
        i = j
    }

    for &ch in chars {
        switch ch.class {
        case .Left:
            ch.level = 0
        case .Right:
            ch.level = 1
        case .Number:
            ch.level = 2
        case .Neutral: // resolved above
            ch.level = 0
        }
    }
}

// Rule N1 reads a number as right-to-left text.
@(private = "file")
strong_side :: proc(class: Bidi_Class) -> Bidi_Class {
    return class == .Left ? .Left : .Right
}

// Gives every neutral character the script of its neighbour, so that one line of
// code stays one run.
@(private = "file")
resolve_scripts :: proc(chars: []Char_Info) {
    inherited := hb.script_t.SCRIPT_INVALID
    first := -1
    for &ch, i in chars {
        if script_is_real(ch.script) {
            inherited = ch.script
            if first < 0 {
                first = i
            }
            continue
        }
        if first >= 0 {
            ch.script = inherited
        }
    }

    // A line that starts with punctuation has nothing before it to inherit.
    lead := first >= 0 ? chars[first].script : hb.script_t.SCRIPT_LATIN
    for i in 0 ..< (first >= 0 ? first : len(chars)) {
        chars[i].script = lead
    }
}

@(private = "file")
build_runs :: proc(line: string, chars: []Char_Info, runs: ^[dynamic]Shape_Run) {
    for ch, i in chars {
        end := i + 1 < len(chars) ? chars[i + 1].offset : len(line)
        if len(runs) > 0 {
            last := &runs[len(runs) - 1]
            if last.level == ch.level && last.script == ch.script {
                last.end = end
                continue
            }
        }
        append(runs, Shape_Run {start = ch.offset, end = end, script = ch.script, level = ch.level})
    }
}

// Rule L2: reverse the runs of every level, the highest first, down to the
// lowest odd one.
@(private = "file")
reorder_runs :: proc(runs: []Shape_Run) {
    highest: u8 = 0
    lowest_odd := max(u8)
    for run in runs {
        highest = max(highest, run.level)
        if run.level % 2 == 1 {
            lowest_odd = min(lowest_odd, run.level)
        }
    }
    if lowest_odd > highest {
        return
    }

    for level := highest; level >= lowest_odd; level -= 1 {
        i := 0
        for i < len(runs) {
            if runs[i].level < level {
                i += 1
                continue
            }
            j := i
            for j < len(runs) && runs[j].level >= level {
                j += 1
            }
            slice.reverse(runs[i:j])
            i = j
        }
    }
}
