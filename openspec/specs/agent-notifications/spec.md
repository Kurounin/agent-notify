## Purpose

Define lifecycle notification behavior for supported agent integrations.

## Requirements

### Requirement: Normalize agent lifecycle events
The system SHALL accept normalized lifecycle events from Claude Code and OpenCode over standard input, associating each event with its agent source and session identifier. It SHALL recognize `began`, `attention`, `attention-cleared`, `completed`, `failed`, and `reset` event kinds. Attention events SHALL carry a stable request identifier when the source provides one; `attention-cleared` SHALL clear only its matching request, and `reset` SHALL clear state without sending a notification.

#### Scenario: A Claude Code hook reports a completion
- **WHEN** the Claude Code `Stop` hook submits a completion event for a main-agent session
- **THEN** the system SHALL process it as a `completed` event for that session

#### Scenario: An OpenCode session becomes busy
- **WHEN** the OpenCode adapter observes `session.status` with a `busy` status
- **THEN** the system SHALL process it as a `began` event for that session

#### Scenario: An OpenCode request is answered
- **WHEN** the OpenCode adapter observes a reply for an attention request
- **THEN** it SHALL submit an `attention-cleared` event with the same request identifier without resetting the active-turn timer

### Requirement: Suppress noisy and duplicate notifications per session
The system SHALL maintain short-lived local state keyed by a non-reversible derivative of the agent source and session identifier. It SHALL serialize each session's read, eligibility decision, delivery reservation, and state transition across notifier processes. It SHALL notify a completion only after a corresponding `began` event, suppress completions below the configured minimum runtime, and suppress repeated unresolved attention notifications during the configured debounce interval. A `completed` or `failed` event SHALL consume the active turn, be delivered at most once for that turn, and prevent a conflicting later terminal notification. Suppressed short completions SHALL also consume the active turn. General retention cleanup SHALL NOT remove active state before the documented maximum active lifetime.

#### Scenario: An idle event has no observed active work
- **WHEN** the OpenCode adapter observes an idle status for a session not marked busy
- **THEN** it SHALL NOT submit a completion notification

#### Scenario: A short agent turn completes
- **WHEN** a session completes before the configured minimum runtime
- **THEN** the system SHALL NOT deliver a completion notification and SHALL clear that active turn

#### Scenario: Two tabs run the same project
- **WHEN** two sessions from the same agent and project emit lifecycle events concurrently
- **THEN** the system SHALL track and suppress their notifications independently

#### Scenario: A failure is followed by an idle signal
- **WHEN** a session has already processed a terminal `failed` event for its active turn
- **THEN** the system SHALL NOT deliver a later completion notification for that turn

### Requirement: Deliver privacy-minimized Pushover messages
The system SHALL retrieve the Pushover user key and application token from the logged-in user's macOS Keychain and deliver messages only to Pushover's fixed HTTPS endpoint with TLS verification, redirects disabled, a five-second total timeout, and no retries. It SHALL send only the agent name, a sanitized and length-bounded basename of the session directory, and a normalized state message to Pushover. It SHALL use normal priority for completion, attention, and agent-error notifications. Adapter values SHALL be treated as untrusted data and SHALL NOT alter transport options, destination, or request structure.

#### Scenario: A permission request requires action
- **WHEN** an adapter submits an `attention` event with a session directory
- **THEN** the system SHALL deliver a normal-priority notification titled with the agent and project basename and a message indicating that attention is required

#### Scenario: A completion is eligible for delivery
- **WHEN** a `completed` event passes the suppression rules
- **THEN** the system SHALL deliver a normal-priority notification indicating that the turn is complete

### Requirement: Fail open without exposing secrets
The system SHALL return success to adapter-invoked lifecycle processing when credential lookup, state handling, or Pushover delivery fails. It SHALL NOT write secrets, prompt content, assistant messages, tool input/output, source code, raw events, session identifiers, paths, Pushover request bodies, or third-party response bodies to state or diagnostic logs. It SHALL NOT place Pushover credentials in process arguments, environment variables, temporary files, or persistent curl configuration. State and diagnostic directories SHALL be user-only, and diagnostics SHALL contain only timestamp, component, categorical error code, HTTP status, and Pushover request identifier with bounded retention.

#### Scenario: Pushover is unavailable
- **WHEN** the Pushover request times out or returns an error
- **THEN** the system SHALL record only scrubbed diagnostic metadata locally and return success to the calling integration

#### Scenario: A user runs the smoke test
- **WHEN** the user explicitly invokes the notifier smoke-test command
- **THEN** it SHALL return nonzero with a sanitized diagnostic unless Pushover returns an HTTP success response with `status: 1`

### Requirement: Integrate supported Claude Code and OpenCode events
The system SHALL map Claude Code main-agent attention, completion, and failure hooks to normalized events. Claude attention SHALL be limited to `permission_prompt`, `elicitation_dialog`, and `elicitation_url_dialog`; all other notification types, including background-agent and subagent events, SHALL be ignored. Claude `began` events SHALL clear stale Claude attention; the adapter SHALL NOT claim a request-specific clear when Claude does not expose one. The OpenCode adapter SHALL track `session.status` transitions, obtain event-session details through the plugin client, use one declared permission/question event family, and avoid treating the compatibility `session.idle` event as a second completion signal. For a session-associated non-aborted terminal `session.error`, it SHALL emit one `failed` event, clear that session's busy and attention state, and suppress later completion; retry, recoverable, tool, user-abort, and session-less errors SHALL NOT emit `failed`.

#### Scenario: Claude Code requests permission
- **WHEN** Claude Code emits an eligible permission or input notification for a main-agent session
- **THEN** its hook SHALL submit an `attention` event without altering the permission decision

#### Scenario: OpenCode transitions from busy to idle
- **WHEN** an OpenCode session previously observed as busy reports `session.status` as idle
- **THEN** the adapter SHALL submit one `completed` event and remove the session from its in-memory busy set

#### Scenario: OpenCode reports a terminal session error
- **WHEN** OpenCode reports a session-associated non-aborted terminal error
- **THEN** the adapter SHALL submit one `failed` event and SHALL NOT submit a later completion for the same turn

### Requirement: Declare supported integration compatibility
The repository SHALL declare the tested macOS, Claude Code, and OpenCode version ranges and the exact OpenCode permission/question event family used. Before collecting credentials or performing any mutation, the installer SHALL verify the installed clients satisfy that policy and abort without changes for unsupported or unparseable versions.

#### Scenario: An installed client is unsupported
- **WHEN** the installer cannot verify a supported Claude Code or OpenCode version
- **THEN** it SHALL report the incompatibility and SHALL NOT collect credentials or modify the environment
