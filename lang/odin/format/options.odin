// The formatter's option schema, read from `<workspace>/.thor/odin-formatter.lua`
// (parsing lives in lang/odin/formatter.odin — this package stays JSON-free).
package odinfmt

Brace_Style :: enum {
    _1TBS,
    Allman,
    Stroustrup,
    K_And_R,
}

// Unspecified means the config file did not name the key — the caller (the
// engine) uses that to decide whether to touch the open file's line ending at
// all, since the printer itself never emits anything but \n (see printer.odin).
Newline_Style :: enum {
    Unspecified,
    LF,
    CRLF,
}

Options :: struct {
    character_width:                  int,
    spaces:                           int,
    newline_limit:                    int,
    tabs:                             bool,
    tabs_width:                       int,
    convert_do:                       bool,
    exp_multiline_composite_literals: bool,
    brace_style:                      Brace_Style,
    indent_cases:                     bool,
    newline_style:                    Newline_Style,
    inline_single_stmt_case:          bool,
    spaces_around_colons:             bool,
    sort_imports:                     bool,
    space_single_line_blocks:         bool,
    align_struct_fields:              bool,
    align_struct_values:              bool,
    align_struct_declarations:        bool,
    align_constant_definitions:       bool,
}

default_options :: proc() -> Options {
    return Options {
        character_width            = 100,
        spaces                     = 4,
        newline_limit              = 2,
        tabs                       = true,
        tabs_width                 = 4,
        convert_do                 = false,
        exp_multiline_composite_literals = false,
        brace_style                = ._1TBS,
        indent_cases                = false,
        newline_style                = .LF,
        inline_single_stmt_case      = false,
        spaces_around_colons         = false,
        sort_imports                 = true,
        space_single_line_blocks     = false,
        align_struct_fields          = true,
        align_struct_values          = true,
        align_struct_declarations    = false,
        align_constant_definitions   = false,
    }
}

// The range each integer option accepts.
@(private)
Int_Range :: struct {
    key:      string,
    offset:   uintptr,
    min, max: int,
}

@(private)
INT_RANGES := [?]Int_Range {
    {"character_width", offset_of(Options, character_width), 20, 1000},
    {"spaces",          offset_of(Options, spaces),          1,  16},
    {"newline_limit",   offset_of(Options, newline_limit),   0,  16},
    {"tabs_width",      offset_of(Options, tabs_width),      1,  16},
}

// Resets every integer option outside its range to the default, and returns
// the keys it reset.
validate_options :: proc(opts: ^Options, allocator := context.allocator) -> []string {
    defaults := default_options()
    reset := make([dynamic]string, allocator)
    for r in INT_RANGES {
        value := cast(^int) (uintptr(opts) + r.offset)
        if value^ < r.min || value^ > r.max {
            value^ = (cast(^int) (uintptr(&defaults) + r.offset))^
            append(&reset, r.key)
        }
    }
    return reset[:]
}
