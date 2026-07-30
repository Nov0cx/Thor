# Iosevka

`Iosevka-Regular.ttf` here is actually the **Extended** build of Iosevka
v34.8.0 (`PkgTTF-Unhinted-Iosevka-34.8.0.zip`, asset
`iosevka-extended/Iosevka-Extended-Regular.ttf`,
https://github.com/be5invis/Iosevka/releases). Extended's 0.6em advance
width matches JetBrains Mono's width-to-cap-height proportion, whereas
stock Iosevka Regular is 0.5em and reads as narrow/cramped at the same
font_size — see ../IosevkaNarrow/SUBSET.md for that variant, kept as a
separate selectable family for anyone who prefers it.

Subset from 7.7 MB to the ranges the editor can actually bake —
`build_codepoint_list` in `ui/fonts.odin` only requests Latin, so the rest
was 46k unreachable glyphs:

    python -m fontTools.subset Iosevka-Extended.ttf \
        --output-file=Iosevka-Regular.ttf \
        --unicodes="U+0000-04FF,U+2000-206F,U+20A0-20BF,U+2190-21FF,U+2200-22FF,U+2500-257F,U+25A0-25FF,U+FB00-FB06" \
        --layout-features="calt,ccmp,liga,locl,dlig,mark,mkmk" \
        --name-IDs="*" --glyph-names

`calt` is kept, so the coding ligatures still shape.
