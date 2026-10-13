## Purpose

Define lifecycle notification behavior for supported agent integrations.

## Requirements

### Requirement: Normalize agent lifecycle events
The system SHALL accept normalized lifecycle events from Claude Code and OpenCode over standard input, associating each event with its agent source and session identifier. It SHALL recognize `began`, `attention`, `attention-cleared`, `completed`, `failed`, and `reset` event kinds. Attention events SHALL carry a stable request identifier when the source provides one; `attention-cleared` SHALL clear only its matching request, and `reset` SHALL clear state without sending a notification. The OpenCode V2 adapter SHALL normalize validated native `data` payloads into this existing contract without forwarding raw host events.

#### Scenario: A Claude Code hook reports a completion
- **WHEN** the Claude Code `Stop` hook submits a completion event for a main-agent session
- **THEN** the system SHALL process it as a `completed` event for that session

#### Scenario: An OpenCode root execution begins
- **WHEN** the OpenCode adapter observes native `session.execution.started` or a corresponding busy status for a resolved root without an already-active or deferred turn
- **THEN** it SHALL submit one `began` event for that root

#### Scenario: An OpenCode request is answered
- **WHEN** the OpenCode adapter observes a reply for an attention request
- **THEN** it SHALL submit an `attention-cleared` event with the same request identifier without resetting the active-turn timer

#### Scenario: An OpenCode execution is interrupted
- **WHEN** native `session.execution.interrupted` identifies a valid session with usable directory context
- **THEN** the adapter SHALL submit `reset` for that session without an attention, failed, or completed notification for the interrupted execution

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

### Requirement: Preserve Claude session-start project context
The Claude Code adapter SHALL evaluate `CLAUDE_PROJECT_DIR`, then the hook payload's `session_dir`, `cwd`, and `directory` fields in that order, and SHALL use the first candidate that is a non-empty string of at most 256 UTF-16 code units containing no C0 or DEL control as the normalized session directory. It SHALL ignore the event only when none of those candidates is valid. A later change to the hook payload's current working directory SHALL NOT change the project fallback label while a valid session-start project root remains available.

#### Scenario: Claude changes its current working directory
- **WHEN** a Claude Code hook reports a current working directory different from the session-start `CLAUDE_PROJECT_DIR`
- **THEN** the adapter SHALL normalize `CLAUDE_PROJECT_DIR` as `session_dir` and, when no valid `tmux_session` is selected, the project fallback label SHALL remain the basename of that session-start root

#### Scenario: Claude project-root environment is unavailable or invalid
- **WHEN** a Claude Code command hook has no valid non-empty `CLAUDE_PROJECT_DIR`
- **THEN** the adapter SHALL use the first valid existing hook payload directory field and SHALL continue processing the event

#### Scenario: An earlier payload directory is invalid
- **WHEN** `CLAUDE_PROJECT_DIR` and an earlier payload directory candidate are invalid but a later payload directory candidate is valid
- **THEN** the adapter SHALL use the first valid later candidate and SHALL continue processing the event

### Requirement: Carry optional tmux session context
For `attention`, `completed`, and `failed` events only, the Claude Code adapter SHALL retain its existing originating-pane behavior and attempt to resolve the tmux session name only when `TMUX` is non-empty and `TMUX_PANE` matches `^%[0-9]{1,255}$`. The OpenCode V2 adapter SHALL always omit `tmux_session` and use the resolved event-session directory's existing project fallback; it SHALL NOT discover an originating pane, invoke tmux, or interpret inherited server environment or arbitrary session metadata as pane provenance. A permitted Claude lookup SHALL invoke the resolved tmux executable directly, without shell interpolation, as `tmux display-message -p -t <pane> #S`, with a hard 500 ms deadline, no retry, discarded stderr, and captured stdout capped at 1,024 bytes. On timeout or output overflow, it SHALL request child termination, omit `tmux_session`, and continue fail-open without accepting later output. Any launch, read, termination, nonzero-exit, decoding, or validation failure SHALL omit `tmux_session` without suppressing event processing or affecting the host agent.

An adapter SHALL accept a tmux result only when the command exits zero and its captured stdout is valid UTF-8 which, after removing at most one terminal LF, is a non-empty single line of at most 256 UTF-16 code units with no C0 or DEL controls. It SHALL attach only such a successful result to the normalized lifecycle event as the optional `tmux_session` field. The normalized-event boundary SHALL independently validate and length-bound that field; an absent, empty, oversized, or otherwise invalid tmux-session value SHALL be discarded without invalidating, delaying, or discarding the lifecycle event.

Neither accepted nor rejected raw tmux names, `TMUX` or `TMUX_PANE`, pane or socket values, executable paths, subprocess stdout or stderr, nor command errors SHALL enter state or diagnostics. Only the centrally sanitized, bounded selected display label SHALL enter the Pushover title.

#### Scenario: Strict environment gating
- **WHEN** the Claude command-hook environment has empty `TMUX` or `TMUX_PANE` does not match `^%[0-9]{1,255}$`
- **THEN** the adapter SHALL submit the lifecycle event without attempting tmux lookup and without a tmux-session field

#### Scenario: Agent runs in a named tmux session
- **WHEN** a Claude notification-producing event has strictly gated originating context and its pane-targeted tmux command exits zero with a valid session name
- **THEN** the adapter SHALL submit that name in the optional normalized tmux-session field

#### Scenario: Nonzero tmux exit has plausible stdout
- **WHEN** the pane-targeted tmux command emits otherwise plausible stdout but exits nonzero
- **THEN** the adapter SHALL submit the lifecycle event without a tmux-session field and SHALL return success to the host agent

#### Scenario: Tmux lookup times out or overflows
- **WHEN** the tmux lookup exceeds 500 ms or its stdout exceeds 1,024 bytes
- **THEN** the adapter SHALL request child termination, disregard later output, and submit the lifecycle event without a tmux-session field

#### Scenario: Tmux session output is invalid
- **WHEN** zero-exit tmux output is malformed UTF-8, empty, multiline, exceeds 256 UTF-16 code units, or contains C0 or DEL controls
- **THEN** the adapter SHALL submit the lifecycle event without a tmux-session field

#### Scenario: Tmux context is private
- **WHEN** tmux lookup accepts or rejects any environment value, pane value, executable path, stdout, stderr, or command error
- **THEN** none of those raw values SHALL enter state, diagnostics, or host-visible output; only a successful validated session name SHALL transiently populate the optional tmux-session field

#### Scenario: OpenCode shares a server between terminals
- **WHEN** an OpenCode event is received from a server shared between terminals, even if inherited tmux variables are valid or arbitrary session metadata contains a pane claim
- **THEN** the adapter SHALL NOT discover a pane or perform tmux lookup and SHALL submit the event with resolved project context and no tmux-session field

### Requirement: Keep notifier event processing live under abandoned housekeeping locks
The notifier SHALL process the current event before retention cleanup and SHALL treat cleanup as best-effort work that does not wait for a global prune lock or a locked session record. It SHALL rate-limit and batch full retention scans, SHALL rotate bounded passes so persistently locked records cannot permanently starve later records, and SHALL preserve the existing retention and maximum-active-age rules. Every lock mutation SHALL be restricted to a validated non-symlink lock directly under the canonical state directory.

Each acquired lock SHALL carry a unique ownership token. Stale-lock recovery SHALL derive a canonical recovery gate directly in that state directory, acquire a unique reaper token for that gate before the stale-lock snapshot, and use unique gate- or lock-quarantine containers as hard fences. Before and after moving a canonical gate or lock, recovery SHALL verify owned-container and moved-object identity, including the applicable inode and owner/reaper snapshot. A process SHALL NOT remove a replacement gate, quarantine, or lock with mismatched identity. Normal acquisition, callback execution, and owned-lock cleanup SHALL honor canonical gates and quarantine fences.

Recovery cleanup SHALL handle no more than one stale gate or quarantine per attempt. It SHALL preserve a valid live gate or quarantine reaper regardless of its age. A dead, ownerless, malformed, unreadable, or empty gate or quarantine container SHALL be recoverable only when its newest relevant filesystem metadata is older than the configured stale-lock interval. A valid lock owner remains authoritative while its process is live; absent or malformed lock ownership uses the same conservative age rule. These guarantees apply to cooperative `agent-notify` processes that treat owned unique quarantines as immutable.

The notifier SHALL serialize the current session's read, eligibility decision, delivery reservation, and state write, then SHALL release that session lock before Keychain access or Pushover transport.

#### Scenario: Retention encounters an ownerless stale lock
- **WHEN** best-effort retention cleanup encounters a lock with no valid owner metadata whose directory age exceeds the stale-lock interval
- **THEN** the notifier SHALL recover or skip that lock without delaying processing of the current event beyond the current-session lock bound

#### Scenario: Retention encounters a live session lock
- **WHEN** another notifier process holds valid live ownership of a session record during retention cleanup
- **THEN** cleanup SHALL skip that record without removing its lock or waiting for it, and current event processing SHALL continue

#### Scenario: Delivery is slow after reservation
- **WHEN** a notification delivery decision has been reserved and persisted for a session and Keychain or Pushover processing is slow
- **THEN** the notifier SHALL no longer hold that session's state lock and concurrent events SHALL still observe the persisted reservation

#### Scenario: A newly-created lock has not published its owner
- **WHEN** a lock directory has no readable valid owner metadata but is younger than the configured stale-lock interval
- **THEN** the notifier SHALL NOT remove it

#### Scenario: A live recovery gate is present
- **WHEN** a stale lock has a canonical recovery gate with a valid reaper whose process is live
- **THEN** recovery SHALL preserve the gate and SHALL NOT acquire the lock or invoke its callback

#### Scenario: A live quarantine is present
- **WHEN** a gate- or lock-quarantine has a stale or dead outer reaper but its contained gate or lock has valid live ownership
- **THEN** cleanup SHALL preserve that quarantine and normal lock acquisition SHALL remain fenced

#### Scenario: Canonical identity changes during recovery
- **WHEN** a canonical gate or lock is replaced after recovery validates it and before or during quarantine
- **THEN** recovery SHALL fail conservatively, preserve the replacement and relevant quarantine containers, and SHALL NOT invoke the lock callback

#### Scenario: A stale recovery fence is cleaned
- **WHEN** a dead, ownerless, malformed, unreadable, or empty recovery gate or quarantine has exceeded the stale-lock interval
- **THEN** one cleanup attempt SHALL remove only that stale fence, and a later attempt MAY recover the stale lock

#### Scenario: A contended prune prefix persists
- **WHEN** one bounded prune pass skips a full batch of persistently locked records
- **THEN** a later pass SHALL advance beyond that batch and inspect eligible later records

### Requirement: Deliver privacy-minimized Pushover messages
The system SHALL retrieve the Pushover user key and application token from the logged-in user's macOS Keychain and deliver messages only to Pushover's fixed HTTPS endpoint with TLS verification, redirects disabled, a five-second total timeout, and no retries. Pushover and downstream push services SHALL receive only the agent name; a sanitized, length-bounded display context consisting of the valid tmux session name when one is available or otherwise the basename of the session directory; a normalized state message; and — when excerpts are enabled and an excerpt is available — a sanitized, bounded single-line excerpt. Claude completion excerpts SHALL be sourced only from final assistant output, while Claude failure excerpts SHALL use the categorical error identifier and never free-text error detail. OpenCode completion excerpts SHALL use relevant root-session assistant text, while OpenCode failure excerpts SHALL use the structured error message when present and the error type otherwise, never the response body. The selected source SHALL be transmitted in full when it already fits the bound and SHALL be truncated when longer; model output or OpenCode error messages can repeat sensitive content such as secrets or paths. It SHALL use normal priority for completion, attention, and agent-error notifications. Adapter values SHALL be treated as untrusted data and SHALL NOT alter transport options, destination, or request structure.

The system SHALL sanitize `tmux_session` as an entire display label using the existing allowlist and 48-character bound; it SHALL NOT apply basename extraction to that value. A slash in `tmux_session` SHALL be replaced by that allowlist rather than treated as a path separator. It SHALL apply basename extraction only to `session_dir`. A whitespace-only tmux result is unusable. When neither candidate yields a usable label, the title context SHALL be `Unknown project`.

#### Scenario: A permission request requires action
- **WHEN** an adapter submits an `attention` event with a session directory and no valid tmux session name
- **THEN** the system SHALL deliver a normal-priority notification titled with the agent and project basename and a message indicating that attention is required

#### Scenario: A completion is eligible for delivery
- **WHEN** a `completed` event passes the suppression rules
- **THEN** the system SHALL deliver a normal-priority notification indicating that the turn is complete

#### Scenario: A tmux-hosted event is eligible for delivery
- **WHEN** an eligible event carries a valid tmux session name such as `team/api`
- **THEN** the system SHALL title the notification with the agent and sanitized full tmux label such as `team_api` instead of the project basename

#### Scenario: Tmux context is unavailable
- **WHEN** an eligible event does not carry a usable tmux session name
- **THEN** the system SHALL title the notification with the agent and sanitized project basename, or `Unknown project` when the project candidate is also unusable

### Requirement: Carry an optional message excerpt on the normalized event
The normalized lifecycle event contract SHALL accept an optional excerpt field alongside its existing fields. The system SHALL validate the excerpt independently of the rest of the event: an excerpt that is absent, empty, oversized, or otherwise invalid SHALL be discarded on its own and SHALL NOT invalidate, delay, or discard the event that carried it. The excerpt SHALL be preserved across every normalization and re-encoding stage between adapter submission and delivery, and SHALL NOT be written to session state or diagnostic logs.

For OpenCode's 2,048-byte encoded-event bound, the adapter SHALL first remove `tmux_session` and re-encode, then remove `excerpt` and re-encode; it SHALL discard the event only if the base event remains oversized.

#### Scenario: An event carries an invalid excerpt
- **WHEN** an adapter submits a lifecycle event whose excerpt field is oversized or contains disallowed characters
- **THEN** the system SHALL process the event normally without the excerpt and SHALL deliver the existing normalized state message

#### Scenario: An event carries no excerpt
- **WHEN** an adapter submits a lifecycle event with no excerpt field
- **THEN** the system SHALL process and deliver it exactly as it did before excerpts were introduced

#### Scenario: An adapter payload would exceed its transport bound
- **WHEN** an OpenCode encoded event containing `tmux_session` and an excerpt would exceed its 2,048-byte maximum payload size
- **THEN** the adapter SHALL remove and re-encode without `tmux_session`, then remove and re-encode without the excerpt only if necessary, and SHALL discard the event only if the resulting base event still exceeds the bound

#### Scenario: A delivery attempt fails
- **WHEN** delivery of a notification carrying an excerpt fails at any stage
- **THEN** the recorded state and diagnostics SHALL contain no excerpt text

### Requirement: Include a bounded excerpt of the agent's final message
For `completed` and `failed` events, the system SHALL include the excerpt in the delivered Pushover message when excerpts are enabled and an excerpt is available, leading with the normalized state message so the event kind remains distinguishable. The excerpt SHALL be produced by the adapter, never by the notifier. It SHALL be reduced to a single line with line breaks, control characters, C1 characters, bidirectional-formatting characters, and zero-width characters removed or replaced by spaces. It SHALL be bounded simultaneously by grapheme count, UTF-16 code units, and UTF-8 bytes, SHALL be taken from the END of the source text, and SHALL carry an explicit leading truncation marker when any text was dropped. Truncation SHALL NOT split a grapheme cluster. Adapters SHALL produce identical output for identical source text.

The Claude Code adapter SHALL read the `completed` excerpt only from the hook payload's final-assistant-message field, SHALL NOT read the transcript file, and SHALL NOT read any other payload field for excerpt purposes. For `failed` it SHALL use the payload's categorical error identifier and SHALL NOT use the payload's free-text error detail field.

The OpenCode V2 adapter SHALL resolve completion text through the native plugin session-context API for the session it is reporting completion for — the root, never a descendant. It SHALL inspect at most the twelve most-recent available context entries, select the newest `type: "assistant"` entry within that window, and select its first non-empty `content` item of type `text` in content order. It SHALL NOT concatenate content items or select an older assistant entry when the newest assistant has no eligible text. It SHALL exclude reasoning, tool content, synthetic/system entries, compaction summaries, prompts, and form values. Context lookup SHALL have a one-second deadline, and lookup failure or unavailable assistant text SHALL be treated as no excerpt available. For `failed` it SHALL use the native terminal error's `message` when present and its `type` otherwise, never its response body. A late lookup SHALL NOT cause a stale completion after a resumption, terminal event, or plugin cleanup.

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
- **THEN** the excerpt SHALL come from the root session's available assistant context and SHALL NOT come from descendant messages or a synthetic child report

#### Scenario: A deferred OpenCode root completion carries its last message
- **WHEN** an OpenCode root completion was deferred until descendants settled, no newer root assistant text exists, and the previous root assistant text remains available in native context
- **THEN** the system SHALL use that root assistant text even though it predates the background work and SHALL NOT replace it with child output

#### Scenario: OpenCode session messages cannot be resolved
- **WHEN** the OpenCode adapter cannot retrieve native context or its lookup exceeds the one-second deadline
- **THEN** it SHALL submit the event without an excerpt and SHALL NOT fail OpenCode

#### Scenario: The newest assistant contains multiple text items
- **WHEN** the newest root assistant entry within the twelve-entry inspection window contains reasoning/tool content and multiple non-empty text items
- **THEN** the adapter SHALL excerpt only the first non-empty text item in content order and SHALL NOT concatenate the other items

#### Scenario: The newest assistant contains no eligible text
- **WHEN** the newest assistant entry in the inspection window has no non-empty text item but an older assistant entry has text
- **THEN** the adapter SHALL submit the completion without an excerpt rather than selecting the older text

#### Scenario: The host agent does not expose a final message field
- **WHEN** the installed host agent version omits the final-assistant-message field from its completion payload
- **THEN** the adapter SHALL submit the event without an excerpt rather than failing, and the system SHALL deliver the existing normalized state message

#### Scenario: An attention notification is delivered
- **WHEN** an `attention` event is delivered
- **THEN** its message SHALL be the existing attention state message with no excerpt

#### Scenario: An OpenCode error contains a response body
- **WHEN** a native execution failure contains a structured message/type and a response body with unrelated content
- **THEN** only the sanitized bounded message or type SHALL be selected and the response body SHALL NOT be forwarded or logged

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
The system SHALL map Claude Code main-agent attention, completion, and failure hooks to normalized events. Claude attention SHALL be limited to `permission_prompt`, `elicitation_dialog`, and `elicitation_url_dialog`; all other notification types, including background-agent and subagent events, SHALL be ignored. Claude `began` events SHALL clear stale Claude attention; the adapter SHALL NOT claim a request-specific clear when Claude does not expose one.

The OpenCode runtime module SHALL expose only one default native V2 definition with stable ID `agent-notify` and `setup(ctx)`. It SHALL subscribe through `ctx.event.subscribe`, read native `data` payloads, and resolve event-session relationships/location through native context APIs. It SHALL NOT expose a V1 factory or `server` entrypoint, read V1 `properties` payloads, or translate V1-only/deprecated/speculative event aliases. In particular, deprecated `session.idle` SHALL NOT be a completion signal. Valid session details without a parent identifier SHALL identify a root. Invalid/cyclic/self-parent metadata SHALL NOT be trusted, and `ctx.location.directory` SHALL NOT substitute for an unresolved event-session directory.

The adapter SHALL submit `began` and `completed` only for root sessions when usable tree metadata is available. Descendant lifecycle states SHALL be tracked for root-tree settlement without their own begin/completion events, regardless of built-in/custom agent profile names or foreground/background use. Each genuinely new descendant execution SHALL submit one silent child-only `reset` before its attention/failure events so the unchanged notifier does not retain terminal suppression from a prior child execution. Duplicate corresponding execution-start/busy signals SHALL NOT reset that child again, and child reset SHALL NOT alter the root's original timer. Root completion SHALL require observed activation, successful native execution, idle state, no outstanding observed inbox work, and settlement of every known descendant, followed by bounded quiescence. Success of a root execution alone SHALL NOT imply subtree completion. A root resumed while its completion is deferred SHALL retain the original turn start and SHALL NOT emit another `began`; it SHALL require another successful settlement before completion.

Native `session.execution.succeeded` SHALL establish successful local execution and its native local-idle boundary without requiring a separate `session.status` idle event. Explicit idle status alone SHALL NOT establish successful execution. Subsequent activation, retry, or delivered inbox work SHALL invalidate prior completion eligibility under the existing settlement rules; local idle SHALL NOT bypass tree/inbox settlement or quiescence.

The root-tree decision SHALL remain best effort using observed/resolved relationships and lifecycle states. Lookup failure SHALL retain usable tracked metadata. If no usable relationship exists but usable event-session directory context is available, the adapter SHALL retain per-session lifecycle fallback; without usable directory context it SHALL omit submission and fail open. This SHALL NOT constitute a guarantee for unseen work or independently moved descendants outside the observer's scope. The adapter SHALL use resolved session location for display attribution and invalidate stale candidates on ownership changes. Delayed lookup results for deleted or invalidated ownership SHALL NOT recreate removed state/candidates or submit events attributed to that obsolete ownership.

On native session moves, the adapter SHALL distinguish outgoing and incoming observation ownership using the destination `data.location` identity, including optional workspace ID, and the native plugin-instance location identity. The outgoing instance SHALL relinquish the moved session and SHALL NOT re-arm its former turn's completion. The destination instance SHALL record arrival without replaying an earlier turn or fabricating activation. Plugin-instance identity SHALL be used only for ownership routing, never as a substitute for unresolved display directory context.

For native `session.execution.failed`, the adapter SHALL submit one `failed` for that session, clear its active/attention state, and suppress later completion for that execution. Child failures SHALL remain child-associated and SHALL NOT automatically fail a successful root. Native interruptions and deletions SHALL silently reset their sessions. Step/tool failures, ordinary retry statuses, V1 error events, and session-less errors SHALL NOT produce an execution-failure notification. Actionable retries SHALL retain deduplicated attention behavior without completing the turn.

#### Scenario: Claude Code requests permission
- **WHEN** Claude Code emits an eligible permission or input notification for a main-agent session
- **THEN** its hook SHALL submit an `attention` event without altering the permission decision

#### Scenario: OpenCode loads the adapter
- **WHEN** a supported OpenCode V2 version loads the managed local plugin module
- **THEN** its default definition SHALL provide ID `agent-notify` and a setup function that registers the native event subscription

#### Scenario: OpenCode reports session details without a parent identifier
- **WHEN** the native context returns usable session details with no parent identifier
- **THEN** the adapter SHALL treat that session as a root and apply root-tree deferral

#### Scenario: An OpenCode descendant session runs a background task
- **WHEN** a known descendant starts native execution and later settles
- **THEN** the adapter SHALL NOT submit `began` or `completed` for that descendant and SHALL use its lifecycle to settle its root

#### Scenario: A reused descendant fails in consecutive executions
- **WHEN** the same descendant session starts and fails in two genuinely separate native executions
- **THEN** each execution SHALL receive one child-only reset before its attention/failure events, each failure SHALL remain independently eligible for notifier delivery, and the root's deferred timer SHALL NOT restart

#### Scenario: A child receives duplicate activation signals
- **WHEN** native execution-start and corresponding busy signals describe one already-active child execution
- **THEN** the adapter SHALL NOT submit a second child reset or clear requests/failure suppression belonging to that execution

#### Scenario: Busy-only activation follows a terminal execution
- **WHEN** a root or reused child reports failure/interruption and then a genuine busy status without an execution-start or explicit idle signal
- **THEN** the adapter SHALL activate the new execution, emitting a root begin or one child reset as appropriate, without retaining stale busy status or reusing the previous terminal outcome

#### Scenario: OpenCode root transitions from busy to idle without an active known descendant
- **WHEN** an activated root reports native execution success and idle with no outstanding observed inbox work and all known descendants settled
- **THEN** the adapter SHALL submit one `completed` after quiescence and clear its active root-tree state

#### Scenario: OpenCode root becomes idle while a known descendant is active
- **WHEN** a root reports successful local execution and idle while a known descendant is busy or retrying
- **THEN** the adapter SHALL defer root completion despite the root's success event

#### Scenario: Native execution succeeds without a separate idle status
- **WHEN** an activated root reports `session.execution.succeeded` with no subsequent status-idle event and all observed tree/inbox work is settled
- **THEN** the adapter SHALL use that execution event's native local-idle boundary and submit one completion after quiescence

#### Scenario: A root moves between location-scoped observers
- **WHEN** a successful pending root moves from one native location to another and resumes only in the destination's event stream
- **THEN** the outgoing observer SHALL discard its candidate and SHALL NOT submit completion or queued events from obsolete ownership, even when the move envelope names the old location
- **AND** the destination observer SHALL handle later activation/outcome with the resolved session directory without replaying missed turns

#### Scenario: Locations share a directory but not a workspace
- **WHEN** a root moves between native locations with the same directory and different workspace IDs
- **THEN** ownership routing SHALL distinguish those locations rather than retaining the outgoing observer's turn

#### Scenario: Same-owner movement overlaps a delayed resumption lookup
- **WHEN** a successful pending root ingests resumption before a same-owner move while that resumption's lookup remains delayed
- **THEN** the adapter SHALL preserve and re-resolve the earlier lifecycle input in ingress order rather than re-arm prior success by discarding it
- **AND** late obsolete lookup results SHALL NOT restore old attribution or produce stale completion, including when the fresh lookup uses existing directory fallback

#### Scenario: Same-owner movement overlaps a queued new-execution control
- **WHEN** a new root begin or reused-child reset has reduced but waits behind an earlier submitted notifier subprocess when a same-owner move occurs
- **THEN** the adapter SHALL preserve that unsubmitted control in FIFO under current validated ownership/context before the new execution's outcome
- **AND** it SHALL NOT replay an already-submitted control or carry obsolete controls through outgoing ownership or deletion

#### Scenario: A finished descendant wakes a root whose completion is deferred
- **WHEN** a root with deferred completion receives admitted work or begins another execution to consume background results
- **THEN** the adapter SHALL cancel the existing candidate without another `began` and SHALL wait for admitted work to settle and any resumed execution to succeed before considering completion

#### Scenario: The final known descendant settles after its root is idle
- **WHEN** a successful idle root has deferred completion and its final active descendant settles without new admitted work or a root resumption
- **THEN** the adapter SHALL submit one root completion after quiescence without requiring another root idle signal

#### Scenario: OpenCode session-tree metadata is unavailable
- **WHEN** a lifecycle lookup fails or returns unusable parent metadata
- **THEN** the adapter SHALL retain known usable tree state or use bounded per-session fallback only with usable event-session directory context, and SHALL NOT fail OpenCode

#### Scenario: A lookup resolves after deletion or ownership invalidation
- **WHEN** a pending session lookup resolves after deletion or a move has invalidated the ownership associated with that lookup
- **THEN** the adapter SHALL NOT use that result to recreate removed state/candidates or submit a queued event attributed to the obsolete ownership

#### Scenario: OpenCode reports a terminal session error
- **WHEN** OpenCode emits native `session.execution.failed` for a valid session
- **THEN** the adapter SHALL submit one `failed` and SHALL NOT submit later completion for that execution

#### Scenario: The same agent profile runs as root and child
- **WHEN** a profile supporting primary and subagent use runs in sessions with different parent relationships
- **THEN** the adapter SHALL determine lifecycle notification eligibility from relationships rather than the profile name or mode alone

#### Scenario: Only deprecated or V1 signals arrive
- **WHEN** the plugin receives `session.idle`, a `properties`-only event, V1 `session.error`, `session.next.*`, `question.*`, or a speculative `.v2.*` alias
- **THEN** it SHALL ignore those signals without invoking a V1 API or emitting a duplicate terminal event

### Requirement: Confirm OpenCode root quiescence before completion
The OpenCode adapter SHALL require a short bounded quiescence interval after a successful root is idle, all known descendants are settled, and no observed inbox work remains outstanding before submitting `completed`. It SHALL maintain at most one tokenized completion candidate per root and SHALL synchronously invalidate a known candidate upon ingestion of root/descendant activation, retry, interruption, failure, deletion, ownership change, or admitted inbox work, before awaiting metadata lookup or notification delivery. It SHALL invalidate candidates when their tree is merged/removed or their plugin generation stops, and SHALL re-evaluate eligibility after the interval, after asynchronous excerpt retrieval, and immediately before subprocess submission at the front of the per-session notification FIFO. A completion waiting in that FIFO SHALL remain cancellable; the candidate/root turn SHALL NOT be consumed merely because excerpt retrieval finished. A root resumed before completion submission SHALL discard that queued completion and keep its original turn start without another `began`. A continuously valid candidate SHALL submit one completion without requiring another root idle event, consuming the turn at the submission boundary without awaiting the subprocess's exit. Already-submitted notifications SHALL NOT be treated as retractable. The event-ingestion/invalidation path SHALL NOT wait for a notifier subprocess to finish.

Metadata reduction barriers SHALL be scoped to affected observed trees, preserving their ingestion order while permitting verified independent trees to progress. An unrelated resolved root's stalled or sustained metadata work SHALL NOT delay a continuously valid completion candidate or ready lifecycle reduction on another root. Unresolved relationships SHALL retain conservative protection against premature subtree completion until bounded lookup/fallback resolves them.

The adapter SHALL track observed `session.inbox.enqueued` items by `data.sessionID` and `data.inboxID` across the root and every known descendant without retaining or forwarding item payloads. Outstanding items SHALL block root settlement even when their owning session is idle. Native `session.inbox.delivered/cancelled` SHALL settle only the matching observed item; duplicate signals SHALL NOT create extra outstanding work or corrupt eligibility, and unmatched settlements SHALL NOT clear another item. Delivery alone SHALL NOT establish execution success: delivered work SHALL require a native execution outcome after delivery for its owning session before root completion is eligible. The root SHALL still require success; a child's failure/interruption SHALL remain a settled child and SHALL NOT require subsequent child success or automatically fail the root. Cancellation of unconsumed work SHALL leave prior success usable when no execution has resumed and SHALL permit re-evaluation once other observed conditions are satisfied. This tracking SHALL use observed events without adding inbox polling or durable adapter state.

#### Scenario: A descendant settles immediately before its root resumes
- **WHEN** the final active descendant settles and the deferred root activates during quiescence
- **THEN** the adapter SHALL cancel that candidate without `completed` or another `began` and SHALL keep tracking the same root turn

#### Scenario: A deferred root remains settled
- **WHEN** the root is successful and idle, all known descendants remain settled, and no outstanding admitted work or resumption appears throughout quiescence
- **THEN** the adapter SHALL submit one completion without another idle signal

#### Scenario: Duplicate idle signals arrive during quiescence
- **WHEN** repeated native status-idle events or duplicate success events trigger settlement checks for one root
- **THEN** the adapter SHALL retain at most one candidate and submit at most one completion

#### Scenario: A root resumes during excerpt retrieval
- **WHEN** excerpt lookup is in progress and the root admits work or activates before it finishes
- **THEN** the adapter SHALL invalidate the candidate and SHALL NOT submit its stale completion

#### Scenario: Metadata lookup stalls after activation arrives
- **WHEN** a root or known descendant activation/terminal event arrives while its metadata lookup remains pending
- **THEN** the adapter SHALL invalidate the known root candidate before lookup completes

#### Scenario: An independent root's metadata work stalls
- **WHEN** one successful settled root has a continuously valid candidate while a verified independent root has sustained delayed metadata lookups
- **THEN** the settled root SHALL complete after its own quiescence interval, and its ready lifecycle events SHALL reduce without waiting for the unrelated lookups

#### Scenario: Notification delivery is slow while the root resumes
- **WHEN** a notifier subprocess is pending and the event stream delivers activation or admitted work for a pending root
- **THEN** the adapter SHALL ingest that event and invalidate stale completion eligibility without waiting for the subprocess

#### Scenario: A completion waits behind slow attention delivery
- **WHEN** an eligible completion has finished excerpt retrieval but waits behind an earlier attention subprocess and the root or a known descendant activates before completion submission
- **THEN** the adapter SHALL discard the queued completion without starting its subprocess, retain the root's original turn timer without another `began`, and require a new successful settlement before completing

#### Scenario: An idle descendant has admitted inbox work
- **WHEN** a successful idle root has no busy descendant but a known idle descendant has an outstanding observed inbox item
- **THEN** the adapter SHALL defer root completion until that item's matching settlement and the remaining observed tree conditions permit completion

#### Scenario: Delivered work has no subsequent execution outcome
- **WHEN** observed inbox work is delivered after the owning session's prior success but no subsequent native execution outcome has been observed for that session
- **THEN** the adapter SHALL NOT reuse the prior success to complete the root, even if a stale idle status remains

#### Scenario: Delivered child work fails or is interrupted
- **WHEN** a child's delivered inbox work reaches a native execution failure/interruption and no outstanding observed work remains for that child
- **THEN** the child SHALL be treated as settled under the existing child-outcome policy without requiring child success or automatically failing a successful root

#### Scenario: Duplicate or unrelated inbox signals arrive
- **WHEN** an inbox admission/settlement is duplicated or a delivered/cancelled event has no matching observed item for its session and inbox identifier
- **THEN** the adapter SHALL NOT create duplicate outstanding work, clear another item, or invalidate success because of a duplicate settlement

#### Scenario: Queued work is cancelled
- **WHEN** the last outstanding observed inbox item is cancelled while a previously successful root is idle and all known descendants are settled
- **THEN** the adapter SHALL re-evaluate completion eligibility rather than leaving the turn blocked indefinitely

### Requirement: Declare supported integration compatibility
The repository SHALL declare supported macOS, Claude Code, and OpenCode ranges, identify the exact version used for real OpenCode verification, and declare the native permission/form event family. Initially OpenCode support SHALL be `>= 2.0.27, < 2.1.0`, with 2.0.27 as the verification baseline; V1 and earlier V2 releases SHALL NOT be supported. Accepting a patch range SHALL NOT be described as runtime-testing every patch, and a verification baseline SHALL NOT be described as runtime-verified before successful real-host checks. macOS and Claude compatibility parsing/policy SHALL remain unchanged. Before collecting credentials or performing mutation, the installer SHALL verify clients satisfy this policy and abort without changes for unsupported or unparseable versions. OpenCode preflight SHALL validate the complete announced version token, accepting the normal label and optional `v` prefix, and SHALL NOT accept malformed or unsupported suffixes/additional components by extracting a numeric prefix. Prerelease/build suffixes unsupported by the existing numeric version policy SHALL be rejected.

#### Scenario: An installed client is unsupported
- **WHEN** the installer cannot verify a supported Claude Code or OpenCode version
- **THEN** it SHALL report incompatibility and SHALL NOT collect credentials or modify the environment

#### Scenario: OpenCode V1 or an earlier V2 release is present
- **WHEN** the installed OpenCode is below 2.0.27
- **THEN** compatibility validation and installation SHALL reject it without offering a legacy adapter fallback

#### Scenario: OpenCode is in the supported patch line
- **WHEN** a parseable OpenCode version is at least 2.0.27 and less than 2.1.0
- **THEN** version-policy validation SHALL accept it while documentation separately identifies the version actually runtime-verified

#### Scenario: OpenCode is in a later minor line
- **WHEN** OpenCode is 2.1.0 or newer
- **THEN** the initial compatibility policy SHALL reject it until support is deliberately expanded with evidence

#### Scenario: OpenCode reports its installed version with a label
- **WHEN** the installed client reports `opencode v2.0.27`
- **THEN** preflight SHALL validate the complete `v2.0.27` version token and accept it under the supported range

#### Scenario: OpenCode reports an unsupported version token suffix
- **WHEN** OpenCode reports `opencode v2.0.27.1`, `opencode v2.0.27-rc.1`, or a version token with build metadata
- **THEN** preflight, including dry-run, SHALL reject that complete token before credential collection or mutation rather than accept its `2.0.27` numeric prefix

### Requirement: Normalize native OpenCode permission and form attention
The OpenCode adapter SHALL use only native `permission.asked/replied` and `form.created/replied/cancelled` attention events. It SHALL extract permission request IDs from `data.id` when asked and `data.requestID` when replied, and form IDs/session IDs from `data.form` when created and `data.id/sessionID` when settled. Attention SHALL be deduplicated by session, family, and request identifier; settlement SHALL clear only a matching observed request. Valid child requests SHALL remain observable independently of root lifecycle suppression. Forms owned by `global`, malformed requests, and requests lacking usable session-directory context SHALL be ignored. Form fields, answers, titles, URLs, and request metadata SHALL NOT be included in excerpts, normalized events, state, or diagnostics, and observation SHALL NOT reply or change host decisions.

#### Scenario: A child asks permission
- **WHEN** a native permission request identifies a valid child session and request
- **THEN** the adapter SHALL emit one child-associated attention event without a child begin/completion event or a permission reply

#### Scenario: A native form is answered or cancelled
- **WHEN** an observed `form.created` request receives matching `form.replied` or `form.cancelled`
- **THEN** the adapter SHALL emit one matching attention-clear without forwarding the form or answer

#### Scenario: An unrelated request settles
- **WHEN** a reply or cancellation does not match an observed request for that session and family
- **THEN** it SHALL NOT clear a different request or reset the active root-turn timer

#### Scenario: A non-session form is created
- **WHEN** `form.created` carries the `global` owner sentinel
- **THEN** the adapter SHALL ignore it without fabricating a session identifier, directory, or notification

### Requirement: Own OpenCode plugin generation resources
Native setup SHALL return cleanup without awaiting the event stream's lifetime. Cleanup SHALL abort the subscription, invalidate generation/completion tokens, clear timers and queues, and request termination of owned subprocesses. Work not yet submitted SHALL NOT submit notifications after its generation stops; already delivered notifications SHALL NOT be treated as retractable. A stream failure/end SHALL invalidate pending completion eligibility and SHALL NOT be interpreted as success. Malformed events, subscription errors, bounded lookup failures, subprocess failures, and cleanup errors SHALL remain advisory without unhandled rejections or raw diagnostic output. A new generation SHALL NOT fabricate turn starts or replay missed live events.

#### Scenario: Plugin reload occurs during completion lookup
- **WHEN** cleanup runs with a completion timer or excerpt request pending and an old async result later resolves
- **THEN** the old generation SHALL NOT emit completion and the new generation SHALL start with independent in-memory observation state

#### Scenario: Subscription fails during an active turn
- **WHEN** the native event iterable throws or ends unexpectedly
- **THEN** the plugin SHALL cancel pending completion eligibility, suppress raw exception output, and SHALL NOT affect host execution

#### Scenario: Plugin setup observes malformed data
- **WHEN** an event has invalid native identifiers, wrong nesting, or unusable session context
- **THEN** the adapter SHALL ignore or safely omit that event while continuing valid observation without exposing its raw payload
