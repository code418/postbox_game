import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/leaderboard_screen.dart';

void main() {
  group('notOnBoardText', () {
    test('a board that is not full means the player has not scored', () {
      // Boards omit zero scores, so this player is unranked, not "outside
      // the top 4".
      expect(notOnBoardText('daily', 4), contains('No points today yet'));
      expect(notOnBoardText('weekly', 0), contains('this week'));
      expect(notOnBoardText('monthly', 99), contains('this month'));
      expect(notOnBoardText('lifetime', 12), contains('first postbox'));
      for (final p in ['daily', 'weekly', 'monthly', 'lifetime']) {
        expect(notOnBoardText(p, kLeaderboardSize - 1),
            isNot(contains('outside the top')));
      }
    });

    test('only a full board says the player is outside the top N', () {
      expect(notOnBoardText('daily', kLeaderboardSize),
          'You\'re outside the top $kLeaderboardSize — keep claiming to climb!');
      expect(notOnBoardText('lifetime', kLeaderboardSize),
          'You\'re outside the top $kLeaderboardSize — keep exploring!');
    });
  });
}
