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
typeset last_delivery_context=''
agent_notify_deliver() { (( deliveries++ )); last_delivery_context=$3; return 0; }

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

typeset normalized_tmux_event normalized_legacy_event valid_tmux_session oversized_tmux_session state_contents
normalized_tmux_event=$(agent_notify_normalize_json '{"source":"claude-code","kind":"began","session_id":"tmux-normalized","session_dir":"/tmp/project","tmux_session":"team/api"}')
agent_notify_event_fields "$normalized_tmux_event"
assert_equals "${#AGENT_NOTIFY_EVENT_FIELDS}" 7
assert_equals "${AGENT_NOTIFY_EVENT_FIELDS[7]:-}" 'team/api'
normalized_legacy_event=$(agent_notify_normalize_json '{"source":"claude-code","kind":"began","session_id":"legacy-normalized","session_dir":"/tmp/project"}')
agent_notify_event_fields "$normalized_legacy_event"
assert_equals "${#AGENT_NOTIFY_EVENT_FIELDS}" 7
assert_equals "${AGENT_NOTIFY_EVENT_FIELDS[7]:-}" ''
agent_notify_event_fields "$(agent_notify_normalize_json '{"source":"claude-code","kind":"began","session_id":"tmux-invalid","session_dir":"/tmp/project","tmux_session":"bad\nvalue"}')"
assert_equals "${AGENT_NOTIFY_EVENT_FIELDS[7]:-}" ''

valid_tmux_session=$(/usr/bin/printf '\\ud83d\\ude00%.0s' {1..128})
oversized_tmux_session=$(/usr/bin/printf '\\ud83d\\ude00%.0s' {1..129})
for tmux_session in '' "$oversized_tmux_session" 'c0-marker\u0001' 'del-marker\u007f'; do
  agent_notify_event_fields "$(agent_notify_normalize_json "{\"source\":\"claude-code\",\"kind\":\"began\",\"session_id\":\"tmux-dropped-normalized\",\"session_dir\":\"/tmp/project\",\"tmux_session\":\"$tmux_session\"}")"
  assert_equals "${AGENT_NOTIFY_EVENT_FIELDS[7]:-}" ''
done
agent_notify_event_fields "$(agent_notify_normalize_json "{\"source\":\"claude-code\",\"kind\":\"began\",\"session_id\":\"tmux-boundary-normalized\",\"session_dir\":\"/tmp/project\",\"tmux_session\":\"$valid_tmux_session\"}")"
[[ -n ${AGENT_NOTIFY_EVENT_FIELDS[7]:-} ]] || { print -u2 -- 'a 256-unit tmux session was dropped'; exit 1; }

assert_equals "$(agent_notify_display_context 'team/api' '/tmp/project')" 'team_api'
assert_equals "$(agent_notify_display_context '   ' '/tmp/project')" 'project'
assert_equals "$(agent_notify_display_context '' '/tmp/project')" 'project'
typeset long_tmux_label expected_long_tmux_label
long_tmux_label=$(/usr/bin/printf 'x%.0s' {1..60})
expected_long_tmux_label=$(/usr/bin/printf 'x%.0s' {1..48})
assert_equals "$(agent_notify_display_context "$long_tmux_label" '/tmp/project')" "$expected_long_tmux_label"
assert_equals "$(agent_notify_display_context '   ' '/')" 'Unknown project'
assert_equals "$(agent_notify_display_context '' '/tmp/   ')" 'Unknown project'

typeset deliveries_before_dropped_tmux=$deliveries
integer dropped_tmux_index=0
for tmux_session in '' "$oversized_tmux_session" 'c0-marker\u0001' 'del-marker\u007f'; do
  (( dropped_tmux_index++ ))
  print -rn -- "{\"source\":\"claude-code\",\"kind\":\"began\",\"session_id\":\"tmux-dropped-$dropped_tmux_index\",\"session_dir\":\"/tmp/project\"}" | AGENT_NOTIFY_NOW=$(( 1000 + dropped_tmux_index * 100 )) agent_notify_event
  print -rn -- "{\"source\":\"claude-code\",\"kind\":\"completed\",\"session_id\":\"tmux-dropped-$dropped_tmux_index\",\"session_dir\":\"/tmp/project\",\"tmux_session\":\"$tmux_session\"}" | AGENT_NOTIFY_NOW=$(( 1030 + dropped_tmux_index * 100 )) agent_notify_event
  assert_equals "$last_delivery_context" 'project'
  state_contents=$(<"$AGENT_NOTIFY_STATE_DIR/$(agent_notify_session_key claude-code "tmux-dropped-$dropped_tmux_index").state")
  [[ $state_contents != *tmux* ]] || { print -u2 -- 'a tmux session reached the session state file'; exit 1; }
done
assert_equals "$deliveries" "$(( deliveries_before_dropped_tmux + 4 ))"
[[ ! -e $AGENT_NOTIFY_DIAGNOSTIC_DIR ]] || { print -u2 -- 'a dropped tmux session wrote diagnostics'; exit 1; }

print -rn -- '{"source":"claude-code","kind":"began","session_id":"tmux-boundary-title","session_dir":"/tmp/project"}' | AGENT_NOTIFY_NOW=1500 agent_notify_event
print -rn -- "{\"source\":\"claude-code\",\"kind\":\"completed\",\"session_id\":\"tmux-boundary-title\",\"session_dir\":\"/tmp/project\",\"tmux_session\":\"$valid_tmux_session\"}" | AGENT_NOTIFY_NOW=1530 agent_notify_event
assert_equals "${#last_delivery_context}" 48
deliveries=$deliveries_before_dropped_tmux

send_event 100 began.json
send_event 129 completed.json
assert_equals "$deliveries" 0
send_event 200 began.json
send_event 231 completed.json
assert_equals "$deliveries" 1

typeset deliveries_before_tmux_titles=$deliveries
AGENT_NOTIFY_NOW=250 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"tmux-title","session_dir":"/tmp/project"}
EOF
AGENT_NOTIFY_NOW=290 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"completed","session_id":"tmux-title","session_dir":"/tmp/project","tmux_session":"team/api"}
EOF
assert_equals "$last_delivery_context" 'team_api'
AGENT_NOTIFY_NOW=300 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"tmux-invalid-title","session_dir":"/tmp/project"}
EOF
AGENT_NOTIFY_NOW=340 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"completed","session_id":"tmux-invalid-title","session_dir":"/tmp/project","tmux_session":"bad\nvalue"}
EOF
assert_equals "$last_delivery_context" 'project'
deliveries=$deliveries_before_tmux_titles

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

typeset stale_ownerless_lock="$AGENT_NOTIFY_STATE_DIR/stale-ownerless.lock"
/bin/mkdir "$stale_ownerless_lock"
/usr/bin/touch -t 197001010000 "$stale_ownerless_lock"
AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$stale_ownerless_lock" true || { print -u2 -- 'stale ownerless lock was not recovered'; exit 1; }
[[ ! -e $stale_ownerless_lock ]] || { print -u2 -- 'stale ownerless lock remained'; exit 1; }

typeset fresh_ownerless_lock="$AGENT_NOTIFY_STATE_DIR/fresh-ownerless.lock"
/bin/mkdir "$fresh_ownerless_lock"
if AGENT_NOTIFY_NOW=$(/bin/date +%s) agent_notify_try_mkdir_lock "$fresh_ownerless_lock" true; then
  print -u2 -- 'fresh ownerless lock was recovered'
  exit 1
fi
[[ -d $fresh_ownerless_lock ]] || { print -u2 -- 'fresh ownerless lock was removed'; exit 1; }
/bin/rm -rf "$fresh_ownerless_lock"

typeset stale_malformed_lock="$AGENT_NOTIFY_STATE_DIR/stale-malformed.lock"
/bin/mkdir "$stale_malformed_lock"
print -- 'not an owner record' > "$stale_malformed_lock/owner"
/usr/bin/touch -t 197001010000 "$stale_malformed_lock/owner" "$stale_malformed_lock"
AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$stale_malformed_lock" true || { print -u2 -- 'stale malformed lock was not recovered'; exit 1; }
[[ ! -e $stale_malformed_lock ]] || { print -u2 -- 'stale malformed lock remained'; exit 1; }

typeset fresh_malformed_lock="$AGENT_NOTIFY_STATE_DIR/fresh-malformed.lock"
/bin/mkdir "$fresh_malformed_lock"
print -- 'not an owner record' > "$fresh_malformed_lock/owner"
if AGENT_NOTIFY_NOW=$(/bin/date +%s) agent_notify_try_mkdir_lock "$fresh_malformed_lock" true; then
  print -u2 -- 'fresh malformed lock was recovered'
  exit 1
fi
[[ -d $fresh_malformed_lock ]] || { print -u2 -- 'fresh malformed lock was removed'; exit 1; }
/bin/rm -rf "$fresh_malformed_lock"

typeset gate_lock="$AGENT_NOTIFY_STATE_DIR/external-gate.lock" gate_path
/bin/mkdir "$gate_lock"
print -- '999999 0 stale-owner' > "$gate_lock/owner"
gate_path=$(agent_notify_external_gate_path "$gate_lock")
/bin/mkdir "$gate_path"
print -- "$$ 0 live-gate" > "$gate_path/reaper"
if AGENT_NOTIFY_NOW=100 agent_notify_recover_stale_lock "$gate_lock"; then
  print -u2 -- 'live external gate was reaped'
  exit 1
fi
[[ -d $gate_path ]] || { print -u2 -- 'live external gate was removed'; exit 1; }
/bin/rm -rf "$gate_path"
AGENT_NOTIFY_NOW=100 agent_notify_recover_stale_lock "$gate_lock" || true
[[ ! -e $gate_lock ]] || { print -u2 -- 'stale lock did not recover after gate removal'; exit 1; }

typeset publish_race_lock="$AGENT_NOTIFY_STATE_DIR/publish-race.lock" publish_race_gate publish_race_marker="$test_root/publish-race-callback" publish_race_once=0
publish_race_gate=$(agent_notify_external_gate_path "$publish_race_lock")
agent_notify_before_lock_owner_publish() {
  (( publish_race_once++ )) || {
    /bin/mkdir "$publish_race_gate"
    print -- '999999 0 stale-gate' > "$publish_race_gate/reaper"
  }
}
agent_notify_publish_race_callback() { print -- ran > "$publish_race_marker"; }
if AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$publish_race_lock" agent_notify_publish_race_callback; then
  print -u2 -- 'try ran through a post-mkdir fence'
  exit 1
fi
[[ ! -e $publish_race_lock && ! -e $publish_race_marker ]] || { print -u2 -- 'try left an ownerless lock through a fence'; exit 1; }
AGENT_NOTIFY_NOW=100 agent_notify_with_mkdir_lock "$publish_race_lock" agent_notify_publish_race_callback || { print -u2 -- 'with did not retry after a post-mkdir fence'; exit 1; }
[[ -e $publish_race_marker && ! -e $publish_race_lock ]] || { print -u2 -- 'with left an ownerless lock through a fence'; exit 1; }
agent_notify_before_lock_owner_publish() { :; }

typeset stale_gate_lock stale_gate_path gate_callback
for gate_case in dead ownerless malformed; do
  stale_gate_lock="$AGENT_NOTIFY_STATE_DIR/stale-gate-$gate_case.lock"
  gate_callback="$test_root/gate-callback-$gate_case"
  /bin/mkdir "$stale_gate_lock"
  print -- '999999 0 stale-owner' > "$stale_gate_lock/owner"
  stale_gate_path=$(agent_notify_external_gate_path "$stale_gate_lock")
  /bin/mkdir "$stale_gate_path"
  case $gate_case in
    dead) print -- '999998 0 stale-gate' > "$stale_gate_path/reaper" ;;
    malformed) print -- 'not a reaper token' > "$stale_gate_path/reaper" ;;
  esac
  /usr/bin/touch -t 197001010000 "$stale_gate_path" "$stale_gate_path/reaper"(N)
  agent_notify_gate_callback() { print -- ran > "$gate_callback"; }
  if AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$stale_gate_lock" agent_notify_gate_callback; then
    print -u2 -- 'try acquired through a stale gate fence'
    exit 1
  fi
  [[ ! -e $stale_gate_path && ! -e $gate_callback ]] || { print -u2 -- 'stale gate cleanup was not one-shot'; exit 1; }
  AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$stale_gate_lock" agent_notify_gate_callback || { print -u2 -- 'later try did not progress after gate cleanup'; exit 1; }
  [[ -e $gate_callback ]] || { print -u2 -- 'later try did not run callback'; exit 1; }
done

typeset competing_reaper_lock="$AGENT_NOTIFY_STATE_DIR/competing-reaper.lock" competing_reaper_gate competing_reaper_peer_gq competing_reaper_marker="$test_root/competing-reaper-callback"
/bin/mkdir "$competing_reaper_lock"
print -- '999999 0 stale-owner' > "$competing_reaper_lock/owner"
competing_reaper_gate=$(agent_notify_external_gate_path "$competing_reaper_lock")
/bin/mkdir "$competing_reaper_gate"
print -- '999998 0 stale-gate' > "$competing_reaper_gate/reaper"
competing_reaper_peer_gq="$AGENT_NOTIFY_STATE_DIR/.${competing_reaper_lock:t}.gate-quarantine.peer"
agent_notify_external_before_gate_move() {
  /bin/mkdir "$competing_reaper_peer_gq"
  print -- "$$ 100 peer-gate" > "$competing_reaper_peer_gq/reaper"
  /bin/mv "$2" "$competing_reaper_peer_gq/object"
}
agent_notify_competing_reaper_callback() { print -- ran > "$competing_reaper_marker"; }
if AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$competing_reaper_lock" agent_notify_competing_reaper_callback; then
  print -u2 -- 'competing gate reaper acquired a fenced lock'
  exit 1
fi
typeset -a competing_reaper_gqs
competing_reaper_gqs=("$AGENT_NOTIFY_STATE_DIR"/.${competing_reaper_lock:t}.gate-quarantine.*(N))
assert_equals "${#competing_reaper_gqs}" 1
[[ $competing_reaper_gqs[1] == "$competing_reaper_peer_gq" && -d "$competing_reaper_peer_gq/object" && -d $competing_reaper_lock ]] || { print -u2 -- 'competing gate reaper did not retain only the peer fence'; exit 1; }
if AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$competing_reaper_lock" agent_notify_competing_reaper_callback; then
  print -u2 -- 'competing gate fence allowed a later lock attempt'
  exit 1
fi
[[ ! -e $competing_reaper_marker && ! -e "$AGENT_NOTIFY_STATE_DIR"/.${competing_reaper_lock:t}.lock-quarantine.*(N) ]] || { print -u2 -- 'competing gate fence ran a callback or created a lock quarantine'; exit 1; }
agent_notify_external_before_gate_move() { :; }
/bin/rm -rf "$competing_reaper_lock" "$competing_reaper_gate" "$competing_reaper_peer_gq"

typeset gate_replacement_lock="$AGENT_NOTIFY_STATE_DIR/gate-replacement.lock" gate_replacement_gate gate_replacement_peer_gq gate_replacement_marker="$test_root/gate-replacement-callback"
/bin/mkdir "$gate_replacement_lock"
print -- '999999 0 stale-owner' > "$gate_replacement_lock/owner"
gate_replacement_gate=$(agent_notify_external_gate_path "$gate_replacement_lock")
gate_replacement_peer_gq="$AGENT_NOTIFY_STATE_DIR/.${gate_replacement_lock:t}.gate-quarantine.peer"
agent_notify_recovery_after_final_validation() {
  /bin/mkdir "$gate_replacement_peer_gq"
  print -- "$$ 100 peer-gate" > "$gate_replacement_peer_gq/reaper"
  /bin/mv "$2" "$gate_replacement_peer_gq/object"
  /bin/mkdir "$2"
  print -- "$$ 100 replacement-gate" > "$2/reaper"
}
agent_notify_gate_replacement_callback() { print -- ran > "$gate_replacement_marker"; }
if AGENT_NOTIFY_NOW=100 agent_notify_recover_stale_lock "$gate_replacement_lock"; then
  print -u2 -- 'gate replacement recovery succeeded'
  exit 1
fi
typeset -a gate_replacement_lqs
gate_replacement_lqs=("$AGENT_NOTIFY_STATE_DIR"/.${gate_replacement_lock:t}.lock-quarantine.*(N))
assert_equals "${#gate_replacement_lqs}" 1
[[ -d $gate_replacement_gate && -d "$gate_replacement_peer_gq/object" && -d "$gate_replacement_lqs[1]/object" ]] || { print -u2 -- 'gate replacement did not retain its fences'; exit 1; }
if AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$gate_replacement_lock" agent_notify_gate_replacement_callback || agent_notify_run_owned_lock "$gate_replacement_lock" 'superseded-token' agent_notify_gate_replacement_callback; then
  print -u2 -- 'gate replacement fence allowed a callback'
  exit 1
fi
[[ ! -e $gate_replacement_marker ]] || { print -u2 -- 'gate replacement callback ran through a fence'; exit 1; }
agent_notify_recovery_after_final_validation() { :; }
/bin/rm -rf "$gate_replacement_lock" "$gate_replacement_gate" "$gate_replacement_peer_gq" "${gate_replacement_lqs[@]}"

typeset lock_replacement_lock="$AGENT_NOTIFY_STATE_DIR/lock-replacement.lock" lock_replacement_gate lock_replacement_peer_lq lock_replacement_marker="$test_root/lock-replacement-callback"
/bin/mkdir "$lock_replacement_lock"
print -- '999999 0 stale-owner' > "$lock_replacement_lock/owner"
lock_replacement_gate=$(agent_notify_external_gate_path "$lock_replacement_lock")
lock_replacement_peer_lq="$AGENT_NOTIFY_STATE_DIR/.${lock_replacement_lock:t}.lock-quarantine.peer"
agent_notify_recovery_after_final_validation() {
  /bin/mkdir "$lock_replacement_peer_lq"
  print -- "$$ 100 peer-lock" > "$lock_replacement_peer_lq/reaper"
  /bin/mv "$1" "$lock_replacement_peer_lq/object"
  /bin/mkdir "$1"
  print -- "$$ 100 replacement-owner" > "$1/owner"
}
agent_notify_lock_replacement_callback() { print -- ran > "$lock_replacement_marker"; }
if AGENT_NOTIFY_NOW=100 agent_notify_recover_stale_lock "$lock_replacement_lock"; then
  print -u2 -- 'lock replacement recovery succeeded'
  exit 1
fi
typeset -a lock_replacement_lqs
lock_replacement_lqs=("$AGENT_NOTIFY_STATE_DIR"/.${lock_replacement_lock:t}.lock-quarantine.*(N))
assert_equals "${#lock_replacement_lqs}" 2
[[ -d $lock_replacement_gate &&
  -d "$lock_replacement_peer_lq/object" &&
  ( $(<"$lock_replacement_lqs[1]/object/owner") == "$$ 100 replacement-owner" ||
    $(<"$lock_replacement_lqs[2]/object/owner") == "$$ 100 replacement-owner" ) ]] || { print -u2 -- 'lock replacement did not retain both lock quarantines'; exit 1; }
if AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$lock_replacement_lock" agent_notify_lock_replacement_callback || agent_notify_run_owned_lock "$lock_replacement_lock" 'superseded-token' agent_notify_lock_replacement_callback; then
  print -u2 -- 'lock replacement fence allowed a callback'
  exit 1
fi
[[ ! -e $lock_replacement_marker ]] || { print -u2 -- 'lock replacement callback ran through a fence'; exit 1; }
agent_notify_recovery_after_final_validation() { :; }
/bin/rm -rf "$lock_replacement_lock" "$lock_replacement_gate" "$lock_replacement_peer_lq" "${lock_replacement_lqs[@]}"

typeset unreadable_gate_lock="$AGENT_NOTIFY_STATE_DIR/unreadable-gate.lock" unreadable_gate_path unreadable_gate_marker="$test_root/unreadable-gate-callback"
/bin/mkdir "$unreadable_gate_lock"
print -- '999999 0 stale-owner' > "$unreadable_gate_lock/owner"
unreadable_gate_path=$(agent_notify_external_gate_path "$unreadable_gate_lock")
/bin/mkdir "$unreadable_gate_path"
print -- '999998 0 stale-gate' > "$unreadable_gate_path/reaper"
/usr/bin/touch -t 197001010000 "$unreadable_gate_path" "$unreadable_gate_path/reaper"
/bin/chmod 000 "$unreadable_gate_path/reaper"
[[ ! -r $unreadable_gate_path/reaper ]] || { print -u2 -- 'mode 000 gate reaper remained readable'; exit 1; }
agent_notify_unreadable_gate_callback() { print -- ran > "$unreadable_gate_marker"; }
if AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$unreadable_gate_lock" agent_notify_unreadable_gate_callback; then
  print -u2 -- 'unreadable gate fence allowed an initial lock attempt'
  exit 1
fi
[[ ! -e $unreadable_gate_path && -d $unreadable_gate_lock && ! -e $unreadable_gate_marker ]] || { print -u2 -- 'unreadable gate cleanup was not isolated'; exit 1; }
AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$unreadable_gate_lock" agent_notify_unreadable_gate_callback || { print -u2 -- 'unreadable gate did not allow later recovery'; exit 1; }
[[ -e $unreadable_gate_marker && ! -e $unreadable_gate_lock ]] || { print -u2 -- 'unreadable gate recovery did not run once'; exit 1; }
/bin/chmod 600 "$unreadable_gate_path/reaper" 2>/dev/null || true
/bin/rm -rf "$unreadable_gate_lock" "$unreadable_gate_path"

typeset saved_fence_timeout_attempts=$AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS
AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS=1
typeset live_gq_lock="$AGENT_NOTIFY_STATE_DIR/live-gq-fence.lock" live_gq="$AGENT_NOTIFY_STATE_DIR/.live-gq-fence.lock.gate-quarantine.live" live_gq_marker="$test_root/live-gq-callback"
/bin/mkdir "$live_gq" "$live_gq/object"
print -- '999998 0 stale-outer' > "$live_gq/reaper"
print -- "$$ 100 live-gate" > "$live_gq/object/reaper"
agent_notify_live_gq_callback() { print -- ran >> "$live_gq_marker"; }
if AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$live_gq_lock" agent_notify_live_gq_callback || AGENT_NOTIFY_NOW=100 agent_notify_with_mkdir_lock "$live_gq_lock" agent_notify_live_gq_callback; then
  print -u2 -- 'live gate quarantine allowed a callback'
  exit 1
fi
[[ -d $live_gq && ! -e $live_gq_lock && ! -e $live_gq_marker ]] || { print -u2 -- 'live gate quarantine was not retained'; exit 1; }
/bin/rm -rf "$live_gq"
AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$live_gq_lock" agent_notify_live_gq_callback || { print -u2 -- 'removed gate quarantine did not allow progress'; exit 1; }
assert_equals "$(<"$live_gq_marker")" ran
[[ ! -e $live_gq_lock ]] || { print -u2 -- 'gate quarantine retry retained its lock'; exit 1; }

typeset live_lq_lock="$AGENT_NOTIFY_STATE_DIR/live-lq-fence.lock" live_lq="$AGENT_NOTIFY_STATE_DIR/.live-lq-fence.lock.lock-quarantine.live" live_lq_marker="$test_root/live-lq-callback"
/bin/mkdir "$live_lq" "$live_lq/object"
print -- '999998 0 stale-outer' > "$live_lq/reaper"
print -- "$$ 0 live-owner" > "$live_lq/object/owner"
agent_notify_live_lq_callback() { print -- ran >> "$live_lq_marker"; }
if AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$live_lq_lock" agent_notify_live_lq_callback || AGENT_NOTIFY_NOW=100 agent_notify_with_mkdir_lock "$live_lq_lock" agent_notify_live_lq_callback; then
  print -u2 -- 'live lock quarantine allowed a callback'
  exit 1
fi
[[ -d $live_lq && ! -e $live_lq_lock && ! -e $live_lq_marker ]] || { print -u2 -- 'live lock quarantine was not retained'; exit 1; }
/bin/rm -rf "$live_lq"
AGENT_NOTIFY_NOW=100 agent_notify_try_mkdir_lock "$live_lq_lock" agent_notify_live_lq_callback || { print -u2 -- 'removed lock quarantine did not allow progress'; exit 1; }
assert_equals "$(<"$live_lq_marker")" ran
[[ ! -e $live_lq_lock ]] || { print -u2 -- 'lock quarantine retry retained its lock'; exit 1; }
AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS=$saved_fence_timeout_attempts
agent_notify_external_before_gate_move() { :; }
agent_notify_recovery_after_final_validation() { :; }

typeset empty_container_lock="$AGENT_NOTIFY_STATE_DIR/empty-container.lock" empty_container
/bin/mkdir "$empty_container_lock"
print -- '999999 0 stale-owner' > "$empty_container_lock/owner"
agent_notify_external_reserve_container "$empty_container_lock" lock || { print -u2 -- 'empty container was not reserved'; exit 1; }
empty_container=$AGENT_NOTIFY_EXTERNAL_CONTAINER
agent_notify_external_remove_owned_empty_container "$empty_container" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_TOKEN" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_INODE" || { print -u2 -- 'owned empty container was not removed'; exit 1; }
[[ ! -e $empty_container ]] || { print -u2 -- 'owned empty container remained'; exit 1; }
agent_notify_external_reserve_container "$empty_container_lock" gate || { print -u2 -- 'stale empty container was not reserved'; exit 1; }
empty_container=$AGENT_NOTIFY_EXTERNAL_CONTAINER
print -- '999998 0 dead-container' > "$empty_container/reaper"
AGENT_NOTIFY_NOW=100 agent_notify_external_cleanup_one_fence "$empty_container_lock" || { print -u2 -- 'stale empty container was not reclaimed'; exit 1; }
[[ ! -e $empty_container ]] || { print -u2 -- 'stale empty container remained'; exit 1; }
/bin/rm -rf "$empty_container_lock"

typeset outside_lock="$test_root/outside.lock" traversal_lock="$AGENT_NOTIFY_STATE_DIR/../${AGENT_NOTIFY_STATE_DIR:t}/traversal.lock" dot_parent_lock="$AGENT_NOTIFY_STATE_DIR/./dot-parent.lock" unsafe_basename_lock="$AGENT_NOTIFY_STATE_DIR/.lock" symlink_lock="$AGENT_NOTIFY_STATE_DIR/symlink.lock"
/bin/ln -s "$outside_lock" "$symlink_lock"
for unsafe_lock in "$outside_lock" "$traversal_lock" "$dot_parent_lock" "$unsafe_basename_lock" "$symlink_lock"; do
  if agent_notify_try_mkdir_lock "$unsafe_lock" true; then
    print -u2 -- 'unsafe lock path was accepted'
    exit 1
  fi
done
[[ ! -e $outside_lock && ! -e $dot_parent_lock && ! -e $unsafe_basename_lock && -L $symlink_lock ]] || { print -u2 -- 'unsafe lock path was mutated'; exit 1; }
/bin/rm -f "$symlink_lock"
typeset state_source
state_source=$(<"$root/lib/agent-notify/state.zsh")
[[ $state_source != *uuidgen* ]] || { print -u2 -- 'state locking still invokes uuidgen'; exit 1; }
typeset -A state_function_counts
typeset state_source_line state_function_name
while IFS= read -r state_source_line; do
  [[ $state_source_line =~ '^(agent_notify_[[:alnum:]_]+)\(\)' ]] || continue
  state_function_name=$match[1]
  (( ++state_function_counts[$state_function_name] == 1 )) || { print -u2 -- "duplicate notifier function: $state_function_name"; exit 1; }
done <<< "$state_source"
[[ $state_source != *'/recovery'* ]] || { print -u2 -- 'obsolete nested recovery protocol remains'; exit 1; }

typeset replacement_lock="$AGENT_NOTIFY_STATE_DIR/replacement.lock" replacement_marker="$test_root/replacement-callback"
agent_notify_replacement_callback() { print -- invoked > "$replacement_marker"; }
/bin/mkdir "$replacement_lock"
print -- "$$ 100 original-token" > "$replacement_lock/owner"
print -- "$$ 100 replacement-token" > "$replacement_lock/owner"
if agent_notify_run_owned_lock "$replacement_lock" "$$ 100 original-token" agent_notify_replacement_callback; then
  print -u2 -- 'replacement owner ran a superseded callback'
  exit 1
fi
[[ ! -e $replacement_marker && -d $replacement_lock ]] || { print -u2 -- 'replacement ownership was not protected'; exit 1; }
/bin/rm -rf "$replacement_lock"

typeset callback_failure_lock="$AGENT_NOTIFY_STATE_DIR/callback-failure.lock" callback_result
agent_notify_failing_callback() { return 7; }
if agent_notify_try_mkdir_lock "$callback_failure_lock" agent_notify_failing_callback; then
  callback_result=0
else
  callback_result=$?
fi
assert_equals "$callback_result" 7
[[ ! -e $callback_failure_lock ]] || { print -u2 -- 'nonzero callback left its lock behind'; exit 1; }

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

typeset prune_marker global_prune_lock
prune_marker=$(agent_notify_prune_marker_path)
/bin/rm -f "$prune_marker"
global_prune_lock="$AGENT_NOTIFY_STATE_DIR/.prune.lock"
/bin/mkdir "$global_prune_lock"
print -- "$$ 0 global-prune" > "$global_prune_lock/owner"
AGENT_NOTIFY_NOW=1000000 agent_notify_prune_state_if_due || true
[[ -d $global_prune_lock && ! -e $prune_marker ]] || { print -u2 -- 'contended global prune lock was not skipped'; exit 1; }
/bin/rm -rf "$global_prune_lock"

typeset saved_state_dir=$AGENT_NOTIFY_STATE_DIR saved_prune_batch_size=$AGENT_NOTIFY_PRUNE_BATCH_SIZE
AGENT_NOTIFY_STATE_DIR="$test_root/prune-batch-state"
AGENT_NOTIFY_PRUNE_BATCH_SIZE=64
agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR"
for batch_index in {1..65}; do
  STATE_ACTIVE=0 STATE_STARTED_AT=0 STATE_ATTENTIONS='' STATE_LAST_ATTENTION_AT=0 STATE_TERMINAL=completed STATE_UPDATED_AT=0
  agent_notify_save_state "$AGENT_NOTIFY_STATE_DIR/batch-$batch_index.state"
done
AGENT_NOTIFY_NOW=1000000 agent_notify_prune_state_if_due || { print -u2 -- 'bounded prune pass failed'; exit 1; }
typeset -a batch_states
batch_states=("$AGENT_NOTIFY_STATE_DIR"/*.state(N))
assert_equals "${#batch_states}" 1
[[ $(/usr/bin/stat -f '%Lp' "$(agent_notify_prune_marker_path)") == 600 ]] || { print -u2 -- 'prune marker is not user-only'; exit 1; }
AGENT_NOTIFY_NOW=1000000 agent_notify_prune_state_if_due || { print -u2 -- 'frequency-gated prune failed'; exit 1; }
batch_states=("$AGENT_NOTIFY_STATE_DIR"/*.state(N))
assert_equals "${#batch_states}" 1
AGENT_NOTIFY_STATE_DIR=$saved_state_dir
AGENT_NOTIFY_PRUNE_BATCH_SIZE=$saved_prune_batch_size

typeset cursor_prune_state_dir="$test_root/cursor-prune-state" cursor_late_state
AGENT_NOTIFY_STATE_DIR=$cursor_prune_state_dir
AGENT_NOTIFY_PRUNE_BATCH_SIZE=64
agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR"
for cursor_index in {1..64}; do
  STATE_ACTIVE=0 STATE_STARTED_AT=0 STATE_ATTENTIONS='' STATE_LAST_ATTENTION_AT=0 STATE_TERMINAL=completed STATE_UPDATED_AT=1000000
  agent_notify_save_state "$AGENT_NOTIFY_STATE_DIR/locked-$cursor_index.state"
  /usr/bin/touch -t 197001010000 "$AGENT_NOTIFY_STATE_DIR/locked-$cursor_index.state"
  /bin/mkdir "$AGENT_NOTIFY_STATE_DIR/locked-$cursor_index.lock"
  print -- "$$ 0 live-cursor-$cursor_index" > "$AGENT_NOTIFY_STATE_DIR/locked-$cursor_index.lock/owner"
done
cursor_late_state="$AGENT_NOTIFY_STATE_DIR/late-expired.state"
STATE_ACTIVE=0 STATE_STARTED_AT=0 STATE_ATTENTIONS='' STATE_LAST_ATTENTION_AT=0 STATE_TERMINAL=completed STATE_UPDATED_AT=0
agent_notify_save_state "$cursor_late_state"
/usr/bin/touch -t 197101010000 "$cursor_late_state"
AGENT_NOTIFY_NOW=1000000 agent_notify_prune_state_if_due || { print -u2 -- 'cursor prune first pass failed'; exit 1; }
[[ -f $cursor_late_state ]] || { print -u2 -- 'cursor prune skipped the later stale state too early'; exit 1; }
AGENT_NOTIFY_NOW=1000000 agent_notify_prune_state_forced || { print -u2 -- 'cursor prune second pass failed'; exit 1; }
[[ ! -e $cursor_late_state ]] || { print -u2 -- 'cursor prune starved the later stale state'; exit 1; }
[[ $(/usr/bin/stat -f '%Lp' "$(agent_notify_prune_cursor_path)") == 600 && $(/usr/bin/stat -f '%Lp' "$(agent_notify_prune_marker_path)") == 600 ]] || { print -u2 -- 'prune cursor or marker is not user-only'; exit 1; }
AGENT_NOTIFY_STATE_DIR=$saved_state_dir
AGENT_NOTIFY_PRUNE_BATCH_SIZE=$saved_prune_batch_size

typeset oldest_prune_state_dir="$test_root/oldest-prune-state" oldest_stale_state
AGENT_NOTIFY_STATE_DIR=$oldest_prune_state_dir
AGENT_NOTIFY_PRUNE_BATCH_SIZE=64
agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR"
for oldest_index in {1..64}; do
  STATE_ACTIVE=0 STATE_STARTED_AT=0 STATE_ATTENTIONS='' STATE_LAST_ATTENTION_AT=0 STATE_TERMINAL=completed STATE_UPDATED_AT=1000000
  agent_notify_save_state "$AGENT_NOTIFY_STATE_DIR/early-retained-$oldest_index.state"
done
oldest_stale_state="$AGENT_NOTIFY_STATE_DIR/late-stale.state"
STATE_ACTIVE=0 STATE_STARTED_AT=0 STATE_ATTENTIONS='' STATE_LAST_ATTENTION_AT=0 STATE_TERMINAL=completed STATE_UPDATED_AT=0
agent_notify_save_state "$oldest_stale_state"
/usr/bin/touch -t 197001010000 "$oldest_stale_state"
AGENT_NOTIFY_NOW=1000000 agent_notify_prune_state_forced || { print -u2 -- 'oldest-first prune pass failed'; exit 1; }
[[ ! -e $oldest_stale_state && -f $AGENT_NOTIFY_STATE_DIR/early-retained-1.state ]] || { print -u2 -- 'retained early states starved the oldest stale state'; exit 1; }
AGENT_NOTIFY_STATE_DIR=$saved_state_dir
AGENT_NOTIFY_PRUNE_BATCH_SIZE=$saved_prune_batch_size

typeset event_before_prune_dir="$test_root/event-before-prune-state" event_before_prune_key event_before_prune_marker
AGENT_NOTIFY_STATE_DIR=$event_before_prune_dir
event_before_prune_key=$(agent_notify_session_key claude-code event-before-prune)
event_before_prune_marker="$test_root/event-before-prune-marker"
agent_notify_prune_state_if_due() {
  if [[ -f $AGENT_NOTIFY_STATE_DIR/$event_before_prune_key.state ]]; then
    print -- after-event > "$event_before_prune_marker"
  else
    print -- before-event > "$event_before_prune_marker"
  fi
}
AGENT_NOTIFY_NOW=1000000 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"event-before-prune","session_dir":"/tmp/event-before-prune"}
EOF
assert_equals "$(<"$event_before_prune_marker")" after-event
source "$root/lib/agent-notify/state.zsh"
AGENT_NOTIFY_STATE_DIR=$saved_state_dir

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
  /bin/sleep 1
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
  /bin/sleep 1
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

typeset blocking_state_dir="$test_root/blocking-delivery-state" blocking_key blocking_started="$test_root/blocking-delivery-started" blocking_calls="$test_root/blocking-delivery-calls"
AGENT_NOTIFY_STATE_DIR=$blocking_state_dir
agent_notify_deliver() {
  print -- call >> "$blocking_calls"
  : > "$blocking_started"
  /bin/sleep 2
}
AGENT_NOTIFY_NOW=2000 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"blocking-delivery","session_dir":"/tmp/blocking-delivery"}
EOF
blocking_key=$(agent_notify_session_key claude-code blocking-delivery)
(
  AGENT_NOTIFY_NOW=2031 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"completed","session_id":"blocking-delivery","session_dir":"/tmp/blocking-delivery"}
EOF
) &
typeset blocking_pid=$!
for _ in {1..40}; do
  [[ -e $blocking_started ]] && break
  /bin/sleep 0.05
done
[[ -e $blocking_started ]] || { print -u2 -- 'blocking delivery did not start'; exit 1; }
[[ ! -e $AGENT_NOTIFY_STATE_DIR/$blocking_key.lock ]] || { print -u2 -- 'session lock remained held during delivery'; exit 1; }
AGENT_NOTIFY_NOW=2031 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"completed","session_id":"blocking-delivery","session_dir":"/tmp/blocking-delivery"}
EOF
wait "$blocking_pid"
typeset -a blocking_call_lines
blocking_call_lines=("${(f)$(<"$blocking_calls")}")
assert_equals "${#blocking_call_lines}" 1
AGENT_NOTIFY_STATE_DIR=$saved_state_dir

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

AGENT_NOTIFY_EXPECTED_TITLE='Claude Code — delivery-project'
AGENT_NOTIFY_EXPECTED_PRIORITY=0
AGENT_NOTIFY_EXPECTED_MESSAGE='Turn complete — Reticulated 41 splines.'
agent_notify_deliver completed claude-code delivery-project 'Reticulated 41 splines.' || { print -u2 -- 'completion excerpt was not composed after the state message'; exit 1; }
AGENT_NOTIFY_EXPECTED_MESSAGE='Agent error — rate_limit'
agent_notify_deliver failed claude-code delivery-project 'rate_limit' || { print -u2 -- 'failure excerpt was not composed after the state message'; exit 1; }
AGENT_NOTIFY_EXPECTED_MESSAGE='Attention required'
agent_notify_deliver attention claude-code delivery-project 'must not reach an attention message' || { print -u2 -- 'attention message was not left unchanged'; exit 1; }
# A sanitization escape must cost only the excerpt: curl refuses to quote a line break.
AGENT_NOTIFY_EXPECTED_MESSAGE='Turn complete'
agent_notify_deliver completed claude-code delivery-project $'escaped\nexcerpt' || { print -u2 -- 'an unquotable excerpt cost the whole notification'; exit 1; }

typeset delivered_message_file="$test_root/delivered-message" delivered_message
agent_notify_curl_request() {
  local request_config
  request_config=$(/bin/cat)
  print -r -- "$request_config" | /usr/bin/grep '^data-urlencode = "message=' > "$delivered_message_file" || true
  print -rn -- $'{"status":1,"request":"end-to-end"}\nAGENT_NOTIFY_META:200:{}'
}
delivered_message_for() {
  local now=$1 payload=$2 captured
  : > "$delivered_message_file"
  print -rn -- "$payload" | AGENT_NOTIFY_NOW=$now agent_notify_event
  captured=$(<"$delivered_message_file")
  captured=${captured#'data-urlencode = "message='}
  print -r -- "${captured%\"}"
}

# A five-field event predates excerpts entirely and must still deliver the original message.
AGENT_NOTIFY_NOW=800 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"excerpt-absent","session_dir":"/tmp/excerpt-project"}
EOF
assert_equals "$(delivered_message_for 840 '{"source":"claude-code","kind":"completed","session_id":"excerpt-absent","session_dir":"/tmp/excerpt-project"}')" 'Turn complete'

AGENT_NOTIFY_NOW=800 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"excerpt-present","session_dir":"/tmp/excerpt-project"}
EOF
assert_equals "$(delivered_message_for 840 '{"source":"claude-code","kind":"completed","session_id":"excerpt-present","session_dir":"/tmp/excerpt-project","excerpt":"Reticulated 41 splines."}')" 'Turn complete — Reticulated 41 splines.'

# An invalid excerpt is dropped by itself; the event that carried it still reaches delivery.
AGENT_NOTIFY_NOW=800 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"excerpt-invalid","session_dir":"/tmp/excerpt-project"}
EOF
assert_equals "$(delivered_message_for 840 '{"source":"claude-code","kind":"completed","session_id":"excerpt-invalid","session_dir":"/tmp/excerpt-project","excerpt":"line\nbreak"}')" 'Turn complete'
AGENT_NOTIFY_NOW=800 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"excerpt-oversized","session_dir":"/tmp/excerpt-project"}
EOF
typeset oversized_excerpt
oversized_excerpt=$(/usr/bin/printf 'x%.0s' {1..300})
assert_equals "$(delivered_message_for 840 "{\"source\":\"claude-code\",\"kind\":\"completed\",\"session_id\":\"excerpt-oversized\",\"session_dir\":\"/tmp/excerpt-project\",\"excerpt\":\"$oversized_excerpt\"}")" 'Turn complete'

assert_equals "$(delivered_message_for 850 '{"source":"opencode","kind":"failed","session_id":"excerpt-failed","session_dir":"/tmp/excerpt-project","excerpt":"ProviderAuthError"}')" 'Agent error — ProviderAuthError'
assert_equals "$(delivered_message_for 860 '{"source":"opencode","kind":"attention","session_id":"excerpt-attention","session_dir":"/tmp/excerpt-project","request_id":"request-x","excerpt":"must not reach an attention message"}')" 'Attention required'

typeset excerpt_state_key excerpt_state_contents
excerpt_state_key=$(agent_notify_session_key claude-code excerpt-present)
excerpt_state_contents=$(<"$AGENT_NOTIFY_STATE_DIR/$excerpt_state_key.state")
[[ $excerpt_state_contents != *Reticulated* ]] || { print -u2 -- 'an excerpt reached the session state file'; exit 1; }

# Delivery failure must record no excerpt or tmux-session text, in state or diagnostics.
agent_notify_curl_request() {
  while IFS= read -r _; do :; done
  print -rn -- $'{"status":0,"request":"excerpt-failure"}\nAGENT_NOTIFY_META:503:{}'
}
AGENT_NOTIFY_NOW=900 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"began","session_id":"excerpt-failed-delivery","session_dir":"/tmp/excerpt-project"}
EOF
AGENT_NOTIFY_NOW=940 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"completed","session_id":"excerpt-failed-delivery","session_dir":"/tmp/excerpt-project","excerpt":"Diagnosticmarker excerpt text","tmux_session":"Acceptedtmuxmarker"}
EOF
AGENT_NOTIFY_NOW=950 agent_notify_event <<'EOF'
{"source":"claude-code","kind":"failed","session_id":"rejected-tmux-failed-delivery","session_dir":"/tmp/excerpt-project","tmux_session":"Rejectedtmuxmarker\u0001"}
EOF
typeset excerpt_diagnostics
excerpt_diagnostics=$(/bin/cat "$AGENT_NOTIFY_DIAGNOSTIC_DIR"/*.log(N))
[[ $excerpt_diagnostics != *Diagnosticmarker* ]] || { print -u2 -- 'a failed delivery recorded excerpt text in diagnostics'; exit 1; }
[[ $excerpt_diagnostics != *Acceptedtmuxmarker* && $excerpt_diagnostics != *Rejectedtmuxmarker* ]] || { print -u2 -- 'a failed delivery recorded tmux context in diagnostics'; exit 1; }
typeset failed_delivery_state
failed_delivery_state=$(<"$AGENT_NOTIFY_STATE_DIR/$(agent_notify_session_key claude-code excerpt-failed-delivery).state")
[[ $failed_delivery_state != *Diagnosticmarker* ]] || { print -u2 -- 'a failed delivery recorded excerpt text in session state'; exit 1; }
[[ $failed_delivery_state != *Acceptedtmuxmarker* ]] || { print -u2 -- 'a failed delivery recorded tmux context in session state'; exit 1; }
failed_delivery_state=$(<"$AGENT_NOTIFY_STATE_DIR/$(agent_notify_session_key claude-code rejected-tmux-failed-delivery).state")
[[ $failed_delivery_state != *Rejectedtmuxmarker* ]] || { print -u2 -- 'a failed delivery recorded rejected tmux context in session state'; exit 1; }

typeset curl_config hostile_home="$test_root/hostile-home"
curl_config=$(agent_notify_curl_config userkey012345678901234567890123 apptoken01234567890123456789012 'Claude Code — project' 'Attention required' 0)
[[ $curl_config != *'location'* && $curl_config == *'max-redirs = 0'* && $curl_config == *'proto = "=https"'* ]] || { print -u2 -- 'curl redirect or protocol policy is missing'; exit 1; }
# A code-bearing excerpt would be parsed as markup or rejected if Pushover rendered the message.
[[ $curl_config != *html* ]] || { print -u2 -- 'the Pushover request enabled html rendering'; exit 1; }
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
