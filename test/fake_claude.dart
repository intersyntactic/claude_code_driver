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
  'result': text,
  ...more,
});

Map<String, Object?> tokens(int input, int cacheRead, int created, int out) => {
  'input_tokens': input,
  'cache_read_input_tokens': cacheRead,
  'cache_creation_input_tokens': created,
  'output_tokens': out,
};

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

  /// The path of a `claude` that notes its arguments, environment, working
  /// folder, system prompt and stdin, prints [lines], then exits [exit] (or
  /// sleeps first when [hang]). Each one started also adds to [starts] and,
  /// once its stdin closes, to [reads].
  String script(List<String> lines, {int exit = 0, bool hang = false}) {
    final out = File('${dir.path}/out.jsonl')
      ..writeAsStringSync(lines.map((l) => '$l\n').join());
    final r = notes.path;
    final script = File('${dir.path}/claude')
      ..writeAsStringSync('''#!/bin/sh
for a in "\$@"; do printf '%s\\0' "\$a"; done > $r/args
env > $r/env
pwd > $r/cwd
pwd -P > $r/real-cwd
ls -A > $r/ls
cp -R "\$CLAUDE_CONFIG_DIR" $r/config
prev=
for a in "\$@"; do
  if [ "\$prev" = --system-prompt-file ]; then
    cat "\$a" > $r/system-prompt
    dirname "\$HOME" > $r/scratch
    echo "start \$\$ \$(dirname "\$HOME") \$(cat "\$a")" >> $r/log
  fi
  prev="\$a"
done
cat > $r/stdin
echo "read \$\$" >> $r/log
cat ${out.path}
${hang ? 'sleep 30' : ''}
exit $exit
''');
    Process.runSync('chmod', ['+x', script.path]);
    return script.path;
  }

  /// The path of a `claude` that, like Claude Code reading stream-json,
  /// answers each line of stdin until stdin closes: it adds to [starts] and
  /// [reads], keeps each line for [messagesTo], prints init before its first
  /// answer, and answers `reply <pid> <n>`. [beforeResult] is printed ahead
  /// of each result; [cutOff] stops each reply at its token limit, and
  /// [error] makes each result an error.
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
n=0
while IFS= read -r line; do
  n=\$((n+1))
  printf '%s\\n' "\$line" >> $r/messages.\$\$
  echo "read \$\$" >> $r/log
  [ \$n -eq 1 ] && printf '%s\\n' '${init([])}'
  ${beforeResult == null ? '' : "printf '%s\\n' '$beforeResult'"}
  printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"reply %s %s"}}}\\n' \$\$ \$n
  printf '{"type":"result","subtype":"success","is_error":$error,"result":"reply %s %s"$more}\\n' \$\$ \$n
done
''');
    Process.runSync('chmod', ['+x', script.path]);
    return script.path;
  }

  /// The messages the `claude` [pid] read, each decoded.
  List<Object?> messagesTo(String pid) => [
    for (final line in File('${notes.path}/messages.$pid').readAsLinesSync())
      jsonDecode(line),
  ];

  String noted(String name) => File('${notes.path}/$name').readAsStringSync();

  /// The text of each turn in the one stream-json user message `claude`
  /// read.
  List<String> get sentTurns =>
      switch (const LineSplitter().convert(noted('stdin'))) {
        [final line] when noted('stdin').endsWith('\n') => switch (jsonDecode(
          line,
        )) {
          {
            'type': 'user',
            'message': {'role': 'user', 'content': final List<Object?> blocks},
          } =>
            [
              for (final block in blocks)
                switch (block) {
                  {'type': 'text', 'text': final String text}
                      when block.length == 2 =>
                    text,
                  _ => throw StateError('not a text block: $block'),
                },
            ],
          final other => throw StateError('not a user message: $other'),
        },
        final lines => throw StateError('not one line: $lines'),
      };

  /// The session `claude` was told to resume, or null.
  String? get resumed {
    final args = noted('args').split('\x00')..removeLast();
    final at = args.indexOf('--resume');
    return at < 0 ? null : args[at + 1];
  }

  /// The entries of the transcript `claude` was told to resume, each
  /// decoded, from where Claude Code looks for it: its config's projects,
  /// in the folder named for its working directory's real path.
  List<Map<String, Object?>> get planted {
    final project = noted('real-cwd')
        .trim()
        .replaceAll(RegExp('[^A-Za-z0-9]'), '-');
    final file = File('${notes.path}/config/projects/$project/$resumed.jsonl');
    return [
      for (final line in file.readAsLinesSync())
        switch (jsonDecode(line)) {
          final Map<String, Object?> entry => entry,
          final other => throw StateError('not an entry: $other'),
        },
    ];
  }

  /// Whether `claude` was started at all.
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
  return (const Refused('no answer'), reported);
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
