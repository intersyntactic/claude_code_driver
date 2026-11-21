/// Runs the Claude Code driver as a service (see
/// `package:is_claude_code_driver/service.dart`):
///
///     CLAUDE_CODE_DRIVER_SOCKET=/run/intersyntactic-claude-code-driver/claude-code-driver.sock \
///       CLAUDE_CODE_DRIVER_CALLER=airlock \
///       CREDENTIALS_DIRECTORY=... \
///       dart run is_claude_code_driver:service
///
/// `CLAUDE_CODE_DRIVER_CALLER` is the one user, by name or id, whose calls
/// it carries out. `CLAUDE_CODE_DRIVER_CLAUDE` is the `claude` executable,
/// `claude` on PATH when unset. systemd sets `CREDENTIALS_DIRECTORY` from
/// `LoadCredential=`.
///
/// Exits 78 when it cannot start as configured, and closes cleanly on
/// SIGTERM or SIGINT.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_claude_code_driver/is_claude_code_driver.dart';
import 'package:is_claude_code_driver/service.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_peer_user_admission/is_peer_user_admission.dart';

/// The oldest Claude Code with every flag the driver passes.
const _leastClaude = '2.1.311';

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
  if (!ClaudeCodeDriver.atLeast(version, _leastClaude)) {
    _fail('claude $version is older than $_leastClaude');
  }
  final Map<ModelSignInName, Credential> signIns;
  try {
    signIns = await Credential.load(Directory(credentials));
  } on Exception catch (e) {
    _fail('$e');
  }
  if (signIns.isEmpty) _fail('no model sign-ins in $credentials');
  final ClaudeCodeDriverService service;
  try {
    service = await ClaudeCodeDriverService.start(
      ClaudeCodeDriver(signIns, claude: claude, log: stdout.writeln),
      uid,
      File(socket),
    );
  } on Object catch (e) {
    _fail('$e');
  }
  stdout.writeln(
    'listening on $socket for $caller, claude $version, '
    'model sign-ins: ${signIns.keys.join(' ')}',
  );
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }
  await stop.future;
  await service.close();
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
