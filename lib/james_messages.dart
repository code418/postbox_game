import 'dart:math';

// ─────────────────────────────────────────────────────────────────────────────
// i18n NOTE (future)
// When adding localisation, replace JamesMessage.resolve() with an
// AppLocalizations lookup keyed by [key] (ARB-compatible camelCase names).
// Dynamic string functions (e.g. nearbyFound) become Intl.message() calls
// with named arguments. Until then, all strings live here as Dart literals.
// ─────────────────────────────────────────────────────────────────────────────

final _random = Random();

/// A fixed message or a pool of variant messages for Postman James.
///
/// Call [resolve] at display time to get a string. If multiple variants are
/// defined, one is chosen at random... keeping James from feeling repetitive.
/// The [key] is an ARB-compatible name reserved for the future i18n migration.
class JamesMessage {
  const JamesMessage(this.key, this._variants);

  final String key;
  final List<String> _variants;

  /// Returns the single string, or a randomly chosen variant.
  String resolve() => _variants.length == 1
      ? _variants.first
      : _variants[_random.nextInt(_variants.length)];
}

/// All Postman James messages... single source of truth.
///
/// Fixed messages use a one-element list; variant pools use multiple elements.
/// Dynamic messages (requiring runtime data) are plain static String functions.
abstract final class JamesMessages {
  JamesMessages._();

  // ── Navigation tab hints (fixed, one per tab) ───────────────────────────

  static const navNearby = JamesMessage(
    'jamesNavNearby',
    [
      "Nothing like a good wander. The compass shows roughly where postboxes "
          "are... no exact locations, mind.",
      "There is nothing, and I mean nothing, I like more than being on the "
          "lookout for postboxes. I love it.",
      "Impress your friends and loved ones by finding nearby postboxes!"
    ],
  );

  static const navClaim = JamesMessage(
    'jamesNavClaim',
    [
      "Found one? Get close and claim it. Rarer cyphers are worth more points.",
      "Can you actually see a postbox? Not that I am saying you are a liar "
          "or anything"
    ],
  );

  static const navScores = JamesMessage(
    'jamesNavScores',
    [
      "Daily, weekly, monthly... see how you stack up against the competition. "
          "The only thing better than spotting postboxes is knowing you have "
          "spotted more than your friends"
    ],
  );

  static const navFriends = JamesMessage(
    'jamesNavFriends',
    ["Add friends by UID to see them here. You do not have to do this alone."],
  );

  static const navFriendsLeaderboard = JamesMessage(
    'jamesNavFriendsLeaderboard',
    [
      "See how you and your mates are getting on. Bit of friendly rivalry never hurt anyone.",
      "The only thing better than having friends is knowing you are better than all of them"
    ],
  );

  static const navLifetimeScores = JamesMessage(
    'jamesNavLifetimeScores',
    [
      "This is the all-time tally... unique postboxes ever claimed. "
          "Claiming the same box twice doesn't count, so get out and explore!",
      "There are over a hundred thousand postboxes out there, gotta spot them all!"
    ],
  );

  /// Returns the nav hint for tab [index] (0–3), or null for unknown indices.
  static JamesMessage? forTabIndex(int index) => switch (index) {
        0 => navNearby,
        1 => navClaim,
        2 => navScores,
        3 => navFriends,
        _ => null,
      };

  // ── Idle non-sequiturs (variant pool) ───────────────────────────────────

  static const idle = JamesMessage(
    'jamesIdle',
    [
      "You cannot send an email using a postbox. Send more letters!",
      "Did you know the oldest surviving postbox in the UK is in Botchergate, "
          "Carlisle? Still standing. Still red.",
      "A Victorian VR postbox weighs about 70 kilograms. Don't try to move one.",
      "The first pillar boxes were painted green. Green! Can you imagine.",
      "There are roughly 115,000 postboxes in the UK. You've got a fair way to go.",
      "Edward VIII was only king for 325 days. His cyphers are rarer for it.",
      "Some postboxes have had the same collection time for over a hundred years. "
          "Consistency... that's what I like.",
      "The correct term is 'pillar box'. Though 'postbox' will do. I'm not fussed.",
      "A postbox in Brixham is shaped like a lighthouse. Just thought you should know.",
      "Royal Mail red is officially called 'Pillar Box Red'. The colour is named "
          "after the thing. Marvellous.",
      "Apparently squirrels occasionally nest inside postboxes. I've said nothing "
          "about this to the sorting office.",
      "Sure, sex is great, but have you ever spotted a rare postbox?",
      "Have I ever told you how much I love postboxes?",
      "People say the internet will kill the need for postboxes. I feel personally "
          "attacked at that prospect."
    ],
  );

  // ── Nearby results ───────────────────────────────────────────────────────

  /// Dynamic: [count] postboxes found. Pass pluralised [box] ("postbox" / "postboxes").
  static String nearbyFound(int count, String box) =>
      "Right... $count $box in your area. Crack on!";

  static const nearbyNoneFound = JamesMessage(
    'jamesNearbyNoneFound',
    [
      "Arse... nothing nearby. Try a different area... postboxes are everywhere. "
          "Just not here.",
      "By my calculations you are in the middle of nowhere, try not being there.",
      "An area without postboxes tears me up inside."
    ],
  );

  // ── Nearby errors ────────────────────────────────────────────────────────

  static const nearbyErrorPermission = JamesMessage(
    'jamesNearbyErrorPermission',
    [
      "I'll need your location for this bit, I'm afraid. Worth it, I promise.",
      "Come on, let me know where you are, I won't tell the police."
    ],
  );

  static const nearbyErrorGeneral = JamesMessage(
    'jamesNearbyErrorGeneral',
    [
      "Something went wrong there. Give it another go.",
      "An error occurred. I will contact tech support to get their arses in gear"
    ],
  );

  // ── Offline / no network ─────────────────────────────────────────────────

  static const errorOffline = JamesMessage(
    'jamesErrorOffline',
    ["No signal out here. Find some Wi-Fi and give it another go."],
  );

  // ── Claim out-of-range ───────────────────────────────────────────────────

  static const claimOutOfRange = JamesMessage(
    'jamesClaimOutOfRange',
    [
      "Hmm, I can't see a postbox at your location. Move closer and try again.",
      "No postboxes nearby? Sounds crazy, no?"
    ],
  );

  // ── Claim success ────────────────────────────────────────────────────────

  static const claimSuccessRare = JamesMessage(
    'jamesClaimSuccessRare',
    ["Oh ho... a rare one! That's a find. Well done.", "Nice, big points"],
  );

  /// Dynamic: multiple postboxes claimed in a single scan.
  static String claimSuccessMulti(int count, int pts) =>
      "Blimey... $count at once! That's $pts points in one go. Impressive.";

  /// Variant pool... keeps repeated standard claims feeling fresh.
  static const claimSuccessStandard = JamesMessage(
    'jamesClaimSuccessStandard',
    [
      "Claimed! Every one counts. Keep going.",
      "Nicely done. On to the next.",
      "That's another one in the bag.",
      "Don't rest now. Gotta claim them all!"
    ],
  );

  // ── Claim errors ─────────────────────────────────────────────────────────

  static const claimErrorAlreadyClaimed = JamesMessage(
    'jamesClaimErrorAlreadyClaimed',
    [
      "You've already had that one today. It'll reset tomorrow.",
      "Calm down, you've already claimed that one today.",
      "You know you do need to move around a bit to get different postboxes."
    ],
  );

  static const claimErrorOutOfRange = JamesMessage(
    'jamesClaimErrorOutOfRange',
    [
      "You're not quite close enough. A few steps closer should do it.",
      "You've got to be close, I couldn't sleep at night if I knew you "
          "were trying to cheat me."
    ],
  );

  static const claimErrorGeneral = JamesMessage(
    'jamesClaimErrorGeneral',
    [
      "Hmm, something went wrong there. Give it another go.",
      "Whoops, messed up there, try again."
    ],
  );

  // ── Quiz ─────────────────────────────────────────────────────────────────

  static const quizFailed = JamesMessage(
    'jamesQuizFailed',
    [
      "Not quite. Have another look at the cipher on the postbox.",
      "Ooh, unlucky. The cipher is the emblem stamped on the front.",
      "That's not it. Each monarch had their own design... worth a second look.",
      "Wrong answer, I'm afraid. Don't worry, the postbox isn't going anywhere.",
    ],
  );

  // ── Intro dialogue ───────────────────────────────────────────────────────

  static const introStep2 = JamesMessage(
    'jamesIntroStep2',
    ['Ah, you found one!\nWhat you see here is a perfectly ordinary postbox.'],
  );

  static const introStep3 = JamesMessage(
    'jamesIntroStep3',
    ['Do you know what I see?'],
  );
}
