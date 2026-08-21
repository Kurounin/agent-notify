# agent-notify

`agent-notify` sends advisory [Pushover](https://pushover.net/) notifications for the main-agent lifecycle in Claude Code and OpenCode on macOS. It reports when a turn needs attention, completes after a minimum runtime, or fails. Notifications carry the source application, project-directory basename, normalized state, and—unless you turn them off—a bounded single-line excerpt of the agent's final message. Prompts, thinking and reasoning, tool input and output, subagent output, session IDs, request IDs, and credentials are never sent.

It is not an agent runner, telemetry collector, or remote-control service. The only network request is an HTTPS POST to Pushover's `api.pushover.net`; delivery failures never affect Claude Code or OpenCode execution.

## Compatibility and prerequisites

The installer validates these tested ranges before changing anything:

- macOS 13 through 26
- Claude Code `>= 1.0.0, < 3.0.0`
- OpenCode `>= 1.0.0, < 2.0.0`

Install both `claude` and `opencode` so they are executable on `PATH`, and have a Pushover user key and application token ready. The project uses macOS built-ins: `/bin/zsh`, `/usr/bin/osascript` (JXA), `/usr/bin/security`, `/usr/bin/curl`, `shasum`, and standard BSD file utilities. No npm install is required for the runtime integration.

Check the exact policy in the checked-out version:

```zsh
bin/agent-notify supported-versions
```

## Install, update, smoke test, and rollback

From a trusted checkout:

```zsh
# Review targets and compatibility; does not collect credentials or write files.
bin/agent-notify-install --dry-run

# Confirm the plan, then enter the Pushover user key and app token on the TTY.
bin/agent-notify-install

# Send one real Pushover notification (bounded by a 30-second watchdog).
~/.local/bin/agent-notify smoke-test
```

To update, use a newer trusted checkout and rerun the installer. It recognizes exact installer-managed artifacts; conflicts require confirmation and are not silently overwritten.

```zsh
bin/agent-notify-install

# Selectively restore the backup from the most recent installation.
# The command asks whether to remove the v2 Pushover credentials as well.
bin/agent-notify-install --rollback
```

The installer writes the notifier and Claude adapter to `~/.local/bin`, the library to `~/.local/lib/agent-notify`, the OpenCode plugin to `~/.config/opencode/plugins/agent-notify.js`, and managed hook entries to `~/.claude/settings.json`. Backups and an install manifest live under `~/Library/Application Support/agent-notify/`. Rollback restores only artifacts whose hashes still match the installed version; it leaves externally changed files in place and tells you what must be removed manually.

## Privacy and credentials

Pushover credentials are entered only through the terminal, passed to the Keychain helper on standard input, and stored in the macOS Keychain. They are not placed in command arguments, environment variables, settings files, state files, diagnostics, or installer output.

The current Keychain layout is **v2**: a non-secret active-generation selector and generation-specific user-key and app-token items. Installing v2 asks for new credentials and does not read, alter, or delete any old v1 Keychain items; legacy items are preserved. Reinstalls create a new v2 generation before switching the selector, then retire the prior v2 generation after a successful install.

Local state is keyed by a hash of source and session ID, with user-only permissions. Sanitized diagnostics record only timestamp, component, code, HTTP status, and a safe Pushover request ID; they do not contain event payloads, paths, Keychain metadata, excerpt text, or secrets.

Message excerpts are the one place where content leaves the machine. Completions carry the tail of the agent's final message and failures carry an error identifier, sanitized to a single line and bounded to roughly 200 characters. Whatever the agent wrote in that message can travel with it—paths under `$HOME`, repository and branch names, commands quoted in prose, and any secret the model repeated back—so they reach Pushover's servers and your device's lock screen. Excerpts are enabled by default; set `EXCERPT=0` in `~/Library/Application Support/agent-notify/settings.conf` to disable them. The file is created at install time, is never overwritten by a reinstall, and is re-read per notification, so a change takes effect without restarting anything.

## How integrations behave

- **Claude Code:** installer-managed hooks normalize `UserPromptSubmit`, supported permission/elicitation notifications, `Stop`, and `StopFailure`. Background and subagent events are ignored.
- **OpenCode:** the managed plugin translates busy/idle lifecycle events, selected terminal errors, and the legacy permission/question attention family. Its notifier subprocess has a ten-second outer timeout, allowing the notifier's five-second delivery timeout to complete. When a root's completion is held until its background sessions settle and the root never speaks again, its excerpt is the last thing the root said—which predates that background work. That staleness is accepted rather than dropping the excerpt on exactly the long turns where a notification is most useful.
- **Notifier core:** attention is deduplicated and debounced, completions require the configured minimum runtime (30 seconds by default), and delivery is best-effort. State is serialized per session.

## Repository layout

```text
bin/           notifier and transactional installer entry points
lib/           normalized-event, state, Keychain, delivery, and version logic
integrations/  source adapters for Claude Code and OpenCode
installer/     JXA helpers for Keychain, settings merge, manifest, and plugin staging
tests/         isolated macOS shell/JXA and Node test suites
openspec/      change proposals, design, tasks, and capability specifications
```

## Tests

Run these from the repository root on macOS. Shell tests create temporary homes and use Keychain shims; they do not use or modify your live home directory or Keychain.

```zsh
zsh tests/notifier/test_notifier.zsh
zsh tests/claude/agent-notify-hook.test.zsh
zsh tests/installer/test_installer.zsh
node --test tests/opencode/agent-notify.test.js
```

## Security and reporting

Treat Pushover user keys and application tokens as secrets. Do not include them—or raw hook payloads, session IDs, request IDs, full paths, Keychain dumps, or diagnostic files—in issues, test fixtures, commits, or logs. For a suspected security issue, report it privately to the repository maintainer with a minimal redacted reproduction; do not publish proof-of-concept credentials or sensitive traces in a public issue.
