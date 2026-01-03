import '../services/transformer_service.dart';
import 'clipboard_item.dart';

/// Represents the overall application state
class AppState {
  const AppState({
    this.isSleeping = false,
    this.isGameModeActive = false,
    this.isSpotlightVisible = false,
    this.history = const [],
    this.currentItem,
    this.detectedContentType,
  });

  final bool isSleeping;
  final bool isGameModeActive;
  final bool isSpotlightVisible;
  final List<ClipboardItem> history;
  final ClipboardItem? currentItem;
  final TransformerContentType? detectedContentType;

  AppState copyWith({
    bool? isSleeping,
    bool? isGameModeActive,
    bool? isSpotlightVisible,
    List<ClipboardItem>? history,
    ClipboardItem? currentItem,
    TransformerContentType? detectedContentType,
  }) {
    return AppState(
      isSleeping: isSleeping ?? this.isSleeping,
      isGameModeActive: isGameModeActive ?? this.isGameModeActive,
      isSpotlightVisible: isSpotlightVisible ?? this.isSpotlightVisible,
      history: history ?? this.history,
      currentItem: currentItem ?? this.currentItem,
      detectedContentType: detectedContentType ?? this.detectedContentType,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppState &&
        other.isSleeping == isSleeping &&
        other.isGameModeActive == isGameModeActive &&
        other.isSpotlightVisible == isSpotlightVisible &&
        other.history == history &&
        other.currentItem == currentItem &&
        other.detectedContentType == detectedContentType;
  }

  @override
  int get hashCode {
    return Object.hash(
      isSleeping,
      isGameModeActive,
      isSpotlightVisible,
      history,
      currentItem,
      detectedContentType,
    );
  }
}
