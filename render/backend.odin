// The Loom backend: it answers Loom's five text and platform callbacks from the
// font package, and turns a frame's draw list into raylib calls. It owns no
// window — the application makes the window and drives the loop.
package render


import "../font"
import "../platform"
import ui "../vendor/loom/loom"

DEFAULT_ARC_SEGMENTS :: 6
MAX_SHADOW_STEPS     :: 12

Options :: struct {
    arc_segments: int,
    dpi:          f32,
    right_alt:    Right_Alt,
}

// A key raylib reports as held. The physical key is what raylib answers about;
// the mapped one is what the user's layout prints on the cap.
Held_Key :: struct {
    physical: platform.Scancode,
    mapped:   ui.Key,
}

// A family name and the synthetic style one font handle draws it in.
Family_Handle :: struct {
    name:  string, // borrowed
    style: font.Style,
}

Backend :: struct {
    opts:      Options,
    families:  [dynamic]Family_Handle, // the font package owns the names
    textures:  map[u32]platform.Texture,
    clip:      [dynamic]ui.Rect,
    path_a:    [dynamic]ui.Vec2,
    path_b:    [dynamic]ui.Vec2,
    held:      [dynamic]Held_Key,
    key_evs:   [dynamic]ui.Key_Event,
    text_buf:  [64]byte,
    text_len:  int,
    dpi:       f32,
    cursor:    ui.Cursor,
    // When poll_input last ran; 0 before the first call.
    last_poll: f64,
}

init :: proc(b: ^Backend, opts: Options = {}) -> ui.Backend {
    b^ = {}
    b.opts = opts
    if b.opts.arc_segments <= 0 {
        b.opts.arc_segments = DEFAULT_ARC_SEGMENTS
    }

    b.families = make([dynamic]Family_Handle, 0, 4)
    b.textures = make(map[u32]platform.Texture, 8)
    b.clip = make([dynamic]ui.Rect, 0, 16)
    b.path_a = make([dynamic]ui.Vec2, 0, 64)
    b.path_b = make([dynamic]ui.Vec2, 0, 64)
    b.held = make([dynamic]Held_Key, 0, 8)
    b.key_evs = make([dynamic]ui.Key_Event, 0, 32)

    b.dpi = opts.dpi > 0 ? opts.dpi : 1

    return ui.Backend{
        measure_run = measure_run,
        font_metrics = font_metrics,
        offset_x = offset_x,
        index_at = index_at,
        set_cursor = set_cursor,
        clipboard_get = clipboard_get,
        clipboard_set = clipboard_set,
        user = b,
        // One window per process, so a dock panel never detaches.
        viewports = nil,
    }
}

destroy :: proc(b: ^Backend) {
    delete(b.families)
    delete(b.textures)
    delete(b.clip)
    delete(b.path_a)
    delete(b.path_b)
    delete(b.held)
    delete(b.key_evs)
    b^ = {}
}

// Makes a texture the application already loaded addressable by a draw command.
register_texture :: proc(b: ^Backend, tex: platform.Texture) -> ui.Texture {
    b.textures[tex.id] = tex
    return ui.Texture(tex.id)
}

forget_texture :: proc(b: ^Backend, tex: platform.Texture) {
    delete_key(&b.textures, tex.id)
}
