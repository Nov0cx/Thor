package syntax

import "core:fmt"
import "core:strings"
import "core:testing"

import "../treecache"

// Leading component of the capture covering the first occurrence of `needle`.
@(private = "file")
head_at :: proc(spans: []Span, source, needle: string) -> (string, bool) {
    at := strings.index(source, needle)
    if at < 0 {
        return "", false
    }
    for s in spans {
        if s.start <= at && at < s.end {
            return capture_head(s.capture), true
        }
    }
    return "", false
}

@(test)
test_highlight_odin :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    src := `package demo

Point :: struct { x: int }

Click_Proc :: #type proc(data: rawptr, widget: int)

main :: proc() {
	p: Point
	s := "hi" // note
}
`
    spans := highlight(&h, "", src, "odin", context.allocator)
    defer delete(spans)
    testing.expect(t, len(spans) > 0, "expected highlight spans")

    // Spans must be ascending and non-overlapping.
    prev := 0
    for s in spans {
        testing.expect(t, s.start >= prev, "spans overlap or are unsorted")
        testing.expect(t, s.end > s.start, "empty span")
        prev = s.end
    }

    // Precedence: specific captures override the broad (identifier) @variable.
    expect :: proc(t: ^testing.T, spans: []Span, src, needle, want: string) {
        got, ok := head_at(spans, src, needle)
        testing.expectf(t, ok && got == want, "%q: got %q (found=%v), want %q", needle, got, ok, want)
    }
    expect(t, spans, src, "Point", "type")     // struct declaration
    expect(t, spans, src, "main", "function")  // proc
    expect(t, spans, src, "int", "type")       // builtin type via #any-of?
    expect(t, spans, src, "\"hi\"", "string")
    expect(t, spans, src, "// note", "comment")
    // A named parameter in a `#type proc(...)` stays a parameter, not a type.
    expect(t, spans, src, "data", "parameter")

    // Unknown language yields nothing.
    none := highlight(&h, "", src, "cobol", context.allocator)
    testing.expect(t, len(none) == 0, "unsupported language should have no spans")
}

// An imported package qualifies the same way in a type and in a call, so both
// must read as a namespace — the query alone only tags the type position.
@(test)
test_highlight_odin_package_qualifier :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    src := `package demo

import "core:mem"
import vmem "core:mem/virtual"

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	arena: vmem.Arena
	button.on_click(button)
}
`
    spans := highlight(&h, "", src, "odin", context.temp_allocator)
    expect_head(t, spans, src, "mem.Tracking_Allocator", "namespace")
    expect_head(t, spans, src, "mem.tracking_allocator_init", "namespace")
    expect_head(t, spans, src, "vmem.Arena", "namespace") // aliased import
    // A local that happens to hold a proc field is not a package.
    expect_head(t, spans, src, "button.on_click", "variable")
}

// A name that only stands for a type is a definition, so it reads like the
// `struct` declaration it aliases rather than like a variable.
@(test)
test_highlight_odin_type_alias :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    src := `package demo

import "core:mem"

Point :: struct { x: int }

Vec :: Point
Raw :: mem.Raw_Slice
Handle :: distinct Point
Table :: map[string]Point
Grid :: matrix[2, 2]f32
Click_Proc :: #type proc(data: rawptr)

MAX :: 100
`
    spans := highlight(&h, "", src, "odin", context.temp_allocator)
    testing.expect(t, len(spans) > 0, "the appended alias patterns must still compile")

    for needle in ([]string{"Vec ::", "Raw ::", "Handle ::", "Table ::", "Grid ::", "Click_Proc ::"}) {
        expect_head(t, spans, src, needle, "type")
    }
    // The type an alias names reads as a type too, on either side of a qualifier.
    expect_head(t, spans, src, "Point\n", "type")
    expect_head(t, spans, src, "mem.Raw_Slice", "namespace")
    expect_head(t, spans, src, "Raw_Slice", "type")
    // A constant with a literal value is not an alias.
    expect_head(t, spans, src, "MAX", "variable")
}

// True when some fold range starts on `start` and ends on `end`.
@(private = "file")
has_fold :: proc(folds: []Fold_Range, start, end: int) -> bool {
    for f in folds {
        if f.start_line == start && f.end_line == end {
            return true
        }
    }
    return false
}

@(test)
test_fold_ranges_odin :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    // Lines (0-based):
    // 0 package demo
    // 1 (blank)
    // 2 main :: proc() {
    // 3     if true {
    // 4         x := 1
    // 5     }
    // 6 }
    src := "package demo\n\nmain :: proc() {\n\tif true {\n\t\tx := 1\n\t}\n}\n"
    folds := fold_ranges(&h, "", src, "odin", context.allocator)
    defer delete(folds)

    testing.expect(t, has_fold(folds, 2, 6), "proc body should fold 2..6")
    testing.expect(t, has_fold(folds, 3, 5), "nested if should fold 3..5")

    // Ascending by start line, and no zero-height ranges.
    prev := -1
    for f in folds {
        testing.expect(t, f.start_line >= prev, "folds not sorted by start line")
        testing.expect(t, f.end_line > f.start_line, "fold hides no lines")
        prev = f.start_line
    }

    // The whole file (line 0) is never a single fold.
    testing.expect(t, !has_fold(folds, 0, 6), "root node must not be foldable")

    // Unknown language yields nothing.
    none := fold_ranges(&h, "", src, "cobol", context.allocator)
    testing.expect(t, len(none) == 0, "unsupported language should not fold")
}

// Folding is grammar-agnostic: a brace language other than Odin folds too.
@(test)
test_fold_ranges_c :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    // 0 int main(void) {
    // 1     return 0;
    // 2 }
    src := "int main(void) {\n    return 0;\n}\n"
    folds := fold_ranges(&h, "", src, "c", context.allocator)
    defer delete(folds)
    testing.expect(t, has_fold(folds, 0, 2), "C function body should fold 0..2")
}

// Spans are equal when they cover the same bytes with the same capture.
@(private = "file")
same_spans :: proc(a, b: []Span) -> bool {
    if len(a) != len(b) {
        return false
    }
    for s, i in a {
        if s != b[i] {
            return false
        }
    }
    return true
}

@(private = "file")
same_folds :: proc(a, b: []Fold_Range) -> bool {
    if len(a) != len(b) {
        return false
    }
    for f, i in a {
        if f != b[i] {
            return false
        }
    }
    return true
}

// A buffer walked through a series of edits must highlight and fold exactly as a
// parse of the same text from scratch would. Every step after the first re-parses
// off the resident tree, so a mis-described edit shows up here as drifted spans
// even where the text happens to still look right.
@(test)
test_incremental_highlight_matches_cold_parse :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    steps := []string {
        "package demo\n\nmain :: proc() {\n\tx := 1\n}\n",
        "package demo\n\nmain :: proc() {\n\tx := 12\n}\n",
        // A new declaration above the existing one shifts everything below it.
        "package demo\n\nPoint :: struct {\n\tx: int,\n}\n\nmain :: proc() {\n\tx := 12\n}\n",
        // A comment: the edit lands inside a leaf rather than between nodes.
        "package demo\n\nPoint :: struct {\n\tx: int, // across\n}\n\nmain :: proc() {\n\tx := 12\n}\n",
        // An unterminated string leaves the tree with an error node partway
        // through, which the next step must recover from.
        "package demo\n\nPoint :: struct {\n\tx: int, // across\n}\n\nmain :: proc() {\n\ts := \"\n}\n",
        "package demo\n\nPoint :: struct {\n\tx: int, // across\n}\n\nmain :: proc() {\n\ts := \"hi\"\n}\n",
        // A deletion, and a multi-byte rune edited one byte in.
        "package demo\n\nmain :: proc() {\n\ts := \"naïve\"\n}\n",
        "package demo\n\nmain :: proc() {\n\ts := \"naive\"\n}\n",
    }

    for src, i in steps {
        warm := highlight(&h, "buffer.odin", src, "odin", context.temp_allocator)
        cold := highlight(&h, "", src, "odin", context.temp_allocator)
        testing.expectf(t, same_spans(warm, cold), "step %d: spans diverged\n got: %v\nwant: %v", i, warm, cold)

        wf := fold_ranges(&h, "buffer.odin", src, "odin", context.temp_allocator)
        cf := fold_ranges(&h, "", src, "odin", context.temp_allocator)
        testing.expectf(t, same_folds(wf, cf), "step %d: folds diverged\n got: %v\nwant: %v", i, wf, cf)
    }
}

// Two buffers resident at once: alternating between them must not diff one
// against the other's source, and a resident tree must never seed a parse under
// a different grammar.
@(test)
test_highlight_cache_is_per_path :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    odin := "package demo\n\nmain :: proc() {\n\tx := 1\n}\n"
    c := "int main(void) {\n\treturn 0; // done\n}\n"

    for round in 0 ..< 3 {
        os := highlight(&h, "a.odin", odin, "odin", context.temp_allocator)
        cs := highlight(&h, "b.c", c, "c", context.temp_allocator)
        expect_head(t, os, odin, "main", "function")
        expect_head(t, cs, c, "// done", "comment")
        testing.expectf(t, len(os) > 0 && len(cs) > 0, "round %d: expected spans for both buffers", round)
    }

    // The same path re-typed as another language: the Odin tree is dropped
    // rather than handed to the C parser.
    reused := highlight(&h, "a.odin", c, "c", context.temp_allocator)
    cold := highlight(&h, "", c, "c", context.temp_allocator)
    testing.expect(t, same_spans(reused, cold), "a grammar change must re-parse from scratch")
}

// More buffers than slots: the least recently used is retired, and its next
// parse is cold rather than off a freed tree.
@(test)
test_highlight_cache_evicts_and_reparses :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    src := "package demo\n\nmain :: proc() {\n\tx := 1\n}\n"
    want := highlight(&h, "", src, "odin", context.temp_allocator)

    for i in 0 ..< treecache.SLOTS + 2 {
        path := fmt.tprintf("file%d.odin", i)
        got := highlight(&h, path, src, "odin", context.temp_allocator)
        testing.expectf(t, same_spans(got, want), "%s: spans diverged", path)
    }

    got := highlight(&h, "file0.odin", src, "odin", context.temp_allocator)
    testing.expect(t, same_spans(got, want), "the evicted buffer must re-parse and highlight the same")
}

@(private = "file")
expect_head :: proc(t: ^testing.T, spans: []Span, src, needle, want: string) {
    got, ok := head_at(spans, src, needle)
    testing.expectf(t, ok && got == want, "%q: got %q (found=%v), want %q", needle, got, ok, want)
}

// The query cache is keyed on (lang_id, source): the same pair hits, a
// different source compiles and caches a second entry.
@(test)
test_query_for_keys_on_lang_and_source :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    src := "(comment) @comment"
    q1, _, err1 := query_for(&h, "odin", src)
    testing.expect(t, err1 == .None)
    q2, _, err2 := query_for(&h, "odin", src)
    testing.expect(t, err2 == .None)
    testing.expect(t, q1 == q2, "the same (lang, source) must hit the cache")

    other := "(identifier) @variable"
    q3, _, err3 := query_for(&h, "odin", other)
    testing.expect(t, err3 == .None)
    testing.expect(t, q1 != q3, "a different source must compile a different query")

    testing.expect_value(t, len(h.queries), 2)
}

// Replacing a plugin's override must evict the compiled query it replaces
// from h.queries, not just from resolved, or every override of the same
// lang_id leaks one compiled ts.Query. The tracking allocator (run via
// build.odin -- test) is the leak assertion; this checks the count directly.
@(test)
test_set_highlights_evicts_the_replaced_query :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    before := len(h.queries)
    _, err := set_highlights(&h, "odin", "(comment) @comment")
    testing.expect(t, err == .None)
    after_first := len(h.queries)
    testing.expect_value(t, after_first, before + 1)

    _, err2 := set_highlights(&h, "odin", "(identifier) @variable")
    testing.expect(t, err2 == .None)
    testing.expect_value(t, len(h.queries), after_first)
}

// Each newly added grammar must build its highlights query (the combined
// javascript/typescript queries especially) and tag a few obvious tokens.
@(test)
test_highlight_c_family :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    c := "int main(void) {\n\treturn 0; // done\n}\n"
    cs := highlight(&h, "", c, "c", context.temp_allocator)
    testing.expect(t, len(cs) > 0, "expected c spans")
    expect_head(t, cs, c, "// done", "comment")

    cpp := "#include <vector>\nnamespace app { int x = 1; }\n"
    cps := highlight(&h, "", cpp, "cpp", context.temp_allocator)
    testing.expect(t, len(cps) > 0, "expected cpp spans")

    go := "package main\nfunc main() {\n\ts := \"hi\" // note\n}\n"
    gos := highlight(&h, "", go, "go", context.temp_allocator)
    testing.expect(t, len(gos) > 0, "expected go spans")
    expect_head(t, gos, go, "\"hi\"", "string")
    expect_head(t, gos, go, "// note", "comment")

    jai := "main :: () {\n\ts := \"hi\"; // note\n}\n"
    jas := highlight(&h, "", jai, "jai", context.temp_allocator)
    testing.expect(t, len(jas) > 0, "expected jai spans")
}

@(test)
test_highlight_js_ts :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    js := "const x = 1 // note\nfunction f(a) { return \"hi\" }\n"
    jss := highlight(&h, "", js, "javascript", context.temp_allocator)
    testing.expect(t, len(jss) > 0, "expected javascript spans")
    expect_head(t, jss, js, "// note", "comment")
    expect_head(t, jss, js, "\"hi\"", "string")

    ts := "const n: number = 1\ntype Id = string // alias\n"
    tss := highlight(&h, "", ts, "typescript", context.temp_allocator)
    testing.expect(t, len(tss) > 0, "expected typescript spans")
    expect_head(t, tss, ts, "// alias", "comment") // from the javascript base
    expect_head(t, tss, ts, "number", "type")      // from the typescript layer

    tsx := "const el = <div className=\"a\">{x}</div>\n"
    tsxs := highlight(&h, "", tsx, "tsx", context.temp_allocator)
    testing.expect(t, len(tsxs) > 0, "expected tsx spans")
}

// A windowed highlight colors the window and nothing outside it, and agrees
// with the whole-document answer wherever the two overlap.
@(test)
test_highlight_range_window :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    b := strings.builder_make(context.temp_allocator)
    for i in 0 ..< 400 {
        fmt.sbprintf(&b, "proc_%d :: proc() {{\n    x := %d\n}}\n", i, i)
    }
    src := strings.to_string(b)

    marker := "proc_200 ::"
    lo := strings.index(src, marker)
    testing.expect(t, lo > 0, "marker not found")
    hi := lo + 200

    windowed := highlight_range(&h, "", src, "odin", lo, hi, context.temp_allocator)
    testing.expect(t, len(windowed) > 0, "expected spans in the window")

    // Nothing outside the window, and still ascending and non-overlapping.
    prev := 0
    for s in windowed {
        testing.expectf(t, s.end > lo && s.start < hi, "span %d..%d escaped window %d..%d", s.start, s.end, lo, hi)
        testing.expect(t, s.start >= prev, "windowed spans overlap or are unsorted")
        prev = s.end
    }

    // Same classification as the whole-document run inside the window.
    whole := highlight(&h, "", src, "odin", context.temp_allocator)
    // Needles unique to the window: head_at finds a needle's first occurrence,
    // and one that also appears earlier would look up a span outside it.
    for needle in ([?]string{"proc_200", "x := 200"}) {
        want, ok_whole := head_at(whole, src, needle)
        got, ok_win := head_at(windowed, src, needle)
        testing.expectf(t, ok_whole && ok_win && want == got,
            "%q: windowed %q vs whole %q", needle, got, want)
    }

    // The full range is exactly the whole-document answer.
    full := highlight_range(&h, "", src, "odin", 0, max(int), context.temp_allocator)
    testing.expect_value(t, len(full), len(whole))
}

// The property the windowing rests on: a construct that opens before the window
// and reaches into it is still reported, with its real extent. A block comment
// is the case that would mis-color the whole rest of the file if it were missed.
@(test)
test_highlight_range_straddling_node :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "package p\n\n/* opening comment\n")
    for i in 0 ..< 200 {
        fmt.sbprintf(&b, " still inside the comment, line %d\n", i)
    }
    strings.write_string(&b, "*/\nafter :: proc() {}\n")
    src := strings.to_string(b)

    // A window entirely inside the comment body, far from where it opened.
    lo := strings.index(src, "line 150")
    testing.expect(t, lo > 0, "marker not found")
    spans := highlight_range(&h, "", src, "odin", lo, lo + 20, context.temp_allocator)

    got, ok := head_at(spans, src, "line 150")
    testing.expectf(t, ok && got == "comment",
        "a block comment opening before the window must still color it: got %q (found=%v)", got, ok)

    // And its extent is the real one, reaching back before the window.
    covering := false
    for s in spans {
        if s.start < lo && s.end > lo {
            covering = true
        }
    }
    testing.expect(t, covering, "the straddling span was clipped to the window")
}
