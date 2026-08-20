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

const LEGACY_ATTENTION_EVENTS = Object.freeze([
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

function createBinarySubmitter({
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

function createOpenCodeAdapter({ client, submit = createBinarySubmitter() }) {
  const activeTurns = new Set();
  const terminatedTurns = new Set();
  const attention = new Map();
  const sessionTrees = new Map();
  const sessionRoots = new Map();

  async function lookup(sessionID) {
    try {
      const result = await client.session.get({ path: { id: sessionID } });
      const details = result?.data;
      const directory = boundedDirectory(details?.directory);
      const parentValue = details?.parentID;
      const parentID = parentValue === null || parentValue === undefined
        ? undefined
        : boundedIdentifier(parentValue);
      // OpenCode omits parentID entirely for root sessions, so an absent key means root.
      const treeMetadata = Boolean(
        directory &&
        (parentValue === null || parentValue === undefined || (parentID && parentID !== sessionID)),
      );
      return { directory, parentID, treeMetadata };
    } catch {
      return { directory: undefined, treeMetadata: false };
    }
  }

  function removeTree(rootID) {
    const tree = sessionTrees.get(rootID);
    if (!tree) return;

    for (const sessionID of tree.keys()) sessionRoots.delete(sessionID);
    sessionTrees.delete(rootID);
  }

  function mergeTree(fromRootID, toRootID) {
    if (fromRootID === toRootID) return;

    const fromTree = sessionTrees.get(fromRootID);
    if (!fromTree) return;

    const toTree = sessionTrees.get(toRootID) ?? new Map();
    for (const [sessionID, session] of fromTree) {
      if (!toTree.has(sessionID)) toTree.set(sessionID, session);
      sessionRoots.set(sessionID, toRootID);
    }
    sessionTrees.set(toRootID, toTree);
    sessionTrees.delete(fromRootID);
  }

  function recordSession(sessionID, details, status) {
    const rootID = details.parentID
      ? sessionRoots.get(details.parentID) ?? details.parentID
      : sessionID;
    const previousRootID = sessionRoots.get(sessionID);
    if (previousRootID && previousRootID !== rootID) {
      mergeTree(previousRootID, rootID);
    }
    if (sessionID !== rootID && sessionTrees.has(sessionID)) {
      mergeTree(sessionID, rootID);
    }

    const tree = sessionTrees.get(rootID) ?? new Map();
    const previous = tree.get(sessionID);
    tree.set(sessionID, {
      directory: details.directory,
      parentID: details.parentID,
      status,
      pending: status === "busy" || status === "retry" ? false : previous?.pending,
    });
    sessionTrees.set(rootID, tree);
    sessionRoots.set(sessionID, rootID);
    return rootID;
  }

  function hasPendingCompletion(sessionID) {
    return sessionTrees.get(sessionID)?.get(sessionID)?.pending === true;
  }

  async function completePendingRoot(rootID) {
    const tree = sessionTrees.get(rootID);
    const root = tree?.get(rootID);
    if (!root?.pending || root.status !== "idle") return;

    for (const [sessionID, session] of tree) {
      if (sessionID !== rootID && (session.status === "busy" || session.status === "retry")) return;
    }

    root.pending = false;
    await notify("completed", rootID, root.directory);
    removeTree(rootID);
  }

  function pruneSettledTree(rootID) {
    const tree = sessionTrees.get(rootID);
    if (!tree) return;

    const root = tree.get(rootID);
    const hasActiveSession = [...tree.values()].some(
      (session) => session.status === "busy" || session.status === "retry",
    );
    if (!root?.pending && !hasActiveSession) removeTree(rootID);
  }

  async function fallBackToSessionLifecycle(sessionID, details, status) {
    const rootID = sessionRoots.get(sessionID);
    const session = rootID ? sessionTrees.get(rootID)?.get(sessionID) : undefined;
    const directory = details.directory ?? session?.directory;

    if (session) {
      if (directory) session.directory = directory;

      if (status === "busy" || status === "retry") {
        session.status = status;
        if (status !== "busy" || activeTurns.has(sessionID)) return;

        terminatedTurns.delete(sessionID);
        activeTurns.add(sessionID);
        if (!directory) {
          activeTurns.delete(sessionID);
          return;
        }
        if (sessionID === rootID && !session.pending) await notify("began", sessionID, directory);
        return;
      }

      if (status === "idle") {
        session.status = "idle";
        const wasActive = activeTurns.delete(sessionID);
        if (wasActive) attention.delete(sessionID);
        if (sessionID === rootID) {
          if (!wasActive && session.pending) return;
          removeTree(rootID);
          if (wasActive && directory) await notify("completed", sessionID, directory);
          return;
        }
        await completePendingRoot(rootID);
        pruneSettledTree(rootID);
      }
      return;
    }

    if (status === "busy") {
      if (activeTurns.has(sessionID)) return;
      terminatedTurns.delete(sessionID);
      activeTurns.add(sessionID);
      if (!directory) {
        activeTurns.delete(sessionID);
        return;
      }
      await notify("began", sessionID, directory);
      return;
    }

    if (status === "idle" && activeTurns.has(sessionID)) {
      activeTurns.delete(sessionID);
      attention.delete(sessionID);
      if (directory) await notify("completed", sessionID, directory);
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
        const status = event.properties?.status?.type;
        const details = await lookup(sessionID);
        if (!details.treeMetadata) {
          await fallBackToSessionLifecycle(sessionID, details, status);
          return;
        }

        const isTracked = sessionRoots.has(sessionID);
        if (
          status !== "busy" &&
          status !== "retry" &&
          (status !== "idle" || (!isTracked && !activeTurns.has(sessionID)))
        ) return;

        // A background task waking its root resumes the turn the user is still waiting on, so the
        // turn must not restart: the notifier times a completion from the began it last recorded.
        const resumesPendingTurn = hasPendingCompletion(sessionID);
        const rootID = recordSession(sessionID, details, status);
        if (status === "busy") {
          if (activeTurns.has(sessionID)) return;
          terminatedTurns.delete(sessionID);
          activeTurns.add(sessionID);
          if (sessionID === rootID && !resumesPendingTurn) await notify("began", sessionID, details.directory);
          return;
        }

        if (status === "idle") {
          const wasActive = activeTurns.delete(sessionID);
          if (wasActive) attention.delete(sessionID);
          if (sessionID === rootID) {
            const session = sessionTrees.get(rootID)?.get(sessionID);
            if (wasActive) session.pending = true;
          }
          await completePendingRoot(rootID);
          pruneSettledTree(rootID);
        }
        return;
      }

      if (event.type === "session.error") {
        if (!terminalError(event) || terminatedTurns.has(sessionID)) return;

        terminatedTurns.add(sessionID);
        activeTurns.delete(sessionID);
        attention.delete(sessionID);
        const details = await lookup(sessionID);
        const rootID = sessionRoots.get(sessionID);
        const session = rootID ? sessionTrees.get(rootID)?.get(sessionID) : undefined;
        const directory = details.directory ?? session?.directory;
        if (details.treeMetadata) {
          const trackedRootID = recordSession(sessionID, details, "terminal");
          if (details.directory) await notify("failed", sessionID, details.directory);
          if (sessionID === trackedRootID) removeTree(trackedRootID);
          else {
            await completePendingRoot(trackedRootID);
            pruneSettledTree(trackedRootID);
          }
          return;
        }

        if (session) {
          session.status = "terminal";
          if (directory) await notify("failed", sessionID, directory);
          if (sessionID === rootID) removeTree(rootID);
          else {
            await completePendingRoot(rootID);
            pruneSettledTree(rootID);
          }
          return;
        }

        if (directory) await notify("failed", sessionID, directory);
        return;
      }

      if (!LEGACY_ATTENTION_EVENTS.includes(event.type)) return;

      const requestID = requestIDFrom(event);
      if (!requestID) return;
      const { directory } = await lookup(sessionID);
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

export default async function agentNotifyPlugin({ client, submit }) {
  return createOpenCodeAdapter({ client, submit });
}
