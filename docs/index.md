# Thor Documentation

Thor is a code editor written in [Odin](https://odin-lang.org/) on top of
[raylib](https://pkg.odin-lang.org/vendor/raylib/v6/). This folder is the user
manual: how to get it running and how to use it. For the codebase itself, see
[`CLAUDE.md`](../CLAUDE.md) at the repository root.

## Pages

- [Getting Started](getting-started.md) — install or build Thor, open a
  project, first tour.
- [Building from Source](building.md) — dependencies, platform setup,
  `build.odin`, running the tests.
- [Configuration](configuration.md) — `settings.json`, themes, fonts, icon
  packs, per-workspace `.thor/` files, tasks.
- [Keybindings](keybindings.md) — every default shortcut, by area.
- [Plugins](plugins.md) — syntax highlighting, workspace plugins, and the
  permission prompt.

## Generating HTML

The pages above are plain Markdown, read directly on GitHub, or in Thor's own
Markdown preview through **Help > Documentation**. `docs/generate_html.py`
renders them to static HTML under `docs/html/` for offline browsing, which is
what **Help > Documentation in Browser** opens when it is present:

```bash
pip install -r docs/requirements.txt
python docs/generate_html.py
```

See [`generate_html.py`](generate_html.py) for details; `docs/html/` is
generated output and is not committed.
