package setting

import "core:testing"

// Run from the repository root: odin test setting

// Only the two explicit spellings pick a window; everything else — unset, a
// typo, a stale value — must prompt rather than silently choose one.
@(test)
test_parse_open_folder_in :: proc(t: ^testing.T) {
    testing.expect_value(t, parse_open_folder_in("same"), Open_Folder_In.Same)
    testing.expect_value(t, parse_open_folder_in("new"), Open_Folder_In.New)
    testing.expect_value(t, parse_open_folder_in("ask"), Open_Folder_In.Ask)
    testing.expect_value(t, parse_open_folder_in(""), Open_Folder_In.Ask)
    testing.expect_value(t, parse_open_folder_in("Same"), Open_Folder_In.Ask)
    testing.expect_value(t, parse_open_folder_in("window"), Open_Folder_In.Ask)
}

// Every choice must survive a write/read cycle, so a persisted "don't ask again"
// comes back as the same choice.
@(test)
test_open_folder_in_round_trip :: proc(t: ^testing.T) {
    for choice in Open_Folder_In {
        testing.expect_value(t, parse_open_folder_in(open_folder_in_value(choice)), choice)
    }
}

// An absent open_folder_in leaves the default in place: a settings file written
// before this key existed must still load as Ask.
@(test)
test_open_folder_in_defaults_to_ask :: proc(t: ^testing.T) {
    s: Settings
    testing.expect_value(t, open_folder_in(&s), Open_Folder_In.Ask)
}
