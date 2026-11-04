import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/deep_links.dart';
import 'package:postbox_game/display_name_utils.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/services/friends_repository.dart';
import 'package:postbox_game/services/invite_service.dart';
import 'package:postbox_game/services/perf_service.dart';
import 'package:postbox_game/services/user_properties_publisher.dart';
import 'package:postbox_game/user_profile_page.dart';
import 'package:postbox_game/widgets/invite_accept_flow.dart';
import 'package:postbox_game/widgets/stale_data_chip.dart';
import 'package:postbox_game/services/connectivity_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:share_plus/share_plus.dart';

/// Play Store listing for the app, built from the Android applicationId.
const String _playStoreUrl =
    'https://play.google.com/store/apps/details?id=com.code418.postbox_game';

/// App Store listing, from the app's Apple ID in App Store Connect.
const String _appStoreUrl = 'https://apps.apple.com/app/id6819213888';

/// Builds the invite message shared via the OS share sheet.
///
/// With the sender's invite [code] it is one link: tapping it opens the app
/// (or the invite page, which picks the right store) and adds the two players
/// as friends both ways. The code is spelled out too, for anyone who installs
/// first and has to type it.
///
/// Without a code (offline, or the invite backend unreachable) it falls back
/// to the [uid] plus both store links, labelled. The recipient's phone is
/// unknown, so the sender's own store comes first ([platform], defaulting to
/// this device), since friends tend to share a platform.
String buildInviteMessage(String uid, {String? code, TargetPlatform? platform}) {
  if (code != null) {
    return "Join me on The Postbox Game! Hunt down Britain's historic "
        'postboxes, claim them for points and climb the leaderboards.\n\n'
        'Tap to add me as a friend: ${inviteUrlFor(code)}\n\n'
        'Or enter my invite code in Friends: ${formatInviteCode(code)}';
  }
  final ios = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
  const iphone = 'iPhone: $_appStoreUrl';
  const android = 'Android: $_playStoreUrl';
  return "Join me on Postbox Game! Hunt down Britain's historic postboxes, "
      'claim them for points and climb the leaderboards.\n\n'
      'Add me as a friend with my UID: $uid\n\n'
      '${ios ? '$iphone\n$android' : '$android\n$iphone'}';
}

/// Friends list and add-friend by UID.
/// Display names learned from one batched `users` lookup of [batch], given
/// the docs it returned ([found]: uid → displayName).
///
/// A uid the SERVER says has no user doc is a deleted account, and gets the
/// empty-string marker that renders "Unknown player" rather than a loader
/// forever. Only the server can say so: offline, the query answers from the
/// local cache without throwing, so a friend who simply isn't cached yet was
/// labelled deleted for the rest of the session. Those stay unresolved for a
/// retry instead.
@visibleForTesting
Map<String, String> namesFromLookup(
  List<String> batch,
  Map<String, String?> found, {
  required bool fromCache,
}) =>
    {
      for (final e in found.entries) e.key: e.value ?? '',
      if (!fromCache)
        for (final uid in batch)
          if (!found.containsKey(uid)) uid: '',
    };

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  // Must match the `request.resource.data.friends.size() <= 200` check in
  // firestore.rules (pinned by a test).
  static const int maxFriends = FriendsRepository.maxFriends;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _uidController = TextEditingController();
  final _firestore = FirebaseFirestore.instance;
  final _friendsRepository = FriendsRepository();
  bool _isAdding = false;

  /// This player's invite code; null until fetched, or if it can't be (the
  /// banner and the invite message then fall back to the UID).
  String? _inviteCode;
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

  /// Players who have this player on THEIR list ("Added you"). Adding is
  /// one-way, so these are the people to offer an add-back to. Listened to
  /// once here rather than via StreamBuilder because the section appears in
  /// both the empty and the populated list, and a Firestore query stream
  /// shouldn't be re-subscribed on every switch between them.
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _addedYouSub;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _addedYou = const [];
  final Set<String> _addingBackUids = {};

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      // includeMetadataChanges so StaleDataChip learns when the cached copy
      // is confirmed by the server (see leaderboard_screen.dart).
      _friendsStream = _firestore
          .collection('users')
          .doc(uid)
          .snapshots(includeMetadataChanges: true);
      _addedYouSub = _firestore
          .collection('users')
          .where('friends', arrayContains: uid)
          .limit(50)
          .snapshots()
          .listen((snap) {
        if (mounted) setState(() => _addedYou = snap.docs);
      }, onError: (_) {
        // Non-critical: the list simply doesn't appear.
      });
      unawaited(_loadInviteCode(uid));
    }
    WidgetsBinding.instance.addObserver(this);
    ConnectivityService.instance.online.addListener(_onConnectivityChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ConnectivityService.instance.online.removeListener(_onConnectivityChanged);
    _addedYouSub?.cancel();
    _uidController.dispose();
    super.dispose();
  }

  // This screen stays mounted for the whole session (Home's IndexedStack), and
  // names were otherwise fetched only when the friends list changed: a lookup
  // that failed offline never retried, and a friend's rename never showed.
  // Re-resolve on the two moments that can fix both.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshNames();
  }

  void _onConnectivityChanged() {
    if (ConnectivityService.instance.online.value) _refreshNames();
  }

  /// Re-fetch every current friend's name in place (no flash back to
  /// "Loading..."): retries lookups that couldn't complete and picks up
  /// renames.
  void _refreshNames() {
    if (_knownUids.isEmpty) return;
    unawaited(_fetchNames(_knownUids.toList()));
  }

  Future<void> _loadInviteCode(String uid) async {
    final code = await InviteService.myCode(uid);
    if (mounted && code != null) setState(() => _inviteCode = code);
  }

  /// The add field takes an invite code or link (a mutual add, via the
  /// server) or, for codes shared before invites existed, a raw UID (a
  /// one-way add, as before).
  Future<void> _submitAddField() async {
    final text = _uidController.text.trim();
    final code = parseInviteInput(text);
    if (code == null) return _addFriendByUid(text);
    if (_isAdding) return;
    setState(() => _isAdding = true);
    unawaited(Analytics.inviteLinkOpened(source: 'typed'));
    try {
      final added = await runInviteAcceptFlow(context, code);
      if (added && mounted) _uidController.clear();
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  Future<void> _addFriendByUid(String friendUid) async {
    if (_isAdding) return;
    if (MaintenanceGuard.blocked(context, actionLabel: 'add a friend')) {
      return;
    }
    final uid = _currentUid;
    if (uid == null) return;
    setState(() => _isAdding = true);
    try {
      final result = await _friendsRepository.addByUid(uid, friendUid);
      if (result == AddFriendResult.added) {
        // Bust the name cache so a re-add shows fresh data.
        _namesByUid.remove(friendUid);
        _knownUids = _knownUids.where((u) => u != friendUid).toSet();
        _uidController.clear();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(addFriendMessage(result))),
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
            'Remove $who from your friends list? You\'ll need their invite code to add them again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: dialogActionStyle(),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (MaintenanceGuard.blocked(context, actionLabel: 'remove a friend')) {
      return;
    }

    setState(() => _removingUids.add(friendUid));
    try {
      await _firestore.collection('users').doc(uid).update({
        'friends': FieldValue.arrayRemove([friendUid]),
      });
      Analytics.friendRemoved();
      // Re-read users/{uid} via the publisher to refresh friend_count_bucket
      // (and any other property that may have changed since auth init).
      unawaited(publishUserPropertiesFromFirestore(uid));
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
    final results = await PerfService.traceAsync(
      PerfTraces.friendsLoad,
      (trace) async {
        trace.setMetric(PerfTraces.metricCount, uids.length);
        return Future.wait(batches.map((batch) async {
          try {
            final snap = await _firestore
                .collection('users')
                .where(FieldPath.documentId, whereIn: batch)
                .get();
            return (batch: batch, snap: snap);
          } catch (_) {
            return (batch: batch, snap: null);
          }
        }));
      },
    );
    if (!mounted) return;
    setState(() {
      for (final (:batch, :snap) in results) {
        if (snap == null) continue; // failed: leave unresolved for a retry
        _namesByUid.addAll(namesFromLookup(
          batch,
          {
            for (final doc in snap.docs)
              doc.id: doc.data()['displayName'] as String?,
          },
          fromCache: snap.metadata.isFromCache,
        ));
      }
    });
  }

  /// Copies the invite link (or, without a code, the UID) for pasting
  /// into a chat.
  void _copyInvite() {
    final code = _inviteCode;
    Clipboard.setData(ClipboardData(
        text: code != null ? inviteUrlFor(code) : (_currentUid ?? '')));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(code != null
            ? 'Invite link copied to clipboard'
            : 'UID copied to clipboard')));
  }

  Future<void> _shareApp() async {
    final uid = _currentUid ?? '';
    final result = await SharePlus.instance.share(
      ShareParams(
          text: buildInviteMessage(uid, code: _inviteCode),
          subject: 'The Postbox Game'),
    );
    if (result.status == ShareResultStatus.success ||
        result.status == ShareResultStatus.unavailable) {
      unawaited(Analytics.share(
        contentType: 'invite',
        itemId: _inviteCode != null ? 'invite_link' : 'uid',
        method: result.raw.isNotEmpty ? result.raw : 'unknown',
      ));
    }
  }

  Future<void> _addBack(String friendUid) async {
    final uid = _currentUid;
    if (uid == null || _addingBackUids.contains(friendUid)) return;
    if (MaintenanceGuard.blocked(context, actionLabel: 'add a friend')) {
      return;
    }
    setState(() => _addingBackUids.add(friendUid));
    try {
      final result = await _friendsRepository.addByUid(uid, friendUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(addFriendMessage(result))),
      );
    } finally {
      if (mounted) setState(() => _addingBackUids.remove(friendUid));
    }
  }

  /// "Added you": players with this player on their list who aren't on
  /// this player's yet, each with a one-tap add back. Empty when there are
  /// none, so it costs nothing on screen.
  Widget _addedYouSection(List<String> friends) {
    final me = _currentUid;
    final mine = friends.toSet();
    final pending = _addedYou
        .where((d) => d.id != me && !mine.contains(d.id))
        .toList();
    if (pending.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Text('Added you',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          for (final doc in pending)
            Card(
              child: ListTile(
                onTap: () =>
                    Navigator.of(context).push(UserProfilePage.route(doc.id)),
                leading: CircleAvatar(
                  backgroundColor: postalGold,
                  child: Text(
                    initialsFor(
                        (doc.data()['displayName'] as String?) ?? ''),
                    style: const TextStyle(
                      color: royalNavy,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                title: Text(
                  ((doc.data()['displayName'] as String?)?.trim().isNotEmpty ??
                          false)
                      ? (doc.data()['displayName'] as String).trim()
                      : 'A player',
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: const Text('Has you as a friend'),
                // The theme gives filled buttons an infinite minimum width
                // (page-level CTAs); inside a ListTile that is an unbounded
                // layout, so pin a finite one.
                trailing: FilledButton.tonal(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                  onPressed: _addingBackUids.contains(doc.id)
                      ? null
                      : () => _addBack(doc.id),
                  child: const Text('Add back'),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
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
        // Your invite code (or UID) banner
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
                  _inviteCode != null
                      ? 'Your invite code: ${formatInviteCode(_inviteCode!)}'
                      : 'Your UID: $uid',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: _inviteCode != null ? 'Copy invite link' : 'Copy UID',
                onPressed: _copyInvite,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),

        // Invite / share the app
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _shareApp,
              icon: const Icon(Icons.share, size: 18),
              label: const Text('Invite friends to play'),
            ),
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
                      labelText: 'Friend\'s invite code',
                      prefixIcon: Icon(Icons.person_add_outlined),
                      hintText: 'e.g. ABCD-2345, or paste their link',
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) {
                      if (_formKey.currentState?.validate() ?? false) {
                        _submitAddField();
                      }
                    },
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Enter an invite code'
                        : null,
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
                              _submitAddField();
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
              // Defensive: filter to strings only. Firestore rules cap the
              // array length but don't enforce element types, so a corrupted
              // doc (e.g. from a future schema change or malicious client)
              // could otherwise crash the ListView's `as String` cast below.
              final list = (data?['friends'] as List<dynamic>? ?? const [])
                  .whereType<String>()
                  .toList();
              // Schedule a batched lookup for any uid we haven't resolved yet.
              // This runs once per friend-set change; per-row reads are gone.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _ensureNames(list.toSet());
              });

              if (list.isEmpty) {
                return ListView(
                  padding: const EdgeInsets.only(bottom: kJamesStripClearance),
                  children: [
                    _addedYouSection(list),
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
                            'Tap "Invite friends to play" above and send your link. Anyone who joins with it is added both ways.',
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
              // v1.5 offline play: persistence serves this stream from the
              // local cache while offline — right behaviour, but say so.
              final fromCache = snapshot.data!.metadata.isFromCache;
              return Column(children: [
                StaleDataChip(visible: fromCache),
                Expanded(
                    child: ListView.builder(
                // Item 0 is the "Added you" section (zero-height when empty).
                itemCount: list.length + 1,
                padding: const EdgeInsets.only(
                    top: AppSpacing.sm, bottom: 100),
                itemBuilder: (context, i) {
                  if (i == 0) return _addedYouSection(list);
                  final index = i - 1;
                  final friendUid = list[index];
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
              )),
              ]);
            },
          ),
        ),
      ],
    );
  }
}
