# Changelog

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
