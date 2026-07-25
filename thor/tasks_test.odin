package thor

import "core:testing"

// Tasks survive a write/read of tasks.json unchanged, in order.
// Run from the repository root: odin test thor
@(test)
test_tasks_round_trip :: proc(t: ^testing.T) {
    build := Task {name = "build", command = "odin build ."}
    test := Task {name = "test", command = "odin test thor"}

    data, ok := tasks_encode([]^Task {&build, &test})
    testing.expect(t, ok, "could not encode the tasks")

    tasks := tasks_decode(nil, data)
    defer {
        for task in tasks {
            delete(task.name)
            delete(task.command)
            free(task)
        }
        delete(tasks)
    }

    testing.expect_value(t, len(tasks), 2)
    testing.expect_value(t, tasks[0].name, "build")
    testing.expect_value(t, tasks[0].command, "odin build .")
    testing.expect_value(t, tasks[1].name, "test")
    testing.expect_value(t, tasks[1].command, "odin test thor")
}

// A task needs both halves to be runnable, so blank entries are dropped rather
// than shown as dead menu rows.
@(test)
test_tasks_decode_skips_incomplete :: proc(t: ^testing.T) {
    source := `{"tasks": [
        {"name": "", "command": "echo nameless"},
        {"name": "no command", "command": "   "},
        {"name": "  run  ", "command": "  echo hi  "}
    ]}`

    tasks := tasks_decode(nil, transmute([]u8) source)
    defer {
        for task in tasks {
            delete(task.name)
            delete(task.command)
            free(task)
        }
        delete(tasks)
    }

    testing.expect_value(t, len(tasks), 1)
    testing.expect_value(t, tasks[0].name, "run")
    testing.expect_value(t, tasks[0].command, "echo hi")
}

// The selection is held by name, so it survives a reload of the same tasks and
// falls back to the first one when the name is gone (removed, or another
// workspace's).
@(test)
test_task_selection_resolves_by_name :: proc(t: ^testing.T) {
    thor: Thor
    defer {
        thor_clear_tasks(&thor)
        delete(thor.active_task_name)
    }
    thor.tasks = tasks_decode(&thor, transmute([]u8) string(
        `{"tasks": [{"name": "build", "command": "b"}, {"name": "test", "command": "t"}]}`,
    ))

    thor_select_task(&thor, "test")
    testing.expect(t, thor_active_task(&thor) != nil, "the selected task should resolve")
    testing.expect_value(t, thor_active_task(&thor).command, "t")

    thor_select_task(&thor, "gone")
    thor_sync_task_selector(&thor)
    testing.expect_value(t, thor.active_task_name, "build")

    thor_clear_tasks(&thor)
    thor_sync_task_selector(&thor)
    testing.expect_value(t, thor.active_task_name, "")
    testing.expect(t, thor_active_task(&thor) == nil, "no tasks means no active task")
}

// Malformed JSON leaves the workspace with no tasks instead of failing the load.
@(test)
test_tasks_decode_malformed :: proc(t: ^testing.T) {
    tasks := tasks_decode(nil, transmute([]u8) string("not json"))
    defer delete(tasks)
    testing.expect_value(t, len(tasks), 0)
}
