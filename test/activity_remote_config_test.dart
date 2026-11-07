import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/remote_config_service.dart';

class _RC extends Fake implements FirebaseRemoteConfig {
  _RC(this.values);
  final Map<String, Object> values;
  @override
  bool getBool(String key) => values[key] == true;
  @override
  int getInt(String key) => (values[key] as int?) ?? 0;
  @override
  String getString(String key) => (values[key] as String?) ?? '';
  @override
  double getDouble(String key) => 0.0;
}

RemoteConfigService _svc(Map<String, Object> v) => RemoteConfigService(remoteConfig: _RC(v));

void main() {
  test('workout claims are off by default and need enabled && !killed', () {
    expect(RemoteConfigService.defaults[RemoteConfigService.keyActivityClaimsEnabled], false);
    expect(_svc({}).activityClaimsAvailable, isFalse);
    expect(_svc({RemoteConfigService.keyActivityClaimsEnabled: true}).activityClaimsAvailable, isTrue);
    expect(
        _svc({
          RemoteConfigService.keyActivityClaimsEnabled: true,
          RemoteConfigService.keyKillSwitchActivityClaims: true,
        }).activityClaimsAvailable,
        isFalse);
  });

  test('grace hours are bounded', () {
    expect(_svc({RemoteConfigService.keyActivityClaimGraceHours: 48}).activityClaimGraceHours, 48);
    for (final bad in [0, 169, -5]) {
      expect(_svc({RemoteConfigService.keyActivityClaimGraceHours: bad}).activityClaimGraceHours,
          RemoteConfigService.defaultActivityClaimGraceHours);
    }
  });

  test('the origin allowlist parses, de-duplicates and falls back on junk', () {
    expect(
        _svc({RemoteConfigService.keyActivityOriginAllowlist: '["com.strava","com.strava"]'})
            .activityOriginAllowlist,
        ['com.strava']);
    final fallback = RemoteConfigService.parseOriginAllowlist(RemoteConfigService.defaultActivityOriginAllowlistJson);
    expect(fallback, contains('com.fitbit.FitbitMobile'));
    for (final bad in ['', '[]', '{}', 'nope', '["not a package"]', '[1]']) {
      expect(_svc({RemoteConfigService.keyActivityOriginAllowlist: bad}).activityOriginAllowlist, fallback,
          reason: bad);
    }
  });
}
