import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/clipboard_item.dart';
import '../../models/clipboard_limits.dart';
import '../../models/exceptions.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/account_prompt_store.dart';
import '../../services/auth_service.dart';
import '../../services/clipboard_service.dart';
import '../../services/clipboard_sync_service.dart';
import '../../services/crash_reporting_service.dart';
import '../../services/file_type_service.dart';
import '../../services/notification_service.dart';
import '../../services/temp_file_service.dart';
import '../../services/transformer_service.dart';
import '../../utils/network_errors.dart';

/// ViewModel for SpotlightScreen - handles business logic and state
///
/// Separates business logic from UI, making the code more testable and maintainable.
/// Uses ChangeNotifier for simple, built-in state management.
///
/// Responsibilities:
/// - Send state management (_content, _isSending, _errorMessage, etc.)
/// - History state management (_historyItems, _isLoadingHistory)
/// - Content detection and transformation
/// - Rate limiting and debouncing
/// - Timer management
///
/// UI responsibilities (remain in widget):
/// - Animation controllers (need TickerProvider)
/// - Text controllers and focus nodes (Flutter platform widgets)
/// - Panel navigation state (pure UI concern)
/// - Pausable wrappers (widget lifecycle)
class SpotlightViewModel extends ChangeNotifier {
  SpotlightViewModel({
    required this._authService,
    required IClipboardRepository clipboardRepository,
    required IClipboardSyncService clipboardSyncService,
    required this._transformerService,
    required this._notificationService,
    IClipboardService? clipboardService,
    this._accountPromptStore,
    this._isGameModeActive,
  }) : _clipboardRepo = clipboardRepository,
       _syncService = clipboardSyncService,
       _clipboardService = clipboardService ?? ClipboardService.instance;

  final IAuthService _authService;
  final IClipboardRepository _clipboardRepo;
  final IClipboardSyncService _syncService;
  final ITransformerService _transformerService;
  final INotificationService _notificationService;
  final IClipboardService _clipboardService;

  /// Null turns the account offer and the guest badge off entirely.
  final AccountPromptStore? _accountPromptStore;
  final bool Function()? _isGameModeActive;

  // ========== SEND STATE ==========

  String _content = '';
  String get content => _content;

  ClipboardContent? _clipboardContent;
  ClipboardContent? get clipboardContent => _clipboardContent;

  final Set<String> _selectedPlatforms = {};
  Set<String> get selectedPlatforms => _selectedPlatforms;

  bool _isSending = false;
  bool get isSending => _isSending;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool _isDragOver = false;
  bool get isDragOver => _isDragOver;

  // Rate limiting for manual sends
  DateTime? _lastSendTime;
  static const Duration _minSendInterval = Duration(milliseconds: 500);

  // String caching for expensive computations
  String? _cachedSendButtonTargetText;
  String? get cachedSendButtonTargetText => _cachedSendButtonTargetText;

  // File picker state
  bool _isFilePickerOpen = false;
  bool get isFilePickerOpen => _isFilePickerOpen;

  // ========== HISTORY STATE ==========

  List<ClipboardItem> _historyItems = [];
  List<ClipboardItem> get historyItems => _historyItems;

  bool _isLoadingHistory = false;
  bool get isLoadingHistory => _isLoadingHistory;

  // ========== CONTENT DETECTION STATE ==========

  ContentDetectionResult? _detectedContentType;
  ContentDetectionResult? get detectedContentType => _detectedContentType;

  TransformationResult? _transformationResult;
  TransformationResult? get transformationResult => _transformationResult;

  Future<TransformationResult>? _jwtTransformFuture;
  Future<TransformationResult>? get jwtTransformFuture => _jwtTransformFuture;

  // ========== DRAFT ==========
  //
  // The composer holds one of two things: whatever auto-paste read off the
  // clipboard, or something the user put there - typed, picked or dropped.
  // Auto-paste used to overwrite both on every focus, and blur cleared any
  // attachment, so a picked file or a half-typed message was gone the moment
  // the user clicked away. A draft now survives the hide. Memory is the
  // constraint, so a hidden draft keeps a staged file's path, never its
  // bytes, and nothing is kept past [draftLifetime].

  /// How long a draft waits in the tray before the next opening forgets it.
  static const Duration draftLifetime = Duration(minutes: 10);

  /// Typed text above this is not kept: it would be the one thing a hidden
  /// draft holds that is not small.
  static const int maxKeptDraftChars = 100000;

  bool _isDraft = false;

  /// Whether the composer holds the user's own content rather than
  /// auto-paste's.
  @visibleForTesting
  bool get hasDraft => _isDraft;

  bool _draftRestored = false;

  /// The opening found a kept draft instead of auto-pasting - the cue for
  /// "Paste clipboard instead".
  bool get draftRestored => _draftRestored;

  /// Where a staged file came from, so a hide can drop its bytes and the
  /// next opening read it again. The name and type are the ones staging
  /// settled on: a picker can hand over a cache copy whose path has a
  /// generated name, and the upload must keep the real one.
  ({String path, String name, String? mimeType})? _draftFile;
  DateTime? _hiddenAt;

  /// Bumped by every change to the composer, so a clipboard read that took a
  /// while can tell the user put something else there meanwhile.
  int _composerRevision = 0;

  /// Like [_composerRevision], but not bumped by a hide: whether the user
  /// changed the composer, which is what a send finishing late must not
  /// overwrite.
  int _editRevision = 0;

  /// A change the user, or auto-paste on their behalf, made to the
  /// composer. Hides and a send's own clear bump [_composerRevision] alone.
  void _markEdited() {
    _composerRevision++;
    _editRevision++;
  }

  /// Between a hide and the next focus. A file whose staging finishes in
  /// that window is released as the hide would have released it. Not just
  /// `!_spotlightOpen`: before the first focus the window can be up without
  /// its focus having been seen.
  bool get _hidden => !_spotlightOpen && _hideCount > 0;

  /// Bumped by every hide, so a kept file still being read when the window
  /// goes away again is not installed into a hidden composer.
  int _hideCount = 0;

  /// A kept file whose bytes are not back yet. The composer still shows its
  /// "File ready to send" line, which must not go out as text.
  bool get isRestoringDraft =>
      _isDraft && _draftFile != null && _clipboardContent == null;

  /// The restore in flight, which a second focus for the same opening joins.
  Future<void>? _restore;

  /// Empty the composer, along with everything derived from what was in it -
  /// a decoded JWT or a colour preview must not outlive the text it came from.
  void _resetComposer() {
    _clearDraft();
    _clipboardContent = null;
    _content = '';
    _clearDetection();
  }

  void _clearDetection() {
    _detectedContentType = null;
    _transformationResult = null;
    _jwtTransformFuture = null;
    _contentDetectionTimer?.cancel();
    _contentDetectionTimer = null;
  }

  void _clearDraft() {
    _isDraft = false;
    _draftRestored = false;
    _draftFile = null;
    _hiddenAt = null;
  }

  // ========== ACCOUNT OFFER ==========

  bool _accountOfferVisible = false;
  bool _accountOfferShownThisRun = false;

  /// Between a focus and the next hide. Offers that land outside it - a
  /// confirmation refresh finishing after the window went away - wait.
  bool _spotlightOpen = false;

  /// The card asking a guest to make an account. Re-checks the account on
  /// read, so an upgrade finishing while it is up takes it away at once.
  bool get showAccountOffer => _accountOfferVisible && _authService.isAnonymous;

  /// The small "Guest" label in the header, the way to an account that is
  /// always there and never interrupts.
  bool get showGuestBadge =>
      _accountPromptStore != null && _authService.isAnonymous;

  // ========== TIMERS ==========

  Timer? _contentDetectionTimer;
  Timer? _historyReloadTimer;
  Timer? _errorClearTimer;
  StreamSubscription<AuthState>? _authStateSubscription;
  bool _callbacksInstalled = false;
  void Function()? _previousOnClipboardReceived;
  void Function(ClipboardItem item)? _previousOnClipboardSent;
  String? _historyUserId;
  bool? _historyUserAnonymous;
  int _accountRevision = 0;

  // ========== INITIALIZATION ==========

  /// Initialize the ViewModel
  /// Call this once after construction
  Future<void> initialize() async {
    _historyUserId = _authService.currentUserId;
    _historyUserAnonymous = _authService.currentUser?.isAnonymous;

    // The desktop spotlight stays mounted while the auth panel switches
    // accounts. Without listening here it loaded the anonymous account once,
    // then kept showing that empty list after sign-in until the user toggled
    // encryption (the settings callback happened to refresh history). Reload
    // the repository as soon as Supabase announces the new user instead.
    // initialize runs again whenever a new SpotlightScreen binds to this
    // singleton - on Windows, every return from the tray menu. The old
    // subscription would otherwise live on beside the new one.
    unawaited(_authStateSubscription?.cancel());
    _authStateSubscription = _authService.authStateChanges.listen((state) {
      final user = state.session?.user;
      final userId = user?.id;
      // An upgrade answers the offer for good. Cleared rather than masked,
      // or signing out to a fresh guest would bring the old card back.
      if (user != null && !user.isAnonymous) _accountOfferVisible = false;
      if (userId == _historyUserId) {
        // A guest whose upgrade was just confirmed: the same account and
        // history, but the screen still offers it Sign Up.
        if (user != null && user.isAnonymous != _historyUserAnonymous) {
          _historyUserAnonymous = user.isAnonymous;
          notifyListeners();
        }
        return;
      }

      _historyUserId = userId;
      _historyUserAnonymous = user?.isAnonymous;
      _accountRevision++;
      _historyItems = <ClipboardItem>[];
      _isLoadingHistory = true;
      notifyListeners();
      unawaited(_loadHistory(revision: _accountRevision));
    });

    // Load initial history
    await _loadHistory(revision: _accountRevision);

    // Chained, not replaced: in hybrid mode LifecycleController has already
    // wrapped both to reset its inactivity timer, and overwriting them sent a
    // busy hidden app to polling. Restored in dispose. Installed once: a
    // second initialize would wrap its own wrappers, and every send and
    // receive would run through one more layer per tray-menu opening.
    if (_callbacksInstalled) return;
    _callbacksInstalled = true;
    final previousReceived = _previousOnClipboardReceived =
        _syncService.onClipboardReceived;
    _syncService.onClipboardReceived = () {
      previousReceived?.call();
      _debouncedLoadHistory();
    };

    // Auto-send uploads without passing through handleSend, and a guest who
    // only ever auto-sends has shown the app working just the same.
    final previousSent = _previousOnClipboardSent =
        _syncService.onClipboardSent;
    _syncService.onClipboardSent = (item) {
      previousSent?.call(item);
      _recordSend();
    };
  }

  // ========== PUBLIC METHODS ==========

  /// Update content from text input
  void updateContent(String newContent) {
    if (_content == newContent) return;
    _content = newContent;
    _markEdited();
    // Only typing reaches here with a change: auto-paste sets _content
    // first, so the text field echoing it back is equal and returns above.
    final payload = _clipboardContent;
    if (payload != null &&
        payload.hasHtml &&
        !payload.hasFile &&
        !payload.hasImage) {
      // An edited HTML preview is the user's text now. Left attached, the
      // HTML would be what goes out, without the edit.
      _clipboardContent = null;
    }
    final wasRestored = _draftRestored;
    if (newContent.trim().isEmpty && _clipboardContent == null) {
      _clearDraft();
    } else {
      // Editing a kept file's "File ready to send" line before its bytes
      // are back: the user is writing text now, and the file goes.
      if (isRestoringDraft) _draftFile = null;
      _isDraft = true;
      _draftRestored = false;
    }
    // The detector notifies only when the type changes, which an edit to
    // plain text does not; without this the "Kept from before" row stays,
    // offering to paste over what was just typed.
    if (wasRestored != _draftRestored || payload != _clipboardContent) {
      notifyListeners();
    }
    _debouncedDetectContentType();
  }

  /// Stage an image, file or HTML payload as auto-paste would: not a draft,
  /// so the next hide releases it. The screen stages through
  /// [populateFromClipboard] and [setFileContent]; this is for tests.
  @visibleForTesting
  void updateClipboardContent(ClipboardContent? content) {
    _clipboardContent = content;
    _markEdited();
    notifyListeners();
  }

  /// Clear a pending paste or upload preview, and the text with it, so the
  /// composer returns to an empty text-entry state.
  void clearClipboardPayload() {
    if (_clipboardContent == null && _content.isEmpty) return;
    _resetComposer();
    _markEdited();
    notifyListeners();
  }

  /// Toggle platform selection
  void togglePlatform(String platform) {
    if (_selectedPlatforms.contains(platform)) {
      _selectedPlatforms.remove(platform);
    } else {
      _selectedPlatforms.add(platform);
    }
    _cachedSendButtonTargetText = null; // Invalidate cache
    notifyListeners();
  }

  /// Clear platform selection (send to all devices)
  void clearPlatformSelection() {
    _selectedPlatforms.clear();
    _cachedSendButtonTargetText = null;
    notifyListeners();
  }

  /// Set drag over state
  void setDragOver({required bool isDragOver}) {
    if (_isDragOver == isDragOver) return;
    _isDragOver = isDragOver;
    notifyListeners();
  }

  /// Set file picker open state
  void setFilePickerOpen({required bool isOpen}) {
    if (_isFilePickerOpen == isOpen) return;
    _isFilePickerOpen = isOpen;
    notifyListeners();
  }

  /// Clear error message
  void clearError() {
    _errorMessage = null;
    _errorClearTimer?.cancel();
    _errorClearTimer = null;
    notifyListeners();
  }

  /// Refresh history manually
  Future<void> refreshHistory() async {
    await _loadHistory(revision: _accountRevision);
  }

  /// The window came forward. A sign-up confirmed in a browser meanwhile
  /// should read as signed in, not as the guest it was.
  /// [composerVisible] is false while a panel covers the composer, where
  /// the card would be drawn unseen and still use up this run's showing.
  /// Asked after the await, not before: a panel can open during it.
  ///
  /// The offer waits for the confirmation check: a guest who confirmed an
  /// upgrade in the browser is still anonymous here until it finishes.
  Future<void> onWindowFocused({bool Function()? composerVisible}) async {
    _spotlightOpen = true;
    try {
      await _authService.refreshIfAwaitingConfirmation();
    } on Exception catch (e) {
      debugPrint('[SpotlightVM] Confirmation check failed: $e');
    }
    if (composerVisible?.call() ?? true) offerAccountIfDue();
  }

  /// Spotlight went back to the tray. A card the user looked at and left is
  /// this run's one showing, so it does not come back on the next opening.
  void onSpotlightHidden() {
    // Every hide reaches here, and a tray-menu remount reports one for a
    // window already hidden - redraw only for what this one changed.
    final before = _visibleState;
    _spotlightOpen = false;
    _hideCount++;
    _composerRevision++;
    _restore = null;
    _accountOfferVisible = false;
    _releaseComposerForHide();
    if (_visibleState != before) notifyListeners();
  }

  Object get _visibleState => (
    _content,
    _clipboardContent,
    _draftRestored,
    _detectedContentType,
    _accountOfferVisible,
  );

  /// Give back what a hidden window has no use for. Auto-paste's content
  /// goes entirely - the next opening reads the clipboard again anyway. A
  /// draft keeps only what is small: its text, and a staged file's path in
  /// place of its bytes. Anything else in a draft (an auto-pasted image the
  /// user typed a caption under, a very long text) cannot be kept cheaply,
  /// so it goes too. HTML never reaches here as a draft: editing its preview
  /// drops it, in [updateContent].
  void _releaseComposerForHide() {
    final payload = _clipboardContent;
    final keepable =
        _isDraft &&
        _content.length <= maxKeptDraftChars &&
        (payload == null || (payload.hasFile && _draftFile != null));
    if (!keepable) {
      _resetComposer();
      return;
    }
    if (payload != null && payload.hasFile) {
      _clipboardContent = null; // the bytes; the path brings them back
    }
    // Only the first: Windows remounting the screen behind the tray menu
    // reports a hide again for a window that never came back, and renewing
    // the time there would revive a draft that had already expired.
    _hiddenAt ??= clock.now();
  }

  /// Fill the composer for an opening: the kept draft if there is one and
  /// it is still fresh, otherwise the clipboard.
  ///
  /// A second call for the same opening joins the first rather than reading
  /// the kept file again.
  Future<void> restoreOrPopulateComposer() {
    // Queued by a focus the window was hidden again after: snapshotting the
    // hide count now would miss that hide, and the restore would fill a
    // hidden composer and clear the draft's expiry.
    if (_hidden) return Future.value();
    final pending = _restore;
    if (pending != null) return pending;
    late final Future<void> restore;
    restore = _restoreOrPopulate().whenComplete(() {
      if (identical(_restore, restore)) _restore = null;
    });
    return _restore = restore;
  }

  Future<void> _restoreOrPopulate() async {
    final hiddenAt = _hiddenAt;
    if (_isDraft && hiddenAt != null) {
      final hides = _hideCount;
      final revision = _composerRevision;
      final expired = clock.now().difference(hiddenAt) >= draftLifetime;
      // Only a kept file whose bytes the hide released has anything to read.
      final reading = !expired && isRestoringDraft;
      final file = reading ? await _readDraftFile() : null;
      // Hidden again while the file was read: that opening is over, and
      // its bytes have no business in a hidden window.
      if (hides != _hideCount) return;
      _hiddenAt = null;
      // Typed, staged another file or pasted the clipboard during the read:
      // what the user did since is the composer now, and the old file must
      // not be installed under it.
      if (revision != _composerRevision) return;
      if (!expired && (!reading || file != null)) {
        if (file != null) _clipboardContent = file;
        _draftRestored = true;
        notifyListeners();
        return;
      }
      final lostFile = reading ? _draftFile?.name : null;
      _resetComposer();
      _markEdited();
      notifyListeners();
      // Expiry is the documented end of a draft; a file that cannot be
      // restored is not, and the clipboard taking its place unannounced
      // reads as the app having lost it.
      if (lostFile != null) {
        _setError('$lostFile is no longer available to send');
      }
    }
    await populateFromClipboard();
  }

  /// Read the kept file back from disk. Null when it is gone, empty, now over
  /// the limit, or unreadable - the draft is then dropped rather than
  /// half-restored.
  Future<ClipboardContent?> _readDraftFile() async {
    final kept = _draftFile!;
    RandomAccessFile? handle;
    try {
      // One open for the size check and the read, and a missing file throws
      // here. Async throughout: on a stalled network share or removable
      // drive a sync call would freeze the opening on the UI isolate.
      handle = await File(kept.path).open();
      final length = await handle.length();
      if (length > ClipboardLimits.maxFileBytes) return null;
      // Reads at most length bytes, so a file growing meanwhile cannot take
      // this past the limit.
      final bytes = await handle.read(length);
      // An empty payload has no file identity when sending, so restoring it
      // would send the retained preview as text. Check after the read too:
      // another process can truncate the file after the size check.
      if (bytes.isEmpty) return null;
      // The type staging detected, not detected again: the send detects
      // from the bytes anyway, and this only has to put back what was there.
      return ClipboardContent.file(bytes, kept.name, kept.mimeType);
    } on FileSystemException catch (e) {
      debugPrint('[SpotlightVM] Kept file could not be read again: $e');
      return null;
    } finally {
      await handle?.close();
    }
  }

  /// Offer a guest an account, at most once per run of the app.
  ///
  /// Only after the first clip this install has sent, so the app has shown
  /// what it is for before asking for anything; not while "Not now" holds;
  /// and not during Game Mode, which exists so nothing asks for attention.
  /// Checked on focus rather than on show because focus is what every
  /// opening reaches - the first one after launch never leaves tray mode.
  ///
  /// Also called when a panel closes, since an opening that began behind
  /// one never got its chance at focus.
  void offerAccountIfDue() {
    final store = _accountPromptStore;
    if (store == null || _accountOfferShownThisRun || !_spotlightOpen) return;
    if (!_authService.isAnonymous || !store.hasSent || store.isOfferSnoozed) {
      return;
    }
    if (_isGameModeActive?.call() ?? false) return;
    _accountOfferShownThisRun = true;
    _accountOfferVisible = true;
    notifyListeners();
  }

  /// "Not now", or Create Account opened from anywhere - the card, the badge
  /// or the link-device dialog. Opening the form snoozes too: someone who
  /// closes it without finishing has said not yet, and the guest badge is
  /// still there for them.
  void dismissAccountOffer() {
    final store = _accountPromptStore;
    if (store != null) unawaited(store.snoozeOffer());
    if (!_accountOfferVisible) return;
    _accountOfferVisible = false;
    notifyListeners();
  }

  void _recordSend() {
    final store = _accountPromptStore;
    if (store != null) unawaited(store.recordSend());
  }

  /// Populate content from system clipboard
  /// Returns ClipboardContent if there's something to paste
  ///
  /// Leaves a draft alone unless [force]d by "Paste clipboard instead".
  Future<ClipboardContent?> populateFromClipboard({bool force = false}) async {
    if (_isDraft && !force) return null;
    final revision = _composerRevision;
    try {
      final content = await _clipboardService.read();
      // The user typed, staged or cleared something during the read - forced
      // or not, what they did since is newer than this clipboard.
      if (revision != _composerRevision) return null;
      // An empty clipboard replaces nothing, a draft included.
      if (content.isEmpty) return null;
      if (force) _clearDraft();
      _markEdited();
      // What the replaced content was detected as - a forced paste replaces
      // a draft that may have been a JWT or a colour. Only text is detected,
      // and it detects again below, so its preview is left to be replaced
      // rather than blinking out for the debounce.
      if (content.hasImage || content.hasFile || content.hasHtml) {
        _clearDetection();
      }
      // Sizes only. A large clipboard is where a hang would start.
      recordDiagnostic(
        'clipboard',
        'Clipboard read',
        data: {
          'textChars': content.text?.length ?? 0,
          'imageBytes': content.imageBytes?.length ?? 0,
          'fileBytes': content.fileBytes?.length ?? 0,
        },
      );

      if (content.hasImage) {
        _clipboardContent = content;
        _content = ''; // Clear text when image is pasted
        notifyListeners();
        debugPrint('[SpotlightVM] Populated image from clipboard');
        return content;
      } else if (content.hasFile) {
        _clipboardContent = content;
        _content = ''; // Clear text when file is pasted
        notifyListeners();
        debugPrint(
          '[SpotlightVM] Populated file from clipboard: ${content.filename}',
        );
        return content;
      } else if (content.hasHtml) {
        _clipboardContent = content;
        _content = content.text ?? ''; // Show plaintext preview
        notifyListeners();
        debugPrint('[SpotlightVM] Populated HTML from clipboard');
        return content;
      } else if (content.hasText) {
        _clipboardContent = null; // Clear rich content
        final text = content.text!;
        _content = text;
        _debouncedDetectContentType();
        notifyListeners();
        debugPrint('[SpotlightVM] Populated text from clipboard');
        return content;
      }

      return null;
    } on Exception catch (e) {
      debugPrint('[SpotlightVM] Failed to read clipboard: $e');
      return null;
    }
  }

  /// Handle send action - sends clipboard to Supabase
  ///
  /// UI callbacks:
  /// - onSendSuccess: Called after successful send (for clearing text controller and hiding window)
  /// - onSendError: Called on error (optional, error state is already set in ViewModel)
  Future<void> handleSend({VoidCallback? onSendSuccess}) async {
    // Its bytes are still being read back; sending now would send the
    // "File ready to send" line as text. The screen disables Send for it.
    if (isRestoringDraft) return;
    final hasTextPayload = _content.trim().isNotEmpty;
    final hasClipboardPayload =
        (_clipboardContent?.hasFile ?? false) ||
        (_clipboardContent?.hasImage ?? false) ||
        (_clipboardContent?.hasHtml ?? false);

    if ((!hasTextPayload && !hasClipboardPayload) || _isSending) return;

    // Rate limit: prevent rapid repeated sends
    final now = DateTime.now();
    if (_lastSendTime != null &&
        now.difference(_lastSendTime!) < _minSendInterval) {
      debugPrint(
        'Send suppressed: rate limit (${now.difference(_lastSendTime!)})',
      );
      return;
    }

    _isSending = true;
    notifyListeners();

    // Read once, here. A hide while the upload is out releases the
    // composer, and everything after the await - the manual-send record that
    // stops auto-send repeating this clip, the integrations - must describe
    // what was sent, not what the composer holds by then.
    final sentText = _content;
    final sentClipboard = _clipboardContent;
    final edits = _editRevision;

    try {
      // mark last send time early to avoid races
      _lastSendTime = now;

      // Get current user ID
      final userId = _authService.currentUserId;
      if (userId == null) {
        throw Exception('Not authenticated');
      }

      final currentDeviceType = ClipboardRepository.getCurrentDeviceType();
      final currentDeviceName = ClipboardRepository.getCurrentDeviceName();
      final targetDevicesList = _selectedPlatforms.isEmpty
          ? null
          : _selectedPlatforms.toList();

      // Insert into Supabase based on content type
      if (sentClipboard?.hasFile ?? false) {
        // File content - upload to storage
        final bytes = sentClipboard!.fileBytes!;
        final filename = sentClipboard.filename;

        // Detect file type
        final fileTypeInfo = FileTypeService.instance.detectFromBytes(
          bytes,
          filename,
        );

        await _clipboardRepo.insertFile(
          userId: userId,
          deviceType: currentDeviceType,
          deviceName: currentDeviceName,
          fileBytes: bytes,
          mimeType: fileTypeInfo.mimeType,
          contentType: fileTypeInfo.contentType,
          originalFilename: filename,
          targetDeviceTypes: targetDevicesList,
        );
        debugPrint(
          '[SpotlightVM] ↑ Sent file: $filename (${bytes.length} bytes)',
        );
      } else if (sentClipboard?.hasImage ?? false) {
        // Image content - upload to storage
        final bytes = sentClipboard!.imageBytes!;
        final mimeType = sentClipboard.mimeType ?? 'image/png';
        // Unknown image MIMEs used to fall through to GIF here, which sent a
        // PNG labelled as a GIF rather than failing.
        final contentType = ContentType.fromMimeType(mimeType);
        if (contentType == null || !contentType.isImage) {
          _isSending = false;
          _setError('Unsupported image type: $mimeType');
          return;
        }

        await _clipboardRepo.insertImage(
          userId: userId,
          deviceType: currentDeviceType,
          deviceName: currentDeviceName,
          imageBytes: bytes,
          mimeType: mimeType,
          contentType: contentType,
          targetDeviceTypes: targetDevicesList,
        );
        debugPrint('[SpotlightVM] ↑ Sent image: ${bytes.length} bytes');
      } else if (sentClipboard?.hasHtml ?? false) {
        // HTML content
        await _clipboardRepo.insertRichText(
          userId: userId,
          deviceType: currentDeviceType,
          deviceName: currentDeviceName,
          content: sentClipboard!.html!,
          format: RichTextFormat.html,
          targetDeviceTypes: targetDevicesList,
        );
        debugPrint('[SpotlightVM] ↑ Sent HTML: ${sentText.length} chars');
      } else {
        // Plain text content
        final item = ClipboardItem(
          id: '0', // Will be generated by Supabase
          userId: userId,
          content: sentText,
          deviceName: currentDeviceName,
          deviceType: currentDeviceType,
          targetDeviceTypes: targetDevicesList,
          createdAt: DateTime.now(),
        );
        await _clipboardRepo.insert(item);
        debugPrint('[SpotlightVM] ↑ Sent text: ${sentText.length} chars');
      }

      final targetText = _selectedPlatforms.isEmpty
          ? 'all devices'
          : _selectedPlatforms.length == 1
          ? _selectedPlatforms.first.toLowerCase()
          : '${_selectedPlatforms.length} device types';

      debugPrint('Sent clipboard to $targetText');

      // Notify ClipboardSyncService to prevent duplicate auto-send
      _syncService.notifyManualSend(sentText, clipboardContent: sentClipboard);

      // Show success toast
      _notificationService.showToast(
        message: 'Sent to $targetText',
        type: NotificationType.success,
      );

      _recordSend();

      _isSending = false;
      // The user typed or staged something else while this was uploading:
      // that is theirs, so neither clear it nor hide the window on them.
      if (edits != _editRevision) {
        notifyListeners();
        return;
      }

      // Clear content after successful send. A revision, like any other
      // change to the composer: a kept file being read back after a hide
      // during the upload would otherwise put the file just sent back.
      _resetComposer();
      _composerRevision++;
      notifyListeners();

      // Call success callback for UI actions (clear text controller, hide window)
      onSendSuccess?.call();
    } on ValidationException catch (e) {
      _isSending = false;
      _setError('Validation error: ${e.message}');
    } on SecurityException catch (e) {
      _isSending = false;
      _setError('Security error: ${e.message}');
    } on Exception catch (e) {
      _isSending = false;
      _setError(sendFailureMessage(e, 'Failed to send: $e'));
    }
  }

  /// Set file content after file picker completes
  /// The widget handles FilePicker UI (dialogs, validation)
  /// This just stores the result
  ///
  /// [sourcePath] lets a hide release the bytes and the next opening read
  /// them back; without it the file cannot outlive a hide.
  void setFileContent(
    ClipboardContent content,
    String displayText, {
    String? sourcePath,
  }) {
    _clipboardContent = content;
    _content = displayText;
    _isDraft = true;
    _draftRestored = false;
    _draftFile = sourcePath == null
        ? null
        : (
            path: sourcePath,
            name: content.filename ?? File(sourcePath).uri.pathSegments.last,
            mimeType: content.mimeType,
          );
    _markEdited();
    // Staging read the file after the window had already hidden: release it
    // now, as the hide would have, rather than hold the bytes until the next
    // opening - which would then also skip the restore and the auto-paste.
    if (_hidden) _releaseComposerForHide();
    notifyListeners();
    debugPrint(
      '[SpotlightVM] File loaded: ${content.filename} (${content.fileBytes?.length ?? 0} bytes)',
    );
  }

  /// Handle copying a history item to clipboard
  ///
  /// UI callback:
  /// - onCopySuccess: Called after copy (to close history panel)
  Future<void> handleHistoryItemCopy(
    ClipboardItem item, {
    VoidCallback? onCopySuccess,
  }) async {
    try {
      // Media is downloaded first, and downloadFile returns null when the
      // storage path is missing, the download fails or decryption does.
      // Nothing is written then, so this returns before the copy is counted
      // as the user's: smart receive would otherwise guard a clipboard that
      // never changed and refuse incoming clips for the whole stale window.
      final bytes = item.isImage || item.isFile
          ? await _clipboardRepo.downloadFile(item)
          : null;
      if ((item.isImage || item.isFile) && bytes == null) {
        _setError(
          _clipboardRepo.lastDownloadWasOffline(item)
              ? offlineFileMessage
              : 'Could not copy - the file could not be downloaded',
        );
        return;
      }

      if (item.isImage) {
        await _clipboardService.writeImage(bytes!);
        debugPrint('[SpotlightVM] Copied image to clipboard');
      } else if (item.isFile) {
        // Written to a temp file, whose path goes on the clipboard.
        final fileBytes = bytes!;
        // Sniffed extension rather than a bare 'file': this path is written
        // to the clipboard, and a name with nothing after the dot gives the
        // receiving app no way to tell what it just pasted.
        // Shared with the mobile share paths. This copy never grew the
        // `image.*` case they have, which is the drift that comes of writing
        // the same naming rule out four times.
        final filename = FileTypeService.instance
            .resolveFilename(
              fileBytes,
              originalFilename: item.metadata?.originalFilename,
              isImage: item.isImage,
            )
            .name;
        final tempFile = await TempFileService.instance.saveTempFile(
          fileBytes,
          filename,
        );
        final tempPath = tempFile.path;

        await _clipboardService.writeFilePath(tempPath);
        debugPrint('[SpotlightVM] Copied file path to clipboard: $tempPath');

        // Periodic cleanup retains the file while its URI is on the clipboard.
      } else if (item.isRichText) {
        // Copy rich text with format
        if (item.richTextFormat == RichTextFormat.html) {
          await _clipboardService.writeHtml(item.content);
        } else {
          await _clipboardService.writeText(item.content);
        }
        debugPrint('[SpotlightVM] Copied rich text to clipboard');
      } else {
        // Copy plain text
        await _clipboardService.writeText(item.content);
        debugPrint('[SpotlightVM] Copied text to clipboard');
      }

      // The user chose this copy, so a clip arriving in the next few minutes
      // should not overwrite it under smart auto-receive. A refactor once
      // dropped this call and staleness quietly stopped working.
      _syncService.updateClipboardModificationTime();

      _notificationService.showToast(
        message: 'Copied to clipboard',
        type: NotificationType.success,
      );

      onCopySuccess?.call();
    } on Exception catch (e) {
      _setError('Failed to copy: $e');
      debugPrint('[SpotlightVM] Failed to copy history item: $e');
    }
  }

  /// Handle deleting a history item
  Future<void> handleHistoryItemDelete(ClipboardItem item) async {
    try {
      await _clipboardRepo.delete(item.id);
      _historyItems.removeWhere((i) => i.id == item.id);
      notifyListeners();
      debugPrint('[SpotlightVM] Deleted history item ${item.id}');

      _notificationService.showToast(message: 'Item deleted');
    } on Exception catch (e) {
      _setError('Failed to delete: $e');
      debugPrint('[SpotlightVM] Failed to delete history item: $e');
    }
  }

  // ========== PRIVATE METHODS ==========

  /// Load clipboard history from repository
  Future<void> _loadHistory({required int revision}) async {
    try {
      _isLoadingHistory = true;
      notifyListeners();

      final items = await _clipboardRepo.getHistory();
      if (_isDisposed || revision != _accountRevision) return;
      _historyItems = items;
      _isLoadingHistory = false;
      notifyListeners();

      debugPrint('[SpotlightVM] ✓ Loaded ${items.length} history items');
    } on Exception catch (e) {
      debugPrint('[SpotlightVM] Failed to load history: $e');
      if (_isDisposed || revision != _accountRevision) return;
      _isLoadingHistory = false;
      notifyListeners();
    }
  }

  /// Debounced history reload (called by Realtime updates)
  void _debouncedLoadHistory() {
    _historyReloadTimer?.cancel();
    _historyReloadTimer = Timer(
      const Duration(milliseconds: 500),
      () => _loadHistory(revision: _accountRevision),
    );
  }

  /// Debounced content type detection
  void _debouncedDetectContentType() {
    _contentDetectionTimer?.cancel();
    _contentDetectionTimer = Timer(
      const Duration(milliseconds: 300),
      _detectContentType,
    );
  }

  /// Detect content type for smart transformations
  Future<void> _detectContentType() async {
    if (_content.isEmpty) {
      _detectedContentType = null;
      _transformationResult = null;
      _jwtTransformFuture = null;
      notifyListeners();
      return;
    }

    final content = _content;
    try {
      final result = await _transformerService.detectContentType(content);
      if (_isDisposed || content != _content) return;
      final previous = _detectedContentType;
      _detectedContentType = result;

      // For JWT, prefetch transformation for instant display
      if (result.type == TransformerContentType.jwt) {
        _jwtTransformFuture = _transformerService.transform(
          content,
          TransformerContentType.jwt,
        );
      } else {
        _jwtTransformFuture = null;
      }

      // Plain text has no preview that changes with each edit. The field
      // already paints its own edits; avoid rebuilding the whole spotlight.
      if (previous?.type != result.type ||
          result.type != TransformerContentType.plainText) {
        notifyListeners();
      }
    } on Exception catch (e) {
      debugPrint('[SpotlightVM] Content detection failed: $e');
    }
  }

  /// Set error message with auto-clear timer
  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();

    // Auto-clear error after 4 seconds
    _errorClearTimer?.cancel();
    _errorClearTimer = Timer(const Duration(seconds: 4), () {
      if (_errorMessage == message) {
        _errorMessage = null;
        notifyListeners();
      }
    });
  }

  // ========== DISPOSAL ==========

  bool _isDisposed = false;

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    // Cancel all timers
    _contentDetectionTimer?.cancel();
    _contentDetectionTimer = null;
    _historyReloadTimer?.cancel();
    _historyReloadTimer = null;
    _authStateSubscription?.cancel();
    _authStateSubscription = null;
    _errorClearTimer?.cancel();
    _errorClearTimer = null;

    // Hand the callbacks back as they were before initialize
    _syncService
      ..onClipboardReceived = _previousOnClipboardReceived
      ..onClipboardSent = _previousOnClipboardSent;

    // Clear cached futures
    _jwtTransformFuture = null;
    _transformationResult = null;

    // Clear large data to help GC
    _clipboardContent = null;
    _content = '';

    debugPrint('[SpotlightVM] Disposed');
    super.dispose();
  }
}
