package thor

import "core:os"
import "core:testing"
import "core:time"

import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

// Verifies the thor.doc host service (thor_plugin_doc): the first call opens a
// tab that loads the written text, and a second call refreshes the same tab's
// buffer in place (no new tab, no unsaved churn) rather than reopening it. This
// is what lets the tutorial tick challenges off live. Run from the repo root.
@(test)
test_plugin_doc_opens_and_refreshes :: proc(t: ^testing.T) {
    PATH :: "thor_doc_host_test.md"

    thor := new(Thor)
    defer free(thor)
    thor.config = setting.load("settings")
    defer setting.destroy(&thor.config)
    thor.active_file = ui.make_signal(-1)
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.finished_loads = make([dynamic]^Load_Job)
    thor.finished_saves = make([dynamic]^Save_Job)
    thor.pane_file = {-1, -1}
    thor.editor = widgets.editor_create("test-editor")
    thor.editor2 = widgets.editor_create("test-editor2")
    defer {
        for len(thor.open_files) > 0 {
            thor_close_file(thor, 0)
        }
        delete(thor.open_files)
        delete(thor.zombie_files)
        delete(thor.finished_loads)
        delete(thor.finished_saves)
        widgets.editor_destroy(&thor.editor.widget)
        widgets.editor_destroy(&thor.editor2.widget)
    }
    defer os.remove(PATH)

    // First call opens the document and reveals it.
    thor_plugin_doc(thor, PATH, "first version\n", true)
    testing.expectf(t, len(thor.open_files) == 1, "expected 1 tab, got %d", len(thor.open_files))
    if len(thor.open_files) != 1 {
        return
    }

    file := thor.open_files[0]
    for _ in 0 ..< 500 {
        thor_update_files(thor)
        if file.loaded || file.load_failed {
            break
        }
        time.sleep(2 * time.Millisecond)
    }
    testing.expect(t, file.loaded, "document did not load")
    testing.expect(t, textedit.text(&file.state) == "first version\n", "document did not load the written text")

    // Second call refreshes the same tab in place: no new tab, buffer replaced,
    // and left marked clean (revision matches the just-saved revision).
    thor_plugin_doc(thor, PATH, "second version\n", false)
    testing.expectf(t, len(thor.open_files) == 1, "refresh opened a new tab (%d tabs)", len(thor.open_files))
    testing.expect(t, thor.open_files[0] == file, "refresh replaced the open file record")
    testing.expect(t, textedit.text(&file.state) == "second version\n", "buffer was not refreshed in place")
    testing.expect(t, file.state.revision == file.saved_revision, "refresh left the buffer dirty")
}
