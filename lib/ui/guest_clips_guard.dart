import 'package:flutter/widgets.dart';

import '../locator.dart';
import '../models/exceptions.dart';
import '../repositories/clipboard_repository.dart';
import '../services/auth_service.dart';
import 'platform_adaptive.dart';

/// Ask before signing into a different account while holding guest clips.
///
/// Signing in changes user_id, and clips belong to the id that made them. The
/// two paths differ in how final that is, which is why [deletesClips] exists:
/// on the email path the anonymous account's clips merely become unreachable,
/// but on the Google path AuthService._cleanupPreviousSession runs
/// cleanup_user_data against the outgoing anonymous id and deletes them
/// outright. Neither can be undone, so both ask - but the dialog has to say
/// which one is about to happen, or the user consents to abandonment and gets
/// destruction.
///
/// Shared rather than private to one screen. It began as two methods on the
/// desktop auth panel, which left the mobile welcome screen signing in with no
/// prompt at all - the same clips, destroyed silently, on the platform most
/// likely to be holding them. Any new sign-in surface should call this.
///
/// Deliberately names the alternative, because the user almost always wants
/// Create Account - that keeps the same id and the clips with it.
///
/// Returns true when there is nothing to lose or the user accepted losing it.
Future<bool> confirmGuestClipsBeforeSignIn(
  BuildContext context, {
  required IAuthService authService,
  required bool deletesClips,
  IClipboardRepository? clipboardRepository,
}) async {
  if (!authService.isAnonymous) return true;

  final repository = clipboardRepository ?? locator<IClipboardRepository>();

  final int orphanCount;
  try {
    orphanCount = await repository.getClipboardCountForCurrentUser();
  } on RepositoryException {
    // The count deliberately throws rather than reporting zero, because an
    // unknown count must never authorize discarding an account. Refuse the
    // sign-in instead of guessing there was nothing there.
    return false;
  }

  if (orphanCount == 0) return true;
  if (!context.mounted) return false;

  final clips = orphanCount == 1 ? '1 clip' : '$orphanCount clips';

  // Worded per path. Saying "left behind" when the clips are about to be
  // deleted understates the only thing this dialog exists to warn about.
  final consequence = deletesClips
      ? 'Signing in with Google deletes them from this account first. '
            'They cannot be recovered.'
      : 'Signing into a different account leaves them behind, and they '
            'cannot be moved across later.';

  return Adaptive.confirm(
    context,
    title: deletesClips ? 'Delete your clips?' : 'Leave your clips behind?',
    message:
        "You have $clips saved on this device's anonymous account. "
        '$consequence\n\n'
        'To keep them, use Create Account instead - it turns this anonymous '
        'account into yours and brings the clips with it.',
    confirmText: deletesClips ? 'Delete and sign in' : 'Sign in anyway',
    // Only the Google path actually destroys anything, so only it gets the
    // destructive styling - and on Apple platforms the Cupertino variant.
    isDestructive: deletesClips,
  );
}
