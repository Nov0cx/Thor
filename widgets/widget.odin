package widgets

import "../ui"

append_child :: proc(parent, child: ^ui.Widget) {
    ui.widget_append_child(parent, child)
}
