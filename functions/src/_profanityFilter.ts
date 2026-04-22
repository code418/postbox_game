/**
 * Shared profanity block-list used by onUserCreated and updateDisplayName.
 * Keep in sync with validators.dart on the Flutter side.
 * Matched case-insensitively as a substring; catches obvious cases without
 * being exhaustive.
 */
// Matched as a substring (lower-cased), so entries must avoid common English
// substrings to dodge the Scunthorpe problem. Previously included "arse"
// (Arsenal, parser), "cock" (Cockburn, Hancock, peacock), "dick" (Richard,
// Dickson), "mong" (among, monger, Mongolia) and "spic" (spice, suspicion) —
// all removed because they rejected legitimate names. Kept in sync with
// validators.dart.
export const BLOCKED_WORDS: ReadonlyArray<string> = [
  "fuck", "shit", "cunt", "bitch", "bastard", "asshole", "arsehole",
  "twat", "prick", "pussy", "wank", "wanker",
  "bollocks", "bellend", "tosser", "shite", "knobhead", "knobend",
  "gobshite", "minge", "slag", "slapper", "slut", "whore",
  "bugger", "pillock", "plonker", "numpty", "muppet",
  "nigger", "nigga", "chink", "kike", "faggot", "retard",
  "paki", "spaz", "nonce",
];

/** Returns true if the (already-trimmed) name contains any blocked word. */
export function containsProfanity(name: string): boolean {
  const lower = name.toLowerCase();
  return BLOCKED_WORDS.some((w) => lower.includes(w));
}
