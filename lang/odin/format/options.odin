// The formatter's option schema, read from `<workspace>/.thor/odin-formatter.json`
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
		newline_style                = .CRLF,
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
