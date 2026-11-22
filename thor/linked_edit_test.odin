package thor

import "core:strings"
import "core:testing"

import "../lang"
import "../textedit"

// An edit inside one linked span is copied to the other; an edit outside both ends the session.
@(test)
test_linked_edit_mirrors_a_span :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    lang.manager_init(&thor.lang_manager)
    defer lang.manager_destroy(&thor.lang_manager)
    defer thor_linked_destroy(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)
    thor.active_file = make_signal(-1)

    file := new(Open_File)
    defer free(file)
    file.name = "a.html"
    file.path = "a.html"
    file.loaded = true
    textedit.init(&file.state)
    defer textedit.destroy(&file.state)
    textedit.set_text(&file.state, "<div>x</div>")
    textedit.set_single_cursor(&file.state, 4)
    append(&thor.open_files, file)
    signal_set(&thor.active_file, 0)

    s := &thor.linked
    s.active = true
    s.path = strings.clone("a.html")
    s.revision = file.state.revision
    append(&s.ranges, lang.Text_Range{1, 4}, lang.Text_Range{8, 11})

    testing.expect_value(t, textedit.insert_at(&file.state, 4, "v"), textedit.Error.None)
    thor_linked_tick(thor)
    testing.expect_value(t, textedit.text(&file.state), "<divv>x</divv>")
    testing.expect(t, s.active, "the session ended after an edit inside a span")
    if len(s.ranges) == 2 {
        testing.expect_value(t, s.ranges[1], lang.Text_Range{9, 13})
    }

    testing.expect_value(t, textedit.insert_at(&file.state, 0, " "), textedit.Error.None)
    thor_linked_tick(thor)
    testing.expect(t, !s.active, "an edit outside the spans kept the session")
    testing.expect_value(t, textedit.text(&file.state), " <divv>x</divv>")
}
