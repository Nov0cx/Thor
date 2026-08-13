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

// Applies res.edits to src back to front, the order thor_apply_edits uses.
@(private = "file")
apply_edits :: proc(src: string, res: ^lang.Result) -> string {
    out := src
    #reverse for edit in res.edits {
        out = strings.concatenate({out[:edit.start], edit.new_text, out[edit.end:]}, context.temp_allocator)
    }
    return out
}

@(private = "file")
free_edits :: proc(res: ^lang.Result) {
    for edit in res.edits {
        delete(edit.path)
        delete(edit.old_text)
        delete(edit.new_text)
    }
    delete(res.edits)
}

// Format Selection over one badly-indented region must leave the other alone:
// the printer formats the whole file, and only the spans inside the range reach
// the buffer.
@(test)
test_format_range_clips_to_selection :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\nf :: proc() {\nreturn\n}\ng :: proc() {\nreturn\n}\n"
    lo := strings.index(src, "g :: proc")
    req := lang.Request {
        kind   = .Format_Range,
        path   = "buffer.odin",
        ext    = ".odin",
        source = src,
        offset = lo,
        end    = len(src),
    }
    res := lang.Result{kind = .Format_Range}
    resolve(e, &req, &res)
    defer free_edits(&res)

    testing.expect(t, res.ok, "expected the range format to succeed")
    testing.expect(t, len(res.edits) > 0, "expected the selected region to reindent")
    for edit in res.edits {
        testing.expectf(t, edit.start >= lo, "edit at %d escaped the selection starting at %d", edit.start, lo)
    }

    formatted := apply_edits(src, &res)
    testing.expectf(t, strings.contains(formatted, "f :: proc() {\nreturn"), "region before the selection changed:\n%s", formatted)
    testing.expectf(t, strings.contains(formatted, "g :: proc() {\n\treturn"), "the selected region did not reindent:\n%s", formatted)
}

// Format-on-type at a closing brace reindents that line. The rest of the buffer
// is already formatted while typing, so the printer's only change is the line
// the trigger sits on.
@(test)
test_format_on_type_reindents_trigger_line :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\nf :: proc() {\n\treturn\n    }\n"
    at := strings.index(src, "    }")
    req := lang.Request {
        kind    = .Format_On_Type,
        path    = "buffer.odin",
        ext     = ".odin",
        source  = src,
        offset  = at,
        trigger = "}",
    }
    res := lang.Result{kind = .Format_On_Type}
    resolve(e, &req, &res)
    defer free_edits(&res)

    testing.expect(t, res.ok)
    formatted := apply_edits(src, &res)
    testing.expectf(t, strings.contains(formatted, "\treturn\n}\n"), "the closing brace did not reindent:\n%s", formatted)
}

// A reflow the printer wants to make outside the trigger's own line is refused:
// diff spans coalesce adjacent changed lines, and a span that reaches past the
// window is dropped whole rather than half-applied mid-keystroke.
@(test)
test_format_on_type_leaves_other_lines_alone :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\nf :: proc() {\nreturn\n    }\n"
    at := strings.index(src, "    }")
    req := lang.Request {
        kind    = .Format_On_Type,
        path    = "buffer.odin",
        ext     = ".odin",
        source  = src,
        offset  = at,
        trigger = "}",
    }
    res := lang.Result{kind = .Format_On_Type}
    resolve(e, &req, &res)
    defer free_edits(&res)

    testing.expect(t, res.ok)
    testing.expectf(t, len(res.edits) == 0, "expected no edit, got %d", len(res.edits))
}

// The engine claims `}` and nothing else, so the editor never dispatches
// Format_On_Type on a character the printer has no opinion about.
@(test)
test_on_type_trigger_is_close_brace_only :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    testing.expect(t, on_type_trigger(e, ".odin", "}"))
    testing.expect(t, !on_type_trigger(e, ".odin", "\n"))
    testing.expect(t, !on_type_trigger(e, ".go", "}"))
}
