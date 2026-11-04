import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/theme.dart';

/// The app theme sets `minimumSize: Size(double.infinity, 52)` on the filled
/// and outlined button themes so page CTAs stretch inside a Column. In an
/// [AlertDialog] the actions are laid out by [OverflowBar], where that infinite
/// minimum makes a single button consume the whole action row and pushes the
/// bar into its vertical overflow layout — Cancel and the confirm button end up
/// stacked instead of side by side.
void main() {
  Future<void> pumpDialog(WidgetTester tester, {ButtonStyle? style}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Sign out'),
                  content: const Text('Are you sure you want to sign out?'),
                  actions: [
                    TextButton(onPressed: () {}, child: const Text('Cancel')),
                    FilledButton(
                      style: style,
                      onPressed: () {},
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('unstyled dialog action stretches across the action row',
      (tester) async {
    await pumpDialog(tester);
    final confirm = tester.getRect(find.widgetWithText(FilledButton, 'Sign out'));
    final cancel = tester.getRect(find.widgetWithText(TextButton, 'Cancel'));
    // Documents the defect: the buttons do not share a row.
    expect(confirm.top, greaterThanOrEqualTo(cancel.bottom));
    expect(confirm.width, greaterThan(200));
  });

  testWidgets('dialogActionStyle keeps the action sized to its content',
      (tester) async {
    await pumpDialog(tester, style: dialogActionStyle());
    final confirm = tester.getRect(find.widgetWithText(FilledButton, 'Sign out'));
    final cancel = tester.getRect(find.widgetWithText(TextButton, 'Cancel'));
    // Side by side, and no longer hogging the row.
    expect(confirm.width, lessThan(200));
    expect(confirm.top, lessThan(cancel.bottom));
  });
}
