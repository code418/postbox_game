import 'package:postbox_game/monarch_info.dart';

/// The phone's cipher label without its parenthetical (reign years /
/// "Scotland only"): "Elizabeth II (1952–2022)" wraps inside a watch-width
/// option button, and a two-line label makes the next row overrun the round
/// display's inscribed square.
///
/// Shared by every Wear surface that names a cipher (the claim quiz and the
/// today's-claims glance) so the shortening can't drift between them.
String watchMonarchLabel(String code) {
  final label = MonarchInfo.labels[code] ?? code;
  return label.replaceFirst(RegExp(r'\s*\([^)]*\)$'), '');
}
