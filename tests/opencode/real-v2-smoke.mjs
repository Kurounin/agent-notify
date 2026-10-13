#!/usr/bin/env node
// Opt-in real-host check. No managed-service discovery, live-home writes, or models.
// Contracts: anomalyco/opencode tag v2.0.27, packages/{cli,core,schema,protocol,ai}.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { homedir, tmpdir, userInfo } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const VERSION = "opencode v2.0.27";
const TARBALL = "https://registry.npmjs.org/@opencode/cli-darwin-arm64/-/cli-darwin-arm64-2.0.27.tgz";
const INTEGRITY = "0BAaNYZE5QKve/7EFw9gyTQpkyOdff7Lj8Eul6FwK1vDnkj+yiVt/gdmJZl0PVoexl+6ZhjB7vuUPgSXrRATtA==";
const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const MAX_CAPTURE = 32_768;
let phase = "arguments";
let root;
let server;
let provider;
let streamController;
let streamTask;
let streamFailure = false;
let providerFailure = false;
let providerRequests = 0;
let lastHTTPStatus = 0;
const records = [];
const sessionStates = new Map();
const heldChildren = new Map();
let parentRequests = 0;
let resultConsumptions = 0;
let nativeParent;

function check(value) {
  if (!value) throw new Error("categorical check failed");
}

async function exists(target) {
  try {
    await lstat(target);
    return true;
  } catch (error) {
    if (error.code === "ENOENT" || error.code === "ENOTDIR") return false;
    throw new Error("existence check failed");
  }
}

async function checkIsolation(project) {
  // Presence (including a dangling symlink), not content, is all this check reads.
  for (const target of [
    "/Library/Application Support/opencode",
    "/etc/opencode",
    "/Library/Managed Preferences/ai.opencode.managed.plist",
    `/Library/Managed Preferences/${userInfo().username}/ai.opencode.managed.plist`,
  ]) check(!(await exists(target)));
  for (let directory = project; ; directory = path.dirname(directory)) {
    for (const name of ["opencode.json", "opencode.jsonc", ".opencode", ".claude", ".agents", "AGENTS.md", "CLAUDE.md"])
      check(!(await exists(path.join(directory, name))));
    if (path.dirname(directory) === directory) break;
  }
  check(root !== homedir() && !homedir().startsWith(`${root}${path.sep}`));
}

function run(binary, args, env, cwd) {
  const result = spawnSync(binary, args, { env, cwd, encoding: "utf8", timeout: 20_000, maxBuffer: 1_048_576 });
  check(result.status === 0);
  return result.stdout;
}

async function waitFor(predicate, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    check(!streamFailure && !providerFailure && (!server || server.exitCode === null));
    if (await predicate()) return;
    await delay(20);
  }
  throw new Error("bounded barrier timed out");
}

async function normalized() {
  const file = path.join(root, "normalized.ndjson");
  if (!(await exists(file))) return [];
  check((await stat(file)).size <= MAX_CAPTURE);
  return (await readFile(file, "utf8")).trim().split("\n").filter(Boolean).map((line) => {
    check(Buffer.byteLength(line) <= 2048);
    const event = JSON.parse(line);
    check(event.source === "opencode" && event.session_dir === path.join(root, "project"));
    check(!Object.hasOwn(event, "tmux_session"));
    check(["began", "completed", "reset", "failed", "attention", "attention-cleared"].includes(event.event));
    return event;
  });
}

function reply(response, { text, calls } = {}) {
  response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  const chunk = (delta, finish_reason = null) => response.write(`data: ${JSON.stringify({
    id: "fixture-completion", object: "chat.completion.chunk", created: 0, model: "fixture",
    choices: [{ index: 0, delta, finish_reason }],
  })}\n\n`);
  chunk({ role: "assistant" });
  if (calls) chunk({ tool_calls: calls.map((input, index) => ({
    index, id: `fixture-call-${index}`, type: "function", function: { name: "subagent", arguments: JSON.stringify(input) },
  })) });
  if (text) chunk({ content: text });
  chunk({}, calls ? "tool_calls" : "stop");
  response.end("data: [DONE]\n\n");
}

async function listenProvider() {
  provider = createServer(async (request, response) => {
    try {
      check(request.socket.remoteAddress === "127.0.0.1");
      check(request.method === "POST" && request.url === "/v1/chat/completions");
      const chunks = [];
      let size = 0;
      for await (const chunk of request) {
        size += chunk.length;
        check(size <= 2_097_152);
        chunks.push(chunk);
      }
      const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      providerRequests += 1;
      check(input.model === "fixture" && input.stream === true);
      // Only the first user message determines role. Root tool arguments also contain child markers.
      const firstUser = input.messages.find((message) => message.role === "user");
      const prompt = JSON.stringify(firstUser?.content);
      const child = prompt.includes("fixture-child-A") ? "A" : prompt.includes("fixture-child-B") ? "B" : undefined;
      if (child) {
        check(!heldChildren.has(child));
        heldChildren.set(child, response);
        return;
      }
      if (prompt.includes("fixture-native-parent")) {
        parentRequests += 1;
        if (parentRequests === 1) {
          check(input.tools.some((tool) => tool.function?.name === "subagent"));
          reply(response, { calls: ["A", "B"].map((suffix) => ({
            agent: "fixture-child", description: "Fixture background child", prompt: `fixture-child-${suffix}`, background: true,
          })) });
          return;
        }
        const transcript = JSON.stringify(input.messages);
        const consumed = ["fixture-result-A", "fixture-result-B"].filter((marker) => transcript.includes(marker)).length;
        resultConsumptions = Math.max(resultConsumptions, consumed);
        reply(response, { text: consumed === 2 ? "fixture-parent-final" : "fixture-parent-waiting" });
        return;
      }
      check(prompt.includes("fixture-loader"));
      reply(response, { text: "fixture-loader-complete" });
    } catch {
      providerFailure = true;
      response.writeHead(500);
      response.end();
    }
  });
  await new Promise((resolve, reject) => {
    provider.once("error", reject);
    provider.listen(0, "127.0.0.1", resolve);
  });
  return provider.address().port;
}

async function subscribe(url, headers) {
  streamController = new AbortController();
  const response = await fetch(`${url}/api/event`, { headers, signal: streamController.signal });
  check(response.ok);
  streamTask = (async () => {
    let pending = "";
    const decoder = new TextDecoder();
    for await (const chunk of response.body) {
      pending += decoder.decode(chunk, { stream: true }).replaceAll("\r\n", "\n");
      check(pending.length <= 262_144);
      let boundary;
      while ((boundary = pending.indexOf("\n\n")) !== -1) {
        const frame = pending.slice(0, boundary);
        pending = pending.slice(boundary + 2);
        const data = frame.split("\n").filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
        if (!data) continue;
        const event = JSON.parse(data);
        // Keep only fixture IDs, lifecycle types, and status. Never retain an event payload or output.
        if (!event.type?.startsWith("session.")) continue;
        const id = event.data?.sessionID;
        if (typeof id !== "string") continue;
        const state = sessionStates.get(id) ?? { started: 0, succeeded: 0, delivered: 0, idle: false };
        if (event.type === "session.execution.started") { state.started += 1; state.idle = false; }
        if (event.type === "session.execution.succeeded") state.succeeded += 1;
        if (event.type === "session.inbox.delivered") state.delivered += 1;
        if (event.type === "session.status") state.idle = event.data.status?.type === "idle";
        sessionStates.set(id, state);
        if (/^session\.(execution\.(started|succeeded|failed|interrupted)|inbox\.(enqueued|delivered)|status)$/.test(event.type)) {
          check(records.length < 256);
          records.push({ type: event.type, sessionID: id });
        }
      }
    }
    streamFailure = true;
  })().catch(() => { if (!streamController.signal.aborted) streamFailure = true; });
}

async function stopServer() {
  if (!server || server.exitCode !== null) return;
  const exited = new Promise((resolve) => server.once("exit", resolve));
  server.stdin.end();
  if (await Promise.race([exited.then(() => true), delay(5000).then(() => false)])) return;
  server.kill("SIGTERM");
  if (await Promise.race([exited.then(() => true), delay(5000).then(() => false)])) return;
  server.kill("SIGKILL");
  await exited;
}

async function main() {
  const args = process.argv.slice(2);
  check(process.platform === "darwin" && process.arch === "arm64");
  check(args[0] === "--download" || (args[0] === "--binary" && args.length === 2 && path.isAbsolute(args[1])));
  check(args.length === (args[0] === "--download" ? 1 : 2));
  process.umask(0o077);
  root = await realpath(await mkdtemp(path.join(tmpdir(), "opencode/agent-notify-v2-smoke.")));
  const project = path.join(root, "project");
  for (const directory of ["home", "config/opencode/plugins", "data", "cache", "state", "tmp", "project"])
    await mkdir(path.join(root, directory), { recursive: true, mode: 0o700 });
  phase = "machine-and-ancestor-isolation";
  await checkIsolation(project);
  const env = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin", HOME: path.join(root, "home"),
    XDG_CONFIG_HOME: path.join(root, "config"), XDG_DATA_HOME: path.join(root, "data"),
    XDG_STATE_HOME: path.join(root, "state"), XDG_CACHE_HOME: path.join(root, "cache"), TMPDIR: path.join(root, "tmp"),
    OPENCODE_CONFIG_PROJECT_DISABLE: "1", OPENCODE_DISABLE_MODELS_FETCH: "1", OPENCODE_DISABLE_FFF: "1",
    // Public fixture string, not an inherited credential. Only this private listener accepts it.
    OPENCODE_PASSWORD: "fixture-only-private-server", OPENCODE_LOG_LEVEL: "NONE",
  };
  let binary = args[1];
  if (args[0] === "--download") {
    phase = "pinned-binary-download-and-integrity";
    const response = await fetch(TARBALL, { signal: AbortSignal.timeout(120_000) });
    check(response.ok);
    const archive = Buffer.from(await response.arrayBuffer());
    check(archive.length <= 100_000_000 && createHash("sha512").update(archive).digest("base64") === INTEGRITY);
    const archivePath = path.join(root, "binary.tgz");
    await writeFile(archivePath, archive, { mode: 0o600 });
    check(run("/usr/bin/tar", ["-tzf", archivePath], env, project).trim() === "package/package.json\npackage/bin/opencode");
    run("/usr/bin/tar", ["-xzf", archivePath, "-C", root, "package/bin/opencode"], env, project);
    binary = path.join(root, "package/bin/opencode");
  }
  phase = "exact-version-and-xdg-paths";
  check(run(binary, ["--version"], env, project).trim() === VERSION);
  check(run(binary, ["serve", "--help"], env, project).includes("--stdio"));
  for (const selector of ["home", "config", "data", "state", "cache", "tmp", "db", "log", "repos", "bin"]) {
    const resolved = run(binary, ["debug", "paths", selector], env, project).trim();
    check(resolved.startsWith(`${root}/`));
  }
  phase = "managed-artifact-generation";
  const stub = path.join(root, "notifier");
  const stubModule = path.join(root, "notifier.mjs");
  await writeFile(stubModule, `import { appendFileSync, existsSync, statSync } from "node:fs";
const file = ${JSON.stringify(path.join(root, "normalized.ndjson"))};
let bytes = 0; const chunks = [];
for await (const chunk of process.stdin) { bytes += chunk.length; if (bytes > 2048) process.exit(1); chunks.push(chunk); }
if (existsSync(file) && statSync(file).size + bytes + 1 > ${MAX_CAPTURE}) process.exit(1);
appendFileSync(file, Buffer.concat([...chunks, Buffer.from("\\n")]), { mode: 0o600 });
`, { mode: 0o600 });
  const quote = (text) => `'${text.replaceAll("'", "'\\''")}'`;
  await writeFile(stub, `#!/bin/zsh -f\n[[ "$1" == event && "$#" == 1 ]] || exit 1\nexec ${quote(process.execPath)} ${quote(stubModule)}\n`, { mode: 0o700 });
  const pluginPath = path.join(root, "config/opencode/plugins/agent-notify.js");
  run("/usr/bin/osascript", ["-l", "JavaScript", path.join(REPO, "installer/opencode-plugin.jxa"),
    path.join(REPO, "integrations/opencode/agent-notify.js"), pluginPath, stub], env, project);
  const artifact = await readFile(pluginPath, "utf8");
  check(artifact.startsWith("// >>> agent-notify managed plugin >>>\n") && artifact.includes(JSON.stringify(stub)));
  const providerPort = await listenProvider();
  const config = {
    update: "disable", snapshots: false, model: "fixture/fixture", default_agent: "fixture-primary",
    permissions: [{ action: "*", resource: "*", effect: "deny" }, { action: "subagent", resource: "fixture-child", effect: "allow" }],
    experimental: { policies: [{ action: "provider.use", resource: "*", effect: "deny" }, { action: "provider.use", resource: "fixture", effect: "allow" }] },
    providers: { fixture: { package: "@opencode/ai/providers/openai-compatible", settings: { baseURL: `http://127.0.0.1:${providerPort}/v1` },
      models: { fixture: { name: "Fixture", capabilities: { tools: true, input: ["text"], output: ["text"] }, limit: { context: 128000, output: 2048 } } } } },
    agents: { "fixture-primary": { mode: "primary", model: "fixture/fixture", system: "Fixture only." },
      "fixture-child": { mode: "subagent", model: "fixture/fixture", system: "Fixture only." }, title: { disabled: true } },
  };
  await writeFile(path.join(root, "config/opencode/opencode.json"), JSON.stringify(config), { mode: 0o600 });
  // All pre-start uncertainty has been resolved: pinned private mode, disabled project discovery,
  // absent machine/ancestor inputs, fresh roots, loopback native protocol, and denied other providers.
  phase = "private-server-startup";
  server = spawn(binary, ["serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0"], { env, cwd: project, stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "";
  server.stdout.on("data", (chunk) => { stdout += chunk.toString(); if (stdout.length > MAX_CAPTURE) server.kill("SIGTERM"); });
  server.stderr.resume();
  server.on("error", () => { streamFailure = true; });
  await waitFor(() => stdout.split("\n").some((line) => line.startsWith('{"url":')));
  const url = JSON.parse(stdout.split("\n").find((line) => line.startsWith('{"url":'))).url;
  check(/^http:\/\/127\.0\.0\.1:\d+$/.test(url));
  stdout = "";
  const headers = { authorization: `Basic ${Buffer.from("opencode:fixture-only-private-server").toString("base64")}` };
  const api = async (route, method = "GET", body) => {
    const response = await fetch(`${url}${route}`, { method, headers: { ...headers, "content-type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(20_000) });
    lastHTTPStatus = response.status;
    check(response.ok);
    if (response.status === 204) return undefined;
    const value = await response.json();
    return Object.hasOwn(value, "data") ? value.data : value;
  };
  check((await api("/api/info")).version === "2.0.27");
  const plugins = () => api(`/api/plugin?${new URLSearchParams({ "location[directory]": project })}`);
  const active = (inventory) => inventory.find((plugin) => plugin.id === "agent-notify");
  phase = "native-loader-id-and-source";
  await waitFor(async () => Boolean(active(await plugins())));
  const loaded = active(await plugins());
  if (loaded?.state.status !== "active" || loaded.source.type !== "local" || loaded.source.path !== pluginPath)
    console.error(`CHECK real-v2-smoke: plugin-present=${Boolean(loaded)} plugin-active=${loaded?.state.status === "active"} local-source=${loaded?.source.type === "local"} generated-source=${loaded?.source.path === pluginPath}`);
  check(loaded?.state.status === "active" && loaded.source.type === "local" && loaded.source.path === pluginPath);
  await subscribe(url, headers);
  const create = async (text) => {
    const session = await api("/api/session", "POST", { title: "Fixture", agent: "fixture-primary", model: { providerID: "fixture", id: "fixture" }, location: { directory: project } });
    await api(`/api/session/${session.id}/prompt`, "POST", { text });
    return session.id;
  };
  const complete = async (id) => {
    await waitFor(() => sessionStates.get(id)?.succeeded > 0);
    await waitFor(async () => (await normalized()).some((event) => event.event === "completed" && event.session_id === id));
  };
  const began = async (id) => {
    await waitFor(() => sessionStates.get(id)?.succeeded > 0);
    await waitFor(async () => (await normalized()).some((event) => event.event === "began" && event.session_id === id));
  };
  phase = "native-subscription-activity";
  const initial = await create("fixture-loader-initial");
  await began(initial);
  check((await normalized()).filter((event) => event.session_id === initial && event.event === "began").length === 1);
  phase = "native-unload";
  await rename(pluginPath, path.join(root, "disabled-plugin.js"));
  await api("/api/location/reload", "POST");
  check(!active(await plugins()));
  const unloaded = await create("fixture-loader-unloaded");
  await waitFor(() => sessionStates.get(unloaded)?.succeeded > 0);
  await delay(300);
  check(!(await normalized()).some((event) => event.session_id === unloaded));
  phase = "native-reload";
  await rename(path.join(root, "disabled-plugin.js"), pluginPath);
  await api("/api/location/reload", "POST");
  await waitFor(async () => active(await plugins())?.state.status === "active");
  check(active(await plugins())?.state.status === "active");
  const reloaded = await create("fixture-loader-reloaded");
  await began(reloaded);
  check((await normalized()).filter((event) => event.session_id === reloaded && event.event === "began").length === 1);
  console.log("PASS real-v2-smoke: exact=2.0.27 isolation=private loader=active source=generated subscription=active unload=silent reload=active");
  phase = "native-background-child-barriers";
  const parent = await create("fixture-native-parent");
  nativeParent = parent;
  await waitFor(() => heldChildren.size === 2 && sessionStates.get(parent)?.succeeded >= 1);
  await delay(300); // >50 ms: root must stay pending while actual native children are held.
  check(!(await normalized()).some((event) => event.session_id === parent && event.event === "completed"));
  phase = "native-first-child-parent-wakeup";
  reply(heldChildren.get("A"), { text: "fixture-result-A" });
  await waitFor(() => resultConsumptions === 1 && sessionStates.get(parent)?.succeeded >= 2);
  await delay(300);
  check(!(await normalized()).some((event) => event.session_id === parent && event.event === "completed"));
  phase = "native-final-child-result-consumption";
  reply(heldChildren.get("B"), { text: "fixture-result-B" });
  await waitFor(() => resultConsumptions === 2 && sessionStates.get(parent)?.succeeded >= 3);
  phase = "native-root-completion-after-result-consumption";
  await complete(parent);
  await delay(300);
  const events = await normalized();
  check(events.filter((event) => event.session_id === parent && event.event === "began").length === 1);
  check(events.filter((event) => event.session_id === parent && event.event === "completed").length === 1);
  const children = [...sessionStates.keys()].filter((id) => ![initial, unloaded, reloaded, parent].includes(id));
  check(children.length === 2 && children.every((id) => sessionStates.get(id).succeeded === 1));
  check(!events.some((event) => children.includes(event.session_id) && ["began", "completed"].includes(event.event)));
  check(!events.some((event) => event.event === "failed"));
  check(sessionStates.get(parent).started === 3 && sessionStates.get(parent).delivered >= 3);
  console.log("PASS real-v2-smoke: exact=2.0.27 native-children=2 parent-executions=3 results-consumed=2 root-began=1 root-completed=1 child-completed=0");
}

try {
  await main();
} catch {
  const capture = root && await exists(path.join(root, "normalized.ndjson"));
  console.error(`CHECK real-v2-smoke: normalized-capture=${Boolean(capture)} normalized-bytes=${capture ? (await stat(path.join(root, "normalized.ndjson"))).size : 0} idle-sessions=${[...sessionStates.values()].filter((state) => state.idle).length}`);
  console.error(`CHECK real-v2-smoke: http-status=${lastHTTPStatus} provider-requests=${providerRequests} provider-failed=${providerFailure} stream-failed=${streamFailure} starts=${records.filter((record) => record.type === "session.execution.started").length} successes=${records.filter((record) => record.type === "session.execution.succeeded").length} failures=${records.filter((record) => record.type === "session.execution.failed").length}`);
  if (nativeParent) {
    const events = await normalized().catch(() => []);
    console.error(`CHECK real-v2-smoke: held-native-children=${heldChildren.size} parent-executions=${sessionStates.get(nativeParent)?.started ?? 0} results-consumed=${resultConsumptions} root-began=${events.filter((event) => event.session_id === nativeParent && event.event === "began").length} root-completed=${events.filter((event) => event.session_id === nativeParent && event.event === "completed").length}`);
  }
  console.error(`FAIL real-v2-smoke: ${phase}; no raw diagnostics emitted`);
  process.exitCode = 1;
} finally {
  try {
    streamController?.abort();
    await stopServer();
    await streamTask;
    if (provider) {
      provider.closeAllConnections();
      await new Promise((resolve) => provider.close(resolve));
    }
    // This unique mkdtemp tree was created by this invocation; no user-owned files are removed.
    if (root) await rm(root, { recursive: true, force: true });
  } catch {
    console.error("FAIL real-v2-smoke: owned-fixture-cleanup; no raw diagnostics emitted");
    process.exitCode = 1;
  }
}
