import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:postbox_game/remote_config_service.dart';

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
          "spotted more than your friends",
      "There is no prize for second place... or first place for that matter"
    ],
  );

  static const navFriends = JamesMessage(
    'jamesNavFriends',
    [
      "Add friends by UID to see them here. You do not have to do this alone.",
      "Colour the map with your friends. Seize their territory!",
      "Don't have any friends? Try hanging out with your local postie."
    ],
  );

  static const navHistory = JamesMessage(
    'jamesNavHistory',
    [
      "Admiring your handiwork, are we? Every pin is somewhere you've been.",
      "A walk down memory lane... or should I say, pillar-box lane.",
      "Today, this week, this month, all-time. See where you have roamed.",
    ],
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

  static const navCountyLeaders = JamesMessage(
    'jamesNavCountyLeaders',
    [
      "See who is lording it over each county. Tap a region to see the local champion.",
      "Colour the country in your shade. Cornwall is up for grabs, last I checked.",
      "Each county belongs to whoever has claimed the most postboxes in it. Simple as that."
    ],
  );

  /// Returns the nav hint for tab [index] (0–4), or null for unknown indices.
  static JamesMessage? forTabIndex(int index) => switch (index) {
        0 => navNearby,
        1 => navClaim,
        2 => navScores,
        3 => navFriends,
        4 => navHistory,
        _ => null,
      };

  // ── Idle non-sequiturs (variant pool) ───────────────────────────────────

  static const idle = JamesMessage(
    'jamesIdle',
    [
      "You cannot send an email using a postbox. Send more letters!",
      "Evri? DPD? They can do one",
      "The first pillar boxes were painted green. Green! Can you imagine. Crazy.",
      "There are roughly 115,000 postboxes in the UK. You've got a fair way to go.",
      "Edward VIII was only king for 325 days. His cyphers are rarer for it.",
      "Some postboxes have had the same collection time for over a hundred years. "
          "Consistency... that's what I like.",
      "The correct term is 'pillar box'. Though 'postbox' will do. I'm not fussed.",
      "A postbox in Brixham is shaped like a lighthouse. Just thought you should know.",
      "Royal Mail red is officially called 'Pillar Box Red'. The colour is named "
          "after the thing. Marvellous.",
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

  // ── Claim scan found nothing (30 m radius empty) ─────────────────────────

  static const claimScanEmpty = JamesMessage(
    'jamesClaimScanEmpty',
    [
      "Nothing within range. You need to be right next to a postbox.",
      "No postboxes in your immediate area. A few steps might make all the difference.",
      "I'm not detecting any postboxes here. Move closer and try again.",
    ],
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

  static const claimErrorTooFast = JamesMessage(
    'jamesClaimErrorTooFast',
    [
      "Steady on, my old legs only go so fast. Slow down and try again.",
      "Blimey, you're shifting a bit quick for me. Catch your breath, then claim.",
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

  // ── Problem reports ──────────────────────────────────────────────────────

  static const reportSent = JamesMessage(
    'jamesReportSent',
    [
      "Report logged. I'll have a word with the sorting office.",
      "Noted, and passed up the chain. Cheers for keeping the records straight.",
      "Good spot. If it checks out we'll fix the data... and re-score your claims where it matters.",
    ],
  );

  // ── Route mode ───────────────────────────────────────────────────────────

  /// Fires when the user enters Live Route mode.
  static const routeStart = JamesMessage(
    'jamesRouteStart',
    [
      "Right then, off we trot.",
      "Best foot forward, eh?",
      "Don't dawdle, there are postboxes to claim.",
      "On your marks. Plenty out there, let's go.",
      "A fine day for a walk. Let's make it count.",
      "Right, I'll keep you company. Off we go.",
      "Step lively, the postboxes won't claim themselves.",
      "Ready when you are. Lead the way.",
    ],
  );

  /// Fires when an unclaimed postbox is within ~50 m (one-shot per postbox).
  static const routePostboxNearby = JamesMessage(
    'jamesRoutePostboxNearby',
    [
      "Oi, there's one within whistling distance.",
      "Look sharp, a claim is just around the corner.",
      "Eyes peeled, we're getting close.",
      "Hold on... there's one very nearby.",
      "Can you smell that? That's the scent of points.",
      "Nearly there, keep going.",
      "Just a smidge further. You've got this.",
      "Almost in range. Don't stop now.",
    ],
  );

  /// Returns a direction hint phrase for one of "ahead", "left", "right",
  /// "behind". Falls back to the "ahead" pool for unrecognised directions.
  static String routeHint(String direction) {
    final lists = <String, List<String>>{
      'ahead': [
        "Just keep ploughing on, mate.",
        "Bit further straight on.",
        "You're heading the right way. Carry on.",
        "Straight ahead. Simple as that.",
        "Keep going, you're on the right track.",
      ],
      'left': [
        "Veer leftward, if you've the time.",
        "Bear left a bit, I reckon.",
        "Slight left from where you're standing.",
        "Left a touch. Trust me on this one.",
        "Nudge left and you should be in luck.",
      ],
      'right': [
        "Right a bit, I reckon.",
        "Bear right from here.",
        "Try veering right, see how you get on.",
        "Bit to the right. Off you go.",
        "Right-ish. You'll figure it out.",
      ],
      'behind': [
        "You're past it. Backtrack if you fancy.",
        "It was behind you! Turn around.",
        "Looks like you overshot. Worth doubling back.",
        "Retrace your steps a little. It's back there.",
        "Behind you, I'm afraid. No shame in it.",
      ],
    };
    final pool = lists[direction];
    if (pool == null) {
      debugPrint(
          'JamesMessages.routeHint: unrecognised direction "$direction", defaulting to "ahead"');
      return routeHint('ahead');
    }
    return pool[_random.nextInt(pool.length)];
  }

  /// Fires when the user arrives at the destination.
  static const routeArrival = JamesMessage(
    'jamesRouteArrival',
    [
      "Tidy work, that.",
      "Well there you go.",
      "Right, that's a tidy round.",
      "Made it! Not bad at all.",
      "You got there in the end. Nicely done.",
      "Destination reached. I am quietly impressed.",
      "All the way there. Top effort.",
      "Job done. Time for a sit-down, I'd say.",
    ],
  );

  // ── Intro dialogue ───────────────────────────────────────────────────────

  static const _introStep2Classic = JamesMessage(
    'jamesIntroStep2',
    ['Ah, you found one!\nWhat you see here is a perfectly ordinary postbox.'],
  );

  static const _introStep2Cheeky = JamesMessage(
    'jamesIntroStep2Cheeky',
    ['Oi oi... look who it is.\nNow that, my friend, is a proper postbox.'],
  );

  /// First-launch greeting. The variant is driven by the
  /// `james_welcome_variant` Remote Config flag — defaults to the classic
  /// copy. Future variants can be added without changing call sites.
  static JamesMessage get introStep2 {
    final variant = RemoteConfigService.instance.jamesWelcomeVariant;
    return variant == RemoteConfigService.welcomeVariantCheeky
        ? _introStep2Cheeky
        : _introStep2Classic;
  }

  static const introStep3 = JamesMessage(
    'jamesIntroStep3',
    ['Do you know what I see?'],
  );
}
