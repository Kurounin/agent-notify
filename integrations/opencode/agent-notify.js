const SOURCE = "opencode";
const MAX_IDENTIFIER_LENGTH = 256;
const MAX_PAYLOAD_BYTES = 2048;
const SUBPROCESS_TIMEOUT_MS = 5000;
const NORMALIZED_EVENT_KINDS = new Set([
  "began",
  "attention",
  "attention-cleared",
  "completed",
  "failed",
]);

export const LEGACY_ATTENTION_EVENTS = Object.freeze([
  "permission.asked",
  "permission.replied",
  "question.asked",
  "question.replied",
  "question.rejected",
]);

function boundedIdentifier(value) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_IDENTIFIER_LENGTH ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    return undefined;
  }

  return value;
}

function boundedDirectory(value) {
  return boundedIdentifier(value);
}

function boundedRequestID(value) {
  return value === "" ? "" : boundedIdentifier(value);
}

function attentionKey(eventType, requestID) {
  return `${eventType.startsWith("permission.") ? "permission" : "question"}:${requestID}`;
}

function sessionIDFrom(event) {
  return boundedIdentifier(event?.properties?.sessionID);
}

function requestIDFrom(event) {
  const properties = event?.properties;
  return boundedIdentifier(event?.type?.endsWith(".asked") ? properties?.id : properties?.requestID);
}

function terminalError(event) {
  const error = event?.properties?.error;
  if (!error || typeof error !== "object") return false;

  if (
    error.name === "MessageAbortedError" ||
    error.name === "AbortError" ||
    error.name === "UserAbortError" ||
    error.name === "ToolError" ||
    error.isRetryable === true ||
    error.isRecoverable === true ||
    error.data?.isRetryable === true ||
    error.data?.isRecoverable === true
  ) return false;
  if (error.name === "APIError") return error.data?.isRetryable === false;

  return error.name === "ProviderAuthError" ||
    error.name === "UnknownError" ||
    error.name === "MessageOutputLengthError" ||
    error.name === "StructuredOutputError" ||
    error.name === "ContextOverflowError" ||
    error.name === "ContentFilterError";
}

function encodeEvent(event) {
  if (event?.source !== SOURCE || !NORMALIZED_EVENT_KINDS.has(event.kind)) return undefined;

  const sessionID = boundedIdentifier(event.session_id);
  const sessionDir = boundedDirectory(event.session_dir);
  const requestID = event.request_id === undefined ? "" : boundedRequestID(event.request_id);
  if (!sessionID || !sessionDir || requestID === undefined) return undefined;
  if ((event.kind === "attention" || event.kind === "attention-cleared") && !requestID) return undefined;

  const normalized = {
    source: SOURCE,
    event: event.kind,
    session_id: sessionID,
    session_dir: sessionDir,
    request_id: requestID,
  };

  const encoded = JSON.stringify(normalized);
  if (new TextEncoder().encode(encoded).byteLength > MAX_PAYLOAD_BYTES) return undefined;
  return encoded;
}

export function createBinarySubmitter({
  spawn = globalThis.Bun?.spawn,
  binary = "agent-notify",
  timeoutMs = SUBPROCESS_TIMEOUT_MS,
} = {}) {
  return async (event) => {
    const input = encodeEvent(event);
    if (!input || typeof spawn !== "function") return;

    try {
      const process = spawn([binary, "event"], {
        stdin: new TextEncoder().encode(input),
        stdout: "ignore",
        stderr: "ignore",
      });
      const timeout = setTimeout(() => process.kill(), timeoutMs);
      try {
        await process.exited;
      } finally {
        clearTimeout(timeout);
      }
    } catch {
      // Notifications are advisory and must not affect OpenCode execution.
    }
  };
}

export function createOpenCodeAdapter({ client, submit = createBinarySubmitter() }) {
  const activeTurns = new Set();
  const terminatedTurns = new Set();
  const attention = new Map();

  async function lookup(sessionID) {
    try {
      const result = await client.session.get({ path: { id: sessionID } });
      return boundedDirectory(result?.data?.directory);
    } catch {
      return undefined;
    }
  }

  async function notify(kind, sessionID, sessionDir, requestID = "") {
    await submit({
      source: SOURCE,
      kind,
      session_id: sessionID,
      session_dir: sessionDir,
      request_id: requestID,
    });
  }

  return {
    async event({ event }) {
      const sessionID = sessionIDFrom(event);
      if (!sessionID) return;

      if (event.type === "session.status") {
        if (event.properties?.status?.type === "busy") {
          if (activeTurns.has(sessionID)) return;
          terminatedTurns.delete(sessionID);
          activeTurns.add(sessionID);
          const directory = await lookup(sessionID);
          if (!directory) {
            activeTurns.delete(sessionID);
            return;
          }
          if (!activeTurns.has(sessionID)) return;
          await notify("began", sessionID, directory);
          return;
        }

        if (event.properties?.status?.type === "idle" && activeTurns.has(sessionID)) {
          activeTurns.delete(sessionID);
          attention.delete(sessionID);
          const directory = await lookup(sessionID);
          if (directory) await notify("completed", sessionID, directory);
        }
        return;
      }

      if (event.type === "session.error") {
        if (!terminalError(event) || terminatedTurns.has(sessionID)) return;

        terminatedTurns.add(sessionID);
        activeTurns.delete(sessionID);
        attention.delete(sessionID);
        const directory = await lookup(sessionID);
        if (directory) await notify("failed", sessionID, directory);
        return;
      }

      if (!LEGACY_ATTENTION_EVENTS.includes(event.type)) return;

      const requestID = requestIDFrom(event);
      if (!requestID) return;
      const directory = await lookup(sessionID);
      if (!directory) return;

      const key = attentionKey(event.type, requestID);
      if (event.type.endsWith(".asked")) {
        const requests = attention.get(sessionID) ?? new Set();
        if (requests.has(key)) return;
        requests.add(key);
        attention.set(sessionID, requests);
        await notify("attention", sessionID, directory, requestID);
        return;
      }

      const requests = attention.get(sessionID);
      if (requests?.delete(key)) {
        if (requests.size === 0) attention.delete(sessionID);
        await notify("attention-cleared", sessionID, directory, requestID);
      }
    },
  };
}

export default async function agentNotifyPlugin({ client }) {
  return createOpenCodeAdapter({ client });
}
