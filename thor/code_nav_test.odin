package thor

import "core:strings"
import "core:testing"
import "core:time"

import "../editview"
import "../lang"
import "../textedit"

@(private = "file")
nav_stub_handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".stub"
}

// Answers a selection chain of "alpha", "alpha beta" and the whole buffer.
@(private = "file")
nav_stub_resolve :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {
    if req.kind != .Selection_Range {
        return
    }
    append(&res.ranges, lang.Text_Range{0, 5}, lang.Text_Range{0, 10}, lang.Text_Range{0, 22})
    res.ok = true
}

@(private = "file")
nav_land :: proc(user: rawptr, res: ^lang.Result) {
    thor_on_lang_result(user, res)
}

@(private = "file")
nav_selection :: proc(file: ^Open_File) -> lang.Text_Range {
    lo, hi := textedit.selection_range(textedit.primary_cursor(&file.state))
    return {lo, hi}
}

// Expand takes the chain one step at a time and shrink walks back down it.
@(test)
test_expand_and_shrink_selection :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    lang.manager_init(&thor.lang_manager)
    defer lang.manager_destroy(&thor.lang_manager)
    lang.manager_register(&thor.lang_manager, lang.Backend{name = "stub", handles = nav_stub_handles, resolve = nav_stub_resolve})
    defer thor_nav_destroy(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)
    thor.active_file = make_signal(-1)

    file := new(Open_File)
    defer free(file)
    file.name = "a.stub"
    file.path = "a.stub"
    file.loaded = true
    textedit.init(&file.state)
    defer textedit.destroy(&file.state)
    textedit.set_text(&file.state, "alpha beta\ngamma delta\n")
    textedit.set_single_cursor(&file.state, 2)
    append(&thor.open_files, file)
    signal_set(&thor.active_file, 0)

    pump :: proc(thor: ^Thor) {
        for _ in 0 ..< 2000 {
            time.sleep(time.Millisecond)
            lang.manager_dispatch(&thor.lang_manager, thor, nav_land)
            if thor.nav.chain_request_id == 0 {
                return
            }
        }
    }

    thor_expand_selection(thor)
    pump(thor)
    testing.expect_value(t, nav_selection(file), lang.Text_Range{0, 5})

    // A chain that is still current needs no new request.
    thor_expand_selection(thor)
    testing.expect_value(t, thor.nav.chain_request_id, 0)
    testing.expect_value(t, nav_selection(file), lang.Text_Range{0, 10})
    thor_expand_selection(thor)
    testing.expect_value(t, nav_selection(file), lang.Text_Range{0, 22})
    thor_expand_selection(thor)
    testing.expect_value(t, nav_selection(file), lang.Text_Range{0, 22})

    thor_shrink_selection(thor)
    testing.expect_value(t, nav_selection(file), lang.Text_Range{0, 10})
    thor_shrink_selection(thor)
    thor_shrink_selection(thor)
    testing.expect_value(t, nav_selection(file), lang.Text_Range{2, 2})

    // A moved caret starts a new chain.
    textedit.set_single_cursor(&file.state, 12)
    thor_expand_selection(thor)
    testing.expect(t, thor.nav.chain_request_id != 0, "a selection the chain does not know asks again")
}

// The reference counts merge with the file's inlay hints by offset.
@(test)
test_lens_view_merges_by_offset :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.nav.lens_on = true
    file := new(Open_File)
    defer free(file)
    textedit.init(&file.state)
    defer textedit.destroy(&file.state)
    textedit.set_text(&file.state, "aa bb cc dd\n")
    defer thor_destroy_file_lens(file)
    defer delete(file.inlay_view)

    append(&file.inlay_view, editview.Inlay{offset = 1, label = "h1"}, editview.Inlay{offset = 9, label = "h2"})
    file.lens.source = strings.clone(textedit.text(&file.state))
    append(&file.lens.items, editview.Inlay{offset = 2, label = strings.clone("2 references")}, editview.Inlay{offset = 5, label = strings.clone("no references")})
    file.lens.ready = true
    file.lens.asked = file.state.revision
    file.lens.asked_valid = true

    view := thor_lens_view(thor, file)
    testing.expect_value(t, len(view), 4)
    offsets := [?]int{1, 2, 5, 9}
    for want, i in offsets {
        testing.expect_value(t, view[i].offset, want)
    }

    // An edit before the counts moves them with the text.
    textedit.set_single_cursor(&file.state, 0)
    textedit.insert_text(&file.state, "xx")
    file.inlay_view_valid = false
    clear(&file.inlay_view)
    moved := thor_lens_view(thor, file)
    testing.expect_value(t, len(moved), 2)
    testing.expect_value(t, moved[0].offset, 4)

    thor.nav.lens_on = false
    testing.expect_value(t, len(thor_lens_view(thor, file)), 0)
}
