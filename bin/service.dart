/// Runs the Claude Code driver (see `ClaudeCodeDriver`):
///
///     CLAUDE_CODE_DRIVER_SOCKET=/run/intersyntactic-claude-code-driver/claude-code-driver.sock \
///       CLAUDE_CODE_DRIVER_CALLER=airlock \
///       CREDENTIALS_DIRECTORY=... \
///       dart run is_claude_code_driver:service
///
/// `CLAUDE_CODE_DRIVER_CALLER` is the one user, by name or id, whose calls
/// it carries out. `CLAUDE_CODE_DRIVER_CLAUDE` is the `claude` executable,
/// `claude` on PATH when unset; it must be 2.1.311 or later, or 2.1.112.
/// `CLAUDE_CODE_DRIVER_SPARES` is how many combinations of sign-in, model
/// and system prompt keep a `claude` started and waiting, 0 when unset.
/// systemd sets `CREDENTIALS_DIRECTORY` from `LoadCredential=`.
///
/// Exits 78 when it cannot start as configured, and closes cleanly on
/// SIGTERM or SIGINT.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_claude_code_driver/is_claude_code_driver.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

Future<void> main() async {
  final env = Platform.environment;
  final [socket, caller, credentials] = [
    for (final name in [
      'CLAUDE_CODE_DRIVER_SOCKET',
      'CLAUDE_CODE_DRIVER_CALLER',
      'CREDENTIALS_DIRECTORY',
    ])
      env[name] ?? _fail('$name is not set'),
  ];
  final claude = env['CLAUDE_CODE_DRIVER_CLAUDE'] ?? 'claude';
  final uid =
      _uidOf(caller) ??
      _fail('no user $caller, or one that names no real user');
  final version =
      await ClaudeCodeDriver.versionOf(claude) ??
      _fail('$claude --version did not answer with a version');
  final flags =
      ClaudeCodeFlags.forVersion(version) ??
      _fail('claude $version is neither 2.1.311 or later nor 2.1.112');
  final sparesSetting = env['CLAUDE_CODE_DRIVER_SPARES'];
  final spares = sparesSetting == null ? 0 : int.tryParse(sparesSetting);
  if (spares == null || spares < 0) {
    _fail('CLAUDE_CODE_DRIVER_SPARES is not a count: $sparesSetting');
  }
  final Map<ModelSignInName, Credential> signIns;
  try {
    signIns = await Credential.load(Directory(credentials));
  } on Exception catch (e) {
    _fail('$e');
  }
  if (signIns.isEmpty) _fail('no model sign-ins in $credentials');
  final ClaudeCodeDriver driver;
  try {
    driver = await ClaudeCodeDriver.start(
      signIns,
      caller: uid,
      socket: File(socket),
      flags: flags,
      claude: claude,
      spares: spares,
      log: stdout.writeln,
    );
  } on Object catch (e) {
    _fail('$e');
  }
  stdout.writeln(
    'listening on $socket for $caller, claude $version, '
    'model sign-ins: ${signIns.keys.join(' ')}, spares: $spares',
  );
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }
  await stop.future;
  await driver.close();
  exit(0);
}

/// [user], by name or id, as a user that names one real user; null when no
/// such user exists or it is one the kernel uses for an unknown user.
UserId? _uidOf(String user) {
  final number =
      int.tryParse(user) ??
      switch (Process.runSync('id', ['-u', user])) {
        final r when r.exitCode == 0 => int.tryParse('${r.stdout}'.trim()),
        _ => null,
      };
  return number == null ? null : UserId.parse(number);
}

Never _fail(String why) {
  stderr.writeln('is_claude_code_driver service: $why');
  exit(78);
}
