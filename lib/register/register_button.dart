import 'package:flutter/material.dart';

class RegisterButton extends StatelessWidget {
  final VoidCallback? _onPressed;

  const RegisterButton({Key? key, VoidCallback? onPressed})
      : _onPressed = onPressed,
        super(key: key);

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: _onPressed,
      child: const Text('Create account'),
    );
  }
}
