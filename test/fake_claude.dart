import 'dart:convert';
import 'dart:io';

import 'package:is_claude_code_driver/is_claude_code_driver.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

final seat = ModelSignInName.parse('nick-claude-team')!;
final haiku = ModelName.parse('claude-haiku-5-5')!;
final token = ClaudeCodeSetupToken.parse('sk-ant-oat01-${'a' * 95}')!;
final me = UserId.parse(
  int.parse((Process.runSync('id', ['-u']).stdout as String).trim()),
)!;

String init(List<String> tools) => jsonEncode({
  'type': 'system',
  'subtype': 'init',
  'tools': tools,
  'mcp_servers': <Object?>[],
});

String delta(String text) => jsonEncode({
  'type': 'stream_event',
  'event': {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': text},
  },
});

String result(
  String text, {
  bool error = false,
  Map<String, Object?> more = const {},
}) => jsonEncode({
  'type': 'result',
  'subtype': 'success',
  'is_error': error,
  'duration_api_ms': 812,
  'result': text,
  ...more,
});

Map<String, Object?> tokens(int input, int cacheRead, int created, int out) => {
  'input_tokens': input,
  'cache_read_input_tokens': cacheRead,
  'cache_creation_input_tokens': created,
  'output_tokens': out,
};

/// A stream event of the model's message.
String streamed(Map<String, Object?> event) =>
    jsonEncode({'type': 'stream_event', 'event': event});

/// The stream of one model message that says [text] and calls [calls],
/// each an id, a name as the model calls it, and its input, ending for
/// [stop].
List<String> proposing(
  String text,
  List<(String, String, Map<String, Object?>)> calls, {
  String stop = 'tool_use',
}) => [
  streamed({
    'type': 'message_start',
    'message': {
      'id': 'msg_1',
      'usage': {...tokens(7, 300, 40, 1)},
    },
  }),
  if (text.isNotEmpty) delta(text),
  for (final (i, (id, name, input)) in calls.indexed) ...[
    streamed({
      'type': 'content_block_start',
      'index': i + 1,
      'content_block': {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': <String, Object?>{},
      },
    }),
    streamed({
      'type': 'content_block_delta',
      'index': i + 1,
      'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(input)},
    }),
  ],
  streamed({
    'type': 'message_delta',
    'delta': {'stop_reason': stop},
    'usage': {'output_tokens': 25},
  }),
  streamed({'type': 'message_stop'}),
];

/// What Claude Code acknowledges an appended message with, as 2.1.112 does:
/// its `num_turns` counts the messages so far, not the model's turns.
final ack = jsonEncode({
  'type': 'result',
  'subtype': 'success',
  'is_error': false,
  'duration_api_ms': 0,
  'num_turns': 2,
  'result': '',
  'modelUsage': <String, Object?>{},
});

/// A folder holding the driver's socket and a stand-in for `claude` that
/// writes down how it was started into [notes].
final class FakeClaude {
  FakeClaude._(this.dir, this.notes);

  /// Under /tmp, not the system temp folder: a Unix socket's path is short
  /// on macOS.
  static Future<FakeClaude> create() async {
    final dir = await Directory('/tmp').createTemp('ccd');
    return FakeClaude._(dir, await Directory('${dir.path}/notes').create());
  }

  final Directory dir;
  final Directory notes;

  File get socket => File('${dir.path}/s');

  Future<void> delete() => dir.delete(recursive: true);

  /// The shell both stand-ins begin with: like Claude Code, it asks the
  /// driver's MCP server for its tools at once, and defines `control`,
  /// which answers a line of stdin that is not the message the model
  /// answers and says whether it did: `mcp_status` with [mcpTools], an
  /// appended user message with init (listing [initTools]) the first time
  /// and an acknowledgement ([onAppend] in its place when given, as a
  /// Claude Code that asked the model anyway), and anything else of the
  /// driver's with nothing.
  String _prelude(
    List<String> mcpTools,
    List<String> initTools, {
    List<String>? onAppend,
  }) {
    final status = jsonEncode([
      for (final name in mcpTools) {'name': name},
    ]);
    return '''
printf '%s\\n' '{"type":"control_request","request_id":"fake-1","request":{"subtype":"mcp_message","server_name":"tools","message":{"method":"tools/list","jsonrpc":"2.0","id":1}}}'
inited=
control() {
  case "\$1" in
    *'"subtype":"mcp_status"'*)
      id=\$(printf '%s' "\$1" | sed 's/.*"request_id":"\\([^"]*\\)".*/\\1/')
      printf '%s%s%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"' "\$id" '","response":{"mcpServers":[{"name":"tools","status":"connected","tools":$status}]}}}'
      return 0;;
    '{"type":"user","shouldQuery":false'*)
      [ -z "\$inited" ] && { printf '%s\\n' '${init(initTools)}'; inited=1; }
      ${[
      for (final l in onAppend ?? [ack]) "printf '%s\\n' '$l'",
    ].join('\n      ')}
      return 0;;
    '{"type":"user"'*) return 1;;
  esac
  return 0
}
''';
  }

  /// The path of a `claude` that notes its arguments, environment, working
  /// folder, system prompt and stdin, and, once the message the model
  /// answers arrives, prints [lines], then exits [exit] (or sleeps first
  /// when [hang]). Each one started also adds to [starts] and, once it
  /// reads that message, to [reads]. Its MCP server offers [mcpTools] by
  /// their bare names; [initTools] are the tools its init lists for an
  /// appended message, the offered ones by default. [onAppend] is printed
  /// for an appended message in place of its acknowledgement.
  String script(
    List<String> lines, {
    int exit = 0,
    bool hang = false,
    List<String> mcpTools = const [],
    List<String>? initTools,
    List<String>? onAppend,
  }) {
    final out = File('${dir.path}/out.jsonl')
      ..writeAsStringSync(lines.map((l) => '$l\n').join());
    final r = notes.path;
    final script = File('${dir.path}/claude')
      ..writeAsStringSync('''#!/bin/sh
for a in "\$@"; do printf '%s\\0' "\$a"; done > $r/args
env > $r/env
pwd > $r/cwd
ls -A > $r/ls
prev=
for a in "\$@"; do
  if [ "\$prev" = --system-prompt-file ]; then
    cat "\$a" > $r/system-prompt
    dirname "\$HOME" > $r/scratch
    echo "start \$\$ \$(dirname "\$HOME") \$(cat "\$a")" >> $r/log
  fi
  prev="\$a"
done
${_prelude(mcpTools, initTools ?? [for (final t in mcpTools) 'mcp__tools__$t'], onAppend: onAppend)}
while IFS= read -r line; do
  printf '%s\\n' "\$line" >> $r/stdin
  control "\$line" && continue
  echo "read \$\$" >> $r/log
  cat ${out.path}
  ${hang ? 'sleep 30' : ''}
  exit $exit
done
exit $exit
''');
    Process.runSync('chmod', ['+x', script.path]);
    return script.path;
  }

  /// The path of a `claude` that, like Claude Code reading stream-json,
  /// answers each message the model answers until stdin closes: it adds to
  /// [starts] and [reads], keeps each line for [messagesTo], prints init
  /// before its first answer, and answers `reply <pid> <n>`.
  /// [beforeResult] is printed ahead of each result; [cutOff] stops each
  /// reply at its token limit, and [error] makes each result an error.
  String sessionScript({
    String? beforeResult,
    bool cutOff = false,
    bool error = false,
  }) {
    final r = notes.path;
    final more = cutOff ? ',"stop_reason":"max_tokens"' : '';
    final script = File('${dir.path}/claude-session')
      ..writeAsStringSync('''#!/bin/sh
prev=
for a in "\$@"; do
  if [ "\$prev" = --system-prompt-file ]; then
    echo "start \$\$ \$(dirname "\$HOME") \$(cat "\$a")" >> $r/log
  fi
  prev="\$a"
done
${_prelude(const [], const [])}
n=0
while IFS= read -r line; do
  printf '%s\\n' "\$line" >> $r/messages.\$\$
  control "\$line" && continue
  n=\$((n+1))
  echo "read \$\$" >> $r/log
  [ -z "\$inited" ] && { printf '%s\\n' '${init([])}'; inited=1; }
  ${beforeResult == null ? '' : "printf '%s\\n' '$beforeResult'"}
  printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"reply %s %s"}}}\\n' \$\$ \$n
  printf '{"type":"result","subtype":"success","is_error":$error,"duration_api_ms":5,"result":"reply %s %s"$more}\\n' \$\$ \$n
done
''');
    Process.runSync('chmod', ['+x', script.path]);
    return script.path;
  }

  /// The messages the `claude` [pid] was written, each decoded, leaving
  /// out the driver's dealings with its MCP server and its control
  /// requests.
  List<Map<String, Object?>> messagesTo(String pid) =>
      _messages(File('${notes.path}/messages.$pid'));

  static List<Map<String, Object?>> _messages(File file) => [
    for (final line in file.readAsLinesSync())
      if (jsonDecode(line) case final Map<String, Object?> m
          when m['type'] == 'user' || m['type'] == 'assistant')
        m,
  ];

  String noted(String name) => File('${notes.path}/$name').readAsStringSync();

  /// Every line `claude` read, each decoded: the driver's control messages
  /// and the messages of the conversation.
  List<Map<String, Object?>> get read => [
    for (final line in const LineSplitter().convert(noted('stdin')))
      switch (jsonDecode(line)) {
        final Map<String, Object?> m => m,
        final other => throw StateError('not an object: $other'),
      },
  ];

  /// The messages of the conversation `claude` was written, in order.
  List<Map<String, Object?>> get sent => _messages(File('${notes.path}/stdin'));

  /// The text of each block of the message the model answers: the last one
  /// written.
  List<String> get sentTurns => switch (sent.last) {
    {
              'type': 'user',
              'message': {
                'role': 'user',
                'content': final List<Object?> blocks,
              },
            } &&
            final line
        when !line.containsKey('shouldQuery') =>
      [
        for (final block in blocks)
          switch (block) {
            {'type': 'text', 'text': final String text}
                when block.length == 2 =>
              text,
            _ => throw StateError('not a text block: $block'),
          },
      ],
    final other => throw StateError('not the message answered: $other'),
  };

  /// How each written message reads: its role, whether it was only
  /// appended, and its content. Lists, not records, so a matcher compares
  /// what is inside them.
  List<List<Object?>> get conversation => [
    for (final m in sent)
      switch (m) {
        {
          'type': final String type,
          'message': {'role': final String role, 'content': final content},
        }
            when type == role =>
          [role, m['shouldQuery'] == false, content],
        _ => throw StateError('not a message: $m'),
      },
  ];

  bool get ran => File('${notes.path}/args').existsSync();

  List<String> get _log {
    final log = File('${notes.path}/log');
    return log.existsSync() ? log.readAsLinesSync() : [];
  }

  /// Each `claude` started, in order: its process id, its folder, and the
  /// system prompt it was given.
  List<({String pid, String scratch, String systemPrompt})> get starts => [
    for (final line in _log)
      if (line.split(' ') case ['start', final pid, final scratch, ...final p])
        (pid: pid, scratch: scratch, systemPrompt: p.join(' ')),
  ];

  /// The process id of each `claude` that read its message, in order.
  List<String> get reads => [
    for (final line in _log)
      if (line.split(' ') case ['read', final pid]) pid,
  ];

  /// Each `claude` still running that has not read a message: the spares.
  List<({String pid, String scratch, String systemPrompt})> get waiting => [
    for (final s in starts)
      if (!reads.contains(s.pid) && alive(s.pid)) s,
  ];

  /// Waits until [done] holds, failing the test after five seconds.
  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) throw StateError('never happened');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Starts the driver on [socket] with [claude] for [caller], the test's
  /// own user by default.
  Future<ClaudeCodeDriver> start(
    String claude, {
    UserId? caller,
    ClaudeCodeFlags flags = ClaudeCodeFlags.everyFlag,
    Duration limit = const Duration(seconds: 10),
    int spares = 0,
    Duration spareLifetime = const Duration(minutes: 30),
    int liveSessions = 0,
    Duration sessionLifetime = const Duration(minutes: 30),
    DateTime Function() clock = DateTime.now,
    List<String>? log,
    SocketUserReader? socketUserReader,
  }) => ClaudeCodeDriver.start(
    {seat: token},
    caller: caller ?? me,
    socket: socket,
    flags: flags,
    claude: claude,
    path: '/usr/bin:/bin',
    limit: limit,
    spares: spares,
    spareLifetime: spareLifetime,
    liveSessions: liveSessions,
    sessionLifetime: sessionLifetime,
    clock: clock,
    log: log?.add,
    socketUserReader: socketUserReader,
  );
}

/// Whether the process [pid] still runs.
bool alive(String pid) => Process.runSync('kill', ['-0', pid]).exitCode == 0;

/// One call to the driver at [socket] as the wire carries it: the outcome,
/// and what was reported on the way.
Future<(Outcome<ModelReply>, List<Progress>)> call(
  File socket, {
  ModelSignInName? signIn,
  ModelName? model,
  String systemPrompt = 'You are Cam.',
  String request = '[{"role":"user","content":"hello"}]',
}) async {
  final reported = <Progress>[];
  final lines = await rawCall(
    socket,
    jsonEncode(
      encodeModelCall(signIn ?? seat, model ?? haiku, systemPrompt, request),
    ),
  );
  for (final line in const LineSplitter().convert(lines)) {
    switch (decodeProgramMessage(jsonDecode(line), decodeModelReply)) {
      case Reported(:final progress):
        reported.add(progress);
      case Finished(:final outcome):
        return (outcome, reported);
    }
  }
  return (const NothingRan('no answer'), reported);
}

/// What the driver at [socket] answers [call] with, or '' when it hangs up.
Future<String> rawCall(File socket, String call) async {
  try {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(utf8.encode(call));
    await s.close();
    return await utf8.decoder.bind(s).join();
  } on SocketException {
    return '';
  }
}
