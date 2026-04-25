# Plan — GDPR "Delete User Data" Firebase Extension

- **Status:** Proposed
- **Effort:** Small
- **Firebase services:** Extensions (`firebase/delete-user-data`), Auth, Firestore, Storage, RTDB

## Overview

Installing the official "Delete User Data" extension gives the project a compliant, auditable path for "right to be forgotten" requests. It deletes all of a user's data across Firestore, Storage, and RTDB when the user deletes their Firebase Auth account.

## Configuration

- **Firestore paths to delete** (use `{UID}` substitution):
  - `users/{UID}`
  - `users/{UID}/friends/{DOC}` (if migrated to a subcollection; currently an array on the user doc — no extra config needed)
  - `fcmTokens/{UID}`
  - `claims` — **do not hard-delete**; anonymise instead (see below).
  - `recaps/{UID}/periods/{DOC}`
- **Storage paths to delete:**
  - `claims-photos/{UID}/`
  - `james-audio/` — not user data, do not touch.
- **RTDB paths:**
  - `/status/{UID}` (presence plan).

## Claim anonymisation (extra Function)

Hard-deleting claims would corrupt leaderboards historically. Instead:

- Add a Firestore-triggered Function `onUserDeleted` that rewrites the user's claims to `{ uid: "deleted", displayName: "Deleted user" }` before the extension runs. Triggered by `onAuthUserDeleted` and completes within the retry window.

## In-app path

- Add "Delete my account" button in Settings.
- Confirmation dialog + re-authentication (Firebase requires recent sign-in for `User.delete()`).
- Call `FirebaseAuth.instance.currentUser!.delete()`. The extension + Function fan-out does the rest.

## Audit trail

- Extension writes an audit log by default — keep it.
- Add a simple Firestore doc `deletions/{YYYY-MM-DD}` with counts for internal visibility.

## Rollout

- Install extension in a staging project first.
- Manually trigger an account deletion; verify every listed path is cleared.
- Promote to production.

## Risks

- Paths misconfigured → partial deletions leaving dangling references. Mitigated by staging dry-run.
- Re-auth failures — document a manual admin path for edge cases.

## Testing

- Integration test in staging: create test user with claims, photos, friends; delete; assert no residuals.
