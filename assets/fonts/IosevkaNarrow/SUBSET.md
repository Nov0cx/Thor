# Iosevka Narrow

`Iosevka-Regular.ttf` is stock Iosevka v34.8.0 Regular (0.5em advance
width, `PkgTTF-Unhinted-Iosevka-34.8.0.zip`,
https://github.com/be5invis/Iosevka/releases). This is the canonical
narrow Iosevka proportion; see ../Iosevka/SUBSET.md for the Extended
(0.6em) variant registered as the plain "Iosevka" family, which matches
JetBrains Mono's proportions more closely.

Subset from 7.7 MB to the ranges the editor can actually bake —
`build_codepoint_list` in `ui/fonts.odin` only requests Latin, so the rest
was 46k unreachable glyphs:

    python -m fontTools.subset Iosevka-Regular.ttf \
        --output-file=Iosevka-Regular.ttf \
        --unicodes="U+0000-04FF,U+2000-206F,U+20A0-20BF,U+2190-21FF,U+2200-22FF,U+2500-257F,U+25A0-25FF,U+FB00-FB06" \
        --layout-features="calt,ccmp,liga,locl,dlig,mark,mkmk" \
        --name-IDs="*" --glyph-names

`calt` is kept, so the coding ligatures still shape.
