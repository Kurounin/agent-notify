#!/usr/bin/env zsh

setopt errexit no_unset pipe_fail

typeset root=${0:A:h:h:h}
typeset settings_fixture="$root/tests/fixtures/claude-settings/existing.json"
typeset test_root
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-notify-installer.XXXXXX")
trap '/bin/rm -rf "$test_root"' EXIT

# Nothing in this suite may reach the real Keychain, a real Pushover send, or the real home.
print -r -- '({ copyMatching: () => -25300 })' > "$test_root/no-credentials-shim.jxa"
export AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$test_root/no-credentials-shim.jxa"
export AGENT_NOTIFY_KEYCHAIN_RUNTIME_HELPER="$test_root/no-runtime-keychain-helper"
export HOME="$test_root/outer-home"

"$root/bin/agent-notify" validate-version macos 13.0
"$root/bin/agent-notify" validate-version macos 26.5.2
"$root/bin/agent-notify" validate-version macos 27.0
"$root/bin/agent-notify" validate-version macos 27.0.1
"$root/bin/agent-notify" validate-version claude-code 1.0.0
"$root/bin/agent-notify" validate-version claude-code 2.0.0
"$root/bin/agent-notify" validate-version claude-code 2.999.999
"$root/bin/agent-notify" validate-version macos 12.9 >/dev/null 2>&1 && { print -u2 -- 'unsupported macOS lower boundary accepted'; exit 1; }
"$root/bin/agent-notify" validate-version macos 28.0 >/dev/null 2>&1 && { print -u2 -- 'unsupported macOS upper boundary accepted'; exit 1; }
"$root/bin/agent-notify" validate-version macos 26.5.2.1 >/dev/null 2>&1 && { print -u2 -- 'unparseable macOS version accepted'; exit 1; }
"$root/bin/agent-notify" validate-version macos 27.0.1.1 >/dev/null 2>&1 && { print -u2 -- 'unparseable macOS 27 version accepted'; exit 1; }
"$root/bin/agent-notify" validate-version claude-code 3.0.0 >/dev/null 2>&1 && { print -u2 -- 'unsupported Claude upper boundary accepted'; exit 1; }
"$root/bin/agent-notify" validate-version claude-code 2.0.0.1 >/dev/null 2>&1 && { print -u2 -- 'unparseable Claude version accepted'; exit 1; }
typeset -a supported_opencode_versions=(2.0.27 v2.0.27 'opencode 2.0.27' 'opencode v2.0.27' $'opencode\tv2.0.27' 2.0.28 2.0.999 2.0.1000 2.1.0 2.1.999 2.2.0 2.2.1 v2.2.1 'opencode 2.2.1' 'opencode v2.2.1' $'opencode\tv2.2.1' 2.2.999 2.2.1000)
typeset -a rejected_opencode_versions=(1.0.0 1.999.999 1.1000.27 2.0.0 2.0.26 2.3.0 v2.3.0 'opencode v2.3.0' 2.1000.27 3.0.0 2.0.27.1 2.0.27-rc.1 2.0.27+build.1 'opencode v2.0.27.1' 'opencode v2.0.27-rc.1' 'opencode v2.0.27+build.1' 2.2.1.1 2.2.1-rc.1 2.2.1+build.1 'opencode v2.2.1.1' 'opencode v2.2.1-rc.1' 'opencode v2.2.1+build.1' unknown 'opencode unknown' 'opencode v2.0.27 trailing' 'opencode v2.2.1 trailing' 'prefix 2.0.27' 2.0 '2.0.27 2.1.0' opencodet2.0.27 'opencode t2.0.27')
for version in $supported_opencode_versions; do
  "$root/bin/agent-notify" validate-version opencode "$version" || { print -u2 -- 'supported OpenCode version rejected'; exit 1; }
done
for version in $rejected_opencode_versions; do
  "$root/bin/agent-notify" validate-version opencode "$version" >/dev/null 2>&1 && { print -u2 -- 'unsupported OpenCode version accepted'; exit 1; }
done

make_client() { { print -- '#!/bin/zsh'; print -- "print -- '$2'"; } > "$1"; /bin/chmod 700 "$1"; }
make_helper() { print -r -- '#!/bin/zsh
if [[ $3 == *manifest.jxa ]]; then /usr/bin/osascript -l JavaScript "$3" "${@:4}"; exit $?; fi
if [[ $3 == *plugin-jxa ]]; then /usr/bin/osascript -l JavaScript "'"$2"'" "$4" "$5" "$6"; exit $?; fi
if [[ $3 == *failing-helper ]]; then exit 7; fi
if [[ $3 == *keychain-jxa ]]; then "$3" "${@:4}"; exit $?; fi
case $4 in inspect) print -- valid;; merge|remove-managed) /bin/cp "$5" "$6" 2>/dev/null || print -- "{}" > "$6";; store|rollback|remove) /bin/cat >/dev/null;; esac' > "$1"; /bin/chmod 700 "$1"; }
make_keychain_helper() { print -r -- "#!/bin/zsh
typeset state='$2' raw generation selector
case \$1 in
  store) raw=\$(/bin/cat); [[ \$raw =~ '\\\"generation\\\":\\\"([^\\\"]+)' ]] || exit 1; generation=\$match[1]; print -- \$generation > \"\$state/selector\"; print -- \$generation > \"\$state/current-generation\" ;;
  rollback) raw=\$(/bin/cat); [[ \$raw =~ '\\\"selector\\\":\\\"([^\\\"]*)' ]] || exit 1; selector=\$match[1]; [[ -n \$selector ]] && print -- \$selector > \"\$state/selector\" || /bin/rm -f \"\$state/selector\"; /bin/rm -f \"\$state/current-generation\" ;;
  remove) /bin/cat > \"\$state/removed\"; /bin/rm -f \"\$state/selector\" \"\$state/current-generation\" ;;
esac" > "$1"; /bin/chmod 700 "$1"; }
make_security() { print -r -- '#!/bin/zsh
[[ " $* " == *" -w "* ]] && print -- old-generation
exit 0' > "$1"; /bin/chmod 700 "$1"; }
typeset fake="$test_root/fake"; /bin/mkdir -p "$fake"
typeset keychain_state="$test_root/keychain-state"; /bin/mkdir "$keychain_state"; print -- old-generation > "$keychain_state/selector"
make_client "$fake/claude" 'claude 1.2.3'; make_client "$fake/opencode" 'opencode v2.2.1'; make_helper "$fake/jxa" "$root/installer/opencode-plugin.jxa"; make_keychain_helper "$fake/keychain-jxa" "$keychain_state"; make_security "$fake/security"
/usr/bin/touch "$fake/plugin-jxa"; /bin/chmod 600 "$fake/plugin-jxa"
typeset -a env=(AGENT_NOTIFY_INSTALL_HOME="$test_root/home" AGENT_NOTIFY_INSTALL_SKIP_PLATFORM_CHECK=1 AGENT_NOTIFY_INSTALL_MACOS_VERSION=14.5 AGENT_NOTIFY_INSTALL_CLAUDE_BIN="$fake/claude" AGENT_NOTIFY_INSTALL_OPENCODE_BIN="$fake/opencode" AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/security" AGENT_NOTIFY_INSTALL_JXA_BIN="$fake/jxa" AGENT_NOTIFY_INSTALL_KEYCHAIN_HELPER="$fake/keychain-jxa" AGENT_NOTIFY_INSTALL_SETTINGS_HELPER="$fake/jxa" AGENT_NOTIFY_INSTALL_PLUGIN_HELPER="$fake/plugin-jxa")
export $env
[[ $HOME == "$test_root"/* && $AGENT_NOTIFY_INSTALL_HOME == "$test_root"/* && $AGENT_NOTIFY_INSTALL_SECURITY_BIN == "$test_root"/* && -r $AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM ]] || { print -u2 -- 'suite isolation is not in place'; exit 1; }

env $env AGENT_NOTIFY_INSTALL_MACOS_VERSION=27.0.1 "$root/bin/agent-notify-install" --dry-run >/dev/null || { print -u2 -- 'macOS 27.0.1 preflight rejected'; exit 1; }
[[ ! -e "$test_root/home" && $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || { print -u2 -- 'macOS 27 dry-run mutated the fixture home or credentials'; exit 1; }
for version in 28.0 27.0.1.1; do
  for argument in --dry-run ''; do
    env $env AGENT_NOTIFY_INSTALL_MACOS_VERSION="$version" AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" ${argument:+$argument} </dev/null >"$test_root/rejected-macos-version.log" 2>&1 && { print -u2 -- 'unsupported macOS preflight accepted'; exit 1; }
    [[ $(<"$test_root/rejected-macos-version.log") == *'unsupported macOS version'* && ! -e "$test_root/home" && $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || { print -u2 -- 'unsupported macOS preflight did not stop before credentials/mutation'; exit 1; }
  done
done

for version in $rejected_opencode_versions; do
  make_client "$fake/version-opencode" "$version"
  for argument in --dry-run ''; do
    env $env AGENT_NOTIFY_INSTALL_OPENCODE_BIN="$fake/version-opencode" AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" ${argument:+$argument} </dev/null >"$test_root/rejected-version.log" 2>&1 && { print -u2 -- 'unsupported OpenCode preflight accepted'; exit 1; }
    [[ $(<"$test_root/rejected-version.log") == *'OpenCode version'* && ! -e "$test_root/home" && $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || { print -u2 -- 'unsupported OpenCode preflight did not stop before confirmation/credentials/mutation'; exit 1; }
  done
done
for version in $supported_opencode_versions; do
  make_client "$fake/version-opencode" "$version"
  env $env AGENT_NOTIFY_INSTALL_OPENCODE_BIN="$fake/version-opencode" "$root/bin/agent-notify-install" --dry-run >/dev/null || { print -u2 -- 'supported OpenCode preflight rejected'; exit 1; }
done
[[ ! -e "$test_root/home" && $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || { print -u2 -- 'supported OpenCode dry-run mutated the fixture home or credentials'; exit 1; }

typeset keychain_shim_log="$test_root/keychain-shim.log"
/usr/bin/touch "$keychain_shim_log"
print -rn -- '{"generation":"test-generation","user":"test-user","token":"test-token"}' | AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$root/tests/installer/fixtures/keychain-security-shim.jxa" AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM_LOG="$keychain_shim_log" /usr/bin/osascript -l JavaScript "$root/installer/keychain.jxa" store
print -rn -- '{"generation":"test-generation"}' | AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$root/tests/installer/fixtures/keychain-security-shim.jxa" AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM_LOG="$keychain_shim_log" /usr/bin/osascript -l JavaScript "$root/installer/keychain.jxa" remove
typeset keychain_shim_calls=$(<"$keychain_shim_log")
[[ $keychain_shim_calls == $'add agent-notify.pushover.v2.user-key.test-generation\nadd agent-notify.pushover.v2.app-token.test-generation\nlookup agent-notify.pushover.v2.active-generation\nadd agent-notify.pushover.v2.active-generation\nlookup agent-notify.pushover.v2.active-generation\nlookup agent-notify.pushover.v2.user-key.test-generation\nlookup agent-notify.pushover.v2.app-token.test-generation' ]] || { print -u2 -- 'Keychain Security queries were malformed or out of order'; exit 1; }
[[ $keychain_shim_calls != *test-user* && $keychain_shim_calls != *test-token* ]] || { print -u2 -- 'Keychain test shim logged credentials'; exit 1; }

typeset merged_settings="$test_root/merged-settings.json"
/usr/bin/osascript -l JavaScript "$root/installer/claude-settings.jxa" merge "$settings_fixture" "$merged_settings" '/tmp/agent-notify event'
[[ $(/usr/bin/osascript -l JavaScript "$root/installer/claude-settings.jxa" inspect "$merged_settings" - '/tmp/agent-notify event') == valid ]] || { print -u2 -- 'merged settings are invalid'; exit 1; }
typeset merged_content=$(<"$merged_settings")
[[ $merged_content == *keep-this* && $merged_content == *'agent-notify event completed'* ]] || { print -u2 -- 'settings merge lost entries'; exit 1; }
typeset merged_twice="$test_root/merged-twice.json" removed_settings="$test_root/removed-settings.json"
/usr/bin/osascript -l JavaScript "$root/installer/claude-settings.jxa" merge "$merged_settings" "$merged_twice" '/tmp/agent-notify event'
[[ $(<"$merged_settings") == $(<"$merged_twice") ]] || { print -u2 -- 'settings merge is not idempotent'; exit 1; }
/usr/bin/osascript -l JavaScript "$root/installer/claude-settings.jxa" remove-managed "$merged_twice" "$removed_settings" '/tmp/agent-notify event'
[[ $(<"$removed_settings") == *keep-this* && $(<"$removed_settings") != *'/tmp/agent-notify event'* ]] || { print -u2 -- 'managed settings removal was not exact'; exit 1; }
print -- '{"hooks":{"Stop":"conflict"}}' > "$test_root/conflicting-settings.json"
/usr/bin/osascript -l JavaScript "$root/installer/claude-settings.jxa" merge "$test_root/conflicting-settings.json" "$test_root/ignored.json" '/tmp/agent-notify event' >/dev/null 2>&1 && { print -u2 -- 'non-array hook conflict was clobbered'; exit 1; }
typeset staged_plugin="$test_root/agent-notify.js"
/usr/bin/osascript -l JavaScript "$root/installer/opencode-plugin.jxa" "$root/integrations/opencode/agent-notify.js" "$staged_plugin" '/tmp/agent-notify'
typeset plugin_content=$(<"$staged_plugin")
[[ $plugin_content == *'spawn(["/tmp/agent-notify", "event"], {'* && $plugin_content == *session_dir* && $plugin_content == *request_id* ]] || { print -u2 -- 'OpenCode template is not normalized or its absolute notifier path was not embedded'; exit 1; }
# helper_failure_check <name> <expected message> <helper and arguments>: a helper that cannot read or write fails with its own message. Reading an NSError out-parameter after a failed Foundation call crashes osascript with exit 139.
helper_failure_check() {
  local check_name=$1 check_message=$2 check_output check_code=0
  shift 2
  check_output=$(/usr/bin/osascript -l JavaScript "$@" 2>&1 </dev/null) || check_code=$?
  (( check_code == 1 )) || { print -ru2 -- "$check_output"; print -u2 -- "$check_name: expected exit 1, got $check_code"; exit 1; }
  [[ $check_output == *"$check_message"* ]] || { print -ru2 -- "$check_output"; print -u2 -- "$check_name: expected '$check_message'"; exit 1; }
}
typeset missing_path="$test_root/no-such-file" missing_parent="$test_root/no-such-directory/output"
# A directory exists but cannot be read as a file.
helper_failure_check 'settings merge from an unreadable path' 'unable to read Claude settings' "$root/installer/claude-settings.jxa" merge "$test_root" "$test_root/ignored.json" '/tmp/agent-notify event'
[[ $(/usr/bin/osascript -l JavaScript "$root/installer/claude-settings.jxa" inspect "$test_root" - '/tmp/agent-notify event') == unparseable ]] || { print -u2 -- 'settings inspection accepted an unreadable path'; exit 1; }
helper_failure_check 'plugin generation from a missing source' 'unable to read the OpenCode plugin source' "$root/installer/opencode-plugin.jxa" "$missing_path" "$test_root/ignored.js" '/tmp/agent-notify'
helper_failure_check 'manifest read of a missing file' 'unable to read the installation manifest' "$root/installer/manifest.jxa" "$missing_path" backup
AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$missing_path" helper_failure_check 'installer Keychain helper with a missing shim' 'Keychain security shim unavailable' "$root/installer/keychain.jxa" state
AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$missing_path" helper_failure_check 'runtime Keychain helper with a missing shim' 'Keychain security shim unavailable' "$root/lib/agent-notify/keychain.jxa"
helper_failure_check 'settings merge to an unwritable path' 'unable to write Claude settings' "$root/installer/claude-settings.jxa" merge "$merged_settings" "$missing_parent" '/tmp/agent-notify event'
helper_failure_check 'managed settings removal to an unwritable path' 'unable to write Claude settings' "$root/installer/claude-settings.jxa" remove-managed "$merged_settings" "$missing_parent" '/tmp/agent-notify event'
helper_failure_check 'plugin generation to an unwritable path' 'unable to write the OpenCode plugin' "$root/installer/opencode-plugin.jxa" "$root/integrations/opencode/agent-notify.js" "$missing_parent" '/tmp/agent-notify'
# A directory is readable by a permission check and a missing parent is not a permission failure, so neither stands in for these.
typeset denied_settings="$test_root/denied-settings.json" read_only_output="$test_root/read-only-output"
print -r -- '{"keep":true}' > "$denied_settings"
/bin/chmod 000 "$denied_settings"
helper_failure_check 'settings merge from a permission-denied file' 'unable to read Claude settings' "$root/installer/claude-settings.jxa" merge "$denied_settings" "$test_root/ignored.json" '/tmp/agent-notify event'
[[ $(/usr/bin/osascript -l JavaScript "$root/installer/claude-settings.jxa" inspect "$denied_settings" - '/tmp/agent-notify event') == unparseable ]] || { print -u2 -- 'settings inspection accepted a permission-denied file'; exit 1; }
/bin/mkdir "$read_only_output"
/bin/chmod 555 "$read_only_output"
helper_failure_check 'settings merge into a read-only directory' 'unable to write Claude settings' "$root/installer/claude-settings.jxa" merge "$merged_settings" "$read_only_output/settings.json" '/tmp/agent-notify event'
helper_failure_check 'plugin generation into a read-only directory' 'unable to write the OpenCode plugin' "$root/installer/opencode-plugin.jxa" "$root/integrations/opencode/agent-notify.js" "$read_only_output/agent-notify.js" '/tmp/agent-notify'
/bin/chmod 755 "$read_only_output"
# A parse error can quote its input, and this input holds credentials. The value here is made up.
typeset malformed_store_output malformed_store_code=0
malformed_store_output=$(print -rn -- '{"generation":"1-2","user":"x","y":FAKEUSERKEY","token":"t"}' | AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$root/tests/installer/fixtures/keychain-security-shim.jxa" AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM_LOG="$keychain_shim_log" /usr/bin/osascript -l JavaScript "$root/installer/keychain.jxa" store 2>&1) || malformed_store_code=$?
(( malformed_store_code == 1 )) || { print -ru2 -- "$malformed_store_output"; print -u2 -- "a malformed Keychain store did not fail: exit $malformed_store_code"; exit 1; }
[[ $malformed_store_output == *'invalid Keychain helper input'* && $malformed_store_output != *FAKEUSERKEY* ]] || { print -ru2 -- "$malformed_store_output"; print -u2 -- 'a malformed Keychain store echoed its input'; exit 1; }
typeset claude_event=$(print -rn -- '{"agent_type":"main","session_id":"session","cwd":"/tmp/project","notification_type":"permission_prompt","request_id":"request"}' | /usr/bin/osascript -l JavaScript "$root/integrations/claude/agent-notify-hook.jxa" attention)
[[ $claude_event == *'"session_dir":"/tmp/project"'* && $claude_event == *'"request_id":"request"'* ]] || { print -u2 -- 'Claude template is not normalized'; exit 1; }
typeset fallback_event=$(print -rn -- '{"agent_type":"main_agent","session_id":"session","cwd":"/tmp/project","notification_type":"permission_prompt"}' | /usr/bin/osascript -l JavaScript "$root/integrations/claude/agent-notify-hook.jxa" attention)
[[ $fallback_event == *'"request_id":"claude-notification:session:permission_prompt"'* ]] || { print -u2 -- 'Claude fallback request id missing'; exit 1; }
[[ -z $(print -rn -- '{"agent_type":"subagent","session_id":"session","cwd":"/tmp/project","notification_type":"permission_prompt"}' | /usr/bin/osascript -l JavaScript "$root/integrations/claude/agent-notify-hook.jxa" attention) ]] || { print -u2 -- 'subagent hook was not filtered'; exit 1; }
[[ -z $(print -rn -- '{"agent_type":"main","is_background":true,"session_id":"session","cwd":"/tmp/project","notification_type":"permission_prompt"}' | /usr/bin/osascript -l JavaScript "$root/integrations/claude/agent-notify-hook.jxa" attention) ]] || { print -u2 -- 'background hook was not filtered'; exit 1; }

make_client "$fake/bad-claude" 'claude unknown'
env $env AGENT_NOTIFY_INSTALL_CLAUDE_BIN="$fake/bad-claude" "$root/bin/agent-notify-install" --dry-run >/dev/null 2>&1 && { print -u2 -- 'unparseable client accepted'; exit 1; }
make_client "$fake/current-claude" 'claude 2.0.0'
env $env AGENT_NOTIFY_INSTALL_CLAUDE_BIN="$fake/current-claude" "$root/bin/agent-notify-install" --dry-run >/dev/null || { print -u2 -- 'current Claude Code version rejected'; exit 1; }
make_client "$fake/unsupported-claude" 'claude 3.0.0'
typeset unsupported_claude_output
if unsupported_claude_output=$(env $env AGENT_NOTIFY_INSTALL_CLAUDE_BIN="$fake/unsupported-claude" "$root/bin/agent-notify-install" --dry-run 2>&1); then
  print -u2 -- 'parseable unsupported client accepted'
  exit 1
fi
[[ $unsupported_claude_output == *'unsupported Claude Code version: 3.0.0'* ]] || { print -u2 -- 'unsupported Claude version was not reported verbatim'; exit 1; }
env $env AGENT_NOTIFY_INSTALL_SECURITY_BIN=/missing/security "$root/bin/agent-notify-install" --dry-run >/dev/null 2>&1 && { print -u2 -- 'missing prerequisite accepted'; exit 1; }
env $env AGENT_NOTIFY_INSTALL_CURL_BIN=/missing/curl "$root/bin/agent-notify-install" --dry-run >/dev/null 2>&1 && { print -u2 -- 'missing curl accepted'; exit 1; }
/bin/mkdir -p "$test_root/home/.claude"; print -- '{"hooks":{"Stop":"malformed"}}' > "$test_root/home/.claude/settings.json"
env $env AGENT_NOTIFY_INSTALL_JXA_BIN=/usr/bin/osascript AGENT_NOTIFY_INSTALL_SETTINGS_HELPER="$root/installer/claude-settings.jxa" "$root/bin/agent-notify-install" --dry-run >/dev/null 2>&1 && { print -u2 -- 'malformed nested Claude settings accepted'; exit 1; }
[[ ! -e "$test_root/home/.local/bin/agent-notify" ]] || { print -u2 -- 'malformed preflight wrote files'; exit 1; }
/bin/rm -f "$test_root/home/.claude/settings.json"
typeset plan=$(env $env "$root/bin/agent-notify-install" --dry-run)
[[ $plan == *'existing v2 credential generation: will be replaced'* ]] || { print -u2 -- 'existing v2 credentials were not disclosed'; exit 1; }
[[ $plan == *'Keychain migration: creates independent v2 credentials; legacy v1 items are not read, changed, or removed.'* && $plan == *'Keychain migration requires entering new Pushover credentials after confirmation.'* ]] || { print -u2 -- 'v2 Keychain migration was not disclosed'; exit 1; }
[[ $plan == *'Pushover and downstream push services receive agent name, a sanitized and bounded tmux-or-project display context, normalized state, and, when enabled and available, a sanitized bounded single-line excerpt.'* ]] || { print -u2 -- 'the complete transmitted notification data was not accurately disclosed'; exit 1; }
[[ $plan == *'When tmux is detected, the Claude adapter automatically performs a bounded lookup for the originating pane; a valid result uses its current innermost session name, otherwise the project basename is used.'* && $plan == *'Tmux is optional; its user-chosen innermost session name can be sensitive.'* ]] || { print -u2 -- 'the tmux privacy behavior was not disclosed'; exit 1; }
[[ $plan == *'OpenCode always uses the resolved session-directory project basename: its shared-server environment does not establish an originating pane, and this V2 adapter does not discover panes or perform tmux lookup.'* ]] || { print -u2 -- 'OpenCode project-only attribution was not disclosed'; exit 1; }
[[ $plan != *'tmux prerequisite'* && $plan != *'requires tmux'* ]] || { print -u2 -- 'the installer introduced a tmux prerequisite'; exit 1; }
[[ $plan == *'Claude completion excerpts use final assistant output; Claude failure excerpts use the categorical error identifier, never free-text error detail. OpenCode completion excerpts use relevant root-session assistant text available through native context; OpenCode failure excerpts use structured error message when present or error type otherwise, never response bodies. Excerpts are sanitized and bounded: the selected source is sent in full when it already fits the bound and truncated when longer; model output or OpenCode error messages can repeat sensitive content such as secrets or paths.'* ]] || { print -u2 -- 'the complete excerpt sources, bounds, and residual sensitivity were not disclosed'; exit 1; }
[[ $plan == *'Message excerpts are enabled by default; set EXCERPT=0 in '*'/settings.conf to stop sending them.'* ]] || { print -u2 -- 'the excerpt default and opt-out setting were not disclosed'; exit 1; }
[[ ! -e "$test_root/home/.local/bin/agent-notify" ]] || { print -u2 -- 'dry run wrote files'; exit 1; }
env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM=no "$root/bin/agent-notify-install" >/dev/null 2>&1
[[ ! -e "$test_root/home/.local/bin/agent-notify" ]] || { print -u2 -- 'decline wrote files'; exit 1; }
/bin/mkdir -p "$test_root/home/.claude"; print -- '{"unrelated":true}' > "$test_root/home/.claude/settings.json"; /bin/chmod 640 "$test_root/home/.claude/settings.json"
/bin/mkdir -p "$test_root/file-library/.local/lib"; print -- conflict > "$test_root/file-library/.local/lib/agent-notify"
env $env AGENT_NOTIFY_INSTALL_HOME="$test_root/file-library" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'regular-file library conflict was accepted'; exit 1; }
[[ $(<"$test_root/file-library/.local/lib/agent-notify") == conflict ]] || { print -u2 -- 'regular-file library conflict was clobbered'; exit 1; }
/bin/mkdir -p "$test_root/home/.local/bin"; print -- 'old notifier' > "$test_root/home/.local/bin/agent-notify"; /bin/chmod 755 "$test_root/home/.local/bin/agent-notify"
/bin/mkdir -p "$test_root/home/.local/lib/agent-notify"; print -- 'old library' > "$test_root/home/.local/lib/agent-notify/config.zsh"
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 AGENT_NOTIFY_INSTALL_PLUGIN_HELPER="$fake/failing-helper" "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'failed helper reported success'; exit 1; }
[[ $(<"$test_root/home/.local/bin/agent-notify") == 'old notifier' ]] || { print -u2 -- 'helper failure did not restore notifier'; exit 1; }
typeset -a failed_attempt_dirs; failed_attempt_dirs=("$test_root/home/Library/Application Support/agent-notify/install-backups"/*(N))
(( $#failed_attempt_dirs == 0 )) || { print -u2 -- 'pre-mutation helper failure left an attempt directory'; exit 1; }
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 AGENT_NOTIFY_INSTALL_FAIL_AT=library "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'library replacement failure reported success'; exit 1; }
[[ $(<"$test_root/home/.local/lib/agent-notify/config.zsh") == 'old library' ]] || { print -u2 -- 'library replacement failure did not restore prior tree'; exit 1; }
typeset empty_home="$test_root/empty-home"
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_HOME="$empty_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 AGENT_NOTIFY_INSTALL_FAIL_AT=plugin "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'first-time failure reported success'; exit 1; }
[[ ! -d "$empty_home/.local/bin" && ! -d "$empty_home/.config/opencode/plugins" && ! -d "$empty_home/.claude" ]] || { print -u2 -- 'first-time failure left attempt-created directories'; exit 1; }
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 AGENT_NOTIFY_INSTALL_FAIL_AT=plugin "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'injected failure succeeded'; exit 1; }
[[ $(<"$test_root/home/.local/bin/agent-notify") == 'old notifier' && $(/usr/bin/stat -f '%Lp' "$test_root/home/.local/bin/agent-notify") == 755 ]] || { print -u2 -- 'partial failure did not restore the prior notifier and mode'; exit 1; }
[[ $(<"$test_root/home/.local/lib/agent-notify/config.zsh") == 'old library' ]] || { print -u2 -- 'plugin failure did not restore prior library'; exit 1; }
[[ $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || { print -u2 -- 'Keychain selector rollback did not restore the prior generation'; exit 1; }
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 AGENT_NOTIFY_INSTALL_FAIL_AT=settings "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'settings failure succeeded'; exit 1; }
[[ $(<"$test_root/home/.claude/settings.json") == '{"unrelated":true}' ]] || { print -u2 -- 'settings preimage was not restored'; exit 1; }
[[ $(/usr/bin/stat -f '%Lp' "$test_root/home/.claude/settings.json") == 640 ]] || { print -u2 -- 'settings original mode was not restored'; exit 1; }
[[ ! -e "$test_root/home/.config/opencode/plugins/agent-notify.js" ]] || { print -u2 -- 'partial failure left a plugin behind'; exit 1; }
typeset success_output=$(print -- $'hiddenUser42\nhiddenToken42' | env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install")
[[ $success_output != *hiddenUser42* && $success_output != *hiddenToken42* ]] || { print -u2 -- 'credentials were emitted in installer output'; exit 1; }
[[ $success_output == *"  rollback: $root/bin/agent-notify-install --rollback (restores only artifacts whose hashes still match this install; changed files are left in place and reported)"* && $success_output != *'manually remove'* ]] || { print -u2 -- 'install summary did not give the real rollback command without removal advice'; exit 1; }
[[ $success_output == *"  notifier: $test_root/home/.local/bin/agent-notify"$'\n'* && $success_output == *"  Claude hook adapter: $test_root/home/.local/bin/agent-notify-claude-hook"$'\n'* && $success_output == *"  plugin: $test_root/home/.config/opencode/plugins/agent-notify.js"$'\n'* && $success_output == *"  settings: $test_root/home/.claude/settings.json"$'\n'* && $success_output == *"  backups: $test_root/home/Library/Application Support/agent-notify/install-backups/install."* && $success_output == *"  smoke test: $test_root/home/.local/bin/agent-notify smoke-test"$'\n'* ]] || { print -u2 -- 'install summary did not report the installed locations and the smoke-test command'; exit 1; }
[[ -x "$test_root/home/.local/bin/agent-notify" && -e "$test_root/home/.config/opencode/plugins/agent-notify.js" ]] || { print -u2 -- 'confirmed install missing artifact'; exit 1; }
[[ -r "$test_root/home/.local/lib/agent-notify/config.zsh" ]] || { print -u2 -- 'notifier library tree was not installed'; exit 1; }
typeset installed_hook="$test_root/home/.local/bin/agent-notify-claude-hook" installed_hook_jxa="$test_root/home/.local/bin/agent-notify-claude-hook.jxa" installed_plugin="$test_root/home/.config/opencode/plugins/agent-notify.js" installed_manifest="$test_root/home/Library/Application Support/agent-notify/install-manifest.json"
[[ $(/usr/bin/shasum -a 256 "$installed_hook" | /usr/bin/cut -d ' ' -f1) == $(/usr/bin/shasum -a 256 "$root/integrations/claude/agent-notify-hook.zsh" | /usr/bin/cut -d ' ' -f1) && $(/usr/bin/shasum -a 256 "$installed_hook_jxa" | /usr/bin/cut -d ' ' -f1) == $(/usr/bin/shasum -a 256 "$root/integrations/claude/agent-notify-hook.jxa" | /usr/bin/cut -d ' ' -f1) ]] || { print -u2 -- 'updated Claude adapter pair was not staged verbatim'; exit 1; }
[[ $(<$installed_plugin) == *'// >>> agent-notify managed plugin >>>'* ]] || { print -u2 -- 'generated OpenCode plugin omitted its managed marker'; exit 1; }
[[ $(/usr/bin/plutil -extract files.hook.path raw "$installed_manifest") == "$installed_hook" && $(/usr/bin/plutil -extract files.hook_jxa.path raw "$installed_manifest") == "$installed_hook_jxa" && $(/usr/bin/plutil -extract files.plugin.path raw "$installed_manifest") == "$installed_plugin" ]] || { print -u2 -- 'managed adapter paths were not recorded in the manifest'; exit 1; }
[[ $(/usr/bin/plutil -extract files.hook.post_hash raw "$installed_manifest") == $(/usr/bin/shasum -a 256 "$installed_hook" | /usr/bin/cut -d ' ' -f1) && $(/usr/bin/plutil -extract files.hook_jxa.post_hash raw "$installed_manifest") == $(/usr/bin/shasum -a 256 "$installed_hook_jxa" | /usr/bin/cut -d ' ' -f1) && $(/usr/bin/plutil -extract files.plugin.post_hash raw "$installed_manifest") == $(/usr/bin/shasum -a 256 "$installed_plugin" | /usr/bin/cut -d ' ' -f1) ]] || { print -u2 -- 'managed adapter hashes were not recorded in the manifest'; exit 1; }
[[ $(/usr/bin/plutil -extract files raw "$installed_manifest") != *tmux* ]] || { print -u2 -- 'tmux introduced an installed artifact'; exit 1; }
typeset installed_settings="$test_root/home/Library/Application Support/agent-notify/settings.conf"
[[ -r $installed_settings && $(<"$installed_settings") == *'EXCERPT=1'* ]] || { print -u2 -- 'the excerpt settings file was not created with the documented default'; exit 1; }
[[ $(/usr/bin/stat -f '%Lp' "$installed_settings") == 600 ]] || { print -u2 -- 'the excerpt settings file is not user-only'; exit 1; }
print -- 'EXCERPT=0' > "$test_root/generated-settings.conf"
env HOME="$test_root/home" AGENT_NOTIFY_SETTINGS_FILE="$test_root/generated-settings.conf" TMUX=server-socket TMUX_PANE=%99 node "$root/tests/installer/generated-plugin.test.mjs" "$installed_plugin" "$test_root/home/.local/bin/agent-notify"
print -rn -- '{"agent_type":"main","session_id":"installed","cwd":"/tmp/project","notification_type":"permission_prompt"}' | env -u TMUX -u TMUX_PANE HOME="$test_root/home" "$test_root/home/.local/bin/agent-notify-claude-hook" attention
typeset -a hook_diagnostics hook_states
hook_diagnostics=("$test_root/home/Library/Application Support/agent-notify/diagnostics"/diagnostics-*.log(N))
hook_states=("$test_root/home/Library/Application Support/agent-notify/state"/*.state(N))
(( $#hook_diagnostics == 1 && $#hook_states == 1 )) && [[ $(<"$hook_diagnostics[1]") == *' component=keychain code=runtime_-50 '* ]] || { print -u2 -- 'installed hook did not stop at the blocked delivery attempt inside the test home'; exit 1; }
[[ -z $(print -rn -- '{"agent":{"type":"subagent"},"session_id":"installed","cwd":"/tmp/project","notification_type":"permission_prompt"}' | env -u TMUX -u TMUX_PANE /usr/bin/osascript -l JavaScript "$test_root/home/.local/bin/agent-notify-claude-hook.jxa" attention) ]] || { print -u2 -- 'installed nested subagent adapter was not filtered'; exit 1; }
[[ -z $(print -rn -- '{"agentType":"background","session_id":"installed","cwd":"/tmp/project","notification_type":"permission_prompt"}' | env -u TMUX -u TMUX_PANE /usr/bin/osascript -l JavaScript "$test_root/home/.local/bin/agent-notify-claude-hook.jxa" attention) ]] || { print -u2 -- 'installed agentType adapter was not filtered'; exit 1; }
typeset -a settings_backups; settings_backups=("$test_root/home/Library/Application Support/agent-notify/install-backups"/*/settings.json(N))
(( $#settings_backups > 0 )) || { print -u2 -- 'settings backup missing'; exit 1; }
/bin/cp "$root/lib/agent-notify/config.zsh" "$test_root/home/.local/lib/agent-notify/config.zsh"; print -- '# external library change' >> "$test_root/home/.local/lib/agent-notify/config.zsh"
env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'library conflict was overwritten'; exit 1; }
[[ $(<"$test_root/home/.local/lib/agent-notify/config.zsh") == *'external library change'* ]] || { print -u2 -- 'library conflict was clobbered'; exit 1; }
/bin/cp "$root/lib/agent-notify/config.zsh" "$test_root/home/.local/lib/agent-notify/config.zsh"
env $env AGENT_NOTIFY_INSTALL_CLAUDE_BIN=/missing/claude AGENT_NOTIFY_INSTALL_OPENCODE_BIN=/missing/opencode AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=no "$root/bin/agent-notify-install" --rollback >/dev/null
[[ $(<"$test_root/home/.claude/settings.json") == '{"unrelated":true}' && $(/usr/bin/stat -f '%Lp' "$test_root/home/.claude/settings.json") == 640 ]] || { print -u2 -- 'unchanged settings rollback did not restore exact backup bytes and mode'; exit 1; }
print -- 'EXCERPT=0' > "$installed_settings"
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" >/dev/null
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" >/dev/null || { print -u2 -- 'exact reinstall falsely reported a conflict'; exit 1; }
[[ $(<"$installed_settings") == 'EXCERPT=0' ]] || { print -u2 -- 'a reinstall overwrote the excerpt setting'; exit 1; }
print -- '// >>> agent-notify managed plugin >>>' > "$test_root/home/.config/opencode/plugins/agent-notify.js"
print -- '{"changed":true}' > "$test_root/home/.claude/settings.json"
env $env AGENT_NOTIFY_INSTALL_CLAUDE_BIN=/missing/claude AGENT_NOTIFY_INSTALL_OPENCODE_BIN=/missing/opencode AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=no "$root/bin/agent-notify-install" --rollback >/dev/null
[[ -x "$test_root/home/.local/bin/agent-notify" && -x "$test_root/home/.local/bin/agent-notify-claude-hook" && -r "$test_root/home/.local/bin/agent-notify-claude-hook.jxa" && $(/usr/bin/stat -f '%Lp' "$test_root/home/.local/bin/agent-notify-claude-hook.jxa") == 600 ]] || { print -u2 -- 'selective rollback did not restore prior managed artifacts'; exit 1; }
[[ $(<"$test_root/home/.config/opencode/plugins/agent-notify.js") == '// >>> agent-notify managed plugin >>>' ]] || { print -u2 -- 'selective rollback clobbered changed plugin'; exit 1; }
[[ $(<"$test_root/home/.claude/settings.json") == '{"changed":true}' ]] || { print -u2 -- 'selective rollback clobbered changed settings'; exit 1; }
env $env AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'plugin conflict was overwritten'; exit 1; }
[[ $(<"$test_root/home/.config/opencode/plugins/agent-notify.js") == '// >>> agent-notify managed plugin >>>' ]] || { print -u2 -- 'marker-only plugin conflict clobbered'; exit 1; }
typeset race_home="$test_root/race-home"
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_HOME="$race_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 AGENT_NOTIFY_INSTALL_TEST_CREATE_SETTINGS_BEFORE_RENAME=1 "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'appearing settings TOCTOU was overwritten'; exit 1; }
[[ -e "$race_home/.claude/settings.json" && ! -e "$race_home/.local/bin/agent-notify" ]] || { print -u2 -- 'settings appearance race did not remain write-safe'; exit 1; }

# A prior manifest owns exact V1 bytes, not merely the marker. Update in place,
# retaining backups outside discovery and restoring original bytes/modes on failure.
typeset v1_home="$test_root/v1-home" v1_plugin="$test_root/v1-home/.config/opencode/plugins/agent-notify.js"
typeset v1_manifest="$test_root/v1-home/Library/Application Support/agent-notify/install-manifest.json"
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_HOME="$v1_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" >/dev/null
print -r -- $'// >>> agent-notify managed plugin >>>\nexport default async function agentNotifyPlugin() { return { event: async () => {} }; }' > "$v1_plugin"
/bin/chmod 640 "$v1_plugin"
typeset v1_hash=$(/usr/bin/shasum -a 256 "$v1_plugin" | /usr/bin/cut -d ' ' -f1)
/usr/bin/plutil -replace files.plugin.post_hash -string "$v1_hash" "$v1_manifest"
/bin/cp -p "$v1_plugin" "$test_root/v1-preimage.js"
/bin/cp -p "$v1_manifest" "$test_root/v1-preimage-manifest.json"
print -- '// unrelated plugin' > "$v1_home/.config/opencode/plugins/unrelated.js"
print -- '{"unrelated":true}' > "$v1_home/.config/opencode/opencode.json"
print -- old-generation > "$keychain_state/selector"
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_HOME="$v1_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 AGENT_NOTIFY_INSTALL_FAIL_AT=settings "$root/bin/agent-notify-install" >/dev/null 2>&1 && { print -u2 -- 'V1 update failure reported success'; exit 1; }
[[ $(<"$v1_plugin") == $(<"$test_root/v1-preimage.js") && $(/usr/bin/stat -f '%Lp' "$v1_plugin") == 640 && $(<"$v1_manifest") == $(<"$test_root/v1-preimage-manifest.json") && $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || { print -u2 -- 'failed V1 update did not restore plugin bytes/mode, manifest, and v2 selector'; exit 1; }
print -- $'user\ntoken' | env $env AGENT_NOTIFY_INSTALL_HOME="$v1_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" >/dev/null || { print -u2 -- 'exact manifest-owned V1 update falsely reported a conflict'; exit 1; }
typeset v1_backup=$(/usr/bin/plutil -extract backup raw "$v1_manifest")
[[ $(<"$v1_backup/agent-notify.js") == $(<"$test_root/v1-preimage.js") && $v1_backup == "$v1_home/Library/Application Support/agent-notify/install-backups/"* && $(/usr/bin/stat -f '%Lp' "$v1_backup") == 700 && $(/usr/bin/stat -f '%Lp' "$v1_backup/agent-notify.js") == 600 && $(/usr/bin/stat -f '%Lp' "$v1_plugin") == 600 ]] || { print -u2 -- 'V1 update backup layout/bytes/modes changed'; exit 1; }
[[ $(<"$v1_plugin") != $(<"$test_root/v1-preimage.js") && $(/usr/bin/plutil -extract files.plugin.post_hash raw "$v1_manifest") == $(/usr/bin/shasum -a 256 "$v1_plugin" | /usr/bin/cut -d ' ' -f1) ]] || { print -u2 -- 'V1 update did not replace the managed artifact and record its hash'; exit 1; }
typeset -a discoverable_plugins; discoverable_plugins=("$v1_home/.config/opencode/plugins"/*(N))
(( $#discoverable_plugins == 2 )) || { print -u2 -- 'V1 update left a discoverable legacy/backup plugin'; exit 1; }
env HOME="$v1_home" AGENT_NOTIFY_SETTINGS_FILE="$test_root/generated-settings.conf" TMUX=server-socket TMUX_PANE=%99 node "$root/tests/installer/generated-plugin.test.mjs" "$v1_plugin" "$v1_home/.local/bin/agent-notify"
env $env AGENT_NOTIFY_INSTALL_HOME="$v1_home" AGENT_NOTIFY_INSTALL_CLAUDE_BIN=/missing/claude AGENT_NOTIFY_INSTALL_OPENCODE_BIN=/missing/opencode AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=no "$root/bin/agent-notify-install" --rollback >/dev/null
[[ $(<"$v1_plugin") == $(<"$test_root/v1-preimage.js") && $(/usr/bin/stat -f '%Lp' "$v1_plugin") == 640 ]] || { print -u2 -- 'V1 selective rollback did not restore exact prior bytes/mode'; exit 1; }
[[ $(<"$v1_home/.config/opencode/plugins/unrelated.js") == '// unrelated plugin' && $(<"$v1_home/.config/opencode/opencode.json") == '{"unrelated":true}' ]] || { print -u2 -- 'V1 migration/rollback changed unrelated OpenCode files'; exit 1; }

# A marker-bearing V1 artifact changed after ownership was recorded must be refused.
/usr/bin/plutil -replace files.plugin.post_hash -string "$v1_hash" "$v1_manifest"
print -- '// external V1 edit' >> "$v1_plugin"
typeset changed_v1=$(<"$v1_plugin")
env $env AGENT_NOTIFY_INSTALL_HOME="$v1_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no "$root/bin/agent-notify-install" </dev/null >/dev/null 2>&1 && { print -u2 -- 'changed manifest-owned V1 plugin was overwritten'; exit 1; }
[[ $(<"$v1_plugin") == "$changed_v1" && $(/usr/bin/stat -f '%Lp' "$v1_plugin") == 640 ]] || { print -u2 -- 'changed V1 plugin refusal altered bytes/mode'; exit 1; }
typeset unmanaged_home="$test_root/unmanaged-home"
/bin/mkdir -p "$unmanaged_home/.config/opencode/plugins"
/bin/cp -p "$test_root/v1-preimage.js" "$unmanaged_home/.config/opencode/plugins/agent-notify.js"
env $env AGENT_NOTIFY_INSTALL_HOME="$unmanaged_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no "$root/bin/agent-notify-install" </dev/null >/dev/null 2>&1 && { print -u2 -- 'unmanaged V1 plugin was overwritten'; exit 1; }
[[ $(<"$unmanaged_home/.config/opencode/plugins/agent-notify.js") == $(<"$test_root/v1-preimage.js") && ! -e "$unmanaged_home/.local/bin/agent-notify" ]] || { print -u2 -- 'unmanaged V1 plugin refusal mutated the home'; exit 1; }
# rollback tests: support
print -r -- '#!/bin/zsh
if [[ $3 == *keychain-jxa ]]; then "$3" "${@:4}"; exit $?; fi
exec /usr/bin/osascript "$@"' > "$fake/real-jxa"; /bin/chmod 700 "$fake/real-jxa"
print -r -- 'ObjC.import("Foundation");
const processArguments = $.NSProcessInfo.processInfo.arguments;
const args = [];
for (let index = 0; index < processArguments.count; index += 1) args.push(ObjC.unwrap(processArguments.objectAtIndex(index)));
const [file, field, value] = args.slice(4);
const manifest = JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null)));
const keys = field.split(".");
const last = keys.pop();
const parent = keys.reduce((object, key) => object[key], manifest);
if (value === undefined) delete parent[last];
else parent[last] = JSON.parse(value);
$(JSON.stringify(manifest)).writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null);' > "$fake/manifest-tamper.jxa"
typeset -a real_env=($env AGENT_NOTIFY_INSTALL_JXA_BIN="$fake/real-jxa" AGENT_NOTIFY_INSTALL_SETTINGS_HELPER="$root/installer/claude-settings.jxa" AGENT_NOTIFY_INSTALL_PLUGIN_HELPER="$root/installer/opencode-plugin.jxa")
# Label, path under the home, and backup item name, in the order rollback validates them.
typeset -a managed_artifacts=(binary .local/bin/agent-notify agent-notify library .local/lib/agent-notify lib hook .local/bin/agent-notify-claude-hook agent-notify-claude-hook hook_jxa .local/bin/agent-notify-claude-hook.jxa agent-notify-claude-hook.jxa plugin .config/opencode/plugins/agent-notify.js agent-notify.js settings .claude/settings.json settings.json)
typeset artifact_label artifact_path artifact_backup rollback_output
fail_with() { print -ru2 -- "$2"; print -u2 -- "$1"; exit 1; }
manifest_file() { print -r -- "$1/Library/Application Support/agent-notify/install-manifest.json"; }
manifest_value() { /usr/bin/plutil -extract "$2" raw "$(manifest_file "$1")"; }
# manifest_tamper <manifest> <field> [<json value>]: without a value, the field is deleted.
manifest_tamper() { /usr/bin/osascript -l JavaScript "$fake/manifest-tamper.jxa" "$@" >/dev/null; }
real_install() {
  local install_output
  install_output=$(print -- $'user\ntoken' | env $real_env AGENT_NOTIFY_INSTALL_HOME="$1" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE="$2" AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" 2>&1) || fail_with "real install failed in $1" "$install_output"
}
real_rollback() {
  local rollback_home=$1 rollback_confirm=$2; shift 2
  env $real_env AGENT_NOTIFY_INSTALL_HOME="$rollback_home" AGENT_NOTIFY_INSTALL_CLAUDE_BIN=/missing/claude AGENT_NOTIFY_INSTALL_OPENCODE_BIN=/missing/opencode AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE="$rollback_confirm" "$root/bin/agent-notify-install" --rollback "$@" 2>&1
}
must_rollback() { rollback_output=$(real_rollback "$@") || fail_with "rollback failed in $1" "$rollback_output"; }
managed_tree() {
  (
    cd "$1" || exit 1
    local top entry
    for top in .local .config .claude; do
      [[ -e $top ]] || continue
      /usr/bin/find "$top" -print | /usr/bin/sort | while IFS= read -r entry; do
        if [[ -L $entry ]]; then print -r -- "link $entry -> $(/usr/bin/readlink "$entry")"
        elif [[ -d $entry ]]; then print -r -- "dir $(/usr/bin/stat -f '%Lp' "$entry") $entry"
        else print -r -- "file $(/usr/bin/stat -f '%Lp' "$entry") $(/usr/bin/shasum -a 256 "$entry" | /usr/bin/cut -d ' ' -f1) $entry"; fi
      done
    done
  )
}
# managed_part <tree> <path>: the lines of one artifact, including everything under a directory.
managed_part() { print -r -- "$1" | /usr/bin/grep -E " $2(/| -> |\$)"; }
assert_tree() {
  local actual
  actual=$(managed_tree "$1")
  [[ $actual == "$2" ]] && return 0
  print -u2 -- "$3"
  /usr/bin/diff <(print -r -- "$2") <(print -r -- "$actual") >&2 || true
  exit 1
}
seed_prior_install() {
  /bin/mkdir -p "$1/.local/bin" "$1/.local/lib/agent-notify/nested" "$1/.config/opencode/plugins" "$1/.claude"
  print -r -- 'seed notifier' > "$1/.local/bin/agent-notify"; /bin/chmod 755 "$1/.local/bin/agent-notify"
  print -r -- '# seed library' > "$1/.local/lib/agent-notify/config.zsh"; /bin/chmod 644 "$1/.local/lib/agent-notify/config.zsh"
  print -r -- '# seed group-writable library file' > "$1/.local/lib/agent-notify/shared.zsh"; /bin/chmod 664 "$1/.local/lib/agent-notify/shared.zsh"
  print -r -- '# seed nested library file' > "$1/.local/lib/agent-notify/nested/inner.zsh"; /bin/chmod 640 "$1/.local/lib/agent-notify/nested/inner.zsh"
  /bin/chmod 750 "$1/.local/lib/agent-notify/nested"
  print -r -- 'seed hook' > "$1/.local/bin/agent-notify-claude-hook"; /bin/chmod 750 "$1/.local/bin/agent-notify-claude-hook"
  print -r -- '// seed hook jxa' > "$1/.local/bin/agent-notify-claude-hook.jxa"; /bin/chmod 740 "$1/.local/bin/agent-notify-claude-hook.jxa"
  print -r -- '// seed plugin' > "$1/.config/opencode/plugins/agent-notify.js"; /bin/chmod 604 "$1/.config/opencode/plugins/agent-notify.js"
  print -r -- '{"seed":"prior"}' > "$1/.claude/settings.json"; /bin/chmod 660 "$1/.claude/settings.json"
}

# rollback tests: manifest helper
typeset helper_fixture="$test_root/helper-fixture.json" helper_field helper_expected
print -r -- '{"text":"value","number":1,"boolean":true,"array":[],"object":{},"null":null,"files":{"numeric_yes":{"existed":1},"numeric_no":{"existed":0},"boolean_yes":{"existed":true},"boolean_no":{"existed":false},"two":{"existed":2},"negative":{"existed":-1},"fraction":{"existed":1.5},"string_one":{"existed":"1"},"string_zero":{"existed":"0"},"string_true":{"existed":"true"},"string_false":{"existed":"false"},"string_empty":{"existed":""},"null":{"existed":null},"array":{"existed":[]},"object":{"existed":{}},"absent":{}}}' > "$helper_fixture"
helper_read() { /usr/bin/osascript -l JavaScript "$root/installer/manifest.jxa" "$helper_fixture" "$1" 2>/dev/null; }
for helper_field helper_expected in files.numeric_yes.existed true files.numeric_no.existed false files.boolean_yes.existed true files.boolean_no.existed false text value; do
  [[ $(helper_read "$helper_field") == "$helper_expected" ]] || { print -u2 -- "manifest helper misread $helper_field"; exit 1; }
done
for helper_field in number boolean array object null missing files.two.existed files.negative.existed files.fraction.existed files.string_one.existed files.string_zero.existed files.string_true.existed files.string_false.existed files.string_empty.existed files.null.existed files.array.existed files.object.existed files.absent.existed; do
  helper_read "$helper_field" >/dev/null && { print -u2 -- "manifest helper accepted $helper_field"; exit 1; }
done

# rollback tests: first install
typeset first_home="$test_root/first-home" first_generation
/bin/rm -f "$keychain_state/removed"
real_install "$first_home" yes
first_generation=$(manifest_value "$first_home" generation)
must_rollback "$first_home" no
[[ $rollback_output == 'Selective rollback complete.' ]] || fail_with 'first-install rollback did not print exactly the completion line' "$rollback_output"
for artifact_label artifact_path artifact_backup in $managed_artifacts; do
  [[ ! -e "$first_home/$artifact_path" && ! -L "$first_home/$artifact_path" ]] || fail_with "first-install rollback left $artifact_label" "$rollback_output"
done
[[ $(<"$keychain_state/selector") == "$first_generation" && ! -e "$keychain_state/removed" ]] || { print -u2 -- 'declining credential removal changed Keychain state'; exit 1; }
must_rollback "$first_home" yes
[[ $(<"$keychain_state/removed") == "{\"generation\":\"$first_generation\",\"previous\":\"\"}" && ! -e "$keychain_state/selector" ]] || fail_with 'confirming credential removal did not remove the generation the manifest records' "$rollback_output"

typeset first_shim="$test_root/first-keychain-shim.jxa" first_shim_log="$test_root/first-keychain-shim.log" first_shim_source first_shim_items
first_shim_source=$(<"$root/tests/installer/fixtures/keychain-security-shim.jxa")
first_shim_items="new Set(['agent-notify.pushover.v2.active-generation', 'agent-notify.pushover.v2.user-key.test-generation', 'agent-notify.pushover.v2.app-token.test-generation'])"
print -r -- "${first_shim_source/'new Set()'/$first_shim_items}" > "$first_shim"
/usr/bin/touch "$first_shim_log"
print -rn -- '{"generation":"test-generation","previous":""}' | AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$first_shim" AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM_LOG="$first_shim_log" /usr/bin/osascript -l JavaScript "$root/installer/keychain.jxa" remove
[[ $(<"$first_shim_log") == $'lookup agent-notify.pushover.v2.active-generation\nremove agent-notify.pushover.v2.active-generation\nlookup agent-notify.pushover.v2.user-key.test-generation\nremove agent-notify.pushover.v2.user-key.test-generation\nlookup agent-notify.pushover.v2.app-token.test-generation\nremove agent-notify.pushover.v2.app-token.test-generation' ]] || fail_with 'Keychain removal did not touch exactly the selector and the recorded generation' "$(<"$first_shim_log")"

# An existing selector takes the update branch, on a reinstall and on a rollback. A fresh shim never reaches it.
typeset update_shim="$test_root/update-keychain-shim.jxa" update_shim_log="$test_root/update-keychain-shim.log" update_shim_items="new Set(['agent-notify.pushover.v2.active-generation'])"
print -r -- "${first_shim_source/'new Set()'/$update_shim_items}" > "$update_shim"
/usr/bin/touch "$update_shim_log"
print -rn -- '{"generation":"next-generation","user":"test-user","token":"test-token"}' | AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$update_shim" AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM_LOG="$update_shim_log" /usr/bin/osascript -l JavaScript "$root/installer/keychain.jxa" store
[[ $(<"$update_shim_log") == $'add agent-notify.pushover.v2.user-key.next-generation\nadd agent-notify.pushover.v2.app-token.next-generation\nlookup agent-notify.pushover.v2.active-generation\nupdate agent-notify.pushover.v2.active-generation' ]] || { print -u2 -- 'a store with an existing selector did not update it'; exit 1; }
: > "$update_shim_log"
print -rn -- '{"generation":"next-generation","selector":"prior-generation"}' | AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$update_shim" AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM_LOG="$update_shim_log" /usr/bin/osascript -l JavaScript "$root/installer/keychain.jxa" rollback
[[ $(<"$update_shim_log") == *$'update agent-notify.pushover.v2.active-generation\n'* ]] || { print -u2 -- 'a rollback with an existing selector did not update it'; exit 1; }

typeset first_edited_home="$test_root/first-edited-home" first_settings_home="$test_root/first-settings-home"
real_install "$first_edited_home" yes
print -r -- '{"edited":true}' > "$first_edited_home/.claude/settings.json"
must_rollback "$first_edited_home" no
[[ $(<"$first_edited_home/.claude/settings.json") == '{"edited":true}' ]] || fail_with 'first-install rollback clobbered edited settings' "$rollback_output"
[[ $rollback_output == "rollback: left changed Claude settings in place; manually remove commands beginning with $first_edited_home/.local/bin/agent-notify-claude-hook"$'\nSelective rollback complete.' ]] || fail_with 'edited settings the install created did not print exactly the manual-removal message' "$rollback_output"

/bin/mkdir -p "$first_settings_home/.claude"; print -r -- '{"seed":"settings"}' > "$first_settings_home/.claude/settings.json"
real_install "$first_settings_home" yes
print -r -- '{"edited":true}' > "$first_settings_home/.claude/settings.json"
must_rollback "$first_settings_home" no
[[ ! -e "$first_settings_home/.local/bin/agent-notify-claude-hook" && $(<"$first_settings_home/.claude/settings.json") == '{"edited":true}' ]] || fail_with 'rollback over existing edited settings did not remove the adapter and keep the edits' "$rollback_output"
[[ $rollback_output == "rollback: left changed Claude settings in place; manually remove commands beginning with $first_settings_home/.local/bin/agent-notify-claude-hook"$'\nSelective rollback complete.' ]] || fail_with 'edited settings with the adapter gone did not print exactly the manual-removal message' "$rollback_output"

# rollback tests: upgrade
typeset upgrade_home="$test_root/upgrade-home" upgrade_before upgrade_flag_form upgrade_flags_home upgrade_manifest upgrade_library_home="$test_root/upgrade-library-home"
seed_prior_install "$upgrade_home"
upgrade_before=$(managed_tree "$upgrade_home")
real_install "$upgrade_home" yes
[[ $(managed_tree "$upgrade_home") != "$upgrade_before" ]] || { print -u2 -- 'upgrade install changed nothing to roll back'; exit 1; }
must_rollback "$upgrade_home" no
[[ $rollback_output == 'Selective rollback complete.' ]] || fail_with 'upgrade rollback did not print exactly the completion line' "$rollback_output"
assert_tree "$upgrade_home" "$upgrade_before" 'upgrade rollback did not restore the prior tree exactly'
must_rollback "$upgrade_home" no
assert_tree "$upgrade_home" "$upgrade_before" 'a repeat upgrade rollback changed files'
[[ -r "$upgrade_home/Library/Application Support/agent-notify/settings.conf" ]] || { print -u2 -- 'rollback removed the excerpt settings file'; exit 1; }

for upgrade_flag_form in numeric boolean; do
  upgrade_flags_home="$test_root/upgrade-$upgrade_flag_form-home"
  seed_prior_install "$upgrade_flags_home"
  /bin/rm -f "$upgrade_flags_home/.local/bin/agent-notify-claude-hook" "$upgrade_flags_home/.config/opencode/plugins/agent-notify.js"
  upgrade_before=$(managed_tree "$upgrade_flags_home")
  real_install "$upgrade_flags_home" yes
  upgrade_manifest=$(manifest_file "$upgrade_flags_home")
  if [[ $upgrade_flag_form == boolean ]]; then
    for artifact_label artifact_path artifact_backup in $managed_artifacts; do
      if [[ $artifact_label == (hook|plugin) ]]; then manifest_tamper "$upgrade_manifest" "files.$artifact_label.existed" false
      else manifest_tamper "$upgrade_manifest" "files.$artifact_label.existed" true; fi
    done
    [[ $(<"$upgrade_manifest") == *'"existed":true'* && $(<"$upgrade_manifest") == *'"existed":false'* && $(<"$upgrade_manifest") != *'"existed":1'* && $(<"$upgrade_manifest") != *'"existed":0'* ]] || { print -u2 -- 'manifest does not hold boolean flags'; exit 1; }
  else
    [[ $(<"$upgrade_manifest") == *'"existed":1'* && $(<"$upgrade_manifest") == *'"existed":0'* ]] || { print -u2 -- 'manifest does not hold numeric flags'; exit 1; }
  fi
  must_rollback "$upgrade_flags_home" no
  [[ $rollback_output == 'Selective rollback complete.' ]] || fail_with "$upgrade_flag_form flag rollback did not print exactly the completion line" "$rollback_output"
  assert_tree "$upgrade_flags_home" "$upgrade_before" "$upgrade_flag_form flag rollback did not restore and remove exactly"
done

seed_prior_install "$upgrade_library_home"
/bin/rm -f "$upgrade_library_home/.local/bin/agent-notify" "$upgrade_library_home/.local/bin/agent-notify-claude-hook" "$upgrade_library_home/.local/bin/agent-notify-claude-hook.jxa" "$upgrade_library_home/.config/opencode/plugins/agent-notify.js" "$upgrade_library_home/.claude/settings.json"
upgrade_before=$(managed_tree "$upgrade_library_home")
real_install "$upgrade_library_home" yes
[[ ! -e "$(manifest_value "$upgrade_library_home" backup)/modes" ]] || { print -u2 -- 'a library-only install unexpectedly recorded file modes'; exit 1; }
must_rollback "$upgrade_library_home" no
[[ $rollback_output == 'Selective rollback complete.' ]] || fail_with 'library-only rollback did not print exactly the completion line' "$rollback_output"
assert_tree "$upgrade_library_home" "$upgrade_before" 'library-only rollback did not restore the library and remove the rest'

# rollback tests: selective
selective_check() {
  local check_home=$1 check_before check_edited check_after; shift
  local -a changed=($@)
  seed_prior_install "$check_home"
  check_before=$(managed_tree "$check_home")
  real_install "$check_home" yes
  for artifact_label artifact_path artifact_backup in $managed_artifacts; do
    (( ${changed[(Ie)$artifact_label]} )) || continue
    case $artifact_label in
      library) print -r -- '# selective change' >> "$check_home/$artifact_path/config.zsh" ;;
      settings) print -r -- '{"selective":true}' > "$check_home/$artifact_path" ;;
      *) print -r -- '// selective change' >> "$check_home/$artifact_path" ;;
    esac
  done
  check_edited=$(managed_tree "$check_home")
  must_rollback "$check_home" no
  check_after=$(managed_tree "$check_home")
  for artifact_label artifact_path artifact_backup in $managed_artifacts; do
    if (( ${changed[(Ie)$artifact_label]} )); then
      [[ $(managed_part "$check_after" "$artifact_path") == $(managed_part "$check_edited" "$artifact_path") ]] || fail_with "selective rollback did not keep changed $artifact_label" "$rollback_output"
      [[ $artifact_label == settings || $rollback_output == *"rollback: left externally changed $artifact_label in place"* ]] || fail_with "selective rollback did not report changed $artifact_label" "$rollback_output"
    else
      [[ $(managed_part "$check_after" "$artifact_path") == $(managed_part "$check_before" "$artifact_path") ]] || fail_with "selective rollback did not restore $artifact_label with its mode" "$rollback_output"
      [[ $rollback_output != *"changed $artifact_label in place"* ]] || fail_with "selective rollback falsely reported $artifact_label" "$rollback_output"
    fi
  done
}
typeset selective_home="$test_root/selective-a-home"
selective_check "$selective_home" binary library settings
[[ $rollback_output == *"rollback: left changed Claude settings in place; compare them with $(manifest_value "$selective_home" backup)/settings.json, and remove commands beginning with $selective_home/.local/bin/agent-notify-claude-hook only if the notifier is no longer wanted"* ]] || fail_with 'changed prior settings with the adapter present did not name the backup to compare with' "$rollback_output"
[[ $rollback_output != *'manually remove'* ]] || fail_with 'changed prior settings with the adapter present told the user to remove working hooks' "$rollback_output"
selective_check "$test_root/selective-b-home" hook hook_jxa plugin
[[ $rollback_output != *'Claude settings'* ]] || fail_with 'unchanged settings were reported as changed' "$rollback_output"

typeset selective_link_home="$test_root/selective-link-home" selective_targets="$test_root/selective-link-targets" selective_before selective_edited selective_after selective_targets_before
seed_prior_install "$selective_link_home"
selective_before=$(managed_tree "$selective_link_home")
real_install "$selective_link_home" yes
/bin/mkdir -p "$selective_targets/.local"
for artifact_label artifact_path artifact_backup in $managed_artifacts; do
  [[ $artifact_label == (binary|library|settings) ]] || continue
  /bin/cp -pR "$selective_link_home/$artifact_path" "$selective_targets/.local/$artifact_backup"
  /bin/rm -rf "$selective_link_home/$artifact_path"
  /bin/ln -s "$selective_targets/.local/$artifact_backup" "$selective_link_home/$artifact_path"
done
selective_edited=$(managed_tree "$selective_link_home")
selective_targets_before=$(managed_tree "$selective_targets")
must_rollback "$selective_link_home" no
selective_after=$(managed_tree "$selective_link_home")
assert_tree "$selective_targets" "$selective_targets_before" 'rollback changed the target of a managed symbolic link'
for artifact_label artifact_path artifact_backup in $managed_artifacts; do
  if [[ $artifact_label == (binary|library|settings) ]]; then
    [[ $(managed_part "$selective_after" "$artifact_path") == $(managed_part "$selective_edited" "$artifact_path") && $(managed_part "$selective_after" "$artifact_path") == link\ * ]] || fail_with "rollback replaced the symbolic link at $artifact_label" "$rollback_output"
    [[ $artifact_label == settings || $rollback_output == *"rollback: left externally changed $artifact_label in place"* ]] || fail_with "rollback did not report the symbolic link at $artifact_label" "$rollback_output"
  else
    [[ $(managed_part "$selective_after" "$artifact_path") == $(managed_part "$selective_before" "$artifact_path") ]] || fail_with "rollback did not restore $artifact_label beside the symbolic links" "$rollback_output"
  fi
done
[[ $rollback_output == *'rollback: left changed Claude settings in place; compare them with '* ]] || fail_with 'rollback did not report the symbolic link at settings' "$rollback_output"

# rollback tests: prior links
typeset prior_link_home="$test_root/prior-link-home" prior_link_targets="$test_root/prior-link-targets" prior_link_targets_tree prior_link_artifact prior_link_name prior_link_mode
seed_prior_install "$prior_link_home"
/bin/mkdir -p "$prior_link_targets/.local"
# Neither mode equals what a link gets under a common umask, so the link's own mode cannot pass for the target's.
typeset -a prior_links=(.claude/settings.json settings.json 600 .local/bin/agent-notify agent-notify 710)
for prior_link_artifact prior_link_name prior_link_mode in $prior_links; do
  /bin/mv "$prior_link_home/$prior_link_artifact" "$prior_link_targets/.local/$prior_link_name"
  /bin/chmod "$prior_link_mode" "$prior_link_targets/.local/$prior_link_name"
  /bin/ln -s "$prior_link_targets/.local/$prior_link_name" "$prior_link_home/$prior_link_artifact"
done
prior_link_targets_tree=$(managed_tree "$prior_link_targets")
real_install "$prior_link_home" yes
must_rollback "$prior_link_home" no
[[ $rollback_output == 'Selective rollback complete.' ]] || fail_with 'rollback over prior file links did not print exactly the completion line' "$rollback_output"
assert_tree "$prior_link_targets" "$prior_link_targets_tree" 'install and rollback changed the target of a prior link'
for prior_link_artifact prior_link_name prior_link_mode in $prior_links; do
  [[ ! -L $prior_link_home/$prior_link_artifact && -f $prior_link_home/$prior_link_artifact ]] || fail_with "rollback did not leave a regular file at $prior_link_artifact" "$rollback_output"
  [[ $(/usr/bin/stat -f '%Lp' "$prior_link_home/$prior_link_artifact") == "$prior_link_mode" ]] || fail_with "rollback restored $prior_link_artifact with the link's mode, not the target's" "$(/usr/bin/stat -f '%Lp' "$prior_link_home/$prior_link_artifact")"
  /usr/bin/cmp -s "$prior_link_home/$prior_link_artifact" "$prior_link_targets/.local/$prior_link_name" || fail_with "rollback did not restore the target's bytes at $prior_link_artifact" "$rollback_output"
done

typeset prior_library_home="$test_root/prior-library-home" prior_library_tree
seed_prior_install "$prior_library_home"
/bin/mkdir -p "$prior_library_home/dotfiles/lib"
/bin/mv "$prior_library_home/.local/lib/agent-notify" "$prior_library_home/dotfiles/lib/agent-notify"
/bin/ln -s ../../dotfiles/lib/agent-notify "$prior_library_home/.local/lib/agent-notify"
prior_library_tree=$(managed_tree "$prior_library_home")
real_install "$prior_library_home" yes
must_rollback "$prior_library_home" no
[[ $rollback_output == 'Selective rollback complete.' ]] || fail_with 'rollback over a prior relative library link did not print exactly the completion line' "$rollback_output"
assert_tree "$prior_library_home" "$prior_library_tree" 'rollback did not restore the prior relative library link'
[[ $(<"$prior_library_home/.local/lib/agent-notify/config.zsh") == '# seed library' ]] || fail_with 'the restored library link does not reach its files' "$rollback_output"

# rollback tests: guard
typeset guard_home="$test_root/guard-home" guard_first_home="$test_root/guard-first-home" guard_copy_home="$test_root/guard-copy-home" guard_saved_manifest="$test_root/guard-saved-manifest.json" guard_items="$test_root/guard-items"
typeset guard_hex=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
typeset guard_manifest guard_backup guard_root guard_seed_tree guard_installed_tree guard_content guard_value guard_directory guard_arguments guard_output guard_code
/bin/rm -f "$keychain_state/removed"
guard_refuses() {
  local refuse_home=$1 description=$2 refusal=$3 tree output code=0
  tree=$(managed_tree "$refuse_home")
  output=$(real_rollback "$refuse_home" yes) || code=$?
  (( code )) || fail_with "rollback was not refused: $description" "$output"
  [[ $output == "agent-notify-install: $refusal; no changes made" ]] || fail_with "rollback was refused with the wrong text: $description" "$output"
  assert_tree "$refuse_home" "$tree" "refused rollback changed the home: $description"
  [[ ! -e "$keychain_state/removed" ]] || fail_with "refused rollback removed credentials: $description" "$output"
}
guard_case() { guard_refuses "$guard_home" "$@"; /bin/cp -p "$guard_saved_manifest" "$guard_manifest"; }

seed_prior_install "$guard_home"
guard_seed_tree=$(managed_tree "$guard_home")
real_install "$guard_home" yes
guard_installed_tree=$(managed_tree "$guard_home")
guard_manifest=$(manifest_file "$guard_home")
guard_backup=$(manifest_value "$guard_home" backup)
guard_root=${guard_backup:h}
/bin/cp -p "$guard_manifest" "$guard_saved_manifest"
/bin/cp -pR "$guard_backup" "$guard_items"

for artifact_label artifact_path artifact_backup in $managed_artifacts; do
  /bin/mv "$guard_backup/$artifact_backup" "$guard_backup/$artifact_backup.aside"
  guard_case "backup of $artifact_label moved aside" "backup of $artifact_label does not match the manifest"
  if [[ $artifact_label != library ]]; then
    /bin/ln -s /missing/target "$guard_backup/$artifact_backup"
    guard_case "backup of $artifact_label is a dangling link" "backup of $artifact_label does not match the manifest"
    /bin/rm -f "$guard_backup/$artifact_backup"
  fi
  /bin/mv "$guard_backup/$artifact_backup.aside" "$guard_backup/$artifact_backup"
done
/bin/mv "$guard_backup" "$guard_backup.aside"
guard_case 'backup directory moved aside' 'backup of binary does not match the manifest'
/bin/mv "$guard_backup.aside" "$guard_backup"

/bin/mv "$guard_backup/modes" "$guard_backup/modes.aside"
guard_case 'modes moved aside' 'backup of binary has no recorded mode'
/bin/mv "$guard_backup/modes.aside" "$guard_backup/modes"
for artifact_label artifact_path artifact_backup in $managed_artifacts; do
  [[ $artifact_label == library ]] && continue
  /usr/bin/grep -v "^$artifact_backup " "$guard_items/modes" > "$guard_backup/modes"
  guard_case "no recorded mode for $artifact_label" "backup of $artifact_label has no recorded mode"
done
for guard_value in not-a-mode 77777; do
  /usr/bin/sed "s/^agent-notify\.js .*/agent-notify.js $guard_value/" "$guard_items/modes" > "$guard_backup/modes"
  guard_case "plugin mode $guard_value" 'backup of plugin has no recorded mode'
done
/bin/cp -p "$guard_items/modes" "$guard_backup/modes"

for artifact_label artifact_path artifact_backup in $managed_artifacts; do
  manifest_tamper "$guard_manifest" "files.$artifact_label.path" "\"$test_root/elsewhere/$artifact_backup\""
  guard_case "tampered $artifact_label path" "recorded path for $artifact_label is not the managed path for this home"
  manifest_tamper "$guard_manifest" "files.$artifact_label.post_hash" null
  guard_case "null $artifact_label hash" "installation manifest entry for $artifact_label is invalid"
done

manifest_tamper "$guard_manifest" files.plugin.post_hash
guard_case 'missing plugin hash' 'installation manifest entry for plugin is invalid'
for guard_value in not-a-hash "${guard_hex[1,63]}" "a$guard_hex" "${guard_hex}a" "${(U)guard_hex}" "${guard_hex[1,63]}g"; do
  manifest_tamper "$guard_manifest" files.plugin.post_hash "\"$guard_value\""
  guard_case "plugin hash $guard_value" 'installation manifest entry for plugin is invalid'
done

manifest_tamper "$guard_manifest" files.plugin.existed '"1"'
guard_case 'string plugin flag' 'installation manifest entry for plugin is invalid'
manifest_tamper "$guard_manifest" files.plugin.existed
guard_case 'missing plugin flag' 'installation manifest entry for plugin is invalid'
manifest_tamper "$guard_manifest" files.plugin.existed 0
guard_case 'plugin flag edited to 0 with its backup present' 'backup of plugin does not match the manifest'

for guard_directory in "$test_root/guard-other/install.other" "$guard_root/../guard-climb/install.climb" "$guard_root.sibling/install.sibling" "$guard_root/other.named" "$guard_backup/install.nested"; do
  /bin/mkdir -p "${guard_directory:h}"
  /bin/cp -pR "$guard_items" "$guard_directory"
  manifest_tamper "$guard_manifest" backup "\"$guard_directory\""
  guard_case "backup recorded as $guard_directory" 'recorded backup directory is not under the backup location for this home'
  /bin/rm -rf "$guard_directory"
done

guard_content=$(<"$guard_saved_manifest")
print -rn -- "${guard_content[1,$(( $#guard_content / 2 ))]}" > "$guard_manifest"
guard_case 'truncated manifest' 'installation manifest is invalid'
print -r -- 'not json' > "$guard_manifest"
guard_case 'unparseable manifest' 'installation manifest is invalid'
for guard_value in missing unreadable; do
  if [[ $guard_value == missing ]]; then /bin/rm -f "$guard_manifest"; else /bin/chmod 000 "$guard_manifest"; fi
  guard_code=0
  guard_output=$(real_rollback "$guard_home" yes) || guard_code=$?
  (( guard_code )) && [[ $guard_output == 'agent-notify-install: no installation manifest found' ]] || fail_with "$guard_value manifest was not refused" "$guard_output"
  assert_tree "$guard_home" "$guard_installed_tree" "$guard_value manifest changed the home"
  [[ ! -e "$keychain_state/removed" ]] || fail_with "$guard_value manifest reached credential removal" "$guard_output"
  /bin/rm -f "$guard_manifest"; /bin/cp -p "$guard_saved_manifest" "$guard_manifest"
done

manifest_tamper "$guard_manifest" generation 1
guard_code=0
guard_output=$(real_rollback "$guard_home" yes) || guard_code=$?
(( guard_code )) && [[ $guard_output == *'manifest field is invalid'* ]] || fail_with 'a numeric generation did not stop at the helper error' "$guard_output"
assert_tree "$guard_home" "$guard_installed_tree" 'a numeric generation changed the home'
[[ ! -e "$keychain_state/removed" ]] || fail_with 'a numeric generation reached credential removal' "$guard_output"
/bin/cp -p "$guard_saved_manifest" "$guard_manifest"

real_install "$guard_first_home" yes
manifest_tamper "$(manifest_file "$guard_first_home")" files.plugin.existed '"0"'
guard_refuses "$guard_first_home" 'string plugin flag on a first install' 'installation manifest entry for plugin is invalid'

real_install "$guard_copy_home" yes
/bin/cp -p "$guard_manifest" "$(manifest_file "$guard_copy_home")"
guard_refuses "$guard_copy_home" 'manifest copied from another home' 'recorded backup directory is not under the backup location for this home'
assert_tree "$guard_home" "$guard_installed_tree" 'a copied manifest changed the home it came from'

for guard_arguments in '--dry-run --rollback' '--rollback --dry-run'; do
  guard_code=0
  guard_output=$(env $real_env AGENT_NOTIFY_INSTALL_HOME="$guard_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes "$root/bin/agent-notify-install" ${=guard_arguments} 2>&1) || guard_code=$?
  (( guard_code == 2 )) && [[ $guard_output == *'usage:'* ]] || fail_with "$guard_arguments was not a usage error (exit $guard_code)" "$guard_output"
  assert_tree "$guard_home" "$guard_installed_tree" "$guard_arguments changed the home"
  [[ ! -e "$keychain_state/removed" ]] || fail_with "$guard_arguments reached credential removal" "$guard_output"
done

must_rollback "$guard_home" no
[[ $rollback_output == 'Selective rollback complete.' ]] || fail_with 'an intact rollback did not print exactly the completion line' "$rollback_output"
assert_tree "$guard_home" "$guard_seed_tree" 'an intact rollback did not restore exactly after the guard cases'

print -- 'installer tests passed'
