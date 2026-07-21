import "./adminInit";
import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logger } from "firebase-functions";
import { getTodayLondon, previousDay, getLondonHourMinute } from "./_dateUtils";
import { sendToUser } from "./_notifications";

const db = admin.firestore();

// The reminder polls every 15 minutes from 17:00 to 20:45 Europe/London, giving
// 16 discrete slots (0 = 17:00 … 15 = 20:45). The last slot sits safely before
// 21:00 so a fired reminder always lands inside the 5pm–9pm window.
export const STREAK_REMINDER_SLOTS = 16;
const WINDOW_START_HOUR = 17;

// Firestore doc holding the once-per-day dispatch state.
const STATE_DOC_PATH = "notificationState/streakReminder";

interface ReminderState {
  day?: string;        // "YYYY-MM-DD" the current targetSlot was rolled for
  targetSlot?: number; // slot (0..SLOTS-1) at/after which to fire today
  sentDay?: string;    // "YYYY-MM-DD" the reminder was actually sent
}

/**
 * Maps a Europe/London hour+minute to a 15-minute slot index within the
 * reminder window. Clamped to [0, totalSlots-1]: the scheduler only invokes us
 * inside 17:00–20:59, but clamping keeps the maths total regardless.
 */
export function slotForLondonTime(
  hour: number,
  minute: number,
  totalSlots = STREAK_REMINDER_SLOTS
): number {
  const raw = (hour - WINDOW_START_HOUR) * 4 + Math.floor(minute / 15);
  if (raw < 0) return 0;
  if (raw > totalSlots - 1) return totalSlots - 1;
  return raw;
}

/**
 * Pure dispatch decision. Given the persisted state, today's date, the current
 * slot and an injectable RNG, returns whether to fire now plus the state to
 * persist.
 *
 * - On the first run of a new day we roll a fresh random targetSlot so the
 *   reminder lands at an unpredictable time each day.
 * - Once sent for `today` we never fire again that day.
 * - We fire when the current slot has reached-or-passed the target (`>=`, not
 *   `===`) so a skipped scheduler run doesn't cause us to miss the whole day.
 */
export function decideFire(
  state: ReminderState | undefined,
  today: string,
  currentSlot: number,
  totalSlots: number,
  rng: () => number
): { fire: boolean; newState: ReminderState } {
  let s: ReminderState = state ?? {};
  if (s.day !== today) {
    // New day: roll a fresh target slot in [0, totalSlots-1]. Any sentDay from a
    // previous day is dropped — it's meaningless once the day flips (the
    // `sentDay === today` guard below would never match it), and carrying an
    // absent one through as `undefined` would break the Firestore write (this
    // project doesn't enable ignoreUndefinedProperties).
    s = { day: today, targetSlot: Math.floor(rng() * totalSlots) };
  }
  if (s.sentDay === today) return { fire: false, newState: s };
  if (currentSlot >= (s.targetSlot ?? 0)) {
    return { fire: true, newState: { ...s, sentDay: today } };
  }
  return { fire: false, newState: s };
}

/**
 * True unless the user has explicitly disabled the streak reminder. Absent /
 * undefined pref means enabled, matching the opt-out convention used by the
 * other notification eligibility helpers.
 */
export function shouldNotifyStreakReminder(
  fdata: Record<string, unknown> | undefined
): boolean {
  const prefs = fdata?.notificationPrefs as Record<string, boolean> | undefined;
  return prefs?.streakReminder !== false;
}

/**
 * Builds the reminder body, tailoring it to the streak length when known.
 */
export function streakReminderBody(streak: number | undefined): string {
  const base =
    "You claimed yesterday but not yet today! Claim a postbox before " +
    "midnight to keep your ";
  if (typeof streak === "number" && streak > 0) {
    return `${base}${streak}-day streak alive.`;
  }
  return `${base}streak alive.`;
}

interface Recipient {
  uid: string;
  streak?: number;
  fdata: Record<string, unknown>;
}

/**
 * Finds users whose most recent claim was `yesterday` — i.e. they claimed
 * yesterday but have not yet claimed today (a claim today advances
 * lastClaimDate to today). Exported for unit testing.
 */
export async function findStreakReminderRecipients(
  yesterday: string,
  database: admin.firestore.Firestore = db
): Promise<Recipient[]> {
  const snap = await database
    .collection("users")
    .where("lastClaimDate", "==", yesterday)
    .get();
  return snap.docs.map((doc) => {
    const fdata = doc.data() as Record<string, unknown>;
    return { uid: doc.id, streak: fdata.streak as number | undefined, fdata };
  });
}

/**
 * Sends the streak-loss reminder to every eligible recipient (fan-out with
 * allSettled so one failed push doesn't abort the rest). Exported for testing.
 */
export async function sendStreakReminders(
  recipients: Recipient[],
  send: (uid: string, title: string, body: string) => Promise<void> = sendToUser
): Promise<number> {
  const eligible = recipients.filter((r) => shouldNotifyStreakReminder(r.fdata));
  await Promise.allSettled(
    eligible.map((r) =>
      send(r.uid, "Don't lose your streak! 🔥", streakReminderBody(r.streak))
    )
  );
  return eligible.length;
}

// Runs every 15 minutes from 17:00 to 20:45 London time; fires the reminder
// once per day at a random slot within that window.
// Manually trigger via https://console.cloud.google.com/cloudscheduler
export const streakReminder = onSchedule(
  { schedule: "*/15 17-20 * * *", timeZone: "Europe/London" },
  async (_event) => {
    const today = getTodayLondon();
    const { hour, minute } = getLondonHourMinute();
    const currentSlot = slotForLondonTime(hour, minute);

    // Atomically decide + record so two overlapping invocations can't both
    // fire the reminder for the same day.
    const stateRef = db.doc(STATE_DOC_PATH);
    const fire = await db.runTransaction(async (tx) => {
      const snap = await tx.get(stateRef);
      const { fire, newState } = decideFire(
        snap.data() as ReminderState | undefined,
        today,
        currentSlot,
        STREAK_REMINDER_SLOTS,
        Math.random
      );
      tx.set(stateRef, newState, { merge: false });
      return fire;
    });

    if (!fire) {
      logger.info(`Streak reminder: no send this slot (slot=${currentSlot})`);
      return;
    }

    const yesterday = previousDay(today);
    const recipients = await findStreakReminderRecipients(yesterday);
    const sent = await sendStreakReminders(recipients);
    logger.info(
      `Streak reminder fired at slot ${currentSlot}: ${sent} of ${recipients.length} candidates notified (yesterday=${yesterday})`
    );
  }
);
