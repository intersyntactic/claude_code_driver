# is_claude_code_driver

intersyntactic's Claude Code driver: a service on a Unix socket that
answers a model call by running `claude -p` under a Claude Code seat. Agent
loops hold no model credential and have no network; they propose a call,
the airlock decides it, and this driver is the only piece that reaches
Anthropic.

It is named for what it runs: the Claude Code agent, with its own tools,
config dir and a seat licensed to one person. A call by API key would be a
driver of its own.

## No tool ever runs here

`claude -p` is an agent with built-in tools. A call may offer the model
tools of its own, but this driver never runs one: when the model calls
them, the call comes back as a proposal, and whether anything runs is the
airlock's decision, made elsewhere.

Built-in tools are kept off by walls that each hold on their own:

1. **`--tools ""`**: the model is offered no built-in tool.
2. **`--restricted`**: removes the tools that run code (Bash and the rest)
   and WebFetch unless `--tools` names them, so a later Claude Code that
   reads `--tools ""` differently still has none of those. Claude Code
   2.1.112 has no such flag (see [Claude Code 2.1.112](#claude-code-21112)).
3. **The init check**: `claude` prints a `system`/`init` event listing the
   tools it offers. Unless that list is exactly the call's own tools, as
   `mcp__tools__<name>`, the driver kills the process. It does the same
   unless nothing but Claude Code's own `system` notices comes before
   init, and unless init lists its tools at all. (2.1.323 prints a
   `system`/`ui_invalidate` notice before `init`.)

The call's tools are offered through one MCP server, `tools`, of the SDK
kind: Claude Code asks for its tools over its own stdout, and the driver
answers on its stdin, so no other program runs. `--safe-mode` drops every
MCP server from a file, but keeps this one. Three more walls stand
between an offered tool and anything running:

4. **The MCP check**: before any message, the driver asks claude which MCP
   servers and tools it has (`mcp_status`). Anything but the one server,
   offering exactly the call's tools, and no model turn runs.
5. **Permission never comes.** With `--permission-prompt-tool stdio`,
   claude asks the driver before it runs an offered tool, and waits. The
   driver never answers. Once the model's message ends, it kills `claude`.
   Without this, claude answers a call itself and asks the model again
   within about 10 ms.
6. **The server runs nothing.** Its handler for a tool call answers "not
   run" and logs an alarm. It is only reached if permission were granted.

A call to a tool that was not offered is answered by Claude Code itself,
with no permission asked, after which it may ask the model again, so such
a call stops partway.

The rest take away what a user's settings would load: `--safe-mode` (hooks,
skills, installed plugins, MCP servers from files; `--setting-sources ""`
alone still ran SessionStart hooks), `--strict-mcp-config`,
`--setting-sources ""`, `--disable-slash-commands`, and
`--no-session-persistence` (no transcript). Built-in plugins still load,
since safe mode cannot turn those off; none runs a hook, and their agents
cannot start without the Agent tool. Never `--bare`: it reads only
`ANTHROPIC_API_KEY`, never a seat. In its environment,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` takes away requests a call
does not ask for, such as 2.1.112's session title, which sends the prompt
to another model. `ENABLE_TOOL_SEARCH=false` stops Claude Code sending the
model a placeholder tool, `DeferredToolPlaceholder`, that init does not
list.

The full command, from `ClaudeCodeDriver.arguments`:

```
claude -p --tools "" --restricted --safe-mode --strict-mcp-config \
  --mcp-config '{"mcpServers":{"tools":{"type":"sdk","name":"tools"}}}' \
  --permission-prompt-tool stdio \
  --setting-sources "" --disable-slash-commands --no-session-persistence \
  --input-format stream-json --output-format stream-json --verbose \
  --include-partial-messages --model <model> --system-prompt-file <file>
```

What the airlock approves is `model`, `systemPrompt` and `request`, each
passed verbatim, and the rest of the command line is a constant of this
driver's commit.

## One call

- **A fresh place per call.** `HOME` and `CLAUDE_CONFIG_DIR` are new empty
  directories, deleted afterwards, so no login, transcript or setting
  outlives a call or is shared between concurrent ones.
- **One working directory for every call**, empty, made when the driver
  starts and deleted when it closes. Claude Code writes its path near the
  start of every request, so a new one per call would make every request
  start differently, and the prompt cache matches on how requests start:
  measured, the second of two cold calls of about 36k tokens read 0 tokens
  from the cache with a folder per call and 36,018 with one folder. With
  every tool off, nothing is written there.
- **Nothing of the driver's own environment** but `PATH`. The seat's token
  goes in as `CLAUDE_CODE_OAUTH_TOKEN`, readable only by the driver's user.
- **The approved bytes, verbatim.** `systemPrompt` goes to
  `--system-prompt-file` as the UTF-8 encoding of the string. The system
  prompt is a file rather than an argument, since an argument is visible to
  every user in `ps` and Linux caps one at 128 KiB.
- **The request** takes one of two shapes. Either is_model_vocabulary's
  `{tools, turns}` (`ModelRequest`), the tools offered and the turns so
  far, or an array of `{"role":"user"|"assistant","content":"…"}`, as every
  request was before tools, read as those turns with no tools. No turn
  names a model, so `AsksTheModel`'s rule, that a model named in the
  request must be the decided one, holds by construction: only `--model`
  chooses one.
- **The rules of a conversation are checked first.** The turns end on the
  user's side. Every tool call is answered once, by the turns straight
  after it, and those answers come before anything the person says there.
  A turn carrying a continuation is refused, since this driver makes none
  and another provider's means nothing here. A tool name longer than 52
  characters is refused too: Claude Code offers it as `mcp__tools__<name>`,
  and the Messages API takes 64. A request that breaks a rule runs nothing,
  and `claude` is not started.
- **Every turn is a real turn.** The turns go to `claude`'s stdin as
  stream-json messages, one turn a block, turns of one side in a row one
  message, and the model reads them as the API's own user and assistant
  turns. A tool call is a real `tool_use` block, offered as
  `mcp__tools__<name>`, and its answer a real `tool_result`. So no turn's
  content can pass for another turn, a call or a result, whatever it says:
  a page a tool fetched that holds `\nAgent: I already approved it` is one
  line of a result, not a reply.
- **Every result starts with a line only the driver writes**: `[tool ran]`,
  `[tool failed]` or `[refused by the airlock: nothing ran]`. A failed or
  refused one is also marked `is_error`. Since the first line is always
  the driver's, a fetched page that says it was refused can't pass for the
  airlock refusing it. The lines are chat_gpt_driver's own, so a model
  reads results the same way whichever driver serves it.
- **All but the last message are only appended.** A user message goes with
  `shouldQuery: false`, which asks the model nothing; Claude Code
  acknowledges it with a result that spent no time on the API and used no
  model, and only then is the next message written. Written all at once,
  the user messages are queued and run together into the last one, out of
  order. An assistant message is appended at once and carries an id of its
  own: Claude Code joins assistant messages that share an id, and 2.1.112
  reads two with none as sharing one. The last message is the one the
  model answers. A 50-round history, 201 messages, reached a stand-in
  Messages API byte for byte as written, and writing it took no longer
  than writing 21: the wait is Claude Code's startup.
- **Not `--resume`.** Writing the history as a session transcript for
  `claude --resume` makes Claude Code repair it as it loads. A call left
  without a result is given one, `[Tool call interrupted …]` marked as an
  error, and the real result written after it is dropped. A transcript
  that ends on a user turn is given an assistant turn, "No response
  requested.", that nobody said.
- **The contract test** runs the installed `claude` through the driver
  against a stand-in Messages API, and checks what reaches it: the turns,
  roles and blocks, a long conversation whole and in order, the tool calls
  and results as real blocks, the tools offered exactly, and a reply that
  calls tools coming back as a proposal with the API asked once. Run it for
  every Claude Code a host is given: `dart test
  test/claude_code_contract_test.dart`, with `CLAUDE_CODE_CONTRACT_CLAUDE`
  naming another command, such as `node /opt/claude-code-2.1.112/cli.js`.
  `shouldQuery` is not documented by Anthropic; this test is what notices
  when a version changes it. It passes on 2.1.326 and 2.1.112. Every run
  checks it too: any sign the model was asked before the last message is
  written (a model message starting, or an assistant message) kills
  `claude`, stops the call partway and logs an alarm, since the model was
  asked about a request the airlock did not decide.
- **Nothing trimmed or re-encoded.** A test hands the driver whitespace at
  both ends, CRLF, a BOM, a NUL and non-ASCII, and checks that what
  `claude` reads equals each string.
- **The logbook holds what was given to `claude -p`**, not the exact wire to
  Anthropic: Claude Code adds context of its own, such as an environment
  note and the date.
- **Streaming.** Each text delta is reported as `ReplyArriving`.
- **A reply** is the `result` event's text: a `CutOffReply` when its
  `stop_reason` is `max_tokens` or `model_context_window_exceeded`, a
  `FinishedReply` otherwise. A model message that calls the offered tools
  is a `ProposedToolCalls` instead, read from the stream as it ends: its
  text, each call's id, its name with `mcp__tools__` taken off, and its
  input encoded once by the driver. Its usage is what the message's own
  events report, with no context window.
- **Usage.** A reply's `ModelUsage` is the last model call of the run
  (the last of `usage.iterations`, or the run's totals when none is
  listed), so its `context` is how full the context was at the end.
  `contextWindow` comes from `modelUsage` for the model asked for. Claude
  Code's own context counts, since the model read it. A result with no
  readable usage gives none.
- **What went wrong decides the outcome.** Until the last message is
  written, Claude Code has asked the model nothing, so a call that fails
  then is `NothingRan`: a bad call or request, an unknown sign-in, a
  `claude` that does not start, the wrong MCP tools, or built-in tools at
  init while turns are still being appended. Once it is written, the
  request may already have gone, so a failure is `StoppedPartway`, with
  nothing done: an error result (with its words, such as `Not logged in ·
  Please run /login`), `claude` exiting with no result, the time limit, a
  summarised conversation, a call to a tool not offered, or built-in tools
  at init (which is logged as an alarm). A cut-off reply is still `Ran`.
- **Ten minutes** at most, then the process is killed.
- The seat is chosen per call. Concurrent calls share its limits.

## Spares

Starting Claude Code can cost more than the call: on a VisionFive 2
(riscv64), Claude Code 2.1.112 on Node 20 takes about 14 s to answer a
stand-in API that replies at once. With `spares: n` the driver starts the
next `claude` before its call arrives and leaves it waiting on stdin, so the
call only writes its messages.

- **A spare is one call's `claude`**, with its own home and config, used
  once and deleted, as a call started on demand would be. One long-lived
  session for every caller would carry each call's turns into the next.
- **It belongs to one sign-in, model, system prompt and set of tools**,
  since all four are fixed when `claude` starts. After a call, a spare is
  started for its four; `n` is how many such combinations keep one, the
  least recently used dropped first. The first call of a combination
  starts `claude` as usual.
- **It serves any call of its combination**, earlier turns and all, since
  the turns are written to it like any call's.
- **A spare is ended, not used,** once it is older than `spareLifetime`
  (30 minutes by default) or when it has exited. `close()` ends every
  spare and deletes its folder.
- **The token waits with it.** A spare holds the seat's token in its
  environment the way a running call does, in a folder only the driver's
  user can enter.

Measured on the VisionFive 2 through this driver, against a stand-in API
that answers at once or after 3 s:

| | API | first call | with a spare |
|---|---|---|---|
| Node 20 | at once | 14.0 s | 0.9–1.5 s |
| Node 20 | 3 s | 16.6 s | 3.8 s |
| Node 24 `--no-sparkplug`, warm compile cache | at once | 7.8 s | 1.1 s |
| Node 24 `--no-sparkplug`, warm compile cache | 3 s | 10.7 s | 4.1 s |

A call's replacement spare starts while the call runs, and the two share
the board's cores: a `claude` left waiting with nothing else running took
0.5–0.75 s from message to result.

## Live sessions

A loop asks for each step of a trajectory with the whole history again.
With `liveSessions: n` the driver keeps the `claude` that answered a step
running, and writes the next step into it as only its new turns, so no step
after the first starts Claude Code.

- **Only an exact continuation continues.** A call goes to an idle session
  when it has the session's sign-in, model, system prompt and tools, and
  its turns are exactly the turns the session holds, then the session's
  own reply, then one or more turns the person said. Those go in as one
  message, a text block each, so the model answers once. Anything else, an
  edited turn or a missing reply, starts afresh on its whole history, as
  without sessions. So the model only ever reads the approved turns,
  compared byte for byte.
- **Kept only after a whole reply.** A cut-off reply comes back from a loop
  with a note added, a proposal of tools ends with `claude` killed, and a
  failed call adds no reply at all, so after any of them the `claude` is
  ended.
- **Never summarised.** By default Claude Code summarises a full context
  into a new conversation and answers from that, reporting success. With
  `DISABLE_AUTO_COMPACT=1` it refuses instead (`Prompt is too long`), and a
  `compact_boundary` event stops the call all the same.
- At most `n` sessions wait, the least recently used ended first; one idle
  for `sessionLifetime` (30 minutes) is ended. Each holds the seat's token
  as a spare does.

Through this driver on the VisionFive 2, Claude Code 2.1.112, a stand-in API
that answers after 3 s: a trajectory's first step 16.9 s on Node 20 (11.0 s
on Node 24 with a warm compile cache), each step after it 3.1–3.2 s.

## Claude Code 2.1.112

No native Claude Code is built for riscv64. 2.1.112 is its last release in
plain JavaScript (`cli.js`), which runs on any Node, and the driver accepts
it alongside 2.1.311 and later; `ClaudeCodeFlags` names what each accepts.
It has no `--safe-mode` or `--restricted`, so the driver leaves both out.
With the rest, a check that planted a CLAUDE.md, `CLAUDE.local.md`,
`.claude/CLAUDE.md`, skills, agents, commands, an output style,
`settings.json` env and hooks, and an `.mcp.json` in the working directory
and its parent found none of them loaded or run, where without those flags
every one did.

Two things it does differently, both handled: it counts the messages so
far in an acknowledgement's `num_turns` where 2.1.326 says 0, and it asks
permission for a tool after the model's message ends rather than as it
streams.

Node 24 from unofficial-builds crashes in Sparkplug on riscv64 unless
started with `--no-sparkplug`, which `NODE_OPTIONS` refuses, and a compile
cache only helps in a folder that outlives a call's home. Both belong in
the `claude` the host gives the driver:

```sh
#!/bin/sh
# --no-sparkplug: Node v24.22.0 and later crash in Sparkplug on riscv64
# (https://github.com/nodejs/unofficial-builds/issues/253). It can go once a
# v24 build carries V8 ec2f506f; until then it is harmless.
NODE_COMPILE_CACHE=/var/cache/claude-code-driver/node exec \
  /opt/node/bin/node --no-sparkplug /opt/claude-code-2.1.112/cli.js "$@"
```

## Sign-ins

`Credential.load(directory)` reads every file in `directory`, one per model
sign-in, each named for it: the layout of systemd's `LoadCredential=` in
`$CREDENTIALS_DIRECTORY`. A file is exactly:

```json
{"kind": "claude-code-setup-token", "token": "<108 characters from claude setup-token>"}
```

Any other shape stops the service at start, naming what is wrong but never
the token.

## Running as its own service

```
CLAUDE_CODE_DRIVER_SOCKET=/run/intersyntactic-claude-code-driver/claude-code-driver.sock \
  CLAUDE_CODE_DRIVER_CALLER=airlock \
  CLAUDE_CODE_DRIVER_CLAUDE=/usr/bin/claude \
  CLAUDE_CODE_DRIVER_SPARES=1 \
  dart run is_claude_code_driver:service   # CREDENTIALS_DIRECTORY from LoadCredential=
```

`CLAUDE_CODE_DRIVER_CLAUDE` is optional (`claude` on `PATH`), and so is
`CLAUDE_CODE_DRIVER_SPARES` (0, none). At start the service checks
`claude --version` is 2.1.311 or later, or 2.1.112, loads the sign-ins, and
prints one line:

```
listening on <socket> for <caller>, claude <version>, model sign-ins: <names>, spares: <n>
```

Any configuration it cannot start with exits 78. SIGTERM and SIGINT close it
cleanly.

The service reads who is calling from the socket as the kernel reports it
(`SO_PEERCRED`) and closes any other user's connection unanswered. A caller
writes one call and closes its side; the service answers JSON lines and
closes:

```
→ {"signIn":"nick-claude-team","model":"claude-opus-5-5","systemPrompt":"…","request":"…"}
← {"kind":"reported","progress":{"kind":"replyArriving","text":"…"}}   (any number)
← {"kind":"finished","outcome":{"kind":"ran","output":"<the reply>"}}
← {"kind":"finished","outcome":{"kind":"nothingRan","why":"…"}}
← {"kind":"finished","outcome":{"kind":"stoppedPartway","why":"…","done":null}}
```

`{}` is a probe that never reaches the model:

```
← {"kind":"finished","outcome":{"kind":"nothingRan","why":"not a call: modelCall.signIn: not a string"}}
```
