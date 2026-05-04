import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'avatar_config.dart';
import 'postie_avatar.dart';

/// "Your Postie Profile" — the avatar workshop.
///
/// Reads users/{uid}.avatar on open, lets the user cycle / randomise parts,
/// and saves back to Firestore. Display sites (friends list, leaderboards,
/// profile) read from the same field and re-render.
class AvatarCreatorScreen extends StatefulWidget {
  const AvatarCreatorScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const AvatarCreatorScreen());

  @override
  State<AvatarCreatorScreen> createState() => _AvatarCreatorScreenState();
}

class _AvatarCreatorScreenState extends State<AvatarCreatorScreen> {
  AvatarConfig? _saved; // Last persisted version; null until loaded / first save.
  late AvatarConfig _draft;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _draft = AvatarConfig.defaultPostie();
    _load();
  }

  Future<void> _load() async {
    final uid = _uid;
    if (uid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final stored = AvatarConfig.tryFromMap(doc.data()?['avatar']);
      if (!mounted) return;
      setState(() {
        _saved = stored;
        // Surface the saved avatar (if any) so the user starts editing what
        // they already have rather than a fresh default.
        _draft = stored ?? AvatarConfig.defaultPostie();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = 'Could not load your avatar.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final uid = _uid;
    if (uid == null) return;
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set({'avatar': _draft.toMap()}, SetOptions(merge: true));
      if (!mounted) return;
      setState(() => _saved = _draft);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Avatar saved')),
      );
    } on FirebaseException catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save your avatar. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _randomise() {
    HapticFeedback.lightImpact();
    setState(() => _draft = AvatarConfig.random());
  }

  void _cycle(AvatarSlot slot, int direction) {
    setState(() => _draft = _draft.cycle(slot, direction));
  }

  void _revert() {
    final saved = _saved;
    if (saved != null) setState(() => _draft = saved);
  }

  @override
  Widget build(BuildContext context) {
    final hasUnsavedChanges = _saved != null && _saved != _draft;
    final isFirstSave = _saved == null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Postie'),
        actions: [
          IconButton(
            icon: const Icon(Icons.shuffle),
            tooltip: 'Surprise me',
            onPressed: _loading || _saving ? null : _randomise,
          ),
        ],
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.only(bottom: kJamesStripClearance),
              child: Center(child: CircularProgressIndicator(color: postalRed)),
            )
          : _loadError != null
              ? Padding(
                  padding: const EdgeInsets.only(bottom: kJamesStripClearance),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline,
                            size: 48,
                            color: Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(height: AppSpacing.md),
                        Text(_loadError!,
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md,
                      AppSpacing.md, AppSpacing.md, kJamesStripClearance + 16),
                  children: [
                    _StageCard(config: _draft),
                    const SizedBox(height: AppSpacing.md),
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.sm),
                        child: Column(
                          children: [
                            for (final slot in AvatarSlot.values)
                              _SlotRow(
                                slot: slot,
                                index: _draft[slot],
                                onPrev: () => _cycle(slot, -1),
                                onNext: () => _cycle(slot, 1),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (hasUnsavedChanges)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: OutlinedButton.icon(
                          onPressed: _saving ? null : _revert,
                          icon: const Icon(Icons.undo, size: 18),
                          label: const Text('Discard changes'),
                        ),
                      ),
                    FilledButton(
                      onPressed: _saving || (!isFirstSave && !hasUnsavedChanges)
                          ? null
                          : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : Text(isFirstSave ? 'Set as my avatar' : 'Save changes'),
                    ),
                  ],
                ),
    );
  }
}

class _StageCard extends StatelessWidget {
  final AvatarConfig config;
  const _StageCard({required this.config});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.md),
        child: Column(
          children: [
            PostieAvatar(config: config, size: 220),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Tap arrows to cycle each part — or shuffle the lot.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotRow extends StatelessWidget {
  final AvatarSlot slot;
  final int index;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  const _SlotRow({
    required this.slot,
    required this.index,
    required this.onPrev,
    required this.onNext,
  });

  Color? _swatch() {
    final hex = slot.swatchColor(index);
    if (hex == null) return null;
    final n = int.parse(hex.substring(1), radix: 16);
    return Color(0xFF000000 | n);
  }

  @override
  Widget build(BuildContext context) {
    final swatch = _swatch();
    final total = slot.length();
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              slot.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: onPrev,
            visualDensity: VisualDensity.compact,
            tooltip: 'Previous ${slot.label}',
          ),
          Expanded(
            child: Row(
              children: [
                if (swatch != null) ...[
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: swatch,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF1A1A1A), width: 1.2),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(
                  child: Text(
                    slot.optionName(index),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${index + 1}/$total',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: onNext,
            visualDensity: VisualDensity.compact,
            tooltip: 'Next ${slot.label}',
          ),
        ],
      ),
    );
  }
}
