/// Asks the model through `claude -p` under a Claude Code seat, with every
/// built-in tool switched off. Holds each seat's token, so no loop or
/// logbook ever sees one.
library;

export 'src/claude_code_driver.dart' show ClaudeCodeDriver, ClaudeCodeFlags;
export 'src/credential.dart' show ClaudeCodeSetupToken, Credential;
