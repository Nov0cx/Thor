#+build !windows
package thor

thor_shell_menu_supported :: proc() -> bool {
    return false
}

thor_shell_menu_registered :: proc() -> bool {
    return false
}

thor_shell_menu_set :: proc(on: bool) -> bool {
    return false
}
