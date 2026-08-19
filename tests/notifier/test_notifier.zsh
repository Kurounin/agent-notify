#!/usr/bin/env zsh

unsetopt xtrace verbose
emulate -R zsh
setopt errexit no_unset pipe_fail
export PATH='/usr/bin:/bin:/usr/sbin:/sbin'

typeset root=${0:A:h:h:h}
typeset fixture_dir="$root/tests/fixtures"
typeset test_root
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-notify-test.XXXXXX")
trap '/bin/rm -rf "$test_root"' EXIT

export HOME="$test_root/home"
export AGENT_NOTIFY_STATE_DIR="$test_root/state"
export AGENT_NOTIFY_DIAGNOSTIC_DIR="$test_root/diagnostics"
export AGENT_NOTIFY_MIN_RUNTIME_SECONDS=30
export AGENT_NOTIFY_ATTENTION_DEBOUNCE_SECONDS=60
export AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS=2
export AGENT_NOTIFY_LOCK_STALE_SECONDS=60

source "$root/lib/agent-notify/config.zsh"
source "$root/lib/agent-notify/json.zsh"
source "$root/lib/agent-notify/state.zsh"
source "$root/lib/agent-notify/delivery.zsh"
source "$root/lib/agent-notify/event.zsh"

typeset -gi deliveries=0
agent_notify_diag() { :; }
agent_notify_deliver() { (( deliveries++ )); return 0; }

assert_equals() {
  [[ $1 == "$2" ]] || { print -u2 -- "expected '$2', got '$1'"; exit 1; }
}

assert_equals "$AGENT_NOTIFY_OPEN_CODE_ATTENTION_FAMILY" 'permission.asked/replied and question.asked/replied/rejected'

send_event() {
  local now=$1 fixture=$2
  AGENT_NOTIFY_NOW=$now agent_notify_event < "$fixture_dir/$fixture"
}

agent_notify_validate_json_document "$(/bin/cat "$fixture_dir/claude-settings/existing.json")"
! agent_notify_validate_json_document '{invalid json}'

send_event 100 began.json
send_event 129 completed.json
assert_equals "$deliveries" 0
send_event 200 began.json
send_event 231 completed.json
assert_equals "$deliveries" 1

AGENT_NOTIFY_NOW=240 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"session-isolation-a","session_dir":"/tmp/a"}
EOF
AGENT_NOTIFY_NOW=241 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"session-isolation-b","session_dir":"/tmp/b"}
EOF
AGENT_NOTIFY_NOW=280 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"completed","session_id":"session-isolation-a","session_dir":"/tmp/a"}
EOF
typeset isolation_b_key
isolation_b_key=$(agent_notify_session_key claude-code session-isolation-b)
agent_notify_load_state "$AGENT_NOTIFY_STATE_DIR/$isolation_b_key.state"
[[ $STATE_ACTIVE == 1 && -z $STATE_TERMINAL ]] || { print -u2 -- 'session state leaked across sessions'; exit 1; }

send_event 300 attention.json
assert_equals "$deliveries" 3
AGENT_NOTIFY_NOW=301 agent_notify_event <<'EOF'
{"source":"opencode","kind":"attention","session_id":"session-one","session_dir":"/private/tmp/my-project","request_id":"request-two"}
EOF
assert_equals "$deliveries" 3
send_event 361 attention.json
assert_equals "$deliveries" 3
send_event 362 attention-cleared.json
AGENT_NOTIFY_NOW=363 agent_notify_event <<'EOF'
{"source":"opencode","kind":"attention","session_id":"session-one","session_dir":"/private/tmp/my-project","request_id":"request-two"}
EOF
assert_equals "$deliveries" 4
send_event 364 attention-cleared-two.json
AGENT_NOTIFY_NOW=365 agent_notify_event <<'EOF'
{"source":"opencode","kind":"attention","session_id":"session-one","session_dir":"/private/tmp/my-project","request_id":"request-three"}
EOF
assert_equals "$deliveries" 5

send_event 400 invalid.json
assert_equals "$deliveries" 5

send_event 410 failed-no-began.json
assert_equals "$deliveries" 6
AGENT_NOTIFY_NOW=411 agent_notify_event <<'EOF'
{"source":"opencode","kind":"completed","session_id":"failed-without-began","session_dir":"/tmp/failed-project"}
EOF
assert_equals "$deliveries" 6

typeset reset_key deliveries_before_reset=$deliveries
AGENT_NOTIFY_NOW=420 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"reset-session","session_dir":"/tmp/reset-project"}
EOF
reset_key=$(agent_notify_session_key claude-code reset-session)
AGENT_NOTIFY_NOW=421 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"reset","session_id":"reset-session","session_dir":"/tmp/reset-project"}
EOF
[[ ! -e $AGENT_NOTIFY_STATE_DIR/$reset_key.state ]] || { print -u2 -- 'reset did not clear session state'; exit 1; }
assert_equals "$deliveries" "$deliveries_before_reset"

typeset active_retention_key
AGENT_NOTIFY_NOW=10000 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"active-retention","session_dir":"/tmp/active-project"}
EOF
active_retention_key=$(agent_notify_session_key claude-code active-retention)
AGENT_NOTIFY_NOW=$(( 10000 + AGENT_NOTIFY_MAX_ACTIVE_SECONDS - 1 )) agent_notify_prune_state
agent_notify_load_state "$AGENT_NOTIFY_STATE_DIR/$active_retention_key.state"
[[ $STATE_ACTIVE == 1 ]] || { print -u2 -- 'active state was pruned before maximum lifetime'; exit 1; }

typeset stale_key
stale_key=$(agent_notify_session_key claude-code stale-session)
/bin/mkdir -p "$AGENT_NOTIFY_STATE_DIR/$stale_key.lock"
print -- '999999 0' > "$AGENT_NOTIFY_STATE_DIR/$stale_key.lock/owner"
AGENT_NOTIFY_NOW=100 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"stale-session","session_dir":"/tmp/stale"}
EOF
[[ ! -e $AGENT_NOTIFY_STATE_DIR/$stale_key.lock ]] || { print -u2 -- 'stale lock was not recovered'; exit 1; }

typeset busy_lock="$AGENT_NOTIFY_STATE_DIR/busy.lock"
/bin/mkdir "$busy_lock"
print -- "$$ 0" > "$busy_lock/owner"
if AGENT_NOTIFY_NOW=100 agent_notify_with_mkdir_lock "$busy_lock" true; then
  print -u2 -- 'live lock did not time out'
  exit 1
fi
/bin/rm -rf "$busy_lock"
AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS=100

typeset retained_state="$AGENT_NOTIFY_STATE_DIR/prune-locked.state"
STATE_ACTIVE=0 STATE_STARTED_AT=0 STATE_ATTENTIONS='' STATE_LAST_ATTENTION_AT=0 STATE_TERMINAL=completed STATE_UPDATED_AT=0
agent_notify_save_state "$retained_state"
/bin/mkdir "$AGENT_NOTIFY_STATE_DIR/prune-locked.lock"
print -- "$$ 0" > "$AGENT_NOTIFY_STATE_DIR/prune-locked.lock/owner"
AGENT_NOTIFY_NOW=1000000 agent_notify_prune_state
[[ -f $retained_state ]] || { print -u2 -- 'pruning raced a live state lock'; exit 1; }
/bin/rm -rf "$AGENT_NOTIFY_STATE_DIR/prune-locked.lock"
AGENT_NOTIFY_NOW=1000000 agent_notify_prune_state
[[ ! -e $retained_state ]] || { print -u2 -- 'stale inactive state was not pruned'; exit 1; }

AGENT_NOTIFY_NOW=500 agent_notify_event <<'EOF'
{"source":"opencode","kind":"attention","session_id":"concurrent-clears","session_dir":"/tmp/lock-test","request_id":"clear-one"}
EOF
AGENT_NOTIFY_NOW=501 agent_notify_event <<'EOF'
{"source":"opencode","kind":"attention","session_id":"concurrent-clears","session_dir":"/tmp/lock-test","request_id":"clear-two"}
EOF
typeset concurrent_key
concurrent_key=$(agent_notify_session_key opencode concurrent-clears)
(
AGENT_NOTIFY_NOW=510 agent_notify_event <<'EOF'
{"source":"opencode","kind":"attention-cleared","session_id":"concurrent-clears","session_dir":"/tmp/lock-test","request_id":"clear-one"}
EOF
)&
typeset clear_one_pid=$!
(
AGENT_NOTIFY_NOW=510 agent_notify_event <<'EOF'
{"source":"opencode","kind":"attention-cleared","session_id":"concurrent-clears","session_dir":"/tmp/lock-test","request_id":"clear-two"}
EOF
)&
typeset clear_two_pid=$!
wait "$clear_one_pid" "$clear_two_pid"
agent_notify_load_state "$AGENT_NOTIFY_STATE_DIR/$concurrent_key.state"
[[ -z $STATE_ATTENTIONS ]] || { print -u2 -- 'concurrent attention clears lost a request'; exit 1; }

AGENT_NOTIFY_NOW=600 agent_notify_event <<'EOF'
{"source":"opencode","kind":"began","session_id":"terminal-race","session_dir":"/tmp/terminal-race"}
EOF
typeset terminal_key
terminal_key=$(agent_notify_session_key opencode terminal-race)
(
AGENT_NOTIFY_NOW=631 agent_notify_event <<'EOF'
{"source":"opencode","kind":"completed","session_id":"terminal-race","session_dir":"/tmp/terminal-race"}
EOF
)&
typeset completed_pid=$!
(
AGENT_NOTIFY_NOW=631 agent_notify_event <<'EOF'
{"source":"opencode","kind":"failed","session_id":"terminal-race","session_dir":"/tmp/terminal-race"}
EOF
)&
typeset failed_pid=$!
wait "$completed_pid"
wait "$failed_pid"
agent_notify_load_state "$AGENT_NOTIFY_STATE_DIR/$terminal_key.state"
[[ $STATE_ACTIVE == 0 && ( $STATE_TERMINAL == completed || $STATE_TERMINAL == failed ) ]] || { print -u2 -- 'terminal race was not serialized'; exit 1; }

source "$root/lib/agent-notify/delivery.zsh"
typeset keychain_jxa="$test_root/keychain-jxa" keychain_legacy_marker="$test_root/keychain-legacy-used"
print -r -- '#!/bin/zsh
[[ $1 == -l && $2 == JavaScript && $4 == read ]] || exit 1
exec /usr/bin/osascript -l JavaScript "$3" read' > "$keychain_jxa"
/bin/chmod 700 "$keychain_jxa"
agent_notify_keychain_lookup() {
  print -- legacy > "$keychain_legacy_marker"
  /bin/sleep 5
  return 1
}
agent_notify_curl_request() {
  while IFS= read -r _; do :; done
  print -rn -- $'{"status":1,"request":"test-success"}\nAGENT_NOTIFY_META:200:{}'
}
typeset keychain_read_started keychain_read_elapsed
keychain_read_started=$(/bin/date +%s)
typeset keychain_runtime_log="$test_root/keychain-runtime.log"
/usr/bin/touch "$keychain_runtime_log"
AGENT_NOTIFY_LIB_DIR="$root/lib/agent-notify" AGENT_NOTIFY_KEYCHAIN_JXA_BIN="$keychain_jxa" AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$root/tests/fixtures/keychain-v2-security-shim.jxa" AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM_LOG="$keychain_runtime_log" agent_notify_deliver completed claude-code project || { print -u2 -- 'runtime JXA Keychain read did not deliver'; exit 1; }
keychain_read_elapsed=$(( $(/bin/date +%s) - keychain_read_started ))
(( keychain_read_elapsed < 3 )) || { print -u2 -- 'runtime Keychain read waited for legacy security'; exit 1; }
[[ ! -e $keychain_legacy_marker ]] || { print -u2 -- 'runtime used blocking security -w lookup'; exit 1; }
[[ $(<"$keychain_runtime_log") == $'lookup agent-notify.pushover.v2.active-generation\nlookup agent-notify.pushover.v2.user-key.1720000000-54321\nlookup agent-notify.pushover.v2.app-token.1720000000-54321' ]] || { print -u2 -- 'runtime queried a legacy or malformed Keychain service'; exit 1; }
! AGENT_NOTIFY_LIB_DIR="$root/lib/agent-notify" AGENT_NOTIFY_KEYCHAIN_JXA_BIN="$keychain_jxa" AGENT_NOTIFY_KEYCHAIN_SECURITY_SHIM="$root/tests/fixtures/keychain-v2-security-shim.jxa" AGENT_NOTIFY_KEYCHAIN_TEST_FAILURE_STAGE=selector agent_notify_deliver completed claude-code project
typeset keychain_failure_diagnostics
keychain_failure_diagnostics=$(/bin/cat "$AGENT_NOTIFY_DIAGNOSTIC_DIR"/*.log(N))
[[ $keychain_failure_diagnostics == *'component=keychain code=selector_-25291 http_status=0 request_id=-'* ]] || { print -u2 -- 'runtime Keychain OSStatus diagnostic missing'; exit 1; }
[[ $keychain_failure_diagnostics != *'agent-notify.pushover.'* && $keychain_failure_diagnostics != *userkey012345678901234567890123* && $keychain_failure_diagnostics != *apptoken01234567890123456789012* ]] || { print -u2 -- 'runtime Keychain diagnostic exposed metadata or credentials'; exit 1; }
agent_notify_keychain_read() {
  print -rn -- $'ok\t1720000000-54321\tuserkey012345678901234567890123\tapptoken01234567890123456789012'
}
if ! agent_notify_deliver completed claude-code project; then
  print -u2 -- 'generation-selected credentials did not deliver'
  exit 1
fi
agent_notify_curl_request() {
  while IFS= read -r _; do :; done
  print -rn -- $'{"status":0,"request":"test-failure"}\nAGENT_NOTIFY_META:503:{}'
}
! agent_notify_deliver attention claude-code project
agent_notify_transition "$concurrent_key" opencode attention /tmp/lock-test delivery-failure

typeset raw_event raw_session='session-redaction-marker' raw_path='path-redaction-marker' raw_request='payload-redaction-marker'
raw_event="{\"source\":\"opencode\",\"kind\":\"attention\",\"session_id\":\"$raw_session\",\"session_dir\":\"/tmp/$raw_path\",\"request_id\":\"$raw_request\"}"
print -rn -- "$raw_event" | AGENT_NOTIFY_NOW=700 agent_notify_event
typeset diagnostic_contents
diagnostic_contents=$(/bin/cat "$AGENT_NOTIFY_DIAGNOSTIC_DIR"/*.log(N))
forbidden_diagnostic_values=("$raw_event" "$raw_session" "$raw_path" "$raw_request" 'userkey012345678901234567890123' 'apptoken01234567890123456789012' 'data-urlencode')
for forbidden_diagnostic_value in "${forbidden_diagnostic_values[@]}"; do
  [[ $diagnostic_contents != *"$forbidden_diagnostic_value"* ]] || { print -u2 -- 'diagnostic log exposed sensitive event data'; exit 1; }
done

agent_notify_curl_request() {
  local request_config
  request_config=$(/bin/cat)
  [[ $request_config == *"data-urlencode = \"title=$AGENT_NOTIFY_EXPECTED_TITLE\""* && $request_config == *"data-urlencode = \"message=$AGENT_NOTIFY_EXPECTED_MESSAGE\""* && $request_config == *"data-urlencode = \"priority=$AGENT_NOTIFY_EXPECTED_PRIORITY\""* ]] || return 1
  print -rn -- $'{"status":1,"request":"delivery-content"}\nAGENT_NOTIFY_META:200:{}'
}
for delivery_case in 'attention|Attention required|0' 'completed|Turn complete|0' 'failed|Agent error|0'; do
  IFS='|' read -r delivery_kind AGENT_NOTIFY_EXPECTED_MESSAGE AGENT_NOTIFY_EXPECTED_PRIORITY <<< "$delivery_case"
  AGENT_NOTIFY_EXPECTED_TITLE='Claude Code — delivery-project'
  agent_notify_deliver "$delivery_kind" claude-code delivery-project || { print -u2 -- 'delivery content did not match event kind'; exit 1; }
done

typeset curl_config hostile_home="$test_root/hostile-home"
curl_config=$(agent_notify_curl_config userkey012345678901234567890123 apptoken01234567890123456789012 'Claude Code — project' 'Attention required' 0)
[[ $curl_config != *'location'* && $curl_config == *'max-redirs = 0'* && $curl_config == *'proto = "=https"'* ]] || { print -u2 -- 'curl redirect or protocol policy is missing'; exit 1; }
/bin/mkdir -p "$hostile_home"
print -- '--this-option-does-not-exist' > "$hostile_home/.curlrc"
print -rn -- "$curl_config" | HOME="$hostile_home" /usr/bin/curl --disable --config - --proto '=file' --request GET --url file:///dev/null --output /dev/null --silent >/dev/null 2>&1
typeset delivery_source
delivery_source=$(/bin/cat "$root/lib/agent-notify/delivery.zsh")
[[ $delivery_source == *'/usr/bin/curl --disable --config -'* ]] || { print -u2 -- 'curl is not fixed and disabled before config'; exit 1; }

typeset install_root="$test_root/installed" installed_bin="$test_root/installed/.local/bin/agent-notify"
/bin/mkdir -p "$install_root/.local/bin" "$install_root/.local/lib"
/bin/cp "$root/bin/agent-notify" "$installed_bin"
/bin/cp -R "$root/lib/agent-notify" "$install_root/.local/lib/"
/bin/chmod 700 "$installed_bin"
AGENT_NOTIFY_HOME="$test_root/untrusted" "$installed_bin" supported-versions >/dev/null
(
  export PATH="$install_root/.local/bin:/usr/bin:/bin"
  agent-notify supported-versions >/dev/null
)

print -r -- 'agent_notify_deliver() { /bin/sh -c '\''echo "$PPID"'\'' > "$AGENT_NOTIFY_SMOKE_PID_MARKER"; /bin/sleep 5; }' >> "$install_root/.local/lib/agent-notify/delivery.zsh"
typeset smoke_output smoke_output_file smoke_pid_marker smoke_pid smoke_started smoke_elapsed
smoke_output_file="$test_root/smoke-output"
smoke_pid_marker="$test_root/smoke-delivery-parent"
smoke_started=$(/bin/date +%s)
AGENT_NOTIFY_SMOKE_TEST_TIMEOUT_SECONDS=1 AGENT_NOTIFY_SMOKE_PID_MARKER="$smoke_pid_marker" "$installed_bin" smoke-test > "$smoke_output_file" 2>&1 &
smoke_pid=$!
if wait "$smoke_pid"; then
  print -u2 -- 'smoke test accepted a stalled delivery'
  exit 1
fi
smoke_elapsed=$(( $(/bin/date +%s) - smoke_started ))
(( smoke_elapsed < 3 )) || { print -u2 -- 'smoke test timeout was not bounded'; exit 1; }
[[ $(<"$smoke_pid_marker") == "$smoke_pid" ]] || { print -u2 -- 'smoke test did not run delivery in the foreground process'; exit 1; }
smoke_output=$(<"$smoke_output_file")
[[ $smoke_output == *'smoke test timed out (see sanitized diagnostics)'* ]] || { print -u2 -- 'smoke timeout diagnostics were not sanitized'; exit 1; }
[[ $smoke_output != *'command not found'* ]] || { print -u2 -- 'smoke watchdog emitted a shell error'; exit 1; }
typeset smoke_diagnostics
smoke_diagnostics=$(/bin/cat "$AGENT_NOTIFY_DIAGNOSTIC_DIR"/*.log(N))
[[ $smoke_diagnostics == *'component=transport code=smoke_timeout http_status=0 request_id=-'* ]] || { print -u2 -- 'smoke timeout diagnostic was not recorded'; exit 1; }

[[ $(/usr/bin/stat -f '%Lp' "$AGENT_NOTIFY_STATE_DIR") == 700 ]] || { print -u2 -- 'state directory is not user-only'; exit 1; }

print -- 'notifier tests passed'
