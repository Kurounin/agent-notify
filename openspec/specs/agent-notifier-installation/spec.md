## Purpose

Define safe installation and rollback behavior for the agent notifier.

## Requirements

### Requirement: Preview and confirm all user-environment changes
The installer SHALL detect the required macOS tools, supported client versions, target configuration locations, existing credential state, and managed-file conflicts before collecting credentials or performing any persistent or externally visible action. It SHALL disclose the files and Keychain service names it intends to create or update, the agent name, project-directory basename, normalized state, and timing metadata transmitted to Pushover and downstream push services, and require explicit confirmation before mutation.

#### Scenario: The user declines installation
- **WHEN** the user does not explicitly confirm the displayed installation plan
- **THEN** the installer SHALL leave Keychain entries, installed files, and agent configuration unchanged

#### Scenario: Prerequisites are unavailable
- **WHEN** a required executable or supported Claude Code/OpenCode installation is unavailable
- **THEN** the installer SHALL report the missing prerequisite and SHALL NOT modify configuration

### Requirement: Collect and protect Pushover credentials
The installer SHALL prompt for the Pushover user key and application token without echoing their values, retain them only in memory until confirmation, and save them to distinct Keychain items for the logged-in user after confirmation. It SHALL NOT write credentials to repository files, shell profiles, agent configuration, state files, logs, process arguments, environment variables, or temporary files.

#### Scenario: New credentials are confirmed
- **WHEN** the user supplies both credentials and confirms installation
- **THEN** the installer SHALL store each credential in its designated Keychain item without printing its value

#### Scenario: Credentials already exist
- **WHEN** the designated Keychain items already exist
- **THEN** the installer SHALL disclose that existing credentials will be retained or replaced and require confirmation before replacing them

### Requirement: Install integrations without clobbering unrelated settings
After all conflict and credential-replacement decisions are confirmed, the installer SHALL install the notifier executable in the user's local bin directory, add a dedicated OpenCode plugin, and merge only the notifier's dedicated Claude Code hook entries into the global settings file. It SHALL preserve unrelated settings and plugins, create unique user-only recoverable backups outside auto-loaded plugin directories before modifying existing configuration, and refuse to overwrite a conflicting notifier-managed file without explicit replacement consent. On failure after mutation begins, it SHALL restore prior file bytes and modes, restore the prior Keychain state, and remove only artifacts created by that attempt.

#### Scenario: Existing Claude Code settings are present
- **WHEN** the installer adds notifier hooks to an existing Claude Code settings file
- **THEN** it SHALL preserve the existing settings and create a backup before writing the merged configuration

#### Scenario: A conflicting OpenCode plugin exists
- **WHEN** the target OpenCode plugin path exists but is not recognized as installer-managed
- **THEN** the installer SHALL NOT overwrite it unless the user explicitly consents to replacement

#### Scenario: Installation fails after the first mutation
- **WHEN** a confirmed installation step fails after writing a Keychain item or managed file
- **THEN** the installer SHALL restore the pre-install environment and report that installation did not complete

### Requirement: Verify the completed installation
The installer SHALL provide a local notifier smoke-test command and report the installed locations, backup locations, configuration changes, and selective rollback instructions after successful installation. It SHALL report failures clearly without claiming successful configuration when any required installation step failed. Rollback SHALL remove only managed entries; it SHALL restore an entire backup only when the current file matches the recorded post-install hash, otherwise it SHALL provide manual merge instructions. Deleting credentials during rollback SHALL require separate confirmation.

#### Scenario: Installation succeeds
- **WHEN** all confirmed installation steps complete successfully
- **THEN** the installer SHALL display the notifier command path, managed configuration locations, and the command to send a test notification
