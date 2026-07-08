package ui

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
    green_color:            rl.Color,
    yellow_color:           rl.Color,
    blue_color:             rl.Color,
    red_color:              rl.Color,
    purple_color:           rl.Color,
    orange_color:           rl.Color,
    cyan_color:             rl.Color,
    gray_color:             rl.Color,
    white_black_color:      rl.Color,
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

theme_material_deep_ocean :: proc() -> Theme {
    return Theme {
        name = "Deep ocean",
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
        green_color = rl.Color {0xC3, 0xE8, 0x8D, 0xFF},
        yellow_color = rl.Color {0xFF, 0xCB, 0x6B, 0xFF},
        blue_color = rl.Color {0x82, 0xAA, 0xFF, 0xFF},
        red_color = rl.Color {0xF0, 0x71, 0x78, 0xFF},
        purple_color = rl.Color {0xC7, 0x92, 0xEA, 0xFF},
        orange_color = rl.Color {0xF7, 0x8C, 0x6C, 0xFF},
        cyan_color = rl.Color {0x89, 0xDD, 0xFF, 0xFF},
        gray_color = rl.Color {0x71, 0x7C, 0xB4, 0xFF},
        white_black_color = rl.Color {0xEE, 0xFF, 0xFF, 0xFF},
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

theme_load_from_file :: proc(path: string) -> Theme {
    theme := theme_material_deep_ocean()

    data, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil {
        log.warnf("Failed to read theme file %q, using built-in %q", path, theme.name)
        return theme
    }

    text := string(data)
    saw_name := false

    for raw_line in strings.split_lines_iterator(&text) {
        line := strings.trim_space(raw_line)
        if line == "" {
            continue
        }

        if !saw_name {
            theme.name = line
            saw_name = true
            continue
        }

        separator := strings.index_byte(line, ':')
        if separator < 0 {
            log.warnf("Ignoring malformed theme line %q in %q", line, path)
            continue
        }

        key := strings.trim_space(line[:separator])
        value := strings.trim_space(line[separator+1:])
        color, ok := parse_hex_color(value)
        if !ok {
            log.warnf("Ignoring invalid theme color %q for key %q in %q", value, key, path)
            continue
        }

        if !theme_assign_color(&theme, key, color) {
            log.warnf("Ignoring unknown theme key %q in %q", key, path)
        }
    }

    return theme
}

parse_hex_color :: proc(value: string) -> (rl.Color, bool) {
    if !strings.has_prefix(value, "#") {
        return rl.Color {}, false
    }

    hex := value[1:]
    if len(hex) != 6 && len(hex) != 8 {
        return rl.Color {}, false
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

theme_assign_color :: proc(theme: ^Theme, key: string, color: rl.Color) -> bool {
    switch key {
    case "Background":
        theme.background = color
    case "Foreground":
        theme.foreground = color
    case "Text":
        theme.text = color
    case "Selection Background":
        theme.selection_background = color
    case "Selection Foreground":
        theme.selection_foreground = color
    case "Buttons":
        theme.buttons = color
    case "Second Background":
        theme.second_background = color
    case "Disabled":
        theme.disabled = color
    case "Contrast":
        theme.contrast = color
    case "Active":
        theme.active = color
    case "Border":
        theme.border = color
    case "Highlight":
        theme.highlight = color
    case "Tree":
        theme.tree = color
    case "Notifications":
        theme.notifications = color
    case "Accent Color":
        theme.accent_color = color
    case "Excluded Files Color":
        theme.excluded_files_color = color
    case "Green Color":
        theme.green_color = color
    case "Yellow Color":
        theme.yellow_color = color
    case "Blue Color":
        theme.blue_color = color
    case "Red Color":
        theme.red_color = color
    case "Purple Color":
        theme.purple_color = color
    case "Orange Color":
        theme.orange_color = color
    case "Cyan Color":
        theme.cyan_color = color
    case "Gray Color":
        theme.gray_color = color
    case "White/Black Color":
        theme.white_black_color = color
    case "Error Color":
        theme.error_color = color
    case "Comments Color":
        theme.comments_color = color
    case "Variables Color":
        theme.variables_color = color
    case "Links Color":
        theme.links_color = color
    case "Functions Color":
        theme.functions_color = color
    case "Keywords Color":
        theme.keywords_color = color
    case "Tags Color":
        theme.tags_color = color
    case "Strings Color":
        theme.strings_color = color
    case "Operators Color":
        theme.operators_color = color
    case "Attributes Color":
        theme.attributes_color = color
    case "Numbers Color":
        theme.numbers_color = color
    case "Parameters Color":
        theme.parameters_color = color
    case:
        return false
    }

    return true
}
