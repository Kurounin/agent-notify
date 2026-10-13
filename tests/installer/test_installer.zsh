#!/usr/bin/env zsh

setopt errexit no_unset pipe_fail

typeset root=${0:A:h:h:h}
typeset settings_fixture="$root/tests/fixtures/claude-settings/existing.json"
typeset test_root
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-notify-installer.XXXXXX")
trap '/bin/rm -rf "$test_root"' EXIT

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
typeset -a supported_opencode_versions=(2.0.27 v2.0.27 'opencode 2.0.27' 'opencode v2.0.27' $'opencode\tv2.0.27' 2.0.28 2.0.999 2.0.1000)
typeset -a rejected_opencode_versions=(1.0.0 1.999.999 1.1000.27 2.0.0 2.0.26 2.1.0 3.0.0 2.0.27.1 2.0.27-rc.1 2.0.27+build.1 'opencode v2.0.27.1' 'opencode v2.0.27-rc.1' 'opencode v2.0.27+build.1' unknown 'opencode unknown' 'opencode v2.0.27 trailing' 'prefix 2.0.27' 2.0 '2.0.27 2.1.0' opencodet2.0.27 'opencode t2.0.27')
for version in $supported_opencode_versions; do
  "$root/bin/agent-notify" validate-version opencode "$version" || { print -u2 -- 'supported OpenCode version rejected'; exit 1; }
done
for version in $rejected_opencode_versions; do
  "$root/bin/agent-notify" validate-version opencode "$version" >/dev/null 2>&1 && { print -u2 -- 'unsupported OpenCode version accepted'; exit 1; }
done

make_client() { { print -- '#!/bin/zsh'; print -- "print -- '$2'"; } > "$1"; /bin/chmod 700 "$1"; }
make_helper() { print -r -- '#!/bin/zsh
if [[ $3 == *manifest.jxa ]]; then value=$(/usr/bin/plutil -extract "$5" raw "$4") || exit $?; [[ $value == 1 ]] && value=true; [[ $value == 0 ]] && value=false; print -- "$value"; exit 0; fi
if [[ $3 == *plugin-jxa ]]; then /usr/bin/osascript -l JavaScript "'"$2"'" "$4" "$5" "$6"; exit $?; fi
if [[ $3 == *failing-helper ]]; then exit 7; fi
if [[ $3 == *keychain-jxa ]]; then "$3" "${@:4}"; exit $?; fi
case $4 in inspect) print -- valid;; merge|remove-managed) /bin/cp "$5" "$6" 2>/dev/null || print -- "{}" > "$6";; store|rollback|remove) /bin/cat >/dev/null;; esac' > "$1"; /bin/chmod 700 "$1"; }
make_keychain_helper() { print -r -- "#!/bin/zsh
typeset state='$2' raw generation selector
case \$1 in
  store) raw=\$(/bin/cat); [[ \$raw =~ '\\\"generation\\\":\\\"([^\\\"]+)' ]] || exit 1; generation=\$match[1]; print -- \$generation > \"\$state/selector\"; print -- \$generation > \"\$state/current-generation\" ;;
  rollback) raw=\$(/bin/cat); [[ \$raw =~ '\\\"selector\\\":\\\"([^\\\"]*)' ]] || exit 1; selector=\$match[1]; [[ -n \$selector ]] && print -- \$selector > \"\$state/selector\" || /bin/rm -f \"\$state/selector\"; /bin/rm -f \"\$state/current-generation\" ;;
  remove) /bin/rm -f \"\$state/selector\" \"\$state/current-generation\" ;;
esac" > "$1"; /bin/chmod 700 "$1"; }
make_security() { print -r -- '#!/bin/zsh
[[ " $* " == *" -w "* ]] && print -- old-generation
exit 0' > "$1"; /bin/chmod 700 "$1"; }
typeset fake="$test_root/fake"; /bin/mkdir -p "$fake"
typeset keychain_state="$test_root/keychain-state"; /bin/mkdir "$keychain_state"; print -- old-generation > "$keychain_state/selector"
make_client "$fake/claude" 'claude 1.2.3'; make_client "$fake/opencode" 'opencode v2.0.27'; make_helper "$fake/jxa" "$root/installer/opencode-plugin.jxa"; make_keychain_helper "$fake/keychain-jxa" "$keychain_state"; make_security "$fake/security"
/usr/bin/touch "$fake/plugin-jxa"; /bin/chmod 600 "$fake/plugin-jxa"
typeset -a env=(AGENT_NOTIFY_INSTALL_HOME="$test_root/home" AGENT_NOTIFY_INSTALL_SKIP_PLATFORM_CHECK=1 AGENT_NOTIFY_INSTALL_MACOS_VERSION=14.5 AGENT_NOTIFY_INSTALL_CLAUDE_BIN="$fake/claude" AGENT_NOTIFY_INSTALL_OPENCODE_BIN="$fake/opencode" AGENT_NOTIFY_INSTALL_SECURITY_BIN="$fake/security" AGENT_NOTIFY_INSTALL_JXA_BIN="$fake/jxa" AGENT_NOTIFY_INSTALL_KEYCHAIN_HELPER="$fake/keychain-jxa" AGENT_NOTIFY_INSTALL_SETTINGS_HELPER="$fake/jxa" AGENT_NOTIFY_INSTALL_PLUGIN_HELPER="$fake/plugin-jxa")

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
print -- 'installer tests passed'
