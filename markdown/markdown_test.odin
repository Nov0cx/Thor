package markdown

import "core:testing"

import ui "../vendor/loom/loom"

// A monospace face of a fixed advance, so a laid-out box has a real width with
// no font atlas: every test below can state where a thing lands.
@(private = "file")
CELL :: f32(10)

@(private = "file")
LINE :: f32(20)

@(private = "file")
fake_metrics :: proc() -> Metrics {
    return Metrics {
        measure = proc(text: string, size: i32, user: rawptr) -> f32 {
            return f32(len(text)) * CELL
        },
        line_height = proc(size: i32, user: rawptr) -> f32 {
            return LINE
        },
    }
}

@(private = "file")
test_palette :: proc() -> Palette {
    return Palette {
        text = {1, 0, 0, 255},
        strong = {2, 0, 0, 255},
        heading = {3, 0, 0, 255},
        code = {4, 0, 0, 255},
        code_bg = {5, 0, 0, 255},
        link = {6, 0, 0, 255},
        quote = {7, 0, 0, 255},
        rule = {8, 0, 0, 255},
        accent = {9, 0, 0, 255},
    }
}

@(private = "file")
lay :: proc(page: ^Page, source: string, avail := f32(600)) {
    layout(page, source, avail, 16, test_palette(), fake_metrics())
}

@(private = "file")
first_url :: proc(page: ^Page) -> string {
    for item in page.items {
        if item.url != "" {
            return item.url
        }
    }
    return ""
}

// Anything that is not a full [text](url) is prose, so nothing in it opens. An
// empty target is a link with nowhere to go, which is the same thing here.
@(test)
test_partial_link_has_no_target :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)

    for source in ([]string{"[docs\n", "[docs]\n", "[docs] (x)\n", "[docs](x\n", "[docs]()\n"}) {
        lay(&page, source)
        testing.expect_value(t, first_url(&page), "")
    }

    // The complete form does resolve, so the cases above fail on their shape and
    // not because the fixture never finds anything.
    lay(&page, "[docs](x)\n")
    testing.expect_value(t, first_url(&page), "x")
}

// The url has to survive parsing and layout: it is what a click opens.
@(test)
test_layout_keeps_link_url :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "see [docs](building.md) here\n")

    found := false
    for item in page.items {
        if item.url == "" {
            continue
        }
        testing.expect_value(t, item.kind, Item_Kind.Text)
        testing.expect_value(t, item.text, "docs")
        testing.expect_value(t, item.url, "building.md")
        found = true
    }
    testing.expect(t, found, "the laid-out link carries its target")
}

@(test)
test_plain_text_has_no_url :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "just some words\n")

    for item in page.items {
        testing.expect_value(t, item.url, "")
    }
}

// The link box is what the click is tested against, so it has to sit on the
// text and nowhere else.
@(test)
test_link_hit_test_covers_the_word :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "see [docs](building.md) here\n")

    index := -1
    for item, i in page.items {
        if item.url != "" && item.kind == .Text {
            index = i
            break
        }
    }
    testing.expect(t, index >= 0, "the page holds a link")

    box := page.items[index]
    testing.expect_value(t, box.w, 4 * CELL)
    testing.expect_value(t, link_at(&page, box.x + 1, box.y + 1), index)
    testing.expect_value(t, link_at(&page, box.x - 4, box.y + 1), -1)
    testing.expect_value(t, link_at(&page, box.x + 1, box.y + LINE + 1), -1)
}

// A word that does not fit starts the next row, at the block's indent.
@(test)
test_wrap_breaks_on_the_column :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    // Four five-letter words at 10 px a character: two fit in 120 px, not three.
    lay(&page, "aaaaa bbbbb ccccc ddddd\n", 120 + 2 * PAD_X)

    rows: [dynamic]f32
    defer delete(rows)
    for item in page.items {
        if item.kind != .Text {
            continue
        }
        if len(rows) == 0 || rows[len(rows) - 1] != item.y {
            append(&rows, item.y)
        }
    }
    testing.expect_value(t, len(rows), 2)
    testing.expect_value(t, page.items[0].x, f32(0))
    testing.expect(t, rows[1] - rows[0] == LINE, "the second row is one line down")
}

// A heading is bigger than the body and, at level 1 and 2, draws its rule.
@(test)
test_heading_steps_the_size_and_rules :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "# Title\n")

    text_size := i32(0)
    rules := 0
    for item in page.items {
        switch item.kind {
        case .Text:
            text_size = item.size
        case .Rect:
            rules += 1
        }
    }
    testing.expect_value(t, text_size, i32(16 + 13))
    testing.expect_value(t, rules, 1)

    lay(&page, "#### Small\n")
    rules = 0
    for item in page.items {
        if item.kind == .Rect {
            rules += 1
        }
    }
    testing.expect_value(t, rules, 0)
}

// An ordered list's number is built, not sliced out of the source, so the page
// has to own it — and let it go on the next layout.
@(test)
test_ordered_list_owns_its_numbers :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)

    lay(&page, "3. first\n4. second\n")
    testing.expect_value(t, len(page.owned), 2)
    testing.expect_value(t, page.owned[0], "3.")
    testing.expect_value(t, page.owned[1], "4.")

    lay(&page, "no list here\n")
    testing.expect_value(t, len(page.owned), 0)
}

// A fenced block draws verbatim on one panel, and the fence lines are not text.
@(test)
test_code_block_draws_verbatim :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "```odin\nx := 1\n**not bold**\n```\n")

    texts: [dynamic]string
    defer delete(texts)
    panels := 0
    for item in page.items {
        switch item.kind {
        case .Text:
            append(&texts, item.text)
        case .Rect:
            panels += 1
        }
    }
    testing.expect_value(t, panels, 1)
    testing.expect_value(t, len(texts), 2)
    testing.expect_value(t, texts[0], "x := 1")
    testing.expect_value(t, texts[1], "**not bold**")
}

// The page grows with its content, which is the scroll extent the host states.
@(test)
test_content_height_follows_the_rows :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)

    lay(&page, "one line\n")
    short := page.content_height

    lay(&page, "one line\n\ntwo\n\nthree\n")
    testing.expect(t, page.content_height > short, "more rows, more page")
    testing.expect(t, short > PAD_TOP + PAD_BOTTOM, "and a row of its own takes height")
}

// The column is capped, so a wide pane centres a readable measure instead of
// running the text edge to edge.
@(test)
test_content_column_is_capped_and_centred :: proc(t: ^testing.T) {
    narrow := content_width(400)
    testing.expect_value(t, narrow, 400 - 2 * PAD_X)
    testing.expect_value(t, content_left(400, narrow), PAD_X)

    wide := content_width(4000)
    testing.expect_value(t, wide, MAX_WIDTH)
    testing.expect_value(t, content_left(4000, wide), (4000 - MAX_WIDTH) * 0.5)
}

// Emphasis and code carry the palette, which is how the page reads without a
// second face to bold or slant with.
@(test)
test_inline_styles_take_their_colors :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    pal := test_palette()
    lay(&page, "plain **strong** and `code` here\n")

    seen: map[string]ui.Color
    defer delete(seen)
    for item in page.items {
        if item.kind == .Text {
            seen[item.text] = item.color
        }
    }
    testing.expect_value(t, seen["plain"], pal.text)
    testing.expect_value(t, seen["strong"], pal.strong)
    testing.expect_value(t, seen["code"], pal.code)
}
