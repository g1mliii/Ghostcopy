/// Wording for in-app account deletion, shared by the mobile settings screen
/// and the desktop account panel so the two cannot drift apart.
library;

const accountDeletionTitle = 'Delete Account?';

/// The confirmation body. [appleNext] adds the line saying Apple's own sheet
/// follows - see IAuthService.deletionNeedsAppleConfirmation.
String accountDeletionWarning({required bool appleNext}) =>
    'This permanently deletes your GhostCopy account and everything in it: '
    'your clipboard history, the files and images you sent, and your linked '
    'devices. It cannot be undone.'
    '${appleNext ? '\n\nYou will confirm with Apple next.' : ''}';

const accountDeletionFailed =
    'Could not delete your account. Check your connection and try again - '
    'nothing was deleted.';
