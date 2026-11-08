package thor

import "base:runtime"

import ui "../vendor/loom/loom"

// Loom builds and frees its process-global state with the first and last
// context, without a lock. Tests that run in parallel race on it, so one
// context lives for the whole test process.
@(private = "file")
loom_anchor: ui.Context

@(init)
loom_anchor_init :: proc "contextless" () {
    context = runtime.default_context()
    ui.init(&loom_anchor, ui.Config{backend = ui.noop_backend()})
}
