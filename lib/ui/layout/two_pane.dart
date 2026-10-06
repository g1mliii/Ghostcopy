/// Whether the main screen splits into compose and history panes, for a body
/// [width] wide on a window whose shorter side is [shortestSide].
///
/// Two conditions, because either alone gets a device wrong:
///
///  * Width: with the compose pane at its 320 minimum, 660 still leaves
///    history a small phone's width. Narrower, history would be thinner than
///    any phone.
///  * Shortest side: wide is not enough when the window is short. A phone in
///    landscape, or the iPhone Duo's cover screen turned sideways (678x466),
///    is wide enough to split but leaves each pane a sliver of height under
///    the app bar and keyboard. 600 is the usual phone/tablet line, so
///    phones stay one column in either orientation and tablets and unfolded
///    foldables split in both.
///
///   13" iPad portrait            1032 wide -> 400 compose + 632 history
///   11" iPad portrait             834      -> 375 + 459
///   iPad mini portrait            744      -> 335 + 409
///   iPhone Duo, unfolded     669 or 951    -> split either way
///   Galaxy Z Fold, unfolded  ~673-750      -> 320-338 + ~350-410
///   iPhone Duo cover, rotated     678x466  -> one column (too short)
///   phone, either orientation               -> one column
///   narrow iPad Split View        < 660    -> one column
bool usesTwoPanes({required double width, required double shortestSide}) =>
    width >= twoPaneMinWidth && shortestSide >= twoPaneMinShortestSide;

/// Narrowest body that splits. See [usesTwoPanes].
const double twoPaneMinWidth = 660;

/// Shortest window side that splits. See [usesTwoPanes].
const double twoPaneMinShortestSide = 600;
