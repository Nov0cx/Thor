package thor

// Updates of plugins and themes. An item updates from a GitHub release when its
// manifest or theme file names `source` and `version`, or from its upstream when
// it is a git clone. A held item is never updated, and a held bundled item keeps
// its local copy through an app update (thor_swap_and_relaunch).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

import "../atomicfile"
import "../lockfree"
import "../luaconf"
import "../plugin"
import "../setting"
import "../update"

// The held items, by hold key.
@(private = "file")
HOLDS_FILE :: "sessions/update-holds.json"

// The settings category of the update rows.
EXT_SETTINGS_CATEGORY :: "extensions"

@(private = "file")
EXT_ROW_PREFIX :: "ext:"

EXT_CHECK_NOW_ROW :: "ext_check_now"

@(private = "file")
EXT_UPDATE_NOW :: "Update Now"

@(private = "file")
EXT_HOLD :: "Hold Updates"

@(private = "file")
EXT_RELEASE_HOLD :: "Release Hold"

@(private = "file")
EXT_OPEN_SOURCE :: "Open Source Page"

Ext_Item_Kind :: enum {
    Plugin,
    Theme,
}

// One plugin or theme the update rows list.
Ext_Update :: struct {
    kind:      Ext_Item_Kind,
    name:      string, // owned; plugin id or theme file base
    path:      string, // owned; live path with '/' separators, the hold key
    bundled:   bool,   // shipped with Thor, so an app update replaces it unless held
    workspace: bool,
    updatable: bool, // a release source or a git upstream is known
    target:    update.Ext_Kind,
    repo:      string, // owned; Git: the clone
    version:   string, // owned; Release: the local version
    source:    string, // owned; Release: owner/repo
    held:      bool,
    checked:   bool,
    status:    update.Status,
    latest:    string, // owned
    tag:       string, // owned
    behind:    int,
    dirty:     bool,
}

Ext_Job_Kind :: enum {
    Check,
    Install,
}

// One item of a job. Every string is owned by the job.
Ext_Job_Item :: struct {
    target: update.Ext_Target,
    result: update.Ext_Result,
    status: update.Status, // Install: what the install answered
}

// Async plugin and theme update work, the Update_Job pattern.
Ext_Job :: struct {
    queue_next: ^Ext_Job, // link in Thor.finished_ext_updates
    owner:      ^Thor,
    allocator:  runtime.Allocator,
    worker:     ^thread.Thread,
    kind:       Ext_Job_Kind,
    manual:     bool,
    cancel:     bool,
    items:      []Ext_Job_Item, // owned
}

@(private = "file")
Holds_Record :: struct {
    held: []string,
}

// A path as a hold key: forward slashes, no leading "./".
thor_ext_key :: proc(path: string, allocator := context.temp_allocator) -> string {
    key, _ := strings.replace_all(path, "\\", "/", allocator)
    return strings.trim_prefix(key, "./")
}

// The held keys, in the temp allocator. A missing file holds nothing.
thor_ext_read_holds :: proc() -> []string {
    data, err := os.read_entire_file(HOLDS_FILE, context.temp_allocator)
    if err != nil {
        return nil
    }
    record: Holds_Record
    if uerr := json.unmarshal(data, &record, allocator = context.temp_allocator); uerr != nil {
        log.warnf("Could not read %q: %v", HOLDS_FILE, uerr)
        return nil
    }
    return record.held
}

@(private = "file")
thor_ext_write_holds :: proc(held: []string) -> bool {
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return false
        }
    }
    data, err := json.marshal(Holds_Record{held}, {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal the update holds: %v", err)
        return false
    }
    if werr := atomicfile.write(HOLDS_FILE, data); werr != nil {
        log.errorf("Could not write %q: %v", HOLDS_FILE, werr)
        return false
    }
    return true
}

// The held keys an app update must carry: the bundled plugins and shipped
// themes, which are the ones beside the binary.
thor_ext_held_bundled :: proc() -> []string {
    out := make([dynamic]string, context.temp_allocator)
    for key in thor_ext_read_holds() {
        if (strings.has_prefix(key, "plugins/") || strings.has_prefix(key, SHIPPED_THEME_DIR + "/")) && !strings.contains(key, "..") {
            append(&out, key)
        }
    }
    return out[:]
}

@(private = "file")
thor_ext_free_item :: proc(item: ^Ext_Update) {
    delete(item.name)
    delete(item.path)
    delete(item.repo)
    delete(item.version)
    delete(item.source)
    delete(item.latest)
    delete(item.tag)
    item^ = {}
}

// Frees the item list. Called from thor_clear_update.
thor_ext_clear :: proc(thor: ^Thor) {
    for &item in thor.ext_updates {
        thor_ext_free_item(&item)
    }
    delete(thor.ext_updates)
    thor.ext_updates = nil
    delete(thor.ext_setting_target)
    thor.ext_setting_target = ""
}

// The `version` and `source` a theme file sets, in the temp allocator.
@(private = "file")
thor_theme_info :: proc(path: string) -> (version, source: string) {
    parsed, status, _ := luaconf.eval_file(path)
    root, is_object   := parsed.(json.Object)
    if status != .Ok || !is_object {
        return "", ""
    }
    if v, ok := root["version"].(json.String); ok {
        version = v
    }
    if s, ok := root["source"].(json.String); ok {
        source = s
    }
    return version, source
}

// Whether `dir` is the root of a git clone.
@(private = "file")
thor_is_clone :: proc(dir: string) -> bool {
    dot, err := filepath.join({dir, ".git"}, context.temp_allocator)
    return err == nil && os.exists(dot)
}

// Adds one item to `list`. A non-bundled item without a source is left out:
// there is nothing to update it from and nothing an app update replaces.
@(private = "file")
thor_ext_add :: proc(
    list: ^[dynamic]Ext_Update,
    kind: Ext_Item_Kind,
    name, path: string,
    bundled, workspace: bool,
    version, source, repo: string,
    held: []string,
) {
    item := Ext_Update{kind = kind, bundled = bundled, workspace = workspace}
    switch {
    case repo != "":
        item.updatable = true
        item.target = .Git
    case version != "" && source != "":
        item.updatable = true
        item.target = .Release
    }
    if !item.updatable && !bundled {
        return
    }
    key := thor_ext_key(path)
    item.name = strings.clone(name)
    item.path = strings.clone(key)
    item.repo = strings.clone(repo)
    item.version = strings.clone(version)
    item.source = strings.clone(source)
    item.held = slice.contains(held, key)
    append(list, item)
}

// Rebuilds the item list from disk. Check results carry over by path.
thor_ext_scan :: proc(thor: ^Thor) {
    held := thor_ext_read_holds()
    list := make([dynamic]Ext_Update)

    for p in plugin.manager_scan(&thor.plugins) {
        version, source := plugin.manifest_info(p.dir)
        repo            := thor_is_clone(p.dir) ? p.dir : ""
        thor_ext_add(&list, .Plugin, p.id, p.dir, true, false, version, source, repo, held)
    }
    for p in thor_scan_workspace_plugins(thor) {
        version, source := plugin.manifest_info(p.dir)
        repo            := thor_is_clone(p.dir) ? p.dir : ""
        thor_ext_add(&list, .Plugin, p.id, p.dir, false, true, version, source, repo, held)
    }
    user_repo := thor_is_clone(USER_THEME_DIR) ? USER_THEME_DIR : ""
    for dir in ([]string{USER_THEME_DIR, SHIPPED_THEME_DIR}) {
        pattern      := strings.concatenate({dir, "/*", THEME_EXT}, context.temp_allocator)
        matches, err := filepath.glob(pattern, context.temp_allocator)
        if err != nil {
            continue
        }
        bundled := dir == SHIPPED_THEME_DIR
        for path in matches {
            name            := strings.trim_suffix(filepath.base(path), THEME_EXT)
            version, source := thor_theme_info(path)
            thor_ext_add(&list, .Theme, name, path, bundled, false, version, source, bundled ? "" : user_repo, held)
        }
    }

    for &item in list {
        for &old in thor.ext_updates {
            if old.path != item.path || !old.checked || old.version != item.version {
                continue
            }
            item.checked = true
            item.status = old.status
            item.latest = strings.clone(old.latest)
            item.tag = strings.clone(old.tag)
            item.behind = old.behind
            item.dirty = old.dirty
            break
        }
    }
    for &old in thor.ext_updates {
        thor_ext_free_item(&old)
    }
    delete(thor.ext_updates)
    thor.ext_updates = list
}

// Whether an item has an update the user can take.
thor_ext_pending :: proc(item: Ext_Update) -> bool {
    return item.updatable && item.checked && !item.held && item.status == .Ok
}

// How many items have an update waiting.
thor_ext_pending_count :: proc(thor: ^Thor) -> int {
    n := 0
    for item in thor.ext_updates {
        if thor_ext_pending(item) {
            n += 1
        }
    }
    return n
}

// Whether the theme `name` has an update waiting.
thor_ext_theme_pending :: proc(thor: ^Thor, name: string) -> bool {
    for item in thor.ext_updates {
        if item.kind == .Theme && item.name == name && thor_ext_pending(item) {
            return true
        }
    }
    return false
}

@(private = "file")
thor_ext_job_target :: proc(item: Ext_Update) -> update.Ext_Target {
    return {
        kind = item.target,
        path = strings.clone(item.path),
        repo = strings.clone(item.repo),
        version = strings.clone(item.version),
        source = strings.clone(item.source),
    }
}

@(private = "file")
thor_ext_start :: proc(thor: ^Thor, kind: Ext_Job_Kind, manual: bool, items: []Ext_Job_Item) {
    job := new(Ext_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.kind = kind
    job.manual = manual
    job.items = items
    thor.ext_inflight = true
    thor.ext_job = job
    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, ext_worker)
}

// Starts a check of every updatable item that is not held.
thor_check_ext_updates :: proc(thor: ^Thor, manual: bool) {
    if thor.ext_inflight {
        if manual {
            thor_flash_status(thor, "Already checking plugins and themes")
        }
        return
    }
    thor_ext_scan(thor)
    items := make([dynamic]Ext_Job_Item)
    for item in thor.ext_updates {
        if item.updatable && !item.held {
            append(&items, Ext_Job_Item{target = thor_ext_job_target(item)})
        }
    }
    if len(items) == 0 {
        delete(items)
        if manual {
            thor_flash_status(thor, "No plugin or theme names an update source")
        }
        return
    }
    thor_ext_start(thor, .Check, manual, items[:])
    if manual {
        thor_flash_status(thor, "Checking plugins and themes for updates...")
    }
}

// Starts the install of the update the last check found for `path`.
@(private = "file")
thor_install_ext_update :: proc(thor: ^Thor, path: string) {
    if thor.ext_inflight {
        thor_flash_status(thor, "A plugin or theme update is already running")
        return
    }
    for item in thor.ext_updates {
        if item.path != path || !thor_ext_pending(item) {
            continue
        }
        if item.dirty {
            thor_flash_status(thor, fmt.tprintf("%s has local changes; commit or stash them first", item.name), true)
            return
        }
        items := make([]Ext_Job_Item, 1)
        items[0].target = thor_ext_job_target(item)
        items[0].result = {status = item.status, latest = strings.clone(item.latest), tag = strings.clone(item.tag), behind = item.behind, dirty = item.dirty}
        thor_ext_start(thor, .Install, true, items)
        thor_flash_status(thor, fmt.tprintf("Updating %s...", item.name))
        return
    }
}

@(private = "file")
ext_worker :: proc(job: ^Ext_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    agent := update.user_agent(VERSION, context.temp_allocator)
    for &item in job.items {
        if sync.atomic_load(&job.cancel) {
            item.result.status = .Cancelled
            item.status = .Cancelled
            continue
        }
        switch job.kind {
        case .Check:
            item.result = update.ext_check(item.target, agent, &job.cancel, job.allocator)
        case .Install:
            item.status = update.ext_install(item.target, item.result, agent, &job.cancel)
        }
    }
    lockfree.stack_push(&job.owner.finished_ext_updates, job)
}

// Applies a finished job (called from thor_process_io).
thor_apply_ext_job :: proc(thor: ^Thor, job: ^Ext_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)

    switch job.kind {
    case .Check:
        thor_apply_ext_check(thor, job)
    case .Install:
        thor_apply_ext_install(thor, job)
    }

    for &item in job.items {
        delete(item.target.path)
        delete(item.target.repo)
        delete(item.target.version)
        delete(item.target.source)
        update.ext_result_destroy(&item.result)
    }
    delete(job.items)
    if thor.ext_job == job {
        thor.ext_job = nil
    }
    free(job)
    thor.ext_inflight = false
    thor.inflight_jobs -= 1
    if thor.settings_open {
        thor_populate_settings_view(thor)
    }
}

@(private = "file")
thor_apply_ext_check :: proc(thor: ^Thor, job: ^Ext_Job) {
    reached := false
    for job_item in job.items {
        if job_item.result.status != .No_Network && job_item.result.status != .Rate_Limited && job_item.result.status != .Cancelled {
            reached = true
        }
        for &item in thor.ext_updates {
            if item.path != job_item.target.path {
                continue
            }
            delete(item.latest)
            delete(item.tag)
            item.checked = true
            item.status = job_item.result.status
            item.latest = strings.clone(job_item.result.latest)
            item.tag = strings.clone(job_item.result.tag)
            item.behind = job_item.result.behind
            item.dirty = job_item.result.dirty
            if item.status != .Ok && item.status != .Up_To_Date {
                log.debugf("Update check of %q stopped: %v", item.path, item.status)
            }
            break
        }
    }
    // A transient failure must not eat the day's slot.
    if reached {
        thor_record_ext_check()
    }
    pending := thor_ext_pending_count(thor)
    switch {
    case pending > 0:
        thor_flash_status(thor, fmt.tprintf("%d plugin or theme %s available", pending, pending == 1 ? "update" : "updates"))
    case job.manual:
        thor_flash_status(thor, "Plugins and themes are up to date")
    }
}

@(private = "file")
thor_apply_ext_install :: proc(thor: ^Thor, job: ^Ext_Job) {
    for job_item in job.items {
        name := filepath.base(job_item.target.path)
        if job_item.status != .Ok {
            if job_item.status != .Cancelled {
                thor_flash_status(thor, fmt.tprintf("%s: %s", name, update.status_message(job_item.status)), true)
            }
            continue
        }
        kind := Ext_Item_Kind.Plugin
        for &item in thor.ext_updates {
            if item.path == job_item.target.path {
                kind = item.kind
                name = item.name
                item.status = .Up_To_Date
                item.behind = 0
                break
            }
        }
        switch kind {
        case .Plugin:
            thor.plugin_reload_pending = true
        case .Theme:
            active := setting.theme_name(&thor.config)
            if active == "" {
                active = DEFAULT_THEME
            }
            if active == name {
                thor_load_theme_by_name(thor, name)
                thor_apply_theme(thor)
            }
        }
        thor_flash_status(thor, fmt.tprintf("Updated %s", name))
    }
    thor_ext_scan(thor)
}

// Asks an in-flight job to stop. Called at shutdown.
thor_cancel_ext_update :: proc(thor: ^Thor) {
    if thor.ext_job != nil {
        sync.atomic_store(&thor.ext_job.cancel, true)
    }
}

// Holds or releases one item.
@(private = "file")
thor_ext_set_held :: proc(thor: ^Thor, path: string, hold: bool) {
    held := make([dynamic]string, context.temp_allocator)
    for key in thor_ext_read_holds() {
        if key != path {
            append(&held, key)
        }
    }
    if hold {
        append(&held, path)
    }
    if !thor_ext_write_holds(held[:]) {
        thor_flash_status(thor, "Could not save the update hold", true)
        return
    }
    for &item in thor.ext_updates {
        if item.path == path {
            item.held = hold
        }
    }
    thor_flash_status(thor, hold ? "Updates held" : "Hold released")
}

// The Help menu and palette entry. An explicit request beats the throttle and
// the check_for_plugin_updates setting.
thor_cmd_check_for_plugin_updates :: proc(data: rawptr) {
    thor_check_ext_updates(cast(^Thor)data, manual = true)
}

// The titlebar badge: opens the update rows.
thor_click_ext_updates :: proc(data: rawptr) {
    thor_open_settings_view(cast(^Thor)data, EXT_SETTINGS_CATEGORY)
}

// What an item's row reads.
@(private = "file")
thor_ext_value_label :: proc(thor: ^Thor, item: Ext_Update) -> string {
    if item.held {
        return "Held"
    }
    if !item.updatable {
        return "Updates with Thor"
    }
    if thor.ext_inflight && thor.ext_job != nil && thor.ext_job.kind == .Install && thor.ext_job.items[0].target.path == item.path {
        return "Updating..."
    }
    if !item.checked {
        return "Not checked"
    }
    #partial switch item.status {
    case .Ok:
        label := item.target == .Git ? fmt.tprintf("%d commits behind", item.behind) : fmt.tprintf("%s available", item.latest)
        if item.dirty {
            return fmt.tprintf("%s, local changes", label)
        }
        return label
    case .Up_To_Date:
        return "Up to date"
    }
    return update.status_message(item.status)
}

@(private = "file")
thor_ext_row_label :: proc(item: Ext_Update) -> string {
    switch {
    case item.workspace:
        return fmt.tprintf("%s — %s", item.name, WORKSPACE_PLUGIN_DIR)
    case item.kind == .Theme && !item.bundled:
        return fmt.tprintf("%s — user theme", item.name)
    }
    return item.name
}

// The update rows of the Settings view.
thor_populate_ext_category :: proc(thor: ^Thor, config: ^setting.Settings) {
    view := &thor.settings
    if !thor.ext_inflight {
        thor_ext_scan(thor)
    }
    thor_settings_begin_category(view, EXT_SETTINGS_CATEGORY, "Plugin & Theme Updates", "refresh")
    thor_settings_add_choice(view, "check_for_plugin_updates", "Check Automatically", thor_on_off_label(setting.check_for_plugin_updates(config)))
    pending   := thor_ext_pending_count(thor)
    now_label := thor.ext_inflight ? "Checking..." : pending > 0 ? fmt.tprintf("Check Now (%d available)", pending) : "Check Now"
    thor_settings_add_action(view, EXT_CHECK_NOW_ROW, now_label, "Check")

    for item in thor.ext_updates {
        if item.updatable {
            thor_settings_add_choice(
                view,
                strings.concatenate({EXT_ROW_PREFIX, item.path}, context.temp_allocator),
                thor_ext_row_label(item),
                thor_ext_value_label(thor, item),
            )
        }
    }
    groups := [?]struct {
        id, label: string,
        kind:      Ext_Item_Kind,
    }{{"ext_bundled_plugins", "Bundled Plugins", .Plugin}, {"ext_shipped_themes", "Shipped Themes", .Theme}}
    for group in groups {
        thor_settings_begin_group(view, group.id, group.label, collapsed = true)
        for item in thor.ext_updates {
            if item.bundled && !item.updatable && item.kind == group.kind {
                thor_settings_add_choice(
                    view,
                    strings.concatenate({EXT_ROW_PREFIX, item.path}, context.temp_allocator),
                    thor_ext_row_label(item),
                    thor_ext_value_label(thor, item),
                )
            }
        }
        thor_settings_end_group(view)
    }
}

// Handles a click on an update row. False when `id` is not one.
thor_ext_on_setting_choice :: proc(thor: ^Thor, id: string) -> bool {
    if id == "check_for_plugin_updates" {
        thor_select_open(
            thor,
            "Check Plugins and Themes Automatically",
            ON_OFF_LABELS[:],
            thor_on_off_label(setting.check_for_plugin_updates(&thor.config)),
            thor_no_preview,
            thor_ext_auto_commit,
            thor,
        )
        return true
    }
    if !strings.has_prefix(id, EXT_ROW_PREFIX) {
        return false
    }
    path := id[len(EXT_ROW_PREFIX):]
    for item in thor.ext_updates {
        if item.path != path {
            continue
        }
        options := make([dynamic]string, context.temp_allocator)
        if thor_ext_pending(item) && !item.dirty {
            append(&options, EXT_UPDATE_NOW)
        }
        append(&options, item.held ? EXT_RELEASE_HOLD : EXT_HOLD)
        if item.target == .Release && item.updatable && update.source_valid(item.source) {
            append(&options, EXT_OPEN_SOURCE)
        }
        delete(thor.ext_setting_target)
        thor.ext_setting_target = strings.clone(path)
        thor_select_open(thor, item.name, options[:], options[0], thor_no_preview, thor_ext_row_commit, thor)
        return true
    }
    return true
}

@(private = "file")
thor_ext_auto_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor)data
    if err := setting.persist_bool(thor_active_settings_path(thor), "check_for_plugin_updates", choice == ON_OFF_LABELS[0]); err != .None {
        thor_settings_save_failed(thor, thor_active_settings_path(thor), err)
        return
    }
    thor_reload_settings(thor)
}

@(private = "file")
thor_ext_row_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor)data
    path := thor.ext_setting_target
    switch choice {
    case EXT_UPDATE_NOW:
        thor_install_ext_update(thor, path)
    case EXT_HOLD:
        thor_ext_set_held(thor, path, true)
    case EXT_RELEASE_HOLD:
        thor_ext_set_held(thor, path, false)
    case EXT_OPEN_SOURCE:
        for item in thor.ext_updates {
            if item.path == path && update.source_valid(item.source) {
                if !thor_open_in_browser(fmt.tprintf("https://github.com/%s", item.source)) {
                    thor_flash_status(thor, "Could not open the source page", true)
                }
                break
            }
        }
    }
    if thor.settings_open {
        thor_populate_settings_view(thor)
    }
}
