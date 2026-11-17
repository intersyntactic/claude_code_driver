import 'dart:convert';
import 'dart:io';

import 'package:is_claude_code_driver/service.dart';
import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

/// Streams the request back a word at a time, and refuses `refuse`.
final class Echo implements AsksTheModel {
  final calls = <(ModelSignInName, ModelName, String, String)>[];

  @override
  Future<Outcome<ModelReply>> askTheModel(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String request, {
    required Report report,
  }) async {
    calls.add((signIn, model, systemPrompt, request));
    if (request == 'refuse') return const Refused('claude: no');
    for (final word in request.split(' ')) {
      report(ReplyArriving(word));
    }
    return Ran(ModelReply(request));
  }
}

final me = int.parse((Process.runSync('id', ['-u']).stdout as String).trim());
final seat = ModelSignInName.parse('nick-claude-team')!;
final haiku = ModelName.parse('claude-haiku-5-5')!;

void main() {
  late Directory dir;
  late File socket;
  late Echo driver;

  setUp(() async {
    // A Unix socket's path is short on macOS, so not under the test's own
    // temp directory.
    dir = await Directory('/tmp').createTemp('ccd');
    socket = File('${dir.path}/s');
    driver = Echo();
  });
  tearDown(() => dir.delete(recursive: true));

  Future<String> raw(String call) async {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(utf8.encode(call));
    await s.close();
    return (await utf8.decoder.bind(s).join()).trim();
  }

  test('asks for its caller, streaming the reply back', () async {
    final service = await ClaudeCodeDriverService.start(driver, me, socket);
    addTearDown(service.close);
    final pieces = <String>[];
    final out = await ClaudeCodeDriverSocket(socket).askTheModel(
      seat,
      haiku,
      'You are Cam.',
      'hello there you',
      report: (p) => pieces.add((p as ReplyArriving).text),
    );
    expect((out as Ran<ModelReply>).output.text, 'hello there you');
    expect(pieces, ['hello', 'there', 'you']);
    expect(driver.calls.single, (
      seat,
      haiku,
      'You are Cam.',
      'hello there you',
    ));
  });

  test('carries a refusal back across the socket', () async {
    final service = await ClaudeCodeDriverService.start(driver, me, socket);
    addTearDown(service.close);
    final out = await ClaudeCodeDriverSocket(socket)
        .askTheModel(seat, haiku, '', 'refuse', report: (_) {});
    expect((out as Refused).why, 'claude: no');
  });

  test('answers the probe {} without asking the model', () async {
    final service = await ClaudeCodeDriverService.start(driver, me, socket);
    addTearDown(service.close);
    expect(
      await raw('{}'),
      '{"kind":"finished","outcome":{"kind":"refused",'
      '"why":"not a call: needs signIn, model, systemPrompt and request"}}',
    );
    expect(driver.calls, isEmpty);
  });

  test('refuses a sign-in that is not a name', () async {
    final service = await ClaudeCodeDriverService.start(driver, me, socket);
    addTearDown(service.close);
    expect(
      await raw(
        '{"signIn":"Nick!","model":"m","systemPrompt":"","request":"x"}',
      ),
      contains('not a call: signIn: not a model sign-in'),
    );
    expect(driver.calls, isEmpty);
  });

  test('closes on any other user, unanswered', () async {
    final service = await ClaudeCodeDriverService.start(driver, me + 1, socket);
    addTearDown(service.close);
    final out = await ClaudeCodeDriverSocket(socket)
        .askTheModel(seat, haiku, '', 'hello', report: (_) {});
    // The service may hang up before the call is even written, so the
    // client's words vary; that it is refused and never asked does not.
    expect((out as Refused).why, startsWith('claude code driver: '));
    expect(driver.calls, isEmpty);
  });

  test('will not start over a socket something listens on', () async {
    final service = await ClaudeCodeDriverService.start(driver, me, socket);
    addTearDown(service.close);
    expect(
      () => ClaudeCodeDriverService.start(driver, me, socket),
      throwsStateError,
    );
  });
}
