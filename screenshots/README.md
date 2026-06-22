# Store screenshots

Play Store-grade marketing screenshots for The Postbox Game, captured from Android
emulators (Pixel 7a phone + Wear OS Small Round) driving the real debug build against
the live Firebase backend, then composited onto branded frames.

## What's here

```
marketing/
  phone/light/   01..08  1080x1920  (9:16, framed)            <- default listing set
  phone/dark/    01..08  1080x1920  (framed)
  wear/          01,02   384x384    RAW interface, no frame   <- Wear submission set
                 03_stats_blurred.png  optional 3rd (name blurred — see note)
  _contact_*.png         contact sheets for quick review
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
watch screen, alpha flattened onto black, 24-bit). The stats page is excluded from the
submission set because it shows the account display name; a name-blurred copy
(`03_stats_blurred.png`) is kept in case a 3rd shot is wanted, but a blur is a
modification a strict reviewer could query — prefer the two clean pages.

## Privacy

`raw/` (gitignored) holds the unblurred captures — they contain real usernames, the
account UID and display name. Only the PII shots are redacted before compositing
(leaderboard usernames, wear stats name); all committed `marketing/` finals are clean.

## Play Store compliance

Phone finals are 1080x1920 (1.78:1) and wear 1080x1080 (1:1): both satisfy Play's
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
