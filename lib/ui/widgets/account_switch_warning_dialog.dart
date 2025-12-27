import 'package:flutter/material.dart';

/// Warning dialog shown when user attempts to sign into a different account
///
/// Informs user that switching accounts will erase their current clipboard history
/// Returns true if user confirms, false if cancelled
class AccountSwitchWarningDialog extends StatelessWidget {
  const AccountSwitchWarningDialog({
    required this.clipboardCount,
    super.key,
  });

  final int clipboardCount;

  /// Show the warning dialog and return user's choice
  /// Returns true if user confirmed, false if cancelled
  static Future<bool> show(
    BuildContext context,
    int clipboardCount,
  ) async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AccountSwitchWarningDialog(
        clipboardCount: clipboardCount,
      ),
    ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    const bgColor = Color(0xFF1A1A1D); // surface
    const textPrimaryColor = Color(0xFFFFFFFF);
    const textSecondaryColor = Color(0xFFB9BBBE);
    const bgDarkColor = Color(0xFF0D0D0F); // background
    const warningColor = Color(0xFFFF6B6B); // warning/error red

    return AlertDialog(
      backgroundColor: bgColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Row(
        children: [
          Icon(
            Icons.warning_rounded,
            color: warningColor,
            size: 24,
          ),
          const SizedBox(width: 12),
          const Text(
            'Switch Account?',
            style: TextStyle(
              color: textPrimaryColor,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You have $clipboardCount clipboard item${clipboardCount != 1 ? 's' : ''} in your current account.',
            style: const TextStyle(
              color: textSecondaryColor,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: bgDarkColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: warningColor.withValues(alpha: 0.3),
              ),
            ),
            child: const Text(
              'Signing into a different account will permanently erase this history.',
              style: TextStyle(
                color: textSecondaryColor,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(
            'Cancel',
            style: TextStyle(color: textSecondaryColor),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text(
            'Continue',
            style: TextStyle(color: warningColor),
          ),
        ),
      ],
    );
  }
}
