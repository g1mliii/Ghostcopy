import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/command_line_tool_service.dart';

void main() {
  late Directory root;
  late String helper;
  late String link;
  late List<List<String>> calls;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ghostcopy_cli_');
    helper = '${root.path}/GhostCopy.app/Contents/Helpers/ghostcopy';
    link = '${root.path}/bin/ghostcopy';
    calls = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  void bundleHelper() => File(helper).createSync(recursive: true);

  /// Stands in for osascript: records the call and, when [succeed], makes the
  /// link the real script would have made.
  CommandLineToolService build({bool succeed = true, String? linkTo}) =>
      CommandLineToolService(
        helperPath: helper,
        linkPath: link,
        runProcess: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          if (!succeed) {
            return ProcessResult(0, 1, '', 'User canceled. (-128)');
          }
          Directory('${root.path}/bin').createSync(recursive: true);
          Link(link).createSync(linkTo ?? helper);
          return ProcessResult(0, 0, '', '');
        },
      );

  group('state', () {
    test('is unavailable when the build carries no command', () async {
      expect(await build().state(), CommandLineToolState.unavailable);
    });

    test('is not installed when nothing is on the PATH', () async {
      bundleHelper();
      expect(await build().state(), CommandLineToolState.notInstalled);
    });

    test('is installed when the link points at this app', () async {
      bundleHelper();
      Link(link).createSync(helper, recursive: true);
      expect(await build().state(), CommandLineToolState.installed);
    });

    test('is not installed when the link points at another copy', () async {
      bundleHelper();
      Link(link).createSync('/Applications/Old.app/ghostcopy', recursive: true);
      expect(await build().state(), CommandLineToolState.notInstalled);
    });

    test('is not installed when a plain file holds the name', () async {
      bundleHelper();
      File(link).createSync(recursive: true);
      expect(await build().state(), CommandLineToolState.notInstalled);
    });
  });

  group('install', () {
    test('passes the paths as arguments, not inside the script', () async {
      bundleHelper();
      expect(await build().install(), isTrue);

      final call = calls.single;
      expect(call.first, '/usr/bin/osascript');
      expect(call.sublist(call.length - 3), [helper, link, '${root.path}/bin']);
      final script = call.where((part) => part != '-e').take(4).join('\n');
      expect(script, isNot(contains(root.path)));
      expect(script, contains('with administrator privileges'));
    });

    test('reports a cancelled password prompt as not installed', () async {
      bundleHelper();
      final service = build(succeed: false);
      expect(await service.install(), isFalse);
      expect(await service.state(), CommandLineToolState.notInstalled);
    });

    test('is false when the link made does not point at this app', () async {
      bundleHelper();
      expect(await build(linkTo: '/elsewhere').install(), isFalse);
    });
  });
}
