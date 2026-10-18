package snippet

import "core:testing"

// The grammar in one pass: a bare tabstop, a placeholder with a default, a
// choice, a mirror of an earlier stop, an escape, and the exit stop last.
@(test)
test_parse_grammar :: proc(t: ^testing.T) {
    snip := parse(`fn(${1:name}, ${2|a,b|}) \$$1$0`)
    defer destroy(&snip)

    testing.expect_value(t, snip.text, "fn(name, a) $name")
    // Visit order: 1, its mirror, 2, then 0.
    testing.expect_value(t, len(snip.stops), 4)
    if len(snip.stops) != 4 {
        return
    }
    testing.expect_value(t, snip.stops[0].index, 1)
    testing.expect_value(t, snip.stops[0].start, 3)
    testing.expect_value(t, snip.stops[0].end, 7)
    testing.expect_value(t, snip.stops[1].index, 1)
    testing.expect_value(t, snip.stops[1].end - snip.stops[1].start, 4)
    testing.expect_value(t, snip.stops[2].index, 2)
    testing.expect_value(t, snip.stops[3].index, 0)
    testing.expect_value(t, snip.stops[3].start, len(snip.text))
}

// A variable with no value takes its written default. An unclosed construct is
// text, not a stop.
@(test)
test_parse_variables :: proc(t: ^testing.T) {
    snip := parse("${TM_LINE_NUMBER}:${NOPE:fallback}:${1", Vars{line = 7})
    defer destroy(&snip)

    testing.expect_value(t, snip.text, "7:fallback:${1")
    testing.expect_value(t, len(snip.stops), 0)
}

// An unclosed placeholder stays as written, with what was inside it.
@(test)
test_unclosed_placeholder_is_text :: proc(t: ^testing.T) {
    snip := parse("a ${1:foo $2")
    defer destroy(&snip)

    testing.expect_value(t, snip.text, "a ${1:foo ")
    testing.expect_value(t, len(snip.stops), 1)

    unclosed_var := parse("x ${NOPE:bar")
    defer destroy(&unclosed_var)
    testing.expect_value(t, unclosed_var.text, "x ${NOPE:bar")
}

// A stop knows how many placeholders are around it.
@(test)
test_nested_stop_depth :: proc(t: ^testing.T) {
    snip := parse("${1:a ${2:b ${3:c}}}")
    defer destroy(&snip)

    testing.expect_value(t, snip.text, "a b c")
    testing.expect_value(t, len(snip.stops), 3)
    if len(snip.stops) != 3 {
        return
    }
    testing.expect_value(t, snip.stops[0].depth, 0)
    testing.expect_value(t, snip.stops[1].depth, 1)
    testing.expect_value(t, snip.stops[2].depth, 2)
}

@(test)
test_file_and_clipboard_variables :: proc(t: ^testing.T) {
    vars := Vars {
        filename  = "src/main.odin",
        workspace = "work/thor",
        clipboard = "pasted",
    }
    snip := parse("$TM_FILEPATH|$TM_FILENAME|$TM_FILENAME_BASE|$CLIPBOARD|$WORKSPACE_NAME", vars)
    defer destroy(&snip)
    testing.expect_value(t, snip.text, "src/main.odin|main.odin|main|pasted|thor")
}

@(test)
test_date_variables :: proc(t: ^testing.T) {
    vars := Vars {
        has_time   = true,
        year       = 2026,
        month      = 3,
        day        = 9,
        weekday    = 1,
        hour       = 7,
        minute     = 5,
        second     = 2,
        unix       = 1773039902,
        utc_offset = -330,
    }
    snip := parse(
        "$CURRENT_YEAR-$CURRENT_MONTH-$CURRENT_DATE $CURRENT_HOUR:$CURRENT_MINUTE:$CURRENT_SECOND " +
        "$CURRENT_YEAR_SHORT $CURRENT_MONTH_NAME $CURRENT_MONTH_NAME_SHORT $CURRENT_DAY_NAME " +
        "$CURRENT_DAY_NAME_SHORT $CURRENT_SECONDS_UNIX $CURRENT_TIMEZONE_OFFSET",
        vars,
    )
    defer destroy(&snip)
    testing.expect_value(
        t,
        snip.text,
        "2026-03-09 07:05:02 26 March Mar Monday Mon 1773039902 -05:30",
    )

    // With no clock the date variables take their default.
    none := parse("${CURRENT_YEAR:then}")
    defer destroy(&none)
    testing.expect_value(t, none.text, "then")
}

@(test)
test_choice_keeps_every_alternative :: proc(t: ^testing.T) {
    snip := parse(`${1|one,t\,wo,three|}`)
    defer destroy(&snip)

    testing.expect_value(t, snip.text, "one")
    testing.expect_value(t, len(snip.stops), 1)
    testing.expect_value(t, len(snip.choices), 3)
    if len(snip.stops) != 1 || len(snip.choices) != 3 {
        return
    }
    testing.expect_value(t, snip.stops[0].choice_count, 3)
    testing.expect_value(t, snip.choices[1], "t,wo")
    testing.expect_value(t, snip.choices[2], "three")
}

@(test)
test_variable_transform :: proc(t: ^testing.T) {
    vars := Vars{filename = "my_file-name.odin"}

    upper := parse("${TM_FILENAME_BASE/(.*)/${1:/upcase}/}", vars)
    defer destroy(&upper)
    testing.expect_value(t, upper.text, "MY_FILE-NAME")

    pascal := parse("${TM_FILENAME_BASE/(.*)/${1:/pascalcase}/}", vars)
    defer destroy(&pascal)
    testing.expect_value(t, pascal.text, "MyFileName")

    camel := parse("${TM_FILENAME_BASE/(.*)/${1:/camelcase}/}", vars)
    defer destroy(&camel)
    testing.expect_value(t, camel.text, "myFileName")

    // Without `g` only the first match changes.
    first := parse("${TM_FILENAME_BASE/[_-]/ /}", vars)
    defer destroy(&first)
    testing.expect_value(t, first.text, "my file-name")

    every := parse("${TM_FILENAME_BASE/[_-]/ /g}", vars)
    defer destroy(&every)
    testing.expect_value(t, every.text, "my file name")
}

@(test)
test_transform_format :: proc(t: ^testing.T) {
    swap := transform_apply("key=value", Transform{pattern = "(\\w+)=(\\w+)", format = "$2: ${1}"})
    testing.expect_value(t, swap, "value: key")

    cond := Transform{pattern = "(a)?(b)", format = "${1:+has}${1:?:no}-${1:-none}"}
    testing.expect_value(t, transform_apply("ab", cond), "has-a")
    testing.expect_value(t, transform_apply("b", cond), "no-none")

    icase := Transform{pattern = "x", format = "y", icase = true, global = true}
    testing.expect_value(t, transform_apply("xXz", icase), "yyz")

    // No match and a bad pattern keep the text.
    testing.expect_value(t, transform_apply("abc", Transform{pattern = "z", format = "q"}), "abc")
    testing.expect_value(t, transform_apply("abc", Transform{pattern = "(", format = "q"}), "abc")
}

// A transformed tabstop mirrors the first stop of its number and keeps the
// transform for the live session.
@(test)
test_tabstop_transform :: proc(t: ^testing.T) {
    snip := parse("${1:name} ${1/(.*)/${1:/upcase}/}")
    defer destroy(&snip)

    testing.expect_value(t, snip.text, "name NAME")
    testing.expect_value(t, len(snip.stops), 2)
    testing.expect_value(t, len(snip.transforms), 1)
    if len(snip.stops) != 2 {
        return
    }
    testing.expect_value(t, snip.stops[0].transform, 0)
    testing.expect_value(t, snip.stops[1].transform, 1)
}

@(test)
test_indent_moves_the_stops :: proc(t: ^testing.T) {
    snip := parse("if ${1:cond} {\n\t$0\n}\n\nend")
    defer destroy(&snip)
    indent(&snip, "  ", "    ")

    testing.expect_value(t, snip.text, "if cond {\n      \n  }\n\n  end")
    testing.expect_value(t, len(snip.stops), 2)
    if len(snip.stops) != 2 {
        return
    }
    testing.expect_value(t, snip.text[snip.stops[0].start:snip.stops[0].end], "cond")
    // The exit stop is after the line indent and the unit.
    testing.expect_value(t, snip.stops[1].start, len("if cond {\n      "))
}

// A mirror written before the placeholder that gives its default takes that
// default too, and the stops after it move.
@(test)
test_earlier_mirror_takes_later_default :: proc(t: ^testing.T) {
    snip := parse("$1 = ${1:x}; ${2:y}$0")
    defer destroy(&snip)

    testing.expect_value(t, snip.text, "x = x; y")
    testing.expect_value(t, len(snip.stops), 4)
    if len(snip.stops) != 4 {
        return
    }
    testing.expect_value(t, snip.stops[0].start, 0)
    testing.expect_value(t, snip.stops[0].end, 1)
    testing.expect_value(t, snip.stops[1].start, 4)
    testing.expect_value(t, snip.stops[1].end, 5)
    testing.expect_value(t, snip.stops[2].start, 7)
    testing.expect_value(t, snip.stops[2].end, 8)
    testing.expect_value(t, snip.stops[3].start, 8)
}
