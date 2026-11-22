import 'dart:convert';

/// Who said a turn of a model request, and the name its line is given in
/// the text `claude -p` reads.
enum TurnRole {
  user('User'),
  assistant('Agent');

  const TurnRole(this.label);

  final String label;

  static TurnRole? parse(String role) =>
      values.where((r) => r.name == role).firstOrNull;
}

/// The text `claude -p` reads on stdin for [request], a call's approved
/// bytes.
///
/// [request] is a Responses API input array, oldest turn first:
/// `[{"role":"user","content":"…"},{"role":"assistant","content":"…"}]`.
/// Claude Code takes one prompt, so each turn becomes one line naming who
/// said it, `User: …` or `Agent: …`, its content exactly as sent, and the
/// lines are joined with `\n`.
///
/// Throws [FormatException] for anything but a non-empty JSON array of
/// turns, each exactly a `role` of `user` or `assistant` and a string
/// `content`. A system turn is refused: the system prompt travels apart.
String promptFor(String request) {
  final Object? json;
  try {
    json = jsonDecode(request);
  } on FormatException {
    throw const FormatException('not JSON');
  }
  if (json is! List<Object?> || json.isEmpty) {
    throw const FormatException('not a non-empty array of turns');
  }
  return [
    for (final (i, turn) in json.indexed)
      switch (turn) {
        {'role': final String role, 'content': final String content}
            when turn.length == 2 =>
          '${(TurnRole.parse(role) ?? (throw FormatException('turn $i: role is not user or assistant'))).label}: $content',
        _ => throw FormatException('turn $i is not exactly a role and content'),
      },
  ].join('\n');
}
