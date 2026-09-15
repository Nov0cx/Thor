package thor

// The welcome page: shown in place of the editor while thor.workspace_dir is
// "". Reachable at startup (no CLI path, no last session) or via "Close
// Workspace", which tears a workspace down without replacing it.

import "core:log"
import "core:path/filepath"

import ui "../vendor/loom/loom"

// Rows the welcome page shows. thor_recent_workspaces keeps RECENT_WORKSPACES_MAX
// of them; the column has no room for that many.
WELCOME_RECENT_ROWS :: 5

WELCOME_WIDTH :: f32(520)
WELCOME_RECENT_ROW_H :: f32(36)
WELCOME_TITLE_FONT_SIZE :: i32(28)

// Tears down the current workspace and returns to the welcome page: the
// teardown half of thor_open_folder, without opening a replacement. A later
// bare launch goes back to the welcome page too, since the last-workspace
// record is cleared at the end.
thor_close_workspace :: proc(thor: ^Thor) {
    thor_unregister_window(thor.workspace_dir)

    thor_cmd_save_all(thor)
    thor_drain_io(thor)
    thor_save_session(thor)
    thor_shutdown_watcher(thor)

    for len(thor.open_files) > 0 {
        thor_close_file(thor, 0)
    }
    thor_drain_io(thor)
    thor_set_active_file(thor, -1)
    thor_clear_git_status(thor)
    thor_clear_file_index(thor)
    thor.pending_goto_active = false
    delete(thor.pending_goto_path)
    thor.pending_goto_path = ""
    thor_clear_jump_list(thor)
    thor_clear_tasks(thor)
    thor_sync_task_selector(thor)

    delete(thor.workspace_dir)
    delete(thor.workspace_prefix)
    delete(thor.git_branch)
    delete(thor.git_prefix)
    thor.workspace_dir = ""
    thor.workspace_prefix = ""
    thor.git_branch = ""
    thor.git_prefix = ""
    // thor_refresh_file_index no-ops on the empty workspace, which is right
    // for the welcome page — there is nothing to index.

    // The workspace's .thor/ overlay and plugins no longer apply. The rebuild is
    // deferred: this runs inside a command callback, and a plugin-registered one
    // stands on the widgets thor_reload_plugins destroys.
    thor_reload_settings(thor)
    thor.plugin_reload_pending = true

    thor_explorer_set_root(thor, "")
    // The palette holds the prefix by reference and the old one was just freed.

    // The workspace's .thor/tips.json went away with it, and the floating card
    // has no editor to float over.
    thor.tip_open = false
    thor_refresh_tip_cards(thor)
    thor_apply_layout_state(thor) // hides explorer/console, shows the welcome page
    thor_record_last_workspace("") // a bare launch later goes to the welcome page

    log.infof("Closed workspace")
}

// File menu / palette: close the current workspace, if any.
thor_cmd_close_workspace :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.workspace_dir == "" {
        return
    }
    thor_close_workspace(thor)
}

// Welcome page: pick a folder to open as the workspace.
thor_welcome_open_folder :: proc(data: rawptr) {
    thor_cmd_open_folder(data)
}

// Welcome page: pick a file anywhere on disk and make its folder the
// workspace, mirroring the CLI single-file launch case.
thor_welcome_open_file :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if path, ok := thor_pick_file("Open File", ""); ok {
        defer delete(path)
        thor_open_folder(thor, filepath.dir(path))
        thor_open_file(thor, path)
    }
}

// ---- the view ---------------------------------------------------------------------

// Shown in place of the editor while no workspace is open: the mark, the two
// open buttons, the recent list and the tip of the day.
thor_welcome_view :: proc(thor: ^Thor) {
    ui.scope(
        {
            key = "welcome",
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                bg = thor.theme.background,
            },
        },
    )

    ui.scope(
        {
            key = "column",
            props = {
                w = ui.Px(WELCOME_WIDTH),
                max_w = ui.viewport().x - 80,
                h = ui.FIT,
                dir = .Column,
                gap = {0, 10},
            },
        },
    )

    ui.label(
        "Thor",
        {
            key = "title",
            props = {
                color = thor.theme.foreground,
                font_size = f32(WELCOME_TITLE_FONT_SIZE),
                text_wrap = .None,
            },
        },
    )
    ui.label(
        "Open a folder to start, or pick a file.",
        {key = "sub", props = {color = thor.theme.muted_color, text_wrap = .None}},
    )

    {
        ui.scope(
            {
                key = "actions",
                props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, gap = {8, 0}, margin = {t = 6}},
            },
        )
        if welcome_button(
            thor,
            "open-folder",
            "Open Folder",
            "folder",
            "Open a folder as the workspace",
        ) {
            thor_cmd_open_folder(thor)
            return
        }
        if welcome_button(
            thor,
            "open-file",
            "Open File",
            "file",
            "Open one file, and its folder as the workspace",
        ) {
            thor_welcome_open_file(thor)
            return
        }
    }

    welcome_recent(thor)
    welcome_tip(thor)
}

@(private = "file")
welcome_recent :: proc(thor: ^Thor) {
    paths := thor_recent_workspaces(context.temp_allocator)
    if len(paths) == 0 {
        return
    }

    ui.label(
        "Recent",
        {key = "recent-label", props = {color = thor.theme.disabled, margin = {t = 14}, text_wrap = .None}},
    )
    ui.scope(
        {
            key = "recent",
            props = {w = ui.Grow(1), h = ui.FIT, dir = .Column, gap = {0, 6}},
        },
    )

    for path, index in paths {
        if index >= WELCOME_RECENT_ROWS {
            break
        }
        ui.push_id_int(i64(index))
        it := ui.scope(
            {
                key = "row",
                flags = {.Clickable},
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(WELCOME_RECENT_ROW_H),
                    dir = .Row,
                    align = .Center,
                    gap = {8, 0},
                    pad = ui.xy(10, 0),
                    radius = ui.rad(6),
                    bg = thor.theme.buttons,
                    cursor = .Pointer,
                },
                hover = {bg = thor.theme.active},
            },
        )
        thor_icon_label(thor, "folder", thor.theme.muted_color)
        ui.label(
            filepath.base(path),
            {key = "name", props = {color = thor.theme.foreground, text_wrap = .None}},
        )
        // The name alone reads the same for two folders of one name, so the
        // whole path rides beside it.
        ui.label(
            path,
            {key = "path", props = {w = ui.Grow(1), color = thor.theme.disabled, text_wrap = .Ellipsis}},
        )
        ui.pop_id()

        if it.clicked {
            thor_open_folder_request(thor, path)
            return
        }
    }
}

@(private = "file")
welcome_tip :: proc(thor: ^Thor) {
    tip, index, count, shortcut, ok := thor_tip_current(thor)
    if !ok {
        return
    }

    ui.scope(
        {
            key = "tip",
            props = {
                w = ui.Grow(1),
                h = ui.FIT,
                dir = .Column,
                gap = {0, 8},
                pad = ui.all(14),
                margin = {t = 18},
                radius = ui.rad(8),
                bg = thor.theme.second_background,
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
    )
    thor_tip_card_body(thor, tip, index, count, shortcut, closable = false)
}

@(private = "file")
welcome_button :: proc(thor: ^Thor, key, label, icon, tip: string) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                h = ui.Px(34),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = ui.xy(14, 0),
                radius = ui.rad(6),
                bg = thor.theme.buttons,
                border = {width = ui.all(1), color = thor.theme.accent_color},
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.active},
        },
    )
    thor_icon_label(thor, icon, thor.theme.accent_color)
    ui.label(label, {key = "text", props = {color = thor.theme.foreground, text_wrap = .None}})
    thor_tip(thor, it.id, tip)
    return it.clicked
}
