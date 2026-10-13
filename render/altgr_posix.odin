#+build !windows
package render

// X11, Wayland and Cocoa give no layout query without a new dependency, so
// Right Alt stays AltGr. The right_alt setting overrides it.
layout_has_alt_gr :: proc() -> bool {
    return true
}
