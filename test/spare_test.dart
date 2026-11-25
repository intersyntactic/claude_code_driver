import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

import 'fake_claude.dart';

void main() {
  late FakeClaude fake;
  late String claude;

  setUp(() async {
    fake = await FakeClaude.create();
    claude = fake.script([init([]), result('ok')]);
  });
  tearDown(() => fake.delete());

  Future<void> expectAnswered({String systemPrompt = 'You are Cam.'}) async {
    final (outcome, _) = await call(fake.socket, systemPrompt: systemPrompt);
    expect((outcome as Ran<ModelReply>).output.text, 'ok');
  }

  /// The one spare waiting once it has started.
  Future<({String pid, String scratch, String systemPrompt})> spare() async {
    await fake.until(() => fake.waiting.length == 1);
    return fake.waiting.single;
  }

  test('starts no spare unless asked', () async {
    final driver = await fake.start(claude);
    addTearDown(driver.close);
    await expectAnswered();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(fake.starts, hasLength(1));
  });

  test('the next call is read by the spare started for it', () async {
    final driver = await fake.start(claude, spares: 1);
    addTearDown(driver.close);
    await expectAnswered();
    final first = await spare();

    await expectAnswered();
    expect(fake.reads.last, first.pid);
    expect(Directory(first.scratch).existsSync(), isFalse);
    // And one more is started for the call after.
    final next = await spare();
    expect(next.pid, isNot(first.pid));
  });

  test('a call with earlier turns is read by the spare too, the turns '
      'written to it', () async {
    final driver = await fake.start(claude, spares: 1);
    addTearDown(driver.close);
    await expectAnswered();
    final first = await spare();

    final (outcome, _) = await call(
      fake.socket,
      request:
          '[{"role":"user","content":"hi"},{"role":"assistant","content":"ok"},'
          '{"role":"user","content":"more"}]',
    );
    expect((outcome as Ran<ModelReply>).output.text, 'ok');
    expect(fake.reads.last, first.pid);
    // The notes hold the first call's message too, ahead of these.
    expect(fake.conversation.skip(1), [
      [
        'user',
        true,
        [
          {'type': 'text', 'text': 'hi'},
        ],
      ],
      [
        'assistant',
        false,
        [
          {'type': 'text', 'text': 'ok'},
        ],
      ],
      [
        'user',
        false,
        [
          {'type': 'text', 'text': 'more'},
        ],
      ],
    ]);
  });

  test('a spare serves only its own sign-in, model and prompt', () async {
    final driver = await fake.start(claude, spares: 2);
    addTearDown(driver.close);
    await expectAnswered();
    final forCam = await spare();

    await expectAnswered(systemPrompt: 'You are Bo.');
    final reader = fake.starts.firstWhere((s) => s.pid == fake.reads.last);
    expect(reader.pid, isNot(forCam.pid));
    expect(reader.systemPrompt, 'You are Bo.');
    await fake.until(() => fake.waiting.length == 2);
    expect(fake.waiting.map((s) => s.pid), contains(forCam.pid));
  });

  test('keeps spares for its number of combinations at most', () async {
    final driver = await fake.start(claude, spares: 1);
    addTearDown(driver.close);
    await expectAnswered();
    final forCam = await spare();

    await expectAnswered(systemPrompt: 'You are Bo.');
    await fake.until(() => !alive(forCam.pid));
    await fake.until(() => !Directory(forCam.scratch).existsSync());
    expect((await spare()).systemPrompt, 'You are Bo.');
  });

  test('a spare past its lifetime is ended, not used', () async {
    var now = DateTime.utc(2026, 11, 24);
    final driver = await fake.start(
      claude,
      spares: 1,
      spareLifetime: const Duration(minutes: 30),
      clock: () => now,
    );
    addTearDown(driver.close);
    await expectAnswered();
    final old = await spare();

    now = now.add(const Duration(minutes: 30));
    await expectAnswered();
    expect(fake.reads.last, isNot(old.pid));
    await fake.until(() => !alive(old.pid));
  });

  test('a spare that exited is not used', () async {
    final driver = await fake.start(claude, spares: 1);
    addTearDown(driver.close);
    await expectAnswered();
    final dead = await spare();

    Process.killPid(int.parse(dead.pid), ProcessSignal.sigkill);
    await fake.until(() => !alive(dead.pid));
    // The driver learns of the exit when the process is reaped.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await expectAnswered();
    expect(fake.reads, hasLength(2));
    expect(fake.reads.last, isNot(dead.pid));
  });

  test('calls at once each get a claude of their own', () async {
    final driver = await fake.start(claude, spares: 1);
    addTearDown(driver.close);
    await expectAnswered();
    await spare();

    await Future.wait([expectAnswered(), expectAnswered(), expectAnswered()]);
    expect(fake.reads, hasLength(4));
    expect(fake.reads.toSet(), hasLength(4));
  });

  test('close ends every spare and deletes its folder', () async {
    final driver = await fake.start(claude, spares: 1);
    await expectAnswered();
    final waiting = await spare();

    await driver.close();
    expect(alive(waiting.pid), isFalse);
    expect(Directory(waiting.scratch).existsSync(), isFalse);
  });
}
