# web_styles

Tailwind CSS 4 build for the hosted pages in `web/`:

| Page | URL |
| --- | --- |
| `web/get.html` | `/get` (the canonical marketing link) |
| `web/invite.html` | `/invite/{CODE}` (rewritten to this file by `firebase.json`) |
| `web/support.html` | `/support` |
| `web/privacy-policy.html` | `/privacy-policy` |
| `web/data-safety.html` | `/data-safety` |

`web/index.html` is the Flutter app shell and is not styled from here.

**Adding a page:** create `web/<name>.html` with the same `<head>` lines as the others (`/site.css`, the font preloads) and run `npm run build`. Tailwind scans every `web/*.html` except `index.html`, and `test/web_pages_test.dart` checks the same set, so there is no list to update. Add a rewrite in `firebase.json` only if it needs one; `cleanUrls` already serves it at `/<name>`.

## Commands

Run these in `web_styles/`:

```sh
npm ci            # once
npm run build     # writes web/site.css (minified)
npm run watch     # rebuilds on change while you edit the pages
npm run check     # fails if web/site.css is stale (CI runs this)
npm run fonts     # recopies the self-hosted fonts into web/fonts/
```

`web/site.css` is committed, so a web build needs no Node step: `flutter build web --wasm --source-maps` copies `web/` into `build/web`, then `firebase deploy --only hosting` as before. After changing a page's classes or `src/site.css`, run `npm run build` and commit `web/site.css` with the change. The `Web styles` workflow fails otherwise.

## Design tokens

The colours come from the Postbox Game design system (`lib/theme.dart`). Brand colours stay the same in both themes: `postal-red`, `postal-red-deep`, `postal-gold`, `royal-navy`, `on-red` (secondary text on red), plus the cypher stamp colours.

Everything else switches with `prefers-color-scheme`, through variables in `src/site.css`:

| Utility name | Use |
| --- | --- |
| `page`, `surface` | Page background (parchment / navy) and cards |
| `ink`, `body`, `muted` | Headings and strong text, long-form text, secondary text |
| `heading`, `accent` | Display headings, red accents (a lighter red in dark mode, for contrast) |
| `line` | Borders and dividers |
| `band`, `band-ink` | Navy bands and their secondary text |
| `tint`, `tint-strong` | Pink panels behind screenshots, icon chips |
| `chip`, `chip-ink`, `ok`, `ok-ink`, `highlight` | Neutral pills, Yes/No pills, highlighted text |

Fonts are Plus Jakarta Sans (`font-sans`) and Playfair Display (`font-display`, used for the wordmark and headings, as in the app's splash and login screens).

Red and navy bands carry the `on-dark` class, which switches the focus ring to white.

## Rules the tests enforce

- **No third-party assets.** Fonts, icons and store badges are all self-hosted, so viewing a page tells no font CDN or icon host about the visitor. The privacy policy only discloses Firebase, Apple and Nominatim. Pinned by `test/web_pages_test.dart`, which also checks that every local asset exists and is root-absolute (`/invite/**` rewrites to `invite.html`, so a relative path would resolve under `/invite/`).
- **Privacy policy headings** must be bare `<h2>` tags whose text matches `assets/legal/privacy_policy.md` exactly, with the same "Last updated" stamp (`test/privacy_policy_sync_test.dart`). The `.prose-policy` class styles them, so don't add attributes or rename them on one side only.
- **Store badges:** the App Store link must be `<a class="badge-apple" ...><img src="/app-store-badge.svg" ...>`, with `class` exactly `badge-apple` and `src` as the image's first attribute (`test/app_store_metadata_test.dart`). The `.badge-apple` and `.badge-google` component classes carry the styling.
- **The guide is never named** in a page, its file names included, so his art is `web/images/guide.webp`.

## Assets

- `web/fonts/`: the Latin subsets of `@fontsource-variable/plus-jakarta-sans` and `@fontsource-variable/playfair-display` (SIL Open Font License; the licence files sit next to them).
- `web/icons.svg`: a sprite of Material Symbols Outlined, weight 400 (Apache 2.0), from `@material-symbols/svg-400@0.48.2`. Use an icon with `<svg class="icon size-5" aria-hidden="true"><use href="/icons.svg#mail"/></svg>`. To add one, copy the `<path>` from the package's `outlined/<name>.svg` into a new `<symbol id="..." viewBox="0 -960 960 960">`.
- `web/images/*.webp`: the phone screens are cut from `screenshots/marketing/phone/{light,dark}/` (crop box 207,424 to 873,1904, corners rounded at 44 px). Each has a `-dark` twin, which `<picture>` swaps in for dark mode. `google-play-badge.png` is Google's badge with its built-in padding trimmed.

## Browser support

Tailwind 4 targets Safari 16.4+, Chrome 111+ and Firefox 128+. A few features are progressive enhancements that older browsers simply skip:

- cross-page fades (`@view-transition`)
- prerendering of the other pages on hover (Speculation Rules, Chromium only)
- the FAQ open and close animation (`::details-content`)

All three respect `prefers-reduced-motion`.
