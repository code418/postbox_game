# Plan — Churn-risk retention push

- **Status:** Proposed
- **Effort:** Medium
- **Firebase services:** Analytics → BigQuery, BigQuery ML (or Firebase Predictions if available), Cloud Scheduler, Cloud Functions, FCM

## Overview

Identify users at risk of churn and trigger a James-voiced re-engagement push. Firebase Predictions is deprecated, so the modern path is BigQuery ML trained on the Analytics export.

## Approach

1. Depends on **Analytics → BigQuery export** plan.
2. Create a BQ scheduled query that computes a simple churn feature set: `daysSinceLastClaim`, `totalClaims`, `friendsCount`, `streakLength`, `sessionsLast7d`.
3. Train a logistic regression model with `CREATE MODEL ... OPTIONS(model_type='LOGISTIC_REG')` using a label defined as "did not return in next 7 days".
4. Daily scheduled query writes predictions to `gs://.../churn-predictions/YYYY-MM-DD/`.
5. Cloud Function `sendChurnPushes` reads the predictions, filters to `risk > 0.7 AND notificationPrefs.retentionEnabled`, and sends FCM messages.

## Messages

- James-voiced and specific: "Your streak's looking lonely without you, squire. A VR box in BS6 is waiting."
- Never more than one retention push per user per 7 days.

## Privacy

- Predictions live only in BQ (PII already scrubbed per the Analytics plan).
- Add an opt-out under `notificationPrefs.retentionEnabled` (default true).

## Rollout

- Ship the BQ model with monitoring first, no pushes.
- Review prediction quality manually against actual return behaviour for 2 weeks.
- Enable pushes to 10 % first, then ramp.

## Risks

- Small sample size → noisy model. Start simple; don't over-engineer.
- Push fatigue; enforce frequency caps and quiet hours.

## Testing

- BQ model evaluation (AUC > 0.7 on held-out set) before enabling pushes.
- Unit test the FCM dispatcher against a fake predictions file.
