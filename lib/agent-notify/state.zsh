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

agent_notify_lock_path_is_safe() {
  local lock_path=$1 parent basename state_directory
  [[ -n $lock_path && $lock_path != */../* && $lock_path != ../* && $lock_path != */.. && $lock_path != */./* && ! -L $lock_path ]] || return 1
  parent=${lock_path:h}
  basename=${lock_path:t}
  state_directory=${AGENT_NOTIFY_STATE_DIR:A}
  [[ ${parent:A} == "$state_directory" ]] || return 1
  [[ $basename =~ '^(\.?[[:alnum:]][[:alnum:]_.-]*)\.lock$' ]] || return 1
}

agent_notify_lock_nonce() {
  local now=$1
  print -r -- "p$$-t$now-r$RANDOM-$RANDOM"
}

agent_notify_lock_owned() {
  local lock_path=$1 token=$2 owner_path="$1/owner" owner
  agent_notify_lock_path_is_safe "$lock_path" || return 1
  [[ -r $owner_path ]] || return 1
  owner=$(<"$owner_path")
  [[ $owner == "$token" ]]
}

agent_notify_lock_snapshot() {
  local lock_path=$1 owner_path="$1/owner" lock_stat owner_stat
  local lock_modified owner_modified

  agent_notify_lock_path_is_safe "$lock_path" || return 1
  [[ -d $lock_path ]] || return 1
  lock_stat=$(/usr/bin/stat -f '%i:%m' "$lock_path" 2>/dev/null) || return 1
  [[ $lock_stat =~ '^[0-9]+:-?[0-9]+$' ]] || return 1
  AGENT_NOTIFY_LOCK_SNAPSHOT_INODE=${lock_stat%%:*}
  lock_modified=${lock_stat#*:}
  AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE=missing
  AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_RECORD=''
  AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STAT='-'
  AGENT_NOTIFY_LOCK_SNAPSHOT_FALLBACK_MODIFIED=$lock_modified

  [[ -e $owner_path ]] || return 0
  owner_stat=$(/usr/bin/stat -f '%i:%m' "$owner_path" 2>/dev/null) || return 1
  [[ $owner_stat =~ '^[0-9]+:-?[0-9]+$' ]] || return 1
  AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STAT=$owner_stat
  owner_modified=${owner_stat#*:}
  (( owner_modified > AGENT_NOTIFY_LOCK_SNAPSHOT_FALLBACK_MODIFIED )) && AGENT_NOTIFY_LOCK_SNAPSHOT_FALLBACK_MODIFIED=$owner_modified
  if [[ -r $owner_path ]]; then
    AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE=readable
    AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_RECORD=$(<"$owner_path")
  else
    AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE=unreadable
  fi
}

agent_notify_lock_snapshot_is_recoverable() {
  local fallback_modified=$1 owner_pid owner_started now valid_owner=1
  local -a owner_fields

  if [[ $AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE == readable ]]; then
    owner_fields=(${(s: :)AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_RECORD})
    (( ${#owner_fields} == 2 || ${#owner_fields} == 3 )) || valid_owner=0
    [[ ${owner_fields[1]:-} =~ '^[0-9]+$' && ${owner_fields[2]:-} =~ '^[0-9]+$' ]] || valid_owner=0
    if (( ${#owner_fields} == 3 )); then
      [[ ${owner_fields[3]:-} =~ '^[[:alnum:]-]+$' ]] || valid_owner=0
    fi
    if (( valid_owner )); then
      owner_pid=${owner_fields[1]}
      owner_started=${owner_fields[2]}
      now=$(agent_notify_now)
      (( now - owner_started >= AGENT_NOTIFY_LOCK_STALE_SECONDS )) || return 1
      /bin/kill -0 "$owner_pid" 2>/dev/null && return 1
      return 0
    fi
  fi

  now=$(agent_notify_now)
  (( now - fallback_modified >= AGENT_NOTIFY_LOCK_STALE_SECONDS ))
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
  [[ -n ${project//[[:space:]]/} ]] || project='Unknown project'
  print -r -- "$project"
}

agent_notify_display_context() {
  local tmux_session=${1:-} session_dir=${2:-} label
  label=${tmux_session//[^[:alnum:].\ _()-]/_}
  label=${label[1,48]}
  if [[ -n ${label//[[:space:]]/} ]]; then
    print -r -- "$label"
  else
    agent_notify_project_name "$session_dir"
  fi
}

agent_notify_transition() {
  local state_key=$1 source=$2 kind=$3 session_dir=$4 request_id=$5 excerpt=${6:-}
  local now state_path request_key runtime deliver_kind=''
  REPLY=''
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
  REPLY=$deliver_kind
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
  local now=$1 state_path state_lock cursor='' last_cursor='' state_basename
  local -a state_paths
  integer inspected=0 index start=1 offset
  state_paths=("$AGENT_NOTIFY_STATE_DIR"/*.state(NOm))
  (( ${#state_paths} )) || return 0
  [[ -r $(agent_notify_prune_cursor_path) ]] && cursor=$(<"$(agent_notify_prune_cursor_path)")
  if [[ $cursor =~ '^[[:alnum:]][[:alnum:]_.-]*\.state$' ]]; then
    for (( index = 1; index <= ${#state_paths}; index++ )); do
      [[ ${state_paths[index]:t} == "$cursor" ]] || continue
      start=$(( index + 1 ))
      (( start > ${#state_paths} )) && start=1
      break
    done
  fi
  for (( offset = 0; offset < ${#state_paths}; offset++ )); do
    (( inspected >= AGENT_NOTIFY_PRUNE_BATCH_SIZE )) && break
    index=$(( (start + offset - 1) % ${#state_paths} + 1 ))
    state_path=$state_paths[index]
    state_basename=${state_path:t}
    state_lock="${state_path%.state}.lock"
    agent_notify_try_mkdir_lock "$state_lock" agent_notify_prune_one_state "$state_path" "$now" || true
    last_cursor=$state_basename
    (( inspected++ ))
  done
  [[ -z $last_cursor ]] || agent_notify_save_prune_cursor "$last_cursor"
}

agent_notify_prune_marker_path() {
  print -r -- "$AGENT_NOTIFY_STATE_DIR/.prune.last"
}

agent_notify_save_prune_marker() {
  local now=$1 marker temporary
  marker=$(agent_notify_prune_marker_path)
  temporary="$marker.$$.tmp"
  (umask 077; print -r -- "$now" > "$temporary") || return 1
  /bin/chmod 600 "$temporary" && /bin/mv -f "$temporary" "$marker"
}

agent_notify_prune_cursor_path() {
  print -r -- "$AGENT_NOTIFY_STATE_DIR/.prune.cursor"
}

agent_notify_save_prune_cursor() {
  local cursor=$1 marker temporary
  [[ $cursor =~ '^[[:alnum:]][[:alnum:]_.-]*\.state$' ]] || return 1
  marker=$(agent_notify_prune_cursor_path)
  temporary="$marker.$$.tmp"
  (umask 077; print -r -- "$cursor" > "$temporary") || return 1
  /bin/chmod 600 "$temporary" && /bin/mv -f "$temporary" "$marker"
}

agent_notify_prune_state_forced() {
  local now
  agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR" || return 1
  now=$(agent_notify_now)
  agent_notify_try_mkdir_lock "$AGENT_NOTIFY_STATE_DIR/.prune.lock" agent_notify_prune_state_locked "$now"
}

agent_notify_prune_state() {
  agent_notify_prune_state_forced
}

agent_notify_prune_if_due_locked() {
  local now=$1 marker previous
  marker=$(agent_notify_prune_marker_path)
  previous=''
  [[ -r $marker ]] && previous=$(<"$marker")
  if [[ $previous =~ '^[0-9]+$' ]] && (( now - previous < AGENT_NOTIFY_PRUNE_INTERVAL_SECONDS )); then
    return 0
  fi
  agent_notify_prune_state_locked "$now" || return 1
  agent_notify_save_prune_marker "$now"
}

agent_notify_prune_state_if_due() {
  local now marker previous
  agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR" || return 1
  now=$(agent_notify_now)
  marker=$(agent_notify_prune_marker_path)
  previous=''
  [[ -r $marker ]] && previous=$(<"$marker")
  if [[ $previous =~ '^[0-9]+$' ]] && (( now - previous < AGENT_NOTIFY_PRUNE_INTERVAL_SECONDS )); then
    return 0
  fi
  agent_notify_try_mkdir_lock "$AGENT_NOTIFY_STATE_DIR/.prune.lock" agent_notify_prune_if_due_locked "$now"
}

# Recovery fences are state-directory siblings so a moved lock cannot contain its own recovery owner.
agent_notify_external_gate_path() {
  agent_notify_lock_path_is_safe "$1" || return 1
  print -r -- "$AGENT_NOTIFY_STATE_DIR/.${1:t}.recovery-gate"
}

agent_notify_external_fence_exists() {
  local lock_path=$1 gate
  local -a fences
  gate=$(agent_notify_external_gate_path "$lock_path") || return 0
  [[ -e $gate || -L $gate ]] && return 0
  fences=("$AGENT_NOTIFY_STATE_DIR"/.${lock_path:t}.gate-quarantine.*(N) "$AGENT_NOTIFY_STATE_DIR"/.${lock_path:t}.lock-quarantine.*(N))
  (( ${#fences} ))
}

agent_notify_lock_snapshot_at() {
  local directory=$1 owner_path="$1/owner" details owner_details
  [[ -d $directory && ! -L $directory ]] || return 1
  details=$(/usr/bin/stat -f '%i:%m' "$directory" 2>/dev/null) || return 1
  [[ $details =~ '^[0-9]+:-?[0-9]+$' ]] || return 1
  AGENT_NOTIFY_LOCK_SNAPSHOT_INODE=${details%%:*}
  AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE=missing AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_RECORD='' AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STAT='-'
  AGENT_NOTIFY_LOCK_SNAPSHOT_FALLBACK_MODIFIED=${details#*:}
  [[ -e $owner_path ]] || return 0
  owner_details=$(/usr/bin/stat -f '%i:%m' "$owner_path" 2>/dev/null) || return 1
  [[ $owner_details =~ '^[0-9]+:-?[0-9]+$' ]] || return 1
  AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STAT=$owner_details
  (( ${owner_details#*:} > AGENT_NOTIFY_LOCK_SNAPSHOT_FALLBACK_MODIFIED )) && AGENT_NOTIFY_LOCK_SNAPSHOT_FALLBACK_MODIFIED=${owner_details#*:}
  if [[ -r $owner_path ]]; then
    AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE=readable
    AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_RECORD=$(<"$owner_path")
  else
    AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE=unreadable
  fi
}

agent_notify_external_snapshot_reaper() {
  local directory=$1 path="$1/reaper" details owner_details
  [[ -d $directory && ! -L $directory ]] || return 1
  details=$(/usr/bin/stat -f '%i:%m' "$directory" 2>/dev/null) || return 1
  [[ $details =~ '^[0-9]+:-?[0-9]+$' ]] || return 1
  AGENT_NOTIFY_EXTERNAL_REAPER_INODE=${details%%:*}
  AGENT_NOTIFY_EXTERNAL_REAPER_STATE=missing
  AGENT_NOTIFY_EXTERNAL_REAPER_RECORD=''
  AGENT_NOTIFY_EXTERNAL_REAPER_STAT='-'
  AGENT_NOTIFY_EXTERNAL_REAPER_MTIME=${details#*:}
  [[ -e $path ]] || return 0
  owner_details=$(/usr/bin/stat -f '%i:%m' "$path" 2>/dev/null) || return 1
  [[ $owner_details =~ '^[0-9]+:-?[0-9]+$' ]] || return 1
  AGENT_NOTIFY_EXTERNAL_REAPER_STAT=$owner_details
  (( ${owner_details#*:} > AGENT_NOTIFY_EXTERNAL_REAPER_MTIME )) && AGENT_NOTIFY_EXTERNAL_REAPER_MTIME=${owner_details#*:}
  if [[ -r $path ]]; then
    AGENT_NOTIFY_EXTERNAL_REAPER_STATE=readable
    AGENT_NOTIFY_EXTERNAL_REAPER_RECORD=$(<"$path")
  else
    AGENT_NOTIFY_EXTERNAL_REAPER_STATE=unreadable
  fi
}

agent_notify_external_reaper_is_stale() {
  local now pid started valid=1
  local -a fields
  if [[ $AGENT_NOTIFY_EXTERNAL_REAPER_STATE == readable ]]; then
    fields=(${(s: :)AGENT_NOTIFY_EXTERNAL_REAPER_RECORD})
    (( ${#fields} == 3 )) || valid=0
    [[ ${fields[1]:-} =~ '^[0-9]+$' && ${fields[2]:-} =~ '^[0-9]+$' && ${fields[3]:-} =~ '^[[:alnum:]_-]+$' ]] || valid=0
    if (( valid )); then
      pid=${fields[1]} started=${fields[2]} now=$(agent_notify_now)
      (( now - started >= AGENT_NOTIFY_LOCK_STALE_SECONDS )) || return 1
      /bin/kill -0 "$pid" 2>/dev/null && return 1
      return 0
    fi
  fi
  now=$(agent_notify_now)
  (( now - AGENT_NOTIFY_EXTERNAL_REAPER_MTIME >= AGENT_NOTIFY_LOCK_STALE_SECONDS ))
}

agent_notify_external_reaper_owned() {
  local directory=$1 token=$2 inode=$3 current owner
  [[ -d $directory && ! -L $directory ]] || return 1
  current=$(/usr/bin/stat -f '%i' "$directory" 2>/dev/null) || return 1
  [[ $current == "$inode" && -r $directory/reaper ]] || return 1
  owner=$(<"$directory/reaper")
  [[ $owner == "$token" ]]
}

agent_notify_external_publish_reaper() {
  local directory=$1 token=$2
  ( umask 077
    setopt noclobber
    print -r -- "$token" > "$directory/reaper"
  )
}

agent_notify_external_reserve_container() {
  local lock_path=$1 family=$2 now nonce token directory inode
  integer attempt=0
  agent_notify_lock_path_is_safe "$lock_path" || return 1
  now=$(agent_notify_now)
  while (( attempt++ < 4 )); do
    nonce=$(agent_notify_lock_nonce "$now")
    directory="$AGENT_NOTIFY_STATE_DIR/.${lock_path:t}.${family}-quarantine.$nonce"
    [[ ${directory:h:A} == ${AGENT_NOTIFY_STATE_DIR:A} && ! -e $directory && ! -L $directory ]] || continue
    (umask 077; /bin/mkdir "$directory") 2>/dev/null || continue
    token="$$ $now $nonce"
    agent_notify_external_publish_reaper "$directory" "$token" || { /bin/rmdir "$directory" 2>/dev/null || true; return 1; }
    inode=$(/usr/bin/stat -f '%i' "$directory" 2>/dev/null) || return 1
    agent_notify_external_reaper_owned "$directory" "$token" "$inode" || return 1
    AGENT_NOTIFY_EXTERNAL_CONTAINER=$directory
    AGENT_NOTIFY_EXTERNAL_CONTAINER_TOKEN=$token
    AGENT_NOTIFY_EXTERNAL_CONTAINER_INODE=$inode
    return 0
  done
  return 1
}

agent_notify_external_remove_owned_empty_container() {
  local directory=$1 token=$2 inode=$3
  agent_notify_external_reaper_owned "$directory" "$token" "$inode" || return 1
  [[ ! -e $directory/object ]] || return 1
  /bin/rm -f "$directory/reaper" && /bin/rmdir "$directory"
}

agent_notify_external_gate_snapshot_matches() {
  local directory=$1 inode=$2 state=$3 record=$4 stat=$5
  agent_notify_external_snapshot_reaper "$directory" || return 1
  [[ $AGENT_NOTIFY_EXTERNAL_REAPER_INODE == "$inode" && $AGENT_NOTIFY_EXTERNAL_REAPER_STATE == "$state" && $AGENT_NOTIFY_EXTERNAL_REAPER_RECORD == "$record" && $AGENT_NOTIFY_EXTERNAL_REAPER_STAT == "$stat" ]]
}

agent_notify_external_before_gate_move() { :; }

agent_notify_external_quarantine_gate_snapshot() {
  local lock_path=$1 gate=$2 inode=$3 state=$4 record=$5 stat=$6 object_inode
  agent_notify_external_reserve_container "$lock_path" gate || return 1
  agent_notify_external_before_gate_move "$lock_path" "$gate" "$AGENT_NOTIFY_EXTERNAL_CONTAINER"
  /bin/mv "$gate" "$AGENT_NOTIFY_EXTERNAL_CONTAINER/object" 2>/dev/null || {
    agent_notify_external_remove_owned_empty_container "$AGENT_NOTIFY_EXTERNAL_CONTAINER" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_TOKEN" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_INODE" || true
    return 1
  }
  agent_notify_external_reaper_owned "$AGENT_NOTIFY_EXTERNAL_CONTAINER" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_TOKEN" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_INODE" || return 1
  object_inode=$(/usr/bin/stat -f '%i' "$AGENT_NOTIFY_EXTERNAL_CONTAINER/object" 2>/dev/null) || return 1
  [[ $object_inode == "$inode" ]] || return 1
  agent_notify_external_gate_snapshot_matches "$AGENT_NOTIFY_EXTERNAL_CONTAINER/object" "$inode" "$state" "$record" "$stat" || return 1
  /bin/rm -rf "$AGENT_NOTIFY_EXTERNAL_CONTAINER"
}

agent_notify_external_gate_owned_cleanup() {
  local lock_path=$1 gate=$2 token=$3 inode=$4 object_inode
  agent_notify_external_snapshot_reaper "$gate" || return 1
  [[ $AGENT_NOTIFY_EXTERNAL_REAPER_INODE == "$inode" && $AGENT_NOTIFY_EXTERNAL_REAPER_RECORD == "$token" ]] || return 1
  agent_notify_external_quarantine_gate_snapshot "$lock_path" "$gate" "$inode" "$AGENT_NOTIFY_EXTERNAL_REAPER_STATE" "$AGENT_NOTIFY_EXTERNAL_REAPER_RECORD" "$AGENT_NOTIFY_EXTERNAL_REAPER_STAT"
}

agent_notify_external_cleanup_one_fence() {
  local lock_path=$1 gate fence
  local -a fences
  gate=$(agent_notify_external_gate_path "$lock_path") || return 1
  if [[ -e $gate ]]; then
    agent_notify_external_snapshot_reaper "$gate" || return 1
    agent_notify_external_reaper_is_stale || return 1
    agent_notify_external_quarantine_gate_snapshot "$lock_path" "$gate" "$AGENT_NOTIFY_EXTERNAL_REAPER_INODE" "$AGENT_NOTIFY_EXTERNAL_REAPER_STATE" "$AGENT_NOTIFY_EXTERNAL_REAPER_RECORD" "$AGENT_NOTIFY_EXTERNAL_REAPER_STAT"
    return $?
  fi
  fences=("$AGENT_NOTIFY_STATE_DIR"/.${lock_path:t}.gate-quarantine.*(N) "$AGENT_NOTIFY_STATE_DIR"/.${lock_path:t}.lock-quarantine.*(N))
  (( ${#fences} )) || return 1
  fence=$fences[1]
  agent_notify_external_snapshot_reaper "$fence" || return 1
  agent_notify_external_reaper_is_stale || return 1
  if [[ ! -e $fence/object ]]; then
    agent_notify_external_snapshot_reaper "$fence" || return 1
    agent_notify_external_reaper_is_stale || return 1
    /bin/rm -rf "$fence"
    return 0
  fi
  if [[ ${fence:t} == *.lock-quarantine.* ]]; then
    agent_notify_lock_snapshot_at "$fence/object" || return 1
    agent_notify_lock_snapshot_is_recoverable "$AGENT_NOTIFY_LOCK_SNAPSHOT_FALLBACK_MODIFIED" || return 1
  else
    agent_notify_external_snapshot_reaper "$fence/object" || return 1
    agent_notify_external_reaper_is_stale || return 1
  fi
  /bin/rm -rf "$fence"
}

agent_notify_recovery_before_quarantine() { :; }
agent_notify_recovery_after_final_validation() { :; }

agent_notify_recover_stale_lock() {
  local lock_path=$1 gate observed_inode observed_state observed_record observed_stat observed_fallback object_inode
  agent_notify_lock_path_is_safe "$lock_path" || return 1
  if agent_notify_external_fence_exists "$lock_path"; then
    agent_notify_external_cleanup_one_fence "$lock_path" || true
    return 1
  fi
  gate=$(agent_notify_external_gate_path "$lock_path") || return 1
  (umask 077; /bin/mkdir "$gate") 2>/dev/null || return 1
  local now gate_token gate_inode
  now=$(agent_notify_now)
  gate_token="$$ $now $(agent_notify_lock_nonce "$now")"
  agent_notify_external_publish_reaper "$gate" "$gate_token" || { /bin/rmdir "$gate" 2>/dev/null || true; return 1; }
  gate_inode=$(/usr/bin/stat -f '%i' "$gate" 2>/dev/null) || return 1
  agent_notify_external_reaper_owned "$gate" "$gate_token" "$gate_inode" || return 1
  agent_notify_lock_snapshot "$lock_path" || { agent_notify_external_gate_owned_cleanup "$lock_path" "$gate" "$gate_token" "$gate_inode" || true; return 1; }
  agent_notify_lock_snapshot_is_recoverable "$AGENT_NOTIFY_LOCK_SNAPSHOT_FALLBACK_MODIFIED" || { agent_notify_external_gate_owned_cleanup "$lock_path" "$gate" "$gate_token" "$gate_inode" || true; return 1; }
  observed_inode=$AGENT_NOTIFY_LOCK_SNAPSHOT_INODE observed_state=$AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE observed_record=$AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_RECORD observed_stat=$AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STAT observed_fallback=$AGENT_NOTIFY_LOCK_SNAPSHOT_FALLBACK_MODIFIED
  agent_notify_recovery_before_quarantine "$lock_path"
  agent_notify_external_reaper_owned "$gate" "$gate_token" "$gate_inode" || return 1
  agent_notify_lock_snapshot "$lock_path" || return 1
  [[ $AGENT_NOTIFY_LOCK_SNAPSHOT_INODE == "$observed_inode" && $AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE == "$observed_state" && $AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_RECORD == "$observed_record" && $AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STAT == "$observed_stat" ]] || return 1
  agent_notify_lock_snapshot_is_recoverable "$observed_fallback" || return 1
  agent_notify_recovery_after_final_validation "$lock_path" "$gate"
  agent_notify_external_reserve_container "$lock_path" lock || return 1
  /bin/mv "$lock_path" "$AGENT_NOTIFY_EXTERNAL_CONTAINER/object" 2>/dev/null || {
    agent_notify_external_remove_owned_empty_container "$AGENT_NOTIFY_EXTERNAL_CONTAINER" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_TOKEN" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_INODE" || true
    return 1
  }
  agent_notify_external_reaper_owned "$AGENT_NOTIFY_EXTERNAL_CONTAINER" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_TOKEN" "$AGENT_NOTIFY_EXTERNAL_CONTAINER_INODE" || return 1
  agent_notify_external_reaper_owned "$gate" "$gate_token" "$gate_inode" || return 1
  agent_notify_lock_snapshot_at "$AGENT_NOTIFY_EXTERNAL_CONTAINER/object" || return 1
  [[ $AGENT_NOTIFY_LOCK_SNAPSHOT_INODE == "$observed_inode" && $AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STATE == "$observed_state" && $AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_RECORD == "$observed_record" && $AGENT_NOTIFY_LOCK_SNAPSHOT_OWNER_STAT == "$observed_stat" ]] || return 1
  /bin/rm -rf "$AGENT_NOTIFY_EXTERNAL_CONTAINER"
  agent_notify_external_gate_owned_cleanup "$lock_path" "$gate" "$gate_token" "$gate_inode"
}

agent_notify_remove_owned_lock() {
  local lock_path=$1 token=$2
  agent_notify_lock_path_is_safe "$lock_path" || return 1
  agent_notify_external_fence_exists "$lock_path" && return 1
  agent_notify_lock_owned "$lock_path" "$token" || return 1
  /bin/rm -rf "$lock_path"
}

agent_notify_publish_lock_owner() {
  local lock_path=$1 token=$2
  agent_notify_lock_path_is_safe "$lock_path" || return 1
  agent_notify_external_fence_exists "$lock_path" && return 1
  ( umask 077
    setopt noclobber
    print -r -- "$token" > "$lock_path/owner"
  )
}

agent_notify_before_lock_owner_publish() { :; }

agent_notify_run_owned_lock() {
  local lock_path=$1 token=$2 callback=$3 result
  shift 3
  agent_notify_external_fence_exists "$lock_path" && return 1
  agent_notify_lock_owned "$lock_path" "$token" || return 1
  if "$callback" "$@"; then result=0; else result=$?; fi
  agent_notify_remove_owned_lock "$lock_path" "$token" || true
  return $result
}

agent_notify_acquire_mkdir_lock() {
  local lock_path=$1 now token
  agent_notify_lock_path_is_safe "$lock_path" || return 1
  agent_notify_before_lock_owner_publish "$lock_path"
  if agent_notify_external_fence_exists "$lock_path"; then
    /bin/rmdir "$lock_path" 2>/dev/null || true
    return 1
  fi
  now=$(agent_notify_now)
  token="$$ $now $(agent_notify_lock_nonce "$now")"
  agent_notify_publish_lock_owner "$lock_path" "$token" || { /bin/rmdir "$lock_path" 2>/dev/null || true; return 1; }
  REPLY=$token
}

agent_notify_try_mkdir_lock() {
  local lock_path=$1 callback=$2 token
  shift 2
  agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR" || return 1
  agent_notify_lock_path_is_safe "$lock_path" || return 1
  if agent_notify_external_fence_exists "$lock_path"; then
    agent_notify_external_cleanup_one_fence "$lock_path" || true
    return 1
  fi
  if ! (umask 077; /bin/mkdir "$lock_path") 2>/dev/null; then
    agent_notify_recover_stale_lock "$lock_path" || return 1
    (umask 077; /bin/mkdir "$lock_path") 2>/dev/null || return 1
  fi
  agent_notify_acquire_mkdir_lock "$lock_path" || return 1
  token=$REPLY
  agent_notify_run_owned_lock "$lock_path" "$token" "$callback" "$@"
}

agent_notify_with_mkdir_lock() {
  local lock_path=$1 callback=$2 attempt=0 token
  shift 2
  agent_notify_prepare_directory "$AGENT_NOTIFY_STATE_DIR" || return 1
  agent_notify_lock_path_is_safe "$lock_path" || return 1
  while true; do
    if agent_notify_external_fence_exists "$lock_path"; then
      agent_notify_external_cleanup_one_fence "$lock_path" || true
      (( attempt++ >= AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS )) && return 1
      /bin/sleep 0.05
      continue
    fi
    if (umask 077; /bin/mkdir "$lock_path") 2>/dev/null; then
      if agent_notify_acquire_mkdir_lock "$lock_path"; then
        token=$REPLY
        break
      fi
      (( attempt++ >= AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS )) && return 1
      /bin/sleep 0.05
      continue
    fi
    if [[ -r $lock_path/owner ]]; then
      local owner_record=''
      local -a owner_fields=()
      owner_record=$(<"$lock_path/owner")
      owner_fields=(${(s: :)owner_record})
      if (( ${#owner_fields} == 2 || ${#owner_fields} == 3 )) && [[ ${owner_fields[1]:-} =~ '^[0-9]+$' ]] && /bin/kill -0 "${owner_fields[1]}" 2>/dev/null; then
        (( attempt++ >= AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS )) && return 1
        /bin/sleep 0.05
        continue
      fi
    fi
    agent_notify_recover_stale_lock "$lock_path" && continue
    (( attempt++ >= AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS )) && return 1
    /bin/sleep 0.05
  done
  agent_notify_run_owned_lock "$lock_path" "$token" "$callback" "$@"
}
