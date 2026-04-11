import 'package:flutter/material.dart';
import 'package:postbox_game/theme.dart';

/// Shared monarch cipher metadata used across Nearby, Claim, and other screens.
abstract final class MonarchInfo {
  MonarchInfo._();

  /// Human-readable labels for each royal cipher.
  static const Map<String, String> labels = {
    'EIIR': 'Elizabeth II (1952–2022)',
    'CIIIR': 'Charles III (2022–)',
    'GVIR': 'George VI (1936–1952)',
    'GVR': 'George V (1910–1936)',
    'EVIIIR': 'Edward VIII (1936)',
    'EVIIR': 'Edward VII (1901–1910)',
    'VR': 'Victoria (1840–1901)',
    'GR': 'George (generic)',
  };

  /// Display colours for each cipher.
  static const Map<String, Color> colors = {
    'EIIR': postalRed,
    'CIIIR': postalRed,
    'GVIR': Colors.indigo,
    'GVR': Colors.teal,
    'EVIIIR': postalGold,
    'EVIIR': Colors.deepPurple,
    'VR': Colors.amber,
    'GR': Colors.blueGrey,
  };

  /// Ciphers that are considered rare (shown with a star badge).
  static const Set<String> rareCiphers = {'EVIIIR', 'CIIIR'};

  /// Ciphers that are considered historic (shown with a "Historic" badge).
  static const Set<String> historicCiphers = {'VR', 'EVIIR'};

  /// All known ciphers in display order — used for quiz answer pools etc.
  static const List<String> all = [
    'EIIR', 'CIIIR', 'GR', 'GVR', 'GVIR', 'VR', 'EVIIR', 'EVIIIR',
  ];
}
