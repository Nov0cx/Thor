package thor

import "core:testing"

@(test)
test_latex_magic_root :: proc(t: ^testing.T) {
    root, ok := latex_magic_root("% !TEX program = lualatex\n%!TeX root = ../main.tex\n\\section{One}\n")
    testing.expect(t, ok)
    testing.expect_value(t, root, "../main.tex")

    _, ok = latex_magic_root("\\documentclass{article}\n% just a comment\n")
    testing.expect(t, !ok)
}

@(test)
test_latex_paths_and_sources :: proc(t: ^testing.T) {
    testing.expect(t, latex_is_source("thesis.TEX"))
    testing.expect(t, !latex_is_source("refs.bib"))
    pdf := latex_pdf_path("docs/paper.tex", context.temp_allocator)
    testing.expect_value(t, pdf, "docs/paper.pdf")
}

@(test)
test_latex_first_error :: proc(t: ^testing.T) {
    output := "This is pdfTeX\n(./main.tex\n./main.tex:12: Undefined control sequence.\n! Emergency stop.\n"
    testing.expect_value(t, latex_first_error(output), "./main.tex:12: Undefined control sequence.")
    testing.expect_value(t, latex_first_error("C:\\work\\a.tex:3: Missing $ inserted.\n"), "C:\\work\\a.tex:3: Missing $ inserted.")
    testing.expect_value(t, latex_first_error("! LaTeX Error: File `x.sty' not found.\n"), "! LaTeX Error: File `x.sty' not found.")
    testing.expect_value(t, latex_first_error("Output written on main.pdf (2 pages).\n"), "")
}

@(test)
test_pdfinfo_parse_sizes :: proc(t: ^testing.T) {
    per_page := "Pages:           2\nPage    1 size: 612 x 792 pts (letter)\nPage    1 rot:  0\nPage    2 size: 595.276 x 841.89 pts (A4)\n"
    sizes    := pdfinfo_parse_sizes(per_page, context.temp_allocator)
    testing.expect_value(t, len(sizes), 2)
    testing.expect_value(t, sizes[0], [2]f32{612, 792})
    testing.expect_value(t, sizes[1], [2]f32{595.276, 841.89})

    shared := pdfinfo_parse_sizes("Pages:           3\nPage size:      612 x 792 pts (letter)\n", context.temp_allocator)
    testing.expect_value(t, len(shared), 3)
}

@(test)
test_mutool_parse_sizes :: proc(t: ^testing.T) {
    output := "main.pdf:\n<page pagenum=\"1\">\n<MediaBox l=\"0\" b=\"0\" r=\"612\" t=\"792\" />\n</page>\n"
    sizes  := mutool_parse_sizes(output, context.temp_allocator)
    testing.expect_value(t, len(sizes), 1)
    testing.expect_value(t, sizes[0], [2]f32{612, 792})
}

@(test)
test_synctex_parse :: proc(t: ^testing.T) {
    edit_out := "This is SyncTeX command line utility, version 1.5\nSyncTeX result begin\nOutput:main.pdf\nInput:./chapters/intro.tex\nLine:42\nColumn:-1\nOffset:0\nContext:\nSyncTeX result end\n"
    edit, ok := synctex_parse_edit(edit_out)
    testing.expect(t, ok)
    testing.expect_value(t, edit.input, "./chapters/intro.tex")
    testing.expect_value(t, edit.line, 42)
    testing.expect_value(t, edit.column, 0)

    view_out := "SyncTeX result begin\nOutput:main.pdf\nPage:2\nx:133.7\ny:200.1\nh:133.768356\nv:203.405838\nW:343.711060\nH:9.962640\nbefore:\nPage:3\nh:1\nv:1\nSyncTeX result end\n"
    box, vok := synctex_parse_view(view_out)
    testing.expect(t, vok)
    testing.expect_value(t, box.page, 2)
    testing.expect(t, abs(box.v - 203.405838) < 0.001)
    testing.expect(t, abs(box.height - 9.96264) < 0.001)

    _, vok = synctex_parse_view("SyncTeX result begin\nSyncTeX result end\n")
    testing.expect(t, !vok)
}
