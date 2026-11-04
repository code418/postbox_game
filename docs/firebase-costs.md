# Firebase infrastructure cost projection

> **Status:** modelled estimate, not a binding quote.
> **Date:** 2026-05-28 · **Current userbase:** 6 active users.
> All unit prices are *indicative* (us‑central1 / multi‑region, as published in early
> 2026) and **must be re‑checked against [live Firebase pricing](https://firebase.google.com/pricing)**
> before any budgeting decision. FX is indicative at **$1 = £0.79** (£1 = $1.27).

---

## 1. Executive summary

- **Today (6 users): effectively £0/month.** Every service sits deep inside the free
  daily quota. The project is on the Blaze (pay‑as‑you‑go) plan only because Cloud
  Functions require it — there is no idle/standing charge (functions scale to zero, no
  `minInstances` set).
- **The bill stays at £0 until roughly 700–1,000 monthly active users (MAU)**, at which
  point Firestore document **reads** become the first (and dominant) paid line item.
- **At every scale, one line dominates: Firestore reads**, driven by the *scan* loop
  (`nearbyPostboxes`), and within that, **Route Mode** (auto‑scans every ~12 s while
  walking). Reads are ~80 % of the projected bill from 10k users upward.
- **Two cliffs to watch — and neither is primarily a money problem:**
  1. **Single‑document write contention** on the shared `leaderboards/{daily,weekly,monthly,lifetime}`
     docs. Every claim transacts on the *same* documents; past ~0.5–1 claim/sec globally
     this causes transaction retries, latency and failures. Hits around **100k MAU**.
  2. **`newDayScoreboard` nightly rebuild** re‑reads *all* claims in the week/month window
     every night. The end‑of‑month run reads the entire month's claims in a **single
     invocation** — a memory/timeout failure long before it becomes expensive.
- Rough monthly totals (assumptions in §3): **1k MAU ≈ $2 (£2)**, **10k ≈ $34 (£27)**,
  **100k ≈ $390 (£310)**, **1M ≈ $3,950 (£3,100)**.

---

## 2. Current state — 6 users

| Service | Monthly usage (est.) | Free quota | Headroom |
|---|---|---|---|
| Firestore reads | ~32k / mo (~1.1k/day) | 50k **/day** | <3 % of one day's free reads |
| Firestore writes | ~900 / mo | 20k/day | negligible |
| Firestore storage | ~30 MB (postboxes) + tiny | 1 GiB | <4 % |
| Cloud Functions invocations | ~1.1k / mo | 2M/mo | negligible |
| Functions compute (GB‑s, GHz‑s) | trivial | 400k GB‑s / 200k GHz‑s | negligible |
| Cloud Storage (report photos) | a few MB | 5 GB | negligible |
| Auth, FCM, Analytics, Crashlytics, Performance, Remote Config | — | free | n/a |
| Hosting (web build) | <1 GB transfer | 10 GB/mo | negligible |

**Bill today: $0.00 / £0.00.** No action needed.

---

## 3. Methodology & assumptions

Figures are deliberately reproducible: every number below comes from
`(per‑MAU‑monthly rate) × (MAU)` against the stated unit prices. The model is only as
good as its assumptions — **the Route Mode and reads‑per‑scan assumptions dominate**, so
both are given sensitivity bands.

### Engagement model

| Assumption | Value | Notes |
|---|---|---|
| DAU / MAU | **20 %** | Casual‑game default → the average user plays ~6 days/month. |
| Nearby scans / active day | 3 | App open + a couple of pull‑to‑refreshes (`lib/nearby.dart`, no auto‑poll). |
| **Route Mode walks / active day** | **0.15 walk** | 15 % of daily users do **one ~30‑min walk**. |
| Scans per Route walk | **~150** | Auto‑scan every **≥12 s OR ≥20 m** (`live_route_screen.dart`: `_kScanTimeTriggerS=12`, `_kScanDistanceTriggerM=20`). |
| ⇒ `nearbyPostboxes` calls / active day | **~25.5** | `3 + 0.15×150` — Route Mode is **~88 %** of scan volume. |
| Claims (`startScoring`) / active day | 3 | |
| Leaderboard / friends / misc reads / day | ~10 | Single‑doc reads, cheap. |
| **Reads per scan** | **~30** | Postboxes returned across the 9 geohash cells. Rural ≈ 2–10, dense urban ≈ 50–100 → **±2× swings the dominant cost line ±2×.** |
| Writes per claim | ~10 | claim+postbox (2) · streak (1) · daily/weekly/monthly (3) · lifetime (2) · county (2). |
| Reads per claim | ~20 | lookup + claims query + per‑box unique check + period sums. |

### Derived per‑MAU monthly rates

`active days/MAU/month = 0.20 × 30 = 6`

| Metric | Per active day | **Per MAU / month** |
|---|---|---|
| Firestore reads | ~835 (`25.5×30 + 3×20 + 10`) | **~5,400** (incl. nightly job, below) |
| Firestore writes | ~30 (`3×10`) | **~180** |
| Functions invocations | ~31 (`25.5 + 3 + ~2`) | **~186** |

The **`newDayScoreboard`** nightly job adds **~400 reads/MAU/month** (it re‑reads the
week + month claim windows on every run) — already folded into the ~5,400 figure.

### Unit prices (indicative — verify before budgeting)

| Resource | Price | Free tier |
|---|---|---|
| Firestore document **read** | $0.06 / 100k | 50k / **day** |
| Firestore document **write** | $0.18 / 100k | 20k / day |
| Firestore document **delete** | $0.02 / 100k | 20k / day |
| Firestore **stored data** | $0.18 / GiB‑month | 1 GiB |
| Functions **invocations** | $0.40 / million | 2M / month |
| Functions **compute** | $0.0000025 / GB‑s · $0.00001 / GHz‑s | 400k GB‑s · 200k GHz‑s / month |
| Functions/egress **network** | ~$0.12 / GB | 5 GB / month |
| Cloud Storage | $0.026 / GB‑mo + $0.12 / GB egress | 5 GB + 1 GB/day download |
| Hosting transfer | $0.15 / GB | 10 GB / month |

> **Note on Firestore region.** These are **multi‑region** rates (the conservative,
> higher figure). A **regional** Firestore location (e.g. `europe-west2`, London) bills
> operations roughly **40 % cheaper** — see §7.

---

## 4. What actually drives the bill (per‑operation cost)

| Operation | Resource cost | $ each | Takeaway |
|---|---|---|---|
| **One Route walk** (~150 scans × 30 reads + 150 invocations) | 4,500 reads + 150 inv | **~$0.0028** (~0.2 p) | Cheap individually, but it's ~88 % of all scan volume. **This is the bill.** |
| One Nearby scan | ~30 reads + 1 inv | ~$0.000018 | |
| One claim | ~20 reads + ~10 writes + 1 inv | ~$0.00003 | Write‑heavy but low‑volume; cost negligible. **Contention, not cost, is its risk (§6).** |
| One leaderboard refresh | 1 doc read | ~$0.0000006 | Leaderboards are **cheap to read** (single capped doc), regardless of userbase. |

**Reads dominate everything.** Writes, invocations and compute together are a minority of
the bill at every tier. Optimisation effort should target **scan reads first** (§7).

---

## 5. Cost projection by userbase

Monthly figures, rounded. "FREE" = within the free quota at that tier.

| MAU | Reads/mo | Writes/mo | Invocations/mo | **Firestore $** | **Functions $** | Other $ | **Total $/mo** | **Total £/mo** |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **6** | 32k | 0.9k | 1.1k | FREE | FREE | FREE | **$0** | **£0** |
| **100** | 0.54M | 15k | 19k | FREE | FREE | FREE | **$0** | **£0** |
| **1,000** | 5.4M | 0.18M | 0.19M | ~$2.3 | FREE | ~$0 | **~$2** | **~£2** |
| **10,000** | 54M | 1.8M | 1.9M | ~$34 (reads $31.5 + writes $2.2) | FREE¹ | ~$0 | **~$34** | **~£27** |
| **100,000** | 540M | 18M | 18.6M | ~$355 (reads $323 + writes $31) | ~$29 (inv $6.6 + compute $22.5) | ~$6 egress | **~$390** | **~£310** |
| **1,000,000** | 5.4B | 180M | 186M | ~$3,560 (reads $3,240 + writes $320) | ~$325 (inv $74 + compute $251) | ~$66 egress | **~$3,950** | **~£3,100** |

¹ At 10k MAU, invocations (1.9M/mo) sit just **under** the 2M free monthly limit — the
next tier crosses it.

**Free‑tier exit point:** the bill leaves £0 at roughly **700–1,000 MAU**, when daily
reads first exceed the 50k/day free allowance (~180k reads/day at 1k MAU).

**Sensitivity:** the single biggest lever is the **Route Mode** assumption. If Route Mode
were unused, scan calls drop from ~25.5 to ~3 per active day (~8× less read volume) and
the 1M‑MAU total falls from ~$3,950 to roughly **$700/mo**. Likewise, **reads‑per‑scan**
(modelled at 30) scales the dominant line linearly — a dense‑urban userbase (≈60/scan)
roughly **doubles** the totals above; a rural one roughly halves them.

---

## 6. Scaling ceilings (hard limits, not just cost)

These bite on **reliability**, and arrive before the bill becomes painful.

### 6.1 Single‑document write contention on shared leaderboards — **highest priority**

Every successful claim, inside `startScoring` (`functions/src/startScoring.ts`), runs
transactions that **read‑modify‑write the same shared documents**:
`leaderboards/daily`, `leaderboards/weekly`, `leaderboards/monthly` (via
`updateUserLeaderboards` in `_leaderboardUtils.ts`) **and** `leaderboards/lifetime`. Every
player in the country funnels writes into **the same four documents.**

Firestore's guidance is **~1 sustained write/sec per document** (contention, retries and
latency degrade well before the 500/sec hard limit). Global claim rate:

| MAU | Claims/sec (global) | Writes/sec to each shared doc | Status |
|---:|---:|---:|---|
| 10,000 | ~0.07 | ~0.07 | fine |
| 100,000 | ~0.7 | ~0.7 | **borderline** — retries begin |
| 1,000,000 | ~7 | ~7 | **broken** — sustained contention, failed/slow claims |

> The 100‑entry cap on the leaderboard arrays (`.slice(0, 100)` in
> `mergePeriodEntries`/`mergeLifetimeEntries`) means the **1 MiB document limit is *not* a
> risk** — but it does mean **only the top 100 players globally ever appear**, so beyond a
> few hundred users most players can't see their own global rank (a product issue, not a
> cost one). The contention above is the real cliff.

**Fix:** §7.2.

### 6.2 `newDayScoreboard` nightly rebuild — reliability + cost

`newDayScoreboard` (`functions/src/newDayScoreboard.ts`, runs `0 0 * * *` Europe/London)
re‑reads **all claims in the week window and the month‑to‑date window** on every run, then
one read per affected user. The **end‑of‑month run reads the entire month's claims in a
single invocation**:

| MAU | Claims in full‑month run | Reads in that one invocation |
|---:|---:|---:|
| 10,000 | ~180k | ~180k |
| 100,000 | ~1.8M | ~1.8M |
| 1,000,000 | ~18M | ~18M |

At 100k+ this single invocation risks **memory exhaustion and the function timeout** (the
default is well under what 1.8M+ doc reads need) — the nightly job starts *failing*, not
just costing money. **Fix:** §7.1.

### 6.3 Geohash query fan‑out

Each scan issues **9 prefix queries** (`_lookupPostboxes.ts`: centre + 8 neighbours) and
is billed per postbox doc returned. In dense urban cells this inflates reads/scan toward
the top of the 10–60 band, multiplying the §5 totals. Not a hard limit, but it compounds
the §5 read cost. **Fix:** §7.3.

---

## 7. Optimisation recommendations (ranked by impact)

> All of these are **recommendations only** — no code is changed by this document. Each is
> a separate follow‑up task.

### 7.1 Stop the nightly full‑rebuild from reading every claim *(fixes 6.2; cuts ~400 reads/MAU/mo)*
The per‑period totals are already maintained incrementally per claim. Either (a) trust
those incremental counters and have `newDayScoreboard` only **reset/roll** period markers
rather than re‑summing from `claims`, or (b) replace the full scan with **`count()` /
aggregation queries**, or (c) shard the rebuild into paged batches that can't blow the
single‑invocation memory/timeout budget. Removes both the reliability cliff and the
largest *non‑scan* read line.

### 7.2 Remove the shared‑leaderboard write hotspot *(fixes 6.1 — the top reliability risk)*
Move off "every claim writes the same global doc":
- Keep an authoritative **per‑user score document** (already largely present on
  `users/{uid}`), and compute the **top‑N leaderboard periodically** (scheduled aggregation
  every N minutes) instead of on every claim — turns N writes/sec on one doc into one
  batched writer.
- Or apply the Firestore **distributed‑counter / sharded‑doc** pattern for the hot period
  documents.
- Show the **current user's own rank** from their per‑user doc (a rank query), so players
  beyond the top 100 still see their position.

### 7.3 Cut scan reads — the dominant cost *(targets §4/§5, ~80 % of the bill)*
- **Throttle / cache Route Mode scans**: raise the 12 s trigger, **suppress scans while
  effectively stationary**, and cache the last result so small GPS jitter doesn't re‑query.
  Even a 2× reduction roughly halves the dominant read line at every tier.
- **Cache `nearbyPostboxes` results client‑side** for a short TTL across Nearby ↔ Route.
- Consider returning postbox sets the client can **filter locally** as the user moves
  within a cell, rather than re‑querying per step.

### 7.4 Use a regional Firestore location *(~40 % off all Firestore operations)*
The app is UK‑only. A regional location such as **`europe-west2` (London)** bills reads/
writes ~40 % cheaper than multi‑region **and** lowers latency for UK users. (Region is
fixed at database creation — this is a migration decision, worth taking early.) On the
same note, confirm Cloud Functions run in a **UK/EU region** to avoid cross‑region egress,
and keep **`minInstances` unset** (current state) so there's no idle charge.

### 7.5 `count()` aggregation queries instead of reading documents
Anywhere the app/back‑end reads a set of docs only to count them (unique‑postbox checks,
totals), use Firestore **aggregation queries** — one billed read instead of N.

### 7.6 Cap abuse‑driven spend
Reads are the bill, and a scraped/spoofed client could inflate them. **Enforce App Check**
(already configured for release) in the Firebase console, and add **per‑callable rate
limits** to `nearbyPostboxes` / `routePostboxes` (the report path already has a daily
quota). This caps the worst‑case bill, independent of organic growth.

---

## 8. Free‑tier headroom — which service costs money first

Given the §3 assumptions, as MAU grows the order in which services leave the free tier:

| # | Service / quota | Approx. MAU where it starts costing | Driver |
|---|---|---:|---|
| 1 | **Firestore reads** (50k/day) | **~700–1,000** | scan loop / Route Mode |
| 2 | **Firestore writes** (20k/day) | **~3,500** | claims fan‑out (~10 writes each) |
| 3 | **Functions invocations** (2M/mo) | **~11,000** | scans + claims |
| 4 | **Functions compute** (200k GHz‑s/mo) | **~9,000** | per‑invocation CPU |
| 5 | Network egress (5 GB/mo) | ~15,000 | function response payloads |
| — | Storage, Auth, FCM, Analytics, Hosting | not a factor at these scales | — |

Reads cross first and stay dominant — consistent with §4/§5.

---

## 9. Caveats & recommended next step

- These are **modelled estimates**, sensitive above all to the **Route Mode** and
  **reads‑per‑scan** assumptions (§5). Treat the tiers as order‑of‑magnitude guidance, not
  a quote.
- Unit prices and free quotas **change** — re‑verify against
  [firebase.google.com/pricing](https://firebase.google.com/pricing) before budgeting.
- **Replace estimates with actuals as you grow:** enable a **Cloud Billing budget alert**
  now (e.g. alert at $10/$50/$200), and turn on **BigQuery billing export** plus the
  Firestore usage dashboard so real per‑service costs are visible well before any cliff in
  §6 is reached.
- **`claims` collection growth:** claims accumulate (~18 docs/MAU/month → ~4.5 GB/month at
  1M MAU). Storage cost stays minor, but a retention/rollup policy for old per‑day claims
  is worth considering at scale (it also shrinks the §7.1 rebuild window).
