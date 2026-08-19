# Contributor instructions

## Architecture boundaries

- `bin/agent-notify` is the event entry point; `lib/agent-notify/` owns normalization, state transitions, Keychain reads, diagnostics, and Pushover delivery.
- `integrations/claude/` and `integrations/opencode/` only adapt host events to the normalized event contract. Keep them advisory: failures must not affect the host agent.
- `installer/` owns staging, Keychain v2 writes, managed plugin generation, Claude settings merge, backups, manifests, and selective rollback. Do not move installer policy into integrations.

## Secrets and privacy

- Never commit, print, log, fixture, or pass Pushover credentials through argv, environment variables, or files. Credentials enter on stdin and belong only in the macOS Keychain.
- Do not expose raw event payloads, session/request IDs, full directories, Keychain service metadata, or Pushover response bodies in diagnostics.
- Preserve the v2 generation/selector model. Old v1 Keychain items must never be read, changed, or removed.

## macOS and JXA rules

- This is macOS software: use fixed macOS system paths and built-ins already used by the project (`zsh`, `osascript` JXA, Security.framework/`security`, `curl`, BSD tools).
- Use JXA/Foundation for JSON parsing, settings transforms, and Keychain APIs; do not add `jq`, Python, Node, npm packages, or other runtime dependencies for those jobs.
- Keep JXA input validation strict and output limited to the normalized, non-secret contract.

## Installer and global-config safety

- Run `bin/agent-notify-install --dry-run` before an install path change. Preserve preflight validation, atomic staging, backups, permissions, hashes, conflict prompts, and selective rollback.
- Only add/remove commands owned by the installer prefix in `~/.claude/settings.json`; preserve unrelated hooks and refuse malformed or concurrently changed settings.
- Never silently overwrite an unmanaged OpenCode plugin, settings file, binary, library tree, or user change. Do not modify real home-directory configuration while developing or testing.

## Tests

Run from the repository root on macOS:

```zsh
zsh tests/notifier/test_notifier.zsh
zsh tests/claude/agent-notify-hook.test.zsh
zsh tests/installer/test_installer.zsh
node --test tests/opencode/agent-notify.test.js
```

Tests must use `mktemp` fixtures, injected paths/helpers, and Keychain shims. Do not edit generated files (including `.opencode/node_modules/`) or live-home files to make a test pass.

## OpenSpec workflow

For non-trivial behavior changes, start with `/opsx-propose <change>` and complete the generated proposal, design, and tasks artifacts before `/opsx-apply`. During implementation, read the change context returned by OpenSpec and check off tasks as completed. Before archiving, run `/opsx-verify`, use `/opsx-sync` for delta specifications when applicable, then `/opsx-archive`. Do not edit existing OpenSpec artifacts unless the active workflow calls for it.
