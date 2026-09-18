import receive_sharing_intent

/// Entry point for the iOS share sheet.
///
/// RSIShareViewController does the work: it copies the shared attachments into
/// the App Group container and opens the host app on the
/// `ShareMedia-<bundle id>` URL, which ReceiveSharingIntentPlugin turns back
/// into the SharedMediaFile list the app listens for.
///
/// Auto-redirect is left on. The package can show a compose sheet of its own
/// instead, but GhostCopy already has a composer, and the point of sharing
/// from another app is to be done in one tap - the target devices come from
/// the Default devices setting, the same as every other share.
class ShareViewController: RSIShareViewController {}
