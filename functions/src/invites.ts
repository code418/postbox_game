// Friend invites — the referral loop's server half.
//
// Every user gets one short, unguessable invite code (invites/{code}). Sharing
// it (as https://the-postbox-game.web.app/invite/{code}) lets a friend redeem
// it with acceptInvite, which adds the two players to each other's friends
// lists and, for a brand-new account, records who referred them.
//
// Why a code and not the uid: uids are public (leaderboard rows carry them),
// and being on someone's friends list means receiving pushes about them
// (_notifications.ts notifies every user whose friends array contains the
// claimer). A uid-based mutual add would let anyone push themselves onto a
// stranger's list. The code is a capability the owner hands out deliberately,
// so invites/{code} and referrals/{uid} are server-only (firestore.rules) and
// the code is never stored on the world-readable users/{uid} doc.

import "./adminInit";
import { monitorAppCheck } from "./_appCheck";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { randomBytes } from "crypto";

/** Crockford base32: no I, L, O or U, so a code read aloud or typed by hand
 *  can't be confused. 32 symbols, so a random byte masked to 5 bits maps onto
 *  it uniformly. */
export const INVITE_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const INVITE_CODE_LENGTH = 8;
const INVITE_CODE_RE = /^[0-9A-HJKMNP-TV-Z]{8}$/;

/** Same cap firestore.rules enforces on client writes to users/{uid}.friends. */
export const MAX_FRIENDS = 200;

/** A redeemed invite counts as a referral only for an account this new. */
export const REFERRAL_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

/** How many fresh codes getInviteCode tries before giving up on collisions
 *  (40 bits of code space, so even one collision is vanishingly rare). */
const MAX_CODE_ATTEMPTS = 5;

const FALLBACK_INVITER_NAME = "A player";

/**
 * Canonicalise a typed or pasted invite code: trim, uppercase, drop spaces and
 * hyphens, and apply Crockford's decoding aliases (I and L read as 1, O as 0).
 * Returns null unless the result is exactly a valid 8-symbol code.
 */
export function normaliseInviteCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const code = raw
    .trim()
    .toUpperCase()
    .replace(/[\s-]/g, "")
    .replace(/[IL]/g, "1")
    .replace(/O/g, "0");
  return INVITE_CODE_RE.test(code) ? code : null;
}

/** A fresh random invite code. [randomBytesFn] is injectable for tests. */
export function generateInviteCode(
  randomBytesFn: (n: number) => Uint8Array = randomBytes,
): string {
  const bytes = randomBytesFn(INVITE_CODE_LENGTH);
  let code = "";
  for (let i = 0; i < INVITE_CODE_LENGTH; i++) {
    code += INVITE_CODE_ALPHABET[bytes[i] & 31];
  }
  return code;
}

export interface AcceptInviteInput {
  callerUid: string;
  inviterUid: string;
  callerFriends: string[];
  inviterFriends: string[];
  /** Whether referrals/{callerUid} already exists. */
  referralExists: boolean;
  /** Caller's Auth account age; null when unknown (never counts as new). */
  accountAgeMs: number | null;
}

export type AcceptInvitePlan =
  | { ok: false; error: "self_invite" | "friend_limit" }
  | {
      ok: true;
      alreadyFriends: boolean;
      addInviterToCaller: boolean;
      addCallerToInviter: boolean;
      inviterListFull: boolean;
      recordReferral: boolean;
    };

/**
 * Decide what redeeming an invite writes. Pure, so the transaction in
 * acceptInvite stays a thin read-plan-write. Idempotent by construction: on a
 * retry both players are already on each other's lists and the referral doc
 * exists, so the plan writes nothing.
 */
export function planAcceptInvite(input: AcceptInviteInput): AcceptInvitePlan {
  const { callerUid, inviterUid, callerFriends, inviterFriends } = input;
  if (callerUid === inviterUid) return { ok: false, error: "self_invite" };

  const alreadyFriends = callerFriends.includes(inviterUid);
  if (!alreadyFriends && callerFriends.length >= MAX_FRIENDS) {
    return { ok: false, error: "friend_limit" };
  }

  // The inviter being full doesn't block the caller: they still get the
  // inviter on their own list, just without the reverse add.
  const callerOnInviterList = inviterFriends.includes(callerUid);
  const inviterListFull = !callerOnInviterList && inviterFriends.length >= MAX_FRIENDS;

  const recordReferral =
    !input.referralExists &&
    input.accountAgeMs !== null &&
    input.accountAgeMs < REFERRAL_WINDOW_MS;

  return {
    ok: true,
    alreadyFriends,
    addInviterToCaller: !alreadyFriends,
    addCallerToInviter: !callerOnInviterList && !inviterListFull,
    inviterListFull,
    recordReferral,
  };
}

function friendsOf(snap: admin.firestore.DocumentSnapshot): string[] {
  const friends = snap.data()?.friends;
  return Array.isArray(friends) ? (friends as string[]) : [];
}

function displayNameOf(snap: admin.firestore.DocumentSnapshot): string {
  const name = snap.data()?.displayName;
  return typeof name === "string" && name.trim().length > 0 ? name : FALLBACK_INVITER_NAME;
}

function requireUid(request: functions.https.CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new functions.https.HttpsError("unauthenticated", "Must be signed in to use invites");
  }
  return uid;
}

/** Pick a code no invite doc uses yet, inside [tx]. Recursive rather than a
 *  loop so each read is awaited in turn without tripping no-await-in-loop. */
async function pickFreeCode(
  tx: admin.firestore.Transaction,
  invites: admin.firestore.CollectionReference,
  attemptsLeft: number,
): Promise<string> {
  const code = generateInviteCode();
  const snap = await tx.get(invites.doc(code));
  if (!snap.exists) return code;
  if (attemptsLeft <= 1) {
    throw new functions.https.HttpsError("internal", "Could not allocate an invite code");
  }
  return pickFreeCode(tx, invites, attemptsLeft - 1);
}

/**
 * Returns the caller's invite code, minting one on first use.
 *
 * Response: `{ code: string }`.
 * Errors: `unauthenticated`.
 *
 * Two simultaneous first calls can each mint a code; both stay valid (and are
 * both erased with the account), so the race is harmless.
 */
export const getInviteCode = functions.https.onCall(async (request) => {
  monitorAppCheck(request, "getInviteCode");
  const uid = requireUid(request);

  const db = admin.firestore();
  const invites = db.collection("invites");
  const code = await db.runTransaction(async (tx) => {
    const existing = await tx.get(invites.where("uid", "==", uid).limit(1));
    if (!existing.empty) return existing.docs[0].id;

    const fresh = await pickFreeCode(tx, invites, MAX_CODE_ATTEMPTS);
    tx.create(invites.doc(fresh), {
      uid,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      referralCount: 0,
    });
    return fresh;
  });
  return { code };
});

/**
 * Redeems a friend's invite code.
 *
 * Request: `{ code: string, confirm?: boolean }`.
 * - `confirm !== true` previews without writing:
 *   `{ inviterUid, inviterName, alreadyFriends }`.
 * - `confirm === true` adds both players to each other's friends lists and
 *   records the referral for a new account:
 *   `{ inviterUid, inviterName, added: true, inviterListFull, referralRecorded }`.
 *
 * Errors: `unauthenticated`; `invalid-argument` (malformed code); `not-found`
 * (unknown code, or the inviter's profile is gone); `failed-precondition`
 * "self_invite"; `resource-exhausted` "friend_limit" (caller's list is full);
 * `unavailable` (caller's profile doc not created yet — retry).
 *
 * No push is sent from here: onFriendAdded already sends "New friend!" for
 * each friends-array change, which tells the inviter their invite worked.
 */
export const acceptInvite = functions.https.onCall(async (request) => {
  monitorAppCheck(request, "acceptInvite");
  const uid = requireUid(request);

  const data = (request.data ?? {}) as { code?: unknown; confirm?: unknown };
  const code = normaliseInviteCode(data.code);
  if (!code) {
    throw new functions.https.HttpsError("invalid-argument", "That isn't a valid invite code");
  }

  const db = admin.firestore();
  const inviteRef = db.collection("invites").doc(code);
  const users = db.collection("users");
  const notFound = () =>
    new functions.https.HttpsError("not-found", "That invite code doesn't exist");
  const selfInvite = () =>
    new functions.https.HttpsError("failed-precondition", "self_invite");

  if (data.confirm !== true) {
    const inviteSnap = await inviteRef.get();
    if (!inviteSnap.exists) throw notFound();
    const inviterUid = inviteSnap.data()?.uid as string;
    if (inviterUid === uid) throw selfInvite();
    const [inviterSnap, callerSnap] = await Promise.all([
      users.doc(inviterUid).get(),
      users.doc(uid).get(),
    ]);
    if (!inviterSnap.exists) throw notFound();
    return {
      inviterUid,
      inviterName: displayNameOf(inviterSnap),
      alreadyFriends: friendsOf(callerSnap).includes(inviterUid),
    };
  }

  // Account age comes from Auth, not users/{uid}.createdAt, which
  // onUserCreated writes asynchronously. Read before the transaction so a
  // retry of the transaction body doesn't repeat the Auth call.
  const authUser = await admin.auth().getUser(uid).catch(() => null);
  const createdMs = authUser ? Date.parse(authUser.metadata.creationTime) : NaN;
  const accountAgeMs = Number.isFinite(createdMs) ? Date.now() - createdMs : null;

  const result = await db.runTransaction(async (tx) => {
    const inviteSnap = await tx.get(inviteRef);
    if (!inviteSnap.exists) throw notFound();
    const inviterUid = inviteSnap.data()?.uid as string;
    if (inviterUid === uid) throw selfInvite();

    const callerRef = users.doc(uid);
    const inviterRef = users.doc(inviterUid);
    const referralRef = db.collection("referrals").doc(uid);
    const [callerSnap, inviterSnap, referralSnap] = await Promise.all([
      tx.get(callerRef),
      tx.get(inviterRef),
      tx.get(referralRef),
    ]);
    if (!callerSnap.exists) {
      throw new functions.https.HttpsError("unavailable", "Your profile is still being set up");
    }
    if (!inviterSnap.exists) throw notFound();

    const plan = planAcceptInvite({
      callerUid: uid,
      inviterUid,
      callerFriends: friendsOf(callerSnap),
      inviterFriends: friendsOf(inviterSnap),
      referralExists: referralSnap.exists,
      accountAgeMs,
    });
    if (!plan.ok) {
      if (plan.error === "self_invite") throw selfInvite();
      throw new functions.https.HttpsError("resource-exhausted", "friend_limit");
    }

    if (plan.addInviterToCaller) {
      tx.update(callerRef, { friends: admin.firestore.FieldValue.arrayUnion(inviterUid) });
    }
    if (plan.addCallerToInviter) {
      tx.update(inviterRef, { friends: admin.firestore.FieldValue.arrayUnion(uid) });
    }
    if (plan.recordReferral) {
      tx.create(referralRef, {
        inviterUid,
        code,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.update(inviteRef, { referralCount: admin.firestore.FieldValue.increment(1) });
    }

    return {
      inviterUid,
      inviterName: displayNameOf(inviterSnap),
      added: true,
      inviterListFull: plan.inviterListFull,
      referralRecorded: plan.recordReferral,
    };
  });

  console.log(
    `acceptInvite: ${uid} redeemed ${result.inviterUid}'s invite` +
      (result.referralRecorded ? " (referral recorded)" : ""),
  );
  return result;
});
