// Bracket and quote matching that knows strings and comments. A language is
// described by its markers alone, so no parse tree is needed: the buffer is
// scanned once per query for the ranges a bracket search must not count.
package textedit

import "core:strings"

// How a language writes comments and strings. The strings are borrowed.
Lexical :: struct {
    line_comment: string,
    block_open:   string,
    block_close:  string,
    // The bytes that open and close a string. "" stands for " ' and `.
    quotes:       string,
}

@(private)
Skip_Kind :: enum u8 {
    String,
    Comment,
}

// One string or comment, markers included.
@(private)
Skip_Range :: struct {
    start, end: int,
    kind:       Skip_Kind,
}

// Sets the comment and string syntax bracket matching uses. Borrowed: the
// strings must outlive the state or the next call.
set_lexical :: proc(state: ^State, lex: Lexical) {
    state.lexical = lex
}

@(private)
DEFAULT_QUOTES :: "\"'`"

// The strings and comments of `txt`, ascending and disjoint. Temp allocator.
@(private)
skip_ranges :: proc(txt: string, lex: Lexical) -> []Skip_Range {
    ranges := make([dynamic]Skip_Range, context.temp_allocator)
    quotes := lex.quotes == "" ? DEFAULT_QUOTES : lex.quotes

    i := 0
    for i < len(txt) {
        b := txt[i]
        switch {
        case lex.line_comment != "" && strings.has_prefix(txt[i:], lex.line_comment):
            end := line_end(txt, i)
            append(&ranges, Skip_Range {i, end, .Comment})
            i = end
        case lex.block_open != "" && strings.has_prefix(txt[i:], lex.block_open):
            body := i + len(lex.block_open)
            end := len(txt)
            if at := strings.index(txt[body:], lex.block_close); at >= 0 {
                end = body + at + len(lex.block_close)
            }
            append(&ranges, Skip_Range {i, end, .Comment})
            i = end
        case is_quote_byte(b):
            if end, ok := string_end(txt, i, strings.index_byte(quotes, b) >= 0); ok {
                append(&ranges, Skip_Range {i, end, .String})
                i = end
            } else {
                i += 1
            }
        case:
            i += 1
        }
    }
    return ranges[:]
}

// End of the string that opens at `start`, one past its closing quote. `long`
// is false for a quote the language uses for one character only: then just
// 'x' and '\x...' count. A quote with no partner opens nothing.
@(private)
string_end :: proc(txt: string, start: int, long: bool) -> (end: int, ok: bool) {
    q := txt[start]
    if !long {
        if q != '\'' {
            return 0, false
        }
        return char_literal_end(txt, start)
    }

    // """ and ''' open a string that runs over lines.
    if q != '`' && start + 2 < len(txt) && txt[start + 1] == q && txt[start + 2] == q {
        triple := txt[start:start + 3]
        if at := strings.index(txt[start + 3:], triple); at >= 0 {
            return start + 3 + at + 3, true
        }
    }

    for i := start + 1; i < len(txt); i += 1 {
        switch txt[i] {
        case '\\':
            if q != '`' {
                i += 1
            }
        case '\n':
            if q != '`' {
                return 0, false
            }
        case q:
            return i + 1, true
        }
    }
    return 0, false
}

// End of a character literal: one rune or one escape between two quotes.
@(private)
char_literal_end :: proc(txt: string, start: int) -> (end: int, ok: bool) {
    i := start + 1
    if i >= len(txt) || txt[i] == '\n' || txt[i] == '\'' {
        return 0, false
    }
    if txt[i] == '\\' {
        // An escape is short: \n, \x41, \u{1F600}.
        for j := i + 2; j < len(txt) && j <= i + 12 && txt[j] != '\n'; j += 1 {
            if txt[j] == '\'' {
                return j + 1, true
            }
        }
        return 0, false
    }
    i = grapheme_next(txt, i)
    if i < len(txt) && txt[i] == '\'' {
        return i + 1, true
    }
    return 0, false
}

// Index of the range that holds byte `pos`, or -1.
@(private)
range_at :: proc(ranges: []Skip_Range, pos: int) -> int {
    lo, hi := 0, len(ranges)
    for lo < hi {
        mid := (lo + hi) / 2
        if ranges[mid].end <= pos {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    if lo < len(ranges) && ranges[lo].start <= pos {
        return lo
    }
    return -1
}

// The next byte to read after `i` in direction `step`, past any range that
// starts there. `within` is the range the scan stays in, or -1 for code.
@(private)
scan_step :: proc(ranges: []Skip_Range, i, step, within: int) -> int {
    next := i + step
    if within >= 0 {
        return next
    }
    // Ranges can touch, so one skip can land in the next range.
    for {
        at := range_at(ranges, next)
        if at < 0 {
            return next
        }
        next = step > 0 ? ranges[at].end : ranges[at].start - 1
    }
}

// The bounds a scan from byte `pos` stays in: its own string or comment, else
// the whole text.
@(private)
scan_bounds :: proc(txt: string, ranges: []Skip_Range, pos: int) -> (lo, hi, within: int) {
    within = range_at(ranges, pos)
    if within >= 0 {
        return ranges[within].start, ranges[within].end, within
    }
    return 0, len(txt), -1
}

// Partner of the bracket at `p`. A bracket in code skips strings and comments;
// a bracket inside one matches inside it.
@(private)
bracket_partner :: proc(txt: string, ranges: []Skip_Range, p: int) -> (match: int, forward, found: bool) {
    open, close, fwd, ok := bracket_kind(txt[p])
    if !ok {
        return 0, false, false
    }
    lo, hi, within := scan_bounds(txt, ranges, p)
    depth := 1
    if fwd {
        for i := scan_step(ranges, p, 1, within); i < hi; i = scan_step(ranges, i, 1, within) {
            if txt[i] == open {
                depth += 1
            } else if txt[i] == close {
                depth -= 1
                if depth == 0 {
                    return i, true, true
                }
            }
        }
        return 0, true, false
    }
    for i := scan_step(ranges, p, -1, within); i >= lo; i = scan_step(ranges, i, -1, within) {
        if txt[i] == close {
            depth += 1
        } else if txt[i] == open {
            depth -= 1
            if depth == 0 {
                return i, false, true
            }
        }
    }
    return 0, false, false
}

// Looks for a bracket at `pos` (or just before it) and finds its match.
@(private)
find_matching_bracket :: proc(txt: string, ranges: []Skip_Range, pos: int) -> (bracket_pos, match_pos: int, forward, found: bool) {
    candidates := [2]int {pos, pos - 1}
    for p in candidates {
        if p < 0 || p >= len(txt) {
            continue
        }
        if match, fwd, ok := bracket_partner(txt, ranges, p); ok {
            return p, match, fwd, true
        }
    }
    return 0, 0, false, false
}

// The delimiter pair to act on for a caret: a bracket or quote next to the
// caret, else the innermost pair around it.
bracket_span :: proc(state: ^State, pos: int) -> (open_pos, close_pos: int, found: bool) {
    txt := text(state)
    return bracket_span_in(txt, skip_ranges(txt, state.lexical), pos)
}

@(private)
bracket_span_in :: proc(txt: string, ranges: []Skip_Range, pos: int) -> (open_pos, close_pos: int, found: bool) {
    if bracket_pos, match_pos, forward, ok := find_matching_bracket(txt, ranges, pos); ok {
        if forward {
            return bracket_pos, match_pos, true
        }
        return match_pos, bracket_pos, true
    }
    if quote_pos, match_pos, forward, ok := find_matching_quote(txt, ranges, pos); ok {
        if forward {
            return quote_pos, match_pos, true
        }
        return match_pos, quote_pos, true
    }
    return enclosing_pair(txt, ranges, pos)
}

// Innermost pair around pos, brackets and quotes both: the pair whose opener
// is nearest to pos wins.
@(private)
enclosing_pair :: proc(txt: string, ranges: []Skip_Range, pos: int) -> (open_pos, close_pos: int, found: bool) {
    bo, bc, bok := find_enclosing_bracket(txt, ranges, pos)
    qo, qc, qok := find_enclosing_quote(txt, ranges, pos)
    switch {
    case bok && qok:
        if qo > bo {
            return qo, qc, true
        }
        return bo, bc, true
    case bok:
        return bo, bc, true
    case qok:
        return qo, qc, true
    }
    return 0, 0, false
}

@(private)
is_quote_byte :: proc(b: u8) -> bool {
    return b == '"' || b == '\'' || b == '`'
}

// Partner of a quote at or just before pos: the other end of its string.
@(private)
find_matching_quote :: proc(txt: string, ranges: []Skip_Range, pos: int) -> (quote_pos, match_pos: int, forward, found: bool) {
    candidates := [2]int {pos, pos - 1}
    for p in candidates {
        if p < 0 || p >= len(txt) || !is_quote_byte(txt[p]) {
            continue
        }
        at := range_at(ranges, p)
        if at < 0 || ranges[at].kind != .String {
            continue
        }
        r := ranges[at]
        if p == r.start {
            return p, r.end - 1, true, true
        }
        if p == r.end - 1 {
            return p, r.start, false, true
        }
    }
    return 0, 0, false, false
}

// The string around pos, by its first and last quote.
@(private)
find_enclosing_quote :: proc(txt: string, ranges: []Skip_Range, pos: int) -> (open_pos, close_pos: int, found: bool) {
    at := range_at(ranges, pos)
    if at < 0 || ranges[at].kind != .String || pos <= ranges[at].start {
        return 0, 0, false
    }
    return ranges[at].start, ranges[at].end - 1, true
}

// Innermost bracket pair around pos: scans left for the nearest opener with no
// closer, then takes its partner. Inside a string or a comment the pair in it
// wins, and the code around it is the fallback.
@(private)
find_enclosing_bracket :: proc(txt: string, ranges: []Skip_Range, pos: int) -> (open_pos, close_pos: int, found: bool) {
    at := pos > 0 ? range_at(ranges, pos - 1) : -1
    if at >= 0 && pos < ranges[at].end {
        if open_pos, close_pos, found = enclosing_bracket_in(txt, ranges, pos, at); found {
            return
        }
        // Not inside a pair of its own: the caret stands where the range starts.
        return enclosing_bracket_in(txt, ranges, ranges[at].start, -1)
    }
    return enclosing_bracket_in(txt, ranges, pos, -1)
}

@(private)
enclosing_bracket_in :: proc(txt: string, ranges: []Skip_Range, pos, within: int) -> (open_pos, close_pos: int, found: bool) {
    lo := within >= 0 ? ranges[within].start : 0
    // Closers seen per type on the way left; an opener with none outstanding is
    // the one around pos.
    pending: [3]int // ( ) , [ ] , { }
    for i := scan_step(ranges, min(pos, len(txt)), -1, within); i >= lo; i = scan_step(ranges, i, -1, within) {
        slot := -1
        switch txt[i] {
        case ')': pending[0] += 1
        case ']': pending[1] += 1
        case '}': pending[2] += 1
        case '(': slot = 0
        case '[': slot = 1
        case '{': slot = 2
        }
        if slot < 0 {
            continue
        }
        if pending[slot] > 0 {
            pending[slot] -= 1
            continue
        }
        match, _, ok := bracket_partner(txt, ranges, i)
        return i, match, ok
    }
    return 0, 0, false
}
