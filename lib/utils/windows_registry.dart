import 'dart:io';

/// Execute [arguments] with reg.exe, treating nonzero status as a failure.
/// [run] allows testing without modifying the machine's registry.
Future<void> runWindowsRegistryCommand(
  List<String> arguments, {
  Future<ProcessResult> Function(String, List<String>)? run,
}) async {
  final result = await (run ?? Process.run)('reg', arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      'reg',
      arguments,
      result.stderr.toString(),
      result.exitCode,
    );
  }
}
