import * as admin from "firebase-admin";

type Firestore = admin.firestore.Firestore;

/** Sentinel userid/reporterUid that anonymised records are rewritten to on
 *  account deletion. `rebuildPeriodLeaderboard` skips it so anonymised claims
 *  never resurrect a "deleted" mega-entry on the rebuilt leaderboards. */
export const DELETED_UID = "deleted";

const WRITE_BATCH_SIZE = 400;

/** Firestore field names on a claim that carry location/timing PII and must be
 *  removed when a claim is anonymised. `points`/`monarch`/`dailyDate`/etc. are
 *  kept so the global claim/postbox-history record stays intact. */
const CLAIM_PII_FIELDS = ["userLat", "userLng", "coordKey6", "clientTsMs", "travelSpeed", "deviceIdHash"] as const;

/** Anonymise every claim by [uid]: rewrite `userid` to the deleted sentinel and
 *  strip location PII. Returns the number of claims rewritten. Batched (400). */
export async function anonymiseClaimsForUser(db: Firestore, uid: string): Promise<number> {
  const snap = await db.collection("claims").where("userid", "==", uid).get();
  const update: Record<string, unknown> = { userid: DELETED_UID };
  for (const f of CLAIM_PII_FIELDS) update[f] = admin.firestore.FieldValue.delete();

  let rewritten = 0;
  const batches: admin.firestore.WriteBatch[] = [];
  for (let i = 0; i < snap.docs.length; i += WRITE_BATCH_SIZE) {
    const batch = db.batch();
    for (const doc of snap.docs.slice(i, i + WRITE_BATCH_SIZE)) {
      batch.set(doc.ref, update, { merge: true });
      rewritten++;
    }
    batches.push(batch);
  }
  await Promise.all(batches.map((b) => b.commit()));
  return rewritten;
}

/** Anonymise every report submitted by [uid]: rewrite `reporterUid` to the
 *  deleted sentinel, keeping the report content for data/OSM integrity. */
export async function anonymiseReportsForUser(db: Firestore, uid: string): Promise<number> {
  const snap = await db.collection("reports").where("reporterUid", "==", uid).get();
  let rewritten = 0;
  const batches: admin.firestore.WriteBatch[] = [];
  for (let i = 0; i < snap.docs.length; i += WRITE_BATCH_SIZE) {
    const batch = db.batch();
    for (const doc of snap.docs.slice(i, i + WRITE_BATCH_SIZE)) {
      batch.set(doc.ref, { reporterUid: DELETED_UID }, { merge: true });
      rewritten++;
    }
    batches.push(batch);
  }
  await Promise.all(batches.map((b) => b.commit()));
  return rewritten;
}

/** Remove [uid]'s entry from every leaderboard board it might appear on: the
 *  four period docs plus each per-county lifetime board in [countySlugs]. Each
 *  board is updated in its own transaction (read entries, filter, write back)
 *  so a concurrent claim from another user can't re-introduce the entry. */
export async function removeUserFromLeaderboards(
  db: Firestore,
  uid: string,
  countySlugs: string[],
): Promise<void> {
  const refs: admin.firestore.DocumentReference[] = [
    ...["daily", "weekly", "monthly", "lifetime"].map((p) =>
      db.collection("leaderboards").doc(p),
    ),
    ...countySlugs.map((slug) =>
      db.collection("leaderboards").doc("lifetime_by_county").collection("counties").doc(slug),
    ),
  ];

  await Promise.all(
    refs.map((ref) =>
      db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        const entries = (snap.data()?.entries ?? []) as Array<{ uid?: string }>;
        const filtered = entries.filter((e) => e.uid !== uid);
        if (filtered.length !== entries.length) {
          tx.set(ref, { entries: filtered }, { merge: true });
        }
      }),
    ),
  );
}

/** Remove [uid] from the `friends` array of every other user who had added
 *  them (queried via array-contains). Returns the number of users updated. */
export async function removeUserFromFriends(db: Firestore, uid: string): Promise<number> {
  const snap = await db.collection("users").where("friends", "array-contains", uid).get();
  let updated = 0;
  const batches: admin.firestore.WriteBatch[] = [];
  for (let i = 0; i < snap.docs.length; i += WRITE_BATCH_SIZE) {
    const batch = db.batch();
    for (const doc of snap.docs.slice(i, i + WRITE_BATCH_SIZE)) {
      batch.set(doc.ref, { friends: admin.firestore.FieldValue.arrayRemove(uid) }, { merge: true });
      updated++;
    }
    batches.push(batch);
  }
  await Promise.all(batches.map((b) => b.commit()));
  return updated;
}

/** Hard-delete [uid]'s own per-user documents: the profile doc and its
 *  `countyStats` subcollection, the FCM-token / report-quota / trust-score docs
 *  (all keyed by uid), and any moderation flags referencing the uid. */
export async function deleteUserDocs(db: Firestore, uid: string): Promise<void> {
  const userRef = db.collection("users").doc(uid);

  // countyStats subcollection.
  const countyStats = await userRef.collection("countyStats").get();
  const flags = await db.collection("moderationFlags").where("uid", "==", uid).get();

  const toDelete: admin.firestore.DocumentReference[] = [
    ...countyStats.docs.map((d) => d.ref),
    ...flags.docs.map((d) => d.ref),
    userRef,
    db.collection("fcmTokens").doc(uid),
    db.collection("reportQuotas").doc(uid),
    db.collection("trustScores").doc(uid),
  ];

  const batches: admin.firestore.WriteBatch[] = [];
  for (let i = 0; i < toDelete.length; i += WRITE_BATCH_SIZE) {
    const batch = db.batch();
    for (const ref of toDelete.slice(i, i + WRITE_BATCH_SIZE)) batch.delete(ref);
    batches.push(batch);
  }
  await Promise.all(batches.map((b) => b.commit()));
}
