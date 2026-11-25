import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

import 'fake_claude.dart';

/// A request of [turns], each a role and its content.
String request(List<(String, String)> turns) => jsonEncode([
  for (final (role, content) in turns) {'role': role, 'content': content},
]);

/// The line of the user message the model answers, of a text block for
/// each of [texts], decoded.
Map<String, Object?> answered(List<String> texts) => {
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      for (final text in texts) {'type': 'text', 'text': text},
    ],
  },
};

void main() {
  late FakeClaude fake;

  setUp(() async => fake = await FakeClaude.create());
  tearDown(() => fake.delete());

  /// The reply text of one call, or why it was refused.
  Future<String> ask(
    List<(String, String)> turns, {
    String systemPrompt = 'You are Cam.',
  }) async {
    final (outcome, _) = await call(
      fake.socket,
      systemPrompt: systemPrompt,
      request: request(turns),
    );
    return switch (outcome) {
      Ran(:final output) => output.text,
      NothingRan(:final why) => 'nothing ran: $why',
      StoppedPartway(:final why) => 'stopped: $why',
    };
  }

  /// A trajectory's first step, its reply, and the pid that answered.
  Future<(String reply, String pid)> firstStep() async {
    final reply = await ask([('user', 'task')]);
    return (reply, fake.reads.single);
  }

  test('continues a trajectory in the claude that answered it', () async {
    final driver = await fake.start(fake.sessionScript(), liveSessions: 1);
    addTearDown(driver.close);
    final (reply, pid) = await firstStep();
    expect(reply, 'reply $pid 1');

    expect(
      await ask([('user', 'task'), ('assistant', reply), ('user', 'more')]),
      'reply $pid 2',
    );
    expect(fake.reads, [pid, pid]);
    expect(fake.starts, hasLength(1));
    expect(fake.messagesTo(pid), [
      answered(['task']),
      answered(['more']),
    ]);
  });

  test('sends several new user turns as one message', () async {
    final driver = await fake.start(fake.sessionScript(), liveSessions: 1);
    addTearDown(driver.close);
    final (reply, pid) = await firstStep();

    expect(
      await ask([
        ('user', 'task'),
        ('assistant', reply),
        ('user', 'one'),
        ('user', '  two\r\n'),
      ]),
      'reply $pid 2',
    );
    expect(fake.messagesTo(pid).last, answered(['one', '  two\r\n']));
  });

  test('starts afresh for a history the session does not hold', () async {
    final driver = await fake.start(fake.sessionScript(), liveSessions: 2);
    addTearDown(driver.close);
    final (reply, first) = await firstStep();

    for (final (why, turns) in [
      (
        'reply changed',
        [('user', 'task'), ('assistant', '$reply '), ('user', 'm')],
      ),
      (
        'turn changed',
        [('user', 'task!'), ('assistant', reply), ('user', 'm')],
      ),
      ('no reply', [('user', 'task'), ('user', 'm')]),
      (
        'not only users after',
        [
          ('user', 'task'),
          ('assistant', reply),
          ('assistant', 'x'),
          ('user', 'm'),
        ],
      ),
    ]) {
      final answer = await ask(turns);
      final pid = fake.reads.last;
      expect(pid, isNot(first), reason: why);
      expect(answer, 'reply $pid 1', reason: why);
      // A fresh `claude` is written the whole history, the last user turns
      // the message it answers.
      expect(
        fake.messagesTo(pid).last,
        answered([
          for (final (role, content) in turns.sublist(
            turns.lastIndexWhere((t) => t.$1 == 'assistant') + 1,
          ))
            if (role == 'user') content,
        ]),
        reason: why,
      );
      expect(fake.messagesTo(pid), hasLength(turns.length == 2 ? 1 : 3));
    }

    final started = fake.starts.length;
    expect(
      await ask([('user', 'task'), ('assistant', reply)]),
      'nothing ran: not a request: the request ends with the agent\'s turn',
    );
    expect(fake.starts, hasLength(started));
  });

  test('a session serves only its own system prompt', () async {
    final driver = await fake.start(fake.sessionScript(), liveSessions: 2);
    addTearDown(driver.close);
    final (reply, first) = await firstStep();
    await ask([
      ('user', 'task'),
      ('assistant', reply),
      ('user', 'more'),
    ], systemPrompt: 'You are Bo.');
    expect(fake.reads.last, isNot(first));
  });

  test('without live sessions each call is a claude of its own', () async {
    final driver = await fake.start(fake.sessionScript());
    addTearDown(driver.close);
    final (reply, first) = await firstStep();
    await fake.until(() => !alive(first));
    await ask([('user', 'task'), ('assistant', reply), ('user', 'more')]);
    expect(fake.reads.last, isNot(first));
  });

  for (final (what, script) in [
    ('a cut-off reply', (FakeClaude f) => f.sessionScript(cutOff: true)),
    ('a refusal', (FakeClaude f) => f.sessionScript(error: true)),
  ]) {
    test('ends the claude after $what', () async {
      final driver = await fake.start(script(fake), liveSessions: 1);
      addTearDown(driver.close);
      await ask([('user', 'task')]);
      final pid = fake.reads.single;
      await fake.until(() => !alive(pid));
      expect(Directory(fake.starts.single.scratch).existsSync(), isFalse);
    });
  }

  test('refuses and ends a claude that summarises the conversation', () async {
    final driver = await fake.start(
      fake.sessionScript(
        beforeResult: jsonEncode({
          'type': 'system',
          'subtype': 'compact_boundary',
        }),
      ),
      liveSessions: 1,
    );
    addTearDown(driver.close);
    expect(
      await ask([('user', 'task')]),
      'stopped: claude code summarised the conversation in place of its turns',
    );
    await fake.until(() => !alive(fake.reads.single));
  });

  test('a session idle past its lifetime is ended, not continued', () async {
    var now = DateTime.utc(2026, 11, 24);
    final driver = await fake.start(
      fake.sessionScript(),
      liveSessions: 1,
      sessionLifetime: const Duration(minutes: 30),
      clock: () => now,
    );
    addTearDown(driver.close);
    final (reply, first) = await firstStep();

    now = now.add(const Duration(minutes: 30));
    await ask([('user', 'task'), ('assistant', reply), ('user', 'more')]);
    expect(fake.reads.last, isNot(first));
    await fake.until(() => !alive(first));
  });

  test('a session that exited is not continued', () async {
    final driver = await fake.start(fake.sessionScript(), liveSessions: 1);
    addTearDown(driver.close);
    final (reply, first) = await firstStep();

    Process.killPid(int.parse(first), ProcessSignal.sigkill);
    await fake.until(() => !alive(first));
    // The driver learns of the exit when the process is reaped.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final answer = await ask([
      ('user', 'task'),
      ('assistant', reply),
      ('user', 'more'),
    ]);
    expect(fake.reads.last, isNot(first));
    expect(answer, 'reply ${fake.reads.last} 1');
  });

  test('keeps its number of sessions at most', () async {
    final driver = await fake.start(fake.sessionScript(), liveSessions: 1);
    addTearDown(driver.close);
    final (_, first) = await firstStep();
    await ask([('user', 'another task')]);
    await fake.until(() => !alive(first));
    expect(alive(fake.reads.last), isTrue);
  });

  test('two calls at once continue the session once', () async {
    final driver = await fake.start(fake.sessionScript(), liveSessions: 2);
    addTearDown(driver.close);
    final (reply, first) = await firstStep();
    final next = [('user', 'task'), ('assistant', reply), ('user', 'more')];

    await Future.wait([ask(next), ask(next)]);
    expect(fake.reads.where((pid) => pid == first), hasLength(2));
    expect(fake.reads.toSet(), hasLength(2));
  });

  test('close ends idle sessions and deletes their folders', () async {
    final driver = await fake.start(fake.sessionScript(), liveSessions: 1);
    final (_, pid) = await firstStep();
    final scratch = fake.starts.single.scratch;
    expect(alive(pid), isTrue);

    await driver.close();
    expect(alive(pid), isFalse);
    expect(Directory(scratch).existsSync(), isFalse);
  });
}
