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
  /// folder, stdin and system prompt, prints [lines], then exits [exit] (or
  /// sleeps first when [hang]).
  String script(List<String> lines, {int exit = 0, bool hang = false}) {
    final out = File('${dir.path}/out.jsonl')
      ..writeAsStringSync(lines.map((l) => '$l\n').join());
    final r = notes.path;
    final script = File('${dir.path}/claude')
      ..writeAsStringSync('''#!/bin/sh
for a in "\$@"; do printf '%s\\0' "\$a"; done > $r/args
env > $r/env
pwd > $r/cwd
ls -A > $r/ls
cat > $r/stdin
prev=
for a in "\$@"; do
  if [ "\$prev" = --system-prompt-file ]; then
    cat "\$a" > $r/system-prompt
    dirname "\$HOME" > $r/scratch
  fi
  prev="\$a"
done
cat ${out.path}
${hang ? 'sleep 30' : ''}
exit $exit
''');
    Process.runSync('chmod', ['+x', script.path]);
    return script.path;
  }

  String noted(String name) => File('${notes.path}/$name').readAsStringSync();

  /// Whether `claude` was started at all.
  bool get ran => File('${notes.path}/args').existsSync();

  /// Starts the driver on [socket] with [claude] for [caller], the test's
  /// own user by default.
  Future<ClaudeCodeDriver> start(
    String claude, {
    UserId? caller,
    Duration limit = const Duration(seconds: 10),
    List<String>? log,
    SocketUserReader? socketUserReader,
  }) => ClaudeCodeDriver.start(
    {seat: token},
    caller: caller ?? me,
    socket: socket,
    claude: claude,
    path: '/usr/bin:/bin',
    limit: limit,
    log: log?.add,
    socketUserReader: socketUserReader,
  );
}

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
