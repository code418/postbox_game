# Plan — A/B testing for onboarding and UX experiments

- **Status:** Proposed
- **Effort:** Medium
- **Firebase services:** Remote Config (conditions), A/B Testing, Analytics

## Overview

Use Firebase A/B Testing to drive split experiments off Remote Config conditions. First experiment: onboarding flow variants (current `Intro` vs. shorter two-screen variant). Follow-ups: compass fuzziness level, claim empty-state CTA copy.

## Initial experiments

1. **Onboarding length** — Control: current James intro. Variant: 2-screen condensed. Primary metric: `sign_up_complete` event. Minimum detectable effect: 5 pp uplift.
2. **Compass granularity** — Control: 8 sectors. Variant: 4 sectors (very fuzzy). Metric: `claim_success` per session.
3. **Empty state CTA** — Control: "No postboxes nearby". Variant: "James is on his rounds... try down the road". Metric: `nearby_retry` event.

## Technical approach

- Depends on the Remote Config plan being merged first.
- Add analytics events: `sign_up_complete`, `claim_success`, `nearby_retry`, `onboarding_step_viewed`.
- Declare Remote Config params `exp_onboarding_variant`, `exp_compass_sectors`, `exp_empty_copy` as strings with defaults.
- Use condition-based overrides configured in the Firebase console under A/B Testing.
- Client reads the active variant and branches UI accordingly; log a `experiment_exposure` event with variant name for downstream slicing.

## Files affected

- `lib/intro.dart`, `lib/nearby.dart`, `lib/fuzzy_compass.dart` — variant branches.
- `lib/services/analytics_service.dart` — new event helpers.

## Rollout

- Experiments are paused by default; enable one at a time with 10 % traffic for 48 h, then ramp.
- Document a runbook: how to conclude an experiment and promote the winning variant to 100 %.

## Risks

- Small DAU → long test duration. Pre-register minimum sample size per experiment.
- Cross-experiment interaction — avoid running overlapping experiments on the same surface.
