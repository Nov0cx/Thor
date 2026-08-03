package widgets

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

import "../ui"

// Shows a loaded 3D model on a ground grid, orbited and zoomed with the mouse.
// The model is borrowed from the open file; only the render target and the
// shading shader are owned here.
Model_View :: struct {
    using widget:     ui.Widget,
    model:            rl.Model,
    has_model:        bool,
    label:            string, // borrowed file name, drawn in the info overlay
    // Framing taken from the model bounds: the orbit pivot, and the size that
    // sets the start distance, the grid step and the zoom limits.
    pivot:            rl.Vector3,
    radius:           f32,
    floor:            f32, // world Y of the model's lowest point; the grid sits here
    mesh_count:       int,
    vertex_count:     int,
    triangle_count:   int,
    // Orbit around `pivot + pan` at `distance`. Reset when the model changes.
    yaw:              f32,
    pitch:            f32,
    distance:         f32,
    pan:              rl.Vector3,
    drag:             Model_Drag,
    // Auto-orbit, toggled by the corner button. Paused while a drag is held so
    // the user's own orbit is not fought.
    spinning:         bool,
    // Off-screen target the 3D pass renders into, so the scene keeps the pane's
    // aspect ratio and never leaks past its bounds. Owned, sized to the view.
    target:           rl.RenderTexture2D,
    // Headlight shader, loaded on the first draw (it needs the GL context).
    // Without it an untextured mesh draws as a flat silhouette. Owned.
    shader:           rl.Shader,
    shader_tried:     bool,
    shader_view_dir:  i32,
    font_size:        i32,
    background_color: rl.Color,
    grid_color:       rl.Color,
    axis_color:       rl.Color,
    text_color:       rl.Color,
    button_color:     rl.Color,
    button_hover:     rl.Color,
    // Fill of the spin button while it is on.
    accent_color:     rl.Color,
}

// Which camera motion the held mouse button drives.
Model_Drag :: enum {
    None,
    Orbit,
    Pan,
}

MODEL_FOV :: f32(45)
MODEL_ZOOM_STEP :: f32(1.1)
// Zoom limits, in multiples of the model's bounding-sphere radius.
MODEL_DIST_MIN :: f32(0.05)
MODEL_DIST_MAX :: f32(40)
MODEL_ORBIT_SPEED :: f32(0.008) // radians per pixel
MODEL_PITCH_LIMIT :: f32(1.55)  // just short of straight down/up, where up flips
MODEL_SPIN_SPEED :: f32(0.6) // radians per second while auto-orbiting
// Grid lines each side of center. The step is picked so the model spans a few.
MODEL_GRID_HALF :: 12
// Square spin toggle, inset from the top-right corner of the view.
MODEL_BUTTON_SIZE :: f32(30)
MODEL_BUTTON_MARGIN :: f32(10)
MODEL_BUTTON_ICON :: i32(18)
// The 3D pass renders at this multiple of the pane size and is filtered back
// down, which is the cheapest antialiasing available without an MSAA target.
MODEL_SUPERSAMPLE :: 2
MODEL_TARGET_MAX :: 4096

model_view_vtable := ui.Widget_VTable {
    layout = model_view_layout,
    handle_event = model_view_handle_event,
    draw = model_view_draw,
    destroy = model_view_destroy,
}

model_view_create :: proc(id: string) -> ^Model_View {
    view := new(Model_View)
    ui.widget_init(&view.widget, id, model_view_vtable)
    view.font_size = 15
    view.background_color = rl.Color {15, 17, 26, 255}
    view.grid_color = rl.Color {40, 43, 54, 255}
    view.axis_color = rl.Color {70, 74, 92, 255}
    view.text_color = rl.Color {238, 255, 255, 255}
    view.button_color = rl.Color {40, 43, 54, 255}
    view.button_hover = rl.Color {58, 62, 78, 255}
    view.accent_color = rl.Color {94, 129, 172, 255}
    model_view_reset_camera(view)
    return view
}

model_view_set_colors :: proc(
    view: ^Model_View,
    background, grid, axis, text_color, button, button_hover, accent: rl.Color,
) {
    view.background_color = background
    view.grid_color = grid
    view.axis_color = axis
    view.text_color = text_color
    view.button_color = button
    view.button_hover = button_hover
    view.accent_color = accent
}

// Points the view at a model and the bounds it was measured with (a zero
// mesh_count clears it). Resets the camera so a freshly opened model comes up
// framed, and drops the render target while nothing is shown.
model_view_set_model :: proc(view: ^Model_View, model: rl.Model, bounds: rl.BoundingBox, label: string) {
    has := model.meshCount > 0 && model.meshes != nil
    if has && view.has_model && view.model.meshes == model.meshes && view.label == label {
        return
    }

    view.model = model
    view.has_model = has
    view.label = label
    view.mesh_count = 0
    view.vertex_count = 0
    view.triangle_count = 0
    view.drag = .None

    if !has {
        view.model = {}
        if view.target.id != 0 {
            rl.UnloadRenderTexture(view.target)
            view.target = {}
        }
        model_view_reset_camera(view)
        return
    }

    view.mesh_count = cast(int) model.meshCount
    for i in 0 ..< cast(int) model.meshCount {
        view.vertex_count += cast(int) model.meshes[i].vertexCount
        view.triangle_count += cast(int) model.meshes[i].triangleCount
    }

    size := bounds.max - bounds.min
    view.pivot = (bounds.min + bounds.max) * 0.5
    view.radius = max(rl.Vector3Length(size) * 0.5, 0.0001)
    view.floor = bounds.min.y
    model_view_reset_camera(view)
}

// Three-quarter view at a distance that fits the bounding sphere in frame.
model_view_reset_camera :: proc(view: ^Model_View) {
    radius := view.radius > 0 ? view.radius : 1
    view.yaw = -0.7
    view.pitch = 0.4
    view.pan = {0, 0, 0}
    view.distance = radius / math.tan(math.to_radians(MODEL_FOV) * 0.5) * 1.2
}

model_view_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    view := cast(^Model_View) widget
    view.bounds = bounds
}

model_view_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    view := cast(^Model_View) widget
    if !view.has_model {
        return false
    }

    #partial switch event.kind {
    case .Scroll:
        factor := event.wheel_delta > 0 ? 1 / MODEL_ZOOM_STEP : MODEL_ZOOM_STEP
        view.distance = clamp(
            view.distance * factor,
            view.radius * MODEL_DIST_MIN,
            view.radius * MODEL_DIST_MAX,
        )
        return true
    case .Mouse_Down:
        if event.mouse_button == .LEFT &&
           rl.CheckCollisionPointRec(event.mouse_position, model_view_button_rect(view)) {
            view.spinning = !view.spinning
            return true
        }
        // Left orbits, right (or shift+left) pans. Move events carry no
        // modifiers, so the mode is fixed when the button goes down.
        #partial switch event.mouse_button {
        case .LEFT:  view.drag = event.shift ? .Pan : .Orbit
        case .RIGHT: view.drag = .Pan
        case:        return false
        }
        return true
    case .Mouse_Move:
        #partial switch view.drag {
        case .Orbit:
            view.yaw -= event.mouse_delta.x * MODEL_ORBIT_SPEED
            view.pitch = clamp(
                view.pitch + event.mouse_delta.y * MODEL_ORBIT_SPEED,
                -MODEL_PITCH_LIMIT,
                MODEL_PITCH_LIMIT,
            )
            return true
        case .Pan:
            model_view_pan(view, event.mouse_delta)
            return true
        }
    case .Mouse_Up:
        view.drag = .None
    case .Key_Press:
        if event.key == .R && !event.ctrl && !event.alt {
            model_view_reset_camera(view)
            return true
        }
    case:
    }
    return false
}

// Slides the pivot in the camera plane, at the rate that keeps the point under
// the cursor moving with it.
@(private = "file")
model_view_pan :: proc(view: ^Model_View, delta: rl.Vector2) {
    if view.bounds.height <= 0 {
        return
    }
    world_per_pixel := 2 * view.distance * math.tan(math.to_radians(MODEL_FOV) * 0.5) / view.bounds.height
    _, right, up := model_view_basis(view)
    view.pan -= right * (delta.x * world_per_pixel)
    view.pan += up * (delta.y * world_per_pixel)
}

// Unit vector from the orbit target to the camera, for the current angles.
@(private = "file")
model_view_offset :: proc(view: ^Model_View) -> rl.Vector3 {
    return {
        math.cos(view.pitch) * math.sin(view.yaw),
        math.sin(view.pitch),
        math.cos(view.pitch) * math.cos(view.yaw),
    }
}

// Camera axes for the current orbit angles: where it looks, and the screen
// right/up directions in world space.
@(private = "file")
model_view_basis :: proc(view: ^Model_View) -> (forward, right, up: rl.Vector3) {
    forward = rl.Vector3Normalize(-model_view_offset(view))
    right = rl.Vector3Normalize(rl.Vector3CrossProduct(forward, {0, 1, 0}))
    up = rl.Vector3CrossProduct(right, forward)
    return
}

@(private = "file")
model_view_camera :: proc(view: ^Model_View) -> rl.Camera3D {
    target := view.pivot + view.pan
    return rl.Camera3D {
        position = target + model_view_offset(view) * view.distance,
        target = target,
        up = {0, 1, 0},
        fovy = MODEL_FOV,
        projection = .PERSPECTIVE,
    }
}

model_view_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    view := cast(^Model_View) widget
    rl.DrawRectangleRec(view.bounds, view.background_color)

    if !view.has_model || !model_view_ensure_target(view) {
        return
    }
    model_view_load_shader(view)

    if view.spinning && view.drag == .None {
        // Wrapped, or a view left spinning drifts into f32 sizes where the angle
        // step stops resolving.
        view.yaw = math.mod(view.yaw - rl.GetFrameTime() * MODEL_SPIN_SPEED, math.TAU)
    }

    camera := model_view_camera(view)
    rl.BeginTextureMode(view.target)
    rl.ClearBackground(view.background_color)
    rl.BeginMode3D(camera)
    model_view_draw_grid(view)
    model_view_draw_model(view, camera)
    rl.EndMode3D()
    rl.EndTextureMode()

    // A render target is stored bottom-up; the negative source height flips it.
    source := rl.Rectangle {
        0, 0,
        cast(f32) view.target.texture.width,
        -cast(f32) view.target.texture.height,
    }
    ui.begin_clip(view.bounds)
    rl.DrawTexturePro(view.target.texture, source, view.bounds, rl.Vector2 {0, 0}, 0, rl.WHITE)
    ui.end_clip()

    model_view_draw_info(view)
    model_view_draw_spin_button(view, ctx)
}

// Top-right toggle for the auto-orbit, or a zero rect in a pane too small to
// hold it (which also makes the hit test miss).
@(private = "file")
model_view_button_rect :: proc(view: ^Model_View) -> rl.Rectangle {
    span := MODEL_BUTTON_SIZE + 2 * MODEL_BUTTON_MARGIN
    if view.bounds.width < span || view.bounds.height < span {
        return {}
    }
    return rl.Rectangle {
        x = view.bounds.x + view.bounds.width - MODEL_BUTTON_MARGIN - MODEL_BUTTON_SIZE,
        y = view.bounds.y + MODEL_BUTTON_MARGIN,
        width = MODEL_BUTTON_SIZE,
        height = MODEL_BUTTON_SIZE,
    }
}

@(private = "file")
model_view_draw_spin_button :: proc(view: ^Model_View, ctx: ^ui.Context) {
    rect := model_view_button_rect(view)
    if rect.width <= 0 {
        return
    }
    hovered := ctx != nil && ctx.hot == &view.widget && rl.CheckCollisionPointRec(ctx.mouse_pos, rect)

    fill := view.button_color
    switch {
    case view.spinning: fill = view.accent_color
    case hovered:       fill = view.button_hover
    }
    rl.DrawRectangleRec(rect, fill)

    icon_x := cast(i32) (rect.x + (rect.width - cast(f32) MODEL_BUTTON_ICON) * 0.5)
    icon_y := cast(i32) (rect.y + (rect.height - cast(f32) MODEL_BUTTON_ICON) * 0.5)
    ui.draw_icon("3d-rotate", icon_x, icon_y, MODEL_BUTTON_ICON, view.text_color)
}

// Keeps the render target matching the pane, at the supersampled resolution.
// Reallocated on every size change, so a splitter drag rebuilds it per frame.
@(private = "file")
model_view_ensure_target :: proc(view: ^Model_View) -> bool {
    if view.bounds.width < 1 || view.bounds.height < 1 {
        return false
    }
    // Both axes take the same scale, or the target's aspect ratio stops matching
    // the pane's and the projection stretches the model.
    scale := f32(MODEL_SUPERSAMPLE)
    scale = min(scale, MODEL_TARGET_MAX / view.bounds.width)
    scale = min(scale, MODEL_TARGET_MAX / view.bounds.height)
    width := max(cast(i32) (view.bounds.width * scale), 1)
    height := max(cast(i32) (view.bounds.height * scale), 1)
    if view.target.id != 0 &&
       view.target.texture.width == width &&
       view.target.texture.height == height {
        return true
    }

    if view.target.id != 0 {
        rl.UnloadRenderTexture(view.target)
        view.target = {}
    }
    target := rl.LoadRenderTexture(width, height)
    if !rl.IsRenderTextureValid(target) {
        return false
    }
    rl.SetTextureFilter(target.texture, .BILINEAR)
    view.target = target
    return true
}

// Ground grid at the model's lowest point, centered under it. The step is a
// round number near a third of the model, so the lines read as a scale.
@(private = "file")
model_view_draw_grid :: proc(view: ^Model_View) {
    step := model_view_grid_step(view.radius)
    extent := step * MODEL_GRID_HALF
    cx := math.round(view.pivot.x / step) * step
    cz := math.round(view.pivot.z / step) * step
    y := view.floor - view.radius * 0.001 // just under, so a flat model does not z-fight

    for i in -MODEL_GRID_HALF ..= MODEL_GRID_HALF {
        offset := cast(f32) i * step
        color := i == 0 ? view.axis_color : view.grid_color
        rl.DrawLine3D({cx - extent, y, cz + offset}, {cx + extent, y, cz + offset}, color)
        rl.DrawLine3D({cx + offset, y, cz - extent}, {cx + offset, y, cz + extent}, color)
    }
}

// Grid step: 1, 2 or 5 times a power of ten, near a third of the model size.
@(private = "file")
model_view_grid_step :: proc(radius: f32) -> f32 {
    if radius <= 0 {
        return 1
    }
    raw := radius / 3
    base := math.pow(f32(10), math.floor(math.log10(raw)))
    n := raw / base
    switch {
    case n < 1.5: return base
    case n < 3.5: return base * 2
    case n < 7.5: return base * 5
    }
    return base * 10
}

// Draws the model under the headlight shader. The materials belong to the open
// file, so their shaders are swapped in and put back around the one call.
@(private = "file")
model_view_draw_model :: proc(view: ^Model_View, camera: rl.Camera3D) {
    if view.shader.id == 0 {
        rl.DrawModel(view.model, {0, 0, 0}, 1, rl.WHITE)
        return
    }

    direction := rl.Vector3Normalize(camera.target - camera.position)
    if view.shader_view_dir >= 0 {
        rl.SetShaderValue(view.shader, view.shader_view_dir, &direction, .VEC3)
    }

    count := cast(int) view.model.materialCount
    saved := make([]rl.Shader, count, context.temp_allocator)
    for i in 0 ..< count {
        saved[i] = view.model.materials[i].shader
        view.model.materials[i].shader = view.shader
    }
    rl.DrawModel(view.model, {0, 0, 0}, 1, rl.WHITE)
    for i in 0 ..< count {
        view.model.materials[i].shader = saved[i]
    }
}

// Bottom-left overlay: file name and the mesh, vertex and triangle totals.
@(private = "file")
model_view_draw_info :: proc(view: ^Model_View) {
    text := fmt.tprintf(
        "%s   %d meshes   %d verts   %d tris",
        view.label, view.mesh_count, view.vertex_count, view.triangle_count,
    )
    pad := i32(10)
    y := cast(i32) (view.bounds.y + view.bounds.height) - view.font_size - pad
    ui.draw_text(text, cast(i32) view.bounds.x + pad, y, view.font_size, view.text_color)
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

// Loads the shader once per view. A failure leaves id 0 and the draw falls back
// to raylib's unlit default.
@(private = "file")
model_view_load_shader :: proc(view: ^Model_View) {
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

model_view_destroy :: proc(widget: ^ui.Widget) {
    view := cast(^Model_View) widget
    // The model is owned by the open file, not the view.
    if view.target.id != 0 {
        rl.UnloadRenderTexture(view.target)
    }
    if view.shader.id != 0 {
        rl.UnloadShader(view.shader)
    }
    free(view)
}
