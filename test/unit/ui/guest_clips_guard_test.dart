import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/ui/guest_clips_guard.dart';

/// Tests for the prompt that stands between a guest's clips and sign-in.
///
/// It began as two private methods on the desktop auth panel, which left the
/// mobile welcome screen signing into another account with no prompt at all -
/// the same clips, destroyed silently, on the platform most likely to be
/// holding them. It is shared now, so these cover both surfaces.
class _FakeAuth implements IAuthService {
  _FakeAuth({required this.anonymous});
  final bool anonymous;

  @override
  bool get isAnonymous => anonymous;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRepo implements IClipboardRepository {
  _FakeRepo({this.count = 0, this.throws = false});
  final int count;
  final bool throws;

  @override
  Future<int> getClipboardCountForCurrentUser() async {
    if (throws) throw RepositoryException('offline');
    return count;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  Future<bool?> run(
    WidgetTester tester, {
    required bool anonymous,
    int count = 0,
    bool throws = false,
    bool deletesClips = false,
    String? tap,
  }) async {
    bool? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await confirmGuestClipsBeforeSignIn(
                context,
                authService: _FakeAuth(anonymous: anonymous),
                clipboardRepository: _FakeRepo(count: count, throws: throws),
                deletesClips: deletesClips,
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    if (tap != null) {
      expect(find.text(tap), findsOneWidget);
      await tester.tap(find.text(tap));
      await tester.pumpAndSettle();
    }
    return result;
  }

  testWidgets('a signed-in user is never prompted', (tester) async {
    expect(await run(tester, anonymous: false, count: 9), isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a guest with no clips is never prompted', (tester) async {
    expect(await run(tester, anonymous: true), isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a guest with clips is asked, and cancelling refuses', (
    tester,
  ) async {
    final result = await run(tester, anonymous: true, count: 3, tap: 'Cancel');

    expect(result, isFalse);
  });

  testWidgets('accepting allows the sign-in', (tester) async {
    final result = await run(
      tester,
      anonymous: true,
      count: 3,
      tap: 'Sign in anyway',
    );

    expect(result, isTrue);
  });

  testWidgets('the Google path says the clips are deleted', (tester) async {
    // The whole point of deletesClips: this path really does destroy them,
    // and "left behind" would understate it.
    await run(tester, anonymous: true, count: 2, deletesClips: true);

    expect(find.text('Delete your clips?'), findsOneWidget);
    expect(find.text('Delete and sign in'), findsOneWidget);
    expect(find.textContaining('cannot be recovered'), findsOneWidget);
  });

  testWidgets('the email path does not claim deletion', (tester) async {
    await run(tester, anonymous: true, count: 2);

    expect(find.text('Leave your clips behind?'), findsOneWidget);
    expect(find.textContaining('cannot be recovered'), findsNothing);
  });

  testWidgets('an unknown count refuses rather than assuming zero', (
    tester,
  ) async {
    // getClipboardCountForCurrentUser throws instead of reporting 0 precisely
    // so that an unreachable server cannot authorize discarding an account.
    final result = await run(tester, anonymous: true, throws: true);

    expect(result, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('the count is pluralized', (tester) async {
    await run(tester, anonymous: true, count: 1);
    expect(find.textContaining('1 clip '), findsOneWidget);
  });
}
