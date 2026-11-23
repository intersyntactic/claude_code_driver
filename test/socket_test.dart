import 'dart:convert';
import 'dart:typed_data';

import 'package:is_claude_code_driver/is_claude_code_driver.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';
import 'package:test/test.dart';

import 'fake_claude.dart';

void main() {
  late FakeClaude fake;
  late String claude;

  setUp(() async {
    fake = await FakeClaude.create();
    claude = fake.script([
      init([]),
      delta('hel'),
      delta('lo'),
      result('hello'),
    ]);
  });
  tearDown(() => fake.delete());

  test('asks for its caller, streaming the reply back', () async {
    final driver = await fake.start(claude);
    addTearDown(driver.close);
    final (outcome, reported) = await call(fake.socket);
    expect((outcome as Ran<ModelReply>).output.text, 'hello');
    expect(
      [for (final p in reported) (p as ReplyArriving).text],
      ['hel', 'lo'],
    );
    expect(fake.sentPrompt, 'User: hello');
    expect(fake.noted('system-prompt'), 'You are Cam.');
  });

  test('carries a refusal back across the socket', () async {
    final driver = await fake.start(
      fake.script([init([]), result('no', error: true)], exit: 1),
    );
    addTearDown(driver.close);
    final (outcome, _) = await call(fake.socket);
    expect((outcome as Refused).why, 'claude: no');
  });

  test('answers the probe {} without asking the model', () async {
    final driver = await fake.start(claude);
    addTearDown(driver.close);
    expect(
      (await rawCall(fake.socket, '{}')).trim(),
      '{"kind":"finished","outcome":{"kind":"refused",'
      '"why":"not a call: modelCall.signIn: not a string"}}',
    );
    expect(fake.ran, isFalse);
  });

  test('refuses a sign-in that is not a name', () async {
    final driver = await fake.start(claude);
    addTearDown(driver.close);
    expect(
      await rawCall(
        fake.socket,
        '{"signIn":"Nick!","model":"m","systemPrompt":"","request":"x"}',
      ),
      contains('not a call: modelCall.signIn: not a model sign-in'),
    );
    expect(fake.ran, isFalse);
  });

  test('refuses a call too large to carry', () async {
    final driver = await fake.start(claude);
    addTearDown(driver.close);
    expect(
      await rawCall(fake.socket, ' ' * (ClaudeCodeDriver.maxCall + 1)),
      contains('call too large'),
    );
    expect(fake.ran, isFalse);
  });

  test('closes on any other user, unanswered', () async {
    final driver = await fake.start(
      claude,
      caller: UserId.parse(me.number + 1)!,
    );
    addTearDown(driver.close);
    expect(await rawCall(fake.socket, jsonEncode({})), isEmpty);
    expect(fake.ran, isFalse);
  });

  test('allows only the caller as the kernel reports each peer', () async {
    final caller = UserId.parse(1001)!;
    // What Linux's SO_PEERCRED writes: pid, uid, gid, 32 bits each.
    SocketUserReader peerIs(int? uid) => SocketUserReader(
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
      final driver = await fake.start(
        claude,
        caller: caller,
        socketUserReader: peerIs(uid),
      );
      final (outcome, _) = await call(fake.socket);
      await driver.close();
      expect(outcome is Ran<ModelReply>, asked, reason: 'peer $uid');
      expect(fake.ran, asked, reason: 'peer $uid');
      if (fake.ran) fake.notes.listSync().forEach((f) => f.deleteSync());
    }
  });

  test('will not start over a socket something listens on', () async {
    final driver = await fake.start(claude);
    addTearDown(driver.close);
    expect(() => fake.start(claude), throwsStateError);
  });

  test('replaces a socket file nothing listens on', () async {
    final first = await fake.start(claude);
    // Leave the file behind, as a killed driver would.
    await first.close();
    fake.socket.createSync();
    final driver = await fake.start(claude);
    addTearDown(driver.close);
    final (outcome, _) = await call(fake.socket);
    expect(outcome, isA<Ran<ModelReply>>());
  });
}
