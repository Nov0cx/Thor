// Literal and regular-expression search over a whole document. It knows nothing
// about buffers or widgets: a caller hands in the text and gets byte ranges back,
// which is what lets the find bar and any other caller share one scanner.
package search

import "core:text/regex"
import "core:unicode"
import "core:unicode/utf8"

// One match as a byte range. The length is not len(query): a regular expression
// matches spans of its own size, and a case-folded match can change width.
Match :: struct {
    start: int,
    end:   int,
}

Options :: struct {
    case_sensitive: bool,
    whole_word:     bool,
    use_regex:      bool,
}

// Appends every match of `query` in `text` to `out`. False means the pattern is
// a regular expression that does not compile; `out` is left as it was found.
scan :: proc(text, query: string, opts: Options, out: ^[dynamic]Match) -> bool {
    if len(query) == 0 {
        return true
    }
    if opts.use_regex {
        return scan_regex(text, query, opts, out)
    }
    scan_literal(text, query, opts, out)
    return true
}

// Collects regular-expression matches over the whole document. A zero-width
// match is dropped: it selects nothing, and replacing over one would splice
// forever. The replacement stays literal in this mode — no capture references.
@(private)
scan_regex :: proc(text, pattern: string, opts: Options, out: ^[dynamic]Match) -> bool {
    flags: regex.Flags = {.Unicode}
    if !opts.case_sensitive {
        flags += {.Case_Insensitive}
    }
    it, err := regex.create_iterator(text, pattern, flags)
    if err != nil {
        return false
    }
    defer regex.destroy(it)

    for {
        capture, _, ok := regex.match_iterator(&it)
        if !ok {
            break
        }
        if len(capture.pos) == 0 {
            break
        }
        start, end := capture.pos[0][0], capture.pos[0][1]
        if end <= start {
            continue
        }
        if opts.whole_word && !word_bounded(text, start, end) {
            continue
        }
        append(out, Match{start, end})
    }
    return true
}

// Collects literal matches over the whole document. Re-run once per query change
// rather than per byte: the skip table lets a mismatch jump the window ahead
// instead of retrying every start byte, so a keystroke's rescan stays close to
// O(document length) instead of O(document length x query length).
@(private)
scan_literal :: proc(text, query: string, opts: Options, out: ^[dynamic]Match) {
    // A folded non-ASCII query cannot drive the byte-indexed skip table, since a
    // match is not len(query) bytes wide. Rune-wise scan for those, so the fast
    // path still covers every ASCII query.
    if !opts.case_sensitive && !is_ascii(query) {
        for i := 0; i < len(text); {
            if width, found := fold_match_at(text, i, query);
               found && (!opts.whole_word || word_bounded(text, i, i + width)) {
                append(out, Match{i, i + width})
                i += width
                continue
            }
            _, w := utf8.decode_rune_in_string(text[i:])
            i += max(w, 1)
        }
        return
    }

    n := len(query)
    skip := skip_table(query, opts.case_sensitive)
    i := 0
    for i + n <= len(text) {
        if match_at(text, i, query, opts.case_sensitive) {
            if !opts.whole_word || word_bounded(text, i, i + n) {
                append(out, Match{i, i + n})
                i += n
                continue
            }
        }
        i += skip[fold(text[i + n - 1], opts.case_sensitive)]
    }
}

@(private)
fold :: #force_inline proc(c: u8, sensitive: bool) -> u8 {
    return !sensitive && c >= 'A' && c <= 'Z' ? c + 32 : c
}

@(private)
is_ascii :: proc(s: string) -> bool {
    for i in 0 ..< len(s) {
        if s[i] >= 0x80 {
            return false
        }
    }
    return true
}

// Byte length of the case-folded occurrence of `query` at `pos`, and whether
// there is one. Case mapping changes the encoded width — ẞ is three bytes, the
// ß it folds to is two — so a match is not len(query) bytes.
@(private)
fold_match_at :: proc(text: string, pos: int, query: string) -> (int, bool) {
    i, j := pos, 0
    for j < len(query) {
        if i >= len(text) {
            return 0, false
        }
        a, aw := utf8.decode_rune_in_string(text[i:])
        b, bw := utf8.decode_rune_in_string(query[j:])
        if unicode.to_lower(a) != unicode.to_lower(b) {
            return 0, false
        }
        i += aw
        j += bw
    }
    return i - pos, true
}

@(private)
is_word_byte :: proc(b: u8) -> bool {
    return(
        b == '_' ||
        (b >= '0' && b <= '9') ||
        (b >= 'a' && b <= 'z') ||
        (b >= 'A' && b <= 'Z') ||
        b >= 0x80 \
    )
}

// True when [start, end) is not glued to an identifier character on either side.
@(private)
word_bounded :: proc(text: string, start, end: int) -> bool {
    if start > 0 && is_word_byte(text[start - 1]) {
        return false
    }
    if end < len(text) && is_word_byte(text[end]) {
        return false
    }
    return true
}

@(private)
match_at :: proc(text: string, pos: int, query: string, sensitive: bool) -> bool {
    if pos + len(query) > len(text) {
        return false
    }
    for i in 0 ..< len(query) {
        if fold(text[pos + i], sensitive) != fold(query[i], sensitive) {
            return false
        }
    }
    return true
}

// Boyer-Moore-Horspool bad-character table: how far a mismatch at the window's
// last byte lets the search jump ahead, instead of retrying every intervening
// start byte. Absent from the query, a byte carries the full jump of len(query).
// Built over the same folding the compare uses, or the jump could skip a match.
@(private)
skip_table :: proc(query: string, sensitive: bool) -> (table: [256]int) {
    n := len(query)
    for i in 0 ..< 256 {
        table[i] = n
    }
    for i in 0 ..< n - 1 {
        table[fold(query[i], sensitive)] = n - 1 - i
    }
    return table
}
