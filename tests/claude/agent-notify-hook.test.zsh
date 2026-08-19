#!/usr/bin/env zsh

setopt errexit no_unset pipe_fail

typeset root=${0:A:h:h:h}
typeset adapter="$root/integrations/claude/agent-notify-hook.zsh"
typeset template="$root/integrations/claude/settings.json.template"
typeset test_root
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-notify-claude-test.XXXXXX")
trap '/bin/rm -rf "$test_root"' EXIT

typeset mock_notifier="$test_root/mock-notifier.zsh"
typeset calls="$test_root/calls"

cat > "$mock_notifier" <<'EOF'
#!/usr/bin/env zsh
setopt no_unset pipe_fail
typeset payload
payload=$(command /bin/cat)
print -r -- "$*|$payload" >> "$AGENT_NOTIFY_TEST_CALLS"
EOF
/bin/chmod 700 "$mock_notifier"

assert_equals() {
  [[ $1 == "$2" ]] || { print -u2 -- "expected '$2', got '$1'"; exit 1; }
}

submit() {
  AGENT_NOTIFY_BIN="$mock_notifier" AGENT_NOTIFY_TEST_CALLS="$calls" "$adapter"
}

submit <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"session-a","cwd":"/work/project"}
EOF
submit <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"session-a","cwd":"/work/project"}
EOF
submit <<'EOF'
{"hook_event_name":"Stop","session_id":"session-a","cwd":"/work/project","agent_type":"main"}
EOF
submit <<'EOF'
{"hook_event_name":"StopFailure","session_id":"session-a","cwd":"/work/project","agent_type":"main_agent"}
EOF

assert_equals "$(<"$calls")" $'event|{"source":"claude-code","event":"began","session_id":"session-a","session_dir":"/work/project"}\nevent|{"source":"claude-code","event":"attention","session_id":"session-a","session_dir":"/work/project","request_id":"permission_prompt"}\nevent|{"source":"claude-code","event":"completed","session_id":"session-a","session_dir":"/work/project"}\nevent|{"source":"claude-code","event":"failed","session_id":"session-a","session_dir":"/work/project"}'

/bin/rm -f "$calls"
submit <<'EOF'
{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"session-b","cwd":"/work/project"}
EOF
submit <<'EOF'
{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"session-b","cwd":"/work/project","agent_type":"background"}
EOF
submit <<'EOF'
{"hook_event_name":"Notification","notification_type":"elicitation_dialog","session_id":"session-b","cwd":"/work/project","is_background":true}
EOF
submit <<'EOF'
{"hook_event_name":"Notification","notification_type":"elicitation_url_dialog","session_id":"session-b","cwd":"/work/project","is_subagent":true}
EOF
submit <<'EOF'
{"hook_event_name":"Stop","session_id":"session-b","cwd":"/work/project","agent_type":"subagent"}
EOF

[[ ! -e $calls ]] || { print -u2 -- 'ignored Claude hooks reached the notifier'; exit 1; }

template_summary=$(command /bin/cat "$template" | /usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation");
const input = $.NSString.alloc.initWithDataEncoding(
  $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile,
  $.NSUTF8StringEncoding
).js;
const settings = JSON.parse(input);
const expected = ["UserPromptSubmit", "Notification", "Stop", "StopFailure"];
if (JSON.stringify(Object.keys(settings.hooks)) !== JSON.stringify(expected)) $.exit(1);
const commands = expected.map((name) => settings.hooks[name][0].hooks[0].command);
if (!commands.every((command) => command === "__AGENT_NOTIFY_CLAUDE_HOOK__ # agent-notify:claude-hook")) $.exit(1);
if (settings.hooks.Notification[0].matcher !== "permission_prompt|elicitation_dialog|elicitation_url_dialog") $.exit(1);
JSON.stringify({ commands: commands.length, matcher: settings.hooks.Notification[0].matcher });
')
assert_equals "$template_summary" '{"commands":4,"matcher":"permission_prompt|elicitation_dialog|elicitation_url_dialog"}'

print -- 'Claude hook adapter tests passed'
