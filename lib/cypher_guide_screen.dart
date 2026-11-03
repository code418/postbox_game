import 'package:flutter/material.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/cypher_art.dart';

/// How the Cypher guide orders its cards.
enum CypherGuideSort { reign, points }

/// A field guide to the royal cyphers: what each looks like on the box, the
/// monarch and reign, and how many points a claim scores.
///
/// Opened from the AppBar overflow menu and from the claim quiz. Points come
/// from [RemoteConfigService.pointsForCipher], the same Remote Config-aware
/// source as the rest of the app.
class CypherGuideScreen extends StatefulWidget {
  const CypherGuideScreen({super.key});

  /// Pushes the guide and logs where it was opened from (`menu` or `quiz`).
  static Future<void> open(BuildContext context, {required String source}) {
    Analytics.cypherGuideOpened(source: source);
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CypherGuideScreen()),
    );
  }

  /// [MonarchInfo.reignOrder], or highest points first with ties kept in
  /// reign order.
  static List<String> orderedCodes(
    CypherGuideSort sort,
    int Function(String code) pointsFor,
  ) {
    const reign = MonarchInfo.reignOrder;
    if (sort == CypherGuideSort.reign) return List.of(reign);
    return List.of(reign)
      ..sort((a, b) {
        final byPoints = pointsFor(b).compareTo(pointsFor(a));
        return byPoints != 0 ? byPoints : reign.indexOf(a) - reign.indexOf(b);
      });
  }

  @override
  State<CypherGuideScreen> createState() => _CypherGuideScreenState();
}

class _CypherGuideScreenState extends State<CypherGuideScreen> {
  CypherGuideSort _sort = CypherGuideSort.reign;

  @override
  Widget build(BuildContext context) {
    final rc = RemoteConfigService.instance;
    final codes = CypherGuideScreen.orderedCodes(_sort, rc.pointsForCipher);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Cypher guide')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        children: [
          Text(
            'Every postbox carries the cypher of the monarch it was made '
            'under, usually on the front, below the slot. Before you claim, '
            'you pick the one you can see. Rarer cyphers score more points.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: SegmentedButton<CypherGuideSort>(
              segments: const [
                ButtonSegment(
                  value: CypherGuideSort.reign,
                  label: Text('By reign'),
                  icon: Icon(Icons.history_edu_outlined),
                ),
                ButtonSegment(
                  value: CypherGuideSort.points,
                  label: Text('By points'),
                  icon: Icon(Icons.star_outline),
                ),
              ],
              selected: {_sort},
              onSelectionChanged: (s) => setState(() => _sort = s.first),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          for (final code in codes)
            CypherGuideCard(
              key: ValueKey('cypher-guide-$code'),
              code: code,
              points: rc.pointsForCipher(code),
            ),
          CypherGuideCard(
            key: const ValueKey('cypher-guide-${MonarchInfo.plainKey}'),
            code: MonarchInfo.plainKey,
            points: rc.pointsForCipher(MonarchInfo.plainKey),
          ),
        ],
      ),
    );
  }
}

/// One cypher in the guide: its plate, name, reign, points and what to look
/// for. [MonarchInfo.plainKey] gets a blank plate and its own explanation.
class CypherGuideCard extends StatelessWidget {
  const CypherGuideCard({super.key, required this.code, required this.points});

  final String code;
  final int points;

  static const String plainLookFor =
      'No royal cypher at all, so there is nothing to match in the quiz.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final detail = MonarchInfo.detailOf(code);
    final lookFor = code == MonarchInfo.plainKey
        ? plainLookFor
        : MonarchInfo.lookFor[code];
    final Widget? badge = MonarchInfo.rareCiphers.contains(code)
        ? const _Badge(label: 'Rare', icon: Icons.star, colour: postalGold)
        : MonarchInfo.historicCiphers.contains(code)
            ? _Badge(label: 'Historic', colour: Colors.brown.shade400)
            : null;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: MergeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm + AppSpacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CypherPlate(code, height: 84, width: 104),
              const SizedBox(width: AppSpacing.sm + AppSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            MonarchInfo.nameOf(code),
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        PointsPill(points: points),
                      ],
                    ),
                    if (detail != null || badge != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Wrap(
                          spacing: AppSpacing.sm,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (detail != null)
                              Text(detail,
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(color: muted)),
                            if (badge != null) badge,
                          ],
                        ),
                      ),
                    if (lookFor != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(lookFor, style: theme.textTheme.bodyMedium),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "N pts" in navy on a gold pill. Gold text on a light surface fails
/// contrast; this pairing reads in both themes.
class PointsPill extends StatelessWidget {
  const PointsPill({super.key, required this.points});

  final int points;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$points ${points == 1 ? 'point' : 'points'}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: 2),
        decoration: BoxDecoration(
          color: postalGold,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '$points pts',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: royalNavy,
                fontWeight: FontWeight.w800,
              ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.colour, this.icon});

  final String label;
  final Color colour;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: colour),
          const SizedBox(width: 2),
        ],
        Text(
          label,
          style: TextStyle(
              color: colour, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
