package ui

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

Theme :: struct {
    name:                   string,
    background:             rl.Color,
    foreground:             rl.Color,
    text:                   rl.Color,
    selection_background:   rl.Color,
    selection_foreground:   rl.Color,
    buttons:                rl.Color,
    second_background:      rl.Color,
    disabled:               rl.Color,
    contrast:               rl.Color,
    active:                 rl.Color,
    border:                 rl.Color,
    highlight:              rl.Color,
    tree:                   rl.Color,
    notifications:          rl.Color,
    accent_color:           rl.Color,
    excluded_files_color:   rl.Color,
    success_color:          rl.Color,
    warning_color:          rl.Color,
    info_color:             rl.Color,
    danger_color:           rl.Color,
    submodule_color:        rl.Color,
    conflict_color:         rl.Color,
    accent_secondary_color: rl.Color,
    muted_color:            rl.Color,
    primary_text_color:     rl.Color,
    error_color:            rl.Color,
    comments_color:         rl.Color,
    variables_color:        rl.Color,
    links_color:            rl.Color,
    functions_color:        rl.Color,
    keywords_color:         rl.Color,
    tags_color:             rl.Color,
    strings_color:          rl.Color,
    operators_color:        rl.Color,
    attributes_color:       rl.Color,
    numbers_color:          rl.Color,
    parameters_color:       rl.Color,
}

// Which part of the UI a color role belongs to. Orders THEME_COLORS and names the
// fold groups the Settings modal builds from it.
Theme_Color_Group :: enum {
    Surfaces,
    Text,
    Status,
    Syntax,
}

THEME_GROUP_LABELS := [Theme_Color_Group]string {
    .Surfaces = "Surfaces",
    .Text     = "Text",
    .Status   = "Status",
    .Syntax   = "Syntax",
}

// One color role: the key a theme file names it by, and the offset of its field.
Theme_Color_Entry :: struct {
    key:    string,
    offset: uintptr,
    group:  Theme_Color_Group,
}

// Every color role, grouped and in the order a written theme lists them. The one
// key-to-field mapping in the program: theme_assign_color, theme_color, theme_save
// and the Settings rows all read it.
THEME_COLORS := [?]Theme_Color_Entry {
    {"Background",             offset_of(Theme, background),             .Surfaces},
    {"Second Background",      offset_of(Theme, second_background),      .Surfaces},
    {"Contrast",               offset_of(Theme, contrast),               .Surfaces},
    {"Buttons",                offset_of(Theme, buttons),                .Surfaces},
    {"Active",                 offset_of(Theme, active),                 .Surfaces},
    {"Highlight",              offset_of(Theme, highlight),              .Surfaces},
    {"Border",                 offset_of(Theme, border),                 .Surfaces},
    {"Notifications",          offset_of(Theme, notifications),          .Surfaces},
    {"Tree",                   offset_of(Theme, tree),                   .Surfaces},
    {"Selection Background",   offset_of(Theme, selection_background),   .Surfaces},
    {"Accent Color",           offset_of(Theme, accent_color),           .Surfaces},
    {"Accent Secondary Color", offset_of(Theme, accent_secondary_color), .Surfaces},

    {"Text",                   offset_of(Theme, text),                   .Text},
    {"Primary Text Color",     offset_of(Theme, primary_text_color),     .Text},
    {"Foreground",             offset_of(Theme, foreground),             .Text},
    {"Muted Color",            offset_of(Theme, muted_color),            .Text},
    {"Disabled",               offset_of(Theme, disabled),               .Text},
    {"Selection Foreground",   offset_of(Theme, selection_foreground),   .Text},
    {"Excluded Files Color",   offset_of(Theme, excluded_files_color),   .Text},
    {"Links Color",            offset_of(Theme, links_color),            .Text},

    {"Success Color",          offset_of(Theme, success_color),          .Status},
    {"Warning Color",          offset_of(Theme, warning_color),          .Status},
    {"Info Color",             offset_of(Theme, info_color),             .Status},
    {"Danger Color",           offset_of(Theme, danger_color),           .Status},
    {"Error Color",            offset_of(Theme, error_color),            .Status},
    {"Conflict Color",         offset_of(Theme, conflict_color),         .Status},
    {"Submodule Color",        offset_of(Theme, submodule_color),        .Status},

    {"Comments Color",         offset_of(Theme, comments_color),         .Syntax},
    {"Keywords Color",         offset_of(Theme, keywords_color),         .Syntax},
    {"Functions Color",        offset_of(Theme, functions_color),        .Syntax},
    {"Strings Color",          offset_of(Theme, strings_color),          .Syntax},
    {"Numbers Color",          offset_of(Theme, numbers_color),          .Syntax},
    {"Operators Color",        offset_of(Theme, operators_color),        .Syntax},
    {"Variables Color",        offset_of(Theme, variables_color),        .Syntax},
    {"Parameters Color",       offset_of(Theme, parameters_color),       .Syntax},
    {"Attributes Color",       offset_of(Theme, attributes_color),       .Syntax},
    {"Tags Color",             offset_of(Theme, tags_color),             .Syntax},
}

theme_material_deep_ocean :: proc() -> Theme {
    return Theme {
        name = "Material Deep ocean",
        background = rl.Color {0x0F, 0x11, 0x1A, 0xFF},
        foreground = rl.Color {0x8F, 0x93, 0xA2, 0xFF},
        text = rl.Color {0x4B, 0x52, 0x6D, 0xFF},
        selection_background = rl.Color {0x71, 0x7C, 0xB4, 0x80},
        selection_foreground = rl.Color {0xFF, 0xFF, 0xFF, 0xFF},
        buttons = rl.Color {0x19, 0x1A, 0x21, 0xFF},
        second_background = rl.Color {0x18, 0x1A, 0x1F, 0xFF},
        disabled = rl.Color {0x46, 0x4B, 0x5D, 0xFF},
        contrast = rl.Color {0x09, 0x0B, 0x10, 0xFF},
        active = rl.Color {0x1A, 0x1C, 0x25, 0xFF},
        border = rl.Color {0x0F, 0x11, 0x1A, 0xFF},
        highlight = rl.Color {0x1F, 0x22, 0x33, 0xFF},
        tree = rl.Color {0x71, 0x7C, 0xB4, 0x30},
        notifications = rl.Color {0x09, 0x0B, 0x10, 0xFF},
        accent_color = rl.Color {0x84, 0xFF, 0xFF, 0xFF},
        excluded_files_color = rl.Color {0x29, 0x2D, 0x3E, 0xFF},
        success_color = rl.Color {0xC3, 0xE8, 0x8D, 0xFF},
        warning_color = rl.Color {0xFF, 0xCB, 0x6B, 0xFF},
        info_color = rl.Color {0x82, 0xAA, 0xFF, 0xFF},
        danger_color = rl.Color {0xF0, 0x71, 0x78, 0xFF},
        submodule_color = rl.Color {0xC7, 0x92, 0xEA, 0xFF},
        conflict_color = rl.Color {0xF7, 0x8C, 0x6C, 0xFF},
        accent_secondary_color = rl.Color {0x89, 0xDD, 0xFF, 0xFF},
        muted_color = rl.Color {0x71, 0x7C, 0xB4, 0xFF},
        primary_text_color = rl.Color {0xEE, 0xFF, 0xFF, 0xFF},
        error_color = rl.Color {0xFF, 0x53, 0x70, 0xFF},
        comments_color = rl.Color {0x71, 0x7C, 0xB4, 0xFF},
        variables_color = rl.Color {0xEE, 0xFF, 0xFF, 0xFF},
        links_color = rl.Color {0x80, 0xCB, 0xC4, 0xFF},
        functions_color = rl.Color {0x82, 0xAA, 0xFF, 0xFF},
        keywords_color = rl.Color {0xC7, 0x92, 0xEA, 0xFF},
        tags_color = rl.Color {0xF0, 0x71, 0x78, 0xFF},
        strings_color = rl.Color {0xC3, 0xE8, 0x8D, 0xFF},
        operators_color = rl.Color {0x89, 0xDD, 0xFF, 0xFF},
        attributes_color = rl.Color {0xFF, 0xCB, 0x6B, 0xFF},
        numbers_color = rl.Color {0xF7, 0x8C, 0x6C, 0xFF},
        parameters_color = rl.Color {0xF7, 0x8C, 0x6C, 0xFF},
    }
}

// The built-in fallback theme: used as the base every loaded theme overlays, and
// returned whole when a theme file is missing or malformed. Mirrors
// assets/themes/mjolnir.json.
theme_mjolnir :: proc() -> Theme {
    return Theme {
        name = "Mjolnir",
        background = rl.Color {0x1A, 0x1C, 0x23, 0xFF},
        foreground = rl.Color {0xD0, 0xD4, 0xE0, 0xFF},
        text = rl.Color {0xEC, 0xEF, 0xF1, 0xFF},
        selection_background = rl.Color {0x3F, 0x51, 0xB5, 0x70},
        selection_foreground = rl.Color {0xFF, 0xFF, 0xFF, 0xFF},
        buttons = rl.Color {0x27, 0x2A, 0x33, 0xFF},
        second_background = rl.Color {0x22, 0x25, 0x2C, 0xFF},
        disabled = rl.Color {0x5C, 0x62, 0x70, 0xFF},
        contrast = rl.Color {0x13, 0x15, 0x19, 0xFF},
        active = rl.Color {0x2C, 0x30, 0x3A, 0xFF},
        border = rl.Color {0x1C, 0x1F, 0x26, 0xFF},
        highlight = rl.Color {0x33, 0x38, 0x46, 0xFF},
        tree = rl.Color {0x3F, 0x4A, 0x5A, 0x50},
        notifications = rl.Color {0x13, 0x15, 0x19, 0xFF},
        accent_color = rl.Color {0x4F, 0xC3, 0xF7, 0xFF},
        excluded_files_color = rl.Color {0x2E, 0x32, 0x3C, 0xFF},
        success_color = rl.Color {0x69, 0xF0, 0xAE, 0xFF},
        warning_color = rl.Color {0xFF, 0xCA, 0x28, 0xFF},
        info_color = rl.Color {0x44, 0x8A, 0xFF, 0xFF},
        danger_color = rl.Color {0xFF, 0x52, 0x52, 0xFF},
        submodule_color = rl.Color {0xCE, 0x93, 0xD8, 0xFF},
        conflict_color = rl.Color {0xFF, 0x70, 0x43, 0xFF},
        accent_secondary_color = rl.Color {0x18, 0xFF, 0xFF, 0xFF},
        muted_color = rl.Color {0x90, 0xA4, 0xAE, 0xFF},
        primary_text_color = rl.Color {0xEC, 0xEF, 0xF1, 0xFF},
        error_color = rl.Color {0xFF, 0x52, 0x52, 0xFF},
        comments_color = rl.Color {0x61, 0x6A, 0x7A, 0xFF},
        variables_color = rl.Color {0xEC, 0xEF, 0xF1, 0xFF},
        links_color = rl.Color {0x18, 0xFF, 0xFF, 0xFF},
        functions_color = rl.Color {0x44, 0x8A, 0xFF, 0xFF},
        keywords_color = rl.Color {0xFF, 0x52, 0x52, 0xFF},
        tags_color = rl.Color {0xFF, 0x52, 0x52, 0xFF},
        strings_color = rl.Color {0xFF, 0xCA, 0x28, 0xFF},
        operators_color = rl.Color {0x18, 0xFF, 0xFF, 0xFF},
        attributes_color = rl.Color {0xFF, 0xCA, 0x28, 0xFF},
        numbers_color = rl.Color {0xFF, 0x70, 0x43, 0xFF},
        parameters_color = rl.Color {0xFF, 0x70, 0x43, 0xFF},
    }
}

// Loads a theme from a JSON file shaped `{ "name": string, "colors": { <key>: "#RRGGBB[AA]" } }`.
// Keys are the display names accepted by theme_assign_color. Unspecified keys keep the
// built-in default, so partial themes are valid. On any failure the default is returned.
theme_load :: proc(path: string) -> (Theme, bool) {
    theme := theme_mjolnir()
    // Own the name on every path so theme_destroy can always free it.
    theme.name = strings.clone(theme.name)

    data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
    if read_err != nil {
        log.warnf("Cannot read theme %q: %v", path, read_err)
        return theme, false
    }

    root, parse_err := json.parse(data, allocator = context.temp_allocator)
    if parse_err != .None {
        log.warnf("Cannot parse theme %q: %v", path, parse_err)
        return theme, false
    }

    obj, ok := root.(json.Object)
    if !ok {
        log.warnf("Theme %q: root is not an object", path)
        return theme, false
    }

    if name, has_name := obj["name"].(json.String); has_name {
        delete(theme.name)
        theme.name = strings.clone(string(name))
    }

    colors, has_colors := obj["colors"].(json.Object)
    if !has_colors {
        log.warnf("Theme %q: missing \"colors\" object", path)
        return theme, false
    }

    for key, value in colors {
        hex, is_string := value.(json.String)
        if !is_string {
            continue
        }
        color, color_ok := parse_hex_color(string(hex))
        if !color_ok {
            log.warnf("Theme %q: invalid color %q for %q", path, hex, key)
            continue
        }
        if !theme_assign_color(&theme, key, color) {
            log.warnf("Theme %q: unknown color key %q", path, key)
        }
    }

    return theme, true
}

// Resolves a short color-role id (as referenced by plugins via thor.theme.*) to
// the theme's current color. Unknown roles fall back to the foreground, so a
// plugin can never leave text uncolored by accident.
theme_role_color :: proc(theme: Theme, role: string) -> rl.Color {
    switch role {
    case "background":       return theme.background
    case "foreground":       return theme.foreground
    case "keywords":         return theme.keywords_color
    case "functions":        return theme.functions_color
    case "strings":          return theme.strings_color
    case "operators":        return theme.operators_color
    case "comments":         return theme.comments_color
    case "numbers":          return theme.numbers_color
    case "parameters":       return theme.parameters_color
    case "attributes":       return theme.attributes_color
    case "variables":        return theme.variables_color
    case "tags":             return theme.tags_color
    case "links":            return theme.links_color
    case "warning":          return theme.warning_color
    case "conflict":         return theme.conflict_color
    case "submodule":        return theme.submodule_color
    case "accent_secondary": return theme.accent_secondary_color
    case "info":             return theme.info_color
    case "danger":           return theme.danger_color
    case "success":          return theme.success_color
    case "muted":            return theme.muted_color
    case "accent":           return theme.accent_color
    case "error":            return theme.error_color
    }
    return theme.foreground
}

// Frees a theme's owned allocations. Pairs with theme_load.
theme_destroy :: proc(theme: ^Theme) {
    delete(theme.name)
    theme.name = ""
}

parse_hex_color :: proc(value: string) -> (rl.Color, bool) {
    if !strings.has_prefix(value, "#") {
        return rl.Color {}, false
    }

    hex := value[1:]
    if len(hex) != 6 && len(hex) != 8 {
        return rl.Color {}, false
    }

    // parse_uint takes digit separators and a sign, so "#ff_f00" would pass.
    for i in 0 ..< len(hex) {
        switch hex[i] {
        case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
        case:
            return rl.Color {}, false
        }
    }

    parsed, ok := strconv.parse_uint(hex, 16)
    if !ok {
        return rl.Color {}, false
    }

    if len(hex) == 6 {
        return rl.Color {
            byte((parsed >> 16) & 0xFF),
            byte((parsed >> 8) & 0xFF),
            byte(parsed & 0xFF),
            0xFF,
        }, true
    }

    return rl.Color {
        byte((parsed >> 24) & 0xFF),
        byte((parsed >> 16) & 0xFF),
        byte((parsed >> 8) & 0xFF),
        byte(parsed & 0xFF),
    }, true
}

// The color field `key` names, nil for an unknown key.
theme_color_ptr :: proc(theme: ^Theme, key: string) -> ^rl.Color {
    for entry in THEME_COLORS {
        if entry.key == key {
            return theme_color_field(theme, entry.offset)
        }
    }
    return nil
}

// The color field of THEME_COLORS[index].
theme_color_at :: proc(theme: ^Theme, index: int) -> ^rl.Color {
    return theme_color_field(theme, THEME_COLORS[index].offset)
}

@(private = "file")
theme_color_field :: proc(theme: ^Theme, offset: uintptr) -> ^rl.Color {
    return cast(^rl.Color) (uintptr(theme) + offset)
}

theme_assign_color :: proc(theme: ^Theme, key: string, color: rl.Color) -> bool {
    field := theme_color_ptr(theme, key)
    if field == nil {
        return false
    }
    field^ = color
    return true
}

// The color `key` names; ok is false for an unknown key.
theme_color :: proc(theme: ^Theme, key: string) -> (color: rl.Color, ok: bool) {
    field := theme_color_ptr(theme, key)
    if field == nil {
        return {}, false
    }
    return field^, true
}

@(private = "file")
HEX_DIGITS := "0123456789ABCDEF"

// "#RRGGBB", or "#RRGGBBAA" when the color is not opaque. Uppercase, as the
// shipped themes are written.
color_to_hex :: proc(color: rl.Color, allocator := context.temp_allocator) -> string {
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

// Writes `theme` as the JSON theme_load reads, keys in THEME_COLORS order. Map
// iteration is unordered, so the object is built by hand to keep the file stable.
// Missing parent directories are created, so a first write to user/ lands.
theme_save :: proc(theme: Theme, path: string) -> bool {
    name, marshal_err := json.marshal(theme.name, allocator = context.temp_allocator)
    if marshal_err != nil {
        log.errorf("Cannot encode theme name %q: %v", theme.name, marshal_err)
        return false
    }

    builder := strings.builder_make(context.temp_allocator)
    strings.write_string(&builder, "{\n    \"name\": ")
    strings.write_bytes(&builder, name)
    strings.write_string(&builder, ",\n    \"colors\": {\n")
    palette := theme
    for entry, i in THEME_COLORS {
        strings.write_string(&builder, "        \"")
        strings.write_string(&builder, entry.key)
        strings.write_string(&builder, "\": \"")
        strings.write_string(&builder, color_to_hex(theme_color_at(&palette, i)^))
        strings.write_string(&builder, i == len(THEME_COLORS) - 1 ? "\"\n" : "\",\n")
    }
    strings.write_string(&builder, "    }\n}\n")

    if !theme_make_dirs(path) {
        return false
    }
    if err := os.write_entire_file(path, builder.buf[:]); err != nil {
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
