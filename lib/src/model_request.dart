import 'dart:convert';

/// Who said a turn of a model request.
enum TurnRole {
  user,
  assistant;

  static TurnRole? parse(String role) =>
      values.where((r) => r.name == role).firstOrNull;
}

/// One turn of a request: who said it, and its content exactly as sent.
typedef Turn = ({TurnRole role, String content});

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

/// [turns] split after its last assistant turn: the [history] up to and
/// including it, and the contents of the user turns [added] after it, which
/// the model answers. Null when [turns] ends with an assistant turn, which
/// leaves nothing to answer.
({List<Turn> history, List<String> added})? splitAtLastReply(List<Turn> turns) {
  if (turns.last.role == TurnRole.assistant) return null;
  final last = turns.lastIndexWhere((t) => t.role == TurnRole.assistant);
  return (
    history: turns.sublist(0, last + 1),
    added: [for (final turn in turns.sublist(last + 1)) turn.content],
  );
}

/// [history] as a Claude Code session transcript, one JSON line per message,
/// for `claude --resume [session]` to send as real user and assistant
/// turns, so no turn's content can pass for another turn. Consecutive turns
/// of one role become one message, a text block each. Every entry carries
/// [at]: without a timestamp Claude Code finds no conversation.
String transcript(
  List<Turn> history, {
  required String session,
  required DateTime at,
}) {
  final timestamp = DateTime.fromMillisecondsSinceEpoch(
    at.millisecondsSinceEpoch,
    isUtc: true,
  ).toIso8601String();
  final messages = <(TurnRole, List<String>)>[];
  for (final turn in history) {
    if (messages.lastOrNull case (final role, final texts)
        when role == turn.role) {
      texts.add(turn.content);
    } else {
      messages.add((turn.role, [turn.content]));
    }
  }
  String? parent;
  final lines = <String>[];
  for (final (i, (role, texts)) in messages.indexed) {
    final uuid = _entryId(i);
    lines.add(
      jsonEncode({
        'type': role.name,
        'uuid': uuid,
        'parentUuid': parent,
        'sessionId': session,
        'timestamp': timestamp,
        'message': {
          'role': role.name,
          'content': [
            for (final text in texts) {'type': 'text', 'text': text},
          ],
        },
      }),
    );
    parent = uuid;
  }
  return '${lines.join('\n')}\n';
}

/// The id of a transcript's [i]th entry: unique within its transcript,
/// which is all Claude Code links entries by.
String _entryId(int i) =>
    '00000000-0000-4000-8000-${i.toRadixString(16).padLeft(12, '0')}';
