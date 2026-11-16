package render

import "core:math"

import "../font"
import "../platform"
import "../prof"
import ui "../vendor/loom/loom"

// Turns a frame's draw list into platform draw calls.
draw :: proc(b: ^Backend, list: ui.Draw_List) {
    prof.proc_scope()
    clear(&b.clip)
    platform.list_begin()

    for cmd in list.cmds {
        switch v in cmd {
        case ui.Cmd_Rect:
            draw_rect(b, v)
        case ui.Cmd_Text:
            draw_text(b, v)
        case ui.Cmd_Image:
            draw_image(b, v)
        case ui.Cmd_Line:
            platform.draw_line({v.a.x, v.a.y}, {v.b.x, v.b.y}, v.width, v.color)
        case ui.Cmd_Poly:
            draw_poly(b, v)
        case ui.Cmd_Push_Clip:
            push_clip(b, v.rect)
        case ui.Cmd_Pop_Clip:
            pop_clip(b)
        case ui.Cmd_Custom:
            v.draw(v.node, v.user)
        }
    }

    for len(b.clip) > 0 {
        pop_clip(b)
    }
    platform.list_end()
}

// Always `segs + 1` points, so an outer and an inner path pair up point by point.
@(private)
arc_path :: proc(out: ^[dynamic]ui.Vec2, cx, cy, radius, a0, a1: f32, segs: int) {
    if radius <= 0 {
        for _ in 0 ..= segs {
            append(out, ui.Vec2{cx, cy})
        }
        return
    }
    for i in 0 ..= segs {
        a := a0 + (a1 - a0) * f32(i) / f32(segs)
        append(out, ui.Vec2{cx + math.cos(a) * radius, cy + math.sin(a) * radius})
    }
}

@(private)
rrect_path :: proc(b: ^Backend, out: ^[dynamic]ui.Vec2, r: ui.Rect, rad: ui.Radius) {
    clear(out)
    lim := min(r.w, r.h) * 0.5
    tl  := clamp(rad.tl, 0, lim)
    tr  := clamp(rad.tr, 0, lim)
    br  := clamp(rad.br, 0, lim)
    bl  := clamp(rad.bl, 0, lim)

    segs := b.opts.arc_segments
    PI :: math.PI
    arc_path(out, r.x + tl, r.y + tl, tl, PI, PI * 1.5, segs)
    arc_path(out, r.x + r.w - tr, r.y + tr, tr, PI * 1.5, PI * 2.0, segs)
    arc_path(out, r.x + r.w - br, r.y + r.h - br, br, 0, PI * 0.5, segs)
    arc_path(out, r.x + bl, r.y + r.h - bl, bl, PI * 0.5, PI, segs)
}

@(private)
mix_color :: proc(a, c: ui.Color, k: f32) -> ui.Color {
    out: ui.Color
    for i in 0 ..< 4 {
        out[i] = u8(f32(a[i]) + (f32(c[i]) - f32(a[i])) * k + 0.5)
    }
    return out
}

@(private)
paint_at :: proc(p: ui.Paint, x, y: f32, box: ui.Rect) -> ui.Color {
    switch v in p {
    case ui.Color:
        return (v)
    case ui.Gradient:
        if len(v.stops) == 0 {
            return {0, 0, 0, 0}
        }
        t: f32
        switch v.kind {
        case .Linear:
            dx, dy := math.cos(v.angle), math.sin(v.angle)
            cx, cy := box.x + box.w * 0.5, box.y + box.h * 0.5
            half := (abs(box.w * dx) + abs(box.h * dy)) * 0.5
            t = half > 0 ? (((x - cx) * dx + (y - cy) * dy) / half + 1) * 0.5 : 0
        case .Radial:
            cx, cy := box.x + box.w * 0.5, box.y + box.h * 0.5
            rr := max(box.w, box.h) * 0.5
            t = rr > 0 ? math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / rr : 0
        case .Bilinear:
            if len(v.stops) < 4 {
                return (v.stops[0].color)
            }
            u   := box.w > 0 ? clamp((x - box.x) / box.w, 0, 1) : 0
            w   := box.h > 0 ? clamp((y - box.y) / box.h, 0, 1) : 0
            top := mix_color(v.stops[0].color, v.stops[1].color, u)
            bot := mix_color(v.stops[3].color, v.stops[2].color, u)
            return (mix_color(top, bot, w))
        }
        t = clamp(t, 0, 1)
        lo := v.stops[0]
        for s in v.stops {
            if s.t >= t {
                span := s.t - lo.t
                k    := span > 0 ? (t - lo.t) / span : 0
                return (mix_color(lo.color, s.color, k))
            }
            lo = s
        }
        return (lo.color)
    }
    return {0, 0, 0, 0}
}

// A convex polygon as one fan. A concave outline comes out wrong, which is why
// the command is documented as convex.
@(private)
draw_poly :: proc(b: ^Backend, cmd: ui.Cmd_Poly) {
    if len(cmd.points) < 3 || cmd.color[3] == 0 {
        return
    }
    col := (cmd.color)
    a   := ui.Vec2{cmd.points[0].x, cmd.points[0].y}
    for i in 1 ..< len(cmd.points) - 1 {
        p1 := ui.Vec2{cmd.points[i].x, cmd.points[i].y}
        p2 := ui.Vec2{cmd.points[i + 1].x, cmd.points[i + 1].y}
        platform.draw_triangle(a, p1, p2, col)
    }
}

@(private)
fill_poly :: proc(pts: []ui.Vec2, box: ui.Rect, p: ui.Paint) {
    if len(pts) < 3 || p == nil {
        return
    }
    cx, cy := box.x + box.w * 0.5, box.y + box.h * 0.5
    cc := paint_at(p, cx, cy, box)
    if cc.a == 0 {
        if c0 := paint_at(p, pts[0].x, pts[0].y, box); c0.a == 0 {
            return
        }
    }

    platform.triangles_begin(len(pts) * 3)
    for i in 0 ..< len(pts) {
        a := pts[i]
        d := pts[(i + 1) % len(pts)]
        platform.vertex(cx, cy, cc)
        platform.vertex(a.x, a.y, paint_at(p, a.x, a.y, box))
        platform.vertex(d.x, d.y, paint_at(p, d.x, d.y, box))
    }
    platform.triangles_end()
}

@(private)
stroke_ring :: proc(outer, inner: []ui.Vec2, col: ui.Color) {
    n := min(len(outer), len(inner))
    if n < 3 || col.a == 0 {
        return
    }

    platform.triangles_begin(n * 6)
    for i in 0 ..< n {
        j := (i + 1) % n
        platform.vertex(outer[i].x, outer[i].y, col)
        platform.vertex(inner[i].x, inner[i].y, col)
        platform.vertex(inner[j].x, inner[j].y, col)

        platform.vertex(outer[i].x, outer[i].y, col)
        platform.vertex(inner[j].x, inner[j].y, col)
        platform.vertex(outer[j].x, outer[j].y, col)
    }
    platform.triangles_end()
}

@(private)
inset_radius :: proc(rad: ui.Radius, w: f32) -> ui.Radius {
    return {max(rad.tl - w, 0), max(rad.tr - w, 0), max(rad.br - w, 0), max(rad.bl - w, 0)}
}

@(private)
grow_radius :: proc(rad: ui.Radius, w: f32) -> ui.Radius {
    return {rad.tl + w, rad.tr + w, rad.br + w, rad.bl + w}
}

draw_rect :: proc(b: ^Backend, cmd: ui.Cmd_Rect) {
    box := (cmd.rect)
    s   := cmd.shadow

    if s.color[3] > 0 && !s.inset {
        steps := int(clamp(s.blur * 0.5, 1, MAX_SHADOW_STEPS))
        for i in 0 ..< steps {
            t    := f32(i) / f32(steps)
            grow := s.spread + s.blur * t
            a    := u8(f32(s.color[3]) / f32(steps) * (1 - t))
            r    := ui.Rect{box.x + s.offset.x - grow, box.y + s.offset.y - grow, box.w + grow * 2, box.h + grow * 2}
            rrect_path(b, &b.path_a, r, grow_radius(cmd.radius, grow))
            fill_poly(b.path_a[:], r, ui.Color{s.color[0], s.color[1], s.color[2], a})
        }
    }

    rrect_path(b, &b.path_a, box, cmd.radius)
    fill_poly(b.path_a[:], box, cmd.paint)

    if s.color[3] > 0 && s.inset {
        steps := int(clamp(s.blur * 0.5, 1, MAX_SHADOW_STEPS))
        for i in 0 ..< steps {
            t      := f32(i) / f32(steps)
            shrink := s.spread + s.blur * t
            a      := u8(f32(s.color[3]) / f32(steps) * (1 - t))
            r      := ui.Rect{box.x + s.offset.x + shrink, box.y + s.offset.y + shrink, box.w - shrink * 2, box.h - shrink * 2}
            if r.w <= 0 || r.h <= 0 {
                break
            }
            rrect_path(b, &b.path_a, box, cmd.radius)
            rrect_path(b, &b.path_b, r, inset_radius(cmd.radius, shrink))
            stroke_ring(b.path_a[:], b.path_b[:], ({s.color[0], s.color[1], s.color[2], a}))
        }
    }

    if cmd.border.color[3] == 0 {
        return
    }

    bw  := cmd.border.width
    col := (cmd.border.color)
    if bw.l == bw.t && bw.t == bw.r && bw.r == bw.b {
        if bw.l > 0 {
            w     := bw.l
            inner := ui.Rect{box.x + w, box.y + w, max(box.w - w * 2, 0), max(box.h - w * 2, 0)}
            rrect_path(b, &b.path_a, box, cmd.radius)
            rrect_path(b, &b.path_b, inner, inset_radius(cmd.radius, w))
            stroke_ring(b.path_a[:], b.path_b[:], col)
        }
        return
    }

    if bw.t > 0 {
        platform.draw_rect({box.x, box.y, box.w, bw.t}, col)
    }
    if bw.b > 0 {
        platform.draw_rect({box.x, box.y + box.h - bw.b, box.w, bw.b}, col)
    }
    if bw.l > 0 {
        platform.draw_rect({box.x, box.y, bw.l, box.h}, col)
    }
    if bw.r > 0 {
        platform.draw_rect({box.x + box.w - bw.r, box.y, bw.r, box.h}, col)
    }
}

draw_text :: proc(b: ^Backend, cmd: ui.Cmd_Text) {
    if cmd.text == "" || cmd.color[3] == 0 || cmd.size <= 0 {
        return
    }
    // Loom places a run by its baseline; the font package draws from the top.
    top := cmd.pos.y - cmd.size * ASCENT_FRACTION
    font.draw(cmd.text, i32(cmd.pos.x), i32(math.round(top)), i32(cmd.size), (cmd.color), family_of(b, cmd.font), 0, style_of(b, cmd.font))
}

draw_image :: proc(b: ^Backend, cmd: ui.Cmd_Image) {
    tex, ok := b.textures[u32(cmd.tex)]
    if !ok {
        return
    }

    src := cmd.uv
    if src.w == 0 || src.h == 0 {
        src = {0, 0, f32(tex.width), f32(tex.height)}
    } else {
        src = {src.x * f32(tex.width), src.y * f32(tex.height), src.w * f32(tex.width), src.h * f32(tex.height)}
    }

    tint := cmd.tint
    if tint == (ui.Color{}) {
        tint = {255, 255, 255, 255}
    }
    platform.draw_texture(tex, src, cmd.rect, tint)
}

@(private)
push_clip :: proc(
    // A scissor is axis-aligned, so Cmd_Push_Clip.radius is dropped: a rounded
    // panel clips its contents to the bounding box, not to the corner.
    b: ^Backend,
    r: ui.Rect,
) {
    next := r
    if len(b.clip) > 0 {
        p := b.clip[len(b.clip) - 1]
        x0, y0 := max(p.x, r.x), max(p.y, r.y)
        x1 := min(p.x + p.w, r.x + r.w)
        y1 := min(p.y + p.h, r.y + r.h)
        next = {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
    }
    append(&b.clip, next)
    apply_clip(next)
}

@(private)
pop_clip :: proc(b: ^Backend) {
    if len(b.clip) == 0 {
        return
    }
    pop(&b.clip)
    if len(b.clip) > 0 {
        apply_clip(b.clip[len(b.clip) - 1])
    } else {
        platform.scissor_end()
    }
}

@(private)
apply_clip :: proc(
    // The rect is in screen coordinates, the same space as every draw call; the backend scales it to the framebuffer.
    r: ui.Rect,
) {
    platform.scissor_begin(r)
}
