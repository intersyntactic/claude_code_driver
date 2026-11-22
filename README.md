# is_claude_code_driver

intersyntactic's Claude Code driver: the service that `AsksTheModel` (from
[is_effects](https://github.com/intersyntactic/effects)) by running
`claude -p` under a Claude Code seat. Agent loops hold no model credential
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
   reads `--tools ""` differently still has none of those.
3. **The init check**: `claude` prints a `system`/`init` event listing the
   tools it offers before any model turn. The driver kills the process and
   refuses unless that list is empty, unless it arrives first, and unless it
   lists its tools at all.

The rest take away what a user's settings would load: `--safe-mode` (hooks,
skills, installed plugins, MCP servers; `--setting-sources ""` alone still
ran SessionStart hooks), `--strict-mcp-config`, `--setting-sources ""`,
`--disable-slash-commands`, and `--no-session-persistence` (no transcript).
Built-in plugins still load, since safe mode cannot turn those off; none
runs a hook, and their agents cannot start without the Agent tool. Never
`--bare`: it reads only `ANTHROPIC_API_KEY`, never a seat.

The full command, from `ClaudeCodeDriver.arguments`:

```
claude -p --tools "" --restricted --safe-mode --strict-mcp-config \
  --setting-sources "" --disable-slash-commands --no-session-persistence \
  --input-format text --output-format stream-json --verbose \
  --include-partial-messages --model <model> --system-prompt-file ../system-prompt
```

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
  and that text goes to stdin. Each turn's content goes exactly as sent.
  Anything else, JSON or not, is refused before `claude` starts. No turn
  names a model, so
  `AsksTheModel`'s rule, that a model named in the request must be the
  decided one, holds by construction: only `--model` chooses one.
- **Nothing trimmed or re-encoded.** A test hands the driver whitespace at
  both ends, CRLF, a BOM, a NUL and non-ASCII, and checks that the bytes
  `claude` reads equal `utf8.encode` of each string.
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
  dart run is_claude_code_driver:service   # CREDENTIALS_DIRECTORY from LoadCredential=
```

`CLAUDE_CODE_DRIVER_CLAUDE` is optional (`claude` on `PATH`). At start the
service checks `claude --version` is at least 2.1.311, loads the sign-ins,
and prints one line:

```
listening on <socket> for <caller>, claude <version>, model sign-ins: <names>
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

The airlock side is `ClaudeCodeDriverSocket` from
`package:is_claude_code_driver/service.dart`. It `AsksTheModel` and holds no
secret.
