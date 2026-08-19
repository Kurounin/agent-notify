typeset -g AGENT_NOTIFY_TRANSPORT_HTTP_STATUS=0
typeset -g AGENT_NOTIFY_TRANSPORT_REQUEST_ID='-'

agent_notify_diag() {
  local component=$1 code=$2 http_status=${3:-0} request_id=${4:--}
  local now file safe_request
  [[ $component == (normalize|state|keychain|transport) ]] || component=transport
  [[ $code =~ '^[[:alnum:]_-]+$' ]] || code=unknown
  [[ $http_status =~ '^[0-9]+$' ]] || http_status=0
  safe_request=${request_id//[^[:alnum:]._-]/}
  safe_request=${safe_request[1,64]}
  [[ -n $safe_request ]] || safe_request='-'
  agent_notify_prepare_directory "$AGENT_NOTIFY_DIAGNOSTIC_DIR" || return 0
  now=$(agent_notify_now)
  file="$AGENT_NOTIFY_DIAGNOSTIC_DIR/diagnostics-$(/bin/date -r "$now" +%Y%m%d 2>/dev/null || /bin/date +%Y%m%d).log"
  (umask 077; print -- "timestamp=$now component=$component code=$code http_status=$http_status request_id=$safe_request" >> "$file")
  /bin/chmod 600 "$file" 2>/dev/null || true
  /usr/bin/find "$AGENT_NOTIFY_DIAGNOSTIC_DIR" -type f -name 'diagnostics-*.log' -mtime +6 -delete 2>/dev/null || true
}

agent_notify_keychain_read() {
  local helper=${AGENT_NOTIFY_KEYCHAIN_RUNTIME_HELPER:-${AGENT_NOTIFY_LIB_DIR:-}/keychain.jxa}
  local jxa_bin=${AGENT_NOTIFY_KEYCHAIN_JXA_BIN:-$AGENT_NOTIFY_JXA_BIN}
  [[ -r $helper ]] || return 1
  "$jxa_bin" -l JavaScript "$helper" read 2>/dev/null
}

agent_notify_curl_quote() {
  local value=$1
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || return 1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  print -r -- "$value"
}

agent_notify_curl_config() {
  local user_key=$1 app_token=$2 title=$3 message=$4 priority=$5
  local quoted_user quoted_token quoted_title quoted_message
  quoted_user=$(agent_notify_curl_quote "user=$user_key") || return 1
  quoted_token=$(agent_notify_curl_quote "token=$app_token") || return 1
  quoted_title=$(agent_notify_curl_quote "title=$title") || return 1
  quoted_message=$(agent_notify_curl_quote "message=$message") || return 1
  print -r -- "url = \"$AGENT_NOTIFY_PUSHOVER_ENDPOINT\""
  print -r -- 'request = "POST"'
  print -r -- 'max-redirs = 0'
  print -r -- 'proto = "=https"'
  print -r -- 'max-time = 5'
  print -r -- 'connect-timeout = 5'
  print -r -- 'retry = 0'
  print -r -- 'silent'
  print -r -- 'show-error'
  print -r -- "data-urlencode = \"$quoted_user\""
  print -r -- "data-urlencode = \"$quoted_token\""
  print -r -- "data-urlencode = \"$quoted_title\""
  print -r -- "data-urlencode = \"$quoted_message\""
  print -r -- "data-urlencode = \"priority=$priority\""
  print -r -- 'output = "-"'
  print -r -- 'write-out = "\nAGENT_NOTIFY_META:%{http_code}:%{json}"'
}

agent_notify_curl_request() {
  /usr/bin/curl --disable --config - 2>/dev/null
}

agent_notify_transport_result() {
  local output=$1 metadata body http_status transport_status response_status response_request
  metadata=${output##*$'\nAGENT_NOTIFY_META:'}
  [[ $metadata != "$output" && $metadata == *:* ]] || return 1
  body=${output%$'\nAGENT_NOTIFY_META:'*}
  http_status=${metadata%%:*}
  [[ $http_status =~ '^[0-9]+$' ]] || http_status=0
  transport_status=$(print -rn -- "$body" | "$AGENT_NOTIFY_JXA_BIN" -l JavaScript -e '
ObjC.import("Foundation");
const text = $.NSString.alloc.initWithDataEncoding($.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding).js;
let result;
try { const value = JSON.parse(text); const request = typeof value.request === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(value.request) ? value.request : "-"; result = (value.status === 1 ? "1" : "0") + "\t" + request; } catch (_) { result = "0\t-"; }
result;
' 2>/dev/null) || transport_status=$'0\t-'
  IFS=$'\t' read -r response_status response_request <<< "$transport_status"
  AGENT_NOTIFY_TRANSPORT_HTTP_STATUS=$http_status
  AGENT_NOTIFY_TRANSPORT_REQUEST_ID=$response_request
  [[ $http_status =~ '^2[0-9][0-9]$' && $response_status == 1 ]]
}

agent_notify_deliver() {
  local kind=$1 source=$2 project=$3 title message priority credentials credential_result generation user_key app_token output
  case $kind in
    attention) message='Attention required'; priority=0 ;;
    completed) message='Turn complete'; priority=-1 ;;
    failed) message='Agent error'; priority=0 ;;
    *) return 1 ;;
  esac
  case $source in
    claude-code) title="Claude Code — $project" ;;
    opencode) title="OpenCode — $project" ;;
    *) return 1 ;;
  esac
  credentials=$(agent_notify_keychain_read) || { agent_notify_diag keychain runtime_-50 0 -; return 1; }
  IFS=$'\t' read -r credential_result generation user_key app_token <<< "$credentials"
  if [[ $credential_result == error ]]; then
    [[ $generation == (selector|user|token|credential|action|runtime) && $user_key =~ '^-?[0-9]+$' ]] || { agent_notify_diag keychain runtime_-50 0 -; return 1; }
    agent_notify_diag keychain "${generation}_${user_key}" 0 -
    return 1
  fi
  [[ $credential_result == ok ]] || { agent_notify_diag keychain runtime_-50 0 -; return 1; }
  [[ $generation =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ]] || { agent_notify_diag keychain selector_invalid 0 -; return 1; }
  [[ $user_key =~ '^[[:alnum:]]+$' && $app_token =~ '^[[:alnum:]]+$' ]] || { agent_notify_diag keychain invalid_credential 0 -; return 1; }
  output=$(agent_notify_curl_config "$user_key" "$app_token" "$title" "$message" "$priority" | agent_notify_curl_request) || { agent_notify_diag transport curl_failed 0 -; return 1; }
  agent_notify_transport_result "$output"
  local result=$?
  if (( result )); then
    agent_notify_diag transport rejected "$AGENT_NOTIFY_TRANSPORT_HTTP_STATUS" "$AGENT_NOTIFY_TRANSPORT_REQUEST_ID"
    return 1
  fi
}
