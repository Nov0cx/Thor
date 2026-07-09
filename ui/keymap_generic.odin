#+build !windows
package ui

import rl "vendor:raylib"

remap_key_to_layout :: proc(key: rl.KeyboardKey) -> rl.KeyboardKey {
    return key
}
