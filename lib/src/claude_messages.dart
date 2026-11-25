import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_model_vocabulary/is_model_vocabulary.dart';

/// The name of the MCP server through which the caller's tools are offered.
/// The model sees each tool as `mcp__tools__<name>`.
const toolServer = 'tools';

/// What Claude Code puts before an offered tool's name.
const offeredPrefix = 'mcp__${toolServer}__';

/// The longest name a tool can be offered under: the Messages API takes
/// 64 characters, [offeredPrefix] included.
const longestToolName = 64 - offeredPrefix.length;

/// [name] as the model is offered it and calls it.
String offeredName(String name) => '$offeredPrefix$name';

/// The [ModelRequest] in [request], which takes one of two shapes:
/// - `{tools, turns}`, is_model_vocabulary's request;
/// - an array of `{"role":"user"|"assistant","content":"…"}`, as every
///   request was before tools, read as [UserSaid] and [AgentSaid] turns
///   with no tools.
///
/// A [FormatException] says what is wrong.
ModelRequest requestOf(String request) {
  final Object? json;
  try {
    json = jsonDecode(request);
  } on FormatException {
    throw const FormatException('not JSON');
  }
  if (JsonObject.parse(json) != null) return _decoded(request);
  return switch (json) {
    final List<Object?> turns => ModelRequest(
      tools: const [],
      turns: [
        for (final (i, turn) in turns.indexed)
          switch (turn) {
            {'role': 'user', 'content': final String text}
                when turn.length == 2 =>
              UserSaid(text),
            {'role': 'assistant', 'content': final String text}
                when turn.length == 2 =>
              AgentSaid(text),
            _ => throw FormatException(
              'turn $i is not exactly a role of user or assistant and a '
              'string content',
            ),
          },
      ],
    ),
    _ => throw const FormatException(
      'neither {tools, turns} nor an array of turns',
    ),
  };
}

ModelRequest _decoded(String request) {
  try {
    return ModelRequest.decode(request);
  } on JsonFieldException catch (e) {
    throw FormatException('$e');
  }
}

/// Who says a message to Claude Code.
enum MessageRole { user, assistant }

/// One message as Claude Code's stdin carries it: who says it, and its
/// content blocks as the Messages API spells them.
typedef ClaudeMessage = ({MessageRole role, List<Object?> content});

/// [turns] as the messages Claude Code is handed, oldest first, each turn
/// a block of its own, turns of one side in a row one message. The last is
/// the person's or the tools' and is the one the model answers.
///
/// A tool call and its result are real `tool_use` and `tool_result`
/// blocks, so no turn's text can pass for a call, a result or another turn.
///
/// A [FormatException] names the turn that breaks a rule the Messages API
/// holds a conversation to: it ends on the user's side; every call is
/// answered once, by the turns straight after it, and those answers come
/// before anything the person says there. A turn carrying a continuation
/// is refused too: this driver never makes one, so it would be another
/// provider's, which the model here can't read.
List<ClaudeMessage> messagesOf(List<ModelTurn> turns) {
  if (turns.isEmpty) throw const FormatException('no turns');
  final messages = <ClaudeMessage>[];
  // The calls of the last agent turn still waiting for an answer, and the
  // index of that turn.
  final waiting = <ToolCallId>{};
  var calledAt = -1;
  void add(MessageRole role, Object? block) {
    if (messages.lastOrNull case (role: final r, :final content)
        when r == role) {
      content.add(block);
    } else {
      messages.add((role: role, content: [block]));
    }
  }

  for (final (i, turn) in turns.indexed) {
    switch (turn) {
      case UserSaid(:final text):
        if (waiting.isNotEmpty) {
          throw FormatException(
            'turn $i: the person speaks before every call of turn '
            '$calledAt is answered',
          );
        }
        add(MessageRole.user, {'type': 'text', 'text': text});
      case ToolAnswered(:final callId, :final result):
        if (!waiting.remove(callId)) {
          throw FormatException(
            'turn $i answers $callId, which no call before it waits on',
          );
        }
        add(MessageRole.user, {
          'type': 'tool_result',
          'tool_use_id': callId.value,
          'content': [
            {'type': 'text', 'text': toolResultText(result)},
          ],
          if (result is! ToolRan) 'is_error': true,
        });
      case AgentSaid() || AgentCalledTools() when waiting.isNotEmpty:
        throw FormatException(
          'turn $i: the agent speaks before every call of turn $calledAt '
          'is answered',
        );
      case AgentSaid(:final text):
        if (text.isEmpty) throw FormatException('turn $i says nothing');
        add(MessageRole.assistant, {'type': 'text', 'text': text});
      case AgentCalledTools(:final text, :final calls, :final continuation):
        if (continuation != null) {
          throw FormatException(
            'turn $i carries a continuation this driver did not make',
          );
        }
        if (text.isNotEmpty) {
          add(MessageRole.assistant, {'type': 'text', 'text': text});
        }
        for (final call in calls) {
          if (!waiting.add(call.id)) {
            throw FormatException('turn $i calls ${call.id} twice');
          }
          add(MessageRole.assistant, {
            'type': 'tool_use',
            'id': call.id.value,
            'name': offeredName(call.name.asSent),
            'input': call.input.object.asUncheckedMap(),
          });
        }
        calledAt = i;
    }
  }
  if (waiting.isNotEmpty) {
    throw FormatException(
      turns.last is AgentCalledTools
          ? 'the request ends with the agent calling tools'
          : 'calls of turn $calledAt are left unanswered: '
                '${waiting.join(' ')}',
    );
  }
  if (messages.last.role == MessageRole.assistant) {
    throw const FormatException('the request ends with the agent\'s turn');
  }
  for (final (:role, :content) in messages) {
    if (content.last case {'type': 'tool_result'}
        when role == MessageRole.user) {
      content.add(const {'type': 'text', 'text': endOfToolResultsLine});
    }
  }
  return messages;
}

/// The text block after a message's last tool result. Claude Code ends each
/// request with a note the API folds into the message before it; without
/// this block the note lands inside the tool result, whose bytes then differ
/// on the next step, and the prompt cache stops there.
const endOfToolResultsLine = '[end of tool results]';

/// The one line written to Claude Code's stdin for [message], the [index]th
/// of its conversation. A user message that is not [last] is only appended:
/// `shouldQuery: false` asks no model turn of it, and Claude Code
/// acknowledges it with a result that used no model. An assistant message
/// is appended at once and acknowledged by nothing. [last] is the message
/// the model answers.
///
/// An assistant message carries an id of its own, from its place in the
/// conversation: Claude Code joins assistant messages that share an id,
/// and 2.1.112 reads two with none as sharing one, joining two turns into
/// one.
String stdinLine(
  ClaudeMessage message, {
  required int index,
  required bool last,
}) =>
    '${jsonEncode({
      'type': message.role.name,
      if (message.role == MessageRole.user && !last) 'shouldQuery': false,
      'message': {if (message.role == MessageRole.assistant) 'id': 'msg_turn_$index', 'role': message.role.name, 'content': message.content},
    })}\n';

/// The first line of every tool result the model reads, written by the
/// driver alone, so text from outside never comes first: a fetched page
/// that says "refused" can't pass for the airlock refusing. The same lines
/// as chat_gpt_driver's, so a model reads results the same way whichever
/// driver serves it.
const ranLine = '[tool ran]';
const failedLine = '[tool failed]';
const refusedLine = '[refused by the airlock: nothing ran]';

/// [result] as the text of a `tool_result`.
String toolResultText(ToolResult result) => switch (result) {
  ToolRan(:final text) => '$ranLine\n$text',
  ToolFailed(:final text) => '$failedLine\n$text',
  ToolRefused(:final why) => '$refusedLine\n$why',
};
