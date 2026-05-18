// Pure helpers for rendering display names. Kept here (instead of
// `validators.dart`) so import-only consumers don't pull in the full
// validation surface.

/// Returns 1–2 uppercase letters to render in a `CircleAvatar` for [name].
///
/// Rules:
/// - Empty / whitespace-only name → `?`
/// - Multi-word name → first letter of the first two words (`John Doe` → `JD`).
/// - Single-word name → first two letters (`Alice` → `AL`, `Z` → `Z`).
///
/// Shared by [FriendsScreen] (avatar in the friends list) and
/// [UserProfilePage] (large profile header avatar).
String initialsFor(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  final parts = trimmed.split(' ').where((p) => p.isNotEmpty).toList();
  if (parts.length >= 2) {
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }
  return trimmed.substring(0, trimmed.length.clamp(0, 2)).toUpperCase();
}
