#!/usr/bin/env zsh

setopt no_unset pipe_fail

typeset notifier_bin=${AGENT_NOTIFY_BIN:-agent-notify}
typeset raw normalized

raw=$(command /bin/cat) || exit 0
normalized=$(print -rn -- "$raw" | /usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation");

const text = $.NSString.alloc.initWithDataEncoding(
  $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile,
  $.NSUTF8StringEncoding
).js;

let payload;
try {
  payload = JSON.parse(text);
} catch (_) {
  $.exit(1);
}

if (!payload || typeof payload !== "object" || Array.isArray(payload)) $.exit(1);

let agentType = payload.agent_type;
if (agentType === undefined) agentType = payload.agentType;
if (agentType === undefined && payload.agent && typeof payload.agent === "object") {
  agentType = payload.agent.type;
}
if (payload.is_background === true || payload.background === true || payload.is_subagent === true) $.exit(1);
if (agentType !== undefined && agentType !== null && agentType !== "" &&
  agentType !== "main" && agentType !== "main_agent") $.exit(1);

const validString = (value) => typeof value === "string" && value.length > 0 &&
  value.length <= 256 && !/[\u0000-\u001f\u007f]/.test(value);
if (!validString(payload.session_id) || !validString(payload.cwd)) $.exit(1);

let event;
let requestID;
switch (payload.hook_event_name) {
  case "UserPromptSubmit":
    event = "began";
    break;
  case "Stop":
    event = "completed";
    break;
  case "StopFailure":
    event = "failed";
    break;
  case "Notification": {
    const allowedNotifications = new Set([
      "permission_prompt",
      "elicitation_dialog",
      "elicitation_url_dialog",
    ]);
    if (!allowedNotifications.has(payload.notification_type)) $.exit(1);
    event = "attention";
    requestID = validString(payload.notification_id)
      ? payload.notification_id
      : payload.notification_type;
    break;
  }
  default:
    $.exit(1);
}

const normalized = {
  source: "claude-code",
  event,
  session_id: payload.session_id,
  session_dir: payload.cwd,
};
if (requestID !== undefined) normalized.request_id = requestID;
JSON.stringify(normalized);
' 2>/dev/null) || exit 0

[[ -n $normalized ]] || exit 0
print -rn -- "$normalized" | "$notifier_bin" event >/dev/null 2>&1 || true
