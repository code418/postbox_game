import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/remote_config_service.dart';

/// Minimal stand-in for [FirebaseRemoteConfig]. We only need [getBool] and
/// [getString] for the maintenance flag — anything else would be a bug.
class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  _StubRemoteConfig({required this.maintenance, this.message = ''});

  bool maintenance;
  String message;

  @override
  bool getBool(String key) =>
      key == RemoteConfigService.keyMaintenanceMode ? maintenance : false;

  @override
  String getString(String key) =>
      key == RemoteConfigService.keyMaintenanceMessage ? message : '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(RemoteConfigService.resetForTest);

  Future<BuildContext> pumpHarness(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        }),
      ),
    ));
    return captured;
  }

  testWidgets('returns false and shows no snackbar when maintenance is off',
      (tester) async {
    RemoteConfigService.instance = RemoteConfigService(
      remoteConfig: _StubRemoteConfig(maintenance: false),
    );

    final ctx = await pumpHarness(tester);
    final blocked = MaintenanceGuard.blocked(ctx, actionLabel: 'claim');
    await tester.pump();

    expect(blocked, isFalse);
    expect(MaintenanceGuard.isOn, isFalse);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
      'returns true and shows a snackbar in James voice when maintenance is on',
      (tester) async {
    RemoteConfigService.instance = RemoteConfigService(
      remoteConfig: _StubRemoteConfig(
        maintenance: true,
        message: 'Back in five minutes, postie...',
      ),
    );

    final ctx = await pumpHarness(tester);
    final blocked = MaintenanceGuard.blocked(ctx, actionLabel: 'claim');
    await tester.pump();

    expect(blocked, isTrue);
    expect(MaintenanceGuard.isOn, isTrue);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.textContaining('claim'),
      findsOneWidget,
      reason: 'actionLabel must surface in the toast',
    );
    expect(
      find.textContaining('Back in five minutes, postie...'),
      findsOneWidget,
      reason: 'admin-authored message must surface in the toast',
    );
  });

  testWidgets('falls back to the default message when remote string is empty',
      (tester) async {
    RemoteConfigService.instance = RemoteConfigService(
      remoteConfig: _StubRemoteConfig(maintenance: true),
    );

    final ctx = await pumpHarness(tester);
    MaintenanceGuard.blocked(ctx);
    await tester.pump();

    expect(
      find.textContaining(RemoteConfigService.defaultMaintenanceMessage),
      findsOneWidget,
    );
  });
}
