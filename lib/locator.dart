import 'package:get_it/get_it.dart';

import 'repositories/clipboard_repository.dart';
import 'services/auth_service.dart';
import 'services/clipboard_sync_service.dart';
import 'services/notification_service.dart';
import 'services/transformer_service.dart';
import 'ui/viewmodels/spotlight_viewmodel.dart';

// Global Service Locator
final GetIt locator = GetIt.instance;

/// Setup locator (reserved for pure Dart services if needed in future)
/// Currently, mostly used for registering already-initialized instances from main.dart
void setupLocator() {
  // SpotlightViewModel is a lazy singleton to preserve state across
  // desktop window hide/show cycles.
  locator.registerLazySingleton(
    () => SpotlightViewModel(
      authService: locator<IAuthService>(),
      clipboardRepository: locator<IClipboardRepository>(),
      clipboardSyncService: locator<IClipboardSyncService>(),
      transformerService: locator<ITransformerService>(),
      notificationService: locator<INotificationService>(),
    ),
  );
}
