import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // Cache name lookups so FutureBuilder doesn't re-fetch on every rebuild.
  final Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>> _nameCache = {};

  String? get _currentUid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void dispose() {
    _uidController.dispose();
    super.dispose();
  }

  Future<void> _addFriendByUid(String friendUid) async {
    final uid = _currentUid;
    if (uid == null) return;
    if (uid == friendUid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You can\'t add yourself')),
      );
      return;
    }
    try {
      final userDoc = await _firestore.collection('users').doc(friendUid).get();
      if (!userDoc.exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No player found with that UID')),
          );
        }
        return;
      }
      await _firestore.collection('users').doc(uid).set({
        'friends': FieldValue.arrayUnion([friendUid]),
      }, SetOptions(merge: true));
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
          SnackBar(content: Text('Failed to add friend: $e')),
        );
      }
    }
  }

  Future<void> _removeFriend(String friendUid) async {
    final uid = _currentUid;
    if (uid == null) return;
    try {
      await _firestore.collection('users').doc(uid).update({
        'friends': FieldValue.arrayRemove([friendUid]),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Friend removed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove: $e')),
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
    if (uid == null) {
      return const Center(child: Text('Sign in to manage friends'));
    }

    final friendsRef = _firestore.collection('users').doc(uid).snapshots();

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
                      ?.copyWith(color: Colors.grey.shade700),
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
                    onPressed: () {
                      if (_formKey.currentState?.validate() ?? false) {
                        _addFriendByUid(_uidController.text.trim());
                      }
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 52),
                    ),
                    child: const Text('Add'),
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
            stream: friendsRef,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
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
                        Icon(Icons.people_outline,
                            size: 72, color: Colors.grey.shade300),
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
                              ?.copyWith(color: Colors.grey),
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
                      final displayName = nameSnap.data?.data()?['displayName'] as String?;
                      final label = displayName ?? friendUid;
                      final initials = label.length >= 2
                          ? label.substring(0, 2).toUpperCase()
                          : label.toUpperCase();
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: postalRed,
                            child: Text(
                              initials,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          title: Text(label, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            displayName != null ? friendUid : 'UID',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Colors.grey.shade500,
                                ),
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.person_remove_outlined,
                                color: Colors.grey.shade500),
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
