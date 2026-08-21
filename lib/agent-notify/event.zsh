agent_notify_process_normalized() {
  local normalized_json=$1
  local source kind session_id session_dir request_id excerpt state_key lock_path

  agent_notify_event_fields "$normalized_json" || return 1
  source=$AGENT_NOTIFY_EVENT_FIELDS[1]
  kind=$AGENT_NOTIFY_EVENT_FIELDS[2]
  session_id=$AGENT_NOTIFY_EVENT_FIELDS[3]
  session_dir=$AGENT_NOTIFY_EVENT_FIELDS[4]
  request_id=$AGENT_NOTIFY_EVENT_FIELDS[5]
  excerpt=${AGENT_NOTIFY_EVENT_FIELDS[6]:-}
  state_key=$(agent_notify_session_key "$source" "$session_id") || return 1
  lock_path="$AGENT_NOTIFY_STATE_DIR/$state_key.lock"

  agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR" || return 1
  if [[ ${AGENT_NOTIFY_LOCKED_PROCESS:-0} != 1 && -x $AGENT_NOTIFY_FLOCK_BIN ]]; then
    print -rn -- "$normalized_json" | "$AGENT_NOTIFY_FLOCK_BIN" -x "$lock_path" "$0" __locked
    return $?
  fi
  agent_notify_with_mkdir_lock "$lock_path" agent_notify_transition "$state_key" "$source" "$kind" "$session_dir" "$request_id" "$excerpt"
}

agent_notify_event() {
  local raw normalized
  raw=$(/bin/cat) || return 0
  normalized=$(agent_notify_normalize_json "$raw") || {
    agent_notify_diag normalize invalid_event 0 -
    return 0
  }
  agent_notify_prune_state || true
  agent_notify_process_normalized "$normalized" || agent_notify_diag state processing_failed 0 -
  return 0
}
