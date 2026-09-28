// The model view: a loaded 3D model on a ground grid, orbited and zoomed with
// the mouse. The model is borrowed from the open file; the render target and the
// shading shader are owned here.
//
// The 3D pass cannot run inside the draw list — render.draw holds an unflushed
// rlgl batch and an active scissor across it — so it renders into an off-screen
// target in thor_render_model, before the list is replayed, and the tree shows
// that target as an ordinary image node.
package thor

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

import "../render"
import ui "../vendor/loom/loom"

@(private = "file")
MODEL_FOV :: f32(45)

@(private = "file")
MODEL_ZOOM_STEP :: f32(1.1)

// Zoom limits, in multiples of the model's bounding-sphere radius.
@(private = "file")
MODEL_DIST_MIN :: f32(0.05)

@(private = "file")
MODEL_DIST_MAX :: f32(40)

@(private = "file")
MODEL_ORBIT_SPEED :: f32(0.008) // radians per pixel

@(private = "file")
MODEL_PITCH_LIMIT :: f32(1.55) // just short of straight down or up, where up flips

@(private = "file")
MODEL_SPIN_SPEED :: f32(0.6) // radians per second while auto-orbiting

// Grid lines each side of centre. The step is picked so the model spans a few.
@(private = "file")
MODEL_GRID_HALF :: 12

@(private = "file")
MODEL_BUTTON_SIZE :: f32(30)

@(private = "file")
MODEL_BUTTON_MARGIN :: f32(10)

// The 3D pass renders at this multiple of the pane size and is filtered back
// down, the cheapest antialiasing available without an MSAA target.
@(private = "file")
MODEL_SUPERSAMPLE :: 2

@(private = "file")
MODEL_TARGET_MAX :: 4096

// Slack granularity for the render target: an allocation rounds up to a whole
// step, so small pane growth reuses it instead of reallocating every frame.
@(private = "file")
MODEL_TARGET_STEP :: 128

// How long an oversized target is kept before it is shrunk back down.
@(private = "file")
MODEL_TARGET_DWELL :: 0.5

// Which camera motion the held mouse drives.
Model_Drag :: enum {
    None,
    Orbit,
    Pan,
}

Model_View :: struct {
    file:           ^Open_File, // borrowed, the identity the camera belongs to
    // Framing taken from the model bounds: the orbit pivot, and the size that
    // sets the start distance, the grid step and the zoom limits.
    pivot:          rl.Vector3,
    radius:         f32,
    floor:          f32, // world Y of the model's lowest point; the grid sits here
    mesh_count:     int,
    vertex_count:   int,
    triangle_count: int,
    // Orbit around `pivot + pan` at `distance`.
    yaw:            f32,
    pitch:          f32,
    distance:       f32,
    pan:            rl.Vector3,
    drag:           Model_Drag,
    // Auto-orbit, toggled by the corner button. Paused while a drag is held so
    // the user's own orbit is not fought.
    spinning:       bool,
    // The pane rect and the crop the 3D pass renders for, both stated by the
    // view and read by thor_render_model after the tree is laid out.
    rect:           ui.Rect,
    need_w, need_h: i32,
    // Set by the frame that declared the pane, cleared by the pass it asks for;
    // `live` says the target holds a scene the view can show.
    showing:        bool,
    live:           bool,
    // Off-screen target the 3D pass renders into. Owned, grown with slack so a
    // splitter drag does not reallocate every frame.
    target:         rl.RenderTexture2D,
    // rl.GetTime() when the target first read as bigger than the pane needs, or
    // 0 while it fits. Debounces a shrink.
    shrink_since:   f64,
    // Headlight shader, loaded on the first render (it needs the GL context).
    // Without it an untextured mesh draws as a flat silhouette. Owned.
    shader:         rl.Shader,
    shader_tried:   bool,
    shader_view_dir: i32,
}

// ---- the view ----------------------------------------------------------------

// One pane of the editor column, in the slot the file's tab owns.
thor_model_view :: proc(thor: ^Thor, view: ^Model_View, file: ^Open_File, key: string) {
    thor_model_bind(view, file)

    pane := ui.begin(
        {
            key = key,
            flags = {.Clip, .Clickable, .Draggable, .Wheel},
            // Relative, so it is the containing block of the overlays: Loom
            // resolves an absolute inset against the nearest positioned
            // ancestor, which would otherwise be the window.
            props = {
                position = .Relative,
                w = ui.Grow(1),
                h = ui.Grow(1),
                bg = thor.theme.background,
                cursor = .Grab,
            },
        },
    )
    defer ui.end()

    view.rect = pane.rect
    view.showing = true
    thor_model_input(view, pane)
    thor_model_spin(thor, view)

    // The target holds the previous pass; a fresh pane has no rect yet, so the
    // first frame shows the background and the pass starts on the next.
    if view.live && view.target.id != 0 {
        tex_w := f32(view.target.texture.width)
        tex_h := f32(view.target.texture.height)
        // A render target is stored bottom-up and may be larger than the pane
        // needs: a centred crop of exactly need_w x need_h, flipped by the
        // negative height.
        u := (tex_w - f32(view.need_w)) * 0.5 / tex_w
        v := (tex_h - f32(view.need_h)) * 0.5 / tex_h
        uw := f32(view.need_w) / tex_w
        vh := f32(view.need_h) / tex_h
        ui.image(
            render.register_texture(&thor.backend, view.target.texture),
            {
                key = "scene",
                props = {position = .Absolute, inset = {}, w = ui.Grow(1), h = ui.Grow(1)},
                uv = {u, v + vh, uw, -vh},
            },
        )
    }

    thor_model_info(thor, view)
    thor_model_button(thor, view)
}

// Points the view at a model, resetting the camera so a freshly opened file
// comes up framed.
@(private = "file")
thor_model_bind :: proc(view: ^Model_View, file: ^Open_File) {
    if view.file == file {
        return
    }
    view.file = file
    view.drag = .None
    view.mesh_count = 0
    view.vertex_count = 0
    view.triangle_count = 0

    model := file.model
    for i in 0 ..< int(model.meshCount) {
        view.vertex_count += int(model.meshes[i].vertexCount)
        view.triangle_count += int(model.meshes[i].triangleCount)
    }
    view.mesh_count = int(model.meshCount)

    size := file.model_bounds.max - file.model_bounds.min
    view.pivot = (file.model_bounds.min + file.model_bounds.max) * 0.5
    view.radius = max(rl.Vector3Length(size) * 0.5, 0.0001)
    view.floor = file.model_bounds.min.y
    thor_model_reset_camera(view)
}

// Three-quarter view at a distance that fits the bounding sphere in frame.
@(private = "file")
thor_model_reset_camera :: proc(view: ^Model_View) {
    radius := view.radius > 0 ? view.radius : 1
    view.yaw = -0.7
    view.pitch = 0.4
    view.pan = {0, 0, 0}
    view.distance = radius / math.tan(math.to_radians(MODEL_FOV) * 0.5) * 1.2
}

@(private = "file")
thor_model_input :: proc(view: ^Model_View, pane: ui.Interaction) {
    if pane.wheel.y != 0 {
        // Loom counts a wheel notch down as positive.
        factor := pane.wheel.y < 0 ? 1 / MODEL_ZOOM_STEP : MODEL_ZOOM_STEP
        view.distance = clamp(
            view.distance * factor,
            view.radius * MODEL_DIST_MIN,
            view.radius * MODEL_DIST_MAX,
        )
    }

    if pane.pressed {
        // The mode is fixed when the button goes down: a drag carries no
        // modifiers of its own.
        view.drag = ui.Mod.Shift in ui.mods() ? .Pan : .Orbit
    }
    if pane.right_clicked {
        view.drag = .Pan
    }
    if !pane.dragging {
        if pane.released {
            view.drag = .None
        }
        return
    }

    #partial switch view.drag {
    case .Orbit:
        view.yaw -= pane.drag_delta.x * MODEL_ORBIT_SPEED
        view.pitch = clamp(
            view.pitch + pane.drag_delta.y * MODEL_ORBIT_SPEED,
            -MODEL_PITCH_LIMIT,
            MODEL_PITCH_LIMIT,
        )
    case .Pan:
        thor_model_pan(view, pane.drag_delta)
    }
}

// Slides the pivot in the camera plane, at the rate that keeps the point under
// the cursor moving with it.
@(private = "file")
thor_model_pan :: proc(view: ^Model_View, delta: ui.Vec2) {
    if view.rect.h <= 0 {
        return
    }
    per_pixel := 2 * view.distance * math.tan(math.to_radians(MODEL_FOV) * 0.5) / view.rect.h
    _, right, up := thor_model_basis(view)
    view.pan -= right * (delta.x * per_pixel)
    view.pan += up * (delta.y * per_pixel)
}

@(private = "file")
thor_model_spin :: proc(thor: ^Thor, view: ^Model_View) {
    if !view.spinning || view.drag != .None {
        return
    }
    // Wrapped, or a view left spinning drifts into f32 sizes where the angle
    // step stops resolving.
    view.yaw = math.mod(view.yaw - rl.GetFrameTime() * MODEL_SPIN_SPEED, math.TAU)
}

// Bottom-left overlay: file name and the mesh, vertex and triangle totals.
@(private = "file")
thor_model_info :: proc(thor: ^Thor, view: ^Model_View) {
    text := fmt.tprintf(
        "%s   %d meshes   %d verts   %d tris",
        view.file.name,
        view.mesh_count,
        view.vertex_count,
        view.triangle_count,
    )
    ui.label(
        text,
        {
            key = "model-info",
            props = {
                position = .Absolute,
                inset = {l = MODEL_BUTTON_MARGIN, b = MODEL_BUTTON_MARGIN},
                color = thor.theme.foreground,
                font_size = f32(thor.config.general.font_size),
            },
        },
    )
}

// Top-right toggle for the auto-orbit.
@(private = "file")
thor_model_button :: proc(thor: ^Thor, view: ^Model_View) {
    span := MODEL_BUTTON_SIZE + 2 * MODEL_BUTTON_MARGIN
    if view.rect.w < span || view.rect.h < span {
        return
    }
    it := ui.begin(
        {
            key = "model-spin",
            flags = {.Clickable},
            props = {
                position = .Absolute,
                inset = {r = MODEL_BUTTON_MARGIN, t = MODEL_BUTTON_MARGIN},
                w = ui.Px(MODEL_BUTTON_SIZE),
                h = ui.Px(MODEL_BUTTON_SIZE),
                justify = .Center,
                align = .Center,
                bg = view.spinning ? thor.theme.accent_color : thor.theme.highlight,
                cursor = .Pointer,
            },
        },
    )
    thor_icon_label(thor, "3d-rotate", thor.theme.foreground, 18)
    ui.end()
    if it.clicked {
        view.spinning = !view.spinning
    }
    thor_tip(thor, it.id, "Spin the model")
}

// ---- the 3D pass -------------------------------------------------------------

// Renders each shown scene into its own target. Called once a frame from
// Thor.run, after the tree is laid out and before the draw list is replayed.
thor_render_models :: proc(thor: ^Thor) {
    for &view in thor.model_view {
        thor_render_model(thor, &view)
    }
}

@(private = "file")
thor_render_model :: proc(thor: ^Thor, view: ^Model_View) {
    view.live = false
    // The view states its rect only on a frame that declared it, so a stale
    // rect from a file that is no longer shown never starts a pass.
    if !view.showing {
        return
    }
    view.showing = false
    file := view.file
    if file == nil || !file.model_loaded {
        return
    }
    need_w, need_h, ok := thor_model_ensure_target(thor, view)
    if !ok {
        return
    }
    thor_model_load_shader(view)

    camera := thor_model_camera(view, view.target.texture.height, need_h)
    rl.BeginTextureMode(view.target)
    rl.ClearBackground(render.raylib_color(thor.theme.background))
    rl.BeginMode3D(camera)
    thor_model_draw_grid(thor, view)
    thor_model_draw_model(view, camera)
    rl.EndMode3D()
    rl.EndTextureMode()

    view.need_w, view.need_h = need_w, need_h
    view.live = true
}

// Unit vector from the orbit target to the camera, for the current angles.
@(private = "file")
thor_model_offset :: proc(view: ^Model_View) -> rl.Vector3 {
    return {
        math.cos(view.pitch) * math.sin(view.yaw),
        math.sin(view.pitch),
        math.cos(view.pitch) * math.cos(view.yaw),
    }
}

// Camera axes for the current orbit angles: where it looks, and the screen
// right and up directions in world space.
@(private = "file")
thor_model_basis :: proc(view: ^Model_View) -> (forward, right, up: rl.Vector3) {
    forward = rl.Vector3Normalize(-thor_model_offset(view))
    right = rl.Vector3Normalize(rl.Vector3CrossProduct(forward, {0, 1, 0}))
    up = rl.Vector3CrossProduct(right, forward)
    return
}

// The vertical FOV that keeps a need_h-tall centred crop of a target_h-tall
// render spanning exactly MODEL_FOV: unchanged when the target matches what is
// needed this frame, widened by the size ratio otherwise, so an oversized
// target frames the model identically to an exactly-sized one.
@(private)
thor_model_fovy :: proc(target_h, need_h: i32) -> f32 {
    if target_h == need_h || need_h <= 0 {
        return MODEL_FOV
    }
    ratio := f32(target_h) / f32(need_h)
    return 2 * math.to_degrees(math.atan(math.tan(math.to_radians(MODEL_FOV) * 0.5) * ratio))
}

@(private = "file")
thor_model_camera :: proc(view: ^Model_View, target_h, need_h: i32) -> rl.Camera3D {
    target := view.pivot + view.pan
    return rl.Camera3D {
        position = target + thor_model_offset(view) * view.distance,
        target = target,
        up = {0, 1, 0},
        fovy = thor_model_fovy(target_h, need_h),
        projection = .PERSPECTIVE,
    }
}

// Rounds need up to a whole MODEL_TARGET_STEP, clamped to MODEL_TARGET_MAX, so
// a target allocated with slack absorbs small further growth without another
// reallocation. Below one step, need passes through unchanged, which is what
// keeps the result under 2x need in every case.
@(private)
thor_model_target_size :: proc(need: i32) -> i32 {
    if need <= MODEL_TARGET_STEP {
        return need
    }
    steps := (need + MODEL_TARGET_STEP - 1) / MODEL_TARGET_STEP
    return min(steps * MODEL_TARGET_STEP, i32(MODEL_TARGET_MAX))
}

// Keeps the render target at least as big as the pane needs, at the
// supersampled resolution. Returns the exact size the pane needs this frame:
// the view crops the possibly larger target to that, and the camera's fovy
// compensates so the crop still spans MODEL_FOV.
@(private = "file")
thor_model_ensure_target :: proc(thor: ^Thor, view: ^Model_View) -> (need_w, need_h: i32, ok: bool) {
    if view.rect.w < 1 || view.rect.h < 1 {
        return 0, 0, false
    }
    // Both axes take the same scale, or the target's aspect ratio stops matching
    // the pane's and the projection stretches the model.
    scale := f32(MODEL_SUPERSAMPLE)
    scale = min(scale, MODEL_TARGET_MAX / view.rect.w)
    scale = min(scale, MODEL_TARGET_MAX / view.rect.h)
    need_w = max(i32(view.rect.w * scale), 1)
    need_h = max(i32(view.rect.h * scale), 1)
    want_w := thor_model_target_size(need_w)
    want_h := thor_model_target_size(need_h)

    fits :=
        view.target.id != 0 &&
        view.target.texture.width >= need_w &&
        view.target.texture.height >= need_h
    oversized :=
        fits && (view.target.texture.width > want_w || view.target.texture.height > want_h)

    if fits && !oversized {
        view.shrink_since = 0
        return need_w, need_h, true
    }
    if oversized {
        if view.shrink_since == 0 {
            view.shrink_since = rl.GetTime()
        }
        if rl.GetTime() - view.shrink_since < MODEL_TARGET_DWELL {
            return need_w, need_h, true
        }
    }

    thor_model_drop_target(thor, view)
    target := rl.LoadRenderTexture(want_w, want_h)
    view.shrink_since = 0
    if !rl.IsRenderTextureValid(target) {
        return 0, 0, false
    }
    rl.SetTextureFilter(target.texture, .BILINEAR)
    view.target = target
    return need_w, need_h, true
}

@(private = "file")
thor_model_drop_target :: proc(thor: ^Thor, view: ^Model_View) {
    if view.target.id == 0 {
        return
    }
    render.forget_texture(&thor.backend, view.target.texture)
    rl.UnloadRenderTexture(view.target)
    view.target = {}
}

// Ground grid at the model's lowest point, centred under it. The step is a
// round number near a third of the model, so the lines read as a scale.
@(private = "file")
thor_model_draw_grid :: proc(thor: ^Thor, view: ^Model_View) {
    step := thor_model_grid_step(view.radius)
    extent := step * MODEL_GRID_HALF
    cx := math.round(view.pivot.x / step) * step
    cz := math.round(view.pivot.z / step) * step
    y := view.floor - view.radius * 0.001 // just under, so a flat model does not z-fight

    grid := render.raylib_color(thor.theme.highlight)
    axis := render.raylib_color(thor.theme.disabled)
    for i in -MODEL_GRID_HALF ..= MODEL_GRID_HALF {
        offset := f32(i) * step
        color := i == 0 ? axis : grid
        rl.DrawLine3D({cx - extent, y, cz + offset}, {cx + extent, y, cz + offset}, color)
        rl.DrawLine3D({cx + offset, y, cz - extent}, {cx + offset, y, cz + extent}, color)
    }
}

// Grid step: 1, 2 or 5 times a power of ten, near a third of the model size.
@(private = "file")
thor_model_grid_step :: proc(radius: f32) -> f32 {
    if radius <= 0 {
        return 1
    }
    raw := radius / 3
    base := math.pow(f32(10), math.floor(math.log10(raw)))
    n := raw / base
    switch {
    case n < 1.5:
        return base
    case n < 3.5:
        return base * 2
    case n < 7.5:
        return base * 5
    }
    return base * 10
}

// Draws the model under the headlight shader. The materials belong to the open
// file, so their shaders are swapped in and put back around the one call.
@(private = "file")
thor_model_draw_model :: proc(view: ^Model_View, camera: rl.Camera3D) {
    model := view.file.model
    if view.shader.id == 0 {
        rl.DrawModel(model, {0, 0, 0}, 1, rl.WHITE)
        return
    }

    direction := rl.Vector3Normalize(camera.target - camera.position)
    if view.shader_view_dir >= 0 {
        rl.SetShaderValue(view.shader, view.shader_view_dir, &direction, .VEC3)
    }

    count := int(model.materialCount)
    saved := make([]rl.Shader, count, context.temp_allocator)
    for i in 0 ..< count {
        saved[i] = model.materials[i].shader
        model.materials[i].shader = view.shader
    }
    rl.DrawModel(model, {0, 0, 0}, 1, rl.WHITE)
    for i in 0 ..< count {
        model.materials[i].shader = saved[i]
    }
}

// Diffuse headlight over whatever the material already supplies. raylib fills
// mvp/matNormal/texture0/colDiffuse by name; only viewDir is ours.
@(private = "file")
MODEL_VS :: `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matNormal;
out vec2 fragTexCoord;
out vec4 fragColor;
out vec3 fragNormal;
void main()
{
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    fragNormal = normalize(vec3(matNormal*vec4(vertexNormal, 0.0)));
    gl_Position = mvp*vec4(vertexPosition, 1.0);
}
`

@(private = "file")
MODEL_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec3 viewDir;
out vec4 finalColor;
void main()
{
    vec4 texel = texture(texture0, fragTexCoord)*colDiffuse*fragColor;
    float lambert = max(dot(normalize(fragNormal), -normalize(viewDir)), 0.0);
    finalColor = vec4(texel.rgb*(0.3 + 0.7*lambert), texel.a);
}
`

// Loads the shader once. A failure leaves id 0 and the draw falls back to
// raylib's unlit default.
@(private = "file")
thor_model_load_shader :: proc(view: ^Model_View) {
    if view.shader_tried {
        return
    }
    view.shader_tried = true
    view.shader_view_dir = -1

    shader := rl.LoadShaderFromMemory(MODEL_VS, MODEL_FS)
    if !rl.IsShaderValid(shader) {
        rl.UnloadShader(shader)
        return
    }
    view.shader = shader
    view.shader_view_dir = rl.GetShaderLocation(shader, "viewDir")
}

// The model itself belongs to the open file; only the target and the shader
// are freed here.
thor_model_view_destroy :: proc(thor: ^Thor, view: ^Model_View) {
    thor_model_drop_target(thor, view)
    if view.shader.id != 0 {
        rl.UnloadShader(view.shader)
        view.shader = {}
    }
}
