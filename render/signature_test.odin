package render

import "core:strings"
import "core:testing"

import ui "../vendor/loom/loom"

@(test)
test_list_signature_follows_the_content :: proc(t: ^testing.T) {
    text_a := strings.clone("hello")
    defer delete(text_a)
    text_b := strings.clone("hello")
    defer delete(text_b)

    a := []ui.Draw_Command {
        ui.Cmd_Rect{rect = {0, 0, 10, 10}, paint = ui.Color{1, 2, 3, 255}},
        ui.Cmd_Text{pos = {4, 12}, text = text_a, size = 14, color = {9, 9, 9, 255}},
    }
    // The same text at another address: the signature reads the bytes, not the pointer.
    b := []ui.Draw_Command {
        ui.Cmd_Rect{rect = {0, 0, 10, 10}, paint = ui.Color{1, 2, 3, 255}},
        ui.Cmd_Text{pos = {4, 12}, text = text_b, size = 14, color = {9, 9, 9, 255}},
    }
    moved := []ui.Draw_Command {
        ui.Cmd_Rect{rect = {0, 1, 10, 10}, paint = ui.Color{1, 2, 3, 255}},
        ui.Cmd_Text{pos = {4, 12}, text = text_b, size = 14, color = {9, 9, 9, 255}},
    }
    sig_a, stable_a := list_signature({cmds = a})
    sig_b, stable_b := list_signature({cmds = b})
    sig_moved, _ := list_signature({cmds = moved})
    testing.expect(t, stable_a && stable_b, "a list of plain commands must be stable")
    testing.expect_value(t, sig_a, sig_b)
    testing.expect(t, sig_a != sig_moved, "a moved rect kept the signature")

    custom := []ui.Draw_Command{ui.Cmd_Custom{}}
    _, stable_custom := list_signature({cmds = custom})
    testing.expect(t, !stable_custom, "a custom command must make the list unstable")
}
