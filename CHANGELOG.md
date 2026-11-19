# Changelog

## 0.2.0

- `request` is a Responses API input array of `user` and `assistant` turns, flattened into `User: …` / `Agent: …` lines for `claude -p`. JSON of any other shape is refused before `claude` starts; text that is not JSON still goes as it is.

## 0.1.0

- `ClaudeCodeDriver`: `AsksTheModel` through `claude -p` with every built-in tool off, a fresh config per call, and a seat token per model sign-in.
- `ClaudeCodeDriverService` and `ClaudeCodeDriverSocket`: the driver as its own service, answering only the airlock's user.
