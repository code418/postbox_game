import 'package:flutter/material.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/theme.dart';

/// The column of royal-cypher answer buttons shared by the live claim quiz
/// ([ClaimQuizSheet]) and the workout claim quiz ([ActivityClaimSheet]).
///
/// While [busy] is true every button is disabled and the [selected] option
/// shows "Correct! Claiming…" with a spinner (the parent only sets [busy]
/// after a correct answer, while the claim call is in flight).
class CypherQuizOptions extends StatelessWidget {
  const CypherQuizOptions({
    super.key,
    required this.options,
    required this.selected,
    required this.busy,
    required this.onAnswer,
    this.optionHeight = 56,
  });

  final List<String> options;
  final String? selected;
  final bool busy;
  final ValueChanged<String> onAnswer;
  final double optionHeight;

  static Color _success(BuildContext c) => Theme.of(c).brightness == Brightness.dark
      ? AppColors.successTextDark
      : AppColors.successTextLight;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: options.map((code) {
        final isSelected = selected == code;
        final isCorrectSelected = isSelected && busy;
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: isCorrectSelected
                  ? _success(context).withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: OutlinedButton(
              onPressed: busy ? null : () => onAnswer(code),
              style: OutlinedButton.styleFrom(
                minimumSize: Size(double.infinity, optionHeight),
                side: BorderSide(
                  color: isCorrectSelected
                      ? _success(context)
                      : (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.brandTextDark
                          : AppColors.brandTextLight),
                  width: isCorrectSelected ? 2 : 1,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (isCorrectSelected) ...[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _success(context),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  Column(
                    children: [
                      Text(
                        isCorrectSelected ? 'Correct! Claiming…' : code,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: isCorrectSelected ? _success(context) : null,
                        ),
                      ),
                      if (!isCorrectSelected)
                        Text(
                          MonarchInfo.labels[code] ?? code,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
