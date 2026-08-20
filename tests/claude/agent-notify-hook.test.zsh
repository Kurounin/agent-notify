#!/usr/bin/env zsh

setopt errexit no_unset pipe_fail

typeset root=${0:A:h:h:h}
typeset adapter_source="$root/integrations/claude/agent-notify-hook.zsh"
typeset normalizer="$root/integrations/claude/agent-notify-hook.jxa"
typeset test_root
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-notify-claude-test.XXXXXX")
trap '/bin/rm -rf "$test_root"' EXIT

# The adapter resolves its normalizer and the notifier as siblings, so mirror the installed layout.
typeset stage="$test_root/bin"
typeset adapter="$stage/agent-notify-claude-hook"
typeset calls="$test_root/calls"
/bin/mkdir -p "$stage"
/bin/cp "$adapter_source" "$adapter"
/bin/cp "$normalizer" "$stage/agent-notify-claude-hook.jxa"
/bin/chmod 700 "$adapter"

cat > "$stage/agent-notify" <<'EOF'
#!/usr/bin/env zsh
setopt no_unset pipe_fail
typeset payload
payload=$(command /bin/cat)
print -r -- "$*|$payload" >> "$AGENT_NOTIFY_TEST_CALLS"
EOF
/bin/chmod 700 "$stage/agent-notify"

assert_equals() {
  [[ $1 == "$2" ]] || { print -u2 -- "expected '$2', got '$1'"; exit 1; }
}

submit() {
  AGENT_NOTIFY_TEST_CALLS="$calls" "$adapter" "$1"
}

normalize() {
  print -rn -- "$2" | /usr/bin/osascript -l JavaScript "$normalizer" "$1"
}

assert_ignored() {
  [[ -z $(normalize "$1" "$2") ]] || { print -u2 -- "expected '$3' to be ignored"; exit 1; }
}

submit began <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"session-a","cwd":"/work/project"}
EOF
submit attention <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","notification_id":"request-a","session_id":"session-a","cwd":"/work/project"}
EOF
submit completed <<'EOF'
{"hook_event_name":"Stop","session_id":"session-a","cwd":"/work/project","stop_hook_active":false,"background_tasks":[]}
EOF
submit failed <<'EOF'
{"hook_event_name":"StopFailure","session_id":"session-a","cwd":"/work/project","error":"unknown"}
EOF

assert_equals "$(<"$calls")" $'event|{"source":"claude-code","kind":"began","session_id":"session-a","session_dir":"/work/project"}\nevent|{"source":"claude-code","kind":"attention","session_id":"session-a","session_dir":"/work/project","request_id":"request-a"}\nevent|{"source":"claude-code","kind":"completed","session_id":"session-a","session_dir":"/work/project"}\nevent|{"source":"claude-code","kind":"failed","session_id":"session-a","session_dir":"/work/project"}'

/bin/rm -f "$calls"
submit unsupported <<'EOF'
{"hook_event_name":"Stop","session_id":"session-a","cwd":"/work/project"}
EOF
[[ ! -e $calls ]] || { print -u2 -- 'an unsupported event kind reached the notifier'; exit 1; }

# Claude reports in-flight background work on the Stop that pauses the turn, and wakes the session
# with an empty list once it settles; only the latter is a completion.
assert_ignored completed \
  '{"hook_event_name":"Stop","session_id":"session-a","cwd":"/work/project","background_tasks":[{"id":"task-1","type":"workflow","status":"running","description":"review"}]}' \
  'completion with in-flight background work'
assert_ignored completed \
  '{"hook_event_name":"Stop","session_id":"session-a","cwd":"/work/project","background_tasks":[{"id":"task-1","type":"shell","status":"running","description":"sleep 40","command":"sleep 40"},{"id":"task-2","type":"subagent","status":"running","description":"explore","agent_type":"Explore"}]}' \
  'completion with several in-flight background tasks'

typeset settled_completion
settled_completion=$(normalize completed '{"hook_event_name":"Stop","session_id":"session-a","cwd":"/work/project","background_tasks":[]}')
assert_equals "$settled_completion" '{"source":"claude-code","kind":"completed","session_id":"session-a","session_dir":"/work/project"}'

typeset failure_with_background_work
failure_with_background_work=$(normalize failed '{"hook_event_name":"StopFailure","session_id":"session-a","cwd":"/work/project","background_tasks":[{"id":"task-1","type":"workflow","status":"running","description":"review"}]}')
assert_equals "$failure_with_background_work" '{"source":"claude-code","kind":"failed","session_id":"session-a","session_dir":"/work/project"}'

assert_ignored attention \
  '{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"session-b","cwd":"/work/project"}' \
  'an unsupported notification type'
assert_ignored attention \
  '{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"session-b","cwd":"/work/project","agent_type":"background"}' \
  'a background agent type'
assert_ignored attention \
  '{"hook_event_name":"Notification","notification_type":"elicitation_dialog","session_id":"session-b","cwd":"/work/project","is_background":true}' \
  'an is_background payload'
assert_ignored attention \
  '{"hook_event_name":"Notification","notification_type":"elicitation_url_dialog","session_id":"session-b","cwd":"/work/project","is_subagent":true}' \
  'an is_subagent payload'
assert_ignored completed \
  '{"hook_event_name":"Stop","session_id":"session-b","cwd":"/work/project","agent_type":"subagent"}' \
  'a subagent stop'
assert_ignored completed \
  '{"hook_event_name":"Stop","session_id":"session-b","cwd":"/work/project","parent_tool_use_id":"toolu_1"}' \
  'a nested tool-use stop'
assert_ignored completed \
  '{"hook_event_name":"Stop","cwd":"/work/project"}' \
  'a payload without a session id'
assert_ignored completed \
  '{"hook_event_name":"Stop","session_id":"session-b"}' \
  'a payload without a session directory'

typeset notification_fallback
notification_fallback=$(normalize attention '{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"session-c","cwd":"/work/project"}')
assert_equals "$notification_fallback" '{"source":"claude-code","kind":"attention","session_id":"session-c","session_dir":"/work/project","request_id":"claude-notification:session-c:permission_prompt"}'

print -- 'Claude hook adapter tests passed'
