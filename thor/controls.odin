// The shared control shapes of GOOD_UI.md section 6: a control that takes the
// focus, a flat text button and an icon button.
package thor

import ui "../vendor/loom/loom"

// `el` as a control: Tab reaches it, keyboard focus shows a ring, and its colour
// fades on hover out.
thor_control :: proc(thor: ^Thor, el: ui.Element) -> ui.Element {
    e := el
    e.flags += {.Focusable}
    e.rules = tk_focus_rules(thor)
    if e.transition.props == {} {
        e.transition = TK_FADE
    }
    return e
}

// A flat chrome button. Loom's button fills with the accent, which suits a
// dialog's confirm and not the chrome, so the fill and the text colour are
// stated here.
thor_text_button :: proc(thor: ^Thor, label: string, el: ui.Element = {}, loc := #caller_location) -> ui.Interaction {
    e := ui.Element{
        text = label,
        flags = {.Clickable},
        props = {
            w = ui.FIT,
            h = ui.Px(tk_h(.Control)),
            pad = tk_pad(.M, .None),
            text_align = .Center,
            text_align_v = .Center,
            radius = tk_rad(.Control),
            color = thor.theme.foreground,
            cursor = .Pointer,
            text_wrap = .None,
        },
        hover = {bg = thor.theme.buttons},
    }
    ui.merge_element(&e, el, loc)
    return ui.leaf(thor_control(thor, e), loc)
}

// An icon-only button with its tooltip and chord (5.8). `danger` fills the
// hover with the danger role.
thor_icon_button :: proc(thor: ^Thor, icon, key: string, tip := "", chord := "", danger := false, color: ui.Color = {}, w: f32 = 0, size: f32 = 14) -> ui.Interaction {
    hover := danger ? thor.theme.danger_color : thor.theme.buttons
    width := w > 0 ? w : tk_h(.Control)
    it    := ui.begin(
        thor_control(
            thor,
            {
                key = key,
                flags = {.Clickable},
                props = {w = ui.Px(width), h = ui.Px(tk_h(.Control)), justify = .Center, align = .Center, radius = tk_rad(.Control), cursor = .Pointer},
                hover = {bg = hover},
            },
        ),
    )
    thor_icon_label(thor, icon, color != {} ? color : thor.theme.foreground, size)
    ui.end()
    if tip != "" {
        thor_tip(thor, it.id, tip, chord)
    }
    return it
}
