// LaTeX: the build on an explicit save, and the tool runs behind the PDF preview
// and the SyncTeX jumps. Each tool runs on a worker as a Latex_Job; the main
// thread applies the result.
package thor

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../lockfree"
import "../platform"
import "../setting"
import "../shell"
import "../textedit"

@(private = "file")
LATEX_BUILD_TIMEOUT :: 10 * time.Minute

@(private = "file")
LATEX_TOOL_TIMEOUT :: 60 * time.Second

Latex_Job_Kind :: enum {
    Build,
    Info,
    Page,
    Sync_Edit,
    Sync_View,
}

Latex_Job :: struct {
    queue_next: ^Latex_Job, // link in Thor.finished_latex
    owner:      ^Thor,
    allocator:  mem.Allocator,
    worker:     ^thread.Thread,
    kind:       Latex_Job_Kind,
    exe:        string,          // owned; empty runs `command` through the shell
    command:    string,          // owned
    args:       [dynamic]string, // owned, with each string
    cwd:        string,          // owned
    pdf:        string,          // owned; the PDF the job builds or reads
    out_png:    string,          // owned; .Page only
    page:       int,             // .Page: 0-based
    dpi:        f32,             // .Page
    generation: u64,             // .Info and .Page: the Pdf_View generation that asked
    cancel:     bool,            // atomic
    output:     string,          // owned
    code:       int,
    ok:         bool,
    decoded:    platform.Image, // .Page: owned until applied
}

Latex_State :: struct {
    preview:  bool, // the PDF pane shows beside a LaTeX source
    view:     Pdf_View,
    jobs:     [dynamic]^Latex_Job, // borrowed; every job in flight
    building: bool,
    rebuild:  string, // owned; the root to build again when the running build lands
}

// The absolute path of a tool on PATH, in the temp allocator.
thor_latex_tool :: proc(name: string) -> (path: string, ok: bool) {
    if path, ok = shell.which(name, context.temp_allocator); ok {
        return
    }
    when ODIN_OS == .Windows {
        return shell.which(strings.concatenate({name, ".exe"}, context.temp_allocator), context.temp_allocator)
    }
    return "", false
}

// A job of `kind` in `cwd`, not started yet.
thor_latex_job :: proc(thor: ^Thor, kind: Latex_Job_Kind, cwd: string) -> ^Latex_Job {
    job := new(Latex_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.kind = kind
    job.cwd = strings.clone(cwd)
    job.args = make([dynamic]string)
    return job
}

thor_latex_arg :: proc(job: ^Latex_Job, args: ..string) {
    for arg in args {
        append(&job.args, strings.clone(arg))
    }
}

thor_latex_run :: proc(thor: ^Thor, job: ^Latex_Job) {
    append(&thor.latex.jobs, job)
    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, latex_worker)
}

@(private = "file")
latex_worker :: proc(job: ^Latex_Job) {
    context.allocator = job.allocator
    defer {
        free_all(context.temp_allocator)
        lockfree.stack_push(&job.owner.finished_latex, job)
    }

    timeout := job.kind == .Build ? LATEX_BUILD_TIMEOUT : LATEX_TOOL_TIMEOUT
    if job.exe == "" {
        job.output, job.code, job.ok = shell.run_status(job.command, job.cwd, timeout, &job.cancel)
    } else {
        job.output, job.code, job.ok = shell.exec_status(job.exe, job.args[:], job.cwd, timeout, &job.cancel)
    }
    if job.kind != .Page {
        return
    }
    defer if job.out_png != "" {
        _ = os.remove(job.out_png)
    }
    if !job.ok || job.code != 0 {
        job.ok = false
        return
    }
    data, err := os.read_entire_file(job.out_png, context.allocator)
    if err != nil || len(data) == 0 {
        job.ok = false
        return
    }
    defer delete(data)
    job.decoded, job.ok = platform.image_decode(".png", data)
}

@(private = "file")
thor_latex_job_free :: proc(job: ^Latex_Job) {
    delete(job.exe)
    delete(job.command)
    for arg in job.args {
        delete(arg)
    }
    delete(job.args)
    delete(job.cwd)
    delete(job.pdf)
    delete(job.out_png)
    delete(job.output)
    platform.image_free(&job.decoded)
    free(job)
}

// Applies every finished job. Called from thor_process_io, so the drain at shutdown reaps them too.
thor_reap_latex :: proc(thor: ^Thor) {
    next: ^Latex_Job
    for job := lockfree.stack_take(&thor.finished_latex); job != nil; job = next {
        next = job.queue_next
        thread.join(job.worker)
        thread.destroy(job.worker)
        thor.inflight_jobs -= 1
        for j, i in thor.latex.jobs {
            if j == job {
                unordered_remove(&thor.latex.jobs, i)
                break
            }
        }
        if !sync.atomic_load(&job.cancel) {
            switch job.kind {
            case .Build:
                thor_latex_apply_build(thor, job)
            case .Info, .Page:
                thor_pdf_apply_job(thor, &thor.latex.view, job)
            case .Sync_Edit:
                thor_latex_apply_sync_edit(thor, job)
            case .Sync_View:
                thor_pdf_apply_sync_view(thor, &thor.latex.view, job)
            }
        } else if job.kind == .Build {
            thor.latex.building = false
        }
        thor_latex_job_free(job)
    }
}

// Stops every tool in flight, so the drain at shutdown does not wait for a build.
thor_latex_cancel_all :: proc(thor: ^Thor) {
    for job in thor.latex.jobs {
        sync.atomic_store(&job.cancel, true)
    }
}

thor_latex_destroy :: proc(thor: ^Thor) {
    delete(thor.latex.jobs)
    delete(thor.latex.rebuild)
    thor.latex.rebuild = ""
    thor_pdf_view_destroy(thor, &thor.latex.view)
}

// The root document of a LaTeX buffer: the file a `% !TEX root` comment names, else the file itself.
thor_latex_root :: proc(file: ^Open_File) -> string {
    if magic, ok := latex_magic_root(textedit.text(&file.state)); ok {
        joined, err := filepath.join({filepath.dir(file.path), magic}, context.temp_allocator)
        if err == nil {
            return thor_abs_path(joined)
        }
    }
    return file.path
}

// Whether an explicit save of `file` builds it.
thor_latex_builds_on_save :: proc(thor: ^Thor, file: ^Open_File) -> bool {
    return setting.latex_build_on_save(&thor.config) && latex_is_source(file.path)
}

// Builds the root document of `file`.
thor_latex_build_file :: proc(thor: ^Thor, file: ^Open_File) {
    thor_latex_build(thor, thor_latex_root(file))
}

// Builds `root` with the latex_build_command setting, else latexmk, else
// tectonic. A build asked for while one runs waits for it, and only the newest waits.
thor_latex_build :: proc(thor: ^Thor, root: string) {
    l := &thor.latex
    if l.building {
        delete(l.rebuild)
        l.rebuild = strings.clone(root)
        return
    }
    dir  := filepath.dir(root)
    base := filepath.base(root)
    job  := thor_latex_job(thor, .Build, dir)
    job.pdf = latex_pdf_path(root)
    if command := setting.latex_build_command(&thor.config); command != "" {
        expanded, _ := strings.replace_all(command, "{file}", fmt.tprintf("\"%s\"", base), context.temp_allocator)
        job.command = strings.clone(expanded)
    } else if latexmk, found := thor_latex_tool("latexmk"); found {
        job.exe = strings.clone(latexmk)
        thor_latex_arg(job, "-pdf", "-synctex=1", "-interaction=nonstopmode", "-file-line-error", base)
    } else if tectonic, ok := thor_latex_tool("tectonic"); ok {
        job.exe = strings.clone(tectonic)
        thor_latex_arg(job, "--synctex", "--keep-logs", base)
    } else {
        thor_latex_job_free(job)
        thor_flash_status(thor, "No LaTeX build tool found: install latexmk or tectonic (see docs/latex.md).", is_error = true)
        return
    }
    l.building = true
    thor_latex_run(thor, job)
    thor_flash_status(thor, fmt.tprintf("Building %s...", base))
}

@(private = "file")
thor_latex_apply_build :: proc(thor: ^Thor, job: ^Latex_Job) {
    l := &thor.latex
    l.building = false
    name := filepath.base(job.pdf)
    if job.ok && job.code == 0 {
        thor_flash_status(thor, fmt.tprintf("Built %s", name))
        thor_pdf_view_poke(&l.view, job.pdf)
    } else {
        message := latex_first_error(job.output)
        if message == "" {
            message = fmt.tprintf("The LaTeX build of %s failed (exit code %d).", name, job.code)
        }
        thor_flash_status(thor, message, is_error = true)
        thor_plugin_print(thor, fmt.tprintf("\n-- LaTeX build of %s failed --\n%s\n", name, job.output))
        log.warnf("LaTeX build in %q failed with exit code %d", job.cwd, job.code)
    }
    if l.rebuild != "" {
        root := l.rebuild
        l.rebuild = ""
        thor_latex_build(thor, root)
        delete(root)
    }
}

// The synctex tool, or a flash that says it is missing.
@(private = "file")
thor_latex_synctex :: proc(thor: ^Thor) -> (string, bool) {
    exe, ok := thor_latex_tool("synctex")
    if !ok {
        thor_flash_status(thor, "synctex was not found on PATH. It comes with TeX Live and MiKTeX (see docs/latex.md).", is_error = true)
    }
    return exe, ok
}

// Asks SyncTeX for the source line at a point of the PDF. `page` is 1-based, x and y in points.
thor_latex_inverse_search :: proc(thor: ^Thor, pdf: string, page: int, x, y: f32) {
    exe, found := thor_latex_synctex(thor)
    if !found {
        return
    }
    job := thor_latex_job(thor, .Sync_Edit, filepath.dir(pdf))
    job.exe = strings.clone(exe)
    job.pdf = strings.clone(pdf)
    thor_latex_arg(job, "edit", "-o", fmt.tprintf("%d:%.2f:%.2f:%s", page, x, y, pdf))
    thor_latex_run(thor, job)
}

@(private = "file")
thor_latex_apply_sync_edit :: proc(thor: ^Thor, job: ^Latex_Job) {
    edit, ok := synctex_parse_edit(job.output)
    if !job.ok || !ok {
        thor_flash_status(thor, "SyncTeX found no source here. Build with -synctex=1.", is_error = true)
        return
    }
    path := edit.input
    if !filepath.is_abs(path) {
        joined, err := filepath.join({job.cwd, path}, context.temp_allocator)
        if err != nil {
            return
        }
        path = joined
    }
    thor_goto_file_line_col(thor, thor_abs_path(path), edit.line, max(edit.column, 1))
}

// Shows the place in the PDF that the caret line of the active LaTeX file makes.
thor_cmd_latex_forward_search :: proc(data: rawptr) {
    thor := cast(^Thor)data
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded || !latex_is_source(file.path) {
        thor_flash_status(thor, "Forward search needs an open LaTeX file.", is_error = true)
        return
    }
    exe, found := thor_latex_synctex(thor)
    if !found {
        return
    }
    pdf := latex_pdf_path(thor_latex_root(file), context.temp_allocator)
    if !os.exists(pdf) {
        thor_flash_status(thor, fmt.tprintf("%s does not exist yet. Save to build it.", filepath.base(pdf)), is_error = true)
        return
    }
    caret  := textedit.primary_cursor(&file.state).caret
    line   := textedit.state_line_index(&file.state, caret) + 1
    column := textedit.char_column(textedit.text(&file.state), caret, textedit.tab_width(&file.state)) + 1
    thor.latex.preview = true

    job := thor_latex_job(thor, .Sync_View, filepath.dir(pdf))
    job.exe = strings.clone(exe)
    job.pdf = strings.clone(pdf)
    thor_latex_arg(job, "view", "-i", fmt.tprintf("%d:%d:%s", line, column, file.path), "-o", pdf)
    thor_latex_run(thor, job)
}

thor_cmd_latex_build :: proc(data: rawptr) {
    thor := cast(^Thor)data
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded || !latex_is_source(file.path) {
        thor_flash_status(thor, "Build needs an open LaTeX file.", is_error = true)
        return
    }
    thor_save_explicit(thor, file)
    if !thor_latex_builds_on_save(thor, file) {
        if file.saving {
            file.latex_build_pending = true
        } else {
            thor_latex_build_file(thor, file)
        }
    }
}

thor_cmd_toggle_latex_preview :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor.latex.preview = !thor.latex.preview
}
