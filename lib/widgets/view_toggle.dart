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

  /// When true, the toggle stretches to the full available width and the two
  /// segments share it equally. SegmentedButton only distributes width across
  /// its segments when handed a *tight* width constraint; under the loose
  /// constraints it gets from a centred Column it otherwise shrinks to intrinsic
  /// size, which on a narrow phone clips the "Map" label to "Ma".
  final bool expand;

  static const _segments = <ButtonSegment<ViewMode>>[
    ButtonSegment(
      value: ViewMode.list,
      icon: Icon(Icons.list),
      label: Text('List', maxLines: 1, softWrap: false),
    ),
    ButtonSegment(
      value: ViewMode.map,
      icon: Icon(Icons.map_outlined),
      label: Text('Map', maxLines: 1, softWrap: false),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final button = SegmentedButton<ViewMode>(
      segments: _segments,
      selected: {mode},
      onSelectionChanged: (s) => onChanged(s.first),
      // Keep each segment's own icon when selected instead of swapping in a
      // check mark: the swap changes the segment's width and, in the equal-
      // width layout, squeezes the "Map" label until it wraps/clips.
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: postalRed,
        selectedForegroundColor: Colors.white,
        minimumSize: const Size(0, 40),
      ),
    );
    // A tight full-width constraint makes SegmentedButton expand its segments to
    // fill the row; without it the button stays at intrinsic width.
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
