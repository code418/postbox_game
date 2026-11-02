# Workout claims (Health Connect): Play declaration and rollout checklist

Owner checklist for shipping "Claim from your workouts" on Android. The code is
behind two gates (the `activity_claims_enabled` Remote Config flag, Admin-only,
and the server's `ACTIVITY_CLAIMS_AUDIENCE` env var, default `admin`), so it can
merge without anyone outside the admin audience seeing it. **But the phone
manifest's Health Connect permissions are live from the first Play upload that
contains them**, so the Play declaration below must be submitted with that
upload, and approved, before the release can roll out.

## 0. Go / no-go: does Fitbit share routes with Health Connect?

Unconfirmed at the time of writing. On an Android 14+ phone with the Fitbit
(Google Health) app connected to Health Connect:

1. Settings → Health Connect → App permissions → Fitbit: check that it is
   allowed to write **Exercise** and **Exercise routes**.
2. Record a GPS walk and a GPS run with the watch (connected GPS and built-in
   GPS if available), let Fitbit sync, then inspect them with the Health
   Connect Toolbox or the `android/health-samples` app:
   - `dataOrigin.packageName`: expected `com.fitbit.FitbitMobile`. Whatever it
     is must be in `activity_origin_allowlist` (Remote Config; defaults in
     `functions/src/_activityConfig.ts` and `lib/remote_config_service.dart`).
   - `recordingMethod`: if Fitbit writes UNKNOWN, that is accepted already.
   - The route: Data / ConsentRequired / NoData, point spacing, accuracy.
   - How long after the run the session (and its route) appears, and whether
     the record is rewritten later (new `lastModifiedTime`).
3. Repeat with route access set to "Always allow" and "Ask every time".

If Fitbit writes sessions but **no routes**, the Health Connect path cannot
serve Fitbit. The server half is source-agnostic: the fallback is a server-side
Google Health API integration (`exportExerciseTcx` gives the GPS track as TCX)
feeding the same `prepareRoute` / `findCandidates` core.

## 1. Before the first upload that carries the permissions

- [ ] Deploy hosting first (`web/privacy-policy.html` now has the
      `#health-connect` section; `web/data-safety.html` the Fitness info row).
      Health Connect's privacy link and the Play declaration both point at it.
- [ ] Deploy functions + rules (`matchActivityRoute`, `claimActivityPostbox`,
      the `activityQuotas` rules block). Leave `ACTIVITY_CLAIMS_AUDIENCE`
      unset (= admin).
- [ ] Publish the client Remote Config template (adds the four `activity_*`
      keys; `activity_claims_enabled` is true only for the Admin audience).
- [ ] Confirm App Check debug tokens work for the admin test devices.

## 2. Play Console: Health apps declaration (App content → Health apps)

**Health features:** Health and fitness → *Activity and fitness*.

**Data types and justifications** (paste-ready):

- **Exercise (READ_EXERCISE)**
  > The Postbox Game is a location game that rewards walking, running and
  > hiking past UK postboxes. When the player opens the app, we read their
  > walking, running and hiking sessions from the past 36 hours (exercise
  > type, start/end time and the recording app) so they can claim the
  > postboxes their recorded workout passed. We do not read titles, heart
  > rate or any other data, we never write to Health Connect, and we only
  > read while the app is in the foreground.

- **Exercise routes (READ_EXERCISE_ROUTES)**
  > The GPS route of an eligible session is sent once, over HTTPS, to our
  > server (Google Firebase) to work out which postboxes it passed within
  > 30 metres and at what time. The route is processed in memory and
  > discarded; it is never stored. Only the point where the player passed a
  > postbox they then choose to claim is stored, with that claim, and it is
  > deleted after 90 days.

**Other answers:** no background access, no historical (30+ day) access, no
write access, no advertising, no sale, no transfer beyond our processor
(Google Firebase). Privacy policy:
`https://the-postbox-game.web.app/privacy-policy#health-connect`.

If Play asks for a video: record connecting Health Connect from Settings →
Workouts, the disclosure panel, the Health Connect permission sheet, a check
finding a postbox, and the cypher quiz claim.

## 3. Play Console: Data safety form

- **Health and fitness → Fitness info:** collected; not shared; optional;
  purposes *App functionality* and *Fraud prevention, security, and
  compliance*. Leave "processed ephemerally" **unticked** (the pass point of a
  claimed box is stored).
- **Location → Precise location:** unchanged (already declared); the wording
  in `web/data-safety.html` now mentions workout pass points.

## 4. Rollout

1. Admin testing with debug builds on Android 13 (Health Connect app
   installed), Android 14, and Android 15/16. Check: connect, a resume
   check, the per-run "Check" consent flow, a same-day claim, a claim
   from yesterday evening (streak saved, no daily-board credit), and a
   pass older than 36 h (`expired`).
2. Upload the release with the declaration and Data safety answers.
3. After approval: set `ACTIVITY_CLAIMS_AUDIENCE=all` on both functions,
   then turn `activity_claims_enabled` on beyond the Admin audience.
4. Watch `moderationFlags` (`activity_near_ceiling`,
   `activity_dense_session`, `activity_shared_session`), `activityQuotas`
   hits, function latency / reads, and Crashlytics.

**Kill switches:** `kill_switch_activity_claims` (Remote Config, read by the
app and by the server from the client template), or
`ACTIVITY_CLAIMS_AUDIENCE=off` (server, no client involvement).
