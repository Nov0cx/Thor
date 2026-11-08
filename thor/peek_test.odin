package thor

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../editview"
import "../lang"
import "../textedit"

@(private = "file")
peek_test_thor :: proc() -> ^Thor {
    thor := new(Thor)
    thor.active_file = make_signal(-1)
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.pane_file = -1
    return thor
}

@(private = "file")
peek_test_destroy :: proc(thor: ^Thor) {
    thor_peek_close(thor)
    for len(thor.open_files) > 0 {
        thor_close_file(thor, 0)
    }
    thor_drain_io(thor)
    for &editor in thor.editors {editview.editor_destroy(&editor)}
    thor_peek_destroy(thor)
    thor_clear_jump_list(thor)
    delete(thor.jump_back)
    delete(thor.jump_forward)
    delete(thor.open_files)
    delete(thor.zombie_files)
    free(thor)
}

@(private = "file")
peek_test_open :: proc(t: ^testing.T, thor: ^Thor, path: string) -> ^Open_File {
    thor_open_file(thor, path)
    file := thor.open_files[len(thor.open_files) - 1]
    for _ in 0 ..< 500 {
        thor_update_files(thor)
        if file.loaded || file.load_failed {
            break
        }
        time.sleep(2 * time.Millisecond)
    }
    testing.expect(t, file.loaded, "load did not complete")
    return file
}

// A definition result the peek asked for opens the peek under the caret's line and does not navigate;
// one that lands after the caret left the line is dropped.
@(test)
test_peek_takes_its_result :: proc(t: ^testing.T) {
    dir := "bin/test/peek_result"
    _ = os.remove_all(dir)
    if err := os.make_directory_all(dir); err != nil {
        testing.fail_now(t, "could not create the fixture directory")
    }
    defer os.remove_all(dir)
    a := strings.concatenate({dir, "/a.odin"}, context.temp_allocator)
    b := strings.concatenate({dir, "/b.odin"}, context.temp_allocator)
    if os.write_entire_file(a, transmute([]byte)string("package p\nx := f()\n")) != nil ||
       os.write_entire_file(b, transmute([]byte)string("package p\nf :: proc() -> int { return 1 }\n")) != nil {
        testing.fail_now(t, "could not write the fixture files")
    }

    thor := peek_test_thor()
    defer peek_test_destroy(thor)
    target := peek_test_open(t, thor, b)
    file := peek_test_open(t, thor, a)
    textedit.set_single_cursor(&file.state, 15)

    thor.peek.request_id = 42
    thor.peek.pane = thor.active_pane
    thor.peek.anchor_line = 1
    thor.peek.anchor_path = strings.clone(file.path)
    res := lang.Result{id = 42, kind = .Definition, ok = true, location = {path = target.path, start = 10, end = 11}}
    testing.expect(t, thor_peek_take_result(thor, &res), "the peek takes its own result")
    testing.expect(t, thor.peek.open)
    testing.expect(t, thor.peek.file == target)
    testing.expect(t, thor_active_open_file(thor) == file, "a peek does not navigate")
    line, has := editview.editor_zone_line(thor_pane_editor(thor, thor.active_pane))
    testing.expect(t, has)
    testing.expect_value(t, line, 1)

    other := lang.Result{id = 7, kind = .Definition, ok = true}
    testing.expect(t, !thor_peek_take_result(thor, &other), "a result the peek did not ask for is not its own")

    thor_peek_close(thor)
    _, has = editview.editor_zone_line(thor_pane_editor(thor, thor.active_pane))
    testing.expect(t, !has, "closing the peek removes its zone")

    // The caret moved off the line before the result landed.
    thor.peek.request_id = 43
    thor.peek.anchor_line = 0
    res.id = 43
    testing.expect(t, thor_peek_take_result(thor, &res))
    testing.expect(t, !thor.peek.open, "a stale result opens nothing")
}
