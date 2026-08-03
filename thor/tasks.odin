package thor

// Workspace tasks: named shell commands kept in <workspace>/.thor/tasks.json and
// run in the console from the titlebar task controls or the command palette. The
// committable counterpart to the console prompt: what a workspace builds, tests
// and runs with, shared with everyone who opens the folder.
//
// The titlebar carries three: add, a selector naming the active task that drops
// down the rest, and run. The selection is per workspace and lives in the
// session, not in the committed file.

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

import "../ui"
import "../widgets"

// Selector geometry: the button tracks the width of its label between these
// bounds, leaving room for the padding and the caret. The icon size matches the
// other titlebar controls so it comes from an atlas that is already baked (only
// the manifest's preload sizes are).
TASK_SELECTOR_MIN_WIDTH :: 110
TASK_SELECTOR_MAX_WIDTH :: 260
TASK_SELECTOR_PAD_X     :: 10
TASK_SELECTOR_ICON_SIZE :: 16

// A named command run in the workspace directory. Carries its owner so a menu
// row can run it with the task itself as the row's data.
Task :: struct {
    thor:    ^Thor,
    name:    string, // owned; the menu borrows it as its label
    command: string, // owned
}

// On-disk shape of tasks.json. Field names are the JSON keys.
@(private = "file")
Task_File :: struct {
    tasks: []Task_Entry,
}

@(private = "file")
Task_Entry :: struct {
    name:    string,
    command: string,
}

// Task file for a workspace: <workspace>/.thor/tasks.json.
thor_tasks_file :: proc(workspace_dir: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({thor_workspace_config_dir(workspace_dir), "/tasks.json"}, allocator)
}

// Parses tasks.json into owned tasks, stamping `thor` on each. Entries missing a
// name or a command are dropped; malformed JSON yields none.
tasks_decode :: proc(thor: ^Thor, data: []u8, allocator := context.allocator) -> [dynamic]^Task {
    tasks := make([dynamic]^Task, allocator)

    file: Task_File
    if err := json.unmarshal(data, &file, allocator = context.temp_allocator); err != nil {
        log.warnf("Ignoring malformed tasks file: %v", err)
        return tasks
    }

    for entry in file.tasks {
        name := strings.trim_space(entry.name)
        command := strings.trim_space(entry.command)
        if name == "" || command == "" {
            continue
        }
        task := new(Task, allocator)
        task.thor = thor
        task.name = strings.clone(name, allocator)
        task.command = strings.clone(command, allocator)
        append(&tasks, task)
    }
    return tasks
}

// Serializes `tasks` as the contents of tasks.json.
tasks_encode :: proc(tasks: []^Task, allocator := context.temp_allocator) -> ([]u8, bool) {
    entries := make([]Task_Entry, len(tasks), context.temp_allocator)
    for task, index in tasks {
        entries[index] = Task_Entry {name = task.name, command = task.command}
    }
    data, err := json.marshal(Task_File {tasks = entries}, {pretty = true}, allocator)
    return data, err == nil
}

// Replaces the in-memory tasks with the workspace's. Missing file: none.
thor_load_tasks :: proc(thor: ^Thor) {
    // The dropdown borrows task names as its row labels, so it must not outlive
    // them; a config poll can reload while it is open.
    if thor.menu != nil && widgets.menu_is_open(thor.menu) {
        widgets.menu_close(thor.menu, &thor.ui_context)
    }
    thor_clear_tasks(thor)
    defer thor_sync_task_selector(thor)
    data, err := os.read_entire_file(thor_tasks_file(thor.workspace_dir), context.temp_allocator)
    if err != nil {
        return
    }
    thor.tasks = tasks_decode(thor, data)
}

thor_clear_tasks :: proc(thor: ^Thor) {
    for task in thor.tasks {
        thor_free_task(task)
    }
    delete(thor.tasks)
    thor.tasks = nil
}

@(private = "file")
thor_free_task :: proc(task: ^Task) {
    delete(task.name)
    delete(task.command)
    free(task)
}

// Writes the tasks to the workspace's tasks.json, creating .thor/ when needed.
// Rebaselines the config watcher so our own write does not read as an edit.
thor_save_tasks :: proc(thor: ^Thor) {
    cfg_dir := thor_workspace_config_dir(thor.workspace_dir)
    if !os.is_dir(cfg_dir) {
        if err := os.make_directory(cfg_dir); err != nil {
            log.errorf("Could not create %q: %v", cfg_dir, err)
            thor_flash_status(thor, "Could not save tasks", true)
            return
        }
        // The overlay directory exists now, so config writes belong there too.
        thor.workspace_initialized = true
    }

    data, ok := tasks_encode(thor.tasks[:])
    if !ok {
        log.error("Could not serialize tasks")
        return
    }
    path := thor_tasks_file(thor.workspace_dir)
    if err := os.write_entire_file(path, data); err != nil {
        log.errorf("Could not write %q: %v", path, err)
        thor_flash_status(thor, "Could not save tasks", true)
        return
    }
    thor_settings_mark_clean(thor)
}

// The task named `name`, or nil.
@(private = "file")
thor_find_task :: proc(thor: ^Thor, name: string) -> ^Task {
    for task in thor.tasks {
        if task.name == name {
            return task
        }
    }
    return nil
}

// Runs `task` in the console, revealing the panel first.
thor_run_task :: proc(thor: ^Thor, task: ^Task) {
    if !ui.signal_get(&thor.console_visible) {
        ui.signal_set(&thor.console_visible, true)
        thor_apply_layout_state(thor)
    }
    if thor.console == nil {
        thor_flash_status(thor, "No terminal is open", true)
        return
    }
    if !widgets.console_run_command(thor.console, task.command) {
        thor_flash_status(thor, "A command is already running", true)
    }
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

// The selected task, or nil when nothing is selected or the name is stale.
thor_active_task :: proc(thor: ^Thor) -> ^Task {
    if thor.active_task_name == "" {
        return nil
    }
    return thor_find_task(thor, thor.active_task_name)
}

// Selects the task named `name`; "" clears the selection.
thor_select_task :: proc(thor: ^Thor, name: string) {
    if name == thor.active_task_name {
        return
    }
    delete(thor.active_task_name)
    thor.active_task_name = strings.clone(name)
    thor_sync_task_selector(thor)
}

// Points the selector at the active task, falling back to the first one when
// the selection is gone (removed, or carried over from another workspace), and
// resizes the button to its label. No-op before the titlebar is built.
thor_sync_task_selector :: proc(thor: ^Thor) {
    if thor_active_task(thor) == nil {
        delete(thor.active_task_name)
        thor.active_task_name = len(thor.tasks) > 0 ? strings.clone(thor.tasks[0].name) : ""
    }

    button := thor.tasks_select_button
    if button == nil {
        return
    }
    button.text = thor.active_task_name != "" ? thor.active_task_name : "No tasks"
    label_width := cast(f32) ui.measure_text(button.text, button.font_size)
    button.min_size.x = clamp(
        label_width + TASK_SELECTOR_PAD_X * 2 + TASK_SELECTOR_ICON_SIZE + 8,
        TASK_SELECTOR_MIN_WIDTH,
        TASK_SELECTOR_MAX_WIDTH,
    )
}

// ---------------------------------------------------------------------------
// Titlebar task controls
// ---------------------------------------------------------------------------

// Selector dropdown: the workspace tasks, then the rows that edit them. Picking
// a task selects it; the run button next to the selector runs it.
thor_open_tasks_menu :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data

    widgets.menu_clear(thor.menu)
    if len(thor.tasks) == 0 {
        widgets.menu_add(thor.menu, "No tasks", nil, nil, false)
    }
    for task in thor.tasks {
        widgets.menu_add(thor.menu, task.name, thor_menu_select_task, task)
    }
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Run Task...", thor_cmd_run_task, thor, len(thor.tasks) > 0)
    widgets.menu_add(thor.menu, "Add Task...", thor_cmd_add_task, thor)
    widgets.menu_add(thor.menu, "Remove Task...", thor_cmd_remove_task, thor, len(thor.tasks) > 0)
    widgets.menu_add(thor.menu, "Edit Tasks (JSON)", thor_cmd_edit_tasks, thor)

    button := thor.tasks_select_button
    anchor := rl.Vector2 {button.bounds.x, button.bounds.y + button.bounds.height}
    widgets.menu_open(thor.menu, &thor.ui_context, anchor)
}

// Menu row: selects the task the row was built from.
@(private = "file")
thor_menu_select_task :: proc(data: rawptr) {
    task := cast(^Task) data
    thor_select_task(task.thor, task.name)
}

// Titlebar add button.
thor_click_add_task :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor_cmd_add_task(data)
}

// Titlebar run button.
thor_click_run_task :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor_cmd_run_active_task(data)
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

// Task names in menu order, for the pickers.
@(private = "file")
thor_task_names :: proc(thor: ^Thor) -> []string {
    names := make([]string, len(thor.tasks), context.temp_allocator)
    for task, index in thor.tasks {
        names[index] = task.name
    }
    return names
}

// Run button: runs whatever the selector shows.
thor_cmd_run_active_task :: proc(data: rawptr) {
    thor := cast(^Thor) data
    task := thor_active_task(thor)
    if task == nil {
        thor_flash_status(thor, "No task selected", true)
        return
    }
    thor_run_task(thor, task)
}

// Picks a task by name and runs it, leaving it selected.
thor_cmd_run_task :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if len(thor.tasks) == 0 {
        thor_flash_status(thor, "No tasks in this workspace", true)
        return
    }
    widgets.command_palette_pick(thor.command_palette, &thor.ui_context, "Run task", thor_task_names(thor), thor_pick_run_task, thor)
}

@(private = "file")
thor_pick_run_task :: proc(data: rawptr, name: string) {
    thor := cast(^Thor) data
    if task := thor_find_task(thor, name); task != nil {
        thor_select_task(thor, task.name)
        thor_run_task(thor, task)
    }
}

// Prompts for a name, then for the command it runs. An existing name is updated
// rather than duplicated.
thor_cmd_add_task :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.command_palette_prompt(thor.command_palette, &thor.ui_context, "Task name", thor_prompt_task_name, thor)
}

@(private = "file")
thor_prompt_task_name :: proc(data: rawptr, name: string) {
    thor := cast(^Thor) data
    delete(thor.pending_task_name)
    thor.pending_task_name = strings.clone(name)
    widgets.command_palette_prompt(thor.command_palette, &thor.ui_context, "Command to run", thor_prompt_task_command, thor)
}

@(private = "file")
thor_prompt_task_command :: proc(data: rawptr, command: string) {
    thor := cast(^Thor) data
    defer {
        delete(thor.pending_task_name)
        thor.pending_task_name = ""
    }
    if thor.pending_task_name == "" {
        return
    }

    if task := thor_find_task(thor, thor.pending_task_name); task != nil {
        delete(task.command)
        task.command = strings.clone(command)
    } else {
        task := new(Task)
        task.thor = thor
        task.name = strings.clone(thor.pending_task_name)
        task.command = strings.clone(command)
        append(&thor.tasks, task)
    }
    thor_save_tasks(thor)
    // A freshly entered task is what you want to run next.
    thor_select_task(thor, thor.pending_task_name)
    thor_flash_status(thor, "Task saved")
}

thor_cmd_remove_task :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if len(thor.tasks) == 0 {
        thor_flash_status(thor, "No tasks in this workspace", true)
        return
    }
    widgets.command_palette_pick(thor.command_palette, &thor.ui_context, "Remove task", thor_task_names(thor), thor_pick_remove_task, thor)
}

@(private = "file")
thor_pick_remove_task :: proc(data: rawptr, name: string) {
    thor := cast(^Thor) data
    for task, index in thor.tasks {
        if task.name != name {
            continue
        }
        thor_free_task(task)
        ordered_remove(&thor.tasks, index)
        thor_save_tasks(thor)
        thor_sync_task_selector(thor)
        thor_flash_status(thor, "Task removed")
        return
    }
}

// Opens the workspace's tasks.json in a tab, writing it first when it is absent
// so there is always a file to edit. The config poll picks up manual edits.
thor_cmd_edit_tasks :: proc(data: rawptr) {
    thor := cast(^Thor) data
    path := thor_tasks_file(thor.workspace_dir)
    if !os.exists(path) {
        thor_save_tasks(thor)
    }
    thor_open_file(thor, path)
}
