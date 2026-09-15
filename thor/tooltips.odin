// Hover explanations for the titlebar and the welcome page. The controls there
// are icon-only or terse, so nothing else says what they do.
//
// A tooltip is declared at the node it belongs to, so each caller passes the id
// the frame just built. The chord goes on a dim second line.
package thor

import "core:strings"

import ui "../vendor/loom/loom"

// A tooltip for `id`. `chord` is the keybind label, dim under the text; pass ""
// where the action has none.
thor_tip :: proc(thor: ^Thor, id: ui.Id, text: string, chord := "") {
    if text == "" {
        return
    }
    if chord == "" {
        ui.tooltip(text, id)
        return
    }

    body := strings.concatenate({text, "\n", chord}, context.temp_allocator)
    dim := make([]ui.Text_Span, 1, context.temp_allocator)
    dim[0] = {start = len(text) + 1, end = len(body), color = thor.theme.disabled}
    ui.tooltip(body, id, el = {spans = dim})
}

// What each titlebar menu covers. The dropdown itself names the commands.
@(private = "file")
MENU_TIPS := [?]string {
    "Files, folders and windows",
    "Undo, clipboard and selection",
    "Panels, split view and appearance",
    "Changes, history and branches",
    "Tutorial, manual and updates",
}

thor_menu_tip :: proc(thor: ^Thor, id: ui.Id, index: int) {
    if index < 0 || index >= len(MENU_TIPS) {
        return
    }
    chord := ""
    switch index {
    case 3:
        chord = thor_action_shortcut(thor, "open_git_gui")
    }
    thor_tip(thor, id, MENU_TIPS[index], chord)
}

// The task selector says which command it runs, so the name in tasks.json does
// not have to.
thor_task_select_tip :: proc(thor: ^Thor, id: ui.Id) {
    text := "No tasks. Add one to run it from here"
    if task := thor_active_task(thor); task != nil {
        text = task.command
    }
    thor_tip(thor, id, text, thor_action_shortcut(thor, "run_task"))
}
