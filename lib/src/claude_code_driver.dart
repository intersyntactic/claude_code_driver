import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

import 'credential.dart';
import 'model_request.dart';

/// The Claude Code driver: a service on a Unix socket that asks the model by
/// running `claude -p` once per call, signed in as the seat the call names,
/// with every built-in tool switched off, for the airlock's user alone.
///
/// A caller connects, writes one call as JSON and closes its side:
///
///     {"signIn":"…","model":"…","systemPrompt":"…","request":"…"}
///
/// The driver answers one JSON line per message and closes: any number of
/// `{"kind":"reported","progress":…}` while the reply streams, then one
/// `{"kind":"finished","outcome":…}`, the `Outcome<ModelReply>`. Who is
/// calling is read from the socket as the kernel reports it, never from the
/// call. It runs as its own user, so a seat's token is readable by this
/// process and no other.
///
/// One call is one user message: its `request`, an input array of turns,
/// is flattened by [promptFor] and goes to stdin as [userMessage], and its
/// `systemPrompt` to `--system-prompt-file` as its UTF-8 bytes; the command
/// line is [arguments], fixed for a model. Claude Code takes no earlier
/// assistant turns, so the turns become lines of one text. No turn names a
/// model, so the model is only ever the one decided.
///
/// The logbook holds what was given to `claude -p`, not the exact wire to
/// Anthropic: Claude Code may add context of its own.
final class ClaudeCodeDriver {
  ClaudeCodeDriver._(
    this._signIns,
    this._claude,
    this._flags,
    this._path,
    this._limit,
    this._spares,
    this._spareLifetime,
    this._liveSessions,
    this._sessionLifetime,
    this._clock,
    this._log,
    this._socketUserCheck,
    this._socket,
    this._server,
  );

  /// Listens on [socket] for the user [caller] alone, asking the model as
  /// the seats in [signIns]. [claude] is the `claude` executable, by path or
  /// by name on [path], and [flags] the ones it accepts; [limit] is how long
  /// one call may run; [socketUserReader] reads each caller's user from the
  /// kernel, the running kernel's by default. A socket file nothing listens
  /// on is replaced.
  ///
  /// [spares] is how many combinations of sign-in, model and system prompt
  /// are kept warm: after a call, a `claude` for the same three is started
  /// and left waiting, so the next such call skips Claude Code's startup.
  /// None by default. A spare older than [spareLifetime] by [clock], or one
  /// that has exited, is replaced instead of used.
  ///
  /// [liveSessions] is how many `claude`s are kept running after a call
  /// they finished, so the next step of the same trajectory is written into
  /// one as only its new turns: when that call's turns are exactly the
  /// ones the session holds, its reply, and one or more new user turns.
  /// Any other call starts afresh. None by default, so each call is a
  /// `claude` of its own. A session idle for [sessionLifetime] is ended.
  static Future<ClaudeCodeDriver> start(
    Map<ModelSignInName, Credential> signIns, {
    required UserId caller,
    required File socket,
    required ClaudeCodeFlags flags,
    String claude = 'claude',
    String? path,
    Duration limit = const Duration(minutes: 10),
    int spares = 0,
    Duration spareLifetime = const Duration(minutes: 30),
    int liveSessions = 0,
    Duration sessionLifetime = const Duration(minutes: 30),
    DateTime Function() clock = DateTime.now,
    void Function(String line)? log,
    SocketUserReader? socketUserReader,
  }) async {
    if (spares < 0) throw ArgumentError.value(spares, 'spares', 'negative');
    if (liveSessions < 0) {
      throw ArgumentError.value(liveSessions, 'liveSessions', 'negative');
    }
    final driver = ClaudeCodeDriver._(
      Map.unmodifiable(signIns),
      claude,
      flags,
      path ?? Platform.environment['PATH'] ?? '/usr/bin:/bin',
      limit,
      spares,
      spareLifetime,
      liveSessions,
      sessionLifetime,
      clock,
      log ?? _silent,
      SocketUserCheck.only(caller, reader: socketUserReader),
      socket,
      await _bind(socket),
    );
    driver._server.listen(driver._serve);
    return driver;
  }

  final Map<ModelSignInName, Credential> _signIns;

  /// The `claude` executable, by path or by name on [_path].
  final String _claude;

  /// The flags [_claude] accepts.
  final ClaudeCodeFlags _flags;

  /// How many combinations of sign-in, model and system prompt keep a
  /// spare, and how long one may wait before it is replaced.
  final int _spares;
  final Duration _spareLifetime;
  final DateTime Function() _clock;

  /// The waiting spares, least recently used first.
  final _waiting = <_SpareKey, _Claude>{};

  /// How many idle `claude`s are kept for their trajectory's next step, and
  /// how long one may wait for it.
  final int _liveSessions;
  final Duration _sessionLifetime;

  /// The idle sessions, least recently used first.
  final _idle = <_Claude>[];

  var _closed = false;

  /// The only variable of the driver's own environment `claude` is given.
  final String _path;

  /// How long one call may run before it is killed.
  final Duration _limit;

  /// Where a failed call's stderr and unreadable lines go: for whoever runs
  /// the driver, not the logbook. Never the token.
  final void Function(String line) _log;

  final SocketUserCheck _socketUserCheck;
  final File _socket;
  final ServerSocket _server;

  static void _silent(String _) {}

  /// A whole trajectory rendered as text fits well inside this.
  static const maxCall = 16 << 20;

  static Future<ServerSocket> _bind(File socket) async {
    final address = InternetAddress(
      socket.path,
      type: InternetAddressType.unix,
    );
    if (socket.existsSync()) {
      try {
        (await Socket.connect(address, 0)).destroy();
        throw StateError('a service is already listening on ${socket.path}');
      } on SocketException {
        socket.deleteSync();
      }
    }
    return ServerSocket.bind(address, 0);
  }

  /// Stops listening and ends every spare and idle session, deleting its
  /// folder. A call still running ends its `claude` when it finishes.
  Future<void> close() async {
    _closed = true;
    await _server.close();
    if (_socket.existsSync()) _socket.deleteSync();
    final ending = [..._waiting.values, ..._idle];
    _waiting.clear();
    _idle.clear();
    await Future.wait([for (final claude in ending) claude.end()]);
  }

  Future<void> _serve(Socket socket) async {
    try {
      if (!_socketUserCheck.allows(socket)) {
        socket.destroy();
        return;
      }
      final bytes = BytesBuilder(copy: false);
      var tooLarge = false;
      await for (final chunk in socket) {
        if (bytes.length + chunk.length > maxCall) {
          tooLarge = true;
          break;
        }
        bytes.add(chunk);
      }
      if (tooLarge) {
        _write(socket, const Finished(Refused('call too large')));
        await socket.close();
        return;
      }
      final ModelSignInName signIn;
      final ModelName model;
      final String systemPrompt;
      final String request;
      try {
        (signIn, model, systemPrompt, request) = decodeModelCall(
          jsonDecode(utf8.decode(bytes.takeBytes(), allowMalformed: true)),
        );
      } on FormatException catch (e) {
        _write(socket, Finished(Refused('not a call: ${e.message}')));
        await socket.close();
        return;
      }
      final outcome = await _ask(
        signIn,
        model,
        systemPrompt,
        request,
        report: (progress) => _write(socket, Reported(progress)),
      );
      _write(socket, Finished(outcome));
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  static void _write(Socket socket, ProgramMessage<ModelReply> message) =>
      socket.add(
        utf8.encode(
          '${jsonEncode(encodeProgramMessage(message, encodeModelReply))}\n',
        ),
      );

  /// Every flag is there to take something away. `--tools ""` offers the
  /// model no tool; `--restricted` removes the tools that run code or reach
  /// the web even if a later Claude Code reads `--tools ""` differently;
  /// `--safe-mode` stops hooks, skills, plugins and MCP servers the user's
  /// settings would load, which `--setting-sources ""` alone does not.
  /// [flags] leaves out the two a Claude Code does not accept. Never
  /// `--bare`: it reads only `ANTHROPIC_API_KEY`, never the seat.
  ///
  /// The request goes in as one stream-json user message: a text prompt is
  /// abandoned when stdin stays empty for 3 s, which a spare's does.
  ///
  /// The same for every call to [model]: the system prompt is named by a
  /// path relative to the working directory, which claude resolves there.
  static List<String> arguments(ModelName model, ClaudeCodeFlags flags) => [
    '-p',
    '--tools',
    '',
    if (flags == ClaudeCodeFlags.everyFlag) ...['--restricted', '--safe-mode'],
    '--strict-mcp-config',
    '--setting-sources',
    '',
    '--disable-slash-commands',
    '--no-session-persistence',
    '--input-format',
    'stream-json',
    '--output-format',
    'stream-json',
    '--verbose',
    '--include-partial-messages',
    '--model',
    model.value,
    '--system-prompt-file',
    '../system-prompt',
  ];

  /// The one line written to claude's stdin for [prompt]: a stream-json
  /// user message whose content is [prompt] exactly.
  static String userMessage(String prompt) =>
      '${jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': prompt},
      })}\n';

  /// The one line written to a live session for the user [turns] that
  /// follow its last reply: one user message, one text block per turn,
  /// each exactly as sent, so the model answers once.
  static String continuation(List<String> turns) =>
      '${jsonEncode({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            for (final turn in turns) {'type': 'text', 'text': turn},
          ],
        },
      })}\n';

  Future<Outcome<ModelReply>> _ask(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String request, {
    required Report report,
  }) async {
    final credential = _signIns[signIn];
    if (credential == null) return Refused('no model sign-in $signIn');
    final List<Turn> turns;
    try {
      turns = turnsOf(request);
    } on FormatException catch (e) {
      return Refused('not a request: ${e.message}');
    }

    final key = (signIn, model, systemPrompt);
    final call = '$signIn $model';
    final _Claude claude;
    final String message;
    if (_continuable(key, turns) case (final session, final added)) {
      claude = session;
      message = continuation(added);
    } else {
      try {
        claude = _takeSpare(key) ?? await _startClaude(key, credential);
      } on ProcessException catch (e) {
        return Refused('claude did not start: ${e.message}');
      }
      if (_spares > 0) unawaited(_keepSpare(key, credential));
      message = userMessage(flatten(turns));
    }

    final outcome = await _converse(claude, message, report, model, call);
    // Kept only after a whole reply, which a trajectory's next call repeats
    // as its assistant turn; a cut-off one it repeats with a note added.
    if (outcome case Ran<ModelReply>(output: FinishedReply(:final text))
        when _liveSessions > 0 && !_closed && !claude.hasExited) {
      claude.turns = [...turns, (role: TurnRole.assistant, content: text)];
      claude.idleSince = _clock();
      _idle.add(claude);
      while (_idle.length > _liveSessions) {
        unawaited(_idle.removeAt(0).end());
      }
      return outcome;
    }
    final exitCode = await claude.finish();
    if (outcome is! Ran<ModelReply> || exitCode != 0) {
      _log('$call: claude exited $exitCode: ${_clip(claude.stderr)}');
    }
    return outcome ?? Refused('claude exited $exitCode without a result');
  }

  /// The idle session [turns] continue, taken from the idle ones, with the
  /// content of the user turns it has not seen; null when none does. A
  /// session continues only a call for its [key] whose turns begin with
  /// exactly the turns it holds, its reply among them, and go on with
  /// nothing but user turns. Sessions past their lifetime, or that exited,
  /// are ended on the way.
  (_Claude, List<String>)? _continuable(_SpareKey key, List<Turn> turns) {
    final now = _clock();
    for (final session in [..._idle]) {
      final stale = !now.isBefore(session.idleSince.add(_sessionLifetime));
      if (session.hasExited || stale) {
        _idle.remove(session);
        unawaited(session.end());
      }
    }
    for (final session in _idle.reversed) {
      final held = session.turns;
      if (session.key != key || !_begins(turns, held)) continue;
      final added = turns.sublist(held.length);
      if (added.isEmpty) continue;
      if (added.any((turn) => turn.role != TurnRole.user)) continue;
      _idle.remove(session);
      return (session, [for (final turn in added) turn.content]);
    }
    return null;
  }

  /// The waiting spare for [key] if it can still be used, taking it from
  /// the waiting ones; null when there is none to use.
  _Claude? _takeSpare(_SpareKey key) {
    final spare = _waiting.remove(key);
    if (spare == null) return null;
    final stale = !_clock().isBefore(spare.started.add(_spareLifetime));
    if (!spare.hasExited && !stale) return spare;
    unawaited(spare.end());
    return null;
  }

  /// Whether [turns] begins with exactly [held], role and content.
  static bool _begins(List<Turn> turns, List<Turn> held) {
    if (turns.length < held.length) return false;
    for (var i = 0; i < held.length; i++) {
      if (turns[i] != held[i]) return false;
    }
    return true;
  }

  /// Starts a spare for [key] and leaves it waiting, ending the one it
  /// replaces and the least recently used beyond [_spares].
  Future<void> _keepSpare(_SpareKey key, Credential credential) async {
    final (signIn, model, _) = key;
    final _Claude spare;
    try {
      spare = await _startClaude(key, credential);
    } on ProcessException catch (e) {
      _log('$signIn $model: no spare: claude did not start: ${e.message}');
      return;
    }
    if (_closed) return spare.end();
    final ending = [?_waiting.remove(key)];
    _waiting[key] = spare;
    while (_waiting.length > _spares) {
      ending.add(_waiting.remove(_waiting.keys.first)!);
    }
    await Future.wait([for (final old in ending) old.end()]);
  }

  /// Starts `claude` for [key]'s model and system prompt, signed in with
  /// [credential], waiting for a message on stdin.
  ///
  /// A fresh home and config per `claude`, so no login, transcript or
  /// setting outlives it or is shared between concurrent calls.
  Future<_Claude> _startClaude(_SpareKey key, Credential credential) async {
    final (_, model, systemPrompt) = key;
    final scratch = await Directory.systemTemp.createTemp('claude-code-call');
    var started = false;
    try {
      final home = await Directory('${scratch.path}/home').create();
      final config = await Directory('${scratch.path}/config').create();
      final work = await Directory('${scratch.path}/work').create();
      // A file, not an argument: an argument is readable by every user on
      // the box in `ps`, and Linux caps one at 128 KiB. Beside [work], where
      // arguments' `../system-prompt` finds it.
      await File('${scratch.path}/system-prompt')
          .writeAsString(systemPrompt, flush: true);
      final process = await Process.start(
        _claude,
        arguments(model, _flags),
        workingDirectory: work.path,
        environment: {
          'PATH': _path,
          'HOME': home.path,
          'CLAUDE_CONFIG_DIR': config.path,
          // Takes away what a call does not ask for, such as 2.1.112's
          // request for a session title, which carries the prompt to
          // another model.
          'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
          // A full context is refused rather than summarised: a summary
          // would stand in for the approved turns without saying so.
          'DISABLE_AUTO_COMPACT': '1',
          ...switch (credential) {
            ClaudeCodeSetupToken(:final token) => {
              'CLAUDE_CODE_OAUTH_TOKEN': token,
            },
          },
        },
        includeParentEnvironment: false,
      );
      started = true;
      return _Claude(process, scratch, key, _clock());
    } finally {
      if (!started) await scratch.delete(recursive: true);
    }
  }

  /// Writes [message] to [claude] and reads its events until the call is
  /// settled: the outcome, or null when claude's output ended first. With no
  /// live sessions, stdin closes after the message, its only one.
  Future<Outcome<ModelReply>?> _converse(
    _Claude claude,
    String message,
    Report report,
    ModelName model,
    String call,
  ) async {
    final settled = Completer<Outcome<ModelReply>?>();
    void settle(Outcome<ModelReply>? outcome) {
      if (!settled.isCompleted) settled.complete(outcome);
    }

    void refuse(String why) {
      claude.kill();
      settle(Refused(why));
    }

    claude.listen((line) {
      if (settled.isCompleted) return;
      switch (ClaudeEvent.parse(line, model: model)) {
        case Initialised(:final tools) when tools.isNotEmpty:
          // The last wall: if the flags ever stop taking every tool away,
          // no model turn runs.
          refuse('claude offered tools: ${tools.join(' ')}');
        case Initialised():
          claude.initialised = true;
        case Unreadable():
          _log('$call: unreadable line: ${_clip(line)}');
        case Compacted():
          refuse('claude summarised the conversation in place of its turns');
        case Notice():
          break;
        case _ when !claude.initialised:
          refuse('claude did not say which tools it offers');
        case TextArriving(:final text):
          report(ReplyArriving(text));
        case Answered(:final reply):
          settle(Ran(reply));
        case Unanswered(:final why):
          settle(Refused('claude: $why'));
        case Other():
          break;
      }
    }, ended: () => settle(null));
    claude.write(message, last: _liveSessions == 0);
    try {
      return await settled.future.timeout(_limit);
    } on TimeoutException {
      claude.kill();
      return Refused('timed out after ${_limit.inSeconds}s');
    } finally {
      claude.unlisten();
    }
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

/// Which spares and sessions a call can use: they share its sign-in, model
/// and system prompt, all three fixed when `claude` starts.
typedef _SpareKey = (ModelSignInName, ModelName, String);

/// A started `claude` and the folder it runs in: a spare until a call
/// takes it, then that call's, and after it a live session if kept.
final class _Claude {
  _Claude(this.process, this.scratch, this.key, this.started)
    : idleSince = started {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => (_onLine ?? _unread.add)(line),
          onDone: _stdoutDone.complete,
        );
    process.stderr.transform(utf8.decoder).listen((text) {
      if (_stderr.length < 64 << 10) _stderr.write(text);
    }, onDone: _stderrDone.complete);
    // A write to a claude that has exited is its outcome to report, not a
    // failure of the driver's.
    unawaited(process.stdin.done.catchError((Object _) {}));
    unawaited(process.exitCode.then((_) => hasExited = true));
  }

  final Process process;
  final Directory scratch;
  final _SpareKey key;
  final DateTime started;
  var hasExited = false;

  /// Whether it has said which tools it offers: once, on its first call.
  var initialised = false;

  /// As a live session: the turns it holds, its last reply the last of
  /// them, and since when it has waited.
  List<Turn> turns = const [];
  DateTime idleSince;

  void Function(String line)? _onLine;
  void Function()? _onEnded;
  final _unread = <String>[];
  final _stdoutDone = Completer<void>();
  final _stderrDone = Completer<void>();
  final _stderr = StringBuffer();

  /// What it has written to stderr, its first 64 KiB.
  String get stderr => _stderr.toString();

  /// Hands each line of its output to [onLine], those no call has read
  /// first, and calls [ended] when its output ends.
  void listen(
    void Function(String line) onLine, {
    required void Function() ended,
  }) {
    _onLine = onLine;
    _onEnded = ended;
    final unread = [..._unread];
    _unread.clear();
    unread.forEach(onLine);
    unawaited(_stdoutDone.future.then((_) => _onEnded?.call()));
  }

  void unlisten() {
    _onLine = null;
    _onEnded = null;
  }

  /// Writes [message] to its stdin, closing stdin after it when [last].
  void write(String message, {required bool last}) {
    process.stdin.add(utf8.encode(message));
    if (last) unawaited(process.stdin.close().catchError((Object _) {}));
  }

  void kill() => process.kill(ProcessSignal.sigkill);

  /// Closes its stdin and waits for it to exit, killing it after ten
  /// seconds; deletes its folder. Its exit code.
  Future<int> finish() async {
    unlisten();
    unawaited(process.stdin.close().catchError((Object _) {}));
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        kill();
        return process.exitCode;
      },
    );
    // A child claude left behind can hold its pipes open after it exits.
    await Future.wait([_stdoutDone.future, _stderrDone.future])
        .timeout(const Duration(seconds: 2), onTimeout: () => []);
    await scratch.delete(recursive: true);
    return exitCode;
  }

  /// Ends it at once: kills it and deletes its folder.
  Future<void> end() async {
    kill();
    await finish();
  }
}

/// Which of the driver's flags a Claude Code accepts: one case for each
/// version the driver's walls were checked against.
enum ClaudeCodeFlags {
  /// 2.1.311 and later: every flag in [ClaudeCodeDriver.arguments].
  everyFlag,

  /// 2.1.112, the last release in plain JavaScript, which runs on any Node
  /// (riscv64 among them). It has no `--safe-mode` or `--restricted`; with
  /// the rest, nothing planted in the working directory or its parent
  /// loaded: no CLAUDE.md, skill, agent, command, output style, setting,
  /// hook or `.mcp.json`.
  withoutSafeModeOrRestricted;

  /// The flags [version] accepts, or null for a version the driver was not
  /// checked against.
  static ClaudeCodeFlags? forVersion(String version) =>
      ClaudeCodeDriver.atLeast(version, '2.1.311')
      ? everyFlag
      : ClaudeCodeDriver.atLeast(version, '2.1.112') &&
            !ClaudeCodeDriver.atLeast(version, '2.1.113')
      ? withoutSafeModeOrRestricted
      : null;
}

/// One line of `claude -p --output-format stream-json`, read once here so
/// nothing else reads its keys.
sealed class ClaudeEvent {
  const ClaudeEvent();

  /// [model] is the one asked for, whose context window a result reports.
  static ClaudeEvent parse(String line, {required ModelName model}) {
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
      {'type': 'system', 'subtype': 'compact_boundary'} => const Compacted(),
      {'type': 'system', 'subtype': String()} => const Notice(),
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
        Answered(switch (json) {
          {'stop_reason': 'max_tokens' || 'model_context_window_exceeded'} =>
            CutOffReply(text: text, usage: _usage(json, model)),
          _ => FinishedReply(text: text, usage: _usage(json, model)),
        }),
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

  /// What a result says the run spent, or null when it says nothing
  /// readable. The last of `usage.iterations` is the last model call, whose
  /// input is how full the context was; the run's totals stand in when no
  /// iteration is listed. Claude Code's own context counts: the model read
  /// it.
  static ModelUsage? _usage(Object? result, ModelName model) {
    final last = switch (result) {
      {'usage': {'iterations': [..., final Map<String, Object?> last]}} => last,
      {'usage': final Map<String, Object?> usage} => usage,
      _ => null,
    };
    final window = switch (result) {
      {'modelUsage': final Map<String, Object?> byModel} =>
        switch (byModel[model.value]) {
          {'contextWindow': final int window} => window,
          _ => null,
        },
      _ => null,
    };
    return switch (last) {
      {
        'input_tokens': final int input,
        'cache_read_input_tokens': final int cacheRead,
        'output_tokens': final int output,
      } =>
        ModelUsage(
          input: input,
          cacheRead: cacheRead,
          output: output,
          cacheCreation: switch (last) {
            {'cache_creation_input_tokens': final int created} => created,
            _ => null,
          },
          contextWindow: window,
        ),
      _ => null,
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

/// Claude Code replaced the conversation with a summary of it, so the model
/// no longer reads the turns that were approved. `DISABLE_AUTO_COMPACT`
/// should stop it; this is the check that it did.
final class Compacted extends ClaudeEvent {
  const Compacted();
}

/// A system event other than init, such as a status or 2.1.323's
/// `ui_invalidate` ahead of init: Claude Code's own, never a model turn,
/// so it may come before init.
final class Notice extends ClaudeEvent {
  const Notice();
}

/// Any other event, such as an assistant message or a rate limit notice.
final class Other extends ClaudeEvent {
  const Other();
}
