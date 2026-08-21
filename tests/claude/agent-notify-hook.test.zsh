#!/usr/bin/env zsh

setopt errexit no_unset pipe_fail

typeset root=${0:A:h:h:h}
typeset adapter_source="$root/integrations/claude/agent-notify-hook.zsh"
typeset normalizer="$root/integrations/claude/agent-notify-hook.jxa"
typeset corpus="$root/tests/fixtures/excerpt-corpus.json"
typeset test_root
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-notify-claude-test.XXXXXX")
trap '/bin/rm -rf "$test_root"' EXIT

# Excerpt settings are read from an injected path so the suite never touches the live home.
export AGENT_NOTIFY_SETTINGS_FILE="$test_root/settings.conf"

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

assert_equals "$(<"$calls")" $'event|{"source":"claude-code","kind":"began","session_id":"session-a","session_dir":"/work/project"}\nevent|{"source":"claude-code","kind":"attention","session_id":"session-a","session_dir":"/work/project","request_id":"request-a"}\nevent|{"source":"claude-code","kind":"completed","session_id":"session-a","session_dir":"/work/project"}\nevent|{"source":"claude-code","kind":"failed","session_id":"session-a","session_dir":"/work/project","excerpt":"unknown"}'

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

typeset completion_excerpt
completion_excerpt=$(normalize completed '{"hook_event_name":"Stop","session_id":"session-d","cwd":"/work/project","background_tasks":[],"last_assistant_message":"All 14 tests pass."}')
assert_equals "$completion_excerpt" '{"source":"claude-code","kind":"completed","session_id":"session-d","session_dir":"/work/project","excerpt":"All 14 tests pass."}'

typeset multiline_excerpt
multiline_excerpt=$(normalize completed '{"hook_event_name":"Stop","session_id":"session-d","cwd":"/work/project","background_tasks":[],"last_assistant_message":"Rewrote the parser.\nRun `zsh tests/notifier/test_notifier.zsh` next."}')
assert_equals "$multiline_excerpt" '{"source":"claude-code","kind":"completed","session_id":"session-d","session_dir":"/work/project","excerpt":"Rewrote the parser. Run zsh tests/notifier/test_notifier.zsh next."}'

assert_no_excerpt() {
  [[ $(normalize "$1" "$2") != *'"excerpt"'* ]] || { print -u2 -- "expected '$3' to carry no excerpt"; exit 1; }
}

assert_no_excerpt completed '{"hook_event_name":"Stop","session_id":"session-d","cwd":"/work/project","background_tasks":[]}' 'an absent final message'
assert_no_excerpt completed '{"hook_event_name":"Stop","session_id":"session-d","cwd":"/work/project","background_tasks":[],"last_assistant_message":""}' 'an empty final message'
assert_no_excerpt completed '{"hook_event_name":"Stop","session_id":"session-d","cwd":"/work/project","background_tasks":[],"last_assistant_message":"   \n\t  "}' 'a whitespace-only final message'
assert_no_excerpt began '{"hook_event_name":"UserPromptSubmit","session_id":"session-d","cwd":"/work/project","last_assistant_message":"prior turn text"}' 'a began event'
assert_no_excerpt attention '{"hook_event_name":"Notification","notification_type":"permission_prompt","notification_id":"request-d","session_id":"session-d","cwd":"/work/project","last_assistant_message":"prior turn text"}' 'an attention event'

# StopFailure exposes three candidates; only the categorical enum is disclosed.
typeset failure_excerpt
failure_excerpt=$(normalize failed '{"hook_event_name":"StopFailure","session_id":"session-d","cwd":"/work/project","error":"rate_limit","error_details":"detail-must-not-leak","last_assistant_message":"banner-must-not-leak"}')
assert_equals "$failure_excerpt" '{"source":"claude-code","kind":"failed","session_id":"session-d","session_dir":"/work/project","excerpt":"rate_limit"}'

# The corpus pins the Claude and OpenCode sanitizers to byte-identical output.
typeset corpus_cases corpus_case corpus_name corpus_payload corpus_expected corpus_actual
corpus_cases=$(AGENT_NOTIFY_CORPUS="$corpus" /usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation");
const path = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey("AGENT_NOTIFY_CORPUS"));
const corpus = JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)));
const b64 = (s) => $.NSString.alloc.initWithString(s).dataUsingEncoding($.NSUTF8StringEncoding).base64EncodedStringWithOptions(0).js;
corpus.cases.map((entry) => {
  const payload = {hook_event_name: "Stop", session_id: "corpus", cwd: "/work/project", background_tasks: [], last_assistant_message: entry.input};
  const expected = {source: "claude-code", kind: "completed", session_id: "corpus", session_dir: "/work/project"};
  if (entry.excerpt) expected.excerpt = entry.excerpt;
  return [entry.name, b64(JSON.stringify(payload)), b64(JSON.stringify(expected))].join(":");
}).join("\n");
')
[[ -n $corpus_cases ]] || { print -u2 -- 'the excerpt corpus produced no cases'; exit 1; }
for corpus_case in ${(f)corpus_cases}; do
  IFS=':' read -r corpus_name corpus_payload corpus_expected <<< "$corpus_case"
  corpus_actual=$(print -rn -- "$corpus_payload" | /usr/bin/base64 -D | /usr/bin/osascript -l JavaScript "$normalizer" completed)
  [[ $corpus_actual == $(print -rn -- "$corpus_expected" | /usr/bin/base64 -D) ]] || { print -u2 -- "excerpt corpus case '$corpus_name' did not match"; exit 1; }
done

print -- 'EXCERPT=1' > "$AGENT_NOTIFY_SETTINGS_FILE"
assert_equals "$(normalize completed '{"hook_event_name":"Stop","session_id":"session-e","cwd":"/work/project","background_tasks":[],"last_assistant_message":"enabled"}')" \
  '{"source":"claude-code","kind":"completed","session_id":"session-e","session_dir":"/work/project","excerpt":"enabled"}'
print -- 'EXCERPT=0' > "$AGENT_NOTIFY_SETTINGS_FILE"
assert_no_excerpt completed '{"hook_event_name":"Stop","session_id":"session-e","cwd":"/work/project","background_tasks":[],"last_assistant_message":"disabled"}' 'a disabled excerpt setting'
print -- 'this file is not key=value at all' > "$AGENT_NOTIFY_SETTINGS_FILE"
assert_equals "$(normalize completed '{"hook_event_name":"Stop","session_id":"session-e","cwd":"/work/project","background_tasks":[],"last_assistant_message":"malformed"}')" \
  '{"source":"claude-code","kind":"completed","session_id":"session-e","session_dir":"/work/project","excerpt":"malformed"}'
/bin/rm -f "$AGENT_NOTIFY_SETTINGS_FILE"

print -- 'Claude hook adapter tests passed'
