import 'package:flutter/material.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/theme.dart';

class ViewToggle extends StatelessWidget {
  const ViewToggle({
    super.key,
    required this.mode,
    required this.onChanged,
    this.expand = false,
  });

  final ViewMode mode;
  final ValueChanged<ViewMode> onChanged;

  /// When true, each segment stretches to share the available width equally.
  /// SegmentedButton sizes to intrinsic content by default; we coerce equal-
  /// width segments via a per-segment `minimumSize` derived from the parent's
  /// constraints.
  final bool expand;

  static const _segments = <ButtonSegment<ViewMode>>[
    ButtonSegment(
      value: ViewMode.list,
      icon: Icon(Icons.list),
      label: Text('List'),
    ),
    ButtonSegment(
      value: ViewMode.map,
      icon: Icon(Icons.map_outlined),
      label: Text('Map'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (!expand) {
      return SegmentedButton<ViewMode>(
        segments: _segments,
        selected: {mode},
        onSelectionChanged: (s) => onChanged(s.first),
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: postalRed,
          selectedForegroundColor: Colors.white,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // SegmentedButton renders the outer border (~1 px each side) inside
        // its width, so subtract a tiny margin to avoid rounding the last
        // segment a hair too wide and clipping.
        final segWidth = (constraints.maxWidth - 2) / _segments.length;
        return SegmentedButton<ViewMode>(
          segments: _segments,
          selected: {mode},
          onSelectionChanged: (s) => onChanged(s.first),
          style: SegmentedButton.styleFrom(
            selectedBackgroundColor: postalRed,
            selectedForegroundColor: Colors.white,
            minimumSize: Size(segWidth, 40),
          ),
        );
      },
    );
  }
}
