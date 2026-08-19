agent_notify_now() {
  if [[ -n ${AGENT_NOTIFY_NOW:-} ]]; then
    print -r -- "$AGENT_NOTIFY_NOW"
  else
    /bin/date +%s
  fi
}

agent_notify_prepare_directory() {
  local directory=$1
  (umask 077; /bin/mkdir -p "$directory") || return 1
  /bin/chmod 700 "$directory"
}

agent_notify_session_key() {
  local source=$1 session_id=$2 digest
  digest=$(print -rn -- "$source\0$session_id" | /usr/bin/shasum -a 256) || return 1
  print -r -- "${digest%% *}"
}

agent_notify_request_key() {
  local digest
  digest=$(print -rn -- "$1" | /usr/bin/shasum -a 256) || return 1
  print -r -- "${digest%% *}"
}

agent_notify_validate_attentions() {
  local entry request_key request_time delivered remainder
  [[ -z $1 ]] && return 0
  for entry in ${(s:,:)1}; do
    request_key=${entry%%:*}
    remainder=${entry#*:}
    request_time=${remainder%%:*}
    delivered=${remainder##*:}
    [[ $request_key =~ '^[[:xdigit:]]{64}$' && $request_time =~ '^[0-9]+$' && ( $delivered == 0 || $delivered == 1 ) ]] || return 1
  done
}

agent_notify_load_state() {
  local state_path=$1 key value
  STATE_ACTIVE=0 STATE_STARTED_AT=0 STATE_ATTENTIONS='' STATE_LAST_ATTENTION_AT=0 STATE_TERMINAL='' STATE_UPDATED_AT=0
  [[ -f $state_path ]] || return 0
  while IFS='=' read -r key value; do
    case $key in
      ACTIVE|STARTED_AT|ATTENTIONS|LAST_ATTENTION_AT|TERMINAL|UPDATED_AT) ;;
      *) return 1 ;;
    esac
    case $key in
      ACTIVE) [[ $value == 0 || $value == 1 ]] || return 1; STATE_ACTIVE=$value ;;
      STARTED_AT|LAST_ATTENTION_AT|UPDATED_AT) [[ $value =~ '^[0-9]+$' ]] || return 1; typeset -g "STATE_$key=$value" ;;
      ATTENTIONS) agent_notify_validate_attentions "$value" || return 1; STATE_ATTENTIONS=$value ;;
      TERMINAL) [[ -z $value || $value == completed || $value == failed ]] || return 1; STATE_TERMINAL=$value ;;
    esac
  done < "$state_path"
}

agent_notify_save_state() {
  local state_path=$1 temporary
  temporary="${state_path}.$$.tmp"
  ( umask 077
    {
      print -- "ACTIVE=$STATE_ACTIVE"
      print -- "STARTED_AT=$STATE_STARTED_AT"
      print -- "ATTENTIONS=$STATE_ATTENTIONS"
      print -- "LAST_ATTENTION_AT=$STATE_LAST_ATTENTION_AT"
      print -- "TERMINAL=$STATE_TERMINAL"
      print -- "UPDATED_AT=$STATE_UPDATED_AT"
    } > "$temporary"
  ) || return 1
  /bin/chmod 600 "$temporary" && /bin/mv -f "$temporary" "$state_path"
}

agent_notify_remove_lock() {
  local lock_path=$1
  [[ $lock_path == "$AGENT_NOTIFY_STATE_DIR/"*.lock ]] || return 1
  /bin/rm -rf "$lock_path"
}

agent_notify_recover_stale_lock() {
  local lock_path=$1 owner_path="$1/owner" owner_pid owner_started now
  [[ -r $owner_path ]] || return 1
  IFS=' ' read -r owner_pid owner_started < "$owner_path" || return 1
  [[ $owner_pid =~ '^[0-9]+$' && $owner_started =~ '^[0-9]+$' ]] || return 1
  now=$(agent_notify_now)
  (( now - owner_started >= AGENT_NOTIFY_LOCK_STALE_SECONDS )) || return 1
  /bin/kill -0 "$owner_pid" 2>/dev/null && return 1
  agent_notify_remove_lock "$lock_path"
}

agent_notify_with_mkdir_lock() {
  local lock_path=$1 callback=$2 attempt=0 now
  shift 2
  agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR" || return 1
  while ! (umask 077; /bin/mkdir "$lock_path") 2>/dev/null; do
    agent_notify_recover_stale_lock "$lock_path" && continue
    (( attempt++ >= AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS )) && return 1
    /bin/sleep 0.05
  done
  now=$(agent_notify_now)
  (umask 077; print -- "$$ $now" > "$lock_path/owner") || { agent_notify_remove_lock "$lock_path"; return 1; }
  "$callback" "$@"
  local result=$?
  agent_notify_remove_lock "$lock_path" || true
  return $result
}

agent_notify_attention_status() {
  local target=$1 entry
  REPLY=missing
  for entry in ${(s:,:)STATE_ATTENTIONS}; do
    [[ ${entry%%:*} == "$target" ]] || continue
    REPLY=${entry##*:}
    return 0
  done
}

agent_notify_add_attention() {
  local request_key=$1 now=$2
  agent_notify_attention_status "$request_key"
  [[ $REPLY == missing ]] || return 0
  STATE_ATTENTIONS+="${STATE_ATTENTIONS:+,}${request_key}:$now:0"
}

agent_notify_mark_attention_delivered() {
  local target=$1 entry kept='' request_key
  for entry in ${(s:,:)STATE_ATTENTIONS}; do
    request_key=${entry%%:*}
    [[ $request_key == "$target" ]] && entry="${entry%:*}:1"
    kept+="${kept:+,}$entry"
  done
  STATE_ATTENTIONS=$kept
}

agent_notify_clear_attention() {
  local target=$1 entry kept=''
  for entry in ${(s:,:)STATE_ATTENTIONS}; do
    [[ ${entry%%:*} == "$target" ]] && continue
    kept+="${kept:+,}$entry"
  done
  STATE_ATTENTIONS=$kept
  [[ -n $STATE_ATTENTIONS ]] || STATE_LAST_ATTENTION_AT=0
}

agent_notify_project_name() {
  local directory=${1%/} project
  project=${directory##*/}
  project=${project//[^[:alnum:].\ _()-]/_}
  project=${project[1,48]}
  [[ -n $project ]] || project='Unknown project'
  print -r -- "$project"
}

agent_notify_transition() {
  local state_key=$1 source=$2 kind=$3 session_dir=$4 request_id=$5
  local now state_path request_key runtime deliver_kind='' project
  now=$(agent_notify_now)
  state_path="$AGENT_NOTIFY_STATE_DIR/$state_key.state"
  agent_notify_load_state "$state_path" || {
    agent_notify_diag state invalid_record 0 -
    /bin/rm -f "$state_path"
    agent_notify_load_state "$state_path" || return 1
  }

  case $kind in
    began)
      STATE_ACTIVE=1
      STATE_STARTED_AT=$now
      STATE_ATTENTIONS=''
      STATE_LAST_ATTENTION_AT=0
      STATE_TERMINAL=''
      ;;
    attention)
      request_key=$(agent_notify_request_key "$request_id") || return 1
      agent_notify_add_attention "$request_key" "$now"
      agent_notify_attention_status "$request_key"
      if [[ $REPLY == 0 ]] && (( STATE_LAST_ATTENTION_AT == 0 || now - STATE_LAST_ATTENTION_AT >= AGENT_NOTIFY_ATTENTION_DEBOUNCE_SECONDS )); then
        deliver_kind=attention
        STATE_LAST_ATTENTION_AT=$now
        agent_notify_mark_attention_delivered "$request_key"
      fi
      ;;
    attention-cleared)
      request_key=$(agent_notify_request_key "$request_id") || return 1
      agent_notify_clear_attention "$request_key"
      ;;
    completed)
      if (( STATE_ACTIVE == 1 )) && [[ -z $STATE_TERMINAL ]]; then
        runtime=$(( now - STATE_STARTED_AT ))
        STATE_ACTIVE=0
        STATE_ATTENTIONS=''
        STATE_LAST_ATTENTION_AT=0
        STATE_TERMINAL=completed
        (( runtime >= AGENT_NOTIFY_MIN_RUNTIME_SECONDS )) && deliver_kind=completed
      fi
      ;;
    failed)
      if [[ -z $STATE_TERMINAL ]]; then
        STATE_ACTIVE=0
        STATE_ATTENTIONS=''
        STATE_LAST_ATTENTION_AT=0
        STATE_TERMINAL=failed
        deliver_kind=failed
      fi
      ;;
    reset)
      /bin/rm -f "$state_path"
      return 0
      ;;
    *) return 1 ;;
  esac

  STATE_UPDATED_AT=$now
  agent_notify_save_state "$state_path" || return 1
  if [[ -n $deliver_kind ]]; then
    project=$(agent_notify_project_name "$session_dir")
    agent_notify_deliver "$deliver_kind" "$source" "$project" || true
  fi
}

agent_notify_prune_one_state() {
  local state_path=$1 now=$2 active updated started
  agent_notify_load_state "$state_path" || { /bin/rm -f "$state_path"; return 0; }
  active=$STATE_ACTIVE updated=$STATE_UPDATED_AT started=$STATE_STARTED_AT
  if (( active == 1 )); then
    (( now - started > AGENT_NOTIFY_MAX_ACTIVE_SECONDS )) && /bin/rm -f "$state_path"
  elif (( now - updated > AGENT_NOTIFY_RETENTION_SECONDS )); then
    /bin/rm -f "$state_path"
  fi
}

agent_notify_prune_state_locked() {
  local now state_path state_lock
  now=$(agent_notify_now)
  for state_path in "$AGENT_NOTIFY_STATE_DIR"/*.state(N); do
    state_lock="${state_path%.state}.lock"
    agent_notify_with_mkdir_lock "$state_lock" agent_notify_prune_one_state "$state_path" "$now" || true
  done
}

agent_notify_prune_state() {
  agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR" || return 1
  agent_notify_with_mkdir_lock "$AGENT_NOTIFY_STATE_DIR/.prune.lock" agent_notify_prune_state_locked
}
