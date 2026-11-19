import 'dart:convert';
import 'dart:io';

import 'package:is_claude_code_driver/is_claude_code_driver.dart';
import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

final seat = ModelSignInName.parse('nick-claude-team')!;
final haiku = ModelName.parse('claude-haiku-5-5')!;
final token = ClaudeCodeSetupToken.parse('sk-ant-oat01-${'a' * 95}')!;

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

String result(String text, {bool error = false}) => jsonEncode({
  'type': 'result',
  'subtype': 'success',
  'is_error': error,
  'result': text,
});

void main() {
  late Directory dir;
  late Directory record;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ccd-test');
    record = await Directory('${dir.path}/record').create();
  });
  tearDown(() => dir.delete(recursive: true));

  /// A stand-in for `claude` that writes down how it was started, prints
  /// [lines], then exits [exit] (or sleeps when [hang]).
  String fakeClaude(List<String> lines, {int exit = 0, bool hang = false}) {
    final out = File('${dir.path}/out.jsonl')
      ..writeAsStringSync(lines.map((l) => '$l\n').join());
    final r = record.path;
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

  String recorded(String name) =>
      File('${record.path}/$name').readAsStringSync();

  Future<(Outcome<ModelReply>, List<Progress>)> ask(
    String claude, {
    Duration limit = const Duration(seconds: 10),
    List<String>? log,
    String systemPrompt = 'You are Cam.',
    String request = 'hello',
  }) async {
    final reported = <Progress>[];
    final outcome = await ClaudeCodeDriver(
      {seat: token},
      claude: claude,
      path: '/usr/bin:/bin',
      limit: limit,
      log: log?.add,
    ).askTheModel(seat, haiku, systemPrompt, request, report: reported.add);
    return (outcome, reported);
  }

  test('hands claude the exact UTF-8 bytes, trimming nothing', () async {
    // Whitespace at both ends, CRLF, a BOM, a NUL and non-ASCII: anything a
    // trim or re-encode would change.
    const systemPrompt = '﻿\n  You are Cam.\r\n\t\x00 “é” \u{1F600}  \n\n';
    const request = '  \r\nline\n\n  trailing  \n';
    await ask(
      fakeClaude([init([]), result('ok')]),
      systemPrompt: systemPrompt,
      request: request,
    );
    expect(
      File('${record.path}/system-prompt').readAsBytesSync(),
      utf8.encode(systemPrompt),
    );
    expect(
      File('${record.path}/stdin').readAsBytesSync(),
      utf8.encode(request),
    );
  });

  test('flattens an input array into one line per turn', () async {
    // Content exactly as sent: CRLF, a newline, padding and non-ASCII.
    await ask(
      fakeClaude([init([]), result('ok')]),
      request: jsonEncode([
        {'role': 'user', 'content': 'hey are you there'},
        {'role': 'assistant', 'content': '  yep,\r\nhere “é” \u{1F600} '},
        {'role': 'user', 'content': 'two\nlines'},
      ]),
    );
    expect(
      File('${record.path}/stdin').readAsBytesSync(),
      utf8.encode(
        'User: hey are you there\n'
        'Agent:   yep,\r\nhere “é” \u{1F600} \n'
        'User: two\nlines',
      ),
    );
  });

  test('refuses a JSON request that is not an array of turns', () async {
    final claude = fakeClaude([init([]), result('ok')]);
    for (final (request, why) in [
      ('[]', 'not a non-empty array of turns'),
      ('{"role":"user","content":"hi"}', 'not a non-empty array of turns'),
      ('"hi"', 'not a non-empty array of turns'),
      (
        '[{"role":"system","content":"be Cam"}]',
        'turn 0: role is not user or assistant',
      ),
      (
        '[{"role":"user","content":"hi"},{"role":"user"}]',
        'turn 1 is not exactly a role and content',
      ),
      (
        '[{"role":"user","content":["hi"]}]',
        'turn 0 is not exactly a role and content',
      ),
      (
        '[{"role":"user","content":"hi","model":"gpt-6"}]',
        'turn 0 is not exactly a role and content',
      ),
    ]) {
      final (outcome, _) = await ask(claude, request: request);
      expect((outcome as Refused).why, 'not a request: $why', reason: request);
    }
    expect(File('${record.path}/args').existsSync(), isFalse);
  });

  test('streams the reply and gives the whole of it', () async {
    final (outcome, reported) = await ask(
      fakeClaude([
        init([]),
        delta('Hel'),
        jsonEncode({'type': 'rate_limit_event'}),
        delta('lo.'),
        result('Hello.'),
      ]),
    );
    expect((outcome as Ran<ModelReply>).output.text, 'Hello.');
    expect(
      [for (final p in reported) (p as ReplyArriving).text],
      ['Hel', 'lo.'],
    );
  });

  test('runs claude with every tool off, and nothing else of ours', () async {
    const request = 'line one\nline two — “quoted” \u{1F600}\n';
    await ask(fakeClaude([init([]), result('ok')]), request: request);

    final args = recorded('args').split('\x00')..removeLast();
    expect(args, ClaudeCodeDriver.arguments(haiku));
    expect(args.sublist(0, 4), ['-p', '--tools', '', '--restricted']);
    for (final flag in [
      '--safe-mode',
      '--strict-mcp-config',
      '--disable-slash-commands',
      '--no-session-persistence',
    ]) {
      expect(args, contains(flag));
    }
    expect(args, isNot(contains('--bare')));
    expect(args[args.indexOf('--setting-sources') + 1], '');
    expect(args[args.indexOf('--model') + 1], 'claude-haiku-5-5');
    expect(args, isNot(contains('You are Cam.')));

    expect(recorded('stdin'), request);
    expect(recorded('system-prompt'), 'You are Cam.');

    final env =
        {
            for (final line in const LineSplitter().convert(recorded('env')))
              line.substring(0, line.indexOf('=')): line.substring(
                line.indexOf('=') + 1,
              ),
          }
          ..remove('PWD')
          ..remove('SHLVL')
          ..remove('_');
    final scratch = recorded('scratch').trim();
    expect(env, {
      'PATH': '/usr/bin:/bin',
      'HOME': '$scratch/home',
      'CLAUDE_CONFIG_DIR': '$scratch/config',
      'CLAUDE_CODE_OAUTH_TOKEN': token.token,
    });
    expect(recorded('cwd').trim(), endsWith('$scratch/work'));
    expect(recorded('ls'), isEmpty);
    expect(Directory(scratch).existsSync(), isFalse);
  });

  test('refuses, before any model turn, when claude offers a tool', () async {
    final (outcome, reported) = await ask(
      fakeClaude([
        init(['Bash', 'Read']),
        delta('ran it'),
        result('done'),
      ]),
    );
    expect((outcome as Refused).why, 'claude offered tools: Bash Read');
    expect(reported, isEmpty);
  });

  test('refuses an init that does not list its tools', () async {
    final (outcome, _) = await ask(
      fakeClaude([
        jsonEncode({'type': 'system', 'subtype': 'init'}),
        result('ok'),
      ]),
    );
    expect((outcome as Refused).why, 'claude offered tools: ?');
  });

  test('refuses a reply that arrives before claude says its tools', () async {
    final (outcome, reported) = await ask(
      fakeClaude([delta('early'), init([]), result('ok')]),
    );
    expect((outcome as Refused).why, contains('did not say which tools'));
    expect(reported, isEmpty);
  });

  test('says why when claude reports an error', () async {
    // What claude 2.1.311 printed, signed in to nothing.
    final (outcome, _) = await ask(
      fakeClaude([
        init([]),
        result('Not logged in · Please run /login', error: true),
      ], exit: 1),
    );
    expect(
      (outcome as Refused).why,
      'claude: Not logged in · Please run /login',
    );
  });

  test('refuses when claude exits without a result', () async {
    final log = <String>[];
    final (outcome, _) = await ask(fakeClaude([init([])], exit: 3), log: log);
    expect((outcome as Refused).why, 'claude exited 3 without a result');
    expect(log.single, contains('exited 3'));
    expect(log.single, isNot(contains(token.token)));
  });

  test('kills a call that runs past its limit', () async {
    final (outcome, _) = await ask(
      fakeClaude([init([])], hang: true),
      limit: const Duration(milliseconds: 500),
    );
    expect((outcome as Refused).why, 'timed out after 0s');
  });

  test('refuses an unknown sign-in without starting claude', () async {
    final outcome =
        await ClaudeCodeDriver({
          seat: token,
        }, claude: fakeClaude([])).askTheModel(
          ModelSignInName.parse('someone-else')!,
          haiku,
          '',
          'hi',
          report: (_) {},
        );
    expect((outcome as Refused).why, 'no model sign-in someone-else');
    expect(File('${record.path}/args').existsSync(), isFalse);
  });

  test('refuses when claude cannot be started', () async {
    final (outcome, _) = await ask('${dir.path}/no-such-claude');
    expect((outcome as Refused).why, startsWith('claude did not start'));
  });

  test('compares versions', () {
    expect(ClaudeCodeDriver.atLeast('2.1.326', '2.1.311'), isTrue);
    expect(ClaudeCodeDriver.atLeast('2.1.311', '2.1.311'), isTrue);
    expect(ClaudeCodeDriver.atLeast('2.1.99', '2.1.311'), isFalse);
    expect(ClaudeCodeDriver.atLeast('3.0.0', '2.1.311'), isTrue);
  });
}
