// Literal and regular-expression search over a whole document. It knows nothing
// about buffers or widgets: a caller hands in the text and gets byte ranges back,
// which is what lets the find bar and any other caller share one scanner.
package search

import "core:strings"
import "core:text/regex"
import "core:unicode"
import "core:unicode/utf8"

// One match as a byte range. The length is not len(query): a regular expression
// matches spans of its own size, and a case-folded match can change width.
Match :: struct {
    start:       int,
    end:         int,
    // The capture groups of a regular-expression match: `group_count` ranges
    // from `group_first` in the capture list scan filled. Group 0 is the match.
    group_first: int,
    group_count: int,
}

Options :: struct {
    case_sensitive: bool,
    whole_word:     bool,
    use_regex:      bool,
}

// Appends every match of `query` in `text` to `out`. False means the pattern is
// a regular expression that does not compile; `out` is left as it was found.
// `captures` takes the group ranges of each regular-expression match, for
// expand; nil when the caller replaces nothing.
scan :: proc(text, query: string, opts: Options, out: ^[dynamic]Match, captures: ^[dynamic][2]int = nil) -> bool {
    if len(query) == 0 {
        return true
    }
    if opts.use_regex {
        return scan_regex(text, query, opts, out, captures)
    }
    scan_literal(text, query, opts, out)
    return true
}

// Collects regular-expression matches over the whole document. `^` and `$`
// match at every line. A zero-width match is kept: it is where a replace
// inserts. The scan steps one rune past it, which the iterator alone does not.
@(private)
scan_regex :: proc(text, pattern: string, opts: Options, out: ^[dynamic]Match, captures: ^[dynamic][2]int) -> bool {
    flags: regex.Flags = {.Unicode, .Multiline}
    if !opts.case_sensitive {
        flags += {.Case_Insensitive}
    }
    it, err := regex.create_iterator(text, pattern, flags)
    if err != nil {
        return false
    }
    defer regex.destroy(it)

    // The engine does not scan ahead for a pattern that opens with `^`: it tries
    // the scan position alone. Such a pattern is tried again at each line start.
    anchored := starts_anchored(pattern)
    last_end := -1
    pos := 0 // where the next run of the engine starts
    for {
        capture, _, ok := regex.match_iterator(&it)
        if !ok || len(capture.pos) == 0 {
            newline := anchored && pos < len(text) ? strings.index_byte(text[pos:], '\n') : -1
            if newline < 0 {
                break
            }
            pos += newline + 1
            seek(&it, text, pos)
            continue
        }
        start, end := capture.pos[0][0], capture.pos[0][1]
        pos = end
        if end <= start {
            // The iterator stops at a match that takes no text. Step one rune.
            if start >= len(text) {
                it.done = true
            } else {
                _, width := utf8.decode_rune_in_string(text[start:])
                pos = start + width
                seek(&it, text, pos)
            }
            // An empty match right after a match is part of that match.
            if start == last_end {
                continue
            }
        } else if opts.whole_word && !word_bounded(text, start, end) {
            continue
        }
        last_end = end

        match := Match {start = start, end = end}
        if captures != nil {
            match.group_first = len(captures)
            match.group_count = len(capture.pos)
            append(captures, ..capture.pos)
        }
        append(out, match)
    }
    return true
}

// Puts the iterator at byte `pos` for its next run.
@(private)
seek :: proc(it: ^regex.Match_Iterator, text: string, pos: int) {
    it.vm.string_pointer = pos
    // `^` reads the rune before the scan position.
    it.vm.last_rune, _ = utf8.decode_last_rune_in_string(text[:pos])
    it.done = false
    // A run after the first one clears the thread lists; a failed first run
    // does not count itself.
    it.idx = max(it.idx, 1)
}

// True when the pattern opens with `^`, groups aside.
@(private)
starts_anchored :: proc(pattern: string) -> bool {
    rest := pattern
    for {
        switch {
        case strings.has_prefix(rest, "(?:"):
            rest = rest[3:]
        case strings.has_prefix(rest, "("):
            rest = rest[1:]
        case:
            return strings.has_prefix(rest, "^")
        }
    }
}

// The replacement for one regular-expression match: `$1` to `$9` give a
// capture group, `$0` and `$&` the whole match, `$$` a dollar sign, and `\n`,
// `\t` and `\\` a newline, a tab and a backslash. A group that took no part
// in the match gives nothing.
expand :: proc(text: string, match: Match, captures: [][2]int, template: string, allocator := context.temp_allocator) -> string {
    b := strings.builder_make(0, len(template), allocator)
    for i := 0; i < len(template); i += 1 {
        c := template[i]
        if i + 1 >= len(template) || (c != '$' && c != '\\') {
            strings.write_byte(&b, c)
            continue
        }
        next := template[i + 1]
        if c == '\\' {
            switch next {
            case 'n':  strings.write_byte(&b, '\n')
            case 't':  strings.write_byte(&b, '\t')
            case '\\': strings.write_byte(&b, '\\')
            case:
                strings.write_byte(&b, c)
                continue
            }
            i += 1
            continue
        }
        switch next {
        case '$':
            strings.write_byte(&b, '$')
        case '&':
            strings.write_string(&b, text[match.start:match.end])
        case '0' ..= '9':
            group := int(next - '0')
            if group < match.group_count {
                span := captures[match.group_first + group]
                strings.write_string(&b, text[span[0]:span[1]])
            } else if group == 0 {
                strings.write_string(&b, text[match.start:match.end])
            }
        case:
            strings.write_byte(&b, c)
            continue
        }
        i += 1
    }
    return strings.to_string(b)
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
                append(out, Match {start = i, end = i + width})
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
                append(out, Match {start = i, end = i + n})
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
