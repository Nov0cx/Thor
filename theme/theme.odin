package theme

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

import "../atomicfile"
import "../luaconf"
import ui "../vendor/loom/loom"

Theme :: struct {
    name:                   string,
    background:             ui.Color,
    foreground:             ui.Color,
    text:                   ui.Color,
    selection_background:   ui.Color,
    selection_foreground:   ui.Color,
    buttons:                ui.Color,
    second_background:      ui.Color,
    disabled:               ui.Color,
    contrast:               ui.Color,
    active:                 ui.Color,
    border:                 ui.Color,
    highlight:              ui.Color,
    tree:                   ui.Color,
    notifications:          ui.Color,
    accent_color:           ui.Color,
    excluded_files_color:   ui.Color,
    success_color:          ui.Color,
    warning_color:          ui.Color,
    info_color:             ui.Color,
    danger_color:           ui.Color,
    submodule_color:        ui.Color,
    conflict_color:         ui.Color,
    accent_secondary_color: ui.Color,
    muted_color:            ui.Color,
    primary_text_color:     ui.Color,
    error_color:            ui.Color,
    comments_color:         ui.Color,
    variables_color:        ui.Color,
    links_color:            ui.Color,
    functions_color:        ui.Color,
    keywords_color:         ui.Color,
    tags_color:             ui.Color,
    strings_color:          ui.Color,
    operators_color:        ui.Color,
    attributes_color:       ui.Color,
    numbers_color:          ui.Color,
    parameters_color:       ui.Color,
}

// Which part of the UI a color role belongs to. Orders COLORS and names the
// fold groups the Settings modal builds from it.
Color_Group :: enum {
    Surfaces,
    Text,
    Status,
    Syntax,
}

GROUP_LABELS := [Color_Group]string {
    .Surfaces = "Surfaces",
    .Text     = "Text",
    .Status   = "Status",
    .Syntax   = "Syntax",
}

// One color role: its display label, its field, its group, the id a theme file
// and a plugin name it by, and one line that says what it paints.
Color_Entry :: struct {
    key:    string, // display label; a theme file may also name the role by it
    offset: uintptr,
    group:  Color_Group,
    role:   string, // theme file key and plugin id (thor.theme.<role>)
    hint:   string,
}

// Every color role, grouped and in the order a written theme lists them. The one
// key-to-field mapping in the program: assign_color, color, role_color, save
// and the theme window rows all read it.
COLORS := [?]Color_Entry {
    {"Background",             offset_of(Theme, background),             .Surfaces, "background",           "The editor and the main panels."},
    {"Second Background",      offset_of(Theme, second_background),      .Surfaces, "second_background",    "Headers, sidebars and the row under the pointer."},
    {"Contrast",               offset_of(Theme, contrast),               .Surfaces, "contrast",             "The deepest surface: the window frame, input fields and shadows."},
    {"Buttons",                offset_of(Theme, buttons),                .Surfaces, "buttons",              "Buttons, chips and tabs."},
    {"Active",                 offset_of(Theme, active),                 .Surfaces, "active",               "The selected tab, row or button."},
    {"Highlight",              offset_of(Theme, highlight),              .Surfaces, "highlight",            "The current line and marked areas."},
    {"Border",                 offset_of(Theme, border),                 .Surfaces, "border",               "Lines between panels and around boxes."},
    {"Notifications",          offset_of(Theme, notifications),          .Surfaces, "notifications",        "Toasts and the status flash."},
    {"Tree",                   offset_of(Theme, tree),                   .Surfaces, "tree",                 "The indent guides of the file tree."},
    {"Selection Background",   offset_of(Theme, selection_background),   .Surfaces, "selection_background", "Selected text. Use alpha to keep the syntax colors visible."},
    {"Accent Color",           offset_of(Theme, accent_color),           .Surfaces, "accent",               "The caret, focus rings, toggles and the main buttons."},
    {"Accent Secondary Color", offset_of(Theme, accent_secondary_color), .Surfaces, "accent_secondary",     "The second accent, for plugins and marks."},

    {"Text",                   offset_of(Theme, text),                   .Text,     "text",                 "Body text of the editor."},
    {"Primary Text Color",     offset_of(Theme, primary_text_color),     .Text,     "primary_text",         "Names in lists: files, symbols and results."},
    {"Foreground",             offset_of(Theme, foreground),             .Text,     "foreground",           "Labels, titles and the text of controls."},
    {"Muted Color",            offset_of(Theme, muted_color),            .Text,     "muted",                "Second lines, paths and hints."},
    {"Disabled",               offset_of(Theme, disabled),               .Text,     "disabled",             "Controls you cannot use, and line numbers."},
    {"Selection Foreground",   offset_of(Theme, selection_foreground),   .Text,     "selection_foreground", "Text on the selected palette row."},
    {"Excluded Files Color",   offset_of(Theme, excluded_files_color),   .Text,     "excluded_files",       "Ignored files in the file tree."},
    {"Links Color",            offset_of(Theme, links_color),            .Text,     "links",                "Links in rendered markdown."},

    {"Success Color",          offset_of(Theme, success_color),          .Status,   "success",              "Added lines and passed tasks."},
    {"Warning Color",          offset_of(Theme, warning_color),          .Status,   "warning",              "Warnings and changed files."},
    {"Info Color",             offset_of(Theme, info_color),             .Status,   "info",                 "Information marks and modified files."},
    {"Danger Color",           offset_of(Theme, danger_color),           .Status,   "danger",               "Destructive buttons and deleted lines."},
    {"Error Color",            offset_of(Theme, error_color),            .Status,   "error",                "Errors and failed tasks."},
    {"Conflict Color",         offset_of(Theme, conflict_color),         .Status,   "conflict",             "Git merge conflicts."},
    {"Submodule Color",        offset_of(Theme, submodule_color),        .Status,   "submodule",            "Git submodules."},

    {"Comments Color",         offset_of(Theme, comments_color),         .Syntax,   "comments",             "Comments."},
    {"Keywords Color",         offset_of(Theme, keywords_color),         .Syntax,   "keywords",             "Keywords such as if, for and return."},
    {"Functions Color",        offset_of(Theme, functions_color),        .Syntax,   "functions",            "Names of functions and procedures."},
    {"Strings Color",          offset_of(Theme, strings_color),          .Syntax,   "strings",              "String and character literals."},
    {"Numbers Color",          offset_of(Theme, numbers_color),          .Syntax,   "numbers",              "Number literals and constants."},
    {"Operators Color",        offset_of(Theme, operators_color),        .Syntax,   "operators",            "Operators and punctuation."},
    {"Variables Color",        offset_of(Theme, variables_color),        .Syntax,   "variables",            "Variables and fields."},
    {"Parameters Color",       offset_of(Theme, parameters_color),       .Syntax,   "parameters",           "Parameters of a procedure."},
    {"Attributes Color",       offset_of(Theme, attributes_color),       .Syntax,   "attributes",           "Attributes, directives and annotations."},
    {"Tags Color",             offset_of(Theme, tags_color),             .Syntax,   "tags",                 "Types, and tags in markup."},
}

// The built-in fallback theme: used as the base every loaded theme overlays, and
// returned whole when a theme file is missing or malformed. Mirrors
// assets/themes/mjolnir.lua.
mjolnir :: proc() -> Theme {
    return Theme {
        name = "Mjolnir",
        background = ui.Color {0x1A, 0x1C, 0x23, 0xFF},
        foreground = ui.Color {0xD0, 0xD4, 0xE0, 0xFF},
        text = ui.Color {0xEC, 0xEF, 0xF1, 0xFF},
        selection_background = ui.Color {0x3F, 0x51, 0xB5, 0x70},
        selection_foreground = ui.Color {0xFF, 0xFF, 0xFF, 0xFF},
        buttons = ui.Color {0x27, 0x2A, 0x33, 0xFF},
        second_background = ui.Color {0x22, 0x25, 0x2C, 0xFF},
        disabled = ui.Color {0x5C, 0x62, 0x70, 0xFF},
        contrast = ui.Color {0x13, 0x15, 0x19, 0xFF},
        active = ui.Color {0x2C, 0x30, 0x3A, 0xFF},
        border = ui.Color {0x1C, 0x1F, 0x26, 0xFF},
        highlight = ui.Color {0x33, 0x38, 0x46, 0xFF},
        tree = ui.Color {0x3F, 0x4A, 0x5A, 0x50},
        notifications = ui.Color {0x13, 0x15, 0x19, 0xFF},
        accent_color = ui.Color {0x4F, 0xC3, 0xF7, 0xFF},
        excluded_files_color = ui.Color {0x2E, 0x32, 0x3C, 0xFF},
        success_color = ui.Color {0x69, 0xF0, 0xAE, 0xFF},
        warning_color = ui.Color {0xFF, 0xCA, 0x28, 0xFF},
        info_color = ui.Color {0x44, 0x8A, 0xFF, 0xFF},
        danger_color = ui.Color {0xFF, 0x52, 0x52, 0xFF},
        submodule_color = ui.Color {0xCE, 0x93, 0xD8, 0xFF},
        conflict_color = ui.Color {0xFF, 0x70, 0x43, 0xFF},
        accent_secondary_color = ui.Color {0x18, 0xFF, 0xFF, 0xFF},
        muted_color = ui.Color {0x90, 0xA4, 0xAE, 0xFF},
        primary_text_color = ui.Color {0xEC, 0xEF, 0xF1, 0xFF},
        error_color = ui.Color {0xFF, 0x52, 0x52, 0xFF},
        comments_color = ui.Color {0x61, 0x6A, 0x7A, 0xFF},
        variables_color = ui.Color {0xEC, 0xEF, 0xF1, 0xFF},
        links_color = ui.Color {0x18, 0xFF, 0xFF, 0xFF},
        functions_color = ui.Color {0x44, 0x8A, 0xFF, 0xFF},
        keywords_color = ui.Color {0xFF, 0x52, 0x52, 0xFF},
        tags_color = ui.Color {0xFF, 0x52, 0x52, 0xFF},
        strings_color = ui.Color {0xFF, 0xCA, 0x28, 0xFF},
        operators_color = ui.Color {0x18, 0xFF, 0xFF, 0xFF},
        attributes_color = ui.Color {0xFF, 0xCA, 0x28, 0xFF},
        numbers_color = ui.Color {0xFF, 0x70, 0x43, 0xFF},
        parameters_color = ui.Color {0xFF, 0x70, 0x43, 0xFF},
    }
}

// Loads a theme from a Lua file that returns `{ name = string, colors = { <role> = "#RRGGBB[AA]" } }`.
// Keys are role ids; the old display labels are accepted too. A role the file
// does not name keeps the built-in color, so a partial theme is valid. On any
// failure the built-in theme is returned.
load :: proc(path: string) -> (Theme, bool) {
    root, status, message := luaconf.eval_file(path, context.temp_allocator)
    switch status {
    case .Ok:
    case .Missing:
        log.warnf("Cannot read theme %q: the file does not exist", path)
        return theme_default(), false
    case .Failed:
        log.warnf("Cannot load theme: %s", message)
        return theme_default(), false
    }
    return from_value(root, path)
}

// Loads a theme from the JSON shape older versions wrote. Only the converter
// reads it.
load_json :: proc(path: string) -> (Theme, bool) {
    data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
    if read_err != nil {
        log.warnf("Cannot read theme %q: %v", path, read_err)
        return theme_default(), false
    }
    root, parse_err := json.parse(data, allocator = context.temp_allocator)
    if parse_err != .None {
        log.warnf("Cannot parse theme %q: %v", path, parse_err)
        return theme_default(), false
    }
    return from_value(root, path)
}

// The built-in theme with an owned name, so destroy can always free it.
@(private = "file")
theme_default :: proc() -> Theme {
    theme := mjolnir()
    theme.name = strings.clone(theme.name)
    return theme
}

// Reads a theme from the value tree of a theme file.
@(private = "file")
from_value :: proc(root: json.Value, path: string) -> (Theme, bool) {
    theme := theme_default()
    obj, ok := root.(json.Object)
    if !ok {
        log.warnf("Theme %q: root is not a table", path)
        return theme, false
    }

    if name, has_name := obj["name"].(json.String); has_name {
        delete(theme.name)
        theme.name = strings.clone(string(name))
    }

    colors, has_colors := obj["colors"].(json.Object)
    if !has_colors {
        log.warnf("Theme %q: missing \"colors\" table", path)
        return theme, false
    }

    for key, value in colors {
        hex, is_string := value.(json.String)
        if !is_string {
            log.warnf("Theme %q: color %q is not a string", path, key)
            continue
        }
        color, color_ok := parse_hex(string(hex))
        if !color_ok {
            log.warnf("Theme %q: invalid color %q for %q", path, hex, key)
            continue
        }
        if !assign_color(&theme, key, color) {
            log.warnf("Theme %q: unknown color key %q", path, key)
        }
    }

    return theme, true
}

// Resolves a short color-role id (as referenced by plugins via thor.theme.*) to
// the theme's current color. Unknown roles fall back to the foreground, so a
// plugin can never leave text uncolored by accident.
role_color :: proc(theme: Theme, role: string) -> ui.Color {
    theme := theme
    for entry in COLORS {
        if entry.role == role {
            return theme_color_field(&theme, entry.offset)^
        }
    }
    return theme.foreground
}

// Frees a theme's owned allocations. Pairs with load.
destroy :: proc(theme: ^Theme) {
    delete(theme.name)
    theme.name = ""
}

parse_hex :: proc(value: string) -> (ui.Color, bool) {
    if !strings.has_prefix(value, "#") {
        return ui.Color {}, false
    }

    hex := value[1:]
    if len(hex) != 6 && len(hex) != 8 {
        return ui.Color {}, false
    }

    // parse_uint takes digit separators and a sign, so "#ff_f00" would pass.
    for i in 0 ..< len(hex) {
        switch hex[i] {
        case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
        case:
            return ui.Color {}, false
        }
    }

    parsed, ok := strconv.parse_uint(hex, 16)
    if !ok {
        return ui.Color {}, false
    }

    if len(hex) == 6 {
        return ui.Color {
            byte((parsed >> 16) & 0xFF),
            byte((parsed >> 8) & 0xFF),
            byte(parsed & 0xFF),
            0xFF,
        }, true
    }

    return ui.Color {
        byte((parsed >> 24) & 0xFF),
        byte((parsed >> 16) & 0xFF),
        byte((parsed >> 8) & 0xFF),
        byte(parsed & 0xFF),
    }, true
}

// The index into COLORS of the role `key` names, by role id or display label;
// -1 for an unknown key.
color_index :: proc(key: string) -> int {
    for entry, i in COLORS {
        if entry.role == key || entry.key == key {
            return i
        }
    }
    return -1
}

// The color field `key` names (role id or display label), nil for an unknown key.
color_ptr :: proc(theme: ^Theme, key: string) -> ^ui.Color {
    i := color_index(key)
    if i < 0 {
        return nil
    }
    return theme_color_field(theme, COLORS[i].offset)
}

// The color field of COLORS[index].
color_at :: proc(theme: ^Theme, index: int) -> ^ui.Color {
    return theme_color_field(theme, COLORS[index].offset)
}

@(private = "file")
theme_color_field :: proc(theme: ^Theme, offset: uintptr) -> ^ui.Color {
    return cast(^ui.Color) (uintptr(theme) + offset)
}

assign_color :: proc(theme: ^Theme, key: string, color: ui.Color) -> bool {
    field := color_ptr(theme, key)
    if field == nil {
        return false
    }
    field^ = color
    return true
}

// The color `key` names; ok is false for an unknown key.
color :: proc(theme: ^Theme, key: string) -> (color: ui.Color, ok: bool) {
    field := color_ptr(theme, key)
    if field == nil {
        return {}, false
    }
    return field^, true
}

@(private = "file")
HEX_DIGITS := "0123456789ABCDEF"

// "#RRGGBB", or "#RRGGBBAA" when the color is not opaque. Uppercase, as the
// shipped themes are written.
to_hex :: proc(color: ui.Color, allocator := context.temp_allocator) -> string {
    buf: [9]u8
    buf[0] = '#'
    n := 1
    for value in ([]u8 {color.r, color.g, color.b}) {
        buf[n] = HEX_DIGITS[value >> 4]
        buf[n + 1] = HEX_DIGITS[value & 0xF]
        n += 2
    }
    if color.a != 0xFF {
        buf[n] = HEX_DIGITS[color.a >> 4]
        buf[n + 1] = HEX_DIGITS[color.a & 0xF]
        n += 2
    }
    return strings.clone(string(buf[:n]), allocator)
}

// The Lua source save writes: roles in COLORS order, one comment per group.
encode :: proc(theme: Theme, allocator := context.temp_allocator) -> string {
    builder := strings.builder_make(allocator)
    strings.write_string(&builder, "-- Thor theme. A color is \"#RRGGBB\" or \"#RRGGBBAA\".\n")
    strings.write_string(&builder, "-- A role this file does not name keeps the Mjolnir color.\n\n")
    strings.write_string(&builder, "return {\n    name = ")
    strings.write_string(&builder, luaconf.quote(theme.name, context.temp_allocator))
    strings.write_string(&builder, ",\n    colors = {\n")
    palette := theme
    for entry, i in COLORS {
        if i == 0 || entry.group != COLORS[i - 1].group {
            if i > 0 {
                strings.write_string(&builder, "\n")
            }
            strings.write_string(&builder, "        -- ")
            strings.write_string(&builder, GROUP_LABELS[entry.group])
            strings.write_string(&builder, "\n")
        }
        strings.write_string(&builder, "        ")
        strings.write_string(&builder, entry.role)
        strings.write_string(&builder, " = \"")
        strings.write_string(&builder, to_hex(color_at(&palette, i)^))
        strings.write_string(&builder, "\",\n")
    }
    strings.write_string(&builder, "    },\n}\n")
    return strings.to_string(builder)
}

// Writes `theme` as the Lua load reads. Missing parent directories are created,
// so a first write to user/ lands.
save :: proc(theme: Theme, path: string) -> bool {
    text := encode(theme)
    if !theme_make_dirs(path) {
        return false
    }
    if err := atomicfile.write(path, transmute([]u8)text); err != nil {
        log.errorf("Cannot write theme %q: %v", path, err)
        return false
    }
    return true
}

// Creates the directories above `path`, one level at a time — os.make_directory
// makes only one, and user/themes needs user/ first. An existing directory is not
// an error.
@(private = "file")
theme_make_dirs :: proc(path: string) -> bool {
    for i in 0 ..< len(path) {
        if path[i] != '/' && path[i] != '\\' {
            continue
        }
        dir := path[:i]
        if dir == "" || os.exists(dir) {
            continue
        }
        if err := os.make_directory(dir); err != nil && !os.exists(dir) {
            log.errorf("Cannot create directory %q: %v", dir, err)
            return false
        }
    }
    return true
}
