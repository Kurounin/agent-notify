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
unset TMUX TMUX_PANE AGENT_NOTIFY_TMUX_PATH

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

normalize_fragmented() {
  { print -rn -- "$2"; /bin/sleep 0.05; print -rn -- "$3"; } |
    /usr/bin/osascript -l JavaScript "$normalizer" "$1"
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

# The stubbed notifier above cannot show what a dropped Stop does, so this case runs the real one beside the adapter.
typeset pipeline_root="$test_root/pipeline" pipeline_state="$test_root/pipeline-state" pipeline_diagnostics="$test_root/pipeline-diagnostics" pipeline_log
/bin/mkdir -p "$pipeline_root/bin" "$pipeline_root/lib"
/bin/cp "$adapter_source" "$pipeline_root/bin/agent-notify-claude-hook"
/bin/cp "$normalizer" "$pipeline_root/bin/agent-notify-claude-hook.jxa"
/bin/cp "$root/bin/agent-notify" "$pipeline_root/bin/agent-notify"
/bin/cp -R "$root/lib/agent-notify" "$pipeline_root/lib/agent-notify"
/bin/chmod 700 "$pipeline_root/bin/agent-notify-claude-hook" "$pipeline_root/bin/agent-notify"
submit_pipeline() {
  AGENT_NOTIFY_STATE_DIR="$pipeline_state" AGENT_NOTIFY_DIAGNOSTIC_DIR="$pipeline_diagnostics" AGENT_NOTIFY_KEYCHAIN_RUNTIME_HELPER=/nonexistent \
    "$pipeline_root/bin/agent-notify-claude-hook" "$1"
}
submit_pipeline began <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"session-dropped","cwd":"/work/project"}
EOF
submit_pipeline completed <<'EOF'
{"hook_event_name":"Stop","session_id":"session-dropped","cwd":"/work/project","background_tasks":[{"id":"task-1","type":"shell","status":"running","description":"sleep 40","command":"sleep 40"}]}
EOF
pipeline_log=$(/bin/cat /dev/null "$pipeline_diagnostics"/*.log(N))
[[ $pipeline_log == *'component=normalize code=adapter_ignored '* ]] || { print -u2 -- 'a dropped Stop was not recorded as adapter_ignored'; exit 1; }
[[ $pipeline_log != *invalid_event* ]] || { print -u2 -- 'a dropped Stop was recorded as a malformed event'; exit 1; }
typeset -a pipeline_states
pipeline_states=("$pipeline_state"/*.state(N))
assert_equals "${#pipeline_states}" 1
[[ $(<"$pipeline_states[1]") == *$'ACTIVE=1\n'* && $(<"$pipeline_states[1]") == *$'\nTERMINAL=\n'* ]] || { print -u2 -- 'a dropped Stop closed the open turn'; exit 1; }

typeset settled_completion
settled_completion=$(normalize completed '{"hook_event_name":"Stop","session_id":"session-a","cwd":"/work/project","background_tasks":[]}')
assert_equals "$settled_completion" '{"source":"claude-code","kind":"completed","session_id":"session-a","session_dir":"/work/project"}'

typeset fragmented_completion
fragmented_completion=$(normalize_fragmented completed \
  '{"hook_event_name":"Stop","session_id":"session-fragmented",' \
  '"cwd":"/work/project","background_tasks":[]}')
assert_equals "$fragmented_completion" '{"source":"claude-code","kind":"completed","session_id":"session-fragmented","session_dir":"/work/project"}'

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

typeset project_root
project_root=$(CLAUDE_PROJECT_DIR='/work/session-root' normalize completed '{"hook_event_name":"Stop","session_id":"session-root","cwd":"/work/changed","background_tasks":[]}')
assert_equals "$project_root" '{"source":"claude-code","kind":"completed","session_id":"session-root","session_dir":"/work/session-root"}'
assert_equals "$(CLAUDE_PROJECT_DIR='' normalize completed '{"hook_event_name":"Stop","session_id":"session-root","session_dir":"/work/payload","cwd":"/work/changed","background_tasks":[]}')" \
  '{"source":"claude-code","kind":"completed","session_id":"session-root","session_dir":"/work/payload"}'
assert_equals "$(CLAUDE_PROJECT_DIR=$'bad\x7froot' normalize completed '{"hook_event_name":"Stop","session_id":"session-root","session_dir":"bad\u0000dir","cwd":"/work/later","background_tasks":[]}')" \
  '{"source":"claude-code","kind":"completed","session_id":"session-root","session_dir":"/work/later"}'
typeset oversized_project=${(l:257::x:)${:-x}}
assert_equals "$(CLAUDE_PROJECT_DIR="$oversized_project" normalize completed '{"hook_event_name":"Stop","session_id":"session-root","session_dir":"/work/payload","background_tasks":[]}')" \
  '{"source":"claude-code","kind":"completed","session_id":"session-root","session_dir":"/work/payload"}'
assert_ignored completed '{"hook_event_name":"Stop","session_id":"session-root","session_dir":"","cwd":"bad\u0001dir","directory":"bad\u007fdir","background_tasks":[]}' 'payload with no valid directory candidates'

# Reading a zero-argument bridge method already calls it, so parentheses run it and then throw. A throw here costs the event, and the catch block can hide one call site's mistake from the cases below.
[[ $(<"$normalizer") != *'.terminate()'* ]] || { print -u2 -- 'normalizer calls terminate with parentheses'; exit 1; }

# All tmux cases use an injected executable; no test contacts a live tmux server.
typeset tmux_dir="$test_root/tmux executable"
typeset tmux_fake="$tmux_dir/tmux"
typeset tmux_calls="$test_root/tmux-calls"
typeset unresponsive_pane="%$$"
/bin/mkdir -p "$tmux_dir"
cat > "$tmux_fake" <<'EOF'
#!/usr/bin/env zsh
setopt no_unset pipe_fail
print -r -- "$*" >> "$AGENT_NOTIFY_TMUX_CALLS"
print -u2 -r -- "${AGENT_NOTIFY_TMUX_STDERR:-}"
case ${AGENT_NOTIFY_TMUX_MODE:-valid} in
  valid) print -r -- "${AGENT_NOTIFY_TMUX_VALUE:-session-one}" ;;
  nonzero) print -r -- rejected-stdout; exit 7 ;;
  timeout) while true; do /bin/sleep 1; done ;;
  overflow) /usr/bin/yes x | /usr/bin/head -c 1025; while true; do /bin/sleep 1; done ;;
  overflow_ignoring_term) trap '' TERM; /usr/bin/yes x | /usr/bin/head -c 1025; /bin/sleep 2 ;;
  output_1024) /usr/bin/yes x | /usr/bin/head -c 1024 || true ;;
  descendant_holds_stdout) (/bin/sleep 2; print -r -- descendant-stdout-marker) & exit 0 ;;
  invalid_utf8) print -rn -- $'\xff' ;;
  closed_stdout) exec 1>&- ;;
  multiline) print -r -- $'one\ntwo' ;;
  control) print -r -- $'bad\x01name' ;;
  signaled) kill -TERM $$ ;;
esac
EOF
/bin/chmod 700 "$tmux_fake"

submit_tmux() {
  AGENT_NOTIFY_TEST_CALLS="$calls" AGENT_NOTIFY_TMUX_CALLS="$tmux_calls" \
    PATH="$tmux_dir:$PATH" TMUX='private-socket-marker' TMUX_PANE="${AGENT_NOTIFY_TEST_TMUX_PANE:-%123}" "$adapter" "$1"
}
# A child that misses the normalizer's 0.5-second deadline is correctly left out of the event, so on a busy machine a lookup that should succeed gets a few tries. One that can never succeed still fails the assertion after this.
submit_tmux_expecting_session() {
  local payload attempt
  payload=$(</dev/stdin)
  for (( attempt = 0; attempt < 5; attempt++ )); do
    /bin/rm -f "$calls" "$tmux_calls"
    submit_tmux "$1" <<<"$payload"
    [[ $(<"$calls") == *'"tmux_session"'* ]] && return 0
  done
}
# A failed lookup only costs the session name: the event must still be submitted.
assert_no_tmux_session() {
  [[ $(<"$calls") == 'event|{"source":"claude-code",'* ]] || { print -u2 -- "expected '$1' to submit the event"; exit 1; }
  [[ $(<"$calls") != *'"tmux_session"'* ]] || { print -u2 -- "expected '$1' to have no tmux session"; exit 1; }
}
zmodload zsh/datetime
# assert_lookup_bounded <name> <mode>: the child in these modes holds the lookup open for 2 seconds, so a hook that waits for it takes at least that long. Load can only add time, so the best of a few tries measures the deadline and not the machine.
assert_lookup_bounded() {
  local attempt output
  local -F 6 start elapsed
  for (( attempt = 0; attempt < 5; attempt++ )); do
    /bin/rm -f "$calls" "$tmux_calls"
    start=$EPOCHREALTIME
    output=$(AGENT_NOTIFY_TMUX_MODE=$2 submit_tmux completed <<'EOF' 2>&1
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
)
    elapsed=$(( EPOCHREALTIME - start ))
    (( elapsed < 1.5 )) && break
  done
  (( elapsed < 1.5 )) || { print -u2 -- "$1 exceeded deadline: $elapsed seconds"; exit 1; }
  assert_equals "$output" ''
  assert_no_tmux_session "$1"
}
# The timeout and overflow modes never exit on their own, so the child being gone proves it was terminated. A marker from a TERM trap cannot show this: on a busy machine the deadline can pass before the child has set the trap, and zsh runs a trap that arrives while it starts a command only once that command exits. The normalizer also signals the child and moves on, so it can briefly outlive the hook.
assert_child_terminated() {
  local attempt pgrep_status pattern="display-message -p -t $unresponsive_pane #S"
  for (( attempt = 0; attempt < 100; attempt++ )); do
    pgrep_status=0
    /usr/bin/pgrep -f "$pattern" >/dev/null || pgrep_status=$?
    (( pgrep_status == 1 )) && return 0
    (( pgrep_status == 0 )) || break
    /bin/sleep 0.1
  done
  /usr/bin/pkill -KILL -f "$pattern" || true
  print -u2 -- "$1 did not request child termination"
  exit 1
}

/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TMUX_MODE=valid AGENT_NOTIFY_TMUX_VALUE='renamed-session' submit_tmux_expecting_session completed <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
assert_equals "$(<"$calls")" 'event|{"source":"claude-code","kind":"completed","session_id":"session-tmux","session_dir":"/work/project","tmux_session":"renamed-session"}'
assert_equals "$(<"$tmux_calls")" 'display-message -p -t %123 #S'

# The lookup is fresh per notification-producing event, not cached from the earlier name.
/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TMUX_MODE=valid AGENT_NOTIFY_TMUX_VALUE='renamed-again' submit_tmux_expecting_session attention <<'EOF'
{"notification_type":"permission_prompt","session_id":"session-tmux","cwd":"/work/project"}
EOF
[[ $(<"$calls") == *'"tmux_session":"renamed-again"'* ]] || { print -u2 -- 'tmux name was not refreshed per event'; exit 1; }

typeset pane_255="%${(l:255::7:)${:-7}}"
typeset pane_256="%${(l:256::7:)${:-7}}"
/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TEST_TMUX_PANE="$pane_255" AGENT_NOTIFY_TMUX_MODE=valid AGENT_NOTIFY_TMUX_VALUE='pane-boundary' submit_tmux_expecting_session completed <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
assert_equals "$(<"$tmux_calls")" "display-message -p -t $pane_255 #S"
[[ $(<"$calls") == *'"tmux_session":"pane-boundary"'* ]] || { print -u2 -- '255-digit TMUX_PANE did not launch tmux'; exit 1; }

/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TEST_TMUX_PANE="$pane_256" AGENT_NOTIFY_TMUX_MODE=valid submit_tmux completed <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
[[ ! -e $tmux_calls ]] || { print -u2 -- '256-digit TMUX_PANE launched tmux'; exit 1; }
assert_no_tmux_session '256-digit TMUX_PANE'

# began is a lifecycle event but does not produce a notification, so it cannot launch tmux.
/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TMUX_MODE=valid submit_tmux began <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project"}
EOF
[[ ! -e $tmux_calls ]] || { print -u2 -- 'began launched tmux'; exit 1; }
assert_no_tmux_session 'began'

for mode in nonzero invalid_utf8 closed_stdout multiline control signaled; do
  /bin/rm -f "$calls" "$tmux_calls"
  AGENT_NOTIFY_TMUX_MODE="$mode" submit_tmux completed <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
  assert_no_tmux_session "$mode"
done

# A launch failure remains advisory and must not reveal the unavailable executable path or tmux data.
typeset launch_failure_output
launch_failure_output=$(TMUX='private-socket-marker' TMUX_PANE='%123' AGENT_NOTIFY_TMUX_PATH="$tmux_dir/missing-tmux" \
  /usr/bin/osascript -l JavaScript "$normalizer" completed <<'EOF' 2>&1
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
)
assert_equals "$launch_failure_output" '{"source":"claude-code","kind":"completed","session_id":"session-tmux","session_dir":"/work/project"}'
[[ $launch_failure_output != *'private-'* && $launch_failure_output != *'missing-tmux'* ]] || { print -u2 -- 'tmux launch failure leaked raw data'; exit 1; }

/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TEST_TMUX_PANE="$unresponsive_pane" AGENT_NOTIFY_TMUX_MODE=timeout submit_tmux completed <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
assert_no_tmux_session 'timeout'
assert_child_terminated 'timeout'

/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TEST_TMUX_PANE="$unresponsive_pane" AGENT_NOTIFY_TMUX_MODE=overflow submit_tmux completed <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
assert_no_tmux_session 'overflow'
assert_child_terminated 'overflow'

# A child that ignores the signal is still running when the normalizer checks it, and must neither cost the event nor hold the hook. It exits by itself.
assert_lookup_bounded 'overflow with a child ignoring termination' overflow_ignoring_term

/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TMUX_MODE=output_1024 submit_tmux completed <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
assert_no_tmux_session '1024-byte tmux output'

# A direct child can exit successfully while a descendant keeps the stdout pipe open. The hook
# must treat process exit and stdout EOF as one deadline-bound operation without forwarding output.
assert_lookup_bounded 'descendant-held stdout' descendant_holds_stdout
[[ $(<"$calls") != *'descendant-stdout-marker'* ]] || { print -u2 -- 'descendant stdout leaked to submitted event'; exit 1; }

# Invalid gates do not launch the injected executable or leak their raw marker values.
/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TEST_CALLS="$calls" AGENT_NOTIFY_TMUX_CALLS="$tmux_calls" PATH="$tmux_dir:$PATH" TMUX='' TMUX_PANE='%123' "$adapter" completed <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
[[ ! -e $tmux_calls ]] || { print -u2 -- 'empty TMUX launched tmux'; exit 1; }
assert_no_tmux_session 'empty TMUX'

/bin/rm -f "$calls" "$tmux_calls"
AGENT_NOTIFY_TEST_CALLS="$calls" AGENT_NOTIFY_TMUX_CALLS="$tmux_calls" PATH="$tmux_dir:$PATH" TMUX='private-socket-marker' TMUX_PANE='private-pane-marker' "$adapter" completed <<'EOF'
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
[[ ! -e $tmux_calls ]] || { print -u2 -- 'invalid TMUX_PANE launched tmux'; exit 1; }
assert_no_tmux_session 'invalid TMUX_PANE'
[[ $(<"$calls") != *'private-socket-marker'* && $(<"$calls") != *'private-pane-marker'* ]] || { print -u2 -- 'tmux environment marker leaked to submitted event'; exit 1; }

/bin/rm -f "$calls" "$tmux_calls"
typeset host_output
host_output=$(AGENT_NOTIFY_TEST_CALLS="$calls" AGENT_NOTIFY_TMUX_CALLS="$tmux_calls" AGENT_NOTIFY_TMUX_MODE=nonzero AGENT_NOTIFY_TMUX_STDERR='private-stderr-marker' PATH="$tmux_dir:$PATH" TMUX='private-socket-marker' TMUX_PANE='%123' "$adapter" completed <<'EOF' 2>&1
{"session_id":"session-tmux","cwd":"/work/project","background_tasks":[]}
EOF
)
assert_equals "$host_output" ''
[[ $(<"$calls") != *'private-'* && $(<"$calls") != *'rejected-stdout'* && $(<"$calls") != *'tmux executable'* ]] || { print -u2 -- 'raw tmux data leaked to submitted event'; exit 1; }

print -- 'Claude hook adapter tests passed'
