# Changelog

## 0.7.0

- **Breaking:** `ClaudeCodeDriver.start` takes `flags:`, a `ClaudeCodeFlags`: `everyFlag` for Claude Code 2.1.311 and later, `withoutSafeModeOrRestricted` for 2.1.112, its last release in plain JavaScript, which runs on any Node (riscv64 among them). `ClaudeCodeFlags.forVersion` gives the flags for a version, or null for one the driver was not checked against, and the service refuses such a version at start.
- **Breaking:** `ClaudeCodeDriver.arguments` takes the flags too, and passes `--input-format stream-json`: the request goes to stdin as one stream-json user message (`ClaudeCodeDriver.userMessage`), then stdin closes. Its content is the same flattened text as before.
- Spares: `spares:` (the service's `CLAUDE_CODE_DRIVER_SPARES`, 0 by default) keeps a `claude` started and waiting for that many combinations of sign-in, model and system prompt, so a call skips Claude Code's startup. A spare is used once, like any call's `claude`; one past `spareLifetime` (30 minutes) or one that exited is ended instead. `close()` ends them all.
- `claude` runs with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, which stops 2.1.112 sending each prompt to Haiku 4.5 for a session title.
- A `system` event other than `init` may come before `init`; 2.1.323 prints `ui_invalidate` there when reading stream-json. Any other event before `init` is still refused.

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
