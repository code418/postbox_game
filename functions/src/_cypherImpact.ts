// Dry-run of a cypher correction for the local review dashboard: what an
// accept would do to a box's claims and its claimants' totals, BEFORE the
// reviewer commits. Uses the exact planner + points lookup the real rescore
// uses (planRepointClaims / getPointsForMonarch), and writes nothing.

import type { firestore } from "firebase-admin";
import { DELETED_UID } from "./_accountDeletion";
import { getPointsForMonarch } from "./_config";
import { planRepointClaims } from "./_recomputeScores";
import type { CypherImpactDto, CypherImpactUserDto } from "./_reviewTypes";

/** Users listed individually in the preview; the totals cover everyone. */
export const IMPACT_USER_LIMIT = 50;
const GET_ALL_CHUNK = 100;

export async function previewCypherImpact(
  db: firestore.Firestore,
  postboxKey: string,
  newMonarch: string | null
): Promise<CypherImpactDto> {
  const newPoints = await getPointsForMonarch(newMonarch);
  const snap = await db.collection("claims").where("postboxes", "==", `/postbox/${postboxKey}`).get();
  const claims = snap.docs.map((d) => d.data());
  const plan = planRepointClaims(claims, newMonarch, newPoints);

  const claimsByUid = new Map<string, number>();
  let deletedAccountClaims = 0;
  for (const i of plan.rewrite) {
    const uid = claims[i].userid;
    if (uid === DELETED_UID) deletedAccountClaims++;
    else if (typeof uid === "string" && plan.deltaByUid.has(uid)) claimsByUid.set(uid, (claimsByUid.get(uid) ?? 0) + 1);
  }

  const ranked = [...plan.deltaByUid.entries()].sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]) || a[0].localeCompare(b[0]));
  const shown = ranked.slice(0, IMPACT_USER_LIMIT);
  const userDocs = new Map<string, Record<string, unknown> | undefined>();
  const refs = shown.map(([uid]) => db.collection("users").doc(uid));
  const chunks: Array<typeof refs> = [];
  for (let i = 0; i < refs.length; i += GET_ALL_CHUNK) chunks.push(refs.slice(i, i + GET_ALL_CHUNK));
  const snaps = (await Promise.all(chunks.map((c) => db.getAll(...c)))).flat();
  for (const s of snaps) userDocs.set(s.id, s.exists ? (s.data() as Record<string, unknown>) : undefined);

  const users: CypherImpactUserDto[] = shown.map(([uid, delta]) => {
    const u = userDocs.get(uid);
    const before = typeof u?.lifetimePoints === "number" ? u.lifetimePoints : null;
    return {
      uid,
      displayName: typeof u?.displayName === "string" ? u.displayName : null,
      claims: claimsByUid.get(uid) ?? 0,
      delta,
      lifetimePointsBefore: before,
      // recomputeUserAggregates clamps at 0, so the preview does too.
      lifetimePointsAfter: before === null ? null : Math.max(0, before + delta),
    };
  });

  let totalDelta = 0;
  for (const d of plan.deltaByUid.values()) totalDelta += d;
  return {
    postboxId: postboxKey,
    newMonarch,
    newPoints,
    totalClaims: claims.length,
    claimsToRewrite: plan.rewrite.length,
    affectedUsers: ranked.filter(([, d]) => d !== 0).length,
    totalDelta,
    deletedAccountClaims,
    users,
    usersTruncated: ranked.length > shown.length,
  };
}
