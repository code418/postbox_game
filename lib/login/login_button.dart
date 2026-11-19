import 'package:material_ui/material_ui.dart';

class LoginButton extends StatelessWidget {
  final VoidCallback? _onPressed;

  const LoginButton({super.key, VoidCallback? onPressed})
      : _onPressed = onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: _onPressed,
      child: const Text('Sign in'),
    );
  }
}
