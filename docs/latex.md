# LaTeX

Thor edits LaTeX with highlighting, a language server, a build on save, a PDF
preview beside the source, and SyncTeX jumps in both directions. Thor runs
tools that you install; it does not ship a TeX distribution.

## What to install

| Tool | Gives | Needed for |
| --- | --- | --- |
| A TeX distribution: [TeX Live](https://tug.org/texlive/), [MiKTeX](https://miktex.org/) or [MacTeX](https://tug.org/mactex/) | `pdflatex`, `latexmk`, `synctex` | the build and SyncTeX |
| or [Tectonic](https://tectonic-typesetting.github.io/) | a self-contained engine | the build, when `latexmk` is not installed |
| [texlab](https://github.com/latex-lsp/texlab) | completion, diagnostics, go to definition, references, rename | the language features |
| [Poppler](https://poppler.freedesktop.org/) (`pdftoppm`, `pdfinfo`) or [MuPDF](https://mupdf.com/) (`mutool`) | page rendering | the PDF preview |

Each tool must be on `PATH`. Commands that install them:

| System | Commands |
| --- | --- |
| Windows | `winget install MiKTeX.MiKTeX` (has `latexmk` and `synctex`; MiKTeX installs Perl for `latexmk` on its first run), and Poppler from [poppler-windows](https://github.com/oschwartz10612/poppler-windows/releases) with its `Library\bin` folder added to `PATH` |
| Debian, Ubuntu | `sudo apt install texlive-latex-extra latexmk poppler-utils` |
| Fedora | `sudo dnf install texlive-scheme-medium latexmk poppler-utils` |
| Arch | `sudo pacman -S texlive-latexextra texlive-binextra poppler` |
| macOS | `brew install --cask mactex-no-gui` and `brew install poppler texlab` |

Install texlab with `cargo install --locked --git https://github.com/latex-lsp/texlab`,
or download a release binary. Thor starts it when you open the first `.tex` file. If it
is missing, Settings > Language servers shows the install command.

## Files

| Extension | Language |
| --- | --- |
| `.tex .ltx .latex` | LaTeX document: built and previewed |
| `.sty .cls .dtx` | LaTeX package or class: highlighted, served by texlab |
| `.bib` | BibTeX |

`ctrl + k` (toggle line comment) comments a line with `%`.

## Build on save

`ctrl + s` on a LaTeX document saves it and then builds it. An autosave does
not start a build. The build runs in the folder of the root document:

1. the `latex_build_command` setting, when it is set
2. else `latexmk -pdf -synctex=1 -interaction=nonstopmode -file-line-error <file>`
3. else `tectonic --synctex --keep-logs <file>`

The status bar shows "Building …" and then "Built …". When a build fails, the
status bar shows the first error and the terminal panel shows the full log.
texlab reads the `.log` file that the build writes, so build errors also show
as diagnostics in the source. If you save again during a build, Thor builds
again when the running build stops. It builds only the newest version.

A document split into several files names its root at the top of each part:

```latex
% !TEX root = ../main.tex
```

The build, the preview and the SyncTeX jumps then use `main.tex` and
`main.pdf`.

## PDF preview

`ctrl + alt + p` (View: Toggle LaTeX PDF preview) shows the PDF of the active
document in the pane next to it. If only one pane is open, Thor opens a second
one. The PDF is the root file name with `.pdf`, in the root's folder. The
preview reloads each time that file changes, so a build from a terminal also
updates it. Thor renders only the pages near the view, at the resolution of
the current zoom.

| Binding | Action |
| --- | --- |
| wheel | scroll |
| `ctrl` + wheel | zoom toward the cursor |
| click + drag | pan |
| `ctrl` + click | go to the source line of that point (SyncTeX) |

## SyncTeX

- **PDF to source**: `ctrl` + click a point in the preview. Thor opens the source file at that line.
- **Source to PDF**: `ctrl + alt + j` (LaTeX: Go to PDF position) scrolls the
  preview to the caret line and briefly highlights it.

Both directions use the `synctex` command from the TeX distribution and the
`.synctex.gz` file that a build with `-synctex=1` writes. A custom
`latex_build_command` must also pass `-synctex=1`.

## Settings

| Key | Meaning | Default |
| --- | --- | --- |
| `latex_build_on_save` | Build a LaTeX document after `ctrl + s` | `true` |
| `latex_build_command` | Shell command for the build, run in the root's folder; `{file}` is the quoted root file name. It is a project key, so `.thor/settings.lua` can set it | `""` (latexmk, then tectonic) |
| `latex_pdf_renderer` | `"auto"`, `"pdftoppm"` or `"mutool"` | `"auto"` (Poppler, then MuPDF) |

For example, to build with LuaLaTeX:

```lua
latex_build_command = "latexmk -lualatex -synctex=1 -interaction=nonstopmode -file-line-error {file}",
```

The texlab entry is in `settings/lsp.lua`. Thor does the build itself, so the
entry sets texlab's own `build.onSave` to off. It runs ChkTeX on open and
on save.

## Troubleshooting

- **"No LaTeX build tool found"**: `latexmk` and `tectonic` are not on `PATH`.
  If you start Thor from a desktop shortcut, it may get a different `PATH`
  than your terminal.
- **"No PDF renderer found"**: install Poppler or MuPDF (see above), then restart Thor.
- **SyncTeX finds nothing**: the build did not write a `.synctex.gz`. Add
  `-synctex=1` to a custom build command.
- **The preview shows an old PDF**: the build writes the PDF somewhere else,
  for example with `-outdir`. The preview reads only `<root>.pdf` beside the root.
