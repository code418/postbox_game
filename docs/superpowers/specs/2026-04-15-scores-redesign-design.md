# Scores Redesign — Design Spec

**Date:** 2026-04-15  
**Status:** Approved

---

## Context

The current Scores screen has five tabs: Daily, Weekly, Monthly, Lifetime, and Friends. The Friends tab only shows lifetime scores and is a separate tab rather than a filter. There is no way to tap a player's display name to learn more about them. This redesign makes friends the default view, adds a toggle to switch to the global leaderboard, and introduces a tappable player profile page accessible from both the leaderboard and the Friends screen.

---

## Design

### 1. Scores Screen (`LeaderboardScreen`)

**Structure:**
- Four period tabs at the top: **Daily**, **Weekly**, **Monthly**, **Lifetime**
- Below the tabs, a **"Friends only" toggle row** (label left, `Switch` widget right) — default **ON**
- The list below reflects the active tab × toggle state

**Friends mode (toggle ON — default):**
- Reads the current user's `friends` array from `users/{uid}`
- Fetches each friend's user doc (`users/{friendUid}`) to get their period score: `dailyPoints`, `weeklyPoints`, `monthlyPoints`, or `uniquePostboxesClaimed` / `lifetimePoints` for Lifetime
- Sorts descending by score; renders the same rank/trophy/avatar row style as today
- Current user's own row highlighted in red as before

**Global mode (toggle OFF):**
- Reads `leaderboards/{period}` entries array — same as current behaviour
- Current user pinned at bottom with "unranked" label if outside top 100

**Tappable names:** Every display name row (in both modes) is tappable and pushes `UserProfilePage` for that UID.

---

### 2. User Profile Page (`UserProfilePage`)

A new pushed route, accessible from `LeaderboardScreen` and `FriendsScreen`.

**Route:** `/profile/:uid`  
**AppBar title:** "Your Profile" when viewing own UID, "Player Profile" otherwise  
**Back:** pops to wherever the user came from

**Content:**

| Section | Detail |
|---|---|
| **Header** | Circle avatar (initials, red bg), display name, "Joined {month year}" |
| **Headline stats** | 3-up row: Unique boxes (gold), Lifetime pts (red), Day streak (green 🔥) |
| **Current Rankings** | Card list: Daily / Weekly / Monthly / Lifetime → rank number or "Unranked" |

**No UID, no email anywhere on this page.**

Rankings are resolved client-side by searching the 4 leaderboard documents for the viewed user's UID. If the user is not present in a leaderboard's top-100 entries, that period shows "Unranked". A small caption reads: *"Rankings shown for top 100 players per period."*

Gold highlight (#1 row background tint + trophy icon) applied to any period where the viewed user holds rank 1.

**Data sources:**
- `users/{uid}` — `displayName`, `createdAt`, `streak`, `uniquePostboxesClaimed`, `lifetimePoints`
- `leaderboards/daily`, `leaderboards/weekly`, `leaderboards/monthly`, `leaderboards/lifetime` — scanned for rank

---

### 3. Friends Screen (`FriendsScreen`)

No structural changes. One addition: every friend's display name / card row becomes tappable and pushes `UserProfilePage` for that friend's UID.

The "Your UID" banner at the top is retained as-is (needed for the add-friend flow).

---

### 4. Backend Changes

#### `users/{uid}` document — new fields

| Field | Type | Written by | Reset by |
|---|---|---|---|
| `dailyPoints` | number | `startScoring` | `newDayScoreboard` (midnight daily) |
| `weeklyPoints` | number | `startScoring` | `newDayScoreboard` (Monday midnight) |
| `monthlyPoints` | number | `startScoring` | `newDayScoreboard` (1st of month midnight) |

#### `startScoring` Cloud Function

After the existing `uniquePostboxesClaimed` / `lifetimePoints` updates, also increment `dailyPoints`, `weeklyPoints`, and `monthlyPoints` by the points awarded in the same transaction.

#### `newDayScoreboard` Cloud Function

Extend the existing midnight rebuild logic:
- **Every day:** reset `dailyPoints` to 0 on all user docs
- **Monday:** also reset `weeklyPoints` to 0
- **1st of month:** also reset `monthlyPoints` to 0

The reset can be done as a batched write across all `users` documents (same pattern as the leaderboard rebuild).

#### Firestore rules

No changes required. `users/{uid}` is already readable by all authenticated users; Cloud Functions have admin write access.

---

### 5. Files to Create / Modify

| File | Change |
|---|---|
| `lib/leaderboard_screen.dart` | Replace 5-tab structure with 4-tab + toggle; friends mode reads user docs; names tappable |
| `lib/user_profile_page.dart` | **New file** — `UserProfilePage` widget |
| `lib/friends_screen.dart` | Make friend rows tappable → push `UserProfilePage` |
| `functions/src/index.ts` | Update `startScoring` to increment period point fields; extend `newDayScoreboard` to reset them |

---

### 6. Verification

1. **Friends toggle default:** Open Scores tab — toggle is ON, list shows only friends' scores for the active period.
2. **Toggle off:** Switch to Everyone — list shows global top-100 from Firestore; current user pinned at bottom if outside top 100.
3. **Period tabs:** Switch between Daily/Weekly/Monthly/Lifetime — data updates correctly in both friends and global modes.
4. **Profile from leaderboard:** Tap any display name in leaderboard → profile page opens with correct stats and ranks; no UID visible.
5. **Profile from friends list:** Tap a friend's name in the Friends screen → same profile page.
6. **Own profile:** Tap own name (in leaderboard) → AppBar shows "Your Profile".
7. **Unranked handling:** A user outside top 100 for a period shows "Unranked" gracefully.
8. **Backend — daily reset:** After midnight, `dailyPoints` on user docs resets to 0; after a claim, `dailyPoints` increments correctly.
9. **No PII on profile:** Confirm no UID, email, or raw identifier appears on `UserProfilePage`.
