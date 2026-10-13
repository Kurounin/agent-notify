## Purpose

Define safe installation and rollback behavior for the agent notifier.

## Requirements

### Requirement: Preview and confirm all user-environment changes
The installer SHALL detect the required macOS tools, supported client versions, target configuration locations, existing credential state, and managed-file conflicts before collecting credentials or performing any persistent or externally visible action. OpenCode preflight SHALL accept only the declared V2 support range, validate the complete announced version token without numeric-prefix truncation, and reject V1 or unsupported version syntax without staging a legacy adapter. It SHALL disclose the files and Keychain service names it intends to create or update and that Pushover and downstream push services receive the agent name; a sanitized, length-bounded display context; normalized state; and, when excerpts are enabled and available, an optional sanitized bounded single-line excerpt. Claude display context SHALL be a valid current innermost tmux session name for its originating pane when automatic bounded lookup succeeds, or otherwise the project-directory basename; OpenCode display context SHALL always use the resolved session-directory project fallback. The disclosure SHALL state that tmux is optional, Claude lookup failures fall back to project context, and user-chosen tmux names can be sensitive. It SHALL explain that OpenCode's shared-server environment does not establish an originating pane and that this V2 adapter does not discover panes or perform tmux lookup. It SHALL state that Claude completion excerpts use final assistant output, Claude failure excerpts use the categorical error identifier and never free-text error detail, OpenCode completion excerpts use relevant root-session assistant text available through native context, and OpenCode failure excerpts use structured error message when present or error type otherwise, never response bodies. It SHALL state that excerpts are sanitized and bounded, with the selected source transmitted in full when it already fits the bound and truncated when longer, and that model output or OpenCode error messages can still repeat sensitive content such as secrets or paths. It SHALL state that excerpts are enabled by default and name the setting that disables them. The installer SHALL require explicit confirmation before mutation.

#### Scenario: The user declines installation
- **WHEN** the user does not explicitly confirm the displayed installation plan
- **THEN** the installer SHALL leave Keychain entries, installed files, and agent configuration unchanged

#### Scenario: Prerequisites are unavailable
- **WHEN** a required executable or supported Claude Code/OpenCode installation is unavailable
- **THEN** the installer SHALL report the missing prerequisite and SHALL NOT modify configuration

#### Scenario: The user reviews what is transmitted
- **WHEN** the installer displays its plan before collecting credentials
- **THEN** the disclosure SHALL identify Claude's tmux-or-project display context, OpenCode's project-only attribution with no pane discovery, normalized state, optional bounded excerpt, both integrations' excerpt sources, residual sensitive-content risk, and excerpt default/opt-out

#### Scenario: OpenCode V1 is installed
- **WHEN** preflight discovers OpenCode V1, including during dry-run
- **THEN** it SHALL report an unsupported version before credential collection or managed-file mutation and SHALL NOT generate a V1 fallback

#### Scenario: OpenCode version output has an unsupported suffix
- **WHEN** preflight or dry-run receives a malformed/additionally suffixed OpenCode version token such as `opencode v2.0.27.1` or `opencode v2.0.27-rc.1`
- **THEN** it SHALL reject the complete token before credential collection or mutation rather than accept a supported numeric prefix

### Requirement: Collect and protect Pushover credentials
The installer SHALL prompt for the Pushover user key and application token without echoing their values, retain them only in memory until confirmation, and save them to distinct Keychain items for the logged-in user after confirmation. It SHALL NOT write credentials to repository files, shell profiles, agent configuration, state files, logs, process arguments, environment variables, or temporary files.

#### Scenario: New credentials are confirmed
- **WHEN** the user supplies both credentials and confirms installation
- **THEN** the installer SHALL store each credential in its designated Keychain item without printing its value

#### Scenario: Credentials already exist
- **WHEN** the designated Keychain items already exist
- **THEN** the installer SHALL disclose that existing credentials will be retained or replaced and require confirmation before replacing them

### Requirement: Install integrations without clobbering unrelated settings
After all conflict and credential-replacement decisions are confirmed, the installer SHALL install the notifier executable in the user's local bin directory, stage the single native OpenCode V2 adapter from `integrations/opencode/` into the managed global path `~/.config/opencode/plugins/agent-notify.js`, and merge only the notifier's dedicated Claude Code hook entries into global settings. The generated plugin SHALL retain its managed marker and safely embedded absolute notifier executable path and SHALL expose the native V2 definition without requiring npm installation or a second installed adapter copy. It SHALL NOT edit unrelated OpenCode configuration or agent definitions. The installer SHALL preserve unrelated settings/plugins, create unique user-only recoverable backups outside auto-loaded plugin directories before modifying existing configuration, and refuse to overwrite a conflicting notifier-managed file without explicit replacement consent. An exact manifest-owned V1 artifact SHALL be updated through these existing ownership rules without retaining a second discoverable legacy plugin. On failure after mutation begins, it SHALL restore prior file bytes and modes, restore prior Keychain state, and remove only artifacts created by that attempt. The OpenCode migration SHALL NOT change the existing Keychain v2 generation/selector policy or read, change, or remove old Keychain v1 items.

#### Scenario: Existing Claude Code settings are present
- **WHEN** the installer adds notifier hooks to an existing Claude Code settings file
- **THEN** it SHALL preserve the existing settings and create a backup before writing the merged configuration

#### Scenario: A conflicting OpenCode plugin exists
- **WHEN** the target OpenCode plugin path exists but is not recognized as installer-managed
- **THEN** the installer SHALL NOT overwrite it unless the user explicitly consents to replacement

#### Scenario: Installation fails after the first mutation
- **WHEN** a confirmed installation step fails after writing a Keychain item or managed file
- **THEN** the installer SHALL restore the pre-install environment and report that installation did not complete

#### Scenario: A manifest-owned V1 plugin is updated
- **WHEN** installation on supported V2 finds a prior plugin whose bytes match its managed manifest hash
- **THEN** it SHALL back up that artifact outside discovery directories and replace it at the same managed path with one native V2 definition without changing unrelated OpenCode files

#### Scenario: A user changed the prior managed plugin
- **WHEN** the prior plugin's current hash differs from its managed manifest hash
- **THEN** the installer SHALL preserve the file unless replacement is explicitly confirmed and SHALL NOT treat its marker alone as sufficient ownership

#### Scenario: The generated plugin is exercised
- **WHEN** a staged or installed plugin is loaded by a native-context fixture
- **THEN** it SHALL provide ID `agent-notify`, register a native subscription, and submit normalized events to the safely embedded absolute notifier path without additional dependency installation

### Requirement: Verify the completed installation
The installer SHALL provide a local notifier smoke-test command and report the installed locations, backup locations, configuration changes, and selective rollback instructions after successful installation. It SHALL report failures clearly without claiming successful configuration when any required installation step failed. Rollback SHALL remove only managed entries; it SHALL restore an entire backup only when the current file matches the recorded post-install hash, otherwise it SHALL provide manual merge instructions. Deleting credentials during rollback SHALL require separate confirmation.

#### Scenario: Installation succeeds
- **WHEN** all confirmed installation steps complete successfully
- **THEN** the installer SHALL display the notifier command path, managed configuration locations, and the command to send a test notification
