import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logger } from "firebase-functions";
import { monitorAppCheck } from "./_appCheck";
import { getTodayLondon } from "./_dateUtils";
import { DELETED_UID } from "./_accountDeletion";
import { sendToUser } from "./_notifications";
import {
  UnpackedAccumulator,
  UnpackedStats,
  PostboxMeta,
  LaunchNotifyState,
  UNPACKED_SNAPSHOT_VERSION,
  FIRST_UNPACKED_YEAR,
  applyPercentiles,
  decideLaunchNotify,
  finalizeUnpacked,
  launchNotifyBody,
  postboxIdFromPath,
  summarise,
  unpackedWindow,
  unpackedYearFor,
} from "./_unpacked";

type Firestore = admin.firestore.Firestore;

const db = admin.firestore();

const CLAIMS_PAGE_SIZE = 5000;
const GET_ALL_CHUNK = 100;
const WRITE_BATCH_SIZE = 400;

/** Remote Config (server template) key gating the launch push. Separate from
 *  the client's `unpacked_enabled` so the recap can be soft-launched (visible
 *  in-app) before anyone is pinged about it. */
export const KEY_UNPACKED_NOTIFY_ENABLED = "unpacked_notify_enabled";

const NOTIFY_STATE_DOC = "notificationState/unpacked";

/** `unpacked/{year}` — the community summary doc. */
export function summaryRef(database: Firestore, year: number): admin.firestore.DocumentReference {
  return database.collection("unpacked").doc(String(year));
}

/** `unpacked/{year}/players/{uid}` — one player's snapshot. (Not `users`: a
 *  collection-group query on "users" would also hit the top-level users.) */
export function playerRef(database: Firestore, year: number, uid: string): admin.firestore.DocumentReference {
  return summaryRef(database, year).collection("players").doc(uid);
}

export interface BuildResult {
  year: number;
  players: number;
  claimsRead: number;
  throughDate: string;
}

/**
 * Builds every player's recap for [year] from the `claims` collection and
 * writes `unpacked/{year}` + `unpacked/{year}/players/{uid}`.
 *
 * Three passes: stream the year's claims (paged, dailyDate-ordered — served by
 * the automatic single-field index) into per-player accumulators; join the
 * distinct claimed postboxes for county/reference; finalise, rank and write.
 * Idempotent: a re-run overwrites with fresher numbers. Claims up to
 * [throughDate] (inclusive) are counted, so the 1 December build is "the year
 * so far".
 */
export async function buildUnpackedSnapshots(
  year: number,
  database: Firestore = db,
  throughDate: string = getTodayLondon(),
): Promise<BuildResult> {
  const start = `${year}-01-01`;
  const yearEnd = `${year}-12-31`;
  const end = throughDate < yearEnd ? throughDate : yearEnd;

  // ── Pass 1: aggregate ────────────────────────────────────────────────
  const players = new Map<string, UnpackedAccumulator>();
  let claimsRead = 0;
  let cursor: admin.firestore.QueryDocumentSnapshot | undefined;
  for (;;) {
    let q = database
      .collection("claims")
      .where("dailyDate", ">=", start)
      .where("dailyDate", "<=", end)
      .orderBy("dailyDate")
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(CLAIMS_PAGE_SIZE);
    if (cursor) q = q.startAfter(cursor);
    // Paging is inherently sequential: each page starts after the last.
    // eslint-disable-next-line no-await-in-loop
    const page = await q.get();
    for (const doc of page.docs) {
      claimsRead++;
      const d = doc.data();
      const uid = d.userid;
      // Claims anonymised by account deletion belong to nobody.
      if (typeof uid !== "string" || uid.length === 0 || uid === DELETED_UID) continue;
      const postboxId = postboxIdFromPath(d.postboxes);
      if (postboxId === null || typeof d.dailyDate !== "string") continue;
      let acc = players.get(uid);
      if (!acc) {
        acc = new UnpackedAccumulator(uid, year);
        players.set(uid, acc);
      }
      acc.add({
        userid: uid,
        dailyDate: d.dailyDate,
        points: typeof d.points === "number" ? d.points : 0,
        monarch: typeof d.monarch === "string" ? d.monarch : null,
        postboxId,
      });
    }
    if (page.docs.length < CLAIMS_PAGE_SIZE) break;
    cursor = page.docs[page.docs.length - 1];
  }

  // ── Pass 2: postbox join (county + reference) ────────────────────────
  const allPostboxes = new Set<string>();
  for (const acc of players.values()) for (const id of acc.postboxes) allPostboxes.add(id);
  const meta = new Map<string, PostboxMeta>();
  const ids = [...allPostboxes];
  for (let i = 0; i < ids.length; i += GET_ALL_CHUNK) {
    const refs = ids.slice(i, i + GET_ALL_CHUNK).map((id) => database.collection("postbox").doc(id));
    // Sequential chunks bound the in-flight read size.
    // eslint-disable-next-line no-await-in-loop
    const snaps = await database.getAll(...refs);
    for (const s of snaps) {
      if (!s.exists) continue;
      const p = s.data() ?? {};
      meta.set(s.id, {
        county: typeof p.county === "string" ? p.county : undefined,
        reference: typeof p.reference === "string" ? p.reference : undefined,
      });
    }
  }

  // ── Pass 3: finalise, rank, write ────────────────────────────────────
  const finished: Array<{ uid: string; stats: UnpackedStats }> = [];
  for (const [uid, acc] of players) {
    const stats = finalizeUnpacked(acc, meta);
    if (stats) finished.push({ uid, stats });
  }
  applyPercentiles(finished.map((f) => f.stats));

  const window = unpackedWindow(year);
  const generatedAt = admin.firestore.FieldValue.serverTimestamp();
  for (let i = 0; i < finished.length; i += WRITE_BATCH_SIZE) {
    const batch = database.batch();
    for (const { uid, stats } of finished.slice(i, i + WRITE_BATCH_SIZE)) {
      batch.set(playerRef(database, year, uid), {
        ...stats,
        version: UNPACKED_SNAPSHOT_VERSION,
        throughDate: end,
        generatedAt,
      });
    }
    // One batch at a time keeps write pressure (and memory) flat.
    // eslint-disable-next-line no-await-in-loop
    await batch.commit();
  }

  // Summary last: its existence is what the client and the launch push treat
  // as "the recap is ready", so it must never precede the player docs.
  await summaryRef(database, year).set({
    ...summarise(year, finished.map((f) => f.stats), allPostboxes.size),
    ...window,
    version: UNPACKED_SNAPSHOT_VERSION,
    throughDate: end,
    generatedAt,
  });

  return { year, players: finished.length, claimsRead, throughDate: end };
}

// 03:00 London on 1 December: build the recap of the year so far, ahead of
// the launch push (and the operator flipping `unpacked_enabled`) later that
// morning. Re-run on demand with rebuildUnpacked.
export const buildUnpacked = onSchedule(
  { schedule: "0 3 1 12 *", timeZone: "Europe/London", timeoutSeconds: 540, memory: "1GiB" },
  async () => {
    const year = parseInt(getTodayLondon().slice(0, 4), 10);
    const r = await buildUnpackedSnapshots(year);
    logger.info(`buildUnpacked: ${r.players} players from ${r.claimsRead} claims (year=${year}, through=${r.throughDate})`);
  },
);

/** Validates the admin callable's `year` argument. */
export function parseRebuildYear(raw: unknown, todayLondon: string): number {
  const current = parseInt(todayLondon.slice(0, 4), 10);
  if (raw === undefined || raw === null) return current;
  if (typeof raw !== "number" || !Number.isInteger(raw) || raw < FIRST_UNPACKED_YEAR || raw > current) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `year must be an integer between ${FIRST_UNPACKED_YEAR} and ${current}`,
    );
  }
  return raw;
}

/** Admin-only: (re)build a year's recap now — for the pre-launch soft test and
 *  for refreshing the numbers later in December. */
export const rebuildUnpacked = functions.https.onCall(
  { timeoutSeconds: 540, memory: "1GiB" },
  async (request) => {
    monitorAppCheck(request, "rebuildUnpacked");
    if (request.auth?.token?.admin !== true) {
      throw new functions.https.HttpsError("permission-denied", "Admin access required");
    }
    const year = parseRebuildYear((request.data as { year?: unknown } | undefined)?.year, getTodayLondon());
    const r = await buildUnpackedSnapshots(year);
    logger.info(`rebuildUnpacked by ${request.auth.uid}: ${r.players} players (year=${year})`);
    return r;
  },
);

/** Reads the server-side launch-push flag. Fails closed: if Remote Config
 *  can't be read, nobody is notified (retried by tomorrow's run). */
async function fetchNotifyFlag(): Promise<boolean> {
  try {
    const template = await admin.remoteConfig().getServerTemplate();
    return template.evaluate().getValue(KEY_UNPACKED_NOTIFY_ENABLED).asBoolean();
  } catch (e) {
    logger.warn("unpackedLaunchNotify: Remote Config read failed; not sending", e);
    return false;
  }
}

/** True unless the user turned the "recap ready" push off. */
export function shouldNotifyUnpackedReady(fdata: Record<string, unknown> | undefined): boolean {
  const prefs = fdata?.notificationPrefs as Record<string, boolean> | undefined;
  return prefs?.unpackedReady !== false;
}

/**
 * Sends the launch push to every player with a snapshot who hasn't opted out.
 * Exported (with injectable send) for testing.
 */
export async function sendLaunchNotifications(
  year: number,
  database: Firestore = db,
  send: (uid: string, title: string, body: string) => Promise<void> = sendToUser,
): Promise<number> {
  const players = await summaryRef(database, year).collection("players").get();
  const docs = players.docs;
  let sent = 0;
  for (let i = 0; i < docs.length; i += GET_ALL_CHUNK) {
    const chunk = docs.slice(i, i + GET_ALL_CHUNK);
    // Chunked sequentially so a big player base never fans out unbounded.
    // eslint-disable-next-line no-await-in-loop
    const users = await database.getAll(...chunk.map((d) => database.collection("users").doc(d.id)));
    const prefsByUid = new Map(users.map((u) => [u.id, u.data() as Record<string, unknown> | undefined]));
    const eligible = chunk.filter((d) => prefsByUid.has(d.id) && shouldNotifyUnpackedReady(prefsByUid.get(d.id)));
    // eslint-disable-next-line no-await-in-loop
    await Promise.allSettled(
      eligible.map((d) =>
        send(
          d.id,
          `Your ${year} Postboxes Unpacked 📮`,
          launchNotifyBody(d.data() as Pick<UnpackedStats, "year" | "uniquePostboxes">),
        ),
      ),
    );
    sent += eligible.length;
  }
  return sent;
}

// 10:00 London every day in December: once the snapshot exists AND an operator
// has turned `unpacked_notify_enabled` on, send the "ready" push exactly once
// for the year (transactional marker, as streakReminder does).
export const unpackedLaunchNotify = onSchedule(
  { schedule: "0 10 * 12 *", timeZone: "Europe/London", timeoutSeconds: 540 },
  async () => {
    const today = getTodayLondon();
    const year = unpackedYearFor(today);
    const [summary, flagOn] = await Promise.all([summaryRef(db, year).get(), fetchNotifyFlag()]);

    const stateRef = db.doc(NOTIFY_STATE_DOC);
    const fire = await db.runTransaction(async (tx) => {
      const snap = await tx.get(stateRef);
      const { fire, newState } = decideLaunchNotify(
        snap.data() as LaunchNotifyState | undefined,
        year,
        today,
        summary.exists,
        flagOn,
      );
      if (fire) tx.set(stateRef, newState, { merge: false });
      return fire;
    });
    if (!fire) {
      logger.info(`unpackedLaunchNotify: not sending (year=${year}, summary=${summary.exists}, flag=${flagOn})`);
      return;
    }
    const sent = await sendLaunchNotifications(year);
    logger.info(`unpackedLaunchNotify: notified ${sent} players (year=${year})`);
  },
);
