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
The system SHALL retrieve the Pushover user key and application token from the logged-in user's macOS Keychain and deliver messages only to Pushover's fixed HTTPS endpoint with TLS verification, redirects disabled, a five-second total timeout, and no retries. It SHALL send only the agent name, a sanitized and length-bounded basename of the session directory, a normalized state message, and — when excerpts are enabled and an excerpt is available — a sanitized, single-line, length-bounded excerpt of the agent's final message text. It SHALL use normal priority for completion, attention, and agent-error notifications. Adapter values SHALL be treated as untrusted data and SHALL NOT alter transport options, destination, or request structure.

#### Scenario: A permission request requires action
- **WHEN** an adapter submits an `attention` event with a session directory
- **THEN** the system SHALL deliver a normal-priority notification titled with the agent and project basename and a message indicating that attention is required

#### Scenario: A completion is eligible for delivery
- **WHEN** a `completed` event passes the suppression rules
- **THEN** the system SHALL deliver a normal-priority notification indicating that the turn is complete

### Requirement: Carry an optional message excerpt on the normalized event
The normalized lifecycle event contract SHALL accept an optional excerpt field alongside its existing fields. The system SHALL validate the excerpt independently of the rest of the event: an excerpt that is absent, empty, oversized, or otherwise invalid SHALL be discarded on its own and SHALL NOT invalidate, delay, or discard the event that carried it. The excerpt SHALL be preserved across every normalization and re-encoding stage between adapter submission and delivery, and SHALL NOT be written to session state or diagnostic logs.

#### Scenario: An event carries an invalid excerpt
- **WHEN** an adapter submits a lifecycle event whose excerpt field is oversized or contains disallowed characters
- **THEN** the system SHALL process the event normally without the excerpt and SHALL deliver the existing normalized state message

#### Scenario: An event carries no excerpt
- **WHEN** an adapter submits a lifecycle event with no excerpt field
- **THEN** the system SHALL process and deliver it exactly as it did before excerpts were introduced

#### Scenario: An adapter payload would exceed its transport bound
- **WHEN** including the excerpt would push an adapter's encoded event past its maximum payload size
- **THEN** the adapter SHALL submit the event without the excerpt rather than discarding the event

#### Scenario: A delivery attempt fails
- **WHEN** delivery of a notification carrying an excerpt fails at any stage
- **THEN** the recorded state and diagnostics SHALL contain no excerpt text

### Requirement: Include a bounded excerpt of the agent's final message
For `completed` and `failed` events, the system SHALL include the excerpt in the delivered Pushover message when excerpts are enabled and an excerpt is available, leading with the normalized state message so the event kind remains distinguishable. The excerpt SHALL be produced by the adapter, never by the notifier. It SHALL be reduced to a single line with line breaks, control characters, C1 characters, bidirectional-formatting characters, and zero-width characters removed or replaced by spaces. It SHALL be bounded simultaneously by grapheme count, UTF-16 code units, and UTF-8 bytes, SHALL be taken from the END of the source text, and SHALL carry an explicit leading truncation marker when any text was dropped. Truncation SHALL NOT split a grapheme cluster. Adapters SHALL produce identical output for identical source text.

The Claude Code adapter SHALL read the `completed` excerpt only from the hook payload's final-assistant-message field, SHALL NOT read the transcript file, and SHALL NOT read any other payload field for excerpt purposes. For `failed` it SHALL use the payload's categorical error identifier and SHALL NOT use the payload's free-text error detail field.

The OpenCode adapter SHALL read the `completed` excerpt from the messages of the session it is reporting completion for — the root session, never a descendant — selecting the most recent assistant message and, within it, text parts only, excluding parts marked synthetic or ignored and excluding reasoning parts. For `failed` it SHALL use the terminal error's message when the error carries one and the error name otherwise. Failure to resolve session messages SHALL be treated as no excerpt available.

An adapter that supplies no excerpt SHALL continue to deliver the existing normalized state message.

#### Scenario: A completion carries the tail of the agent's final message
- **WHEN** a `completed` event passes the suppression rules and its adapter supplied an excerpt
- **THEN** the system SHALL deliver a notification whose message leads with the turn-complete state and continues with that excerpt

#### Scenario: The agent's final message is unavailable or empty
- **WHEN** the host agent reports a completion with no final message text, or with text that sanitizes to nothing
- **THEN** the adapter SHALL submit the event without an excerpt and the system SHALL deliver the existing normalized state message

#### Scenario: The final message is multi-line and oversized
- **WHEN** the agent's final message spans multiple lines and exceeds the excerpt bounds
- **THEN** the delivered message SHALL contain one sanitized bounded line ending at the source text's end and marked as truncated, and the notification SHALL NOT be dropped

#### Scenario: A turn fails
- **WHEN** an adapter submits a `failed` event
- **THEN** the delivered message SHALL lead with the agent-error state and continue with that adapter's error identifier or message, and the Claude Code adapter SHALL NOT use the payload's free-text error detail

#### Scenario: An OpenCode root completes with descendant sessions in its tree
- **WHEN** the OpenCode adapter submits a `completed` event for a root session whose tree contains descendant sessions
- **THEN** the excerpt SHALL come from the root session's messages and SHALL NOT come from any descendant session's messages

#### Scenario: A deferred OpenCode root completion carries its last message
- **WHEN** an OpenCode root completion was deferred until its descendants settled and the root produced no further assistant message before completing
- **THEN** the system SHALL deliver the root's most recent assistant text as the excerpt, even though it predates the background work, and SHALL NOT suppress the excerpt for that turn

#### Scenario: OpenCode session messages cannot be resolved
- **WHEN** the OpenCode adapter cannot retrieve messages for the session it is reporting completion for
- **THEN** it SHALL submit the event without an excerpt and SHALL return success to OpenCode

#### Scenario: The host agent does not expose a final message field
- **WHEN** the installed host agent version omits the final-assistant-message field from its completion payload
- **THEN** the adapter SHALL submit the event without an excerpt rather than failing, and the system SHALL deliver the existing normalized state message

#### Scenario: An attention notification is delivered
- **WHEN** an `attention` event is delivered
- **THEN** its message SHALL be the existing attention state message with no excerpt

### Requirement: Enable excerpts by default with a documented opt-out
The system SHALL enable message excerpts by default and SHALL provide a user-editable setting that disables them without reinstalling. The setting SHALL be readable by every adapter that produces excerpts and SHALL be re-read often enough that a change takes effect without restarting the notifier or the host agent. When excerpts are disabled, an adapter that would need to request the agent's message text from its host SHALL NOT issue that request, and an adapter whose host supplies the text unsolicited SHALL NOT forward it. Disabling excerpts SHALL leave all other notification behavior unchanged. A malformed or unreadable setting SHALL leave excerpts enabled.

#### Scenario: Excerpts are disabled
- **WHEN** the user sets the excerpt setting to disabled and a `completed` event is delivered
- **THEN** the delivered message SHALL be the existing normalized state message with no excerpt, and the adapter SHALL NOT forward the agent's message text

#### Scenario: Excerpts are disabled in a running OpenCode session
- **WHEN** the user disables excerpts while an OpenCode session is already running and that session later completes a turn
- **THEN** the adapter SHALL NOT request the session's messages for that completion, without requiring OpenCode to be restarted

#### Scenario: The setting is absent
- **WHEN** no excerpt setting exists
- **THEN** the system SHALL behave as if excerpts are enabled

#### Scenario: The setting file is malformed
- **WHEN** the excerpt setting cannot be parsed
- **THEN** the system SHALL leave excerpts enabled and SHALL NOT fail the notification

### Requirement: Fail open without exposing secrets
The system SHALL return success to adapter-invoked lifecycle processing when credential lookup, state handling, or Pushover delivery fails. It SHALL NOT write secrets, prompt content, assistant messages, tool input/output, source code, raw events, session identifiers, paths, Pushover request bodies, or third-party response bodies to state or diagnostic logs. It SHALL NOT place Pushover credentials in process arguments, environment variables, temporary files, or persistent curl configuration. State and diagnostic directories SHALL be user-only, and diagnostics SHALL contain only timestamp, component, categorical error code, HTTP status, and Pushover request identifier with bounded retention.

#### Scenario: Pushover is unavailable
- **WHEN** the Pushover request times out or returns an error
- **THEN** the system SHALL record only scrubbed diagnostic metadata locally and return success to the calling integration

#### Scenario: A user runs the smoke test
- **WHEN** the user explicitly invokes the notifier smoke-test command
- **THEN** it SHALL return nonzero with a sanitized diagnostic unless Pushover returns an HTTP success response with `status: 1`

### Requirement: Integrate supported Claude Code and OpenCode events
The system SHALL map Claude Code main-agent attention, completion, and failure hooks to normalized events. Claude attention SHALL be limited to `permission_prompt`, `elicitation_dialog`, and `elicitation_url_dialog`; all other notification types, including background-agent and subagent events, SHALL be ignored. Claude `began` events SHALL clear stale Claude attention; the adapter SHALL NOT claim a request-specific clear when Claude does not expose one. The OpenCode runtime module SHALL expose only its default plugin factory so supported OpenCode loaders can register it. The OpenCode adapter SHALL track `session.status` transitions, obtain event-session details through the plugin client, use one declared permission/question event family, and avoid treating the compatibility `session.idle` event as a second completion signal. The adapter SHALL treat session details without a parent identifier as a root session, because OpenCode omits that field entirely for roots. It SHALL submit `began` and `completed` only for root sessions; descendant sessions SHALL be tracked for root-tree settlement without emitting their own lifecycle events. For an OpenCode root session, the adapter SHALL defer a `completed` event until that root is idle and every known descendant session is settled. It SHALL re-evaluate a deferred root completion when a known descendant changes lifecycle state. While a root completion is deferred, the adapter SHALL NOT submit another `began` event for that root, so a turn resumed to consume background results keeps the start it was already recorded with. This root-tree decision SHALL be best effort, using only session relationships and lifecycle states the adapter has observed or resolved through the plugin client; if the adapter cannot resolve usable session details or a usable parent identifier, it SHALL preserve the existing per-session lifecycle behavior for that event. For a session-associated non-aborted terminal `session.error`, it SHALL emit one `failed` event, clear that session's busy and attention state, and suppress later completion; retry, recoverable, tool, user-abort, and session-less errors SHALL NOT emit `failed`.

#### Scenario: Claude Code requests permission
- **WHEN** Claude Code emits an eligible permission or input notification for a main-agent session
- **THEN** its hook SHALL submit an `attention` event without altering the permission decision

#### Scenario: OpenCode loads the adapter
- **WHEN** a supported OpenCode version loads the managed local plugin module
- **THEN** the module SHALL provide only its default plugin factory and OpenCode SHALL be able to register its event hook

#### Scenario: OpenCode reports session details without a parent identifier
- **WHEN** the plugin client returns usable session details that carry no parent identifier
- **THEN** the adapter SHALL treat that session as a root and apply root-tree deferral to it rather than the per-session fallback

#### Scenario: An OpenCode descendant session runs a background task
- **WHEN** a known descendant session reports `session.status` as busy and later idle
- **THEN** the adapter SHALL NOT submit `began` or `completed` for that descendant, and SHALL use its transitions only to settle its root

#### Scenario: OpenCode root transitions from busy to idle without an active known descendant
- **WHEN** an OpenCode root session previously observed as busy reports `session.status` as idle and every known descendant is settled
- **THEN** the adapter SHALL submit one `completed` event for that root and clear its active root-tree state

#### Scenario: An OpenCode root becomes idle while a known descendant is active
- **WHEN** an OpenCode root session reports `session.status` as idle while a known descendant reports `busy` or `retry`
- **THEN** the adapter SHALL defer the root `completed` event

#### Scenario: A finished descendant wakes a root whose completion is deferred
- **WHEN** an OpenCode root with a deferred completion reports `session.status` as busy again to consume background results
- **THEN** the adapter SHALL NOT submit another `began` event for that root, and SHALL submit one `completed` event once the root and its known descendants next settle

#### Scenario: The final known descendant settles after its root is idle
- **WHEN** an OpenCode root has a deferred completion and its final known active descendant reports `session.status` as idle
- **THEN** the adapter SHALL submit one `completed` event for the root without requiring another root idle event

#### Scenario: OpenCode session-tree metadata is unavailable
- **WHEN** the adapter cannot resolve usable parent or session metadata for an OpenCode lifecycle event
- **THEN** it SHALL process that event with the existing per-session lifecycle behavior and return success to OpenCode

#### Scenario: OpenCode reports a terminal session error
- **WHEN** OpenCode reports a session-associated non-aborted terminal error
- **THEN** the adapter SHALL submit one `failed` event and SHALL NOT submit a later completion for the same turn

### Requirement: Declare supported integration compatibility
The repository SHALL declare the tested macOS, Claude Code, and OpenCode version ranges and the exact OpenCode permission/question event family used. Before collecting credentials or performing any mutation, the installer SHALL verify the installed clients satisfy that policy and abort without changes for unsupported or unparseable versions.

#### Scenario: An installed client is unsupported
- **WHEN** the installer cannot verify a supported Claude Code or OpenCode version
- **THEN** it SHALL report the incompatibility and SHALL NOT collect credentials or modify the environment
