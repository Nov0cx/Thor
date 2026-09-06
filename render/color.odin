package render

import rl "vendor:raylib"

import ui "../vendor/loom/loom"

// The draw list speaks Loom colours and rects; raylib wants its own. This is the
// only place inside the backend the two meet.
raylib_color :: proc(c: ui.Color) -> rl.Color {
	return {c[0], c[1], c[2], c[3]}
}

raylib_rect :: proc(r: ui.Rect) -> rl.Rectangle {
	return {r.x, r.y, r.w, r.h}
}
