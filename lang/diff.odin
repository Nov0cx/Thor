// Minimal line-based diff between an original source and a formatted result:
// ascending, non-overlapping byte-range spans — exactly the shape
// textedit.replace_ranges wants, so cursors outside a changed region never
// move. A whole-buffer single edit would work too, but it drags every
// cursor to the end of the file; a formatter that only reindented one
// function should not touch anyone's cursor two screens away. Shared by
// every backend that reconstructs a whole-file formatting result and needs
// it turned back into minimal Text_Edits: lang/odin/formatter.odin and
// lang/lsp/decode.odin.
package lang

// Lines beyond this on either side of a still-unmatched middle collapse the
// whole middle into one span instead of running the O(n*m) LCS — a diff
// that large is not "minimal edits" anyway, and the cap keeps a huge
// (near-total) rewrite from allocating an equally huge DP table.
@(private)
DIFF_LINE_CAP :: 1500

Diff_Span :: struct {
    start: int, // byte offset in `old`
    end:   int, // byte offset in `old`, exclusive
    text:  string, // replacement text — borrowed from `new`
}

@(private)
Diff_Line :: struct {
    start: int, // byte offset of the line's first byte
    end:   int, // byte offset one past its last content byte (before '\n')
}

@(private)
diff_split_lines :: proc(s: string, allocator := context.allocator) -> []Diff_Line {
    lines: [dynamic]Diff_Line
    lines.allocator = allocator
    start := 0
    for i := 0; i < len(s); i += 1 {
        if s[i] == '\n' {
            append(&lines, Diff_Line{start, i})
            start = i + 1
        }
    }
    append(&lines, Diff_Line{start, len(s)})
    return lines[:]
}

@(private)
diff_line_text :: proc(s: string, l: Diff_Line) -> string {
    return s[l.start:l.end]
}

// Byte range in `old` spanning every line in `a` (inclusive of the newline
// that follows each line but the source's very last), and the matching
// replacement text spanning every line in `b`. Either may be empty — a pure
// insertion (empty a) anchors a zero-width old range at the position the new
// lines belong (the next surviving old line, or end-of-source when they were
// appended at the tail); a pure deletion (empty b) anchors an empty
// replacement over exactly the deleted lines and their trailing newline.
@(private)
diff_run_span :: proc(old, new: string, a, b: []Diff_Line, insertion_at: int) -> Diff_Span {
    if len(a) == 0 {
        return Diff_Span{start = insertion_at, end = insertion_at, text = diff_insert_text(new, b, 0, len(b))}
    }
    start := a[0].start
    end := a[len(a) - 1].end
    if end < len(old) && old[end] == '\n' {
        end += 1
    }
    if len(b) == 0 {
        return Diff_Span{start = start, end = end, text = ""}
    }
    return Diff_Span{start = start, end = end, text = diff_insert_text(new, b, 0, len(b))}
}

// diff_spans returns the minimal set of replace spans that turn `old` into
// `new`. Spans are ascending and non-overlapping; nil when the two are
// equal.
diff_spans :: proc(old, new: string, allocator := context.allocator) -> []Diff_Span {
    if old == new {
        return nil
    }

    old_lines := diff_split_lines(old, context.temp_allocator)
    new_lines := diff_split_lines(new, context.temp_allocator)

    lo := 0
    for lo < len(old_lines) && lo < len(new_lines) && diff_line_text(old, old_lines[lo]) == diff_line_text(new, new_lines[lo]) {
        lo += 1
    }
    hi_old := len(old_lines)
    hi_new := len(new_lines)
    for hi_old > lo && hi_new > lo && diff_line_text(old, old_lines[hi_old - 1]) == diff_line_text(new, new_lines[hi_new - 1]) {
        hi_old -= 1
        hi_new -= 1
    }

    a := old_lines[lo:hi_old]
    b := new_lines[lo:hi_new]
    if len(a) == 0 && len(b) == 0 {
        return nil
    }

    spans: [dynamic]Diff_Span
    spans.allocator = allocator

    if len(a) == 0 || len(b) == 0 || len(a) > DIFF_LINE_CAP || len(b) > DIFF_LINE_CAP {
        insertion_at := len(old)
        if hi_old < len(old_lines) {
            insertion_at = old_lines[hi_old].start
        }
        append(&spans, diff_run_span(old, new, a, b, insertion_at))
        return spans[:]
    }

    diff_lcs(old, new, a, b, &spans)
    return spans[:]
}

// Longest-common-subsequence line diff over the (already prefix/suffix
// trimmed) middle, appending one Diff_Span per maximal non-matching run.
// Classic O(len(a)*len(b)) DP + backtrack; DIFF_LINE_CAP keeps that bounded.
@(private)
diff_lcs :: proc(old, new: string, a, b: []Diff_Line, spans: ^[dynamic]Diff_Span) {
    na, nb := len(a), len(b)
    // dp[i*  (nb+1) + j] = LCS length of a[:i], b[:j]
    dp := make([]int, (na + 1) * (nb + 1), context.temp_allocator)
    row :: proc(nb: int, i: int) -> int {return i * (nb + 1)}
    for i := 1; i <= na; i += 1 {
        for j := 1; j <= nb; j += 1 {
            if diff_line_text(old, a[i - 1]) == diff_line_text(new, b[j - 1]) {
                dp[row(nb, i) + j] = dp[row(nb, i - 1) + j - 1] + 1
            } else {
                x := dp[row(nb, i - 1) + j]
                y := dp[row(nb, i) + j - 1]
                dp[row(nb, i) + j] = max(x, y)
            }
        }
    }

    // Backtrack to a list of matched (i,j) index pairs, oldest first.
    matches: [dynamic][2]int
    matches.allocator = context.temp_allocator
    i, j := na, nb
    for i > 0 && j > 0 {
        if diff_line_text(old, a[i - 1]) == diff_line_text(new, b[j - 1]) {
            append(&matches, [2]int{i - 1, j - 1})
            i -= 1
            j -= 1
        } else if dp[row(nb, i - 1) + j] >= dp[row(nb, i) + j - 1] {
            i -= 1
        } else {
            j -= 1
        }
    }
    // reverse in place (backtrack ran newest-first)
    for k := 0; k < len(matches) / 2; k += 1 {
        matches[k], matches[len(matches) - 1 - k] = matches[len(matches) - 1 - k], matches[k]
    }

    // Walk the gaps between consecutive matches (and before the first / after
    // the last): each non-empty gap on either side is one replace span.
    pa, pb := 0, 0
    flush_gap :: proc(old, new: string, a, b: []Diff_Line, pa, pb, ia, ib: int, spans: ^[dynamic]Diff_Span) {
        if ia > pa || ib > pb {
            if ia > pa && ib > pb {
                append(spans, diff_run_span(old, new, a[pa:ia], b[pb:ib], 0)) // insertion_at unused: a is non-empty here
            } else if ia > pa {
                // pure deletion: replace the old run with nothing, anchored
                // on the byte range those lines (and their newlines) cover
                start := a[pa].start
                end := a[ia - 1].end
                if end < len(old) && old[end] == '\n' {
                    end += 1
                }
                append(spans, Diff_Span{start = start, end = end, text = ""})
            } else {
                // pure insertion: zero-width old range, right where the new
                // lines belong — the start of the next surviving old line,
                // or end-of-source when they were appended at the tail.
                at := len(old)
                if ia < len(a) {
                    at = a[ia].start
                }
                append(spans, Diff_Span{start = at, end = at, text = diff_insert_text(new, b, pb, ib)})
            }
        }
    }
    for m in matches {
        flush_gap(old, new, a, b, pa, pb, m[0], m[1], spans)
        pa, pb = m[0] + 1, m[1] + 1
    }
    flush_gap(old, new, a, b, pa, pb, na, nb, spans)
}

@(private)
diff_insert_text :: proc(new: string, b: []Diff_Line, pb, ib: int) -> string {
    start := b[pb].start
    end := b[ib - 1].end
    if end < len(new) && new[end] == '\n' {
        end += 1
    }
    return new[start:end]
}
