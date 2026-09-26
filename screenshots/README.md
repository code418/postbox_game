# Store screenshots

Play Store-grade marketing screenshots for The Postbox Game, captured from Android
emulators (Pixel 7a phone + Wear OS Small Round) driving the real debug build against
the live Firebase backend, then composited onto branded frames.

## What's here

```
marketing/
  phone/light/   01..08  1080x1920  (9:16, framed)            <- default listing set
  phone/dark/    01..08  1080x1920  (framed)
  wear/          01..05  384x384    RAW interface, no frame   <- Wear submission set
  feature_graphic.png    1024x500   Play feature graphic
  _contact_*.png         contact sheets for quick review
feature_graphic.html  source for feature_graphic.png (render with headless Chrome — see below)
frame.sh          composite one capture onto a branded, Play-compliant frame
cap.sh            capture a clean phone screenshot (re-asserts demo-mode status bar)
build_finals.sh   map captures -> captions -> ordered finals (single source of truth)
```

The upload-ready copies also live in the fastlane layout:
`fastlane/metadata/android/en-GB/images/{phoneScreenshots,wearScreenshots}/`
(structure only — nothing is auto-uploaded).

## The marquee set (order = narrative)

1. Stand close. Tap. Claim.        (claim CTA + Postman James + streak)
2. Postboxes worth points, nearby  (Nearby scan: map + rarity breakdown)
3. Hints, not directions           (fuzzy compass)
4. Name the royal cypher           (claim quiz)
5. Rarer boxes, bigger scores      (claimed + points + streak)
6. Climb the leaderboards          (leaderboard — usernames blurred)
7. Where now, postie?              (live route mode)
8. Every pin, a place you've been  (history map)

Default listing = the **light** set. Swap in `marketing/phone/dark/` if a dark listing
is preferred. Play allows max 8 phone screenshots per listing; this is exactly 8.

## Wear OS screenshots are different — DO NOT frame them

Play allows promotional framing/captions/backgrounds for **phone/tablet** screenshots
(hence the framed phone set above), but **Wear OS (and Android TV) screenshots must be
the raw app interface only** — no device frame, no background, no added text/graphics.
A framed wear set was rejected: *"Wear screenshots must not be positioned within device
frames, or include additional text, graphics, or backgrounds that are not part of the
interface of the app."* So `marketing/wear/` holds raw 384x384 captures (the native round
watch screen, alpha flattened onto black, 24-bit).

Current set (recaptured 2026-09-21 on `Wear_OS4_Small_Round`, API 33, after the
`WearRoundInset` relayout — the June captures still showed the old horizontal page dots):

```
01_tap_to_scan.png    compass page, idle CTA
02_fuzzy_compass.png  compass page after a real scan ("18 to find")
03_claim.png          claim page, "Scan & Claim" / within 30.0m
04_tile.png           the Postbox tile (seeded demo stats)
05_complication.png   a watch face carrying the Postbox streak complication
```

Everything is captured **signed out** (guest mode), which is why no quiz or claimed state is
in the set: Wear sign-in is Google-only and the emulator has no Google account, and a real
account would put a display name in the frame. The tile and complication numbers come from
seeding `shared_prefs/HomeWidgetPreferences.xml` against a DEAD app process — see the
`wear_tile_complications` notes; launching the app overwrites the seed on its next refresh.

The stats page is excluded because it shows the account display name.

## Privacy

`raw/` (gitignored) holds the unblurred captures — they contain real usernames, the
account UID and display name. Only the PII shots are redacted before compositing
(leaderboard usernames, wear stats name); all committed `marketing/` finals are clean.

## Play Store compliance

Phone finals are 1080x1920 (1.78:1) and wear 384x384 (1:1, Play's Wear minimum; the cap is
3840): both satisfy Play's
"long side <= 2x short side" rule. A raw 1080x2400 phone capture is 2.22:1 and would be
rejected on its own, which is why every shot is framed. `build_finals.sh` re-checks
ratios on every run.

## Regenerating

Boot the emulators, run the debug build, then drive with `cap.sh` (phone) / adb
(wear) to refresh `raw/`, and run `./build_finals.sh`. Status bar is cleaned via Android
demo mode; theme is toggled with `adb shell cmd uimode night yes|no`. JDK 17+ is required
for the Gradle build (use the Android Studio JBR: `JAVA_HOME=/snap/android-studio/current/jbr`).
Note: the debug build is required because App Check uses the debug provider under
`kDebugMode`; a profile/release build switches to Play Integrity and fails on a bare emulator.

## Feature graphic

`feature_graphic.png` is 1024x500 (Play's only accepted size), PNG, no alpha. It is generated
from `feature_graphic.html`, which is committed so the graphic can be re-rendered rather than
re-drawn. It uses the app's own assets — `../assets/postbox.svg` and the Plus Jakarta Sans /
Playfair Display files in `fonts/` — so it stays in step with the in-app art.

```bash
cd screenshots
google-chrome --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1024,500 \
  --screenshot=/tmp/fg_2x.png --virtual-time-budget=3000 feature_graphic.html
convert /tmp/fg_2x.png -resize 1024x500 -background black -alpha remove -alpha off \
  -depth 8 -type TrueColor PNG24:marketing/feature_graphic.png
```

It renders at 2x and downsamples because Chrome's headless text rendering at 1x is noticeably
softer. The alpha flatten matters: Play rejects transparency.

`fonts/` is gitignored (see `.gitignore`), so a fresh clone renders the graphic in the browser's
default serif/sans — drop the two variable TTFs from Google Fonts back into `screenshots/fonts/`
(`PlayfairDisplay.ttf`, `PlusJakartaSans.ttf`, the same families `google_fonts` serves in the app)
before re-rendering, and check the output against the committed PNG.
