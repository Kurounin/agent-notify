# Isolated OpenCode 2.0.27 smoke check

Run from the repository root on an Apple Silicon Mac with the existing Node test runtime:

```sh
node --check tests/opencode/real-v2-smoke.mjs
node tests/opencode/real-v2-smoke.mjs --download
```

`--download` obtains only the official `@opencode/cli-darwin-arm64@2.0.27`
binary archive, checks its pinned SHA-512 integrity, and extracts the binary into
a private temporary fixture. It does not run npm, package scripts, or an installer.
Alternatively, `--binary` accepts an absolute path to a previously obtained
binary and checks its exact version before startup. Other platforms and versions
are deliberately rejected.

## Safety boundary

- Uses a fresh, mode-0700 temporary tree under the existing OpenCode temporary
  parent, with a clean child environment and separate HOME, XDG config/data/
  state/cache, and TMPDIR. Checks the host's reported paths before startup.
- Checks only presence of machine configuration directories, machine/user
  managed preferences, and every ancestor's discoverable configuration,
  definitions, and instruction files. Refuses startup if any is present or an
  existence check is uncertain. Never reads those files.
- Sets `OPENCODE_CONFIG_PROJECT_DISABLE=1` and disables models catalog fetching.
  This flag reaches both configuration and instruction discovery in the pinned
  server. `OPENCODE_PURE` is not an isolation mechanism and is not used.
- Starts only `serve --stdio --hostname 127.0.0.1 --port 0`. Never invokes
  `opencode api`, service discovery, registration, restart, or the managed service.
- Generates the actual managed artifact with `installer/opencode-plugin.jxa`.
  The substituted absolute notifier is a fixture-only stdin collector, not the
  notifier executable. It never reads Keychain or delivers a notification.
- Allows only the fixture provider, its native subagent tool, and one exact
  fixture-only shell command (`/bin/cat` reading a private FIFO in the fixture
  project). The FIFO is created mode 0600 and released with one fixed output
  write; there is no shell polling, arbitrary command input, or process scan. The
  scripted provider is a loopback OpenAI-compatible chat stream with no model
  credentials or external model calls. The private API password is a public,
  fixed fixture string, never an inherited credential.
- Keeps bounded normalized fixture submissions privately; reduces native
  events to lifecycle counts in memory. Prints only categorical outcomes.
  Removes observed fixture shells through the private native API, shuts down
  its own processes, and removes only its unique fixture tree.

Pinned contracts used: `packages/cli/src/server-process.ts`,
`packages/util/src/global-roots.ts`, `packages/core/src/config/discovery.ts`,
`packages/server/src/routes.ts`, `packages/protocol/openapi.json`,
`packages/core/src/tool/plugin/subagent.ts`, and
`packages/core/src/session/subagent-completion.ts`,
`packages/schema/src/shell.ts`, and `packages/core/src/tool/plugin/shell.ts`
at tag `v2.0.27`.

## Evidence and interpretation

The first PASS establishes generated-source/ID acceptance, actual native event
subscription activity, silent unload, and a single active reloaded subscription.
It does **not** establish completion correctness.

The child scenario uses the real native `subagent` tool with `background: true`.
Both loopback child responses remain held until the root's first local execution
succeeds. It waits 300 ms without root completion, releases one child, waits for
native parent wakeup and consumption of that result, and again waits 300 ms
without completion. It then releases the other child and requires final native
parent execution/result consumption, one root begin/completion, and no child
begin/completion. No fake idle, execution, inbox, or child-result events are
injected. These barriers verify one concrete observed native sequence, not a
global timing guarantee.

The shell scenario uses the real native `shell` tool with `background: true`.
Its fixed command stays blocked on the fixture FIFO through the root's first
successful local execution and a further 300 ms without completion. One write
releases it; native shell exit and output/inbox handling must then resume the
parent and produce one original root begin/completion after output consumption.
The event observer retains only shell/session IDs and lifecycle status, never
commands, output, PID, or capture paths. No shell lifecycle, execution, idle, or
inbox events are injected. This checks live observation, not pre-subscription
recovery, every accepted patch, or exhaustive process detection.

Initial execution on 2026-10-13, using exact 2.0.27:

- Loader/source/subscription/unload/reload: **passed**.
- Two native background children and three successful parent executions:
  **observed**, with both child results consumed automatically.
- Root begin count: **1**; root completion count: **0**. The command correctly
  exited nonzero at `native-root-completion-after-result-consumption`.
- No native status-idle signals were observed. The initial adapter retained
  busy status after native execution success, preventing completion. Pinned
  `Session.Info` records terminal outcome at `time.idle`, and
  `session/message-updater.ts` projects that transition directly from execution
  terminal events. Do not add invented idle signals to make this check pass.

Rerun after an adapter change; initial evidence does not validate later artifacts.

Final corrected execution on 2026-10-13, using exact 2.0.27:

- Adapter source SHA-256: `85709a72ddf188d47fa98397b88830f6d7b46db06a4b8c8335a194d243a9acd2`.
- Private isolation; generated-plugin ID/source, native subscription, silent
  unload, and single active reloaded subscription: **passed**.
- Native background children: **2**; successful parent executions: **3**;
  child results consumed: **2**.
- Root begin/completion: **1 / 1**; child completions: **0**.
- Both categorical PASS checks succeeded; the command exited zero and cleaned
  up its own fixture processes/tree. No managed-service, live-home, Keychain,
  or external-model access was used.

The adapter now derives local idle from native execution success while retaining
tree/inbox settlement and quiescence. Controlled tests additionally cover
location-routed moves, workspace identity, same-owner delayed lookup and queued
begin/reset preservation, busy-only reactivation after terminal outcomes, and
independent trees under sustained stalled metadata work. The real-host result
establishes this concrete background-child sequence, not every accepted patch,
unseen work, or a host-global timing guarantee.

## Warning follow-up execution — 2026-10-13

After correcting retry-before-busy activation and valid-creation/invalid-lookup
relationship precedence, a fresh exact-2.0.27 check passed on adapter SHA-256
`0f4e098a742c9a67ab53ea7a123767dc0aecdf08b31fd31345ba2a208e7674ae`:

- Private isolation; generated-plugin loading/source, native subscription,
  silent unload, and single active reload: **passed**.
- Native children: **2**; parent executions: **3**; results consumed: **2**.
- Root begin/completion: **1 / 1**; child completions: **0**.
- Both categorical PASS checks succeeded and fixture cleanup completed.

The two warning traces are established by five controlled regression tests,
which failed before the fixes and passed afterward. The complete native suite
now passes 70 tests; notifier, Claude, and installer suites also passed. The
real-host check confirms the existing concrete background-child sequence, not
direct injection of malformed metadata or missing execution-start events. No
live-home, Keychain, managed-service, or external-model access was used.

## Running-shell execution — 2026-10-29

Fresh execution with the official `@opencode/cli-darwin-arm64@2.0.27`
archive and its pinned SHA-512 integrity passed on adapter SHA-256
`a2f1ffcbdd02ae21ea99c11b5f4df900806e4a6f851b09de04e7b4d31ebf0d2e`:

- Private isolation; generated-plugin loading/source, native subscription,
  silent unload, and single active reload: **passed**.
- Existing native background-child scenario: **2** children, **3** parent
  executions, **2** results consumed, root begin/completion **1 / 1**, and
  **0** child completions.
- Native background-shell scenario: **1** shell observed running through the
  parent's first successful execution and the additional 300 ms hold, with
  **0** root completions while held. After release, native exit and output
  consumption produced **2** total parent executions and root begin/completion
  **1 / 1**, without a session failure.
- All three categorical PASS checks succeeded; the command exited zero and
  cleaned up its owned shell, server, provider, and temporary tree. No synthetic
  lifecycle events, managed-service, live-home, Keychain, or external-model
  access was used.

The 103-test controlled adapter suite additionally establishes shell payload
validation, tree-local association, settlement, cancellation during delayed
work, bounded ancestry resolution, ownership changes, and inbox/outcome rules.
The native result establishes only these exercised 2.0.27 sequences; it does
not recover missed shell starts or guarantee exhaustive process detection.
