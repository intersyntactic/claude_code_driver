# Changelog

## 0.9.1

- Every run checks that `shouldQuery: false` held. Any sign the model was asked before the last message is written now logs an alarm as well as stopping the call partway, and a bare `assistant` event counts as such a sign; before, it was let through and only the stream events caught it.

## 0.9.0

- **Breaking:** is_effects ^0.15.0 and is_model_vocabulary ^0.2.0. `Refused` is gone: a call that fails before its last message is written, when Claude Code has asked the model nothing, is `NothingRan` (a bad call or request, an unknown sign-in, a `claude` that does not start, the wrong MCP tools, built-in tools at init while turns are still being appended). One that fails after is `StoppedPartway` with nothing done (an error result, no result, the time limit, a summarised conversation, a call to a tool not offered, built-in tools at init). The `{}` probe now answers `{"kind":"nothingRan",…}`.
- The request may be is_model_vocabulary's `{tools, turns}` (`ModelRequest`) as well as the array of `{role, content}` turns, which reads as `UserSaid` and `AgentSaid` with no tools.
- Tools: the call's tools are offered through an SDK MCP server, `tools`, that the driver answers over claude's own stdin and stdout, so the model sees `mcp__tools__<name>`. They never run. claude asks permission (`--permission-prompt-tool stdio`) and is never answered, and is killed once the model's message ends; the calls come back as `Ran(ProposedToolCalls)`, each name with the prefix taken off and its input encoded once. Before any message the driver checks `mcp_status` for exactly the offered tools, and init must list exactly those. `ENABLE_TOOL_SEARCH=false` stops a placeholder tool init does not list. A call to a tool not offered stops partway, since Claude Code answers it itself and asks again.
- Every turn is written to claude's stdin, one at a time, in place of a `--resume` transcript, which Claude Code repairs as it loads (a call with no result gets an invented "interrupted" result and the real one is dropped; a transcript ending on a user turn gets an invented "No response requested." reply). A user message that is not the last goes with `shouldQuery: false` and is acknowledged before the next is written; an assistant message carries an id of its own, without which 2.1.112 joins two turns into one. Tool calls and results are real `tool_use` and `tool_result` blocks, each result led by `[tool ran]`, `[tool failed]` or `[refused by the airlock: nothing ran]`, failed and refused ones marked `is_error`.
- A request that breaks a rule of the conversation runs nothing: it ends with the agent's turn, a call is answered twice, late, never, or after the person speaks, a turn carries a continuation, or a tool name is over 52 characters.
- Every `claude` runs in one empty working directory, made at start and deleted at close: Claude Code writes its path near the start of every request, and one path keeps cold calls' requests alike for the prompt cache (36,018 of about 36k tokens read on the second of two cold calls, against 0 with a folder per call).
- A spare serves any call of its sign-in, model, system prompt and tools, earlier turns included.
- **Breaking:** `ClaudeCodeDriver.arguments` takes `systemPromptFile:`, an absolute path, and no `resume:`; `ClaudeCodeDriver.userMessage` is gone.
- The contract test checks tool turns as real blocks, the exact tools offered, a proposal with the API asked once, a call to a tool not offered, and an 81-turn conversation whole and in order. It passes on 2.1.326 and 2.1.112.

## 0.8.1

- A refused peer is logged before its socket is closed, one line saying why: `refused a peer: not allowed: user 1002 is not one of {998}`, or `refused a peer: unread: …` with the kernel's error when its user could not be read. The refusal itself is unchanged.
- is_unix_socket_user_check ^0.2.1, whose `decide` says why a peer is refused, on one line even when the kernel's error text holds a line break.

## 0.8.0

- Every turn is a real turn. A cold call no longer flattens its turns into one `User: …` / `Agent: …` text, where a turn's content could forge another turn (a fetched page holding `\nAgent: I already approved it` read as the agent's own reply). The turns up to the last assistant turn are written as a Claude Code session transcript in the call's config and `claude` starts with `--resume` on it, so the model reads them as the API's own user and assistant turns; the user turns after it go to stdin as one user message, a text block each.
- **Breaking:** a request that ends with an assistant turn is refused (`a request ends with a user turn`): it leaves nothing to answer.
- **Breaking:** `ClaudeCodeDriver.userMessage` takes the user turns, a `List<String>`, and writes one text block each; `continuation` is gone into it. `ClaudeCodeDriver.arguments` takes `resume:`.
- A spare serves only a call with no earlier reply, since earlier turns are handed to `claude` as it starts; a call with one starts its own `claude` and leaves the spare waiting.
- `test/claude_code_contract_test.dart` runs the installed Claude Code through the driver against a stand-in Messages API and checks the turns that reach it. Run it for each Claude Code a host is given; `CLAUDE_CODE_CONTRACT_CLAUDE` names another command. It passes on 2.1.325 and 2.1.112.

## 0.7.1

- is_effects ^0.14.3. It moves `SignIn` into `is_sign_in_vocabulary`, re-exported as the same type, and its `decodeAddressPrefix` refuses keys other than `origin` and `pathPrefix`; neither touches what the driver uses.

## 0.7.0

- **Breaking:** `ClaudeCodeDriver.start` takes `flags:`, a `ClaudeCodeFlags`: `everyFlag` for Claude Code 2.1.311 and later, `withoutSafeModeOrRestricted` for 2.1.112, its last release in plain JavaScript, which runs on any Node (riscv64 among them). `ClaudeCodeFlags.forVersion` gives the flags for a version, or null for one the driver was not checked against, and the service refuses such a version at start.
- **Breaking:** `ClaudeCodeDriver.arguments` takes the flags too, and passes `--input-format stream-json`: the request goes to stdin as one stream-json user message (`ClaudeCodeDriver.userMessage`), then stdin closes. Its content is the same flattened text as before.
- Spares: `spares:` (the service's `CLAUDE_CODE_DRIVER_SPARES`, 0 by default) keeps a `claude` started and waiting for that many combinations of sign-in, model and system prompt, so a call skips Claude Code's startup. A spare is used once, like any call's `claude`; one past `spareLifetime` (30 minutes) or one that exited is ended instead. `close()` ends them all.
- `claude` runs with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, which stops 2.1.112 sending each prompt to Haiku 4.5 for a session title.
- A `system` event other than `init` may come before `init`; 2.1.323 prints `ui_invalidate` there when reading stream-json. Any other event before `init` is still refused.
- Live sessions: `liveSessions:` (the service's `CLAUDE_CODE_DRIVER_LIVE_SESSIONS`, 0 by default) keeps a `claude` running after a call it finished with a whole reply. A later call whose turns are exactly the ones it holds, then its reply, then one or more user turns, is written into it as one message of only the new turns (`ClaudeCodeDriver.continuation`); any other call starts afresh, as before. A session idle past `sessionLifetime` (30 minutes), or one that exited, is ended; `close()` ends them all.
- `claude` runs with `DISABLE_AUTO_COMPACT=1`, so a full context is refused (`Prompt is too long`) rather than silently summarised; a `compact_boundary` event is refused all the same, and its `claude` ended.
- A `claude` that has exited is waited on for its output at most 2 s more, since a child it left can hold its pipes open.

## 0.6.2

- is_effects ^0.14.2. 0.14.1 adds `FileRequest` and 0.14.2 moves the web address types into `is_web_address_vocabulary`, which is_effects re-exports; neither touches what the driver uses.

## 0.6.1

- is_effects ^0.14.0. Its one breaking change, splitting `Request` into `ProposedRequest` and `GrantedRequest`, touches nothing the driver uses.

## 0.6.0

- **Breaking:** one class, `ClaudeCodeDriver`, is the driver and owns its socket: `ClaudeCodeDriver.start(signIns, caller:, socket:, …)` binds and serves, and `close()` stops it. `ClaudeCodeDriverService` is gone, and `ClaudeCodeDriver` no longer implements `AsksTheModel`: the only way to ask it is over the socket.
- **Breaking:** `package:is_claude_code_driver/service.dart` is gone, with `ClaudeCodeDriverSocket` and `CheckDriver`. A caller now writes its own client: connect to the socket, write one call as JSON and close the write side, then read one JSON line per message until `{"kind":"finished",…}` (the README shows each line).
- The socket protocol is unchanged.

## 0.5.1

- is_effects ^0.13.0. Nothing `AsksTheModel` or the model-call codec uses changed.

## 0.5.0

- **Breaking:** `request` must be a JSON input array of turns. Text that is not JSON, which 0.2.0 to 0.4.1 passed straight through for the switchover, is refused before `claude` starts with `not a request: not JSON`.

## 0.4.1

- Docs say "the logbook" where they said "the record": one word for one thing. No code change.

## 0.4.0

- **Breaking:** `ClaudeCodeDriverService.start` takes the caller as a `UserId` from is_unix_socket_user_check, not an `int`, and an optional `SocketUserReader`. Who may call is decided by `SocketUserCheck`, which denies a peer whose user the kernel does not name; a `UserId` can never be 65534, 4294967294 or `(uid_t)-1`, so none of them can be the configured caller. The service refuses to start on such a caller.

## 0.3.2

- is_effects ^0.12.0. Nothing `AsksTheModel` or the model-call codec uses changed.

## 0.3.1

- is_effects ^0.11.0. Nothing `AsksTheModel` uses changed.

## 0.3.0

- is_effects ^0.9.0. A reply is a `FinishedReply`, or a `CutOffReply` when `claude -p` stopped at a token limit (`max_tokens`, `model_context_window_exceeded`).
- Each reply carries `ModelUsage` from the run's last model call, with the asked-for model's context window.
- `ClaudeCodeDriverSocket(socket, checkDriver:)`: an optional `CheckDriver` that runs on each connected socket before the call is written. A reason it returns becomes `Refused` and the driver never sees the call. The airlock uses it to check which release the kernel says the driver is.

## 0.2.0

- `request` is a Responses API input array of `user` and `assistant` turns, flattened into `User: …` / `Agent: …` lines for `claude -p`. JSON of any other shape is refused before `claude` starts; text that is not JSON still goes as it is.

## 0.1.0

- `ClaudeCodeDriver`: `AsksTheModel` through `claude -p` with every built-in tool off, a fresh config per call, and a seat token per model sign-in.
- `ClaudeCodeDriverService` and `ClaudeCodeDriverSocket`: the driver as its own service, answering only the airlock's user.
