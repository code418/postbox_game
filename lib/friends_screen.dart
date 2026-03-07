import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Friends list and add-friend by UID (or email when backend supports lookup).
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({Key? key}) : super(key: key);

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uidController = TextEditingController();
  final _firestore = FirebaseFirestore.instance;

  String? get _currentUid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void dispose() {
    _uidController.dispose();
    super.dispose();
  }

  Future<void> _addFriendByUid(String friendUid) async {
    final uid = _currentUid;
    if (uid == null || uid == friendUid) return;
    try {
      await _firestore.collection('users').doc(uid).set({
        'friends': FieldValue.arrayUnion([friendUid]),
      }, SetOptions(merge: true));
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

  @override
  Widget build(BuildContext context) {
    final uid = _currentUid;
    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Friends')),
        body: const Center(child: Text('Sign in to manage friends')),
      );
    }

    final friendsRef = _firestore.collection('users').doc(uid).snapshots();

    return Scaffold(
      appBar: AppBar(title: const Text('Friends')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _uidController,
                      decoration: const InputDecoration(
                        labelText: 'Friend UID or email',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Enter UID' : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      if (_formKey.currentState?.validate() ?? false) {
                        _addFriendByUid(_uidController.text.trim());
                      }
                    },
                    child: const Text('Add'),
                  ),
                ],
              ),
            ),
          ),
          const Divider(),
          Expanded(
            child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: friendsRef,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.data!.data();
                final list = data?['friends'] as List<dynamic>? ?? [];
                if (list.isEmpty) {
                  return const Center(
                    child: Text('No friends yet. Add by UID above.'),
                  );
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final friendUid = list[index] as String;
                    return ListTile(
                      title: Text(friendUid),
                      trailing: IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => _removeFriend(friendUid),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
