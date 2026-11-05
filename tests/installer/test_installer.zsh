#!/usr/bin/env zsh

setopt errexit no_unset pipe_fail

typeset root=${0:A:h:h:h}
typeset settings_fixture="$root/tests/fixtures/claude-settings/existing.json"
typeset test_root
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-notify-installer.XXXXXX")
trap '/bin/chmod -R u+rwx "$test_root"; /bin/rm -rf "$test_root"' EXIT

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
  rollback) raw=\$(/bin/cat); [[ \$raw =~ '\\\"generation\\\":\\\"([^\\\"]+)' ]] || exit 1; generation=\$match[1]; [[ \$raw =~ '\\\"selector\\\":\\\"([^\\\"]*)' ]] || exit 1; selector=\$match[1]; [[ -n \$selector ]] && print -- \$selector > \"\$state/selector\" || /bin/rm -f \"\$state/selector\"; [[ -e \"\$state/current-generation\" && \$(<\"\$state/current-generation\") != \$generation ]] || /bin/rm -f \"\$state/current-generation\" ;;
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
[[ ! -d "$empty_home/.local/bin" && ! -e "$empty_home/.local/lib" && ! -d "$empty_home/.config/opencode/plugins" && ! -d "$empty_home/.claude" ]] || { print -u2 -- 'first-time failure left attempt-created directories'; exit 1; }
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
        elif [[ -p $entry ]]; then print -r -- "fifo $(/usr/bin/stat -f '%Lp' "$entry") $entry"
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

# A link whose target cannot be reached looks absent to [[ -e ]], so replacing it takes the same consent as any other conflict.
typeset link_missing="$test_root/no-such-target" link_home link_tree link_output link_path link_step
typeset -i link_code=0 link_index=0
typeset -a link_paths=(.local/bin/agent-notify .local/lib/agent-notify .local/bin/agent-notify-claude-hook .local/bin/agent-notify-claude-hook.jxa .config/opencode/plugins/agent-notify.js .claude/settings.json 'Library/Application Support/agent-notify/install-manifest.json')
# link_attempt <home> <confirm sequence> [<env assignment>...]: runs one install, which may fail.
link_attempt() {
  local attempt_home=$1 attempt_confirm=$2
  shift 2
  link_code=0
  /bin/rm -f "$keychain_state/current-generation"
  link_output=$(print -- $'user\ntoken' | env $real_env AGENT_NOTIFY_INSTALL_HOME="$attempt_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE="$attempt_confirm" AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$@" "$root/bin/agent-notify-install" 2>&1) || link_code=$?
}
link_dry_run() { link_output=$(env $real_env AGENT_NOTIFY_INSTALL_HOME="$1" "$root/bin/agent-notify-install" --dry-run 2>&1) || fail_with "a dry run failed on an unavailable link: $1" "$link_output"; }
add_link() { /bin/mkdir -p "$1/${2:h}"; /bin/ln -s -- "$3" "$1/$2"; }
assert_link_text() { [[ $(/usr/bin/readlink -n "$1/$2"; print -n x) == "${3}x" ]] || fail_with "$4" "$link_output"; }
assert_declined() {
  (( link_code )) && [[ $link_output == *'conflicting target not replaced'* ]] || fail_with "an unavailable link did not stop a declined install: $1" "$link_output"
  [[ ! -e "$keychain_state/current-generation" ]] || fail_with "a declined install stored credentials: $1" "$link_output"
}
assert_named() { [[ $link_output == *"conflict: $1/$2 is a link to an unavailable target ($3); replacing it removes the link, and neither the backups nor --rollback bring it back"* ]] || fail_with "the plan did not name the unavailable link at $2" "$link_output"; }

for link_path in $link_paths; do
  link_home="$test_root/link-declined-$(( ++link_index ))"
  add_link "$link_home" "$link_path" "$link_missing"
  link_tree=$(managed_tree "$link_home")
  link_attempt "$link_home" yes:no
  assert_named "$link_home" "$link_path" "$link_missing"
  assert_declined "$link_path"
  assert_tree "$link_home" "$link_tree" "a declined install changed the home: $link_path"
  assert_link_text "$link_home" "$link_path" "$link_missing" "a declined install changed the link at $link_path"
done

link_home="$test_root/link-all-home"
for link_path in $link_paths; do add_link "$link_home" "$link_path" "$link_missing"; done
link_tree=$(managed_tree "$link_home")
link_dry_run "$link_home"
for link_path in $link_paths; do assert_named "$link_home" "$link_path" "$link_missing"; done
[[ $link_output == *'executable: conflict'* && $link_output == *'OpenCode-plugin: conflict'* ]] || fail_with 'the plan classified an unavailable link as absent' "$link_output"
assert_tree "$link_home" "$link_tree" 'a dry run changed unavailable links'

# The conflict prompt comes before the credential prompts, so declining needs no credentials.
link_code=0
link_output=$(env $real_env AGENT_NOTIFY_INSTALL_HOME="$link_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" </dev/null 2>&1) || link_code=$?
assert_declined 'no credentials available'
assert_tree "$link_home" "$link_tree" 'declining with no credentials changed the links'

# Consent changes nothing until the attempt has its credentials, so failing to read them must leave the links.
link_code=0
link_output=$(env $real_env AGENT_NOTIFY_INSTALL_HOME="$link_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" </dev/null 2>&1) || link_code=$?
(( link_code )) && [[ $link_output == *'unable to read user key'* ]] || fail_with 'consent with no credentials did not stop the install' "$link_output"
assert_tree "$link_home" "$link_tree" 'consent with no credentials changed the links'
assert_link_text "$link_home" "${link_paths[-1]}" "$link_missing" 'consent with no credentials changed the manifest link'

# With no terminal, nothing can answer the prompts, and that counts as declining.
link_code=0
link_output=$(env $real_env AGENT_NOTIFY_INSTALL_HOME="$link_home" /usr/bin/perl -MPOSIX -e 'if (my $child = fork()) { waitpid($child, 0); exit($? >> 8); } POSIX::setsid(); exec(@ARGV) or die "exec failed: $!\n";' "$root/bin/agent-notify-install" </dev/null 2>&1) || link_code=$?
(( ! link_code )) && [[ $link_output == *'Installation declined; no changes made.'* && $link_output != *'Pushover user key'* ]] || fail_with 'an install with no terminal did not count as declined' "$link_output"
assert_tree "$link_home" "$link_tree" 'an install with no terminal changed the links'

# These steps run in this order, so the failures leave none, some, or all but the manifest's link replaced.
for link_step in keychain library binary plugin settings; do
  link_attempt "$link_home" yes:yes AGENT_NOTIFY_INSTALL_FAIL_AT="$link_step"
  (( link_code )) && [[ $link_output == *'installation failed; restored only unchanged attempt artifacts'* ]] || fail_with "a failed attempt at $link_step did not report" "$link_output"
  assert_tree "$link_home" "$link_tree" "a failed attempt at $link_step did not restore the links"
  assert_link_text "$link_home" "${link_paths[-1]}" "$link_missing" "a failed attempt at $link_step changed the manifest link"
  [[ ! -e "$keychain_state/current-generation" ]] || fail_with "a failed attempt at $link_step kept its Keychain generation" "$link_output"
  [[ $'\n'$link_output != *$'\n'ln:* ]] || fail_with "a failed attempt at $link_step tried to recreate a link that was still there" "$link_output"
  [[ $link_output != *'replaced link:'* ]] || fail_with "a failed attempt at $link_step reported a replaced link" "$link_output"
done

link_attempt "$link_home" yes:yes
(( ! link_code )) || fail_with 'consent did not let the install replace unavailable links' "$link_output"
for link_path in $link_paths; do
  [[ ! -L "$link_home/$link_path" && -e "$link_home/$link_path" ]] || fail_with "consent did not replace the link at $link_path" "$link_output"
  [[ $link_output == *"replaced link: $link_home/$link_path (it pointed to $link_missing; the backups and --rollback do not restore it)"* ]] || fail_with "the report did not name the replaced link at $link_path" "$link_output"
done
[[ ! -e $link_missing ]] || fail_with 'the install created the target of an unavailable link' "$link_output"
link_attempt "$link_home" yes:no
(( ! link_code )) || fail_with 'the install after replacing the links found a conflict' "$link_output"

# The plan says rollback does not bring a replaced link back.
link_home="$test_root/link-rollback-home"
for link_path in $link_paths; do add_link "$link_home" "$link_path" "$link_missing"; done
link_attempt "$link_home" yes:yes
(( ! link_code )) || fail_with 'consent did not let the install replace links before a rollback' "$link_output"
must_rollback "$link_home" no
for link_path in ${link_paths[1,-2]}; do
  [[ ! -e "$link_home/$link_path" && ! -L "$link_home/$link_path" ]] || fail_with "rollback left something at $link_path" "$rollback_output"
done

# A target behind an unsearchable directory still exists, so it must survive being replaced.
typeset link_locked="$test_root/link-locked"
/bin/mkdir "$link_locked"
print -r -- '{"locked":true}' > "$link_locked/settings.json"
link_home="$test_root/link-locked-home"
add_link "$link_home" .claude/settings.json "$link_locked/settings.json"
link_tree=$(managed_tree "$link_home")
/bin/chmod 000 "$link_locked"
link_attempt "$link_home" yes:no
/bin/chmod 700 "$link_locked"
assert_named "$link_home" .claude/settings.json "$link_locked/settings.json"
assert_declined 'target behind an unsearchable directory'
assert_tree "$link_home" "$link_tree" 'a declined install changed a link to a locked target'
/bin/chmod 000 "$link_locked"
link_attempt "$link_home" yes:yes
/bin/chmod 700 "$link_locked"
(( ! link_code )) && [[ ! -L "$link_home/.claude/settings.json" && -f "$link_home/.claude/settings.json" ]] || fail_with 'consent did not replace a link to a locked target' "$link_output"
[[ $(<"$link_locked/settings.json") == '{"locked":true}' ]] || fail_with 'replacing a link changed its locked target' "$link_output"

# A relative link has to come back with its exact text.
link_home="$test_root/link-cycle-home"
add_link "$link_home" .claude/settings.json settings.json
# A failed first install leaves empty parents, which this case is not about.
/bin/mkdir -p "$link_home/.local/bin" "$link_home/.local/lib" "$link_home/.config/opencode/plugins"
link_tree=$(managed_tree "$link_home")
link_attempt "$link_home" yes:no
assert_named "$link_home" .claude/settings.json settings.json
assert_declined 'link that points at itself'
link_attempt "$link_home" yes:yes AGENT_NOTIFY_INSTALL_FAIL_AT=settings
(( link_code )) || fail_with 'an injected failure succeeded over a relative link' "$link_output"
assert_tree "$link_home" "$link_tree" 'a failed attempt did not restore a relative link'
/bin/rm -f "$link_home/.claude/settings.json"
add_link "$link_home" .claude/settings.json -dash-target
link_tree=$(managed_tree "$link_home")
link_attempt "$link_home" yes:yes AGENT_NOTIFY_INSTALL_FAIL_AT=settings
(( link_code )) || fail_with 'an injected failure succeeded over a link starting with a dash' "$link_output"
assert_tree "$link_home" "$link_tree" 'a failed attempt did not restore a link starting with a dash'

# Link text is not trusted for display, and has to come back byte for byte, trailing newline included.
link_home="$test_root/link-escape-home"
typeset link_hostile=$'/no-such\e[2K\r\a\ttarget\n' link_visible='/no-such^[[2K^M^G\ttarget\n'
add_link "$link_home" .local/bin/agent-notify "$link_hostile"
link_attempt "$link_home" yes:yes AGENT_NOTIFY_INSTALL_FAIL_AT=settings
(( link_code )) || fail_with 'an injected failure succeeded over a link with control characters' "$link_output"
[[ $link_output == *"is a link to an unavailable target ($link_visible);"* ]] || fail_with 'the plan did not show the control characters in a link' "$link_output"
[[ $link_output != *$'\e'* && $link_output != *$'\r'* && $link_output != *$'\a'* ]] || fail_with 'the plan printed control characters from a link' "$link_output"
assert_link_text "$link_home" .local/bin/agent-notify "$link_hostile" 'a failed attempt changed the text of a link'
link_attempt "$link_home" yes:yes
(( ! link_code )) && [[ $link_output == *"(it pointed to $link_visible;"* ]] || fail_with 'the report did not show the control characters in a link' "$link_output"
[[ $link_output != *$'\e'* && $link_output != *$'\r'* && $link_output != *$'\a'* ]] || fail_with 'the report printed control characters from a link' "$link_output"

# Without the text there is nothing to name in the plan or to recreate, so this says why it stopped.
link_home="$test_root/link-unreadable-home"
add_link "$link_home" .local/bin/agent-notify "$link_missing"
/bin/chmod -h 000 "$link_home/.local/bin/agent-notify"
link_tree=$(managed_tree "$link_home" 2>/dev/null)
/bin/rm -f "$keychain_state/current-generation"
link_code=0
link_output=$(env $real_env AGENT_NOTIFY_INSTALL_HOME="$link_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" </dev/null 2>&1) || link_code=$?
(( link_code )) && [[ $link_output == *"unable to read the link at $link_home/.local/bin/agent-notify; no changes made"* && $link_output != *'unable to read user key'* ]] || fail_with 'an unreadable link did not stop the install before its credentials' "$link_output"
[[ $(managed_tree "$link_home" 2>/dev/null) == "$link_tree" && -L "$link_home/.local/bin/agent-notify" && ! -e "$keychain_state/current-generation" ]] || fail_with 'an unreadable link did not leave everything unchanged' "$link_output"
link_code=0
link_output=$(env $real_env AGENT_NOTIFY_INSTALL_HOME="$link_home" "$root/bin/agent-notify-install" --dry-run 2>&1) || link_code=$?
(( link_code )) && [[ $link_output == *"unable to read the link at $link_home/.local/bin/agent-notify"* ]] || fail_with 'a dry run did not stop at an unreadable link' "$link_output"

# A file that took a link's path during the attempt is not the attempt's to replace.
# occupied_attempt <path under the home> <failure step> <commands taking the path, which is $taken>: runs one attempt whose path is taken during the Keychain store.
occupied_attempt() {
  link_home="$test_root/link-occupied-$(( ++link_index ))"
  add_link "$link_home" "$1" "$link_missing"
  print -r -- "#!/bin/zsh
taken='$link_home/$1'
[[ \$1 == store ]] && { /bin/rm -f \"\$taken\"; $3; }
exec '$fake/keychain-jxa' \"\$@\"" > "$fake/link-occupying-keychain-jxa"
  /bin/chmod 700 "$fake/link-occupying-keychain-jxa"
  link_attempt "$link_home" yes:yes AGENT_NOTIFY_INSTALL_FAIL_AT="$2" AGENT_NOTIFY_INSTALL_KEYCHAIN_HELPER="$fake/link-occupying-keychain-jxa"
  (( link_code )) || fail_with 'an injected failure succeeded over an occupied link path' "$link_output"
}
occupied_attempt .local/bin/agent-notify keychain 'print -r -- occupied > "$taken"'
[[ ! -L "$link_home/.local/bin/agent-notify" && $(<"$link_home/.local/bin/agent-notify") == occupied ]] || fail_with 'a failed attempt replaced a file that took the path of a link' "$link_output"
occupied_attempt .local/bin/agent-notify keychain '/bin/mkdir "$taken"; print -r -- occupied > "$taken/kept"'
[[ -d "$link_home/.local/bin/agent-notify" && ! -L "$link_home/.local/bin/agent-notify" && $(/bin/ls -A "$link_home/.local/bin/agent-notify") == kept ]] || fail_with 'a failed attempt changed a directory that took the path of a link' "$link_output"
# The library step runs here, and must not move a file aside as if it were the link.
occupied_attempt .local/lib/agent-notify binary 'print -r -- occupied > "$taken"'
[[ ! -L "$link_home/.local/lib/agent-notify" && -f "$link_home/.local/lib/agent-notify" && $(<"$link_home/.local/lib/agent-notify") == occupied ]] || fail_with 'a failed attempt replaced a file that took the path of the library link' "$link_output"

# Only an unreachable target counts: a link that resolves to identical bytes is not a conflict.
link_home="$test_root/link-healthy-home"
real_install "$link_home" yes
/bin/mv "$link_home/.local/bin/agent-notify" "$test_root/link-healthy-target"
/bin/ln -s "$test_root/link-healthy-target" "$link_home/.local/bin/agent-notify"
link_attempt "$link_home" yes:no
(( ! link_code )) && [[ $link_output != *'is a link to an unavailable target'* ]] || fail_with 'a link with a reachable target counted as unavailable' "$link_output"
# A relative link resolves from its own directory, not from wherever the installer runs.
/bin/rm -f "$link_home/.local/bin/agent-notify"
/bin/mkdir "$link_home/dotfiles"
/bin/mv "$test_root/link-healthy-target" "$link_home/dotfiles/agent-notify"
/bin/ln -s ../../dotfiles/agent-notify "$link_home/.local/bin/agent-notify"
link_attempt "$link_home" yes:no
(( ! link_code )) && [[ $link_output != *'is a link to an unavailable target'* ]] || fail_with 'a relative link with a reachable target counted as unavailable' "$link_output"
# Different bytes behind a reachable link are an ordinary conflict.
/bin/rm -f "$link_home/.local/bin/agent-notify"
print -r -- 'different bytes' > "$link_home/dotfiles/different"
/bin/ln -s ../../dotfiles/different "$link_home/.local/bin/agent-notify"
link_attempt "$link_home" yes:no
assert_declined 'a reachable link with different bytes'
[[ $link_output != *'is a link to an unavailable target'* ]] || fail_with 'a reachable link with different bytes counted as unavailable' "$link_output"

# The plan classifies every target the conflict prompt checks, and the prompt acts on that same answer.
typeset plan_home plan_exact_home="$test_root/plan-home" plan_older="$test_root/plan-older-checkout" plan_label plan_path
typeset plan_bin=.local/bin/agent-notify plan_lib=.local/lib/agent-notify plan_plugin=.config/opencode/plugins/agent-notify.js
typeset -i plan_index=0
typeset -a plan_targets=(executable $plan_bin notifier-library $plan_lib Claude-hook .local/bin/agent-notify-claude-hook Claude-hook-JXA .local/bin/agent-notify-claude-hook.jxa OpenCode-plugin $plan_plugin)
typeset plan_all_absent=$'executable: absent\nnotifier-library: absent\nClaude-hook: absent\nClaude-hook-JXA: absent\nOpenCode-plugin: absent'
typeset plan_all_exact=$'executable: installer-managed exact\nnotifier-library: installer-managed exact\nClaude-hook: installer-managed exact\nClaude-hook-JXA: installer-managed exact\nOpenCode-plugin: installer-managed exact'
typeset plan_older_lines=$'executable: conflict\nnotifier-library: conflict\nClaude-hook: conflict\nClaude-hook-JXA: conflict\nOpenCode-plugin: installer-managed exact'
# assert_plan <expected lines> <message>: the classification lines of the last run, in order.
assert_plan() {
  local actual
  actual=$(print -r -- "$link_output" | /usr/bin/grep -E '^[^ ]+: (absent|installer-managed exact|conflict)$') || true
  [[ $actual == "$1" ]] && return 0
  /usr/bin/diff <(print -r -- "$1") <(print -r -- "$actual") >&2 || true
  fail_with "$2" "$link_output"
}
# Unreadable entries make managed_tree fail partway, identically each time, so this compares what it reached.
plan_snapshot() { { managed_tree "$1"; /usr/bin/find "$1/Library" -ls | /usr/bin/sort; } 2>/dev/null || true; }
# A plan that opens a FIFO blocks for good, so each run gets its own process group, killed whole at the deadline.
plan_bounded() {
  /usr/bin/perl -e '
    setpgrp(0, 0) or die "setpgrp failed: $!\n";
    my $child = fork() // die "fork failed: $!\n";
    if (!$child) { exec(@ARGV) or die "exec failed: $!\n"; }
    $SIG{ALRM} = sub { print STDERR "the run did not finish in time\n"; kill("KILL", -$$); };
    alarm(60);
    waitpid($child, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$@"
}
# plan_dry_run <home> <case>: the plan runs under errexit, so it must reach its end whatever it finds, and change nothing.
plan_dry_run() {
  local before
  before=$(plan_snapshot "$1")
  /bin/rm -f "$keychain_state/current-generation"
  link_output=$(plan_bounded env $real_env AGENT_NOTIFY_INSTALL_HOME="$1" "$root/bin/agent-notify-install" --dry-run </dev/null 2>&1) || fail_with "a dry run stopped early: $2" "$link_output"
  [[ $link_output == *'Dry run complete; no credentials collected and no changes made.'* ]] || fail_with "a dry run did not finish its plan: $2" "$link_output"
  [[ $(plan_snapshot "$1") == "$before" && ! -e "$keychain_state/current-generation" ]] || fail_with "a dry run changed something: $2" "$link_output"
}
# plan_declined <home> <case>: stdin holds no credentials, so reaching their prompt would report that it could not read them.
plan_declined() {
  local before
  before=$(plan_snapshot "$1")
  /bin/rm -f "$keychain_state/current-generation"
  link_code=0
  link_output=$(plan_bounded env $real_env AGENT_NOTIFY_INSTALL_HOME="$1" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" </dev/null 2>&1) || link_code=$?
  (( link_code )) && [[ $link_output == *'conflicting target not replaced'* && $link_output != *'unable to read user key'* ]] || fail_with "declining the conflict prompt did not stop before credentials: $2" "$link_output"
  [[ $(plan_snapshot "$1") == "$before" && ! -e "$keychain_state/current-generation" ]] || fail_with "a declined install changed something: $2" "$link_output"
}
# assert_no_prompt <case>: the last run was an install that a yes:no sequence did not stop.
assert_no_prompt() {
  (( ! link_code )) && [[ $link_output != *'conflicting target not replaced'* && $link_output != *'  conflict: '* ]] || fail_with "the install asked to replace a target: $1" "$link_output"
}
# plan_case: a copy of an exact install. Classifying does not depend on the home it was installed into.
plan_case() { plan_home="$test_root/plan-case-$(( ++plan_index ))"; /bin/cp -pR "$plan_exact_home" "$plan_home"; }
# plan_only_conflict <label> <case>: a dry run and a declined install both report that one conflict.
plan_only_conflict() {
  local expected=${plan_all_exact/$1: installer-managed exact/$1: conflict}
  plan_dry_run "$plan_home" "$2"
  assert_plan "$expected" "the dry-run plan did not report one conflict: $2"
  plan_declined "$plan_home" "$2"
  assert_plan "$expected" "the install plan did not report one conflict: $2"
  [[ $link_output != *'  conflict: '* ]] || fail_with "the plan named a link that is not there: $2" "$link_output"
}
# plan_no_conflict <case>: a dry run and an install both report every target exact, and the install does not ask.
plan_no_conflict() {
  plan_dry_run "$plan_home" "$1"
  assert_plan "$plan_all_exact" "the dry-run plan did not report every target as installer-managed exact: $1"
  link_attempt "$plan_home" yes:no
  assert_no_prompt "$1"
  assert_plan "$plan_all_exact" "the install plan did not report every target as installer-managed exact: $1"
}

plan_dry_run "$plan_exact_home" 'fresh home'
assert_plan "$plan_all_absent" 'a fresh home did not report every target absent'
[[ ! -e $plan_exact_home ]] || fail_with 'a dry run created the fresh home' "$link_output"
link_attempt "$plan_exact_home" yes:no
assert_no_prompt 'fresh home'
assert_plan "$plan_all_absent" 'a first install did not report every target absent'

plan_dry_run "$plan_exact_home" 'exact reinstall'
assert_plan "$plan_all_exact" 'an exact install did not report every target as installer-managed exact'
link_attempt "$plan_exact_home" yes:no
assert_no_prompt 'exact reinstall'
assert_plan "$plan_all_exact" 'an exact reinstall did not report every target as installer-managed exact'

for plan_label plan_path in $plan_targets; do
  plan_case
  [[ -d $plan_home/$plan_path ]] && plan_path+=/config.zsh
  print -r -- '# changed by hand' >> "$plan_home/$plan_path"
  plan_only_conflict "$plan_label" "$plan_label changed by hand"
done

# A link that reaches identical bytes is judged by those bytes, as a dotfiles setup would have it.
for plan_label plan_path in $plan_targets; do
  plan_case
  /bin/mkdir "$plan_home/dotfiles"
  /bin/mv "$plan_home/$plan_path" "$plan_home/dotfiles/${plan_path:t}"
  /bin/ln -s "$plan_home/dotfiles/${plan_path:t}" "$plan_home/$plan_path"
  plan_no_conflict "a link to identical bytes at the $plan_label path"
done

# A marker alone does not make a plugin the installer's: only the manifest can vouch for its bytes.
plan_case; print -r -- $'// >>> agent-notify managed plugin >>>\n// edited by hand' > "$plan_home/$plan_plugin"
plan_only_conflict OpenCode-plugin 'a plugin with the marker and different bytes'
plan_case; /bin/rm -f "$(manifest_file "$plan_home")"
plan_only_conflict OpenCode-plugin 'a managed plugin with the manifest removed'
plan_case; print -r -- 'not json' > "$(manifest_file "$plan_home")"
plan_only_conflict OpenCode-plugin 'a managed plugin with a corrupt manifest'
plan_case; manifest_tamper "$(manifest_file "$plan_home")" files.plugin.post_hash
plan_only_conflict OpenCode-plugin 'a managed plugin with no recorded hash'
plan_case; /bin/chmod 000 "$(manifest_file "$plan_home")"
plan_only_conflict OpenCode-plugin 'a managed plugin with an unreadable manifest'

# A generated plugin has no checkout bytes to match, so one from an older install is still exact if its manifest says so.
plan_record_plugin() { /usr/bin/plutil -replace files.plugin.post_hash -string "$(/usr/bin/shasum -a 256 "$plan_home/$plan_plugin" | /usr/bin/cut -d ' ' -f1)" "$(manifest_file "$plan_home")"; }
plan_case; print -r -- '// no marker' > "$plan_home/$plan_plugin"; plan_record_plugin
plan_only_conflict OpenCode-plugin 'a plugin with no marker that matches its manifest'
plan_case; print -r -- $'// >>> agent-notify managed plugin >>>\n// older plugin' > "$plan_home/$plan_plugin"; plan_record_plugin
plan_no_conflict 'an older plugin matching its manifest'

# An older install has a manifest too, and everything but the plugin still needs consent to be replaced.
/bin/mkdir "$plan_older"
/bin/cp -R "$root/bin" "$root/lib" "$root/integrations" "$root/installer" "$plan_older/"
for plan_path in bin/agent-notify lib/agent-notify/config.zsh integrations/claude/agent-notify-hook.zsh; do print -r -- '# older checkout' >> "$plan_older/$plan_path"; done
for plan_path in integrations/claude/agent-notify-hook.jxa integrations/opencode/agent-notify.js; do print -r -- '// older checkout' >> "$plan_older/$plan_path"; done
plan_home="$test_root/plan-older-home"
link_output=$(print -- $'user\ntoken' | env $real_env AGENT_NOTIFY_INSTALL_HOME="$plan_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$plan_older/bin/agent-notify-install" 2>&1) || fail_with 'the older checkout did not install' "$link_output"
plan_dry_run "$plan_home" 'an install from an older checkout'
assert_plan "$plan_older_lines" 'the dry-run plan of an older install was wrong'
plan_declined "$plan_home" 'an install from an older checkout'
assert_plan "$plan_older_lines" 'the install plan of an older install was wrong'

# A dangling link looks absent to [[ -e ]]. The settings and manifest have no line of their own, so the link's line is what the prompt answers to there.
for plan_label plan_path in $plan_targets; do
  plan_home="$test_root/plan-case-$(( ++plan_index ))"
  add_link "$plan_home" "$plan_path" "$link_missing"
  plan_dry_run "$plan_home" "a link at the $plan_label path"
  assert_plan "${plan_all_absent/$plan_label: absent/$plan_label: conflict}" "the plan did not report a link at the $plan_label path as a conflict"
  plan_declined "$plan_home" "a link at the $plan_label path"
done
for plan_path in .claude/settings.json 'Library/Application Support/agent-notify/install-manifest.json'; do
  plan_home="$test_root/plan-case-$(( ++plan_index ))"
  add_link "$plan_home" "$plan_path" "$link_missing"
  plan_dry_run "$plan_home" "a link at $plan_path"
  assert_plan "$plan_all_absent" "a link at $plan_path changed a classification line"
  [[ $link_output == *"  conflict: $plan_home/$plan_path is a link to an unavailable target"* ]] || fail_with "the plan did not name the link at $plan_path" "$link_output"
  plan_declined "$plan_home" "a link at $plan_path"
done

# None of these can be hashed or read as usual, and errexit must not turn that into a missing plan.
plan_case; : > "$plan_home/$plan_plugin"
plan_only_conflict OpenCode-plugin 'an empty plugin'
plan_case; /bin/chmod 000 "$plan_home/$plan_plugin"
plan_only_conflict OpenCode-plugin 'an unreadable plugin'
plan_case; /bin/rm -f "$plan_home/$plan_plugin"; /bin/mkdir "$plan_home/$plan_plugin"
plan_only_conflict OpenCode-plugin 'a directory at the plugin path'
# read fails on a last line with no newline, though it still sets the marker it read, so the manifest decides.
plan_case; print -rn -- '// >>> agent-notify managed plugin >>>' > "$plan_home/$plan_plugin"
plan_only_conflict OpenCode-plugin 'a plugin that is only an unterminated marker'
plan_case; print -rn -- '// >>> agent-notify managed plugin >>>' > "$plan_home/$plan_plugin"; plan_record_plugin
plan_no_conflict 'an unterminated marker matching its manifest'
plan_case; /bin/rm -f "$plan_home/$plan_bin"; /bin/mkdir "$plan_home/$plan_bin"
plan_only_conflict executable 'a directory at the executable path'
plan_case; /bin/chmod 000 "$plan_home/$plan_bin"
plan_only_conflict executable 'an unreadable executable'
plan_case; /bin/mv "$plan_home/$plan_lib" "$plan_home/library-aside"; print -r -- 'a file' > "$plan_home/$plan_lib"
plan_only_conflict notifier-library 'a file in place of the library'
plan_case; /bin/chmod 000 "$plan_home/$plan_lib"
plan_only_conflict notifier-library 'an unreadable library'
/bin/chmod 700 "$plan_home/$plan_lib"
plan_case; /bin/chmod 000 "$plan_home/$plan_lib/config.zsh"
plan_only_conflict notifier-library 'an unreadable file in the library'
plan_case; print -r -- '# an extra file' > "$plan_home/$plan_lib/extra.zsh"
plan_only_conflict notifier-library 'an extra file in the library'
plan_case; /bin/rm -f "$plan_home/$plan_lib/config.zsh"
plan_only_conflict notifier-library 'a file missing from the library'
# Opening a FIFO blocks until something writes to it, and /dev/zero never ends, so neither can be read to judge a target.
for plan_label plan_path in $plan_targets; do
  [[ $plan_label == notifier-library ]] && continue
  plan_case; /bin/rm -f "$plan_home/$plan_path"; /usr/bin/mkfifo "$plan_home/$plan_path"
  plan_only_conflict "$plan_label" "a FIFO at the $plan_label path"
done
plan_case; /bin/rm -f "$plan_home/.local/bin/agent-notify-claude-hook"; /bin/ln -s /dev/zero "$plan_home/.local/bin/agent-notify-claude-hook"
plan_only_conflict Claude-hook 'a link to /dev/zero at the Claude-hook path'
plan_case; /bin/rm -f "$(manifest_file "$plan_home")"; /usr/bin/mkfifo "$(manifest_file "$plan_home")"
plan_only_conflict OpenCode-plugin 'a FIFO at the manifest path'

# The prompt classifies again, so it acts on the home as it is then, not on what the plan printed. The plan reads the manifest after it has classified the executable, which is when this replaces it.
print -r -- '#!/bin/zsh
[[ $3 == *manifest.jxa ]] && /bin/cp "$AGENT_NOTIFY_TEST_REPLACEMENT" "$AGENT_NOTIFY_TEST_EDIT"
exec "$AGENT_NOTIFY_TEST_JXA" "$@"' > "$fake/plan-editing-jxa"; /bin/chmod 700 "$fake/plan-editing-jxa"
# plan_replaced <replacement>: an install with no credentials that declines a conflict prompt, whose executable becomes the replacement once the plan has classified it.
plan_replaced() {
  link_code=0
  link_output=$(env $real_env AGENT_NOTIFY_INSTALL_JXA_BIN="$fake/plan-editing-jxa" AGENT_NOTIFY_TEST_JXA="$fake/real-jxa" AGENT_NOTIFY_TEST_REPLACEMENT="$1" AGENT_NOTIFY_TEST_EDIT="$plan_home/$plan_bin" AGENT_NOTIFY_INSTALL_HOME="$plan_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$root/bin/agent-notify-install" </dev/null 2>&1) || link_code=$?
}
plan_case
{ /bin/cat "$plan_home/$plan_bin"; print -r -- '# changed after the plan'; } > "$test_root/plan-changed-executable"
plan_replaced "$test_root/plan-changed-executable"
assert_plan "$plan_all_exact" 'the executable changed before the plan classified it'
(( link_code )) && [[ $link_output == *'conflicting target not replaced'* ]] || fail_with 'the prompt did not notice a target changed after the plan' "$link_output"
# A conflict the plan printed that is gone by the prompt is not asked about, so the install goes on to the credentials it cannot read.
plan_case
/bin/cp "$plan_home/$plan_bin" "$test_root/plan-exact-executable"
print -r -- '# changed before the plan' >> "$plan_home/$plan_bin"
plan_replaced "$test_root/plan-exact-executable"
assert_plan "${plan_all_exact/executable: installer-managed exact/executable: conflict}" 'the executable was restored before the plan classified it'
(( link_code )) && [[ $link_output == *'unable to read user key'* && $link_output != *'conflicting target not replaced'* ]] || fail_with 'the prompt asked about a conflict that was gone' "$link_output"

# Nothing is there to replace when a target is simply gone.
plan_case; /bin/rm -f "$plan_home/$plan_plugin"
plan_dry_run "$plan_home" 'a removed plugin'
assert_plan "${plan_all_exact/OpenCode-plugin: installer-managed exact/OpenCode-plugin: absent}" 'a removed plugin was not reported as absent'
link_attempt "$plan_home" yes:no
assert_no_prompt 'a removed plugin'
/bin/rm -f "$keychain_state/current-generation"

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

# rollback tests: failed attempt
typeset attempt_output attempt_code attempt_tree attempt_state attempt_manifest attempt_credentials=$'user\ntoken'
typeset -a attempt_args=() attempt_wrapper=()

# A terminal delivers Ctrl-C to the installer and to the child it is waiting for. Giving each attempt its own process group lets a case do the same without reaching the suite, and lets a hung attempt be killed whole.
own_group() {
  /usr/bin/perl -e '
    setpgrp(0, 0) or die "setpgrp failed: $!\n";
    $ENV{AGENT_NOTIFY_TEST_GROUP} = $$;
    my $child = fork() // die "fork failed: $!\n";
    if (!$child) {
      $ENV{AGENT_NOTIFY_TEST_INSTALLER} = $$;
      $SIG{$_} = "DEFAULT" for qw(HUP INT QUIT TERM);
      exec(@ARGV) or die "exec failed: $!\n";
    }
    close(STDIN);
    $SIG{$_} = "IGNORE" for qw(HUP INT QUIT TERM);
    $SIG{ALRM} = sub { print STDERR "attempt timed out\n"; kill("KILL", -$$); };
    alarm(120);
    waitpid($child, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$@"
}
# state_listing <home>: names are enough to show a leaked backup, without hashing every earlier backup.
state_listing() {
  ( cd "$1/Library/Application Support/agent-notify" && /usr/bin/find . -print | /usr/bin/sort && /usr/bin/stat -f '%Lp' install-manifest.json )
}
snapshot_home() {
  attempt_tree=$(managed_tree "$1")
  attempt_state=$(state_listing "$1")
  attempt_manifest=$(<"$(manifest_file "$1")")
}
# start_attempt <home> [<env assignment>...]: runs one attempt, which may fail.
start_attempt() {
  local run_home=$1
  shift
  # The security fake always reports old-generation as the selector to restore.
  print -- old-generation > "$keychain_state/selector"; /bin/rm -f "$keychain_state/current-generation"
  attempt_code=0
  attempt_output=$(print -r -- "$attempt_credentials" | own_group env $real_env AGENT_NOTIFY_INSTALL_HOME="$run_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 "$@" $attempt_wrapper "$root/bin/agent-notify-install" $attempt_args 2>&1) || attempt_code=$?
  [[ $attempt_output != *'attempt timed out'* ]] || fail_with 'an attempt hung' "$attempt_output"
}
run_attempt() {
  snapshot_home "$1"
  start_attempt "$@"
}
assert_attempt_report() {
  [[ $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || fail_with "failed attempt did not restore the Keychain state: $1" "$attempt_output"
  [[ $(print -r -- "$attempt_output" | /usr/bin/grep -c 'installation failed; restored only unchanged attempt artifacts') == 1 ]] || fail_with "failed attempt did not report exactly once: $1" "$attempt_output"
  [[ $'\n'$attempt_output != *$'\n'cp:* ]] || fail_with "failed attempt printed a stray cp line: $1" "$attempt_output"
}
# assert_attempt_restored <name> <home>: the attempt left the home, state directory, and Keychain as run_attempt found them, and reported once.
assert_attempt_restored() {
  [[ $(managed_tree "$2") == "$attempt_tree" ]] || print -ru2 -- "$attempt_output"
  assert_tree "$2" "$attempt_tree" "failed attempt changed the home: $1"
  [[ $(<"$(manifest_file "$2")") == "$attempt_manifest" ]] || fail_with "failed attempt changed the manifest: $1" "$attempt_output"
  [[ $(state_listing "$2") == "$attempt_state" ]] || fail_with "failed attempt changed the state directory: $1" "$attempt_output"
  assert_attempt_report "$1"
}
# failed_attempt_check <name> <home> [<env assignment>...]: the attempt must fail, report once, and leave the home and Keychain as it found them.
failed_attempt_check() {
  local check_name=$1 check_home=$2
  shift 2
  run_attempt "$check_home" "$@"
  (( attempt_code )) || fail_with "failed attempt reported success: $check_name" "$attempt_output"
  assert_attempt_restored "$check_name" "$check_home"
}

# The installer has no test hook, so signals come from the two programs a test can reach: the JXA binary and, through PERL5OPT, /usr/bin/shasum.
typeset signal_state="$test_root/attempt-signal"
typeset -a signal_env=(AGENT_NOTIFY_INSTALL_JXA_BIN="$fake/attempt-jxa" PERL5OPT=-MAttemptSignal PERL5LIB="$fake/perl" AGENT_NOTIFY_TEST_STATE="$signal_state")
/bin/mkdir "$fake/perl"
print -r -- 'package AttemptSignal;
use strict;
my $state = $ENV{AGENT_NOTIFY_TEST_STATE};
sub send_signal {
  my $group = $ENV{AGENT_NOTIFY_TEST_GROUP};
  die "the attempt does not have its own process group\n" unless getpgrp(0) == $group;
  open(my $fired, ">", "$state.fired") or die "$!\n";
  close($fired);
  kill($ENV{AGENT_NOTIFY_TEST_SIGNAL}, $ENV{AGENT_NOTIFY_TEST_WHOLE_GROUP} ? -$group : $ENV{AGENT_NOTIFY_TEST_INSTALLER});
}
sub signal_when_changed {
  my $path = shift;
  my $start = (stat($path))[1] // 0;
  my $child = fork() // die "$!\n";
  return if $child;
  close(STDIN); close(STDOUT); close(STDERR);
  alarm(120);
  1 while ((stat($path))[1] // 0) == $start;
  send_signal();
  exit(0);
}
# Stands in for someone changing files while the attempt runs, just as the staged settings are hashed.
if ($0 =~ m{/shasum$} && $ENV{AGENT_NOTIFY_TEST_EDIT} && @ARGV && $ARGV[-1] =~ /settings\.json\.new$/) {
  for my $path (split(/\n/, $ENV{AGENT_NOTIFY_TEST_EDIT})) {
    open(my $edited, ">>", $path) or die "$!\n";
    print $edited "# changed during the attempt\n";
    close($edited);
  }
}
# Hashes of a file inside a library tree are left out, so a position is one hash the installer records.
if ($0 =~ m{/shasum$} && -e "$state.armed" && !(@ARGV && $ARGV[-1] =~ m{^\./})) {
  my $count = 0;
  if (open(my $in, "<", "$state.count")) { $count = <$in> + 0; close($in); }
  $count++;
  open(my $out, ">", "$state.count") or die "$!\n";
  print $out "$count\n";
  close($out);
  if ($count == ($ENV{AGENT_NOTIFY_TEST_HASH_NTH} // 0)) {
    my $watch = $ENV{AGENT_NOTIFY_TEST_WATCH};
    $watch ? signal_when_changed($watch) : send_signal();
  }
}
1;' > "$fake/perl/AttemptSignal.pm"
# Stands in for osascript, as real-jxa does, and is Perl to share the signal code above.
print -r -- '#!/usr/bin/perl
my ($helper, $action) = @ARGV[2, 3];
if ($helper =~ /keychain-jxa$/) {
  if ($action eq "store") { open(my $armed, ">", "$ENV{AGENT_NOTIFY_TEST_STATE}.armed") or die "$!\n"; close($armed); }
  AttemptSignal::send_signal() if $action eq ($ENV{AGENT_NOTIFY_TEST_SIGNAL_ON} // "");
  exec($helper, @ARGV[3 .. $#ARGV]) or die "exec failed: $!\n";
}
AttemptSignal::send_signal() if $action eq ($ENV{AGENT_NOTIFY_TEST_SIGNAL_ON} // "");
exec("/usr/bin/osascript", @ARGV) or die "exec failed: $!\n";' > "$fake/attempt-jxa"; /bin/chmod 700 "$fake/attempt-jxa"
: > "$signal_state.armed"
print -- probe | env PERL5OPT=-MAttemptSignal PERL5LIB="$fake/perl" AGENT_NOTIFY_TEST_STATE="$signal_state" /usr/bin/shasum -a 256 >/dev/null
[[ -r "$signal_state.count" ]] || { print -u2 -- 'shasum did not load the signal injector; the signal cases rely on /usr/bin/shasum being a Perl script'; exit 1; }
/bin/rm -f "$signal_state".{armed,count}

# signal_attempt_check <name> <home> <signal> <1 for the whole group, 0 for the installer alone> [<env assignment>...]: as failed_attempt_check, and the signal must really have been sent.
signal_attempt_check() {
  local signal_name=$1 signal_home=$2 signal_kind=$3 signal_group=$4
  shift 4
  /bin/rm -f "$signal_state".{armed,count,fired}
  failed_attempt_check "$signal_name" "$signal_home" $signal_env AGENT_NOTIFY_TEST_SIGNAL="$signal_kind" AGENT_NOTIFY_TEST_WHOLE_GROUP="$signal_group" "$@"
  [[ -e "$signal_state.fired" ]] || fail_with "no signal was sent: $signal_name" "$attempt_output"
}
# hash_signal_sweep <name> <home> <signal> <whole group> [<env assignment>...]: one attempt per hash recorded after the Keychain store.
hash_signal_sweep() {
  local sweep_name=$1 sweep_home=$2 sweep_signal=$3 sweep_group=$4 sweep_count sweep_position
  shift 4
  # An attempt with no signal may finish installing, so the count comes from a copy of the home.
  /bin/rm -rf "$test_root/sweep-count-home" "$signal_state".{armed,count,fired}
  /bin/cp -pR "$sweep_home" "$test_root/sweep-count-home"
  run_attempt "$test_root/sweep-count-home" $signal_env "$@"
  sweep_count=$(<"$signal_state.count")
  for (( sweep_position = 1; sweep_position <= sweep_count; sweep_position++ )); do
    signal_attempt_check "$sweep_name at hash $sweep_position of $sweep_count" "$sweep_home" "$sweep_signal" "$sweep_group" AGENT_NOTIFY_TEST_HASH_NTH="$sweep_position" "$@"
  done
}
# first_install_attempt <position>: a fresh home, with a terminal interrupt at that hash.
typeset first_install_home="$test_root/attempt-first-install-home"
first_install_attempt() {
  /bin/rm -rf "$first_install_home" "$signal_state".{armed,count,fired}
  print -- old-generation > "$keychain_state/selector"; /bin/rm -f "$keychain_state/current-generation"
  attempt_code=0
  attempt_output=$(print -- $'user\ntoken' | own_group env $real_env AGENT_NOTIFY_INSTALL_HOME="$first_install_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:no AGENT_NOTIFY_INSTALL_TEST_INPUT_FD=0 $signal_env AGENT_NOTIFY_TEST_SIGNAL=INT AGENT_NOTIFY_TEST_WHOLE_GROUP=1 AGENT_NOTIFY_TEST_HASH_NTH="$1" "$root/bin/agent-notify-install" 2>&1) || attempt_code=$?
  [[ $attempt_output != *'attempt timed out'* ]] || fail_with 'an attempt hung' "$attempt_output"
}
# Empty parent directories may remain; files may not.
first_install_signal_sweep() {
  local first_count first_position first_name
  local -a first_leftovers
  first_install_attempt 0
  first_count=$(<"$signal_state.count")
  for (( first_position = 1; first_position <= first_count; first_position++ )); do
    first_name="$1 at hash $first_position of $first_count"
    first_install_attempt "$first_position"
    (( attempt_code )) || fail_with "failed attempt reported success: $first_name" "$attempt_output"
    [[ -e "$signal_state.fired" ]] || fail_with "no signal was sent: $first_name" "$attempt_output"
    first_leftovers=("$first_install_home"/**/*(.DN))
    (( $#first_leftovers == 0 )) || fail_with "failed attempt left files behind: $first_name" "$attempt_output"$'\n'"${(F)first_leftovers}"
    assert_attempt_report "$first_name"
  done
}
# signal_on_change_check <name> <path under the home> <signal> <whole group>: no program can be injected right after a move, so a process started at the first hash signals as soon as the path changes. It can land after the install commits, so a clean finish is allowed. Finishing after a restore is not, and neither is stopping with no restore.
signal_on_change_check() {
  local change_home="$test_root/attempt-change-home" change_wait=0
  /bin/rm -rf "$change_home" "$signal_state".{armed,count,fired}
  real_install "$change_home" yes
  seed_prior_install "$change_home"
  /bin/chmod 640 "$(manifest_file "$change_home")"
  run_attempt "$change_home" $signal_env AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes AGENT_NOTIFY_TEST_HASH_NTH=1 AGENT_NOTIFY_TEST_WATCH="$change_home/$2" AGENT_NOTIFY_TEST_SIGNAL="$3" AGENT_NOTIFY_TEST_WHOLE_GROUP="$4"
  # Writing this file is the last thing the watcher does to the disk, so waiting also keeps it from racing the suite's cleanup.
  until [[ -e "$signal_state.fired" ]] || (( ++change_wait > 600 )); do /bin/sleep 0.1; done
  [[ -e "$signal_state.fired" ]] || fail_with "no signal was sent: $1" "$attempt_output"
  if [[ $attempt_output == *'installation failed'* ]]; then
    (( attempt_code )) || fail_with "an attempt that restored finished as a success: $1" "$attempt_output"
    assert_attempt_restored "$1" "$change_home"
  else
    # zsh exposes the default disposition for an instant when a trap replaces a handler, so a signal at the commit point can kill a finished install.
    (( ! attempt_code || attempt_code > 128 )) || fail_with "an attempt stopped without restoring or reporting: $1" "$attempt_output"
    [[ $(<"$(manifest_file "$change_home")") != "$attempt_manifest" ]] || fail_with "an attempt stopped without restoring or reporting: $1" "$attempt_output"
  fi
}
# signal_over_link_check <name> <signal> <whole group>: the restore runs while a dangling library link is still in place, and the attempt then carries on to the library step.
signal_over_link_check() {
  local link_signal_home="$test_root/attempt-link-signal-home" change_wait=0
  /bin/rm -rf "$link_signal_home" "$signal_state".{armed,count,fired}
  real_install "$link_signal_home" yes
  /bin/rm -rf "$link_signal_home/.local/lib/agent-notify"
  /bin/ln -s "$test_root/no-such-library" "$link_signal_home/.local/lib/agent-notify"
  run_attempt "$link_signal_home" $signal_env AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:yes AGENT_NOTIFY_TEST_HASH_NTH=1 AGENT_NOTIFY_TEST_WATCH="$link_signal_home/.local/bin/agent-notify" AGENT_NOTIFY_TEST_SIGNAL="$2" AGENT_NOTIFY_TEST_WHOLE_GROUP="$3"
  until [[ -e "$signal_state.fired" ]] || (( ++change_wait > 600 )); do /bin/sleep 0.1; done
  [[ -e "$signal_state.fired" ]] || fail_with "no signal was sent: $1" "$attempt_output"
  if [[ $attempt_output == *'installation failed'* ]]; then
    (( attempt_code )) || fail_with "an attempt that restored finished as a success: $1" "$attempt_output"
    assert_attempt_restored "$1" "$link_signal_home"
  else
    (( ! attempt_code || attempt_code > 128 )) || fail_with "an attempt stopped without restoring or reporting: $1" "$attempt_output"
    (( attempt_code )) || [[ $(<"$(manifest_file "$link_signal_home")") != "$attempt_manifest" ]] || fail_with "an attempt finished with nothing installed: $1" "$attempt_output"
  fi
}
# A signal during the retire must not stop a finished install, since nothing else would remove the prior generation.
finished_install_signal_check() {
  local finish_home="$test_root/attempt-finish-home"
  real_install "$finish_home" yes
  /bin/rm -f "$signal_state".{armed,count,fired}
  run_attempt "$finish_home" $signal_env AGENT_NOTIFY_TEST_SIGNAL_ON=retire AGENT_NOTIFY_TEST_SIGNAL="$2" AGENT_NOTIFY_TEST_WHOLE_GROUP=1
  (( ! attempt_code )) || fail_with "a signal stopped a finished install: $1" "$attempt_output"
  [[ -e "$signal_state.fired" ]] || fail_with "no signal was sent: $1" "$attempt_output"
  [[ $attempt_output == *'installation complete'* && $attempt_output != *'installation failed'* ]] || fail_with "a finished install did not report completing: $1" "$attempt_output"
  [[ $attempt_output != *'could not be retired'* ]] || fail_with "a signal stopped the retire: $1" "$attempt_output"
}
# Before the first mutation a signal can only stop the installer, so these programs send one during preflight and during the selector read.
print -r -- '#!/usr/bin/perl
AttemptSignal::send_signal();
print "claude 1.2.3\n";' > "$fake/signal-claude"; /bin/chmod 700 "$fake/signal-claude"
print -r -- '#!/usr/bin/perl
if (grep { $_ eq "-w" } @ARGV) { AttemptSignal::send_signal(); print "old-generation\n"; }' > "$fake/signal-security"; /bin/chmod 700 "$fake/signal-security"
# Exits with the chosen status when asked for the selector, as security does when an item is missing or access is denied.
print -r -- '#!/bin/zsh
[[ " $* " == *" -w "* ]] && exit $AGENT_NOTIFY_TEST_SELECTOR_READ
exit 0' > "$fake/selector-read-security"; /bin/chmod 700 "$fake/selector-read-security"
# Runs a command with stderr on a pipe nobody reads, which is what `2>&1 | tee` leaves once a ^C has killed tee.
print -r -- '#!/usr/bin/perl
pipe(my $read, my $write) or die "$!\n";
close($read);
open(STDERR, ">&", $write) or die "$!\n";
close($write);
$SIG{PIPE} = "DEFAULT";
exec(@ARGV) or die "exec failed: $!\n";' > "$fake/closed-stderr"; /bin/chmod 700 "$fake/closed-stderr"
# assert_stopped_before_mutation <name> <home>: the attempt exited 1, and the home, state directory, and Keychain are as run_attempt found them.
assert_stopped_before_mutation() {
  (( attempt_code == 1 )) || fail_with "attempt did not exit 1: $1" "$attempt_output"
  [[ $(managed_tree "$2") == "$attempt_tree" ]] || print -ru2 -- "$attempt_output"
  assert_tree "$2" "$attempt_tree" "attempt changed the home: $1"
  [[ $(<"$(manifest_file "$2")") == "$attempt_manifest" ]] || fail_with "attempt changed the manifest: $1" "$attempt_output"
  [[ $(state_listing "$2") == "$attempt_state" ]] || fail_with "attempt changed the state directory: $1" "$attempt_output"
  [[ $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || fail_with "attempt changed the Keychain state: $1" "$attempt_output"
  [[ $attempt_output != *'installation failed'* ]] || fail_with "attempt reported restoring when nothing had changed: $1" "$attempt_output"
}
# before_mutation_signal_check <name> <home> <signal> <whole group> [<env assignment>...]: preflight stages in a temporary directory only this attempt uses, and must leave nothing there.
before_mutation_signal_check() {
  local stop_name=$1 stop_home=$2 stop_signal=$3 stop_group=$4 stop_tmp="$test_root/attempt-stop-tmp"
  local -a stop_left
  shift 4
  /bin/rm -rf "$stop_tmp" "$signal_state".{armed,count,fired}
  /bin/mkdir "$stop_tmp"
  run_attempt "$stop_home" TMPDIR="$stop_tmp" $signal_env AGENT_NOTIFY_TEST_SIGNAL="$stop_signal" AGENT_NOTIFY_TEST_WHOLE_GROUP="$stop_group" "$@"
  [[ -e "$signal_state.fired" ]] || fail_with "no signal was sent: $stop_name" "$attempt_output"
  assert_stopped_before_mutation "$stop_name" "$stop_home"
  (( $#attempt_wrapper )) || [[ $attempt_output == *'interrupted before installing anything'* ]] || fail_with "attempt did not say it stopped: $stop_name" "$attempt_output"
  stop_left=("$stop_tmp"/*(ND))
  (( ! $#stop_left )) || fail_with "attempt left its stage behind: $stop_name" "$attempt_output"
}
# An empty backup directory that was already there is not the attempt's to remove, and keeps its mode.
existing_backup_root_check() {
  local stop_backups="$first_install_home/Library/Application Support/agent-notify/install-backups"
  /bin/rm -rf "$first_install_home"
  /bin/mkdir -p "$stop_backups"
  /bin/chmod 750 "$stop_backups"
  start_attempt "$first_install_home" AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/selector-read-security" AGENT_NOTIFY_TEST_SELECTOR_READ=51
  (( attempt_code == 1 )) || fail_with "attempt did not exit 1: $1" "$attempt_output"
  [[ -d $stop_backups && $(/usr/bin/stat -f '%Lp' "$stop_backups") == 750 ]] || fail_with "attempt changed an existing backup directory: $1" "$attempt_output"
}
# A reader that died with the ^C can no longer see the report, and must not stop the restore.
dead_reader_restore_check() {
  /bin/rm -f "$signal_state".{armed,count,fired}
  attempt_wrapper=("$fake/closed-stderr")
  run_attempt "$2" $signal_env AGENT_NOTIFY_TEST_SIGNAL=TERM AGENT_NOTIFY_TEST_WHOLE_GROUP=0 AGENT_NOTIFY_TEST_HASH_NTH=5 AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes
  attempt_wrapper=()
  [[ -e "$signal_state.fired" ]] || fail_with "no signal was sent: $1" "$attempt_output"
  (( attempt_code )) || fail_with "failed attempt reported success: $1" "$attempt_output"
  [[ $(managed_tree "$2") == "$attempt_tree" ]] || print -ru2 -- "$attempt_output"
  assert_tree "$2" "$attempt_tree" "failed attempt changed the home: $1"
  [[ $(<"$(manifest_file "$2")") == "$attempt_manifest" ]] || fail_with "failed attempt changed the manifest: $1" "$attempt_output"
  [[ $(state_listing "$2") == "$attempt_state" ]] || fail_with "failed attempt changed the state directory: $1" "$attempt_output"
  [[ $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || fail_with "failed attempt did not restore the Keychain state: $1" "$attempt_output"
}
# A read that fails for any reason but a missing item leaves the prior selector unknown, and a later rollback would delete it.
selector_read_refused_check() {
  run_attempt "$2" AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/selector-read-security" AGENT_NOTIFY_TEST_SELECTOR_READ="$3"
  assert_stopped_before_mutation "$1" "$2"
  [[ $attempt_output == *'unable to read the current Keychain selector; nothing was installed'* ]] || fail_with "attempt did not say why it stopped: $1" "$attempt_output"
}
# first_install_stop_check <name> <message> [<env assignment>...]: a fresh home ends with no files and no backup directory. The empty directories above that one stay, which is why the message cannot claim that nothing changed.
first_install_stop_check() {
  local stop_name=$1 stop_message=$2
  shift 2
  /bin/rm -rf "$first_install_home" "$signal_state".{armed,count,fired}
  start_attempt "$first_install_home" "$@"
  (( attempt_code == 1 )) || fail_with "attempt did not exit 1: $stop_name" "$attempt_output"
  [[ $attempt_output == *"$stop_message"* ]] || fail_with "attempt did not say why it stopped: $stop_name" "$attempt_output"
  [[ -z $(/usr/bin/find "$first_install_home" -type f -print) ]] || fail_with "attempt left files behind: $stop_name" "$attempt_output"
  [[ ! -e "$first_install_home/Library/Application Support/agent-notify/install-backups" ]] || fail_with "attempt left its backup directory: $stop_name" "$attempt_output"
  [[ $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || fail_with "attempt changed the Keychain state: $stop_name" "$attempt_output"
}
# Status 44 is a missing item, which is simply a first install of v2 credentials.
no_selector_check() {
  local fresh_home="$test_root/attempt-no-selector-home"
  /bin/rm -rf "$fresh_home"
  real_install "$fresh_home" yes
  run_attempt "$fresh_home" AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/selector-read-security" AGENT_NOTIFY_TEST_SELECTOR_READ=44
  (( ! attempt_code )) || fail_with "an install with no selector failed: $1" "$attempt_output"
  [[ $attempt_output == *'installation complete'* ]] || fail_with "an install with no selector did not complete: $1" "$attempt_output"
  run_attempt "$fresh_home" AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/selector-read-security" AGENT_NOTIFY_TEST_SELECTOR_READ=44 AGENT_NOTIFY_INSTALL_FAIL_AT=binary
  (( attempt_code )) || fail_with "failed attempt reported success: $1" "$attempt_output"
  [[ ! -e "$keychain_state/selector" && ! -e "$keychain_state/current-generation" ]] || fail_with "failed attempt left a selector where there was none: $1" "$attempt_output"
}
# Only a real terminal exercises the prompts: they read /dev/tty, and the secret ones turn echo off. The spawned terminal copies this one's modes, so the interrupt key is set explicitly.
print -r -- '# usage: expect -f prompt-interrupt.exp <runner> <prompts to answer before the interrupt>
lassign $argv runner answers
set timeout 30
log_user 1
set stty_init "intr ^C"
spawn -noecho /bin/zsh -f $runner
set replies [list "y" "user"]
set prompts [list "Proceed with the displayed plan" "Pushover user key: " "Pushover application token: "]
for {set i 0} {$i < $answers} {incr i} {
  expect -ex [lindex $prompts $i] {} timeout { puts "NO-PROMPT"; exit 99 }
  send -- "[lindex $replies $i]\r"
}
expect -ex [lindex $prompts $answers] {} timeout { puts "NO-PROMPT"; exit 99 }
after 100
send "\x03"
expect -ex "RUNNER-DONE" {} timeout { puts "STILL-WAITING"; exit 99 }' > "$fake/prompt-interrupt.exp"
# prompt_interrupt_check <name> <home> <prompts to answer first>
prompt_interrupt_check() {
  local prompt_out="$test_root/prompt-interrupt.out" prompt_code=0
  local -a prompt_env=(${(q)real_env})
  snapshot_home "$2"
  print -- old-generation > "$keychain_state/selector"; /bin/rm -f "$keychain_state/current-generation"
  # The handler keeps this shell alive through the interrupt, and resets to the default in the installer.
  { print -r -- '#!/bin/zsh -f'
    print -r -- 'trap : INT'
    print -r -- "env ${prompt_env} AGENT_NOTIFY_INSTALL_HOME=${(q)2} ${(q)root}/bin/agent-notify-install"
    print -r -- 'print -r -- "INSTALLER-STATUS=$?"'
    print -r -- '/bin/stty -a </dev/tty'
    print -r -- 'print -r -- RUNNER-DONE'
  } > "$fake/prompt-runner.zsh"
  # -n skips ~/.expect.rc. Without it expect exits 133 once HOME reaches 189 characters, which a long TMPDIR can cause.
  /usr/bin/expect -n -f "$fake/prompt-interrupt.exp" "$fake/prompt-runner.zsh" "$3" > "$prompt_out" 2>&1 || prompt_code=$?
  attempt_output=$(<"$prompt_out")
  (( ! prompt_code )) || fail_with "the terminal test did not finish, status $prompt_code: $1" "$attempt_output"
  [[ $attempt_output =~ 'INSTALLER-STATUS=([0-9]+)' ]] || fail_with "the terminal test reported no status: $1" "$attempt_output"
  attempt_code=$match[1]
  [[ $attempt_output == *' echo '* && $attempt_output != *' -echo '* ]] || fail_with "an interrupted installer left terminal echo off: $1" "$attempt_output"
  [[ $attempt_output == *'interrupted before installing anything'* ]] || fail_with "an interrupted installer did not say it stopped: $1" "$attempt_output"
  assert_stopped_before_mutation "$1" "$2"
}
# rollback_signal_check <name> <signal>: a rollback has changed files by then, so INT or TERM sent to the installer alone must not stop it. One sent to the whole group, or a hangup, does stop it.
rollback_signal_check() {
  local back_home="$test_root/attempt-rollback-signal-home" back_code=0
  /bin/rm -rf "$back_home" "$signal_state".{armed,count,fired}
  real_install "$back_home" yes
  attempt_output=$(own_group env $real_env $signal_env AGENT_NOTIFY_INSTALL_HOME="$back_home" AGENT_NOTIFY_INSTALL_CLAUDE_BIN=/missing/claude AGENT_NOTIFY_INSTALL_OPENCODE_BIN=/missing/opencode AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes AGENT_NOTIFY_TEST_SIGNAL_ON=remove AGENT_NOTIFY_TEST_SIGNAL="$2" AGENT_NOTIFY_TEST_WHOLE_GROUP=0 "$root/bin/agent-notify-install" --rollback 2>&1 </dev/null) || back_code=$?
  [[ $attempt_output != *'attempt timed out'* ]] || fail_with 'an attempt hung' "$attempt_output"
  [[ -e "$signal_state.fired" ]] || fail_with "no signal was sent: $1" "$attempt_output"
  (( ! back_code )) || fail_with "a signal stopped a rollback: $1" "$attempt_output"
  [[ $attempt_output == *'Selective rollback complete.'* && $attempt_output != *'before installing anything'* ]] || fail_with "a rollback did not finish: $1" "$attempt_output"
}
# Changes made during the attempt belong to someone else: the restore must leave them.
changes_during_attempt_check() {
  local edit_home="$test_root/attempt-edit-home" edit_library edit_binary
  edit_library="$edit_home/.local/lib/agent-notify/config.zsh" edit_binary="$edit_home/.local/bin/agent-notify"
  real_install "$edit_home" yes
  seed_prior_install "$edit_home"
  /bin/rm -f "$signal_state".{armed,count,fired}
  run_attempt "$edit_home" $signal_env AGENT_NOTIFY_INSTALL_FAIL_AT=settings AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes AGENT_NOTIFY_TEST_EDIT="$edit_library"$'\n'"$edit_binary"
  (( attempt_code )) || fail_with "failed attempt reported success: $1" "$attempt_output"
  [[ $(<"$edit_library") == *'# changed during the attempt'* && $(<"$edit_binary") == *'# changed during the attempt'* ]] || fail_with "failed attempt overwrote someone else's changes: $1" "$attempt_output"
  assert_attempt_report "$1"
}
# The settings check must run after everything that can take time, or a change made in that time is overwritten.
settings_change_during_attempt_check() {
  local edit_home="$test_root/attempt-edit-settings-home" edit_settings
  edit_settings="$edit_home/.claude/settings.json"
  real_install "$edit_home" yes
  /bin/rm -f "$signal_state".{armed,count,fired}
  run_attempt "$edit_home" $signal_env AGENT_NOTIFY_TEST_EDIT="$edit_settings"
  (( attempt_code )) || fail_with "failed attempt reported success: $1" "$attempt_output"
  [[ $(<"$edit_settings") == *'# changed during the attempt'* ]] || fail_with "failed attempt overwrote someone else's changes: $1" "$attempt_output"
  [[ $attempt_output == *'Claude settings changed during installation; refusing to overwrite'* ]] || fail_with "failed attempt did not refuse: $1" "$attempt_output"
  assert_attempt_report "$1"
}
# read_only_check <name> <home> <directory under the home> [<env assignment>...]: a real failure, with no failure hook.
read_only_check() {
  local read_only_name=$1 read_only_home=$2 read_only_dir="$2/$3" read_only_mode
  shift 3
  read_only_mode=$(/usr/bin/stat -f '%Lp' "$read_only_dir")
  /bin/chmod 500 "$read_only_dir"
  failed_attempt_check "$read_only_name" "$read_only_home" "$@"
  /bin/chmod "$read_only_mode" "$read_only_dir"
}

typeset attempt_home="$test_root/attempt-home" attempt_point
real_install "$attempt_home" yes
[[ $(/usr/bin/stat -f '%Lp' "$attempt_home/.claude/settings.json") == 600 && $(/usr/bin/stat -f '%Lp' "$(manifest_file "$attempt_home")") == 600 ]] || { print -u2 -- 'a successful install left settings or the manifest readable by others'; exit 1; }
[[ $(/usr/bin/stat -f '%Lp' "$attempt_home/Library/Application Support/agent-notify/install-backups") == 700 ]] || { print -u2 -- 'a first install left its backup directory readable by others'; exit 1; }
for attempt_point in keychain library binary plugin settings; do
  failed_attempt_check "same checkout, failing at $attempt_point" "$attempt_home" AGENT_NOTIFY_INSTALL_FAIL_AT="$attempt_point"
done

typeset attempt_older_home="$test_root/attempt-older-plugin-home" attempt_older_plugin="$test_root/attempt-older-plugin-home/.config/opencode/plugins/agent-notify.js"
real_install "$attempt_older_home" yes
print -r -- $'// >>> agent-notify managed plugin >>>\n// older plugin' > "$attempt_older_plugin"
/usr/bin/plutil -replace files.plugin.post_hash -string "$(/usr/bin/shasum -a 256 "$attempt_older_plugin" | /usr/bin/cut -d ' ' -f1)" "$(manifest_file "$attempt_older_home")"
failed_attempt_check 'same library, older plugin, failing at plugin' "$attempt_older_home" AGENT_NOTIFY_INSTALL_FAIL_AT=plugin

read_only_check 'same checkout, read-only plugins directory' "$attempt_home" .config/opencode/plugins
read_only_check 'same checkout, read-only binary directory' "$attempt_home" .local/bin
read_only_check 'same checkout, read-only library parent' "$attempt_home" .local/lib
# The backup copies this mode. If that stopped the backup being removed, later steps could succeed after the restore.
read_only_check 'same checkout, read-only library' "$attempt_home" .local/lib/agent-notify
read_only_check 'same checkout, read-only settings directory' "$attempt_home" .claude
# The manifest's move is the last step that can fail, and this fails it for real while the backups stay writable.
read_only_check 'same checkout, read-only state directory' "$attempt_home" 'Library/Application Support/agent-notify'
read_only_check 'same library, older plugin, read-only library parent' "$attempt_older_home" .local/lib

# The library path is not this attempt's to remove if the attempt never replaced it.
typeset attempt_link_home="$test_root/attempt-dangling-library-home"
real_install "$attempt_link_home" yes
/bin/rm -rf "$attempt_link_home/.local/lib/agent-notify"
/bin/ln -s "$test_root/no-such-library" "$attempt_link_home/.local/lib/agent-notify"
failed_attempt_check 'dangling link at the library path' "$attempt_link_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:yes AGENT_NOTIFY_INSTALL_FAIL_AT=library
# This attempt fails at the library step or after it, and either way the link has to be there afterwards.
failed_attempt_check 'dangling library link, failing at the library step or after it' "$attempt_link_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:yes AGENT_NOTIFY_INSTALL_FAIL_AT=binary

# Before the trap is set, only the explicit call in the main script reports the failure. An unreadable binary fails its backup.
typeset attempt_binary="$attempt_home/.local/bin/agent-notify" attempt_binary_mode
attempt_binary_mode=$(/usr/bin/stat -f '%Lp' "$attempt_binary")
snapshot_home "$attempt_home"
/bin/chmod 000 "$attempt_binary"
start_attempt "$attempt_home" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes
/bin/chmod "$attempt_binary_mode" "$attempt_binary"
(( attempt_code )) || fail_with 'failed attempt reported success: failure before the first mutation' "$attempt_output"
# The backup's own error is the failure here, so it is not a stray line.
attempt_output=$(print -r -- "$attempt_output" | /usr/bin/grep -v '^cp: .*Permission denied')
assert_attempt_restored 'failure before the first mutation' "$attempt_home"

# tree_hash ignores modes, so a restore that skips identical bytes would leave these changed.
typeset attempt_modes_home="$test_root/attempt-prior-modes-home"
real_install "$attempt_modes_home" yes
/bin/chmod 640 "$attempt_modes_home/.local/lib/agent-notify/config.zsh"
/bin/chmod 750 "$attempt_modes_home/.local/lib/agent-notify" "$attempt_modes_home/.local/bin/agent-notify"
failed_attempt_check 'same bytes, different prior modes, failing at binary' "$attempt_modes_home" AGENT_NOTIFY_INSTALL_FAIL_AT=binary

typeset attempt_different_home="$test_root/attempt-different-library-home"
real_install "$attempt_different_home" yes
seed_prior_install "$attempt_different_home"
failed_attempt_check 'different prior library, failing at binary' "$attempt_different_home" AGENT_NOTIFY_INSTALL_FAIL_AT=binary AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes

for attempt_point in INT TERM HUP; do
  before_mutation_signal_check "$attempt_point to the group during preflight" "$attempt_home" "$attempt_point" 1 AGENT_NOTIFY_INSTALL_CLAUDE_BIN="$fake/signal-claude"
  before_mutation_signal_check "$attempt_point to the group during the selector read" "$attempt_home" "$attempt_point" 1 AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/signal-security"
  before_mutation_signal_check "$attempt_point to the installer during preflight" "$attempt_home" "$attempt_point" 0 AGENT_NOTIFY_INSTALL_CLAUDE_BIN="$fake/signal-claude"
  before_mutation_signal_check "$attempt_point to the installer during the selector read" "$attempt_home" "$attempt_point" 0 AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/signal-security"
  before_mutation_signal_check "$attempt_point to the group while preflight holds its stage" "$attempt_home" "$attempt_point" 1 AGENT_NOTIFY_TEST_SIGNAL_ON=merge
  before_mutation_signal_check "$attempt_point to the installer while preflight holds its stage" "$attempt_home" "$attempt_point" 0 AGENT_NOTIFY_TEST_SIGNAL_ON=merge
done
attempt_args=(--dry-run)
before_mutation_signal_check 'INT to the group during a dry run' "$attempt_home" INT 1 AGENT_NOTIFY_TEST_SIGNAL_ON=merge
before_mutation_signal_check 'TERM to the installer during a dry run' "$attempt_home" TERM 0 AGENT_NOTIFY_TEST_SIGNAL_ON=merge
attempt_args=()
attempt_wrapper=("$fake/closed-stderr")
before_mutation_signal_check 'TERM to the installer while preflight holds its stage, reader gone' "$attempt_home" TERM 0 AGENT_NOTIFY_TEST_SIGNAL_ON=merge
before_mutation_signal_check 'TERM to the installer during the selector read, reader gone' "$attempt_home" TERM 0 AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/signal-security"
attempt_wrapper=()
dead_reader_restore_check 'signal during an upgrade, reader gone' "$attempt_different_home"
existing_backup_root_check 'existing empty backup directory'
# Other than 1, these are the low bytes of errSecInteractionNotAllowed, errSecAuthFailed, and errSecUserCanceled, by the truncation that makes a missing item 44, and a child killed by a signal.
selector_read_refused_check 'selector read failed' "$attempt_home" 1
selector_read_refused_check 'selector read not allowed' "$attempt_home" 36
selector_read_refused_check 'selector read denied' "$attempt_home" 51
selector_read_refused_check 'selector read cancelled' "$attempt_home" 128
selector_read_refused_check 'selector read killed' "$attempt_home" 131
no_selector_check 'no selector yet'
first_install_stop_check 'first install, interrupt during the selector read' 'interrupted before installing anything' $signal_env AGENT_NOTIFY_TEST_SIGNAL=INT AGENT_NOTIFY_TEST_WHOLE_GROUP=1 AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/signal-security"
first_install_stop_check 'first install, selector read denied' 'unable to read the current Keychain selector; nothing was installed' AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/selector-read-security" AGENT_NOTIFY_TEST_SELECTOR_READ=51
prompt_interrupt_check 'interrupt at the plan confirmation' "$attempt_home" 0
prompt_interrupt_check 'interrupt at the user key' "$attempt_home" 1
prompt_interrupt_check 'interrupt at the application token' "$attempt_home" 2

# A credential can arrive the moment its prompt appears, as a paste does on a loaded machine, so echo has to be off before the prompt is shown.
print -r -- 'lassign $argv runner
set timeout 30
log_user 1
spawn -noecho /bin/zsh -f $runner
expect -ex "Proceed with the displayed plan" {} timeout { puts "NO-PROMPT"; exit 99 }
send -- "y\r"
expect -ex "Pushover user key: " {} timeout { puts "NO-PROMPT"; exit 99 }
send -- "FAKEPASTEDKEY\r"
expect -ex "Pushover application token: " {} timeout { puts "NO-PROMPT"; exit 99 }
send -- "FAKEPASTEDTOKEN\r"
expect -ex "RUNNER-DONE" {} timeout { puts "STILL-WAITING"; exit 99 }' > "$fake/prompt-paste.exp"
typeset paste_output paste_code=0
typeset -a paste_env=(${(q)real_env})
{ print -r -- '#!/bin/zsh -f'
  print -r -- "env ${paste_env} AGENT_NOTIFY_INSTALL_HOME=${(q)test_root}/attempt-paste-home ${(q)root}/bin/agent-notify-install"
  print -r -- 'print -r -- "INSTALLER-STATUS=$?"'
  print -r -- '/bin/stty -a </dev/tty'
  print -r -- 'print -r -- RUNNER-DONE'
} > "$fake/prompt-paste-runner.zsh"
paste_output=$(/usr/bin/expect -n -f "$fake/prompt-paste.exp" "$fake/prompt-paste-runner.zsh" 2>&1) || paste_code=$?
(( ! paste_code )) || fail_with "the paste test did not finish, status $paste_code" "$paste_output"
[[ $paste_output != *FAKEPASTED* ]] || fail_with 'a credential sent as its prompt appeared was echoed' "$paste_output"
[[ $paste_output =~ 'INSTALLER-STATUS=([0-9]+)' ]] && (( match[1] == 0 )) && [[ $paste_output == *'installation complete'* ]] || fail_with 'the paste test did not finish an install' "$paste_output"
[[ $paste_output == *' echo '* && $paste_output != *' -echo '* ]] || fail_with 'a finished prompt left terminal echo off' "$paste_output"

# With nobody reading stderr, as after a ^C through tee, the prompt's own print raises SIGPIPE, and echo is already off by then.
print -r -- 'lassign $argv runner
set timeout 30
log_user 1
spawn -noecho /bin/zsh -f $runner
expect -ex "RUNNER-DONE" {} timeout { puts "STILL-WAITING"; exit 99 }' > "$fake/prompt-closed-stderr.exp"
{ print -r -- '#!/bin/zsh -f'
  print -r -- "env ${paste_env} AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_HOME=${(q)test_root}/attempt-closed-stderr-home ${(q)fake}/closed-stderr ${(q)root}/bin/agent-notify-install"
  print -r -- 'print -r -- "INSTALLER-STATUS=$?"'
  print -r -- '/bin/stty -a </dev/tty'
  print -r -- 'print -r -- RUNNER-DONE'
} > "$fake/prompt-closed-stderr-runner.zsh"
paste_code=0
paste_output=$(/usr/bin/expect -n -f "$fake/prompt-closed-stderr.exp" "$fake/prompt-closed-stderr-runner.zsh" 2>&1) || paste_code=$?
(( ! paste_code )) || fail_with "the closed stderr test did not finish, status $paste_code" "$paste_output"
[[ $paste_output =~ 'INSTALLER-STATUS=([0-9]+)' ]] && (( match[1] == 1 )) || fail_with 'a prompt nobody could read did not stop the installer' "$paste_output"
[[ $paste_output == *' echo '* && $paste_output != *' -echo '* ]] || fail_with 'a prompt nobody could read left terminal echo off' "$paste_output"

# A warning with nobody to read it must not stop the retire, since nothing else would remove the prior generation.
typeset retire_home="$test_root/attempt-retire-home"
real_install "$retire_home" yes
/bin/rm -f "$retire_home/Library/Application Support/agent-notify/settings.conf"
/bin/ln -s "$test_root/no-such-directory/settings.conf" "$retire_home/Library/Application Support/agent-notify/settings.conf"
print -r -- "#!/bin/zsh
[[ \$1 == retire ]] && : > '$signal_state.retired'
exec '$fake/keychain-jxa' \"\$@\"" > "$fake/retire-recording-keychain-jxa"
/bin/chmod 700 "$fake/retire-recording-keychain-jxa"
/bin/rm -f "$signal_state.retired"
attempt_wrapper=("$fake/closed-stderr")
run_attempt "$retire_home" AGENT_NOTIFY_INSTALL_KEYCHAIN_HELPER="$fake/retire-recording-keychain-jxa"
attempt_wrapper=()
[[ -e "$signal_state.retired" ]] || fail_with 'a warning nobody could read stopped the retire' "$attempt_output"

# The same the other way round: a failed retire's warning must not stop the excerpt settings being written.
/bin/rm -f "$retire_home/Library/Application Support/agent-notify/settings.conf"
print -r -- "#!/bin/zsh
[[ \$1 == retire ]] && exit 1
exec '$fake/keychain-jxa' \"\$@\"" > "$fake/retire-failing-keychain-jxa"
/bin/chmod 700 "$fake/retire-failing-keychain-jxa"
attempt_wrapper=("$fake/closed-stderr")
run_attempt "$retire_home" AGENT_NOTIFY_INSTALL_KEYCHAIN_HELPER="$fake/retire-failing-keychain-jxa"
attempt_wrapper=()
[[ -f "$retire_home/Library/Application Support/agent-notify/settings.conf" ]] || fail_with 'a warning nobody could read stopped the excerpt settings' "$attempt_output"

# A refusal prints before any restore, so with nobody to read it, SIGPIPE must not stop the restore from running.
typeset refusal_home="$test_root/attempt-refusal-home"
real_install "$refusal_home" yes
seed_prior_install "$refusal_home"
/bin/rm -f "$signal_state".{armed,count,fired}
attempt_wrapper=("$fake/closed-stderr")
run_attempt "$refusal_home" $signal_env AGENT_NOTIFY_TEST_EDIT="$refusal_home/.claude/settings.json" AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes
attempt_wrapper=()
(( attempt_code )) || fail_with 'a refused attempt reported success' "$attempt_output"
[[ $(<"$keychain_state/selector") == old-generation && ! -e "$keychain_state/current-generation" ]] || fail_with 'a refusal nobody could read stopped the Keychain restore' "$attempt_output"
[[ $(<"$refusal_home/.local/bin/agent-notify") == 'seed notifier' && $(<"$refusal_home/.local/lib/agent-notify/config.zsh") == '# seed library' ]] || fail_with 'a refusal nobody could read stopped the restore of the artifacts' "$attempt_output"
[[ $(<"$refusal_home/.claude/settings.json") == *'# changed during the attempt'* ]] || fail_with 'a refused attempt overwrote the changed settings' "$attempt_output"

# A job stopped on SIGTTOU and then resumed fails its stty -echo, and a credential must not then be read with echo on.
print -r -- 'use POSIX qw(setpgid tcsetpgrp WUNTRACED WIFSTOPPED);
$SIG{TTOU} = "IGNORE";
my $child = fork() // die "fork failed: $!\n";
if (!$child) {
  setpgid(0, 0);
  $SIG{TTOU} = "DEFAULT";
  exec(@ARGV) or die "exec failed: $!\n";
}
setpgid($child, $child);
open(my $tty, "+<", "/dev/tty") or die "$!\n";
waitpid($child, WUNTRACED);
print "INSTALLER-STOPPED\n" if WIFSTOPPED(${^CHILD_ERROR_NATIVE});
tcsetpgrp(fileno($tty), $child);
kill("CONT", -$child);
waitpid($child, 0);
tcsetpgrp(fileno($tty), getpgrp());
print "INSTALLER-STATUS=", $? >> 8, "\n";' > "$fake/stopped-job.pl"
print -r -- 'lassign $argv runner
set timeout 30
log_user 1
spawn -noecho /bin/zsh -f $runner
expect {
  -ex "Pushover user key: " { send -- "FAKEPASTEDKEY\r"; exp_continue }
  -ex "Pushover application token: " { send -- "FAKEPASTEDTOKEN\r"; exp_continue }
  -ex "RUNNER-DONE" {}
  timeout { puts "STILL-WAITING"; exit 99 }
}' > "$fake/prompt-stopped.exp"
{ print -r -- '#!/bin/zsh -f'
  print -r -- "env ${paste_env} AGENT_NOTIFY_INSTALL_TEST_CONFIRM=yes AGENT_NOTIFY_INSTALL_HOME=${(q)test_root}/attempt-stopped-home /usr/bin/perl ${(q)fake}/stopped-job.pl ${(q)root}/bin/agent-notify-install"
  print -r -- '/bin/stty -a </dev/tty'
  print -r -- 'print -r -- RUNNER-DONE'
} > "$fake/prompt-stopped-runner.zsh"
paste_code=0
paste_output=$(/usr/bin/expect -n -f "$fake/prompt-stopped.exp" "$fake/prompt-stopped-runner.zsh" 2>&1) || paste_code=$?
(( ! paste_code )) || fail_with "the stopped job test did not finish, status $paste_code" "$paste_output"
[[ $paste_output == *INSTALLER-STOPPED* ]] || fail_with 'the stopped job test did not stop the installer' "$paste_output"
[[ $paste_output != *FAKEPASTED* ]] || fail_with 'a stopped and resumed job read a credential with echo on' "$paste_output"
[[ $paste_output =~ 'INSTALLER-STATUS=([0-9]+)' ]] && (( match[1] == 1 )) && [[ $paste_output == *'unable to read user key'* ]] || fail_with 'a failed stty -echo did not refuse the prompt' "$paste_output"
[[ $paste_output == *' echo '* && $paste_output != *' -echo '* ]] || fail_with 'a failed stty -echo left terminal echo off' "$paste_output"
rollback_signal_check 'TERM during a rollback' TERM
rollback_signal_check 'INT during a rollback' INT

changes_during_attempt_check 'changes during the attempt'
settings_change_during_attempt_check 'settings changed during the attempt'

signal_attempt_check 'signal during the Keychain store' "$attempt_home" TERM 0 AGENT_NOTIFY_TEST_SIGNAL_ON=store
signal_attempt_check 'interrupt during the Keychain store' "$attempt_home" INT 0 AGENT_NOTIFY_TEST_SIGNAL_ON=store
signal_attempt_check 'terminal interrupt during the Keychain store' "$attempt_home" INT 1 AGENT_NOTIFY_TEST_SIGNAL_ON=store
# A credential too long for the pipe keeps the store pipeline's forked print alive when the signal arrives, and zsh keeps the trap in that child.
attempt_credentials=$'user\n'${(l:200000::x:)${:-}}
signal_attempt_check 'terminal interrupt during the Keychain store, long credential' "$attempt_home" INT 1 AGENT_NOTIFY_TEST_SIGNAL_ON=store
attempt_credentials=$'user\ntoken'
signal_attempt_check 'signal during the Keychain restore' "$attempt_home" TERM 0 AGENT_NOTIFY_TEST_SIGNAL_ON=rollback AGENT_NOTIFY_INSTALL_FAIL_AT=binary
for attempt_point in INT TERM HUP QUIT; do
  signal_attempt_check "$attempt_point to the group during the Keychain restore" "$attempt_home" "$attempt_point" 1 AGENT_NOTIFY_TEST_SIGNAL_ON=rollback AGENT_NOTIFY_INSTALL_FAIL_AT=binary
done
signal_attempt_check 'terminal interrupt during the Keychain restore, different prior library' "$attempt_different_home" INT 1 AGENT_NOTIFY_TEST_SIGNAL_ON=rollback AGENT_NOTIFY_INSTALL_FAIL_AT=binary AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes

hash_signal_sweep 'same checkout, signal' "$attempt_home" TERM 0
hash_signal_sweep 'different prior library, signal' "$attempt_different_home" TERM 0 AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes
hash_signal_sweep 'different prior library, terminal interrupt' "$attempt_different_home" INT 1 AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes
hash_signal_sweep 'different prior library, failing at settings, terminal interrupt' "$attempt_different_home" INT 1 AGENT_NOTIFY_INSTALL_FAIL_AT=settings AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes
hash_signal_sweep 'different prior library, hangup' "$attempt_different_home" HUP 1 AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes
first_install_signal_sweep 'first install, terminal interrupt'

finished_install_signal_check 'terminal interrupt during the retire' INT
finished_install_signal_check 'hangup during the retire' HUP
finished_install_signal_check 'termination during the retire' TERM

# These land by timing, so one round can miss a regression, but none can fail a correct installer.
typeset attempt_round
for attempt_round in 1 2; do
  signal_on_change_check 'signal between the two library moves' .local/lib/agent-notify TERM 0
  signal_on_change_check 'terminal interrupt between the two library moves' .local/lib/agent-notify INT 1
  signal_on_change_check 'signal just after the settings move' .claude/settings.json TERM 0
  signal_on_change_check 'terminal interrupt just after the settings move' .claude/settings.json INT 1
  signal_on_change_check 'signal just after the manifest moves' 'Library/Application Support/agent-notify/install-manifest.json' TERM 0
  signal_on_change_check 'terminal interrupt just after the manifest moves' 'Library/Application Support/agent-notify/install-manifest.json' INT 1
  signal_over_link_check 'signal just after the binary move, over a library link' TERM 0
  signal_over_link_check 'terminal interrupt just after the binary move, over a library link' INT 1
  signal_over_link_check 'hangup just after the binary move, over a library link' HUP 1
done

# A signal at any hash, with some links already replaced: every one of them has to come back.
typeset attempt_links_home="$test_root/attempt-links-home"
real_install "$attempt_links_home" yes
/bin/rm -rf "$attempt_links_home/.local/lib/agent-notify" "$attempt_links_home/.local/bin/agent-notify" "$attempt_links_home/.claude/settings.json"
/bin/ln -s "$test_root/no-such-library" "$attempt_links_home/.local/lib/agent-notify"
/bin/ln -s "$test_root/no-such-binary" "$attempt_links_home/.local/bin/agent-notify"
/bin/ln -s "$test_root/no-such-settings" "$attempt_links_home/.claude/settings.json"
hash_signal_sweep 'signal with links replaced' "$attempt_links_home" TERM 0 AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:yes
hash_signal_sweep 'terminal interrupt with links replaced' "$attempt_links_home" INT 1 AGENT_NOTIFY_INSTALL_TEST_CONFIRM_SEQUENCE=yes:yes

print -- 'installer tests passed'
