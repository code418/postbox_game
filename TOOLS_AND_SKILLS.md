# Suggested Tools, Skills, and MCPs for Postbox Game Development

## Claude Code Skills (invoke with Skill tool)

### Already Available
- **`fullstack-dev-skills:flutter-expert`** — Flutter/Dart expertise; use for UI work, widget bugs, animations
- **`fullstack-dev-skills:typescript-pro`** — TypeScript best practices; use when touching Cloud Functions
- **`fullstack-dev-skills:secure-code-guardian`** — Security review; use before any release build
- **`fullstack-dev-skills:test-master`** — Testing strategy; needed to fix broken widget tests and add Function tests
- **`fullstack-dev-skills:react-native-expert`** — (If considering cross-platform migration)
- **`superpowers:systematic-debugging`** — For tricky runtime bugs (e.g. geolocation edge cases)
- **`superpowers:test-driven-development`** — When adding the OSM→Firestore import pipeline

### Most Useful Right Now
1. **`fullstack-dev-skills:flutter-expert`** — Add JamesHint strip to Nearby/Claim screens, confetti animation
2. **`fullstack-dev-skills:test-master`** — Fix widget tests (Firebase mock) and Cloud Function tests
3. **`fullstack-dev-skills:secure-code-guardian`** — Audit Firestore rules and Cloud Function auth checks

---

## MCP Servers Worth Adding

### Firebase / Google Cloud
- **Firebase MCP** — Direct Firestore inspection, query collections, check auth users, view logs without leaving Claude. Would allow debugging leaderboard data or postbox documents live.
  - Install: `firebase-tools` based MCP or community `mcp-firebase`
  - Use: Browse `postboxes` collection, verify `dailyClaim` fields, inspect `leaderboards`

### Development
- **GitHub MCP** (already configured) — PR reviews, issue tracking
- **Playwright MCP** (already configured) — Web build UI testing at `flutter build web`

### Data / OSM
- **Fetch/HTTP MCP** — Directly call the Overpass API to preview OSM postbox data for a region, without writing a script. Useful when building the OSM→Firestore import pipeline.

---

## Tools to Add to the Project

### Flutter / Dart
- **`flutter_lints: ^4.0.0`** (dev_dependency) — Currently referenced in `analysis_options.yaml` but missing from `pubspec.yaml`. Adds opinionated lint rules.
  ```yaml
  dev_dependencies:
    flutter_lints: ^4.0.0
  ```

- **`flutter_staggered_animations`** — Staggered list entry animations for Nearby screen monarch cards
- **`confetti`** — Confetti burst on postbox claim success
- **`lottie: ^3.1.0`** — If a Postman James animation asset is commissioned (replaces CustomPainter)

### Firebase Functions (Node/TypeScript)
- **`firebase-functions-test`** — Proper Cloud Function unit testing with emulator support; needed to fix the broken `test/index.js`
- **`firebase-admin` retry logic** — Wrap leaderboard updates in a retry helper so temporary Firestore failures don't silently drop leaderboard updates

---

## Dev Workflow Improvements

### Firestore Composite Index
Required for `_leaderboardUtils.ts` leaderboard queries (compound query on `userid` + `dailyDate`):
```json
{
  "collectionGroup": "claims",
  "queryScope": "COLLECTION",
  "fields": [
    { "fieldPath": "userid", "order": "ASCENDING" },
    { "fieldPath": "dailyDate", "order": "ASCENDING" }
  ]
}
```
Add to `firestore.indexes.json` to auto-deploy with `firebase deploy`.

### Environment Config
- Move `recaptcha-v3-site-key` in `main.dart` to `--dart-define` build argument or a `.env` file excluded from git
- Use `AndroidProvider.playIntegrity` (not debug) for release builds via build flavors

### Scripts
- **OSM Import script** (`scripts/import_postboxes.ts`) — One-off Node script using Overpass API + batch Firestore writes; see CLAUDE.md for schema spec
