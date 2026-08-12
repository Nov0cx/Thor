// The formatter's workspace config: a plain JSON integer ("spaces": 2) must
// actually apply — core:encoding/json tokenizes a number with no decimal
// point as json.Integer, not json.Float, so a reader that checks only Float
// silently ignores every ordinarily-written integer setting in the file.
package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_format_config_integer_settings_apply :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := "thor_lang_fmtcfg_ws"
    cfg_dir := strings.concatenate({root, "/.thor"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(cfg_dir)
    cfg := strings.concatenate({cfg_dir, "/odin-formatter.json"}, context.temp_allocator)
    defer os.remove(root)
    defer os.remove(cfg_dir)
    defer os.remove(cfg)

    // Every numeric key written as a bare integer, plus tabs:false so
    // `spaces` is the one actually rendered — if read_int only matched
    // json.Float, every field here would silently stay at its default.
    cfg_src := "{\n" +
        "    \"spaces\": 2,\n" +
        "    \"tabs\": false,\n" +
        "    \"character_width\": 40,\n" +
        "    \"newline_limit\": 0\n" +
        "}\n"
    _ = os.write_entire_file(cfg, transmute([]byte)cfg_src)

    src := "package demo\nFoo :: struct {\n\tx: int,\n\ty: int,\n}\n"
    req := lang.Request{kind = .Format, path = "buffer.odin", ext = ".odin", source = src, workspace = root}
    res := lang.Result{kind = .Format}
    resolve(e, &req, &res)
    defer {
        for edit in res.edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(res.edits)
    }

    testing.expect(t, res.ok, "expected the format request to succeed")
    testing.expectf(t, len(res.edits) > 0, "expected edits to apply the config")

    // Spans are ascending over the ORIGINAL source, so apply them back to
    // front — front to back would use offsets stale from earlier edits.
    formatted := src
    #reverse for edit in res.edits {
        formatted = strings.concatenate(
            {formatted[:edit.start], edit.new_text, formatted[edit.end:]},
            context.temp_allocator,
        )
    }
    testing.expectf(
        t,
        strings.contains(formatted, "\n  x: int,"),
        "expected 2-space indent from the config's \"spaces\": 2, got:\n%s",
        formatted,
    )
}
