class Validators {
  static final RegExp _emailRegExp = RegExp(
    r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$',
  );

  // Minimum 6 characters, any characters — matches Firebase Auth minimum
  // and the helper text shown in the registration form.
  static final RegExp _passwordRegExp = RegExp(r'^.{6,}$');

  static bool isValidEmail(String email) {
    return _emailRegExp.hasMatch(email);
  }

  static bool isValidPassword(String password) {
    return _passwordRegExp.hasMatch(password);
  }

  // Basic profanity block-list. Matched against the lower-cased, trimmed name.
  // Extend this list as needed; the check is intentionally not exhaustive —
  // it catches obvious cases without being an arms race.
  // Matched as a substring (lower-cased), so entries must avoid common English
  // substrings to dodge the Scunthorpe problem. Previously included 'arse'
  // (Arsenal, parser), 'cock' (Cockburn, Hancock, peacock), 'dick' (Richard,
  // Dickson), 'mong' (among, monger, Mongolia) and 'spic' (spice, suspicion)
  // — all removed because they rejected legitimate names. The remaining
  // entries have few false positives in display names.
  static const _blockedWords = <String>[
    // General English profanity
    'fuck', 'shit', 'cunt', 'bitch', 'bastard', 'asshole', 'arsehole',
    'twat', 'prick', 'pussy', 'wank', 'wanker',
    // British swear words & insults
    'bollocks', 'bellend', 'tosser', 'shite', 'knobhead', 'knobend',
    'gobshite', 'minge', 'slag', 'slapper', 'slut', 'whore',
    'bugger', 'pillock', 'plonker', 'numpty', 'muppet',
    // Slurs
    'nigger', 'nigga', 'chink', 'kike', 'faggot', 'retard',
    'paki', 'spaz', 'nonce'
  ];

  static bool isValidDisplayName(String name) {
    final t = name.trim();
    if (t.length < 2 || t.length > 30) return false;
    final lower = t.toLowerCase();
    for (final word in _blockedWords) {
      if (lower.contains(word)) return false;
    }
    return true;
  }

  /// Returns a human-readable reason why a display name is invalid, or null if valid.
  static String? displayNameError(String name) {
    final t = name.trim();
    if (t.length < 2) return 'Name must be at least 2 characters';
    if (t.length > 30) return 'Name must be 30 characters or fewer';
    final lower = t.toLowerCase();
    for (final word in _blockedWords) {
      if (lower.contains(word)) return 'That name isn\'t allowed';
    }
    return null;
  }
}
