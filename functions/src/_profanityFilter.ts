/**
 * Shared profanity block-list used by onUserCreated and updateDisplayName.
 * Keep in sync with validators.dart on the Flutter side.
 * Matched case-insensitively as a substring; catches obvious cases without
 * being exhaustive.
 */
export const BLOCKED_WORDS: ReadonlyArray<string> = [
  "fuck", "shit", "cunt", "bitch", "bastard", "asshole", "arsehole",
  "twat", "prick", "cock", "dick", "pussy", "wank", "wanker",
  "bollocks", "bellend", "tosser", "shite", "knobhead", "knobend",
  "gobshite", "minge", "slag", "slapper", "slut", "whore",
  "bugger", "arse", "pillock", "plonker", "numpty", "muppet",
  "nigger", "nigga", "chink", "spic", "kike", "faggot", "retard",
  "paki", "spaz", "mong", "nonce",
];

/** Returns true if the (already-trimmed) name contains any blocked word. */
export function containsProfanity(name: string): boolean {
  const lower = name.toLowerCase();
  return BLOCKED_WORDS.some((w) => lower.includes(w));
}
