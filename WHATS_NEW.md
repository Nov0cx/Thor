# 2026.11.6

- **LaTeX.** Highlighting for `.tex`, `.sty`, `.cls`, `.ltx`, `.dtx` and `.bib`, and a texlab language server entry for completion, diagnostics, go to definition, references and rename.
- **Build on save.** `ctrl + s` on a LaTeX document builds it with latexmk, else tectonic. `ctrl + alt + b` builds on demand. A `% !TEX root = main.tex` comment builds the root of a multi-file project.
- **PDF preview.** `ctrl + alt + p` shows the PDF beside the source, rendered with pdftoppm or mutool. It reloads when the PDF changes.
- **SyncTeX.** `ctrl` + click in the PDF opens the source line, and `ctrl + alt + j` scrolls the PDF to the caret line.
- **New settings.** `latex_build_on_save`, `latex_build_command` and `latex_pdf_renderer`.
- **`thor --wait`.** `thor --wait <file>` returns once the tabs of its files are closed, so Thor can be the editor or merge tool of git.
- **Linux.** A title bar drag or an edge resize goes to the window manager, so the window no longer jitters. The release runs on glibc 2.31 (Ubuntu 20.04) and newer.
