package platform

import rl "vendor:raylib"

// Seconds since the window opened.
time :: proc() -> f64 {
    return rl.GetTime()
}

// Seconds the last frame took.
frame_time :: proc() -> f32 {
    return rl.GetFrameTime()
}
