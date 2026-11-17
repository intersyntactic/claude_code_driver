import 'dart:convert';
import 'dart:io';

import 'package:is_claude_code_driver/is_claude_code_driver.dart';
import 'package:test/test.dart';

final secret = 'sk-ant-oat01-${'x' * 95}';

void main() {
  test('reads a setup token', () {
    final c = Credential.parse(
      jsonEncode({'kind': 'claude-code-setup-token', 'token': secret}),
    );
    expect((c as ClaudeCodeSetupToken).token, secret);
    expect('$c', isNot(contains(secret)));
  });

  for (final (name, raw) in [
    ('not JSON', 'nope'),
    ('no kind', '{}'),
    ('another kind', '{"kind":"api-key","token":"$secret"}'),
    ('a short token', '{"kind":"claude-code-setup-token","token":"abc"}'),
    (
      'a token with a newline',
      '{"kind":"claude-code-setup-token","token":"${secret.substring(1)}\\n"}',
    ),
    (
      'a field more',
      '{"kind":"claude-code-setup-token","token":"$secret","x":1}',
    ),
    ('no token', '{"kind":"claude-code-setup-token"}'),
  ]) {
    test('refuses $name, never saying the secret', () {
      expect(
        () => Credential.parse(raw),
        throwsA(
          isA<FormatException>().having(
            (e) => '$e',
            'message',
            isNot(contains('x' * 20)),
          ),
        ),
      );
    });
  }

  test('loads one sign-in per file, named for it', () async {
    final dir = await Directory.systemTemp.createTemp('ccd-cred');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/nick-claude-team').writeAsStringSync(
      jsonEncode({'kind': 'claude-code-setup-token', 'token': secret}),
    );
    final loaded = await Credential.load(dir);
    expect(loaded.keys.map((k) => k.name), ['nick-claude-team']);

    File('${dir.path}/Bad Name').writeAsStringSync('{}');
    expect(() => Credential.load(dir), throwsA(isA<FormatException>()));
  });
}
