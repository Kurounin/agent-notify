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
The installer SHALL provide a local notifier smoke-test command and report the installed locations, backup locations, configuration changes, and selective rollback instructions after successful installation. It SHALL report failures clearly without claiming successful configuration when any required installation step failed.

#### Scenario: Installation succeeds
- **WHEN** all confirmed installation steps complete successfully
- **THEN** the installer SHALL display the notifier command path, managed configuration locations, and the command to send a test notification

### Requirement: Undo the most recent installation from its manifest
Rollback SHALL change only managed artifacts, acting on one only when it is still a regular file or directory matching its recorded post-install hash: it SHALL restore the exact prior bytes and mode if the artifact existed before the install, and remove it otherwise. It SHALL report and leave any other artifact while processing the rest. The rollback option confirms file changes, in place of installation's preview and prompt; deleting credentials SHALL require separate confirmation.

#### Scenario: A manifest records numeric or boolean flags
- **WHEN** rollback runs on a manifest that records existence flags as 0 and 1, or as true and false, and each artifact matches its recorded hash
- **THEN** it SHALL restore each artifact that existed before the install to its exact prior bytes and mode, and remove each artifact that did not

#### Scenario: Nothing existed before the install
- **WHEN** rollback runs after a first install and each artifact matches its recorded hash
- **THEN** it SHALL remove the notifier, the library, both Claude adapter files, the OpenCode plugin, and the Claude settings file that install created

#### Scenario: Only the library existed before the install
- **WHEN** rollback runs after an install where the library was the only artifact that already existed, so no file modes were recorded
- **THEN** it SHALL restore the library and remove the other artifacts rather than refuse

#### Scenario: An artifact changed after installation
- **WHEN** an artifact no longer matches its recorded post-install hash
- **THEN** rollback SHALL leave that artifact unchanged, report it, and still process the unchanged artifacts

#### Scenario: A managed path became a symbolic link
- **WHEN** a managed path is a symbolic link at rollback time, even if its target matches the recorded hash
- **THEN** rollback SHALL leave the link and its target unchanged, report it, and still process the other artifacts

#### Scenario: Settings the install created have changed, or the hook adapter is gone
- **WHEN** Claude settings no longer match their recorded post-install hash and either the install created the settings file or the hook adapter no longer exists once the other artifacts are processed
- **THEN** rollback SHALL leave them unchanged and name the managed command prefix to remove manually

#### Scenario: Settings that predate the install have changed and the hook adapter remains
- **WHEN** Claude settings no longer match their recorded post-install hash, the settings file existed before the install, and the hook adapter still exists once the other artifacts are processed
- **THEN** rollback SHALL leave them unchanged and name the backup to compare with, and SHALL NOT present removing the managed commands as required, because those commands can predate the install

#### Scenario: The rollback option is given
- **WHEN** the user runs the installer with the rollback option and validation passes
- **THEN** the option itself SHALL count as confirmation for restoring and removing artifacts, with no further prompt

#### Scenario: Credential removal is declined
- **WHEN** rollback asks whether to remove credentials and the user does not confirm
- **THEN** it SHALL leave Keychain entries, including the active-generation selector, unchanged

#### Scenario: Credential removal is confirmed
- **WHEN** rollback asks whether to remove credentials and the user confirms
- **THEN** it SHALL remove the active-generation selector and the credential items of the generation the manifest records, and SHALL NOT read, change, or remove v1 items

### Requirement: Refuse a rollback that cannot be trusted
Before changing anything, rollback SHALL validate the manifest and backups. It SHALL report the problem and leave installed files and Keychain entries unchanged when the manifest is unreadable, a recorded artifact path or the recorded backup directory is not managed for the current home, a recorded hash or existence flag is invalid, the backups present do not agree with the recorded flags, or a file to restore has no valid recorded mode. Rollback SHALL NOT run when combined with dry-run.

#### Scenario: An existence flag is invalid
- **WHEN** a recorded existence flag is anything other than 0, 1, true, or false, including a string such as `"1"` or a missing value
- **THEN** rollback SHALL refuse with no changes rather than treat the artifact as not having existed

#### Scenario: A needed backup is missing
- **WHEN** an artifact recorded as having existed before the install has no backup, or a file among them has no valid recorded mode
- **THEN** rollback SHALL refuse with no changes

#### Scenario: A backup contradicts its flag
- **WHEN** an artifact is recorded as not having existed before the install and a backup of it is present
- **THEN** rollback SHALL refuse with no changes rather than remove the artifact

#### Scenario: The manifest names another location
- **WHEN** a recorded artifact path is not the managed path for the current home, as with a manifest copied from another home
- **THEN** rollback SHALL refuse and SHALL NOT change anything at the recorded path

#### Scenario: The recorded backup directory is not managed
- **WHEN** the recorded backup directory is not an install directory directly under the current home's backup location, including a path that starts there and climbs out
- **THEN** rollback SHALL refuse and SHALL NOT restore anything from it

#### Scenario: The manifest is damaged
- **WHEN** the manifest is truncated or unparseable, or a recorded post-install hash is missing or malformed
- **THEN** rollback SHALL refuse with no changes

#### Scenario: Rollback is combined with dry-run
- **WHEN** the installer receives both the dry-run and rollback options, in either order
- **THEN** it SHALL report a usage error and make no changes
