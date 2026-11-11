package odin

import "core:fmt"
import "core:strings"
import "core:testing"

import lang ".."

// The live report of `source` as the buffer of `path` in `workspace`.
@(private)
live_check :: proc(e: ^Engine, source, workspace, path: string) -> lang.Result {
    req := lang.Request{kind = .Syntax_Diagnostics, path = path, ext = ".odin", source = source, workspace = workspace}
    res: lang.Result
    syntax_diagnostics(e, &req, &res)
    return res
}

@(private)
free_live :: proc(res: ^lang.Result) {
    for d in res.report.items {
        delete(d.path)
        delete(d.message)
    }
    delete(res.report.items)
    delete(res.report.scope)
}

// An expected error: the message at the `skip`th occurrence of `needle`.
@(private)
Want :: struct {
    needle:  string,
    message: string,
    skip:    int,
}

// True for the id of a vet or liveness warning.
@(private)
is_vet_code :: proc(code: string) -> bool {
    switch code {
    case CODE_UNUSED_VAR,
        CODE_DEAD_STORE,
        CODE_UNUSED_IMPORT,
        CODE_SHADOWING,
        CODE_WHEN_SHADOWING,
        CODE_CAST,
        CODE_UNUSED_PROC,
        CODE_STYLE,
        CODE_SEMICOLON,
        CODE_TABS:
        return true
    }
    return false
}

// Expects the report to hold exactly `wants`, in order.
@(private)
expect_errors :: proc(t: ^testing.T, res: ^lang.Result, source: string, wants: []Want, loc := #caller_location) {
    testing.expect(t, res.ok, "the live check must answer", loc = loc)
    // Vet and liveness warnings are compared only when a want names one.
    vet := false
    for w in wants {
        vet ||= strings.has_suffix(w.message, "declared but not used") ||
            strings.has_suffix(w.message, "is never used") ||
            strings.contains(w.message, " shadows ") ||
            strings.has_prefix(w.message, "Unneeded ") ||
            w.message == "Found unneeded semicolon" ||
            w.message == "Expected a comma, got a newline" ||
            strings.has_prefix(w.message, "With '-vet-tabs'")
    }
    // A nil dereference is compared only when a want names one.
    nil_wanted := false
    for w in wants {
        nil_wanted ||= strings.has_suffix(w.message, "which is always nil here")
    }
    got := make([dynamic]string, context.temp_allocator)
    for d in res.report.items {
        if !vet && is_vet_code(d.code) || !nil_wanted && d.code == CODE_NIL_DEREF {
            continue
        }
        append(&got, fmt.tprintf("%d:%d %s", d.line, d.col, d.message))
    }
    want := make([dynamic]string, context.temp_allocator)
    for w in wants {
        at   := -1
        from := 0
        for _ in 0 ..= w.skip {
            i := strings.index(source[from:], w.needle)
            if i < 0 {
                at = -1
                break
            }
            at = from + i
            from = at + 1
        }
        if at < 0 {
            testing.expectf(t, false, "needle %q not found", w.needle, loc = loc)
            return
        }
        line := strings.count(source[:at], "\n") + 1
        col  := at - (strings.last_index_byte(source[:at], '\n') + 1) + 1
        append(&want, fmt.tprintf("%d:%d %s", line, col, w.message))
    }
    testing.expectf(t, len(got) == len(want), "got %v, want %v", got[:], want[:], loc = loc)
    for g, i in got {
        if i < len(want) {
            testing.expectf(t, g == want[i], "item %d: got %q, want %q", i, g, want[i], loc = loc)
        }
    }
}
