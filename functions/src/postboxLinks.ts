// Per-postbox links: https://the-postbox-game.web.app/postbox/{CODE}.
//
// - getPostboxLink (callable): a player who has claimed a box gets its link,
//   minting the box's link code on first use. Used by the claim share card's
//   optional QR code and the History "Share link" button.
// - postboxLinkStatus (callable): the app opened a link; how near is the
//   signed-in player to that box? Answers with a distance BAND only.
// - postboxInfo (HTTPS, behind the Hosting rewrite /api/postbox/**): the
//   public facts web/postbox.html shows a visitor without the app.
//
// Codes are opaque (see _postboxPublic.ts for why never the doc id). Storage
// is server-only (firestore.rules) and deliberately holds NO uid, so there is
// nothing here for account deletion, data export or the retention sweep:
//   postboxLinks/{code}           = { postboxId, createdAt }
//   postboxLinkCodes/{postboxId}  = { code, createdAt }
// A code is permanent for its box. To retire one, delete both docs by hand;
// the page then shows "not found".

import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import * as geolib from "geolib";
import { randomBytes } from "crypto";
import { requireAppCheck } from "./_appCheck";
import { getClaimRadiusMeters, getPointsForMonarch } from "./_config";
import { getTodayLondon } from "./_dateUtils";
import { countyMapFor } from "./_countyMap";
import {
  POSTBOX_DOC_ID_RE,
  PostboxDocFields,
  PostboxProximity,
  PostboxPublicInfo,
  buildPostboxPublicInfo,
  cacheControlFor,
  generatePostboxLinkCode,
  isLivePostbox,
  normalisePostboxLinkCode,
  parsePostboxApiPath,
  postboxLinkUrl,
  postboxPosition,
  proximityBand,
  snappedArea,
} from "./_postboxPublic";

type Firestore = admin.firestore.Firestore;

/** Fresh codes tried before giving up on collisions (50 bits of code space,
 *  so even one collision is vanishingly rare). */
const MAX_CODE_ATTEMPTS = 5;

export interface PublicInfoDeps {
  pointsFor: (monarch: string | null) => Promise<number>;
  today: () => string;
}

const defaultInfoDeps: PublicInfoDeps = {
  pointsFor: (m) => getPointsForMonarch(m),
  today: getTodayLondon,
};

async function pickFreeLinkCode(
  tx: admin.firestore.Transaction,
  links: admin.firestore.CollectionReference,
  randomBytesFn: (n: number) => Uint8Array,
  attemptsLeft: number,
): Promise<string> {
  const code = generatePostboxLinkCode(randomBytesFn);
  if (!(await tx.get(links.doc(code))).exists) return code;
  if (attemptsLeft <= 1) {
    throw new functions.https.HttpsError("internal", "Could not mint a link code");
  }
  return pickFreeLinkCode(tx, links, randomBytesFn, attemptsLeft - 1);
}

/**
 * The box's link code, minting one on first use. One transaction, so two
 * players sharing the same box for the first time at the same moment
 * serialise on postboxLinkCodes/{postboxId} and get the same code.
 */
export async function mintPostboxLinkCode(
  db: Firestore,
  postboxId: string,
  randomBytesFn: (n: number) => Uint8Array = randomBytes,
): Promise<string> {
  const byBox = db.collection("postboxLinkCodes").doc(postboxId);
  const links = db.collection("postboxLinks");
  return db.runTransaction(async (tx) => {
    const existing = await tx.get(byBox);
    const stored = existing.exists ? existing.data()?.code : undefined;
    if (typeof stored === "string" && stored) return stored;

    const code = await pickFreeLinkCode(tx, links, randomBytesFn, MAX_CODE_ATTEMPTS);
    const createdAt = admin.firestore.FieldValue.serverTimestamp();
    tx.create(links.doc(code), { postboxId, createdAt });
    tx.create(byBox, { code, createdAt });
    return code;
  });
}

/**
 * getPostboxLink's core. Only for a box the caller has claimed at some point:
 * links come from the claim share card and the claim history, and the check
 * stops a client minting codes for arbitrary boxes.
 */
export async function postboxLinkFor(
  db: Firestore,
  uid: string,
  postboxId: unknown,
  randomBytesFn?: (n: number) => Uint8Array,
): Promise<{ code: string; url: string }> {
  if (typeof postboxId !== "string" || !POSTBOX_DOC_ID_RE.test(postboxId)) {
    throw new functions.https.HttpsError("invalid-argument", "postboxId is not a postbox id");
  }
  const claimed = await db.collection("claims")
    .where("userid", "==", uid)
    .where("postboxes", "==", `/postbox/${postboxId}`)
    .limit(1)
    .get();
  if (claimed.empty) {
    throw new functions.https.HttpsError("permission-denied", "not_claimed");
  }
  const box = await db.collection("postbox").doc(postboxId).get();
  if (!box.exists || !isLivePostbox(box.data() as PostboxDocFields)) {
    throw new functions.https.HttpsError("not-found", "postbox_not_found");
  }
  const code = await mintPostboxLinkCode(db, postboxId, randomBytesFn);
  return { code, url: postboxLinkUrl(code) };
}

/** The live box a code names, or null (unknown code, missing or pruned box). */
export async function resolveLinkCode(
  db: Firestore,
  code: string,
): Promise<{ postboxId: string; doc: PostboxDocFields } | null> {
  const link = await db.collection("postboxLinks").doc(code).get();
  const postboxId = link.exists ? link.data()?.postboxId : undefined;
  if (typeof postboxId !== "string" || !postboxId) return null;
  const box = await db.collection("postbox").doc(postboxId).get();
  if (!box.exists) return null;
  const doc = box.data() as PostboxDocFields;
  return isLivePostbox(doc) ? { postboxId, doc } : null;
}

/**
 * Every claim on the box BEFORE today (London). Today is left out so the
 * public page can't be watched for "someone was here this morning". Claims
 * of deleted accounts (userid "deleted") still count: they happened, and the
 * total says nothing about who. Served by the claims (postboxes, dailyDate)
 * composite index.
 */
export async function claimsBeforeToday(
  db: Firestore,
  postboxId: string,
  today: string,
): Promise<number> {
  const agg = await db.collection("claims")
    .where("postboxes", "==", `/postbox/${postboxId}`)
    .where("dailyDate", "<", today)
    .count()
    .get();
  return agg.data().count;
}

/** The public view of a resolved box. */
export async function loadPublicInfo(
  db: Firestore,
  postboxId: string,
  doc: PostboxDocFields,
  deps: PublicInfoDeps = defaultInfoDeps,
): Promise<PostboxPublicInfo> {
  const monarch = typeof doc.monarch === "string" && doc.monarch ? doc.monarch : null;
  const position = postboxPosition(doc);
  const area = position ? snappedArea(position.lat, position.lng) : null;
  const county = typeof doc.county === "string" ? doc.county : null;
  const [total, points] = await Promise.all([
    claimsBeforeToday(db, postboxId, deps.today()),
    deps.pointsFor(monarch),
  ]);
  return buildPostboxPublicInfo(doc, total, points, countyMapFor(county, area));
}

export interface LinkStatusDeps extends PublicInfoDeps {
  claimRadius: () => Promise<number>;
}

const defaultStatusDeps: LinkStatusDeps = {
  ...defaultInfoDeps,
  claimRadius: getClaimRadiusMeters,
};

export type LinkStatus =
  | { found: false }
  | { found: true; info: PostboxPublicInfo; proximity: PostboxProximity };

/**
 * postboxLinkStatus's core: the box's public info plus a distance BAND for
 * the caller. Never the box id, its coordinates or an exact distance.
 */
export async function linkStatus(
  db: Firestore,
  uid: string,
  code: string,
  position: { lat: number; lng: number } | null,
  deps: LinkStatusDeps = defaultStatusDeps,
): Promise<LinkStatus> {
  const resolved = await resolveLinkCode(db, code);
  if (!resolved) return { found: false };
  const { postboxId, doc } = resolved;
  const today = deps.today();
  const [info, claimedToday] = await Promise.all([
    loadPublicInfo(db, postboxId, doc, deps),
    db.collection("claims").doc(`${uid}_${postboxId}_${today}`).get()
      .then((s) => s.exists),
  ]);
  if (claimedToday) return { found: true, info, proximity: "claimedToday" };
  const box = postboxPosition(doc);
  if (!position || !box) return { found: true, info, proximity: "unknown" };
  const distance = geolib.getDistance(
    { latitude: position.lat, longitude: position.lng },
    { latitude: box.lat, longitude: box.lng },
  );
  return { found: true, info, proximity: proximityBand(distance, await deps.claimRadius()) };
}

export interface HttpResult {
  status: number;
  headers: Record<string, string>;
  body: string;
}

/**
 * postboxInfo's core, as a pure-ish function of the request so it can be
 * tested without an HTTP harness. GET/HEAD /api/postbox/{CODE} only.
 */
export async function resolvePostboxInfo(
  db: Firestore,
  method: string,
  path: string,
  deps: PublicInfoDeps = defaultInfoDeps,
): Promise<HttpResult> {
  const respond = (status: number, body: unknown, extra: Record<string, string> = {}): HttpResult => ({
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": cacheControlFor(status),
      "X-Robots-Tag": "noindex",
      ...extra,
    },
    body: JSON.stringify(body),
  });
  if (method !== "GET" && method !== "HEAD") {
    return respond(405, { error: "method_not_allowed" }, { Allow: "GET, HEAD" });
  }
  const code = parsePostboxApiPath(path);
  if (!code) return respond(400, { error: "bad_code" });
  const resolved = await resolveLinkCode(db, code);
  if (!resolved) return respond(404, { error: "not_found" });
  return respond(200, await loadPublicInfo(db, resolved.postboxId, resolved.doc, deps));
}

function requireUid(request: { auth?: { uid?: string } }): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new functions.https.HttpsError("unauthenticated", "Sign in first");
  }
  return uid;
}

/**
 * Request: `{ postboxId: string }` (a box the caller has claimed).
 * Response: `{ code, url }`.
 * Errors: `unauthenticated`; `invalid-argument`; `permission-denied`
 * "not_claimed"; `not-found` (box gone); `internal` (code collisions).
 */
export const getPostboxLink = functions.https.onCall({ enforceAppCheck: true }, async (request) => {
  requireAppCheck(request);
  const uid = requireUid(request);
  const data = (request.data ?? {}) as { postboxId?: unknown };
  return postboxLinkFor(admin.firestore(), uid, data.postboxId);
});

/**
 * Request: `{ code: string, lat?: number, lng?: number }` (both or neither).
 * Response: `{ found: false }` or `{ found: true, info, proximity }`, where
 * proximity is claimable | claimedToday | veryClose | shortWalk | underKm |
 * far | unknown (no position given).
 * Errors: `unauthenticated`; `invalid-argument` (bad code or position).
 */
export const postboxLinkStatus = functions.https.onCall({ enforceAppCheck: true }, async (request) => {
  requireAppCheck(request);
  const uid = requireUid(request);
  const data = (request.data ?? {}) as { code?: unknown; lat?: unknown; lng?: unknown };
  const code = normalisePostboxLinkCode(data.code);
  if (!code) {
    throw new functions.https.HttpsError("invalid-argument", "code is not a postbox link code");
  }
  const hasLat = data.lat !== undefined && data.lat !== null;
  const hasLng = data.lng !== undefined && data.lng !== null;
  if (hasLat !== hasLng) {
    throw new functions.https.HttpsError("invalid-argument", "send both lat and lng, or neither");
  }
  let position: { lat: number; lng: number } | null = null;
  if (hasLat) {
    const { lat, lng } = data;
    if (typeof lat !== "number" || !Number.isFinite(lat) || lat < -90 || lat > 90 ||
        typeof lng !== "number" || !Number.isFinite(lng) || lng < -180 || lng > 180) {
      throw new functions.https.HttpsError("invalid-argument", "lat/lng out of range");
    }
    position = { lat, lng };
  }
  return linkStatus(admin.firestore(), uid, code, position);
});

/**
 * GET /api/postbox/{CODE}, reached through the Hosting rewrite so it is
 * same-origin with web/postbox.html (no CORS) and cached at the CDN. A static
 * page can't present App Check, so this is unauthenticated: it returns only
 * public facts, and maxInstances bounds what a flood can cost.
 */
export const postboxInfo = functions.https.onRequest(
  { maxInstances: 3, timeoutSeconds: 10 },
  async (req, res) => {
    try {
      const r = await resolvePostboxInfo(admin.firestore(), req.method, req.path);
      res.status(r.status).set(r.headers);
      if (req.method === "HEAD") {
        res.end();
      } else {
        res.send(r.body);
      }
    } catch (e) {
      console.error("[postboxInfo] failed:", e);
      res.status(500).set({ "Cache-Control": cacheControlFor(500) })
        .json({ error: "internal" });
    }
  },
);
