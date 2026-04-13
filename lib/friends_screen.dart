import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/theme.dart';

/// Friends list and add-friend by UID.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uidController = TextEditingController();
  final _firestore = FirebaseFirestore.instance;
  bool _isAdding = false;

  // Cache name lookups so FutureBuilder doesn't re-fetch on every rebuild.
  final Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>> _nameCache = {};

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
      await _firestore.collection('users').doc(uid).update({
        'friends': FieldValue.arrayUnion([friendUid]),
      });
      Analytics.friendAdded();
      // Bust the name cache so a re-add shows fresh data.
      _nameCache.remove(friendUid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Friend added')),
        );
        _uidController.clear();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to add friend. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  Future<void> _removeFriend(String friendUid) async {
    final uid = _currentUid;
    if (uid == null) return;
    try {
      await _firestore.collection('users').doc(uid).update({
        'friends': FieldValue.arrayRemove([friendUid]),
      });
      Analytics.friendRemoved();
      // Bust the cache so re-adding this friend fetches fresh data.
      _nameCache.remove(friendUid);
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
    }
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
                return Center(
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
                );
              }
              if (!snapshot.hasData) {
                return const Center(
                    child: CircularProgressIndicator(color: postalRed));
              }
              final data = snapshot.data!.data();
              final list = data?['friends'] as List<dynamic>? ?? [];
              if (list.isEmpty) {
                return Center(
                  child: Padding(
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
                );
              }
              return ListView.builder(
                itemCount: list.length,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final friendUid = list[index] as String;
                  return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    future: _nameCache[friendUid] ??=
                        _firestore.collection('users').doc(friendUid).get(),
                    builder: (context, nameSnap) {
                      final isLoading = nameSnap.connectionState == ConnectionState.waiting;
                      final displayName = nameSnap.data?.data()?['displayName'] as String?;
                      final initials = displayName != null && displayName.length >= 2
                          ? displayName.substring(0, 2).toUpperCase()
                          : '?';
                      return Card(
                        child: ListTile(
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
                          trailing: IconButton(
                            icon: Icon(Icons.person_remove_outlined,
                                color: Theme.of(context).colorScheme.onSurfaceVariant),
                            tooltip: 'Remove friend',
                            onPressed: () => _removeFriend(friendUid),
                          ),
                        ),
                      );
                    },
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
