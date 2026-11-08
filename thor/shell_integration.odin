package thor

// The "Open with Thor" entry of the file manager's context menu. Each platform file supplies:
//   thor_shell_menu_supported :: proc() -> bool           // the platform has such a menu
//   thor_shell_menu_registered :: proc() -> bool          // the entry exists and names this executable
//   thor_shell_menu_set :: proc(on: bool) -> bool         // adds or removes the entry; false on failure

SHELL_MENU_LABEL :: "Open with Thor"

// Settings row and palette command: adds or removes the entry.
thor_cmd_toggle_shell_menu :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if !thor_shell_menu_supported() {
        thor_flash_status(thor, "The file manager menu entry is only available on Windows", true)
        return
    }
    on := !thor_shell_menu_registered()
    if !thor_shell_menu_set(on) {
        thor_flash_status(thor, "Could not change the file manager menu entry", true)
        return
    }
    thor_flash_status(thor, on ? "Added Thor to the file manager menu" : "Removed Thor from the file manager menu")
}
