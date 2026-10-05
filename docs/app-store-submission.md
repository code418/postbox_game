# App Store submission checklist (iOS)

Everything App Store Connect asks for before **Add for Review**, in the order it
appears. Copy lives in `fastlane/metadata/ios/` (fastlane `deliver` layout) so it is
versioned and validated by `test/app_store_metadata_test.dart`; this page covers
the parts that are questionnaires or settings rather than text.

## 1. Build

- [ ] Merge, then run **Actions → CI → Run workflow** (`build-ios`). This build is
      the first to be iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), so earlier
      TestFlight builds must not be submitted.
- [ ] Sign in with Apple prerequisites (from the Apple sign-in PR) are done:
      the capability is enabled on the App ID and the "Postbox Game App Store"
      profile was regenerated afterwards. The Apple provider is enabled in Firebase Auth.
- [ ] APNs key is uploaded to Firebase Cloud Messaging.
- [ ] On the version page, under **Build**, select the new build. Export compliance
      is answered automatically (`ITSAppUsesNonExemptEncryption = NO`).

## 2. Version page (English (U.K.))

| Field | Source | Limit |
|---|---|---|
| Promotional Text | `fastlane/metadata/ios/en-GB/promotional_text.txt` | 170 |
| Description | `…/description.txt` | 4000 |
| Keywords | `…/keywords.txt` | 100 |
| Support URL | `…/support_url.txt` → `web/support.html` | |
| Marketing URL | optional, leave blank | |
| Version | `1.5.3` (from `pubspec.yaml`) | |
| Copyright | `2026 <your legal name or company>` | |
| What's New | not shown for a first release | |

**Previews and Screenshots → iPhone 6.9" Display.** Upload the 8 files from
`screenshots/marketing/appstore/iphone_6.9/light/` in filename order. The dark set
is an alternative. Smaller iPhone sizes are generated from these. No iPad set is
needed now that the app is iPhone-only.

**App Previews (video)** are optional; skip them for the first release. If added
later: 15–30 s, portrait **886×1920** for the 6.9" slot, H.264 `.mov`/`.mp4`, max
30 fps, and only footage captured from the app itself.

### Screenshots: where they come from

`screenshots/build_appstore.sh [light|dark]` builds the set. For each shot, a
genuine iPhone capture in `screenshots/raw/ios/<theme>/<name>.png` wins, if one
exists. Otherwise the app screen is lifted from the existing Play final, with the
Android status bar and gesture bar painted over. The current set comes from the
Play finals, so its UI is pixel-for-pixel the same app, upscaled ~1.5×. Replacing
them with real iPhone captures from TestFlight sharpens them. Redact leaderboard
names first; `raw/` is gitignored.

## 3. App Information

| Field | Value |
|---|---|
| Name | `…/name.txt`: **The Postbox Game** (must be unique on the store) |
| Subtitle | `…/subtitle.txt` |
| Primary category | Games, subcategories **Adventure** and **Trivia** |
| Secondary category | Travel |
| Content Rights | **Yes**, it contains third-party content, and you have the rights: postbox data and map tiles are OpenStreetMap (ODbL), attributed in-app on every map |
| Age Rating | see §5 |

## 4. App Privacy

**Privacy Policy URL:** `…/privacy_url.txt`. **Tracking:** No. There are no ads, no
IDFA and no data brokers, so no App Tracking Transparency prompt is needed.

Data types to declare. All are collected; none are used for tracking.

| Data type | Linked to user | Purposes |
|---|---|---|
| Contact Info → Email Address | Yes | App Functionality |
| Contact Info → Name | Yes | App Functionality (Apple/Google sign-in name, display name) |
| Location → Precise Location | Yes | App Functionality (finding postboxes, verifying claims) |
| User Content → Photos or Videos | Yes | App Functionality (optional report photos) |
| User Content → Other User Content | Yes | App Functionality (report notes) |
| Identifiers → User ID | Yes | App Functionality, Analytics |
| Identifiers → Device ID | Yes | App Functionality (per-install anti-abuse token) |
| Usage Data → Product Interaction | Yes | Analytics (Firebase Analytics with user ID; opt-out in Settings) |
| Diagnostics → Crash Data | No | App Functionality |
| Diagnostics → Performance Data | No | App Functionality |

## 5. Age Rating questionnaire

Answer **None / No** to everything (violence, sexual content, profanity, horror,
drugs, gambling, simulated gambling, contests, medical, unrestricted web access),
except:

- **User-generated content / messaging:** No. Players can't message each other.
  The only player-visible text is profanity-filtered display names, and report
  photos and notes are visible only to the reporter and moderators.
- **Location:** the questionnaire asks about *sharing* location with other users.
  The answer is No, because the fuzzy compass never reveals exact positions, and
  other players never see yours.
- **Made for Kids:** No (the privacy policy says the app is not directed at under-13s).

Expected result: **4+**.

## 6. App Review Information

- [ ] **Sign-in required: Yes.** Create a dedicated demo account (email/password)
      in the app, give it a few claims, friends and leaderboard history, and enter
      its email and password here. Never commit the password.
- [ ] **Contact:** your first name, last name, phone and email.
- [ ] **Notes:** paste `fastlane/metadata/ios/review_information/notes.txt`.
      First record a screen recording of a full claim at a postbox on the iPhone,
      upload it (unlisted YouTube, or a shared Drive link) and replace
      `[ADD VIDEO LINK]`. Reviewers are not in the UK, and without the video the
      core loop can't be seen.

## 7. Pricing and Availability

- Price: **Free**.
- Availability: **United Kingdom** only for launch. Gameplay only works there, and
  players elsewhere would leave "it doesn't work" reviews. App Review is unaffected.

## 8. Submit

- [ ] **Add for Review → Submit.** First reviews usually take 1–3 days.
- [ ] Choose manual or automatic release. Manual lets you check the live listing first.
