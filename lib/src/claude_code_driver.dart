import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show AgentSaid, ModelRequest, ModelTurn, OfferedTool, StopReason, UserSaid;
import 'package:checked_json/checked_json.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

import 'claude_messages.dart';
import 'credential.dart';

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
/// One call is one model turn. Its `request` is read by [requestOf]: the
/// tools offered and the turns so far. The tools are offered through an MCP
/// server the driver answers itself, over `claude`'s own stdin and stdout,
/// and never run: when the model calls them, Claude Code asks the driver's
/// permission, is never answered, and is stopped once the model's message
/// ends, which is returned as [ProposedToolCalls]. The turns are written to
/// `claude`'s stdin as real messages ([messagesOf]), all but the last only
/// appended, one at a time, so the model reads them exactly as given and in
/// order.
/// The `systemPrompt` goes to `--system-prompt-file` as its UTF-8 bytes;
/// the command line is [arguments]. No turn names a model, so the model is
/// only ever the one decided.
///
/// The logbook holds what was given to `claude -p`, not the exact wire to
/// Anthropic: Claude Code adds context of its own.
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
    this._work,
  );

  /// Listens on [socket] for the user [caller] alone, asking the model as
  /// the seats in [signIns]. [claude] is the `claude` executable, by path or
  /// by name on [path], and [flags] the ones it accepts; [limit] is how long
  /// one call may run; [socketUserReader] reads each caller's user from the
  /// kernel, the running kernel's by default. A socket file nothing listens
  /// on is replaced.
  ///
  /// [spares] is how many combinations of sign-in, model, system prompt and
  /// tools are kept warm: after a call, a `claude` for the same four is
  /// started and left waiting, so the next such call skips Claude Code's
  /// startup. None by default. A spare older than [spareLifetime] by
  /// [clock], or one that has exited, is replaced instead of used.
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
    final server = await _bind(socket);
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
      server,
      await Directory.systemTemp.createTemp('claude-code-driver-work'),
    );
    driver._server.listen(driver._serve);
    return driver;
  }

  final Map<ModelSignInName, Credential> _signIns;

  /// The `claude` executable, by path or by name on [_path].
  final String _claude;

  /// The flags [_claude] accepts.
  final ClaudeCodeFlags _flags;

  /// How many combinations of sign-in, model, system prompt and tools keep
  /// a spare, and how long one may wait before it is replaced.
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

  /// Each seat and model's context window, as its latest whole reply said.
  /// Claude Code names the window only in a run's result, so a proposal of
  /// tools, which ends before one, is given the window remembered here.
  final _contextWindows = <(ModelSignInName, ModelName), int>{};

  var _closed = false;

  /// The only variable of the driver's own environment `claude` is given.
  final String _path;

  /// How long one call may run before it is killed.
  final Duration _limit;

  /// Where a failed call's stderr, unreadable lines, alarms and refused
  /// peers go: for whoever runs the driver, not the logbook. Never the token.
  final void Function(String line) _log;

  final SocketUserCheck _socketUserCheck;
  final File _socket;
  final ServerSocket _server;

  /// The working directory of every `claude`, empty and the same for all:
  /// Claude Code writes its path near the start of every request, so one
  /// path for every call keeps the requests' starts alike, which is what
  /// the prompt cache matches on. With every tool off, nothing is written
  /// here.
  final Directory _work;

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
    await Future.wait([for (final claude in ending) claude.end(_log)]);
    await _work.delete(recursive: true);
  }

  Future<void> _serve(Socket socket) async {
    try {
      switch (_socketUserCheck.decide(socket)) {
        case Allowed():
          break;
        case final refused && (NotAllowed() || Unread()):
          _log('refused a peer: $refused');
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
        _write(socket, const Finished(NothingRan('call too large')));
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
        _write(socket, Finished(NothingRan('not a call: ${e.message}')));
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

  /// Every flag but the MCP server's is there to take something away.
  /// `--tools ""` offers the model no built-in tool; `--restricted` removes
  /// the tools that run code or reach the web even if a later Claude Code
  /// reads `--tools ""` differently; `--safe-mode` stops hooks, skills,
  /// plugins and MCP servers the user's settings would load, which
  /// `--setting-sources ""` alone does not, and leaves the SDK server here,
  /// which the driver itself answers. `--permission-prompt-tool stdio` has
  /// Claude Code ask the driver before any offered tool runs, which the driver
  /// never answers. [flags] leaves out the two a Claude Code does not
  /// accept. Never `--bare`: it reads only `ANTHROPIC_API_KEY`, never the
  /// seat.
  ///
  /// The turns go in as stream-json messages: a text prompt is abandoned
  /// when stdin stays empty for 3 s, which a spare's does.
  static List<String> arguments(
    ModelName model,
    ClaudeCodeFlags flags, {
    required String systemPromptFile,
  }) => [
    '-p',
    '--tools',
    '',
    if (flags == ClaudeCodeFlags.everyFlag) ...['--restricted', '--safe-mode'],
    '--strict-mcp-config',
    '--mcp-config',
    jsonEncode({
      'mcpServers': {
        toolServer: {'type': 'sdk', 'name': toolServer},
      },
    }),
    '--permission-prompt-tool',
    'stdio',
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
    systemPromptFile,
  ];

  Future<Outcome<ModelReply>> _ask(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String text, {
    required Report report,
  }) async {
    final credential = _signIns[signIn];
    if (credential == null) return NothingRan('no model sign-in $signIn');
    final ModelRequest request;
    final List<ClaudeMessage> messages;
    try {
      request = requestOf(text);
      messages = messagesOf(request.turns);
    } on FormatException catch (e) {
      return NothingRan('not a request: ${e.message}');
    }
    for (final tool in request.tools) {
      if (tool.name.value.length > longestToolName) {
        return NothingRan(
          'tool ${tool.name} is longer than the $longestToolName characters '
          'Claude Code can offer',
        );
      }
    }

    final key = (
      signIn,
      model,
      systemPrompt,
      jsonEncode([for (final tool in request.tools) tool.toJson()]),
    );
    final call = '$signIn $model';
    final turns = [for (final turn in request.turns) _turnKey(turn)];
    final _Claude claude;
    final List<ClaudeMessage> toWrite;
    if (_continuable(key, request.turns, turns) case (final session, final n)) {
      claude = session;
      toWrite = messagesOf(request.turns.sublist(n));
    } else {
      try {
        claude =
            _takeSpare(key) ??
            await _startClaude(key, credential, request.tools);
      } on ProcessException catch (e) {
        return NothingRan('claude code did not start: ${e.message}');
      }
      if (_spares > 0) unawaited(_keepSpare(key, credential, request.tools));
      toWrite = messages;
    }

    final outcome = await _Conversation(
      claude,
      toWrite,
      {for (final tool in request.tools) offeredName(tool.name.value)},
      report: report,
      model: model,
      contextWindow: _contextWindows[(signIn, model)],
      log: (line) => _log('$call: $line'),
    ).run(_limit);
    if (outcome case Ran<ModelReply>(
      output: FinishedReply(usage: ModelUsage(contextWindow: final window?)) ||
          CutOffReply(usage: ModelUsage(contextWindow: final window?)),
    )) {
      _contextWindows[(signIn, model)] = window;
    }
    // Kept only after a whole reply, which a trajectory's next call repeats
    // as its agent turn.
    if (outcome case Ran<ModelReply>(output: FinishedReply(:final text))
        when _liveSessions > 0 && !_closed && !claude.hasExited) {
      claude.turns = [...turns, _turnKey(AgentSaid(text))];
      claude.idleSince = _clock();
      _idle.add(claude);
      while (_idle.length > _liveSessions) {
        unawaited(_idle.removeAt(0).end(_log));
      }
      return outcome;
    }
    final int exitCode;
    try {
      exitCode = await claude.finish();
    } on FileSystemException catch (e) {
      final why =
          'claude\'s folder ${claude.scratch.path} could not be deleted: '
          '${e.message}';
      _log('$call: $why');
      return StoppedPartway(
        why: why,
        done: switch (outcome) {
          Ran(:final output) => output,
          NothingRan() || StoppedPartway() => null,
        },
      );
    }
    // A proposal of tools ends with `claude` killed, as it must be.
    final proposed =
        outcome is Ran<ModelReply> && outcome.output is ProposedToolCalls;
    if (outcome is! Ran<ModelReply> || (exitCode != 0 && !proposed)) {
      _log('$call: claude code exited $exitCode: ${_clip(claude.stderr)}');
    }
    return outcome;
  }

  /// A turn as the text a session compares it by.
  static String _turnKey(ModelTurn turn) => jsonEncode(turn.toJson());

  /// The idle session [turns] continue, taken from the idle ones, with the
  /// index of the first turn it has not seen; null when none does. A
  /// session continues only a call for its [key] whose turns begin with
  /// exactly the turns it holds, its reply among them, and go on with
  /// nothing but turns the person said. Sessions past their lifetime, or
  /// that exited, are ended on the way.
  (_Claude, int)? _continuable(
    _SpareKey key,
    List<ModelTurn> turns,
    List<String> keys,
  ) {
    final now = _clock();
    for (final session in [..._idle]) {
      final stale = !now.isBefore(session.idleSince.add(_sessionLifetime));
      if (session.hasExited || stale) {
        _idle.remove(session);
        unawaited(session.end(_log));
      }
    }
    for (final session in _idle.reversed) {
      final held = session.turns;
      if (session.key != key || !_begins(keys, held)) continue;
      if (held.length == keys.length) continue;
      if (turns.skip(held.length).any((turn) => turn is! UserSaid)) continue;
      _idle.remove(session);
      return (session, held.length);
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
    unawaited(spare.end(_log));
    return null;
  }

  /// Whether [keys] begins with exactly [held].
  static bool _begins(List<String> keys, List<String> held) {
    if (keys.length < held.length) return false;
    for (var i = 0; i < held.length; i++) {
      if (keys[i] != held[i]) return false;
    }
    return true;
  }

  /// Starts a spare for [key] and leaves it waiting, ending the one it
  /// replaces and the least recently used beyond [_spares].
  Future<void> _keepSpare(
    _SpareKey key,
    Credential credential,
    List<OfferedTool> tools,
  ) async {
    final (signIn, model, _, _) = key;
    final _Claude spare;
    try {
      spare = await _startClaude(key, credential, tools);
    } on ProcessException catch (e) {
      _log('$signIn $model: no spare: claude code did not start: ${e.message}');
      return;
    }
    if (_closed) return spare.end(_log);
    final ending = [?_waiting.remove(key)];
    _waiting[key] = spare;
    while (_waiting.length > _spares) {
      ending.add(_waiting.remove(_waiting.keys.first)!);
    }
    await Future.wait([for (final old in ending) old.end(_log)]);
  }

  /// Starts `claude` for [key]'s model and system prompt, signed in with
  /// [credential], offering [tools], waiting for messages on stdin.
  ///
  /// A fresh home and config per `claude`, so no login, transcript or
  /// setting outlives it or is shared between concurrent calls.
  Future<_Claude> _startClaude(
    _SpareKey key,
    Credential credential,
    List<OfferedTool> tools,
  ) async {
    final (_, model, systemPrompt, _) = key;
    final scratch = await Directory.systemTemp.createTemp('claude-code-call');
    var started = false;
    try {
      final home = await Directory('${scratch.path}/home').create();
      final config = await Directory('${scratch.path}/config').create();
      // A file, not an argument: an argument is readable by every user on
      // the box in `ps`, and Linux caps one at 128 KiB.
      final systemPromptFile = File('${scratch.path}/system-prompt');
      await systemPromptFile.writeAsString(systemPrompt, flush: true);
      final process = await Process.start(
        _claude,
        arguments(model, _flags, systemPromptFile: systemPromptFile.path),
        workingDirectory: _work.path,
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
          // Without it, a Claude Code that offers any tool also sends the
          // model a placeholder tool its init does not list.
          'ENABLE_TOOL_SEARCH': 'false',
          ...switch (credential) {
            ClaudeCodeSetupToken(:final token) => {
              'CLAUDE_CODE_OAUTH_TOKEN': token,
            },
          },
        },
        includeParentEnvironment: false,
      );
      started = true;
      return _Claude(process, scratch, key, _clock(), tools, _log);
    } finally {
      if (!started) await scratch.delete(recursive: true);
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

/// Which spares and sessions a call can use: they share its sign-in, model,
/// system prompt and tools (as their JSON), all fixed when `claude` starts.
typedef _SpareKey = (ModelSignInName, ModelName, String, String);

/// One call's exchange with a `claude`: checks which tools it offers,
/// writes the turns one at a time, and reads its events until the call is
/// settled.
///
/// Whether anything left the machine decides the outcome of a call that
/// fails: until the last message is written, Claude Code has asked the
/// model nothing, so a failure then is [NothingRan]; after it, the request
/// may already have gone, so it is [StoppedPartway].
final class _Conversation {
  _Conversation(
    this.claude,
    this.messages,
    this.offered, {
    required this.report,
    required this.model,
    required this.contextWindow,
    required this.log,
  });

  final _Claude claude;
  final List<ClaudeMessage> messages;

  /// The names the tools are offered under, as the model sees them.
  final Set<String> offered;
  final Report report;
  final ModelName model;

  /// The window a proposal of tools reports, null when none is known yet.
  final int? contextWindow;
  final void Function(String line) log;

  final _settled = Completer<Outcome<ModelReply>>();

  /// The index of the next message to write, whether the last one has been
  /// written, and whether an appended one waits for Claude Code to say so.
  var _next = 0;
  var _asked = false;
  var _waitingForAck = false;

  /// The model's message so far: its text, the calls it is making, keyed by
  /// their block's index, and what it reported spending.
  final _text = StringBuffer();
  final _calls = <int, _CallArriving>{};
  Object? _startUsage;
  int? _output;
  StopReason? _stopReason;

  Future<Outcome<ModelReply>> run(Duration limit) async {
    try {
      return await _run().timeout(limit);
    } on TimeoutException {
      claude.kill();
      return _failed('timed out after ${limit.inSeconds}s');
    } finally {
      claude.unlisten();
    }
  }

  Future<Outcome<ModelReply>> _run() async {
    if (await _checkMcp() case final refused?) return refused;
    claude.listen(_read, ended: () => _settle(_failed('claude code exited')));
    _writeNext();
    return _settled.future;
  }

  /// [why] as the outcome it is, given whether the model was asked yet.
  Outcome<ModelReply> _failed(String why) =>
      _asked ? StoppedPartway(why: why, done: null) : NothingRan(why);

  void _settle(Outcome<ModelReply> outcome) {
    if (!_settled.isCompleted) _settled.complete(outcome);
  }

  void _stop(String why) {
    claude.kill();
    _settle(_failed(why));
  }

  /// Asks Claude Code, before any message, which MCP tools it offers: exactly
  /// the offered ones from the driver's one server, or no model turn runs.
  /// Null when they are.
  Future<Outcome<ModelReply>?> _checkMcp() async {
    // Claude Code lists the driver's server only once it has connected to
    // it, which ends with its asking the server for its tools.
    if (!await claude.toolsListed) {
      return const NothingRan(
        'claude code exited before it asked the driver for its tools',
      );
    }
    // It registers the server only once the answer to that has reached it,
    // so the server may be missing or pending for a moment after.
    final settling = Stopwatch()..start();
    while (true) {
      final status = await claude.control({'subtype': 'mcp_status'});
      switch (status) {
        case null:
          return const NothingRan(
            'claude code did not say which MCP tools it offers',
          );
        case {'mcpServers': []} ||
                {'mcpServers': [{'name': toolServer, 'status': 'pending'}]}
            when settling.elapsed < const Duration(seconds: 5):
          await Future<void>.delayed(const Duration(milliseconds: 20));
          continue;
        case {
          'mcpServers': [
            {
              'name': toolServer,
              'status': 'connected',
              'tools': final List<Object?> tools,
            },
          ],
        }:
          final names = {
            for (final tool in tools)
              if (tool case {'name': final String name}) offeredName(name),
          };
          if (names.length == tools.length && _same(names, offered)) {
            return null;
          }
          return NothingRan(
            'claude code offers MCP tools other than those asked for: '
            '${names.join(' ')}',
          );
        default:
          return NothingRan(
            'claude code offers MCP servers other than the driver\'s: '
            '${_clip(jsonEncode(status))}',
          );
      }
    }
  }

  /// Writes messages until one must be acknowledged first, or the last is
  /// written.
  void _writeNext() {
    while (_next < messages.length) {
      final message = messages[_next];
      final last = _next == messages.length - 1;
      _next++;
      if (last) _asked = true;
      // A live session is continued with user messages only, so counting
      // from this call's first message gives every assistant one its own id.
      claude.write(stdinLine(message, index: _next - 1, last: last));
      if (last) return;
      if (message.role == MessageRole.user) {
        _waitingForAck = true;
        return;
      }
    }
  }

  void _read(String line) {
    if (_settled.isCompleted) return;
    switch (ClaudeEvent.parse(line, model: model)) {
      case Initialised(:final tools) when !_same(tools.toSet(), offered):
        // The last wall: if the flags ever stop taking every built-in tool
        // away, or another tool slips in, no model turn runs.
        final why = 'claude code offered tools: ${tools.join(' ')}';
        if (_asked) log('ALARM: $why, after the turns were written');
        _stop(why);
      case Initialised():
        claude.initialised = true;
      case Unreadable():
        log('unreadable line: ${_clip(line)}');
      case Compacted():
        _stop('claude code summarised the conversation in place of its turns');
      case Notice():
        break;
      case _ when !claude.initialised:
        _stop('claude code did not say which tools it offers');
      case Acknowledged() when _waitingForAck:
        _waitingForAck = false;
        _writeNext();
      case Acknowledged():
        _stop('claude code acknowledged a message it was not waiting on');
      case Other():
        break;
      case _ when !_asked:
        // Anything else before the last message means Claude Code asked the
        // model about a message that was only to be appended: a request
        // the airlock did not decide. `shouldQuery` is undocumented, so
        // every run checks it held.
        _asked = true;
        const why = 'claude code asked the model before every turn was written';
        log('ALARM: $why');
        _stop(why);
      case AssistantSpoke():
        break;
      case MessageStarted(:final usage):
        if (_calls.isNotEmpty) {
          return _stop(
            'the model called tools, and claude code asked the model again',
          );
        }
        _text.clear();
        _calls.clear();
        _startUsage = usage;
        _output = null;
        _stopReason = null;
      case TextArriving(:final text):
        _text.write(text);
        report(ReplyArriving(text));
      case ToolCallStarted(:final index, :final id, :final name, :final input):
        if (!offered.contains(name)) {
          return _stop(
            'the model called $name, which was not offered; claude code answers '
            'that itself and may have asked the model again',
          );
        }
        _calls[index] = _CallArriving(id, name, input);
      case ToolInputArriving(:final index, :final json):
        final arriving = _calls[index];
        if (arriving == null) {
          return _stop(
            'input arrived for a tool call the driver never saw start',
          );
        }
        arriving.json.write(json);
      case MessageDelta(:final stopReason, :final output):
        _stopReason = stopReason ?? _stopReason;
        _output = output ?? _output;
      case MessageStopped() when _calls.isNotEmpty:
        _propose();
      case MessageStopped():
        break;
      case Answered(:final reply):
        _settle(Ran(reply));
      case Unanswered(:final why):
        _stop('claude: $why');
    }
  }

  /// Settles the call with the tools the model's message called, stopping
  /// `claude` first: it waits for a permission that never comes, so it has
  /// asked nothing more.
  void _propose() {
    claude.kill();
    if (_stopReason != StopReason.toolUse) {
      return _settle(
        _failed(
          'the model called tools but stopped for '
          '${_stopReason?.wire ?? 'no reason'}',
        ),
      );
    }
    final calls = <ToolCall>[];
    for (final index in _calls.keys.toList()..sort()) {
      final arriving = _calls[index]!;
      final id = ToolCallId.parse(arriving.id);
      final input = arriving.input();
      if (id == null || input == null) {
        return _settle(
          _failed(
            'the model called ${arriving.name} with an unreadable '
            '${id == null ? 'id' : 'input'}',
          ),
        );
      }
      calls.add(
        ToolCall(
          id: id,
          name: CalledToolName.fromSent(
            arriving.name.substring(offeredPrefix.length),
          ),
          input: input,
        ),
      );
    }
    _settle(
      Ran(
        ProposedToolCalls(
          text: '$_text',
          calls: calls,
          usage: ClaudeEvent.streamUsage(
            _startUsage,
            _output,
            contextWindow: contextWindow,
          ),
        ),
      ),
    );
  }

  static bool _same(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static String _clip(String s) =>
      s.length <= 2000 ? s : '${s.substring(0, 2000)}…';
}

/// A call the model's message is making: its id and name, the input its
/// block began with, and the JSON its input arrives as.
final class _CallArriving {
  _CallArriving(this.id, this.name, this.started);

  final String id;
  final String name;
  final Object? started;
  final json = StringBuffer();

  /// Its input, encoded once, here: as it arrived, or as its block began
  /// when nothing arrived. Null unless it is a JSON object.
  ToolInput? input() {
    final Object? decoded;
    try {
      decoded = json.isEmpty ? started : jsonDecode('$json');
    } on FormatException {
      return null;
    }
    return ToolInput.parse(jsonEncode(decoded));
  }
}

/// A started `claude` and the folder it runs in: a spare until a call
/// takes it, then that call's, and after it a live session if kept.
///
/// It answers the driver's MCP server itself, from its start, so a spare
/// is ready before any call takes it.
final class _Claude {
  _Claude(
    this.process,
    this.scratch,
    this.key,
    this.started,
    this._tools,
    this._log,
  ) : idleSince = started {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_route, onDone: _stdoutEnded);
    process.stderr.transform(utf8.decoder).listen((text) {
      if (_stderr.length < 64 << 10) _stderr.write(text);
    }, onDone: _stderrDone.complete);
    // A write to a `claude` that has exited is its outcome to report, not a
    // failure of the driver's.
    unawaited(process.stdin.done.catchError((Object _) {}));
    unawaited(process.exitCode.then((_) => hasExited = true));
  }

  final Process process;
  final Directory scratch;
  final _SpareKey key;
  final DateTime started;
  final List<OfferedTool> _tools;
  final void Function(String line) _log;
  var hasExited = false;

  /// Whether it has said which tools it offers.
  var initialised = false;

  /// As a live session: the turns it holds, its last reply the last of
  /// them, and since when it has waited.
  List<String> turns = const [];
  DateTime idleSince;

  void Function(String line)? _onLine;
  void Function()? _onEnded;
  final _unread = <String>[];
  final _stdoutDone = Completer<void>();
  final _stderrDone = Completer<void>();
  final _stderr = StringBuffer();

  /// Whether Claude Code asked the driver's server for its tools before its
  /// output ended.
  Future<bool> get toolsListed => _listed.future;
  final _listed = Completer<bool>();

  /// The driver's control requests waiting for Claude Code's response, by id.
  final _pending = <String, Completer<Object?>>{};
  var _requests = 0;

  /// What it has written to stderr, its first 64 KiB.
  String get stderr => _stderr.toString();

  /// Answers the control requests that are Claude Code's dealings with the
  /// driver's MCP server, and the responses to the driver's own; passes
  /// every other line on to the call, or keeps it for the next one.
  /// A permission request is never answered: that is what keeps an offered
  /// tool from running and the model from being asked again.
  void _route(String line) {
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      (_onLine ?? _unread.add)(line);
      return;
    }
    switch (json) {
      case {
        'type': 'control_request',
        'request_id': final String id,
        'request': {'subtype': 'mcp_message', 'message': final Object? message},
      }:
        _answerMcp(id, message);
      case {'type': 'control_request', 'request': {'subtype': 'can_use_tool'}}:
        break;
      case {
        'type': 'control_response',
        'response': {'request_id': final String id} && final response,
      }:
        _pending.remove(id)?.complete(switch (response) {
          {'subtype': 'success', 'response': final Object? body} => body,
          _ => null,
        });
      default:
        (_onLine ?? _unread.add)(line);
    }
  }

  void _answerMcp(String requestId, Object? message) {
    final result = switch (message) {
      {'method': 'initialize', 'params': {'protocolVersion': final String v}} =>
        {
          'protocolVersion': v,
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': toolServer, 'version': '1'},
        },
      {'method': 'tools/list'} => () {
        if (!_listed.isCompleted) _listed.complete(true);
        return {
          'tools': [for (final tool in _tools) tool.toJson().asUncheckedMap()],
        };
      }(),
      {'method': 'tools/call', 'params': {'name': final Object? name}} => () {
        // Claude Code asks this only once its permission is granted, which the
        // driver never grants.
        _log('ALARM: claude code asked the driver to run $name; it did not');
        return {
          'content': [
            {'type': 'text', 'text': 'not run: this driver never runs tools'},
          ],
          'isError': true,
        };
      }(),
      _ => <String, Object?>{},
    };
    _send({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': {
          'mcp_response': {
            'jsonrpc': '2.0',
            'id': switch (message) {
              {'id': final Object id} => id,
              _ => 0,
            },
            'result': result,
          },
        },
      },
    });
  }

  /// Sends Claude Code the control request [request] and returns its
  /// response's body; null when it fails or `claude`'s output ends first.
  Future<Object?> control(Map<String, Object?> request) {
    if (_stdoutDone.isCompleted) return Future.value();
    final id = 'driver-${_requests++}';
    final response = _pending[id] = Completer<Object?>();
    _send({'type': 'control_request', 'request_id': id, 'request': request});
    return response.future;
  }

  void _send(Object message) => write('${jsonEncode(message)}\n');

  void _stdoutEnded() {
    _stdoutDone.complete();
    if (!_listed.isCompleted) _listed.complete(false);
    for (final waiting in _pending.values) {
      waiting.complete();
    }
    _pending.clear();
    _onEnded?.call();
  }

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
    if (_stdoutDone.isCompleted) ended();
  }

  void unlisten() {
    _onLine = null;
    _onEnded = null;
  }

  /// Whether the driver has closed its stdin, after which nothing is
  /// written.
  var _stdinClosed = false;

  /// Writes [line] to its stdin, unless the driver closed it.
  void write(String line) {
    if (!_stdinClosed) process.stdin.add(utf8.encode(line));
  }

  void kill() => process.kill(ProcessSignal.sigkill);

  /// Closes its stdin and waits for it to exit, killing it after ten
  /// seconds; deletes its folder, which throws a [FileSystemException] when
  /// it can't. Its exit code.
  Future<int> finish() async {
    unlisten();
    _stdinClosed = true;
    unawaited(process.stdin.close().catchError((Object _) {}));
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        kill();
        return process.exitCode;
      },
    );
    // A child `claude` left behind can hold its pipes open after it exits.
    await Future.wait([_stdoutDone.future, _stderrDone.future])
        .timeout(const Duration(seconds: 2), onTimeout: () => []);
    await scratch.delete(recursive: true);
    return exitCode;
  }

  /// Ends it at once: kills it and deletes its folder, logging to [log]
  /// when the folder can't be deleted.
  Future<void> end(void Function(String line) log) async {
    kill();
    try {
      await finish();
    } on FileSystemException catch (e) {
      log(
        'claude\'s folder ${scratch.path} could not be deleted: '
        '${e.message}',
      );
    }
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
      {'type': 'stream_event', 'event': final Object? event} => _streamed(
        event,
      ),
      // What an appended message is acknowledged with: a result that spent
      // no time on the API and used no model. Its `num_turns` is no guide:
      // 2.1.326 says 0, 2.1.112 counts the messages so far.
      {
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'duration_api_ms': 0,
        'modelUsage': final Object? used,
      }
          when JsonObject.parse(used)?.asUncheckedMap().isEmpty ?? false =>
        const Acknowledged(),
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
      {'type': 'assistant'} => const AssistantSpoke(),
      _ when JsonObject.parse(json) != null => const Other(),
      _ => const Unreadable(),
    };
  }

  static ClaudeEvent _streamed(Object? event) => switch (event) {
    {'type': 'message_start', 'message': {'usage': final Object? usage}} =>
      MessageStarted(usage),
    {'type': 'message_start'} => const MessageStarted(null),
    {
      'type': 'content_block_start',
      'index': final int index,
      'content_block': {
        'type': 'tool_use',
        'id': final String id,
        'name': final String name,
        'input': final Object? input,
      },
    } =>
      ToolCallStarted(index: index, id: id, name: name, input: input),
    {
      'type': 'content_block_delta',
      'delta': {'type': 'text_delta', 'text': final String text},
    } =>
      TextArriving(text),
    {
      'type': 'content_block_delta',
      'index': final int index,
      'delta': {'type': 'input_json_delta', 'partial_json': final String json},
    } =>
      ToolInputArriving(index: index, json: json),
    {'type': 'message_delta'} => MessageDelta(
      stopReason: switch (event) {
        {'delta': {'stop_reason': final String reason}} => StopReason.parse(
          reason,
        ),
        _ => null,
      },
      output: switch (event) {
        {'usage': {'output_tokens': final int output}} => output,
        _ => null,
      },
    ),
    {'type': 'message_stop'} => const MessageStopped(),
    _ => const Other(),
  };

  /// What one streamed model message spent: [start] is the usage its start
  /// reported, [output] its tokens out as its end reported them, and
  /// [contextWindow] the window known from elsewhere, since the stream does
  /// not say it. Null when they say nothing readable.
  static ModelUsage? streamUsage(
    Object? start,
    int? output, {
    int? contextWindow,
  }) => switch (start) {
    {
      'input_tokens': final int input,
      'cache_read_input_tokens': final int cacheRead,
      'output_tokens': final int started,
    } =>
      ModelUsage(
        input: input,
        cacheRead: cacheRead,
        output: output ?? started,
        cacheCreation: switch (start) {
          {'cache_creation_input_tokens': final int created} => created,
          _ => null,
        },
        contextWindow: contextWindow,
      ),
    _ => null,
  };

  /// What a result says the run spent, or null when it says nothing
  /// readable. The last of `usage.iterations` is the last model call, whose
  /// input is how full the context was; the run's totals stand in when no
  /// iteration is listed. Claude Code's own context counts: the model read
  /// it.
  static ModelUsage? _usage(Object? result, ModelName model) {
    final last = switch (result) {
      {'usage': {'iterations': [..., final Object? last]}}
          when JsonObject.parse(last) != null =>
        last,
      {'usage': final Object? usage} => usage,
      _ => null,
    };
    final window = switch (result) {
      {'modelUsage': final Object? byModel} => switch (JsonObject.parse(byModel)
          ?.asUncheckedMap()[model.value]) {
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

/// Claude Code started and offers [tools]: exactly the offered ones.
/// An init that lists no tools field reads as offering one, `?`, so a
/// changed format fails closed.
final class Initialised extends ClaudeEvent {
  const Initialised(this.tools);
  final List<String> tools;
}

/// Claude Code appended a message without asking the model anything.
final class Acknowledged extends ClaudeEvent {
  const Acknowledged();
}

/// A model message began; [usage] is what its start says it spent.
final class MessageStarted extends ClaudeEvent {
  const MessageStarted(this.usage);
  final Object? usage;
}

/// A piece of the reply's text as it streams.
final class TextArriving extends ClaudeEvent {
  const TextArriving(this.text);
  final String text;
}

/// The model began calling the tool [name] as call [id], in the message's
/// block [index], its input starting as [input].
final class ToolCallStarted extends ClaudeEvent {
  const ToolCallStarted({
    required this.index,
    required this.id,
    required this.name,
    required this.input,
  });
  final int index;
  final String id;
  final String name;
  final Object? input;
}

/// A piece of the JSON input of the call in block [index].
final class ToolInputArriving extends ClaudeEvent {
  const ToolInputArriving({required this.index, required this.json});
  final int index;
  final String json;
}

/// The end of a model message: why it stopped and its tokens out, each
/// when said.
final class MessageDelta extends ClaudeEvent {
  const MessageDelta({required this.stopReason, required this.output});
  final StopReason? stopReason;
  final int? output;
}

/// A model message is complete.
final class MessageStopped extends ClaudeEvent {
  const MessageStopped();
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

/// An assistant message as Claude Code reports it: the model was asked.
final class AssistantSpoke extends ClaudeEvent {
  const AssistantSpoke();
}

/// Any other event, such as a rate limit notice.
final class Other extends ClaudeEvent {
  const Other();
}
