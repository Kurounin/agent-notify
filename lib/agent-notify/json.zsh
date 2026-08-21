# JXA is the selected built-in JSON implementation: it validates both Claude settings documents and event input.
typeset -ga AGENT_NOTIFY_EVENT_FIELDS
agent_notify_normalize_json() {
  local raw=$1
  print -rn -- "$raw" | "$AGENT_NOTIFY_JXA_BIN" -l JavaScript -e '
ObjC.import("Foundation");
const input = $.NSString.alloc.initWithDataEncoding(
  $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile,
  $.NSUTF8StringEncoding).js;
let value;
try { value = JSON.parse(input); } catch (_) { $.exit(1); }
if (!value || typeof value !== "object" || Array.isArray(value)) $.exit(1);
const allowedSources = new Set(["claude-code", "opencode"]);
const allowedKinds = new Set(["began", "attention", "attention-cleared", "completed", "failed", "reset"]);
const validString = (v, required) => typeof v === "string" && (required ? v.length > 0 : true) && v.length <= 256 && !/[\u0000-\u001f\u007f]/.test(v);
const kind = value.kind === undefined ? value.event : value.kind;
if (!allowedSources.has(value.source) || !allowedKinds.has(kind) || !validString(value.session_id, true)) $.exit(1);
if (value.event !== undefined && value.event !== kind) $.exit(1);
const sessionDir = value.session_dir === undefined ? "" : value.session_dir;
const requestId = value.request_id === undefined ? "" : value.request_id;
if (!validString(sessionDir, false) || !validString(requestId, false)) $.exit(1);
if ((kind === "attention" || kind === "attention-cleared") && !validString(requestId, true)) $.exit(1);
// The excerpt is the only field that fails open: an invalid one is dropped by itself so the event
// still reaches delivery carrying the message it would have had before excerpts existed. Its
// rejected set is wider than validString because C1, NEL, LS, and PS are line breaks curl refuses.
const excerptControl = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029]");
const excerpt = validString(value.excerpt, true) && !excerptControl.test(value.excerpt) ? value.excerpt : "";
JSON.stringify({source:value.source,kind:kind,session_id:value.session_id,session_dir:sessionDir,request_id:requestId,excerpt:excerpt});
' 2>/dev/null
}

agent_notify_validate_json_document() {
  local raw=$1
  print -rn -- "$raw" | "$AGENT_NOTIFY_JXA_BIN" -l JavaScript -e '
ObjC.import("Foundation");
const input = $.NSString.alloc.initWithDataEncoding($.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding).js;
try { const value = JSON.parse(input); if (!value || typeof value !== "object" || Array.isArray(value)) $.exit(1); } catch (_) { $.exit(1); }
true;
' 2>/dev/null >/dev/null
}

agent_notify_event_fields() {
  local normalized_json=$1 encoded delimiters line
  encoded=$(print -rn -- "$normalized_json" | "$AGENT_NOTIFY_JXA_BIN" -l JavaScript -e '
ObjC.import("Foundation");
const text = $.NSString.alloc.initWithDataEncoding($.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding).js;
let value; try { value = JSON.parse(text); } catch (_) { $.exit(1); }
const b64 = (s) => $.NSString.alloc.initWithString(s).dataUsingEncoding($.NSUTF8StringEncoding).base64EncodedStringWithOptions(0).js;
const excerpt = typeof value.excerpt === "string" ? value.excerpt : "";
[value.source, value.kind, value.session_id, value.session_dir, value.request_id, excerpt].map(b64).join(":");
' 2>/dev/null) || return 1
  local field_one field_two field_three field_four field_five field_six
  local -a fields
  # base64 emits neither a colon nor IFS whitespace, so the delimiter count is the field count and
  # an empty field such as an absent request_id keeps its own position instead of collapsing.
  delimiters=${encoded//[^:]/}
  (( ${#delimiters} == 5 )) || return 1
  IFS=':' read -r field_one field_two field_three field_four field_five field_six <<< "$encoded" || return 1
  fields=("$field_one" "$field_two" "$field_three" "$field_four" "$field_five" "$field_six")
  AGENT_NOTIFY_EVENT_FIELDS=()
  for line in "${fields[@]}"; do
    AGENT_NOTIFY_EVENT_FIELDS+=("$(print -rn -- "$line" | /usr/bin/base64 -D)") || return 1
  done
}
