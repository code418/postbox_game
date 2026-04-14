import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/intro.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/validators.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  DistanceUnit _distanceUnit = DistanceUnit.meters;
  bool _isSaving = false;
  final _userRepository = UserRepository();

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final unit = await AppPreferences.getDistanceUnit();
    if (mounted) setState(() => _distanceUnit = unit);
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
                maxLength: 30,
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
            ListTile(
              title: const Text('Meters'),
              leading: Radio<DistanceUnit>(
                value: DistanceUnit.meters,
                groupValue: _distanceUnit,
                onChanged: (v) => Navigator.of(context).pop(v),
              ),
              onTap: () => Navigator.of(context).pop(DistanceUnit.meters),
            ),
            ListTile(
              title: const Text('Miles'),
              leading: Radio<DistanceUnit>(
                value: DistanceUnit.miles,
                groupValue: _distanceUnit,
                onChanged: (v) => Navigator.of(context).pop(v),
              ),
              onTap: () => Navigator.of(context).pop(DistanceUnit.miles),
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
                final ne = newPwCtrl.text.length < 6
                    ? 'Password must be at least 6 characters'
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
                      decoration: InputDecoration(
                        labelText: 'Current password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        errorText: currentError,
                        suffixIcon: IconButton(
                          icon: Icon(showCurrent
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
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
                      decoration: InputDecoration(
                        labelText: 'New password',
                        helperText: 'At least 6 characters',
                        prefixIcon: const Icon(Icons.lock_outline),
                        errorText: newError,
                        suffixIcon: IconButton(
                          icon: Icon(showNew
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
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
                      decoration: InputDecoration(
                        labelText: 'Confirm new password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        errorText: confirmError,
                        suffixIcon: IconButton(
                          icon: Icon(showConfirm
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
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

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'The Postbox Game',
      applicationVersion: '1.0.0',
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
