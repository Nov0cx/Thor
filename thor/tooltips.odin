package thor

// Hover explanations for the title bar, the panel headers and the welcome page.
// The controls there are icon-only, so nothing else says what they do.
//
// One pass over every control, run again after a settings reload, because the
// dim second line of each is the chord the action is bound to.

import "../setting"
import "../ui"

thor_apply_tooltips :: proc(thor: ^Thor) {
    explorer := setting.keybind_to_string(thor.toggle_explorer_key)
    console := setting.keybind_to_string(thor.console_toggle_key)

    ui.widget_set_tooltip(&thor.top_logo.widget, "Settings", thor_action_shortcut(thor, "open_settings_gui"))

    ui.widget_set_tooltip(&thor.menu_file_button.widget, "Files, folders and windows")
    ui.widget_set_tooltip(&thor.menu_edit_button.widget, "Undo, clipboard and selection")
    ui.widget_set_tooltip(&thor.menu_view_button.widget, "Panels, split view and appearance")
    ui.widget_set_tooltip(&thor.menu_help_button.widget, "Tutorial, manual and updates")

    ui.widget_set_tooltip(&thor.explorer_toggle_button.widget, "Hide the explorer", explorer)
    ui.widget_set_tooltip(&thor.explorer_restore_button.widget, "Show the explorer", explorer)
    ui.widget_set_tooltip(&thor.console_toggle_button.widget, "Hide the console", console)
    ui.widget_set_tooltip(&thor.console_restore_button.widget, "Show the console", console)

    ui.widget_set_tooltip(&thor.update_button.widget, "A new version is available. Click to install it")

    ui.widget_set_tooltip(&thor.tasks_add_button.widget, "Add a task to the workspace", thor_action_shortcut(thor, "add_task"))
    ui.widget_set_tooltip(&thor.tasks_run_button.widget, "Run the selected task", thor_action_shortcut(thor, "run_selected_task"))
    thor_sync_task_tooltip(thor)

    ui.widget_set_tooltip(&thor.minimize_button.widget, "Minimize")
    ui.widget_set_tooltip(&thor.maximize_button.widget, "Maximize or restore")
    ui.widget_set_tooltip(&thor.close_button.widget, "Close the window")

    ui.widget_set_tooltip(&thor.welcome_open_folder_button.widget, "Open a folder as the workspace")
    ui.widget_set_tooltip(&thor.welcome_open_file_button.widget, "Open one file, and its folder as the workspace")
}

// The task selector says which command it runs, so the name in tasks.json does
// not have to. Re-run whenever the selected task changes.
thor_sync_task_tooltip :: proc(thor: ^Thor) {
    if thor.tasks_select_button == nil {
        return
    }
    text := "No tasks. Add one to run it from here"
    if task := thor_active_task(thor); task != nil {
        text = task.command
    }
    ui.widget_set_tooltip(&thor.tasks_select_button.widget, text, thor_action_shortcut(thor, "run_task"))
}
