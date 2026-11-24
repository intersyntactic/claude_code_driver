# is_claude_code_driver

intersyntactic's Claude Code driver: a service on a Unix socket that
answers a model call by running `claude -p` under a Claude Code seat. Agent loops hold no model credential
and have no network; they propose a call, the airlock decides it, and this
driver is the only piece that reaches Anthropic.

It is named for what it runs: the Claude Code agent, with its own tools,
config dir and a seat licensed to one person. A call by API key would be a
driver of its own.

## No tool ever runs

`claude -p` is an agent with built-in tools. Three walls keep every one of
them off, each enough on its own:

1. **`--tools ""`**: the model is offered no tool. Asked to run `ls /`, it
   writes the call out as text and nothing runs.
2. **`--restricted`**: removes the tools that run code (Bash and the rest)
   and WebFetch unless `--tools` names them, so a later Claude Code that
   reads `--tools ""` differently still has none of those. Claude Code
   2.1.112 has no such flag (see [Claude Code 2.1.112](#claude-code-21112)).
3. **The init check**: `claude` prints a `system`/`init` event listing the
   tools it offers before any model turn. The driver kills the process and
   refuses unless that list is empty, unless nothing but Claude Code's own
   `system` notices comes before it, and unless it lists its tools at all.
   (2.1.323 prints a `system`/`ui_invalidate` notice before `init`.)

The rest take away what a user's settings would load: `--safe-mode` (hooks,
skills, installed plugins, MCP servers; `--setting-sources ""` alone still
ran SessionStart hooks), `--strict-mcp-config`, `--setting-sources ""`,
`--disable-slash-commands`, and `--no-session-persistence` (no transcript).
Built-in plugins still load, since safe mode cannot turn those off; none
runs a hook, and their agents cannot start without the Agent tool. Never
`--bare`: it reads only `ANTHROPIC_API_KEY`, never a seat.
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` in its environment takes away
requests a call does not ask for, such as 2.1.112's session title, which
sends the prompt to another model.

The full command, from `ClaudeCodeDriver.arguments`:

```
claude -p --tools "" --restricted --safe-mode --strict-mcp-config \
  --setting-sources "" --disable-slash-commands --no-session-persistence \
  --input-format stream-json --output-format stream-json --verbose \
  --include-partial-messages --model <model> --system-prompt-file ../system-prompt
```

The request goes to stdin as one stream-json user message, and stdin
closes. A text prompt would do as well for a call started on demand, but a
[spare](#spares) waits before its message arrives, and in text mode Claude
Code gives up on stdin after 3 s.

It is the same for every call to a model: the system prompt's file sits
beside the call's empty working directory, named by a relative path that
claude resolves there. So what the airlock approves is `model`,
`systemPrompt` and `request`, each passed verbatim, and the rest of the
command line is a constant of this driver's commit.

With exactly this command line, claude 2.1.311 printed four events: `init`
(`"tools":[]`, `"mcp_servers":[]`, `"skills":[]`, `"slash_commands":[]`, and
three built-in plugins), `status`, `assistant` and `result`. There were no
hook events.

## One call

- **A fresh place per call.** `HOME`, `CLAUDE_CONFIG_DIR` and the working
  directory are new empty directories, deleted afterwards, so no login,
  transcript or setting outlives a call or is shared between concurrent
  ones.
- **Nothing of the driver's own environment** but `PATH`. The seat's token
  goes in as `CLAUDE_CODE_OAUTH_TOKEN`, readable only by the driver's user.
- **The approved bytes, verbatim.** `systemPrompt` goes to
  `--system-prompt-file` as the UTF-8 encoding of the string. The system
  prompt is a file rather than an argument, since an argument is visible to
  every user in `ps` and Linux caps one at 128 KiB.
- **The request is an input array of turns**, the shape every model driver
  reads, so the airlock can switch drivers by socket path alone:
  `[{"role":"user","content":"…"},{"role":"assistant","content":"…"}]`,
  oldest first, never empty, no system turn. Claude Code takes one text
  message per call and no earlier assistant turns, so the driver flattens
  the turns into one line each, `User: …` or `Agent: …`, joined with `\n`,
  and that text is the message's content. Each turn's content goes exactly
  as sent.
  Anything else, JSON or not, is refused before `claude` starts. No turn
  names a model, so
  `AsksTheModel`'s rule, that a model named in the request must be the
  decided one, holds by construction: only `--model` chooses one.
- **Nothing trimmed or re-encoded.** A test hands the driver whitespace at
  both ends, CRLF, a BOM, a NUL and non-ASCII, and checks that what
  `claude` reads equals each string. Run against a stand-in Messages API,
  Claude Code 2.1.323 and 2.1.112 both sent such a message on to the API
  byte for byte.
- **The logbook holds what was given to `claude -p`**, not the exact wire to
  Anthropic: Claude Code may add context of its own.
- **Streaming.** Each text delta is reported as `ReplyArriving`; the
  `result` event's text is the `ModelReply`: a `CutOffReply` when its
  `stop_reason` is `max_tokens` or `model_context_window_exceeded`, a
  `FinishedReply` otherwise. A result with `is_error` is `Refused` with its
  words, such as `Not logged in · Please run /login`.
- **Usage.** The reply's `ModelUsage` is the last model call of the run
  (the last of `usage.iterations`, or the run's totals when none is
  listed), so its `context` is how full the context was at the end.
  `contextWindow` comes from `modelUsage` for the model asked for. Claude
  Code's own context counts, since the model read it. A result with no
  readable usage gives none.
- **Ten minutes** at most, then the process is killed.
- The seat is chosen per call. Concurrent calls share its limits.

## Spares

Starting Claude Code can cost more than the call: on a VisionFive 2
(riscv64), Claude Code 2.1.112 on Node 20 takes about 14 s to answer a
stand-in API that replies at once. With `spares: n` the driver starts the
next `claude` before its call arrives and leaves it waiting on stdin, so the
call only writes its message.

- **A spare is one call's `claude`**, with its own home, config and working
  directory, used once and deleted, as a call started on demand would be.
  One long-lived session for every caller would carry each call's turns
  into the next.
- **It belongs to one sign-in, model and system prompt**, since all three
  are fixed when `claude` starts. After a call, a spare is started for its
  three; `n` is how many such combinations keep one, the least recently
  used dropped first. The first call of a combination starts `claude` as
  usual.
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
after the first starts Claude Code, and the model reads real user and
assistant turns rather than one flattened transcript.

- **Only an exact continuation continues.** A call goes to an idle session
  when it has the session's sign-in, model and system prompt, and its turns
  are exactly the turns the session holds, then the session's own reply,
  then one or more user turns. Those go in as one message, a text block
  each, so the model answers once. Anything else, an edited turn, a missing
  reply, a call with no new user turn, starts afresh with the whole history
  flattened, as without sessions. So the model only ever reads the
  approved turns, compared byte for byte.
- **Kept only after a whole reply.** A cut-off reply comes back from a loop
  with a note added, and a refused call adds no reply at all, so after
  either the `claude` is ended.
- **Never summarised.** By default Claude Code summarises a full context
  into a new conversation and answers from that, reporting success. With
  `DISABLE_AUTO_COMPACT=1` it refuses instead (`Prompt is too long`), and a
  `compact_boundary` event is refused all the same.
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

Node 24 from unofficial-builds crashes in Sparkplug on riscv64 unless
started with `--no-sparkplug`, which `NODE_OPTIONS` refuses, and a compile
cache only helps in a folder that outlives a call's home. Both belong in
the `claude` the host gives the driver:

```sh
#!/bin/sh
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
← {"kind":"finished","outcome":{"kind":"refused","why":"…"}}
```

`{}` is a probe that never reaches the model:

```
← {"kind":"finished","outcome":{"kind":"refused","why":"not a call: modelCall.signIn: not a string"}}
```