# agent-notify

`agent-notify` sends advisory [Pushover](https://pushover.net/) notifications for the main-agent lifecycle in Claude Code and OpenCode on macOS. It reports when a turn needs attention, completes after a minimum runtime, or fails; OpenCode child attention and failures remain independently observable. Pushover and downstream push services receive the source application, a sanitized and bounded display context (Claude tmux-or-project; OpenCode project-only), normalized state, and—unless you turn them off—an optional sanitized bounded single-line excerpt. Claude completion excerpts use final assistant output; Claude failure excerpts use the categorical error identifier, never free-text error detail. OpenCode completion excerpts use relevant root-session assistant text available through native context; OpenCode failure excerpts use structured error message when present or error type otherwise, never response bodies. Excerpts are sanitized and bounded: the selected source is sent in full when it already fits the bound and truncated when longer. Prompts, thinking and reasoning, tool input and output, subagent output, session IDs, request IDs, and credentials are not selected as excerpt sources, but model output or OpenCode error messages can repeat sensitive content such as secrets or paths.

It is not an agent runner, telemetry collector, or remote-control service. The only network request is an HTTPS POST to Pushover's `api.pushover.net`; delivery failures never affect Claude Code or OpenCode execution.

## Compatibility and prerequisites

The installer validates these supported ranges before collecting credentials or changing anything:

- macOS 13 through 27
- Claude Code `>= 1.0.0, < 3.0.0`
- OpenCode `>= 2.0.27, < 2.3.0` (native V2 only, including 2.2.1; V1 is no longer supported)

OpenCode **2.0.27 is the runtime-verified baseline**: isolated checks passed for generated-plugin loading, native subscription, unload/reload, and background-child and background-shell output consumption with one original root begin/completion per scenario. The expanded accepted range includes the 2.1 and 2.2 minor lines; it does not mean every accepted release was individually runtime-tested, or that observed-tree quiescence is a global timing guarantee. Preflight accepts complete numeric version tokens, including the normal `opencode v2.2.1` output and optional `v` prefix; extra components, prerelease/build suffixes, and malformed output are rejected rather than truncated to a supported prefix. macOS and Claude policy are unchanged.

Install both `claude` and `opencode` so they are executable on `PATH`, and have a Pushover user key and application token ready. The project uses macOS built-ins: `/bin/zsh`, `/usr/bin/osascript` (JXA), `/usr/bin/security`, `/usr/bin/curl`, `shasum`, and standard BSD file utilities. No npm install or tmux installation is required for the runtime integration.

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

To update, use a newer trusted checkout and rerun the installer (preview with `--dry-run` first). It recognizes exact installer-managed artifacts; conflicts require confirmation and are not silently overwritten. An exact manifest-owned V1 plugin is backed up and replaced at the same managed path, without leaving a second discoverable adapter. A marker alone does not authorize replacing an unmanaged or externally changed file.

```zsh
bin/agent-notify-install

# Selectively restore the backup from the most recent installation.
# The command asks whether to remove the v2 Pushover credentials as well.
bin/agent-notify-install --rollback
```

The installer writes the notifier and Claude adapter to `~/.local/bin`, the library to `~/.local/lib/agent-notify`, the single native OpenCode plugin to `~/.config/opencode/plugins/agent-notify.js`, and managed hook entries to `~/.claude/settings.json`. It does not edit unrelated OpenCode configuration or agent profiles. User-only backups live outside plugin discovery under `~/Library/Application Support/agent-notify/install-backups/`; the install manifest records owned paths and hashes. Rollback restores only artifacts whose hashes still match the installed version, including original bytes and modes; it leaves externally changed files in place and tells you what must be removed manually. A restored V1 plugin is **not compatible with OpenCode V2**: intentionally returning to OpenCode V1 also requires a prior compatible project release, not a widened V2 installer policy.

After updating, allow OpenCode configuration reload and verify that the `agent-notify` plugin is active. If reload does not activate the replacement, restart your own OpenCode service after checking its status; the installer does not restart it. Subscription events are live-only: reload/disconnect can miss events, and the plugin does not reconstruct or replay earlier turns.

## Privacy and credentials

Pushover credentials are entered only through the terminal, passed to the Keychain helper on standard input, and stored in the macOS Keychain. They are not placed in command arguments, environment variables, settings files, state files, diagnostics, or installer output.

The current Keychain layout is **v2**: a non-secret active-generation selector and generation-specific user-key and app-token items. Installing v2 asks for new credentials and does not read, alter, or delete any old v1 Keychain items; legacy items are preserved. Reinstalls create a new v2 generation before switching the selector, then retire the prior v2 generation after a successful install.

Local state is keyed by a hash of source and session ID, with user-only permissions. Sanitized diagnostics record only timestamp, component, code, HTTP status, and a safe Pushover request ID; they do not contain event payloads, paths, Keychain metadata, excerpt text, or secrets.

Pushover and downstream push services receive only the agent name, a sanitized and length-bounded display context, normalized state, and—when enabled and available—an optional sanitized bounded single-line excerpt. Claude uses the project-directory basename unless its optional bounded originating-pane tmux lookup succeeds, in which case it uses the pane's current innermost session name. Lookup failures fall back to project context. Tmux names are user-chosen and can be sensitive, so avoid sensitive names; sanitization limits formatting abuse but cannot determine whether a valid name is secret. **OpenCode always uses the resolved event-session directory's project basename**, not the plugin-instance directory or a shared server's inherited tmux environment. This V2 adapter does not discover originating panes or invoke tmux, even when server tmux variables or arbitrary session metadata claim a pane.

Claude completion excerpts use final assistant output, while Claude failure excerpts use the categorical error identifier rather than free-text error detail. OpenCode completion excerpts inspect at most the twelve most-recent native root-context entries, selecting the newest assistant's first non-empty text item in content order. They do not concatenate text items, fall back to an older assistant when the newest lacks text, or select reasoning, tools, synthetic child reports, system entries, or compaction summaries. A deferred completion can still use available root text predating child work. Context lookup has a one-second deadline; missing/failed lookup means no excerpt. The inspection limit is not a response-size limit. OpenCode failure excerpts use structured error message when present or error type otherwise, never response bodies. Excerpts are single-line, sanitized, bounded, and taken from the source's end with a leading truncation marker when needed; the source is sent in full when it fits. Model output or OpenCode error messages can still repeat sensitive content such as secrets or paths.

Excerpts are enabled by default; set `EXCERPT=0` in `~/Library/Application Support/agent-notify/settings.conf` to disable them. The file is created at install time, is never overwritten by a reinstall, and is re-read per notification, so a change takes effect without restarting anything. Disabled OpenCode excerpts do not request session context at all.

## How integrations behave

- **Claude Code:** installer-managed hooks normalize `UserPromptSubmit`, supported permission/elicitation notifications, `Stop`, and `StopFailure`. Background and subagent events are ignored.
- **OpenCode:** one dependency-free native default definition (`id: "agent-notify"`, `setup(ctx)`) starts a detached `ctx.event.subscribe` async subscription and returns cleanup without waiting for the stream. Only native `data` events are observed; V1 factories, `properties`, deprecated `session.idle`/`session.error`, legacy questions, and speculative aliases are not supported. Its notifier subprocess has a ten-second outer timeout, allowing the notifier's five-second delivery timeout to complete.
  - Native permissions and forms produce request-specific attention/clear events; replies/cancellations clear only their matching observed request. Non-session `global` forms are ignored. Form fields/answers are not forwarded, and the observer never replies or changes host decisions. Actionable retries produce deduplicated attention, not execution failure.
  - Parent relationships—not built-in/custom agent profile names or foreground/background mode—determine roots and children. One root turn retains its original start across child work, running shells, and automatic parent resumptions. Native execution success establishes local idle without requiring a separate status-idle event; completion still requires all known descendants settled, no outstanding observed root/child inbox work, no observed running shell in that session tree, and 50 ms quiescence. Inbox delivery requires a subsequent execution outcome; cancellation of unconsumed work can preserve prior success. Child success never emits a child completion; child failure does not automatically fail the root.
  - Native shell creation associates shells by originating session ancestry, not command text or working directory: unrelated sessions' shells do not block a root even in the same directory, while its own shells can run elsewhere. Matching shell exit/deletion releases the blocker and starts fresh quiescence once the tree is eligible; nonzero exit, timeout, or kill is not an agent failure. Session outcomes alone do not settle running shells. A deliberately long-running shell (such as a dev server) keeps completion pending for the observation lifetime, without a lifetime exemption; attention and failure reporting remain available. Tracking is live-only and in memory, with no polling or process inspection: starts before subscription, shells outside OpenCode's lifecycle, and missed events are not recovered.
  - Execution failures report the failing session once. Interruptions/deletions silently reset rather than push a failure/completion. Each genuinely new child execution silently resets only that child's prior notifier state before its attention/failure events, allowing reused children to fail again without restarting the root timer; duplicate activation does not reset it again.
  - Activation, relevant shell creation, admitted inbox work, terminal events, and location changes cancel stale completion candidates, including those waiting behind slow delivery. Bounded metadata lookups progress independently across verified trees while related events retain ingestion order; unresolved relationships remain conservative barriers. A departing location-scoped observer relinquishes a moved session instead of re-arming its old completion. Native directory/workspace identity is used only for ownership routing, never as a display fallback. Arrival does not replay missed turns or invent activation. Same-owner moves preserve earlier lifecycle inputs and necessary unsubmitted begin/reset controls in FIFO without replaying submitted controls.
  - Cleanup aborts observation, clears queued/timed work, and requests termination of owned subprocesses; already-submitted notifications cannot be retracted. Stream termination is not completion. Settlement is best effort for observed trees, not a guarantee for unseen work or independently moved descendants outside the observer's scope.
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

For the opt-in exact-2.0.27 native check on Apple Silicon macOS:

```sh
node tests/opencode/real-v2-smoke.mjs --download
```

This downloads a pinned official binary into a private temporary fixture, generates the managed artifact, and uses a private server plus a scripted loopback model without installing dependencies or touching the managed service. It refuses uncertain machine/ancestor isolation. See [`tests/opencode/real-v2-smoke.md`](tests/opencode/real-v2-smoke.md) for prerequisites, safety boundaries, evidence, and limitations.

## Security and reporting

Treat Pushover user keys and application tokens as secrets. Do not include them—or raw hook payloads, session IDs, request IDs, full paths, Keychain dumps, or diagnostic files—in issues, test fixtures, commits, or logs. For a suspected security issue, report it privately to the repository maintainer with a minimal redacted reproduction; do not publish proof-of-concept credentials or sensitive traces in a public issue.
