import 'package:flutter/material.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/theme.dart';

class ViewToggle extends StatelessWidget {
  const ViewToggle({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final ViewMode mode;
  final ValueChanged<ViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ViewMode>(
      segments: const [
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
      ],
      selected: {mode},
      onSelectionChanged: (selection) => onChanged(selection.first),
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: postalRed,
        selectedForegroundColor: Colors.white,
      ),
    );
  }
}
