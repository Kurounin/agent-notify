# agent-notify foundation -- installer-managed files use these stable markers.
typeset -gr AGENT_NOTIFY_MANAGED_BEGIN='# >>> agent-notify managed file >>>'
typeset -gr AGENT_NOTIFY_MANAGED_END='# <<< agent-notify managed file <<<'
typeset -gr AGENT_NOTIFY_VERSION='0.1.0'
typeset -gr AGENT_NOTIFY_KEYCHAIN_ACCOUNT='agent-notify'
typeset -gr AGENT_NOTIFY_KEYCHAIN_SELECTOR_SERVICE='agent-notify.pushover.v2.active-generation'
typeset -gr AGENT_NOTIFY_KEYCHAIN_USER_SERVICE_PREFIX='agent-notify.pushover.v2.user-key.'
typeset -gr AGENT_NOTIFY_KEYCHAIN_TOKEN_SERVICE_PREFIX='agent-notify.pushover.v2.app-token.'
typeset -gr AGENT_NOTIFY_PUSHOVER_ENDPOINT='https://api.pushover.net/1/messages.json'
typeset -gr AGENT_NOTIFY_SECURITY_BIN='/usr/bin/security'
typeset -gr AGENT_NOTIFY_JXA_BIN='/usr/bin/osascript'
typeset -gr AGENT_NOTIFY_FLOCK_BIN='/usr/bin/flock'
typeset -gr AGENT_NOTIFY_OPEN_CODE_ATTENTION_FAMILY='permission.asked/replied and question.asked/replied/rejected'

: ${AGENT_NOTIFY_STATE_DIR:=${HOME}/Library/Application Support/agent-notify/state}
: ${AGENT_NOTIFY_DIAGNOSTIC_DIR:=${HOME}/Library/Application Support/agent-notify/diagnostics}
: ${AGENT_NOTIFY_MIN_RUNTIME_SECONDS:=30}
: ${AGENT_NOTIFY_ATTENTION_DEBOUNCE_SECONDS:=60}
: ${AGENT_NOTIFY_RETENTION_SECONDS:=604800}
: ${AGENT_NOTIFY_MAX_ACTIVE_SECONDS:=86400}
: ${AGENT_NOTIFY_LOCK_TIMEOUT_ATTEMPTS:=100}
: ${AGENT_NOTIFY_LOCK_STALE_SECONDS:=60}
