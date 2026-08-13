package thor

// The editor side of the updater. A worker asks GitHub what the latest release
// is, the titlebar button and one prompt report it, and a second worker stages
// the archive that the main thread then swaps in.
//
// A dismissal is remembered: the version the user said no to is written to
// sessions/update.json and never prompted for again, which is what makes the
// titlebar button the only way back to it.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../setting"
import "../ui"
import "../update"
import "../widgets"

import rl "vendor:raylib"

// The titlebar button's metrics, matching the task selector beside it.
@(private = "file")
UPDATE_BUTTON_PAD_X :: 10

@(private = "file")
UPDATE_BUTTON_ICON_SIZE :: 16

@(private = "file")
UPDATE_BUTTON_MIN_WIDTH :: 40

@(private = "file")
UPDATE_BUTTON_MAX_WIDTH :: 180

// Where the throttle and the dismissal live. Machine state, not a preference,
// so it sits beside the other session records and not in settings.json.
@(private = "file")
UPDATE_FILE :: "sessions/update.json"

// How long after the first frame the background check runs. Late enough that
// the window, the fonts and the plugins are up.
@(private = "file")
START_DELAY :: 5.0

// The shortest time between two background checks. A manual check ignores it.
@(private = "file")
CHECK_INTERVAL :: i64(24 * 60 * 60)

// What the updater is doing. Found and Installing are the two states the
// titlebar button is visible in.
Update_State :: enum {
    Idle,
    Checking,
    Found,
    Installing,
}

// The two kinds of update work. They share a struct and a queue because the
// drain, the job accounting and the shutdown handling are identical.
Update_Kind :: enum {
    Check,
    Install,
}

// Async update work. The worker fills the out_ fields and appends itself to
// thor.finished_updates under io_mutex; the main thread applies and frees.
Update_Job :: struct {
    owner:        ^Thor,
    allocator:    runtime.Allocator,
    worker:       ^thread.Thread,
    kind:         Update_Kind,
    manual:       bool,   // a manual check also reports "up to date"
    // Install inputs, cloned on the main thread before the worker starts.
    in_url:       string, // owned
    in_sums_url:  string, // owned
    in_asset:     string, // owned
    in_size:      i64,
    in_target:    update.Target,
    // Set by the main thread at shutdown, read by the worker between download
    // slices so a quit does not wait out a whole download.
    cancel:       bool,
    // Results, applied and freed on the main thread.
    status:       update.Status,
    out_version:  string, // owned
    out_notes:    string, // owned
    out_url:      string, // owned
    out_sums_url: string, // owned
    out_asset:    string, // owned
    out_root:     string, // owned; Install only, the staged folder to swap from
    out_size:     i64,
    out_installable: bool,
}

// What a previous run left: when the last completed check was (unix seconds,
// so the throttle survives a restart) and the one version the user dismissed.
@(private = "file")
Update_Record :: struct {
    last_check:      i64,
    skipped_version: string,
}

// Whether a background check is due. Always true for a manual one, which is an
// explicit request and beats both the throttle and the setting.
thor_update_due :: proc(last_check: i64, now: i64, manual: bool) -> bool {
    if manual {
        return true
    }
    // A clock that moved backwards would otherwise park the check forever.
    if now < last_check {
        return true
    }
    return now - last_check >= CHECK_INTERVAL
}

// Whether a found version still deserves a prompt. A dismissal covers exactly
// the version it was given, so the next release asks again.
thor_update_should_prompt :: proc(skipped_version: string, version: string) -> bool {
    return version != "" && version != skipped_version
}

// Starts a check unless one is already running. A manual check reports what it
// found either way; a background one is silent unless there is an update.
thor_check_for_updates :: proc(thor: ^Thor, manual: bool) {
    if thor.update_inflight {
        if manual {
            thor_flash_status(thor, "Already checking for updates")
        }
        return
    }
    if thor.update_state == .Installing {
        return
    }
    thor.update_inflight = true
    thor.update_state = .Checking

    job := new(Update_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.kind = .Check
    job.manual = manual

    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, update_check_worker)
}

// Starts the download and staging of the release the last check found.
thor_install_update :: proc(thor: ^Thor) {
    if thor.update_inflight || thor.update_state != .Found || thor.update_url == "" {
        return
    }
    target, has_target := update.target_host()
    if !has_target {
        thor_flash_status(thor, update.status_message(.No_Asset), true)
        return
    }
    thor.update_inflight = true
    thor.update_state = .Installing
    thor_sync_update_button(thor)

    job := new(Update_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.kind = .Install
    job.in_url = strings.clone(thor.update_url)
    job.in_sums_url = strings.clone(thor.update_sums_url)
    job.in_asset = strings.clone(thor.update_asset)
    job.in_size = thor.update_size
    job.in_target = target

    thor.update_job = job
    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, update_install_worker)
    thor_flash_status(thor, "Downloading the update...")
}

@(private = "file")
update_check_worker :: proc(job: ^Update_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    result := update.check(VERSION, job.allocator)
    job.status = result.status
    job.out_version = result.version
    job.out_notes = result.notes
    job.out_url = result.url
    job.out_sums_url = result.sums_url
    job.out_asset = result.asset
    job.out_size = result.size
    job.out_installable = result.installable

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_updates, job)
    sync.unlock(&job.owner.io_mutex)
}

@(private = "file")
update_install_worker :: proc(job: ^Update_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    plan := update.Install_Plan {
        url      = job.in_url,
        sums_url = job.in_sums_url,
        asset    = job.in_asset,
        size     = job.in_size,
        target   = job.in_target,
    }
    agent := update.user_agent(VERSION, context.temp_allocator)
    result := update.install_apply(plan, agent, &job.cancel, job.allocator)
    job.status = result.status
    job.out_root = result.root

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_updates, job)
    sync.unlock(&job.owner.io_mutex)
}

// Applies a finished job (called from thor_process_io). The swap itself is
// never done here: thor_drain_io calls this at shutdown, where replacing the
// install would race the teardown, so an ok install only sets update_swap_root
// and thor_poll_update acts on it.
thor_apply_update_job :: proc(thor: ^Thor, job: ^Update_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)

    switch job.kind {
    case .Check:
        thor_apply_update_check(thor, job)
    case .Install:
        thor_apply_update_install(thor, job)
    }

    delete(job.in_url)
    delete(job.in_sums_url)
    delete(job.in_asset)
    delete(job.out_version)
    delete(job.out_notes)
    delete(job.out_url)
    delete(job.out_sums_url)
    delete(job.out_asset)
    delete(job.out_root)
    if thor.update_job == job {
        thor.update_job = nil
    }
    free(job)
    thor.update_inflight = false
    thor.inflight_jobs -= 1
    thor_sync_update_button(thor)
}

@(private = "file")
thor_apply_update_check :: proc(thor: ^Thor, job: ^Update_Job) {
    record := thor_read_update_record()

    #partial switch job.status {
    case .Ok:
        thor_set_found_update(thor, job)
        thor_write_update_record(time.to_unix_seconds(time.now()), record.skipped_version)
        // A dismissed version keeps the button but never raises the prompt
        // again, so the user decides when to come back to it.
        thor.update_prompt_shown = !thor_update_should_prompt(record.skipped_version, thor.update_version)
        if job.manual {
            thor_flash_status(thor, fmt.tprintf("Thor %s is available", thor.update_version))
        }
    case .Up_To_Date:
        thor.update_state = .Idle
        thor_write_update_record(time.to_unix_seconds(time.now()), record.skipped_version)
        if job.manual {
            thor_flash_status(thor, update.status_message(.Up_To_Date))
        }
    case:
        thor.update_state = .Idle
        // A transient failure must not eat the day's slot, so only a real
        // answer from GitHub moves the throttle forward.
        if job.status != .No_Network && job.status != .Rate_Limited {
            thor_write_update_record(time.to_unix_seconds(time.now()), record.skipped_version)
        }
        if job.manual {
            thor_flash_status(thor, update.status_message(job.status), true)
        } else {
            log.debugf("Update check stopped: %v", job.status)
        }
    }
}

@(private = "file")
thor_apply_update_install :: proc(thor: ^Thor, job: ^Update_Job) {
    if job.status == .Ok {
        delete(thor.update_swap_root)
        thor.update_swap_root = strings.clone(job.out_root)
        return
    }
    // The release is still there to retry or to fetch by hand, so the button
    // stays and only the state goes back.
    thor.update_state = .Found
    if job.status != .Cancelled {
        thor_flash_status(thor, update.status_message(job.status), true)
    }
    update.install_cleanup_leftovers()
}

// Remembers what the check found. The titlebar button borrows update_version as
// its label and the prompt borrows update_prompt, so both outlive the widgets.
@(private = "file")
thor_set_found_update :: proc(thor: ^Thor, job: ^Update_Job) {
    delete(thor.update_version)
    delete(thor.update_notes)
    delete(thor.update_url)
    delete(thor.update_sums_url)
    delete(thor.update_asset)
    thor.update_version = strings.clone(job.out_version)
    thor.update_notes = strings.clone(job.out_notes)
    thor.update_url = strings.clone(job.out_url)
    thor.update_sums_url = strings.clone(job.out_sums_url)
    thor.update_asset = strings.clone(job.out_asset)
    thor.update_size = job.out_size
    thor.update_installable = job.out_installable
    thor.update_state = .Found
}

// Frees what the updater owns. Called from shutdown.
thor_clear_update :: proc(thor: ^Thor) {
    delete(thor.update_version)
    delete(thor.update_notes)
    delete(thor.update_url)
    delete(thor.update_sums_url)
    delete(thor.update_asset)
    delete(thor.update_prompt)
    delete(thor.update_swap_root)
    thor.update_version = ""
    thor.update_notes = ""
    thor.update_url = ""
    thor.update_sums_url = ""
    thor.update_asset = ""
    thor.update_prompt = ""
    thor.update_swap_root = ""
}

// Asks an in-flight download to stop between slices, so quitting mid-update
// waits out one slice instead of the whole archive.
thor_cancel_update :: proc(thor: ^Thor) {
    if thor.update_job != nil {
        sync.atomic_store(&thor.update_job.cancel, true)
    }
}

// The updater's frame slot, called from the run loop. Everything that takes
// focus or replaces files happens here rather than in a callback or a drain.
thor_poll_update :: proc(thor: ^Thor) {
    if thor.update_swap_root != "" {
        thor_swap_and_relaunch(thor)
        return
    }
    if !thor.update_started && rl.GetTime() >= START_DELAY {
        thor.update_started = true
        if setting.check_for_updates(&thor.config) {
            record := thor_read_update_record()
            if thor_update_due(record.last_check, time.to_unix_seconds(time.now()), false) {
                thor_check_for_updates(thor, manual = false)
            }
        }
    }
    if thor.update_state == .Found && !thor.update_prompt_shown {
        // One prompt at a time: the plugin permissions ask for the same palette.
        if thor.plugin_prompt_shown || len(thor.plugin_requests) > 0 {
            return
        }
        thor_prompt_update(thor)
    }
}

// Asks whether to install what the check found.
@(private = "file")
thor_prompt_update :: proc(thor: ^Thor) {
    thor.update_prompt_shown = true
    delete(thor.update_prompt)
    if thor.update_installable {
        thor.update_prompt = fmt.aprintf(
            "Thor %s is available, you have %s. Install it and restart?",
            thor.update_version,
            VERSION,
        )
    } else {
        thor.update_prompt = fmt.aprintf(
            "Thor %s is available, you have %s. Open the download page?",
            thor.update_version,
            VERSION,
        )
    }
    widgets.command_palette_confirm(
        thor.command_palette,
        &thor.ui_context,
        thor.update_prompt,
        thor_accept_update,
        thor,
        thor_dismiss_update,
    )
}

@(private = "file")
thor_accept_update :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.update_installable {
        thor_install_update(thor)
        return
    }
    thor_open_release_page(thor)
}

// Says no to this version for good. The titlebar button stays, so the answer
// costs nothing but the prompt.
@(private = "file")
thor_dismiss_update :: proc(data: rawptr) {
    thor := cast(^Thor) data
    record := thor_read_update_record()
    thor_write_update_record(record.last_check, thor.update_version)
    thor_flash_status(thor, "Update kept in the title bar")
}

// The titlebar button. Re-asks while an update is waiting, reports progress
// while one installs.
thor_click_update :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    if thor.update_state == .Installing {
        thor_flash_status(thor, "The update is downloading")
        return
    }
    if thor.update_state != .Found {
        return
    }
    thor.update_prompt_shown = false
    thor_prompt_update(thor)
}

// The Help menu and the palette entry. An explicit request beats both the
// throttle and the check_for_updates setting.
thor_cmd_check_for_updates :: proc(data: rawptr) {
    thor_check_for_updates(cast(^Thor) data, manual = true)
}

// Opens the releases page for a build that cannot replace itself.
@(private = "file")
thor_open_release_page :: proc(thor: ^Thor) {
    if !thor_open_in_browser(update.RELEASES_URL) {
        thor_flash_status(thor, "Could not open the releases page", true)
    }
}

// Points the titlebar button at the found version and sizes it to its label.
// No-op before the titlebar is built.
thor_sync_update_button :: proc(thor: ^Thor) {
    button := thor.update_button
    if button == nil {
        return
    }
    button.visible = thor.update_state == .Found || thor.update_state == .Installing
    if !button.visible {
        return
    }
    button.text = thor.update_version
    button.icon = thor.update_state == .Installing ? "loader-2" : "download"
    label_width := cast(f32) ui.measure_text(button.text, button.font_size)
    button.min_size.x = clamp(
        label_width + UPDATE_BUTTON_PAD_X * 2 + UPDATE_BUTTON_ICON_SIZE + 8,
        UPDATE_BUTTON_MIN_WIDTH,
        UPDATE_BUTTON_MAX_WIDTH,
    )
}

// Reads what a previous run remembered. A missing file is the first run and is
// not worth a warning; a malformed one is read as nothing, so the throttle
// restarts rather than the updater going quiet.
@(private = "file")
thor_read_update_record :: proc() -> (record: Update_Record) {
    data, err := os.read_entire_file(UPDATE_FILE, context.temp_allocator)
    if err != nil {
        return
    }
    if uerr := json.unmarshal(data, &record, allocator = context.temp_allocator); uerr != nil {
        log.warnf("Could not read %q: %v", UPDATE_FILE, uerr)
        return {}
    }
    return record
}

@(private = "file")
thor_write_update_record :: proc(last_check: i64, skipped_version: string) {
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }
    record := Update_Record{last_check, skipped_version}
    data, err := json.marshal(record, {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal the update record: %v", err)
        return
    }
    if werr := os.write_entire_file(UPDATE_FILE, data); werr != nil {
        log.errorf("Could not write %q: %v", UPDATE_FILE, werr)
    }
}
