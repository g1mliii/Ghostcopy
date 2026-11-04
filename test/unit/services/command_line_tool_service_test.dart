import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/command_line_tool_service.dart';
import 'package:path/path.dart' as path;

/// Windows creates a symlink only with Developer Mode on or from an elevated
/// shell, and the tests that make one throw ERROR_PRIVILEGE_NOT_HELD without
/// it. Returns the skip reason then, null wherever links can be made.
String? _symlinksUnavailable() {
  if (!Platform.isWindows) return null;
  final probe = Directory.systemTemp.createTempSync('ghostcopy_link_probe_');
  try {
    Link(path.join(probe.path, 'link')).createSync(probe.path);
    return null;
  } on FileSystemException {
    return 'Creating a symlink needs Developer Mode or an elevated shell';
  } finally {
    probe.deleteSync(recursive: true);
  }
}

void main() {
  final noSymlinks = _symlinksUnavailable();
  late Directory root;
  late String helper;
  late String link;
  late List<List<String>> calls;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ghostcopy_cli_');
    helper = path.join(
      root.path,
      'GhostCopy.app',
      'Contents',
      'Helpers',
      'ghostcopy',
    );
    link = path.join(root.path, 'bin', 'ghostcopy');
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
          Link(link).createSync(linkTo ?? helper, recursive: true);
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
    }, skip: noSymlinks);

    test('is not installed when the link points at another copy', () async {
      bundleHelper();
      Link(link).createSync('/Applications/Old.app/ghostcopy', recursive: true);
      expect(await build().state(), CommandLineToolState.notInstalled);
    }, skip: noSymlinks);

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
      expect(call.sublist(call.length - 3), [helper, link, path.dirname(link)]);
      final script = call.where((part) => part != '-e').take(4).join('\n');
      expect(script, isNot(contains(root.path)));
      expect(script, contains('with administrator privileges'));
    }, skip: noSymlinks);

    test('reports a cancelled password prompt as not installed', () async {
      bundleHelper();
      final service = build(succeed: false);
      expect(await service.install(), isFalse);
      expect(await service.state(), CommandLineToolState.notInstalled);
    });

    test('is false when the link made does not point at this app', () async {
      bundleHelper();
      expect(await build(linkTo: '/elsewhere').install(), isFalse);
    }, skip: noSymlinks);
  });
}
