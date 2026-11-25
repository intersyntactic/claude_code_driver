import 'dart:convert';

import 'package:is_claude_code_driver/src/claude_messages.dart';
import 'package:is_model_vocabulary/is_model_vocabulary.dart';
import 'package:test/test.dart';

void main() {
  ToolCall called(String id) => ToolCall(
    id: ToolCallId.parse(id)!,
    name: CalledToolName.fromSent('fetch_page'),
    input: ToolInput.parse(jsonEncode({'url': id}))!,
  );
  ToolAnswered answered(String id) =>
      ToolAnswered(callId: ToolCallId.parse(id)!, result: ToolRan('page $id'));
  final step1 = <ModelTurn>[
    const UserSaid('read two pages'),
    AgentCalledTools(text: '', calls: [called('toolu_a')]),
    answered('toolu_a'),
  ];
  final step2 = [
    ...step1,
    AgentCalledTools(text: '', calls: [called('toolu_b')]),
    answered('toolu_b'),
  ];
  List<Object?> types(ClaudeMessage message) => [
    for (final block in message.content)
      if (block case {'type': final String type}) type,
  ];

  test('every message of tool results ends with the end-of-results block', () {
    final messages = messagesOf(step2);
    for (final i in [2, 4]) {
      expect(types(messages[i]), ['tool_result', 'text']);
      expect(messages[i].content.last, {
        'type': 'text',
        'text': endOfToolResultsLine,
      });
    }
  });

  test('a step repeats the step before it exactly, so the cache matches', () {
    final before = messagesOf(step1);
    final after = messagesOf(step2);
    expect(
      jsonEncode(after.take(before.length).map((m) => m.content).toList()),
      jsonEncode(before.map((m) => m.content).toList()),
    );
  });

  test('no block when the person speaks after the results', () {
    final messages = messagesOf([...step1, const UserSaid('and then?')]);
    expect(types(messages.last), ['tool_result', 'text']);
    expect(messages.last.content.last, {'type': 'text', 'text': 'and then?'});
  });
}
