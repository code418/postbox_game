import 'package:flutter/material.dart';

class RegisterButton extends StatelessWidget {
  final VoidCallback? _onPressed;

  const RegisterButton({super.key, VoidCallback? onPressed})
      : _onPressed = onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: _onPressed,
      child: const Text('Create account'),
    );
  }
}
