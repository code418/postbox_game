import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/display_name_utils.dart';
import 'package:postbox_game/user_profile_page.dart';
import 'package:postbox_game/theme.dart';

/// Friends list and add-friend by UID.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  // Must match the `request.resource.data.friends.size() <= 200` check in
  // firestore.rules — that is the server-enforced cap; this one is the
  // client-side pre-check so users get a friendly error before the write.
  static const int maxFriends = 200;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uidController = TextEditingController();
  final _firestore = FirebaseFirestore.instance;
  bool _isAdding = false;
  final Set<String> _removingUids = {};

  // Batched display-name lookups: the StreamBuilder fires _ensureNames whenever
  // the friends list changes; that method splits unknown uids into whereIn
  // batches of 30 and stores the resolved names in _namesByUid. The list view
  // reads straight from this map. A per-friend FutureBuilder issued one read
  // per row, so a 200-friend list paid 200 round-trips on first render — this
  // brings it down to ⌈N/30⌉ batches running in parallel.
  final Map<String, String> _namesByUid = {};
  Set<String> _knownUids = const {};

  String? get _currentUid => FirebaseAuth.instance.currentUser?.uid;

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _friendsStream;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _friendsStream = _firestore.collection('users').doc(uid).snapshots();
    }
  }

  @override
  void dispose() {
    _uidController.dispose();
    super.dispose();
  }

  Future<void> _addFriendByUid(String friendUid) async {
    if (_isAdding) return;
    setState(() => _isAdding = true);
    try {
      final uid = _currentUid;
      if (uid == null) return;
      if (uid == friendUid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You can\'t add yourself')),
          );
        }
        return;
      }
      // Check the friend exists AND whether they're already in the list.
      final results = await Future.wait([
        _firestore.collection('users').doc(friendUid).get(),
        _firestore.collection('users').doc(uid).get(),
      ]);
      final friendDoc = results[0];
      final myDoc = results[1];
      if (!friendDoc.exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No player found with that UID')),
          );
        }
        return;
      }
      final existingFriends = (myDoc.data()?['friends'] as List<dynamic>?) ?? [];
      if (existingFriends.contains(friendUid)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Already in your friends list')),
          );
        }
        return;
      }
      if (existingFriends.length >= FriendsScreen.maxFriends) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Friends list is full (${FriendsScreen.maxFriends} maximum)'),
            ),
          );
        }
        return;
      }
      await _firestore.collection('users').doc(uid).update({
        'friends': FieldValue.arrayUnion([friendUid]),
      });
      Analytics.friendAdded();
      // Bust the name cache so a re-add shows fresh data.
      _namesByUid.remove(friendUid);
      _knownUids = _knownUids.where((u) => u != friendUid).toSet();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Friend added')),
        );
        _uidController.clear();
      }
    } on FirebaseException catch (e) {
      if (!mounted) return;
      final msg = e.code == 'permission-denied'
          ? 'Friends list is full (${FriendsScreen.maxFriends} maximum)'
          : 'Failed to add friend. Please try again.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to add friend. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  Future<void> _removeFriend(String friendUid, String? displayName) async {
    if (_removingUids.contains(friendUid)) return;
    final uid = _currentUid;
    if (uid == null) return;

    // Re-adding requires re-entering the friend's UID by hand, so guard
    // against accidental taps on the remove icon with a confirmation prompt.
    final who = (displayName != null && displayName.trim().isNotEmpty)
        ? displayName.trim()
        : 'this friend';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove friend?'),
        content: Text(
            'Remove $who from your friends list? You\'ll need their UID to add them again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _removingUids.add(friendUid));
    try {
      await _firestore.collection('users').doc(uid).update({
        'friends': FieldValue.arrayRemove([friendUid]),
      });
      Analytics.friendRemoved();
      // Bust the cache so re-adding this friend fetches fresh data.
      _namesByUid.remove(friendUid);
      _knownUids = _knownUids.where((u) => u != friendUid).toSet();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Friend removed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to remove friend. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _removingUids.remove(friendUid));
    }
  }


  /// Triggers a batched fetch of any friend uids in [uids] that aren't already
  /// resolved in [_namesByUid]. Idempotent — the in-flight fetch is awaited
  /// rather than restarted, and missing uids are simply added on subsequent
  /// runs.
  void _ensureNames(Set<String> uids) {
    if (setEquals(uids, _knownUids)) return;
    _knownUids = uids;
    final unknown = uids.where((u) => !_namesByUid.containsKey(u)).toList();
    if (unknown.isEmpty) return;
    // Fire-and-forget: completion is signalled via setState inside _fetchNames.
    // Any future change to the friends list re-enters this method and resolves
    // only the newly-added uids.
    unawaited(_fetchNames(unknown));
  }

  Future<void> _fetchNames(List<String> uids) async {
    const batchSize = 30; // Firestore whereIn cap
    final batches = <List<String>>[
      for (var i = 0; i < uids.length; i += batchSize)
        uids.sublist(i, (i + batchSize).clamp(0, uids.length)),
    ];
    final results = await Future.wait(batches.map((batch) async {
      try {
        return await _firestore
            .collection('users')
            .where(FieldPath.documentId, whereIn: batch)
            .get();
      } catch (_) {
        return null;
      }
    }));
    if (!mounted) return;
    setState(() {
      for (final snap in results) {
        if (snap == null) continue;
        for (final doc in snap.docs) {
          final name = (doc.data()['displayName'] as String?) ?? '';
          _namesByUid[doc.id] = name;
        }
      }
      // Any uid in `uids` that came back missing (deleted account) gets an
      // empty-string marker so the list rendering shows "Unknown player"
      // immediately instead of spinning a loader forever.
      for (final u in uids) {
        _namesByUid.putIfAbsent(u, () => '');
      }
    });
  }

  void _copyUid() {
    final uid = _currentUid ?? '';
    Clipboard.setData(ClipboardData(text: uid));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('UID copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = _currentUid;
    if (uid == null || _friendsStream == null) {
      return const Center(child: Text('Sign in to manage friends'));
    }

    return Column(
      children: [
        // Your UID banner
        Container(
          color: postalRed.withValues(alpha:0.07),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: postalRed),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Your UID: $uid',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'Copy UID',
                onPressed: _copyUid,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),

        // Add friend form
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Form(
            key: _formKey,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _uidController,
                    decoration: const InputDecoration(
                      labelText: 'Friend UID',
                      prefixIcon: Icon(Icons.person_add_outlined),
                      hintText: 'Paste your friend\'s UID here',
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) {
                      if (_formKey.currentState?.validate() ?? false) {
                        _addFriendByUid(_uidController.text.trim());
                      }
                    },
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Enter a UID' : null,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FilledButton(
                    onPressed: _isAdding
                        ? null
                        : () {
                            if (_formKey.currentState?.validate() ?? false) {
                              _addFriendByUid(_uidController.text.trim());
                            }
                          },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 52),
                    ),
                    child: _isAdding
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Add'),
                  ),
                ),
              ],
            ),
          ),
        ),

        const Divider(height: 1),

        // Friends list
        Expanded(
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _friendsStream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: kJamesStripClearance),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, size: 48,
                            color: Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(height: AppSpacing.md),
                        Text('Could not load friends list',
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: kJamesStripClearance),
                  child: Center(child: CircularProgressIndicator(color: postalRed)),
                );
              }
              final data = snapshot.data!.data();
              final list = data?['friends'] as List<dynamic>? ?? [];
              // Schedule a batched lookup for any uid we haven't resolved yet.
              // This runs once per friend-set change; per-row reads are gone.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _ensureNames(list.whereType<String>().toSet());
              });

              if (list.isEmpty) {
                return ListView(
                  padding: const EdgeInsets.only(bottom: kJamesStripClearance),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.people_outline, size: 72,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2)),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            'No friends yet',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Share your UID (tap copy above) and ask friends to add you.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }
              return ListView.builder(
                itemCount: list.length,
                padding: const EdgeInsets.only(
                    top: AppSpacing.sm, bottom: 100),
                itemBuilder: (context, index) {
                  final friendUid = list[index] as String;
                  final resolved = _namesByUid[friendUid];
                  final isLoading = resolved == null;
                  // Empty-string marker means the batch lookup returned no
                  // user doc for this uid (deleted account, etc.).
                  final displayName =
                      (resolved != null && resolved.isNotEmpty) ? resolved : null;
                  final initials = initialsFor(displayName ?? '');
                  return Card(
                    child: ListTile(
                      onTap: () => Navigator.of(context).push(UserProfilePage.route(friendUid)),
                      leading: CircleAvatar(
                        backgroundColor: postalRed,
                        child: isLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                initials,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                      ),
                      title: isLoading
                          ? Text(
                              'Loading...',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                            )
                          : Text(
                              displayName ?? 'Unknown player',
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: _removingUids.contains(friendUid)
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: postalRed,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: Icon(Icons.person_remove_outlined,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                              tooltip: 'Remove friend',
                              onPressed: () =>
                                  _removeFriend(friendUid, displayName),
                            ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
