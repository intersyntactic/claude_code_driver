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

/// One turn of a request: who said it, and its content exactly as sent.
typedef Turn = ({TurnRole role, String content});

/// The text `claude -p` reads on stdin for [request], a call's approved
/// bytes: [flatten] of [turnsOf].
String promptFor(String request) => flatten(turnsOf(request));

/// [turns] as one prompt: Claude Code started on a call takes no earlier
/// assistant turns, so each turn becomes one line naming who said it,
/// `User: …` or `Agent: …`, its content exactly as sent, and the lines are
/// joined with `\n`.
String flatten(List<Turn> turns) =>
    [for (final turn in turns) '${turn.role.label}: ${turn.content}']
        .join('\n');

/// The turns of [request], a Responses API input array, oldest turn first:
/// `[{"role":"user","content":"…"},{"role":"assistant","content":"…"}]`.
///
/// Throws [FormatException] for anything but a non-empty JSON array of
/// turns, each exactly a `role` of `user` or `assistant` and a string
/// `content`. A system turn is refused: the system prompt travels apart.
List<Turn> turnsOf(String request) {
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
          (
            role:
                TurnRole.parse(role) ??
                (throw FormatException(
                  'turn $i: role is not user or assistant',
                )),
            content: content,
          ),
        _ => throw FormatException('turn $i is not exactly a role and content'),
      },
  ];
}
