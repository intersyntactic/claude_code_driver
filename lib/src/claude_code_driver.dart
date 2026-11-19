import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

import 'credential.dart';
import 'model_request.dart';

/// [AsksTheModel] by running `claude -p` once per call, signed in as the
/// seat the call names, with every built-in tool switched off.
///
/// One call is one text message: [askTheModel]'s `request`, an input array
/// of turns, goes to stdin flattened by [promptFor], and `systemPrompt` to
/// `--system-prompt-file` as its UTF-8 bytes; the command line is
/// [arguments], fixed for a model. Claude Code takes no earlier assistant
/// turns, so the turns become lines of one text. No turn names a model, so
/// the model is only ever the one decided.
///
/// The record holds what was given to `claude -p`, not the exact wire to
/// Anthropic: Claude Code may add context of its own.
final class ClaudeCodeDriver implements AsksTheModel {
  ClaudeCodeDriver(
    Map<ModelSignInName, Credential> signIns, {
    this._claude = 'claude',
    String? path,
    this._limit = const Duration(minutes: 10),
    void Function(String line)? log,
  }) : _signIns = Map.unmodifiable(signIns),
       _path = path ?? Platform.environment['PATH'] ?? '/usr/bin:/bin',
       _log = log ?? _silent;

  final Map<ModelSignInName, Credential> _signIns;

  /// The `claude` executable, by path or by name on [_path].
  final String _claude;

  /// The only variable of the driver's own environment `claude` is given.
  final String _path;

  /// How long one call may run before it is killed.
  final Duration _limit;

  /// Where a failed call's stderr and unreadable lines go: for whoever runs
  /// the driver, not the record. Never the token.
  final void Function(String line) _log;

  static void _silent(String _) {}

  /// Every flag is there to take something away. `--tools ""` offers the
  /// model no tool; `--restricted` removes the tools that run code or reach
  /// the web even if a later Claude Code reads `--tools ""` differently;
  /// `--safe-mode` stops hooks, skills, plugins and MCP servers the user's
  /// settings would load, which `--setting-sources ""` alone does not.
  /// Never `--bare`: it reads only `ANTHROPIC_API_KEY`, never the seat.
  ///
  /// The same for every call to [model]: the system prompt is named by a
  /// path relative to the working directory, which claude resolves there.
  static List<String> arguments(ModelName model) => [
    '-p',
    '--tools',
    '',
    '--restricted',
    '--safe-mode',
    '--strict-mcp-config',
    '--setting-sources',
    '',
    '--disable-slash-commands',
    '--no-session-persistence',
    '--input-format',
    'text',
    '--output-format',
    'stream-json',
    '--verbose',
    '--include-partial-messages',
    '--model',
    model.value,
    '--system-prompt-file',
    '../system-prompt',
  ];

  @override
  Future<Outcome<ModelReply>> askTheModel(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String request, {
    required Report report,
  }) async {
    final credential = _signIns[signIn];
    if (credential == null) return Refused('no model sign-in $signIn');
    final String prompt;
    try {
      prompt = promptFor(request);
    } on FormatException catch (e) {
      return Refused('not a request: ${e.message}');
    }

    // A fresh home and config per call, so no login, transcript or setting
    // outlives it or is shared between concurrent calls.
    final scratch = await Directory.systemTemp.createTemp('claude-code-call');
    try {
      final home = await Directory('${scratch.path}/home').create();
      final config = await Directory('${scratch.path}/config').create();
      final work = await Directory('${scratch.path}/work').create();
      // A file, not an argument: an argument is readable by every user on
      // the box in `ps`, and Linux caps one at 128 KiB. Beside [work], where
      // arguments' `../system-prompt` finds it.
      await File('${scratch.path}/system-prompt')
          .writeAsString(systemPrompt, flush: true);

      final Process process;
      try {
        process = await Process.start(
          _claude,
          arguments(model),
          workingDirectory: work.path,
          environment: {
            'PATH': _path,
            'HOME': home.path,
            'CLAUDE_CONFIG_DIR': config.path,
            ...switch (credential) {
              ClaudeCodeSetupToken(:final token) => {
                'CLAUDE_CODE_OAUTH_TOKEN': token,
              },
            },
          },
          includeParentEnvironment: false,
        );
      } on ProcessException catch (e) {
        return Refused('claude did not start: ${e.message}');
      }
      return await _run(process, prompt, report, '$signIn $model');
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  Future<Outcome<ModelReply>> _run(
    Process process,
    String request,
    Report report,
    String call,
  ) async {
    final stderr = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach((s) => stderr.write(s));
    process.stdin.add(utf8.encode(request));
    // claude may exit before reading all of stdin; that is its outcome to
    // report, not a failure of the write.
    unawaited(process.stdin.close().catchError((Object _) {}));

    Outcome<ModelReply>? outcome;
    var initialised = false;
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final reading = () async {
      await for (final line in lines) {
        switch (ClaudeEvent.parse(line)) {
          case Initialised(:final tools) when tools.isNotEmpty:
            // The last wall: if the flags ever stop taking every tool away,
            // no model turn runs.
            process.kill(ProcessSignal.sigkill);
            return Refused('claude offered tools: ${tools.join(' ')}');
          case Initialised():
            initialised = true;
          case Unreadable():
            _log('$call: unreadable line: ${_clip(line)}');
          case _ when !initialised:
            process.kill(ProcessSignal.sigkill);
            return const Refused('claude did not say which tools it offers');
          case TextArriving(:final text):
            report(ReplyArriving(text));
          case Answered(:final reply):
            outcome = Ran(reply);
          case Unanswered(:final why):
            outcome = Refused('claude: $why');
          case Other():
            break;
        }
      }
      return null;
    }();

    final Outcome<ModelReply>? early;
    final int exitCode;
    try {
      early = await reading.timeout(_limit);
      exitCode = await process.exitCode;
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      return Refused('timed out after ${_limit.inSeconds}s');
    }
    await stderrDone;
    final result = early ?? outcome;
    if (result is Ran<ModelReply> && exitCode == 0) return result;
    _log('$call: claude exited $exitCode: ${_clip(stderr.toString())}');
    return result ?? Refused('claude exited $exitCode without a result');
  }

  /// The version `claude --version` reports, such as `2.1.326`, or null
  /// when it does not run or says something else.
  static Future<String?> versionOf(String claude, {String? path}) async {
    try {
      final r = await Process.run(
        claude,
        ['--version'],
        environment: {'PATH': path ?? Platform.environment['PATH'] ?? ''},
        includeParentEnvironment: false,
      );
      if (r.exitCode != 0) return null;
      return RegExp(r'^(\d+\.\d+\.\d+)\b')
          .firstMatch('${r.stdout}'.trim())
          ?.group(1);
    } on ProcessException {
      return null;
    }
  }

  /// Whether [version] is at least [least], both `major.minor.patch`.
  static bool atLeast(String version, String least) {
    final [a, b] = [
      for (final v in [version, least])
        [for (final n in v.split('.')) int.parse(n)],
    ];
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return true;
  }

  static String _clip(String s) =>
      s.length <= 2000 ? s : '${s.substring(0, 2000)}…';
}

/// One line of `claude -p --output-format stream-json`, read once here so
/// nothing else reads its keys.
sealed class ClaudeEvent {
  const ClaudeEvent();

  static ClaudeEvent parse(String line) {
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      return const Unreadable();
    }
    return switch (json) {
      {'type': 'system', 'subtype': 'init', 'tools': final List<Object?> t} =>
        Initialised([for (final tool in t) '$tool']),
      {'type': 'system', 'subtype': 'init'} => const Initialised(['?']),
      {
        'type': 'stream_event',
        'event': {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': final String text},
        },
      } =>
        TextArriving(text),
      {
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': final String text,
      } =>
        Answered(ModelReply(text)),
      // An error the call itself reports, such as `Not logged in`, comes as
      // a `success` whose `is_error` is true and whose result says why.
      {'type': 'result', 'is_error': true, 'result': final String why}
          when why.isNotEmpty =>
        Unanswered(_words(why)),
      {'type': 'result', 'subtype': final String subtype} => Unanswered(
        subtype,
      ),
      {'type': 'result'} => const Unanswered('result of no kind'),
      Map<String, Object?>() => const Other(),
      _ => const Unreadable(),
    };
  }

  /// A refusal is kept for good, so a few words, not a body.
  static String _words(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';
}

/// Claude Code started and offers [tools]; it must offer none.
/// An init that lists no tools field reads as offering one, `?`, so a
/// changed format fails closed.
final class Initialised extends ClaudeEvent {
  const Initialised(this.tools);
  final List<String> tools;
}

/// A piece of the reply's text as it streams.
final class TextArriving extends ClaudeEvent {
  const TextArriving(this.text);
  final String text;
}

/// The call is over and [reply] is the whole of it.
final class Answered extends ClaudeEvent {
  const Answered(this.reply);
  final ModelReply reply;
}

/// The call is over without a reply, because [why].
final class Unanswered extends ClaudeEvent {
  const Unanswered(this.why);
  final String why;
}

/// A line that is not a JSON object.
final class Unreadable extends ClaudeEvent {
  const Unreadable();
}

/// Any other event, such as an assistant message or a rate limit notice.
final class Other extends ClaudeEvent {
  const Other();
}
