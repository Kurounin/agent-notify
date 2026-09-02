agent_notify_process_normalized() {
  local normalized_json=$1
  local source kind session_id session_dir request_id excerpt state_key lock_path delivery_kind project

  agent_notify_event_fields "$normalized_json" || return 1
  source=$AGENT_NOTIFY_EVENT_FIELDS[1]
  kind=$AGENT_NOTIFY_EVENT_FIELDS[2]
  session_id=$AGENT_NOTIFY_EVENT_FIELDS[3]
  session_dir=$AGENT_NOTIFY_EVENT_FIELDS[4]
  request_id=$AGENT_NOTIFY_EVENT_FIELDS[5]
  excerpt=${AGENT_NOTIFY_EVENT_FIELDS[6]:-}
  state_key=$(agent_notify_session_key "$source" "$session_id") || return 1
  lock_path="$AGENT_NOTIFY_STATE_DIR/$state_key.lock"

  REPLY=''
  agent_notify_with_mkdir_lock "$lock_path" agent_notify_transition "$state_key" "$source" "$kind" "$session_dir" "$request_id" "$excerpt" || return 1
  delivery_kind=$REPLY
  if [[ -n $delivery_kind ]]; then
    project=$(agent_notify_project_name "$session_dir")
    agent_notify_deliver "$delivery_kind" "$source" "$project" "$excerpt" || true
  fi
}

agent_notify_event() {
  local raw normalized
  raw=$(/bin/cat) || return 0
  normalized=$(agent_notify_normalize_json "$raw") || {
    agent_notify_diag normalize invalid_event 0 -
    return 0
  }
  agent_notify_process_normalized "$normalized" || agent_notify_diag state processing_failed 0 -
  agent_notify_prune_state_if_due || true
  return 0
}
