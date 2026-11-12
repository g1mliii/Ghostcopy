export 'impl/app_review_service.dart';

/// Store reviews are optional and never affect access to GhostCopy.
abstract class IAppReviewService {
  /// Only adults with completed setup may open a public store review flow.
  bool get canReview;

  /// Counts a successful foreground send, without storing clipboard contents.
  Future<void> recordSuccessfulSend();

  /// Requests the native prompt only at an eligible, idle moment.
  /// [canPresent] is rechecked after asynchronous platform work.
  Future<void> maybeRequestReview({required bool Function() canPresent});

  /// Explicit Settings action: opens the store instead of a quota-limited prompt.
  Future<bool> openStoreReview();
}
