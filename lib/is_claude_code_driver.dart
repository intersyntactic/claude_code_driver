/// Asks the model through `claude -p` under a Claude Code seat, with every
/// built-in tool switched off. Holds each seat's token, so no loop or
/// record ever sees one.
library;

export 'src/claude_code_driver.dart' show ClaudeCodeDriver;
export 'src/credential.dart' show ClaudeCodeSetupToken, Credential;
