import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:is_effects/is_effects.dart';

/// A model sign-in's secret. Each kind is a way Claude Code can be signed
/// in, so a new kind is a new case here, never a change to the caller.
sealed class Credential {
  const Credential();

  /// [raw], a sign-in's credential file, or a [FormatException] naming what
  /// is wrong with it but never its secret.
  static Credential parse(String raw) {
    final Object? json;
    try {
      json = decodeJsonRefusingDuplicateKeysAndUnsafeIntegers(raw);
    } on FormatException {
      throw const FormatException(
        'credential is not JSON, names a key twice, or holds an integer past 2^53 - 1',
      );
    }
    return switch (json) {
      {'kind': 'claude-code-setup-token', 'token': final String token}
          when json.length == 2 =>
        ClaudeCodeSetupToken.parse(token) ??
            (throw const FormatException(
              'token is not 108 letters, digits, - and _',
            )),
      {'kind': 'claude-code-setup-token'} => throw const FormatException(
        'a claude-code-setup-token holds exactly kind and token',
      ),
      {'kind': final String kind} => throw FormatException(
        'not a kind of model sign-in: $kind',
      ),
      _ => throw const FormatException('credential names no kind'),
    };
  }

  /// Every file in [directory], each a credential named for its model
  /// sign-in: what systemd's LoadCredential leaves in
  /// `$CREDENTIALS_DIRECTORY`.
  static Future<Map<ModelSignInName, Credential>> load(
    Directory directory,
  ) async {
    final loaded = <ModelSignInName, Credential>{};
    await for (final file in directory.list()) {
      if (file is! File) continue;
      final name = file.uri.pathSegments.last;
      final signIn =
          ModelSignInName.parse(name) ??
          (throw FormatException('not a model sign-in name', name));
      try {
        loaded[signIn] = parse(await file.readAsString());
      } on FormatException catch (e) {
        throw FormatException('$signIn: ${e.message}');
      }
    }
    return loaded;
  }
}

/// A Claude Code seat's long-lived token, as `claude setup-token` prints
/// it. Claude Code reads it from `CLAUDE_CODE_OAUTH_TOKEN`.
final class ClaudeCodeSetupToken extends Credential {
  const ClaudeCodeSetupToken._(this.token);

  /// [raw] as a setup token, or null unless it is 108 letters, digits, `-`
  /// and `_`.
  static ClaudeCodeSetupToken? parse(String raw) =>
      _token.hasMatch(raw) ? ClaudeCodeSetupToken._(raw) : null;

  static final _token = RegExp(r'^[A-Za-z0-9_-]{108}$');

  final String token;

  @override
  String toString() => 'a claude-code-setup-token';
}
