# Postbox review dashboard

A local, desktop-first replacement for the app's **Admin · Reports** screen. It shows a keyboard-driven queue of problem reports, and for each report:

- a map of the reported spot, photo EXIF positions, stored boxes nearby, other reports and live OSM nodes;
- duplicate checks;
- reporter context;
- a preview of what a cypher correction will rescore;
- a batch `.osc` builder for OSM follow-up.

It works on **production data**. Accept and reject run `performReview` in `functions/src/reports.ts`, the same code the `reviewReport` callable runs, through the Admin SDK. Rescores and leaderboard updates happen exactly as they do from the app.

## Layout

- `admin_dashboard/` is the frontend: Vite, React, TypeScript and Leaflet. It shares only types with the backend, imported from `functions/src/_reviewTypes.ts`.
- `functions/src/scripts/review_dashboard/` is the server: `node:http` on 127.0.0.1 with no extra dependencies. It reuses the functions modules directly, so there's one copy of `firebase-admin`.

## Run it

```sh
# once, and after frontend changes
cd admin_dashboard && npm ci && npm run build

# credentials: a service-account key for the project...
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
# ...or your own: gcloud auth application-default login
#                 gcloud auth application-default set-quota-project the-postbox-game

cd ../functions
npm run review-dashboard -- --reviewer <uid or email of an admin>
```

The server prints a link like `http://127.0.0.1:8790/#t=…`. Open it. The `#t=` part is a one-time key for this run, and the API refuses requests without it.

| Option | Effect |
| --- | --- |
| `--reviewer <uid\|email>` | Required. Recorded as `reviewedBy` and `correctedBy`. The account must hold the `admin` claim (`node set_admin.js <uid>`). |
| `--port <n>` | Port on 127.0.0.1 (default 8790). |
| `--open` | Open the link in your browser. |
| `--ignore-maintenance` | Allow reviews while Remote Config `maintenance_mode` is on (blocked by default, as in the app). |
| `--dev`, `--dev-port <n>` | Use the Vite dev server instead of `dist/` (see below). |

The server won't start unless it can reach Auth, Remote Config (server and client templates) and Storage with your credentials. Without that check, a rescore could silently use different points from production.

## Keys

Press `?` in the dashboard for the full list.

**Moving around**
- `j`/`k` (or the arrow keys): next and previous report.
- `p`: photos.
- `o`: show live OSM post boxes on the map.
- `e`: open the spot in iD.
- `g` then `q`, `h` or `o`: switch to Queue, History or OSM edits.

**Deciding**
- `a`: start an accept.
- `1` to `9`: accept with a cypher, in reign order. `0` is plain.
- `r`: start a reject, then `1` to `9` picks a reason.
- `n` / `f`: type a note / a reference.
- `Enter`: confirm.
- `Shift+Enter`: confirm despite a duplicate warning.
- `Esc`: cancel.

**Batch reject**
- `x`: add the report to the batch or remove it.
- `Shift+R`: reject the whole batch.

Accepting a cypher correction is blocked until its impact preview has loaded.

## OSM edits

Accepted reports stay listed under **OSM edits** until you record them as uploaded or as needing no upload.

**Building the file.** **Build .osc** merges the selected reports into one osmChange file:
- Modifies use each node's *current* OSM version and tags.
- Edits OSM already has are skipped.
- A new box is held back if OSM already has a post box within 30 m.

**Uploading.** Open the file in JOSM, check it, and upload it with the suggested comment. Then record the changeset id, plus the new node ids if you have them. Nothing is ever uploaded to OSM from here, in line with the OSM automated-edit policy.

## Development

```sh
cd functions && npx tsc -w                       # rebuild the server on change
REVIEW_DASHBOARD_TOKEN=<32+ chars> node lib/scripts/review_dashboard/main.js --reviewer <uid> --dev
cd admin_dashboard && npm run dev                # http://127.0.0.1:5173/#t=<same token>
```

Tests:
- `cd admin_dashboard && npm test` covers the key map and the decision rules (`node:test`).
- `cd functions && npm test` covers the server and domain modules.
