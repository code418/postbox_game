# Plan — Claim photos with moderation

- **Status:** Proposed
- **Effort:** Large
- **Firebase services:** Cloud Storage, Cloud Functions, (optionally) Cloud Vision API

## Overview

Let users attach a photo to a claim ("postbox selfie"). Photos are private by default and moderated before being attached. Adds collectible / scrapbook feel and gives the recap screen visual content.

## User flow

1. After a successful claim, a sheet offers "Add a photo?".
2. User takes or picks a photo (never uploads without explicit tap).
3. Upload progress overlay; James comments during wait.
4. On moderation pass, photo appears on that claim in the personal scrapbook and recap.

## Storage layout

- `claims-photos/{uid}/{claimId}/original.jpg` — private, user-write, user-read.
- `claims-photos/{uid}/{claimId}/thumb.jpg` — created by Function, used by the client.

## Moderation

- Cloud Function `onClaimPhotoUploaded` (Storage trigger):
  1. Runs Cloud Vision `SafeSearchDetection`.
  2. If adult/violence/racy > `LIKELY`, delete both objects and write `moderation/flags/...`.
  3. Otherwise generate a `thumb.jpg` (max 512 px edge) and mark the claim doc with `photoReady: true`.
- Alternative if Vision API cost is a concern: use a cheap on-device check in the client (Mediapipe or ML Kit) first and defer cloud scan.

## Firestore

- `claims/{id}` gains `photoReady: bool`, `photoPath: string?`, `thumbPath: string?`.

## Security rules (Storage)

```
match /claims-photos/{uid}/{claimId}/{file} {
  allow write: if request.auth.uid == uid && request.resource.size < 5*1024*1024;
  allow read: if request.auth.uid == uid;
}
```

- Friends-visible mode is out of scope for this PR; photos stay private.

## Client

- Add `image_picker` + `flutter_image_compress`.
- Compress to ≤ 1280 px, JPEG quality 80 before upload.
- Retry-safe uploader with resume support.

## Rollout

- Flag `feature_claim_photos`.
- Gradually enable: internal → 10 % → 100 %.
- Provide an in-app delete-photo button.

## Risks

- Moderation false negatives: ensure strict defaults and reporting flow.
- Storage cost: impose per-user quota (e.g. 500 photos).
- Battery / data usage: compress aggressively; allow "Wi-Fi only upload".

## Testing

- Integration test upload → moderation → thumb generation with Firebase emulator + stubbed Vision client.
