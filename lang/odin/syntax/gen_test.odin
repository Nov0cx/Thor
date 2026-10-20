package odinsyntax

import "core:os"
import "core:strings"
import "core:testing"
import syntaxgen "gen"

@(private = "file")
read_lf :: proc(t: ^testing.T, path: string) -> (string, bool) {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if !testing.expectf(t, err == nil, "a read of %s failed: %v", path, err) {
        return "", false
    }
    out, _ := strings.replace_all(string(data), "\r\n", "\n", context.temp_allocator)
    return out, true
}

// The generated files are what syntax.schema gives now.
@(test)
test_generated_files_current :: proc(t: ^testing.T) {
    schema, schema_ok := read_lf(t, syntaxgen.SCHEMA_PATH)
    tokens, tokens_ok := read_lf(t, syntaxgen.TOKEN_PATH)
    if !schema_ok || !tokens_ok {
        return
    }
    out, errors := syntaxgen.generate(schema, tokens, context.temp_allocator)
    for e in errors {
        testing.expectf(t, false, "%s", e)
    }
    if len(errors) > 0 {
        return
    }
    files := [?][2]string{{syntaxgen.KIND_PATH, out.kinds}, {syntaxgen.VIEWS_PATH, out.views}, {syntaxgen.TABLE_PATH, out.table}}
    for f in files {
        if have, ok := read_lf(t, f[0]); ok {
            testing.expectf(t, have == f[1], "%s is stale: run `odin run build.odin -file -- gen_syntax`", f[0])
        }
    }
}

@(test)
test_generator_reports_schema_errors :: proc(t: ^testing.T) {
    tokens, ok := read_lf(t, syntaxgen.TOKEN_PATH)
    if !ok {
        return
    }
    schema := "Root\n    a = node Nope\n    b = token Nope\n    a = node Root\nRoot\n"
    _, errors := syntaxgen.generate(schema, tokens, context.temp_allocator)
    testing.expect_value(t, len(errors), 4)
}
