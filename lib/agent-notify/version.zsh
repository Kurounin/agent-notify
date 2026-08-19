# Tested compatibility policy. Installation will invoke these checks before mutation.
typeset -gr AGENT_NOTIFY_MACOS_MIN_MAJOR=13
typeset -gr AGENT_NOTIFY_MACOS_MAX_MAJOR=26
typeset -gr AGENT_NOTIFY_CLAUDE_CODE_MIN_VERSION='1.0.0'
typeset -gr AGENT_NOTIFY_CLAUDE_CODE_MAX_VERSION='3.0.0'
typeset -gr AGENT_NOTIFY_OPEN_CODE_MIN_VERSION='1.0.0'
typeset -gr AGENT_NOTIFY_OPEN_CODE_MAX_VERSION='2.0.0'

agent_notify_version_number() {
  local value=${1#v} major minor patch
  [[ $value =~ '^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$' ]] || return 1
  major=$match[1]
  minor=${match[3]:-0}
  patch=${match[5]:-0}
  REPLY=$(( 10#$major * 1000000 + 10#$minor * 1000 + 10#$patch ))
}

agent_notify_version_in_range() {
  local value=$1 minimum=$2 exclusive_maximum=$3 REPLY
  local value_number minimum_number maximum_number
  agent_notify_version_number "$value" || return 1
  value_number=$REPLY
  agent_notify_version_number "$minimum" || return 1
  minimum_number=$REPLY
  agent_notify_version_number "$exclusive_maximum" || return 1
  maximum_number=$REPLY
  (( value_number >= minimum_number && value_number < maximum_number ))
}

agent_notify_validate_version() {
  local component=$1 value=$2 major
  case $component in
    macos)
      [[ $value =~ '^([0-9]+)(\.[0-9]+){0,2}$' ]] || return 1
      major=$match[1]
      (( 10#$major >= AGENT_NOTIFY_MACOS_MIN_MAJOR && 10#$major <= AGENT_NOTIFY_MACOS_MAX_MAJOR ))
      ;;
    claude-code)
      agent_notify_version_in_range "$value" "$AGENT_NOTIFY_CLAUDE_CODE_MIN_VERSION" "$AGENT_NOTIFY_CLAUDE_CODE_MAX_VERSION"
      ;;
    opencode)
      agent_notify_version_in_range "$value" "$AGENT_NOTIFY_OPEN_CODE_MIN_VERSION" "$AGENT_NOTIFY_OPEN_CODE_MAX_VERSION"
      ;;
    *) return 2 ;;
  esac
}

agent_notify_print_supported_versions() {
  print -- "macOS: ${AGENT_NOTIFY_MACOS_MIN_MAJOR}-${AGENT_NOTIFY_MACOS_MAX_MAJOR}"
  print -- "Claude Code: >=${AGENT_NOTIFY_CLAUDE_CODE_MIN_VERSION}, <${AGENT_NOTIFY_CLAUDE_CODE_MAX_VERSION}"
  print -- "OpenCode: >=${AGENT_NOTIFY_OPEN_CODE_MIN_VERSION}, <${AGENT_NOTIFY_OPEN_CODE_MAX_VERSION}"
  print -- "OpenCode attention family: ${AGENT_NOTIFY_OPEN_CODE_ATTENTION_FAMILY}"
}
