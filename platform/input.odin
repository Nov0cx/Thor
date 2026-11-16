package platform

import rl "vendor:raylib"

// The mouse in window coordinates.
mouse_position :: proc() -> [2]f32 {
    return rl.GetMousePosition()
}
