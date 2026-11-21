import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_claude_code_driver/service.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_peer_user_admission/is_peer_user_admission.dart';
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
    return Ran(FinishedReply(text: request));
  }
}

final me = UserId.parse(
  int.parse((Process.runSync('id', ['-u']).stdout as String).trim()),
)!;
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

  test('a driver the check refuses never sees the call', () async {
    final service = await ClaudeCodeDriverService.start(driver, me, socket);
    addTearDown(service.close);
    final checked = <Socket>[];
    final out = await ClaudeCodeDriverSocket(
      socket,
      checkDriver: (s) async {
        checked.add(s);
        return 'not release 3';
      },
    ).askTheModel(seat, haiku, '', 'hello', report: (_) {});
    expect((out as Refused).why, 'claude code driver: not release 3');
    expect(checked, hasLength(1));
    expect(driver.calls, isEmpty);
  });

  test('a driver the check passes is asked as usual', () async {
    final service = await ClaudeCodeDriverService.start(driver, me, socket);
    addTearDown(service.close);
    final out = await ClaudeCodeDriverSocket(
      socket,
      checkDriver: (_) async => null,
    ).askTheModel(seat, haiku, '', 'hello', report: (_) {});
    expect((out as Ran<ModelReply>).output.text, 'hello');
    expect(driver.calls, hasLength(1));
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
      '"why":"not a call: modelCall.signIn: not a string"}}',
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
      contains('not a call: modelCall.signIn: not a model sign-in'),
    );
    expect(driver.calls, isEmpty);
  });

  test('closes on any other user, unanswered', () async {
    final service = await ClaudeCodeDriverService.start(
      driver,
      UserId.parse(me.number + 1)!,
      socket,
    );
    addTearDown(service.close);
    final out = await ClaudeCodeDriverSocket(socket)
        .askTheModel(seat, haiku, '', 'hello', report: (_) {});
    // The service may hang up before the call is even written, so the
    // client's words vary; that it is refused and never asked does not.
    expect((out as Refused).why, startsWith('claude code driver: '));
    expect(driver.calls, isEmpty);
  });

  test('admits only the caller as the kernel reports each peer', () async {
    final caller = UserId.parse(1001)!;
    // What Linux's SO_PEERCRED writes: pid, uid, gid, 32 bits each.
    PeerUserReader peerIs(int? uid) => PeerUserReader(
      kernel: Kernel.linux,
      readOption: (_, _) => uid == null
          ? Uint8List(4)
          : (ByteData(12)
                  ..setUint32(0, 42, Endian.host)
                  ..setUint32(4, uid, Endian.host)
                  ..setUint32(8, uid, Endian.host))
                .buffer
                .asUint8List(),
      overflowUid: () => 65534,
    );
    for (final (uid, asked) in [
      (1001, true),
      (1002, false),
      (65534, false),
      (4294967295, false),
      (null, false),
    ]) {
      driver = Echo();
      final service = await ClaudeCodeDriverService.start(
        driver,
        caller,
        socket,
        reader: peerIs(uid),
      );
      final out = await ClaudeCodeDriverSocket(socket)
          .askTheModel(seat, haiku, '', 'hello', report: (_) {});
      await service.close();
      expect(out is Ran<ModelReply>, asked, reason: 'peer $uid');
      expect(driver.calls, hasLength(asked ? 1 : 0), reason: 'peer $uid');
    }
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
