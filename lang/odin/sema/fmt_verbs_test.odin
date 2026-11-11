package odinsema

import "core:fmt"
import "core:strings"
import "core:testing"

// The steps of a format as one line: `kind@at:arg:verb`, then the unused arguments.
@(private = "file")
steps_text :: proc(format: string, arg_count: int) -> string {
    steps, unused := format_steps(format, arg_count, context.temp_allocator)
    b             := strings.builder_make(context.temp_allocator)
    for s in steps {
        switch s.kind {
        case .Verb, .Width, .Precision:
            fmt.sbprintf(&b, "%v@%d:%d:%c ", s.kind, s.at, s.arg, s.verb)
        case .Missing, .Bad_Index:
            fmt.sbprintf(&b, "%v@%d:%c ", s.kind, s.at, s.verb)
        case .No_Verb, .Missing_Brace:
            fmt.sbprintf(&b, "%v@%d ", s.kind, s.at)
        }
    }
    fmt.sbprintf(&b, "unused=%v", unused)
    return strings.to_string(b)
}

@(test)
test_format_steps :: proc(t: ^testing.T) {
    Case :: struct {
        format: string,
        args:   int,
        want:   string,
    }
    cases := []Case{
        {"plain text", 0, "unused=bit_set[0..=63]{}"},
        {"%d and %s", 2, "Verb@0:0:d Verb@7:1:s unused=bit_set[0..=63]{}"},
        {"100%% {{x}}", 0, "unused=bit_set[0..=63]{}"},
        {"%d %d", 1, "Verb@0:0:d Missing@3:d unused=bit_set[0..=63]{}"},
        {"%d", 3, "Verb@0:0:d unused=bit_set[0..=63]{1, 2}"},
        // `[n]` names an argument; a later plain verb takes the lowest one not taken.
        {"%[1]d %d", 2, "Verb@0:1:d Verb@6:0:d unused=bit_set[0..=63]{}"},
        {"%[5]d", 1, "Bad_Index@0:d unused=bit_set[0..=63]{0}"},
        {"%-08.3f", 1, "Verb@0:0:f unused=bit_set[0..=63]{}"},
        {"%*d", 2, "Width@0:0:* Verb@0:1:d unused=bit_set[0..=63]{}"},
        {"%.*[1]f", 2, "Precision@0:1:* Verb@0:0:f unused=bit_set[0..=63]{}"},
        {"%*d", 0, "Missing@0:* Missing@0:d unused=bit_set[0..=63]{}"},
        {"50%", 0, "No_Verb@2 unused=bit_set[0..=63]{}"},
        {"% d", 1, "Verb@0:0:d unused=bit_set[0..=63]{}"},
        {"%5 x", 1, "No_Verb@0 unused=bit_set[0..=63]{0}"},
        {"{} {}", 2, "Verb@0:0:v Verb@3:1:v unused=bit_set[0..=63]{}"},
        {"{1:x} {0}", 2, "Verb@0:1:x Verb@6:0:v unused=bit_set[0..=63]{}"},
        {"{:.2f}", 1, "Verb@0:0:f unused=bit_set[0..=63]{}"},
        {"{3}", 1, "Bad_Index@0:v unused=bit_set[0..=63]{0}"},
        {"{}", 0, "Missing@0:v unused=bit_set[0..=63]{}"},
        // A literal `{` must be written `{{`.
        {"struct {x}", 1, "Missing_Brace@7 unused=bit_set[0..=63]{0}"},
        {"open {", 0, "Missing_Brace@5 unused=bit_set[0..=63]{}"},
        {"{:}", 1, "No_Verb@0 unused=bit_set[0..=63]{0}"},
        {"}}", 0, "unused=bit_set[0..=63]{}"},
    }
    for tc in cases {
        got := steps_text(tc.format, tc.args)
        testing.expectf(t, got == tc.want, "%q with %d args: got %q, want %q", tc.format, tc.args, got, tc.want)
    }
}
