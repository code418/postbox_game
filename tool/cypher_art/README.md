# Cypher artwork

`build_cypher_svgs.py` draws the royal cypher illustrations in
`assets/cyphers/`, one per quiz cypher (`MonarchInfo.all` in
`lib/monarch_info.dart`). The app shows them in the claim quiz (phone and
watch) and on the Cypher guide screen through `CypherArt` / `CypherPlate`
(`lib/widgets/cypher_art.dart`).

```sh
pip install -r tool/cypher_art/requirements.txt
python3 tool/cypher_art/build_cypher_svgs.py
```

The generated SVGs are committed, so building the app needs no Python.
Rerun the script only to change the artwork, and commit its output.

- **Stylised, not copied.** Each file is a crown over the monarch's letters,
  with the regnal number between them, as cast on a postbox door. No
  photograph or third-party drawing is reproduced.
- **Crowns** are built from simple shapes in the script:
  - The Tudor crown, with rounded arches, is used for every king and for
    Victoria.
  - St Edward's Crown, whose arches dip in the middle, is used for
    Elizabeth II.
  - The Crown of Scotland is drawn alone and large. Having no letters is
    what tells it apart.
- **Letters** are outlined from Playfair Display, the app's display font,
  which is under the SIL Open Font License 1.1. The script fetches the font
  from google/fonts at a pinned commit, checks its sha256, and caches it in
  the gitignored `.cache/`. Pass `--font-dir` to use files you already have.
- **GVR and GR share artwork**, because George V's boxes read "GR".
  `buildQuizOptions` (`lib/widgets/quiz_helpers.dart`) never offers one
  George as a distractor for another.
- **Single colour, paths only.** Everything is drawn in `#000` and tinted at
  runtime, with no `<text>`, `<image>`, filters or masks.
  `test/cypher_art_test.dart` enforces this, so flutter_svg renders the same
  thing on the phone and on the watch.
