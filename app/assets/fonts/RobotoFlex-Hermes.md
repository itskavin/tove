# RobotoFlex-Hermes.ttf

Roboto Flex, Copyright 2017 The Roboto Flex Project Authors, SIL Open Font
License 1.1 (`RobotoFlex_LICENSE.txt`, the upstream `OFL.txt`). The font is
registered in Flutter as the family `HermesSans`.

Source: google/fonts, `ofl/robotoflex/RobotoFlex[GRAD,XOPQ,XTRA,YOPQ,YTAS,YTDE,YTFI,YTLC,YTUC,opsz,slnt,wdth,wght].ttf`
(1 787 292 bytes, sha256 `9b523f7d82593df0107173849ebb8c817471a1df4b4fb2c3cbf40cfd810c8281`),
fetched 15 November 2026 (repo head `8b0a1d0`).

Built with fontTools (chat-rendering-v2.md §1.2):

```sh
python -m fontTools.varLib.instancer RobotoFlex.ttf GRAD=0 XOPQ=96 XTRA=468 YOPQ=79 \
  YTAS=750 YTDE=-203 YTFI=738 YTLC=514 YTUC=712 wdth=100 -o inst.ttf
python -m fontTools.subset inst.ttf --layout-features='*' --name-IDs='*' --name-languages='*' \
  --notdef-outline --drop-tables+=DSIG --output-file=RobotoFlex-Hermes.ttf \
  --unicodes="U+0000-007F,U+00A0-00FF,U+0100-017F,U+0180-024F,U+0250-02FF,U+0300-036F,U+0370-03FF,U+0400-04FF,U+0500-052F,U+1E00-1EFF,U+2000-206F,U+2070-209F,U+20A0-20CF,U+2100-214F,U+2150-218F,U+2190-21FF,U+2200-22FF,U+2300-23FF,U+25A0-25FF,U+2700-27BF,U+FB00-FB06,U+FEFF,U+FFFD"
```

Result: 444 920 bytes, 808 mapped code points (Basic Latin, Latin-1, Latin
Extended-A/B/Additional incl. Vietnamese, IPA, combining marks, Greek, Cyrillic
and Cyrillic Supplement, punctuation, super/subscripts, currency, letterlike,
number forms, arrows, math operators, technical, geometric shapes, dingbats and
the fi/fl ligatures, as far as the font covers them). Remaining axes:
`wght` 100–1000, `opsz` 8–144, `slnt` −10–0 (italic is `slnt −10`). `wdth` is
pinned at 100 and the parametric axes at their defaults. Emoji, CJK and other
scripts fall back to the bundled Roboto and the platform (or, on web, the
self-hosted engine fallback fonts).
