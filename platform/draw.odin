package platform

import "core:c"
import "core:math"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

import ui "../vendor/loom/loom"

// A corner of a textured quad: its screen position and its texture coordinate.
Tex_Vertex :: struct {
    pos: [2]f32,
    uv:  [2]f32,
}

// Starts a 2D draw list. A list draws polygons in both windings, so culling is off.
list_begin :: proc() {
    rlgl.DisableBackfaceCulling()
}

// Ends a 2D draw list. The batch drains first, or the state restored here would
// be the state the pending tail draws under.
list_end :: proc() {
    rlgl.DrawRenderBatchActive()
    rlgl.EnableBackfaceCulling()
}

// Sends the pending batch to the GPU.
flush :: proc() {
    rlgl.DrawRenderBatchActive()
}

draw_rect :: proc(r: ui.Rect, color: ui.Color) {
    rl.DrawRectangleRec(to_rl_rect(r), rl.Color(color))
}

draw_rect_lines :: proc(r: ui.Rect, thickness: f32, color: ui.Color) {
    rl.DrawRectangleLinesEx(to_rl_rect(r), thickness, rl.Color(color))
}

draw_line :: proc(a, b: [2]f32, width: f32, color: ui.Color) {
    rl.DrawLineEx(a, b, width, rl.Color(color))
}

// A triangle in counter-clockwise order.
draw_triangle :: proc(a, b, c: [2]f32, color: ui.Color) {
    rl.DrawTriangle(a, b, c, rl.Color(color))
}

// Starts a run of untextured triangles of `vertex_count` vertices in all.
triangles_begin :: proc(vertex_count: int) {
    rlgl.CheckRenderBatchLimit(c.int(vertex_count))
    rlgl.SetTexture(rlgl.GetTextureIdDefault())
    rlgl.Begin(rlgl.TRIANGLES)
    rlgl.TexCoord2f(0, 0)
}

// One vertex of the run triangles_begin opened.
vertex :: proc(x, y: f32, color: ui.Color) {
    rlgl.Color4ub(color.r, color.g, color.b, color.a)
    rlgl.Vertex2f(x, y)
}

triangles_end :: proc() {
    rlgl.End()
    rlgl.SetTexture(0)
}

// Draws `src` of `tex` stretched over `dst`.
draw_texture :: proc(tex: Texture, src, dst: ui.Rect, tint: ui.Color) {
    rl.DrawTexturePro(to_rl_texture(tex), to_rl_rect(src), to_rl_rect(dst), {0, 0}, 0, rl.Color(tint))
}

// Draws `src` of `tex` at its own size with the top left at `pos`.
draw_texture_at :: proc(tex: Texture, src: ui.Rect, pos: [2]f32, tint: ui.Color) {
    rl.DrawTextureRec(to_rl_texture(tex), to_rl_rect(src), pos, rl.Color(tint))
}

// One textured quad. The corners go top left, bottom left, bottom right, top right.
draw_textured_quad :: proc(tex: Texture, corners: [4]Tex_Vertex, tint: ui.Color) {
    rlgl.SetTexture(tex.id)
    rlgl.Begin(rlgl.QUADS)
    rlgl.Color4ub(tint.r, tint.g, tint.b, tint.a)
    rlgl.Normal3f(0, 0, 1)
    for corner in corners {
        rlgl.TexCoord2f(corner.uv.x, corner.uv.y)
        rlgl.Vertex2f(corner.pos.x, corner.pos.y)
    }
    rlgl.End()
    rlgl.SetTexture(0)
}

// Clips every draw to `r`, in screen coordinates.
scissor_begin :: proc(r: ui.Rect) {
    rl.BeginScissorMode(c.int(math.round(r.x)), c.int(math.round(r.y)), c.int(math.round(r.w)), c.int(math.round(r.h)))
}

scissor_end :: proc() {
    rl.EndScissorMode()
}
