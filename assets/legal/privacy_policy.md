# The Postbox Game – Privacy Policy

_Last updated: November 2026_

This Privacy Policy explains how The Postbox Game ("the App", "we", "us") collects, uses, and protects your personal data when you use our mobile application. We are committed to complying with the UK General Data Protection Regulation (UK GDPR) and the Data Protection Act 2018.

## 1. Who We Are

The Postbox Game is an independent mobile game. For data protection enquiries, contact us at richard@agilepixel.io.

## 2. Data We Collect

- **Account information:** When you register or sign in with Google, we receive your email address and display name. When you sign in with Apple, we receive your email address (or an Apple private-relay address, if you choose to hide yours) and, the first time only, your name. When you register with email/password, we store your email address and chosen display name.
- **Location data:** With your permission, we collect your precise GPS location to identify nearby postboxes and validate claims. The location you claimed from is stored with each claim for anti-cheat verification and is automatically removed after 90 days.
- **Gameplay data:** Postbox claims you make (postbox ID, timestamp, points awarded), your running scores, streaks, and leaderboard entries (display name and points only).
- **Device token:** A random per-install identifier sent with claims to detect multi-account abuse. It is not derived from your hardware and identifies only the app installation; it is removed from claims after 90 days.
- **Friends list:** User IDs of friends you choose to add within the App.
- **Workout data (optional, Android):** If you connect Health Connect, we read the walking, running and hiking sessions recorded in the last 36 hours (their type, start and end time, and which fitness app recorded them) and their GPS routes. See Workout Data from Health Connect below.
- **Problem reports:** If you report a postbox data problem, we store your report, its location, and any note or photos you attach (photos may include the time and place they were taken).
- **Anti-abuse records:** Automated checks may record anomaly flags and an internal trust score for your account. While this system runs in "shadow mode" it has no effect on your account or gameplay.
- **Crash and performance data:** Crash reports and performance traces collected by Firebase Crashlytics and Firebase Performance Monitoring to help us fix bugs. You can turn these off in Settings → Privacy (or the Privacy page in the Wear OS watch app). The watch app does not collect performance traces at all.
- **Usage analytics:** Usage events (such as scans, claims and screens viewed) collected by Firebase Analytics and linked to your account's user ID, used only to understand and improve the App and never for advertising. On by default — you can turn it off during onboarding or any time in Settings → Privacy (or the Privacy page in the Wear OS watch app).

## 3. How We Use Your Data

- To operate the App and provide gameplay features (claims, leaderboards, friends).
- To display your scores and display name on leaderboards and to friends.
- To keep the game fair by detecting location spoofing and multi-account abuse.
- To let you claim postboxes that your recorded walks, runs and hikes passed (only if you connect Health Connect).
- To review postbox data problems you report and improve the postbox database.
- To improve the App by analysing crash reports, performance data, and aggregated usage statistics (each of which you can opt out of).
- To associate your gameplay history with your account so it persists across devices.

## 4. Legal Basis for Processing

We process your personal data on the following legal bases under UK GDPR:

- **Contract:** Processing your account and gameplay data is necessary to provide the service you signed up for.
- **Legitimate interests:** Usage analytics, crash reporting, and performance monitoring to maintain and improve a working app (each can be turned off via the Settings → Privacy toggles (or the Privacy page in the Wear OS watch app)), and anti-abuse checks to keep the game fair.
- **Consent:** Location access, which you can grant or revoke at any time in your device settings, and connecting Health Connect, which you can undo at any time in Settings → Workouts or in Health Connect.

## 5. Data Sharing

We do not sell your personal data. We do not use your data for advertising or to track you across other companies' apps and websites, we do not access your device's advertising identifier, and we do not share data with data brokers. We share data only with the following service providers, who process it on our behalf:

- **Google Firebase** (Authentication, Firestore database, Cloud Functions, Crashlytics, Performance Monitoring, Analytics) – processed within Google's infrastructure. See Google's Privacy Policy at policies.google.com/privacy.
- **Apple** (Sign in with Apple) – only if you choose to sign in with Apple; Apple confirms your identity and shares the details above. Deleting your account also revokes the App's access to your Apple ID where your device supports it. See Apple's Privacy Policy at apple.com/legal/privacy.
- **OpenStreetMap / Nominatim:** If you search for a destination in Route Mode, only the text you type is sent to the OpenStreetMap Nominatim search service – never your GPS position.

Your display name and score are visible to other users on leaderboards and to friends you add in the App. Corrections we submit back to OpenStreetMap from accepted postbox reports contain only postbox data, never anything about you.

## 6. Data Retention

- Account data is retained for as long as your account exists; deleting your account anonymises your claims and removes your personal data (see Your Rights).
- The GPS position, timing metadata, and device token stored with a claim are automatically removed after 90 days.
- Workout routes read from Health Connect are processed in memory to find the postboxes they passed and are never stored. For a postbox you choose to claim, the point where you passed it and which fitness app recorded the workout are stored with that claim and removed after 90 days.
- Photos and notes attached to a postbox problem report are removed 30 days after the report is reviewed.
- Anti-abuse anomaly records are deleted after 180 days.
- Leaderboard entries are retained for the relevant period (daily / weekly / monthly) then overwritten.
- Crash and analytics data is retained per Firebase's default retention periods (90 days for Crashlytics; configurable for Analytics).

## 7. Your Rights

Under UK GDPR you have the right to:

- **Access and portability:** Use Settings → Privacy → "Download my data" in the App to receive a machine-readable copy of everything we store about you.
- **Rectification** of inaccurate data (e.g. update your display name in the App).
- **Erasure** ("right to be forgotten"): use Settings → "Delete account" in the App. Your personal data is deleted and your claims are anonymised immediately.
- **Restriction or objection** to certain processing, including turning off crash reporting, performance monitoring, and analytics in Settings → Privacy (or the Privacy page in the Wear OS watch app).
- **Withdraw consent** for location access at any time via your device settings, and for Health Connect in Settings → Workouts or in Health Connect itself; analytics, crash reporting, and performance monitoring can each be turned off in Settings → Privacy (or the Privacy page in the Wear OS watch app).

To exercise any right, or if you have any questions, contact us at richard@agilepixel.io. You also have the right to lodge a complaint with the Information Commissioner's Office (ICO) at ico.org.uk.

## 8. Location Data

The App requests access to your device's precise location (while the app is in use) to find nearby postboxes. We do not track your location in the background. The position you claimed from is stored with that claim for anti-cheat verification and automatically removed after 90 days. Other players never see your location – nearby postboxes are shown only as fuzzy directions.

## 9. Workout Data from Health Connect

Connecting Health Connect is optional and available on Android only. If you connect it:

- We read your walking, running and hiking sessions from the last 36 hours (type, start and end time, and which app recorded them) and their GPS routes. We never write anything to Health Connect, and we never read any other health data such as heart rate or sleep.
- We read only while the App is open, never in the background.
- Each new route is sent once over HTTPS to our servers (Google Firebase) to find postboxes within 30 metres of it and the time you passed each one. The route is processed in memory and discarded; it is never stored.
- When you claim a postbox your workout passed, the point where you passed it, the time, and which fitness app recorded the workout are stored with that claim and removed after 90 days, exactly like a claim made on the spot.
- Health Connect data is never used for advertising or analytics, never sold, and never shared with anyone other than Google Firebase processing it on our behalf.
- You can disconnect at any time in Settings → Workouts or in Health Connect. Disconnecting stops all reading and deletes any workouts waiting to be claimed.

The App's use of information received from Health Connect adheres to the Health Connect Permissions policy, including the Limited Use requirements.

## 10. Children

The App is not directed at children under 13. We do not knowingly collect personal data from children under 13. If you believe a child has provided us with personal data, contact us and we will delete it.

## 11. Security

All data is transmitted over HTTPS and stored in Google Firebase's encrypted infrastructure. Access to Firestore is restricted by server-side security rules; users can only read and write data they are authorised to access.

## 12. Changes to This Policy

We may update this policy occasionally. Material changes will be notified within the App. The "last updated" date at the top of this page will always reflect the current version.

## 13. Contact

For any privacy-related questions or requests: richard@agilepixel.io.
