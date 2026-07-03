import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/analytics_user_properties.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/county_heatmap.dart';
import 'package:postbox_game/intro.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/validators.dart';
import 'package:postbox_game/widgets/postbox_map.dart';
import 'package:postbox_game/widgets/postbox_marker.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  DistanceUnit _distanceUnit = DistanceUnit.meters;
  bool _isSaving = false;
  Position? _lastPosition;
  Map<String, bool> _notifPrefs = const {
    'friendFirstScore': true,
    'friendOvertakes': true,
    'addedAsFriend': true,
  };
  bool _notifPrefsLoaded = false;
  final _userRepository = UserRepository();

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadNotifPrefs();
    _loadLastPosition();
  }

  Future<void> _loadLastPosition() async {
    try {
      final pos = await Geolocator.getLastKnownPosition();
      if (mounted && pos != null) setState(() => _lastPosition = pos);
    } catch (_) {
      // Non-fatal — map will use London fallback.
    }
  }

  Future<void> _loadPrefs() async {
    final unit = await AppPreferences.getDistanceUnit();
    if (mounted) setState(() => _distanceUnit = unit);
  }

  Future<void> _loadNotifPrefs() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _notifPrefsLoaded = true);
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final raw = doc.data()?['notificationPrefs'] as Map<String, dynamic>?;
      if (!mounted) return;
      setState(() {
        if (raw != null) {
          _notifPrefs = {
            'friendFirstScore': raw['friendFirstScore'] as bool? ?? true,
            'friendOvertakes': raw['friendOvertakes'] as bool? ?? true,
            'addedAsFriend': raw['addedAsFriend'] as bool? ?? true,
          };
        }
        _notifPrefsLoaded = true;
      });
    } catch (_) {
      // Non-fatal — show defaults if Firestore is unavailable.
      if (mounted) setState(() => _notifPrefsLoaded = true);
    }
  }

  Future<void> _setNotifPref(String key, bool value) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (MaintenanceGuard.blocked(context,
        actionLabel: 'change notification settings')) {
      return;
    }
    // Snapshot the previous value of *this key only* so a rollback after a
    // failed write doesn't clobber a concurrent toggle of a different switch.
    // Capturing the whole map and restoring it would undo any other key's
    // in-flight optimistic update — and if that other write happened to
    // succeed, the UI would end up out of sync with the server.
    final previousValue = _notifPrefs[key];
    setState(() => _notifPrefs = {..._notifPrefs, key: value});
    try {
      // Use dot-notation update so only the toggled key is touched. A nested
      // set/merge would replace the whole notificationPrefs map, wiping any
      // future pref keys this client doesn't yet know about.
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'notificationPrefs.$key': value});
    } catch (_) {
      // Rollback only this key on write failure, and surface a snackbar so
      // the user knows their toggle didn't take (otherwise the switch
      // silently snaps back and looks like an unresponsive tap).
      if (mounted) {
        if (previousValue != null) {
          setState(() => _notifPrefs = {..._notifPrefs, key: previousValue});
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save notification setting. Please try again.'),
          ),
        );
      }
    }
  }

  Future<void> _editDisplayName() async {
    final controller = TextEditingController(
      text: FirebaseAuth.instance.currentUser?.displayName ?? '',
    );

    final String? newName;
    try {
      // errorText must live in the outer closure (not inside StatefulBuilder.builder)
      // so that setDialogState updates it by reference and it persists across rebuilds.
      String? errorText;
      newName = await showDialog<String>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (_, setDialogState) {
            void trySubmit() {
              final error = Validators.displayNameError(controller.text.trim());
              if (error != null) {
                setDialogState(() => errorText = error);
                return;
              }
              // Defer the pop by one frame so that any pending rebuilds triggered
              // by the keyboard dismissing (MediaQuery viewport insets changing)
              // can complete before the dialog's InheritedWidget subtree is torn
              // down. Popping synchronously from onPressed races with those
              // rebuilds and causes the '_dependents.isEmpty' assertion.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) Navigator.of(context).pop(controller.text.trim());
              });
            }

            return AlertDialog(
              title: const Text('Display name'),
              content: TextField(
                controller: controller,
                autofocus: true,
                maxLength: Validators.maxDisplayNameChars,
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: errorText,
                ),
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (errorText != null) setDialogState(() => errorText = null);
                },
                onSubmitted: (_) => trySubmit(),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) Navigator.of(context).pop();
                    });
                  },
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: trySubmit,
                  child: const Text('Save'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      controller.dispose();
    }

    if (newName == null || !mounted) return;
    if (MaintenanceGuard.blocked(context,
        actionLabel: 'change display name')) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await _userRepository.updateDisplayName(newName);
      if (mounted) setState(() {}); // re-reads Auth displayName in build()
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Failed to update name.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update name. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _chooseDistanceUnit() async {
    final chosen = await showModalBottomSheet<DistanceUnit>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
              child: Text('Distance units',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            RadioGroup<DistanceUnit>(
              groupValue: _distanceUnit,
              onChanged: (v) => Navigator.of(context).pop(v),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: const Text('Meters'),
                    leading: const Radio<DistanceUnit>(value: DistanceUnit.meters),
                    onTap: () => Navigator.of(context).pop(DistanceUnit.meters),
                  ),
                  ListTile(
                    title: const Text('Miles'),
                    leading: const Radio<DistanceUnit>(value: DistanceUnit.miles),
                    onTap: () => Navigator.of(context).pop(DistanceUnit.miles),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != _distanceUnit) {
      await AppPreferences.setDistanceUnit(chosen);
      if (mounted) setState(() => _distanceUnit = chosen);
    }
  }

  Future<void> _changePassword() async {
    final currentPwCtrl = TextEditingController();
    final newPwCtrl = TextEditingController();
    final confirmPwCtrl = TextEditingController();

    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) {
          bool showCurrent = false;
          bool showNew = false;
          bool showConfirm = false;
          String? currentError;
          String? newError;
          String? confirmError;
          return StatefulBuilder(
            builder: (_, setDialogState) {
              void trySubmit() {
                final ce = currentPwCtrl.text.isEmpty ? 'Required' : null;
                final ne = newPwCtrl.text.length < Validators.minPasswordChars
                    ? 'Password must be at least ${Validators.minPasswordChars} characters'
                    : null;
                final co = confirmPwCtrl.text != newPwCtrl.text
                    ? "Passwords don't match"
                    : null;
                if (ce != null || ne != null || co != null) {
                  setDialogState(() {
                    currentError = ce;
                    newError = ne;
                    confirmError = co;
                  });
                  return;
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) Navigator.of(context).pop(true);
                });
              }

              return AlertDialog(
                title: const Text('Change password'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: currentPwCtrl,
                        obscureText: !showCurrent,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Current password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          errorText: currentError,
                          suffixIcon: IconButton(
                            icon: Icon(showCurrent
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined),
                            tooltip:
                                showCurrent ? 'Hide password' : 'Show password',
                            onPressed: () =>
                                setDialogState(() => showCurrent = !showCurrent),
                          ),
                        ),
                        onChanged: (_) {
                          if (currentError != null) {
                            setDialogState(() => currentError = null);
                          }
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextField(
                        controller: newPwCtrl,
                        obscureText: !showNew,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'New password',
                          helperText:
                              'At least ${Validators.minPasswordChars} characters',
                          prefixIcon: const Icon(Icons.lock_outline),
                          errorText: newError,
                          suffixIcon: IconButton(
                            icon: Icon(showNew
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined),
                            tooltip: showNew ? 'Hide password' : 'Show password',
                            onPressed: () =>
                                setDialogState(() => showNew = !showNew),
                          ),
                        ),
                        onChanged: (_) {
                          if (newError != null) setDialogState(() => newError = null);
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextField(
                        controller: confirmPwCtrl,
                        obscureText: !showConfirm,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: 'Confirm new password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          errorText: confirmError,
                          suffixIcon: IconButton(
                            icon: Icon(showConfirm
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined),
                            tooltip:
                                showConfirm ? 'Hide password' : 'Show password',
                            onPressed: () =>
                                setDialogState(() => showConfirm = !showConfirm),
                          ),
                        ),
                        onChanged: (_) {
                          if (confirmError != null) {
                            setDialogState(() => confirmError = null);
                          }
                        },
                        onSubmitted: (_) => trySubmit(),
                      ),
                  ],
                ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) Navigator.of(context).pop(false);
                      });
                    },
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: trySubmit,
                    child: const Text('Update'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (confirmed != true || !mounted) return;
      setState(() => _isSaving = true);
      await _userRepository.changePassword(
        currentPassword: currentPwCtrl.text,
        newPassword: newPwCtrl.text,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password updated.')),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      final msg = switch (e.code) {
        'wrong-password' || 'invalid-credential' =>
          'Current password is incorrect.',
        'weak-password' => 'New password is too weak.',
        'network-request-failed' => 'No internet connection.',
        'too-many-requests' => 'Too many attempts. Please wait and try again.',
        _ => 'Could not update password. Please try again.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update password. Please try again.')),
        );
      }
    } finally {
      currentPwCtrl.dispose();
      newPwCtrl.dispose();
      confirmPwCtrl.dispose();
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      context.read<AuthenticationBloc>().add(LoggedOut());
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _deleteAccount() async {
    if (MaintenanceGuard.blocked(context, actionLabel: 'delete your account')) {
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final isPasswordUser =
        user.providerData.any((p) => p.providerId == 'password');

    // 1. Strong, irreversible-action confirmation.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded,
            color: Colors.red.shade700, size: 36),
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your account and removes your data. Your '
          'past claims are anonymised and your scores are removed from the '
          'leaderboards. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 2. Re-auth for password users (Firebase requires a recent login). Google
    //    users re-auth inside deleteAccount via the Google sign-in flow.
    String? password;
    if (isPasswordUser) {
      password = await _promptPassword();
      if (password == null || !mounted) return; // cancelled
    }

    // 3. Delete + return to the auth gate.
    setState(() => _isSaving = true);
    try {
      await _userRepository.deleteAccount(currentPassword: password);
      if (!mounted) return;
      context.read<AuthenticationBloc>().add(LoggedOut());
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      final msg = switch (e.code) {
        'wrong-password' || 'invalid-credential' => 'Password is incorrect.',
        'requires-recent-login' =>
          'Please sign out and back in, then try again.',
        'network-request-failed' => 'No internet connection.',
        'too-many-requests' => 'Too many attempts. Please wait and try again.',
        _ => 'Could not delete your account. Please try again.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not delete your account. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Prompts for the current password (password-provider re-auth). Returns the
  /// entered value, or null if the user cancelled.
  Future<String?> _promptPassword() async {
    final ctrl = TextEditingController();
    bool show = false;
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Confirm your password'),
            content: TextField(
              controller: ctrl,
              obscureText: !show,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(show
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  tooltip: show ? 'Hide password' : 'Show password',
                  onPressed: () => setDialogState(() => show = !show),
                ),
              ),
              onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _showAbout() async {
    // Read pubspec version at runtime so the dialog never drifts behind a
    // released `1.0.0+N` bump. PackageInfo.fromPlatform() is a no-op on
    // platforms without a native bridge — guard the call so the About dialog
    // still opens (without a version) on web/desktop.
    String version = '';
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.buildNumber.isNotEmpty
          ? '${info.version}+${info.buildNumber}'
          : info.version;
    } catch (_) {
      // Fall through with an empty version rather than blocking the dialog.
    }
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'The Postbox Game',
      applicationVersion: version,
      applicationLegalese: 'Find postboxes. Claim them. Score mega points.',
      applicationIcon: const Icon(Icons.mail, size: 48, color: postalRed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final displayName = user?.displayName ?? 'Postbox Hunter';
    final email = user?.email ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          // Profile header
          Container(
            color: postalRed,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.white,
                  radius: 28,
                  child: Icon(Icons.person, color: postalRed, size: 32),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              displayName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: _isSaving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      color: Colors.white70,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.edit,
                                    color: Colors.white70, size: 18),
                            tooltip: 'Edit display name',
                            onPressed: _isSaving ? null : _editDisplayName,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                      if (email.isNotEmpty)
                        Text(
                          email,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          _sectionHeader('Account'),
          if (user?.providerData.any((p) => p.providerId == 'password') ?? false)
            ListTile(
              leading: const Icon(Icons.lock_reset),
              title: const Text('Change password'),
              subtitle: const Text('Update your account password'),
              onTap: _isSaving ? null : _changePassword,
            ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            subtitle: const Text('Sign out of your account'),
            onTap: _signOut,
          ),
          ListTile(
            leading: Icon(Icons.delete_forever, color: Colors.red.shade700),
            title: Text('Delete account',
                style: TextStyle(color: Colors.red.shade700)),
            subtitle: const Text('Permanently delete your account and data'),
            onTap: _isSaving ? null : _deleteAccount,
          ),
          const Divider(height: 24),
          _sectionHeader('App'),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('Replay intro'),
            subtitle: const Text('Watch the Postman James intro again'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const Intro(replay: true),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.straighten),
            title: const Text('Distance units'),
            subtitle:
                Text('Show distances in ${_distanceUnit.label.toLowerCase()}'),
            onTap: _chooseDistanceUnit,
          ),
          _scanDistancesCard(),
          const Divider(height: 24),
          _sectionHeader('Map'),
          _mapColourPicker(),
          const Divider(height: 24),
          _sectionHeader('Notifications'),
          if (!_notifPrefsLoaded)
            const Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.md),
              child: LinearProgressIndicator(),
            )
          else ...[
            SwitchListTile(
              secondary: const Icon(Icons.group_outlined),
              title: const Text('First friend to score today'),
              subtitle: const Text(
                  'When a friend is first among your group to find a postbox'),
              value: _notifPrefs['friendFirstScore']!,
              onChanged: (v) => _setNotifPref('friendFirstScore', v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.leaderboard_outlined),
              title: const Text('Friend overtakes you'),
              subtitle: const Text('When a friend beats your daily score'),
              value: _notifPrefs['friendOvertakes']!,
              onChanged: (v) => _setNotifPref('friendOvertakes', v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.person_add_outlined),
              title: const Text('Added as a friend'),
              subtitle:
                  const Text('When someone adds you to their friends list'),
              value: _notifPrefs['addedAsFriend']!,
              onChanged: (v) => _setNotifPref('addedAsFriend', v),
            ),
          ],
          const Divider(height: 24),
          _sectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('Version and app info'),
            onTap: _showAbout,
          ),
        ],
      ),
    );
  }

  Widget _scanDistancesCard() {
    final pos = _lastPosition;
    final center = pos != null
        ? LatLng(pos.latitude, pos.longitude)
        : const LatLng(51.5074, -0.1278); // London fallback
    return Card(
      margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
            child: Text(
              'Scan distances',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
            child: Wrap(
              spacing: AppSpacing.md,
              children: [
                _radiusLegend(
                  postalRed,
                  'Nearby scan',
                  AppPreferences.formatDistance(
                      AppPreferences.nearbyRadiusMeters, _distanceUnit),
                ),
                _radiusLegend(
                  postalRed.withValues(alpha: 0.6),
                  'Claim range',
                  AppPreferences.formatShortDistance(
                      AppPreferences.claimRadiusMeters, _distanceUnit),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 200,
            child: PostboxMap(
              center: center,
              zoom: 13,
              interactionOptions:
                  const InteractionOptions(flags: InteractiveFlag.none),
              circleMarkers: [
                scanRadiusCircle(
                  center,
                  radiusMeters: AppPreferences.nearbyRadiusMeters,
                  borderColor: postalRed.withValues(alpha: 0.7),
                ),
                CircleMarker(
                  point: center,
                  radius: AppPreferences.claimRadiusMeters,
                  useRadiusInMeter: true,
                  color: postalRed.withValues(alpha: 0.25),
                  borderColor: postalRed.withValues(alpha: 0.9),
                  borderStrokeWidth: 3,
                ),
              ],
              markers: [userPositionMarker(center)],
              bottomPadding: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _radiusLegend(Color color, String label, String distance) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          '$label ($distance)',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Future<void> _setMapColour(String? key) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (MaintenanceGuard.blocked(context,
        actionLabel: 'change the map colour')) {
      return;
    }
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'mapColor': key ?? FieldValue.delete(),
      });
      Analytics.setUserProperty(AnalyticsUserProps.kMapColor, mapColorProp(key));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save colour. Please try again.')),
        );
      }
    }
  }

  Widget _mapColourPicker() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snap) {
        final raw = snap.data?.data()?['mapColor'];
        final selected = (raw is String && kMapColourPalette.containsKey(raw))
            ? raw
            : null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your colour on the County Leaders map. Friends see this colour for the regions you lead.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  _ColourSwatch(
                    label: 'Default',
                    colour: postalRed,
                    isSelected: selected == null,
                    showDefaultRing: true,
                    onTap: () => _setMapColour(null),
                  ),
                  for (final entry in kMapColourPalette.entries)
                    _ColourSwatch(
                      label: entry.key,
                      colour: entry.value,
                      isSelected: selected == entry.key,
                      onTap: () => _setMapColour(entry.key),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xs),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _ColourSwatch extends StatelessWidget {
  const _ColourSwatch({
    required this.label,
    required this.colour,
    required this.isSelected,
    required this.onTap,
    this.showDefaultRing = false,
  });

  final String label;
  final Color colour;
  final bool isSelected;
  final bool showDefaultRing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Semantics(
      label: label,
      selected: isSelected,
      button: true,
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? onSurface : onSurface.withValues(alpha: 0.25),
              width: isSelected ? 3 : 1,
            ),
          ),
          child: isSelected
              ? const Icon(Icons.check, color: Colors.white, size: 24)
              : (showDefaultRing
                  ? const Icon(Icons.refresh, color: Colors.white, size: 18)
                  : null),
        ),
      ),
    );
  }
}
