package platform

import "core:strings"
import rl "vendor:raylib"

Vec3 :: [3]f32

// An axis-aligned box.
Bounds :: struct {
    min, max: Vec3,
}

// A model on the GPU: its meshes and materials. nil for none.
Model :: distinct rawptr

// A compiled shader program. `id` is 0 for none; `locs` is backend data.
Shader :: struct {
    id:   u32,
    locs: rawptr,
}

// An off-screen colour and depth target, drawn into between target_begin and target_end.
Render_Target :: struct {
    id:      u32,
    texture: Texture,
    depth:   Texture,
}

// A perspective camera. `fovy` is the vertical field of view in degrees.
Camera :: struct {
    position: Vec3,
    target:   Vec3,
    up:       Vec3,
    fovy:     f32,
}

@(private = "file")
model_ptr :: proc(m: Model) -> ^rl.Model {
    return cast(^rl.Model)rawptr(m)
}

@(private = "file")
to_rl_shader :: proc(s: Shader) -> rl.Shader {
    return {id = u32(s.id), locs = cast([^]i32)s.locs}
}

@(private = "file")
to_rl_target :: proc(t: Render_Target) -> rl.RenderTexture2D {
    return {id = u32(t.id), texture = to_rl_texture(t.texture), depth = to_rl_texture(t.depth)}
}

// Loads a model file onto the GPU. Materials and textures resolve relative to
// `path`, so pass an absolute one. Main thread only.
model_load :: proc(path: string) -> (Model, bool) {
    model := rl.LoadModel(strings.clone_to_cstring(path, context.temp_allocator))
    if !rl.IsModelValid(model) {
        // Frees the default material LoadModel still made.
        rl.UnloadModel(model)
        return nil, false
    }
    m := new(rl.Model)
    m^ = model
    return Model(m), true
}

model_free :: proc(model: ^Model) {
    if model^ == nil {
        return
    }
    m := model_ptr(model^)
    rl.UnloadModel(m^)
    free(m)
    model^ = nil
}

model_bounds :: proc(model: Model) -> Bounds {
    if model == nil {
        return {}
    }
    box := rl.GetModelBoundingBox(model_ptr(model)^)
    return {box.min, box.max}
}

// The mesh, vertex and triangle counts of `model`.
model_stats :: proc(model: Model) -> (meshes, vertices, triangles: int) {
    if model == nil {
        return
    }
    m := model_ptr(model)
    meshes = int(m.meshCount)
    for i in 0 ..< meshes {
        vertices += int(m.meshes[i].vertexCount)
        triangles += int(m.meshes[i].triangleCount)
    }
    return
}

// Draws `model` at the origin. A `shader` with an id replaces the shader of
// every material for this one call.
draw_model :: proc(model: Model, shader: Shader) {
    if model == nil {
        return
    }
    m := model_ptr(model)
    if shader.id == 0 {
        rl.DrawModel(m^, {0, 0, 0}, 1, rl.WHITE)
        return
    }
    count := int(m.materialCount)
    saved := make([]rl.Shader, count, context.temp_allocator)
    for i in 0 ..< count {
        saved[i] = m.materials[i].shader
        m.materials[i].shader = to_rl_shader(shader)
    }
    rl.DrawModel(m^, {0, 0, 0}, 1, rl.WHITE)
    for i in 0 ..< count {
        m.materials[i].shader = saved[i]
    }
}

draw_line_3d :: proc(a, b: Vec3, color: Color) {
    rl.DrawLine3D(a, b, rl.Color(color))
}

// Compiles a GLSL program. Main thread only.
shader_load :: proc(vertex, fragment: string) -> (Shader, bool) {
    vs     := strings.clone_to_cstring(vertex, context.temp_allocator)
    fs     := strings.clone_to_cstring(fragment, context.temp_allocator)
    shader := rl.LoadShaderFromMemory(vs, fs)
    if !rl.IsShaderValid(shader) {
        rl.UnloadShader(shader)
        return {}, false
    }
    return {id = u32(shader.id), locs = rawptr(shader.locs)}, true
}

shader_free :: proc(shader: ^Shader) {
    if shader.id != 0 {
        rl.UnloadShader(to_rl_shader(shader^))
    }
    shader^ = {}
}

// The location of uniform `name`, -1 when the program has none.
shader_location :: proc(shader: Shader, name: string) -> i32 {
    return rl.GetShaderLocation(to_rl_shader(shader), strings.clone_to_cstring(name, context.temp_allocator))
}

shader_set_vec3 :: proc(shader: Shader, location: i32, value: Vec3) {
    v := value
    rl.SetShaderValue(to_rl_shader(shader), location, &v, .VEC3)
}

render_target_create :: proc(width, height: i32) -> (Render_Target, bool) {
    target := rl.LoadRenderTexture(width, height)
    if !rl.IsRenderTextureValid(target) {
        return {}, false
    }
    return {id = u32(target.id), texture = from_rl_texture(target.texture), depth = from_rl_texture(target.depth)}, true
}

render_target_free :: proc(target: ^Render_Target) {
    if target.id != 0 {
        rl.UnloadRenderTexture(to_rl_target(target^))
    }
    target^ = {}
}

// Starts drawing into `target`, cleared to `clear`.
target_begin :: proc(target: Render_Target, clear: Color) {
    rl.BeginTextureMode(to_rl_target(target))
    rl.ClearBackground(rl.Color(clear))
}

target_end :: proc() {
    rl.EndTextureMode()
}

// Starts a 3D pass seen through `camera`.
mode_3d_begin :: proc(camera: Camera) {
    rl.BeginMode3D(rl.Camera3D{position = camera.position, target = camera.target, up = camera.up, fovy = camera.fovy, projection = .PERSPECTIVE})
}

mode_3d_end :: proc() {
    rl.EndMode3D()
}
