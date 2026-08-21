#!/usr/bin/env bash
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
# Node 24 warns when these test-only dynamic imports load tracked ESM plugins
# from a clean checkout with no tracked .opencode/package.json. The warning is
# unrelated to plugin output, which the assertions intentionally require empty.
export NODE_NO_WARNINGS=1

# Arm-readiness budget for the hung- and unretired-successor cases below.
#
# The extension defaults this to 12s (35s on Windows). A successor that hangs
# is only ever detected by the budget expiring, once per retry, so these cases
# have to compress it or each one would cost over half a minute.
#
# The compressed value cannot be a literal, because it has to outrun a cold
# child start and that cost is a property of the machine, not of the plugin:
# the extension launches every arm as a login `bash -l`, which sources the
# system profile before exec'ing the arm script, and the script's first append
# is what the arm-count assertions read. When the budget expires first the
# extension SIGTERMs a successor that has not recorded itself yet, the row is
# lost, and the count comes up one short. That start costs about 14ms on a
# developer workstation and about 100ms on a CI runner, so a literal tuned on
# the former is a CI-only false red on the latter.
#
# Measuring it keeps the bound tied to the thing it must beat. Oversizing is
# safe: the fixtures never emit an established line for a successor, so
# readiness cannot resolve true however long the budget is. The budget only
# decides how long each case waits, never what it concludes.
#
# docs/verification/watcher-arm-test-budgets.md owns the measurements and the
# command that refreshes them.
fm_measure_arm_child_start_ms() {
  node --input-type=module <<'MEASURE'
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "fm-arm-child-start-"));
const probe = join(dir, "probe.sh");
writeFileSync(probe, "#!/usr/bin/env bash\nprintf 'started\\n'\n", { mode: 0o755 });
let worst = 0;
for (let i = 0; i < 5; i += 1) {
  const started = process.hrtime.bigint();
  spawnSync("bash", ["-lc", 'exec "$0"', probe], { stdio: "ignore" });
  const elapsed = Number(process.hrtime.bigint() - started) / 1e6;
  if (elapsed > worst) worst = elapsed;
}
rmSync(dir, { recursive: true, force: true });
console.log(Math.ceil(worst));
MEASURE
}

ARM_CHILD_START_MS=$(fm_measure_arm_child_start_ms)
case $ARM_CHILD_START_MS in
  ''|*[!0-9]*) fail "could not measure arm child start cost: '$ARM_CHILD_START_MS'" ;;
esac
# Five times the worst of five cold starts, and never below 500ms so a fast
# workstation still leaves room for a scheduling stall.
ARM_READY_TIMEOUT_MS=$((ARM_CHILD_START_MS * 5))
[ "$ARM_READY_TIMEOUT_MS" -ge 500 ] || ARM_READY_TIMEOUT_MS=500
# Printed so a CI log answers "was the budget the problem?" on its own, without
# a second run to reproduce the machine this executed on.
printf '# arm child start %sms measured, readiness budget %sms\n' \
  "$ARM_CHILD_START_MS" "$ARM_READY_TIMEOUT_MS"

# Per-start budget, per-case slack and poll cadence for every observation
# window below.
#
# The coupling that broke the readiness budget applies to any window waiting on
# a chain of cold arm children: a literal iteration count does not move with the
# machine, so it crosses as soon as the chain costs more than the literal
# allowed. Each driver therefore sizes its own window as
# <chained child starts> * FM_TEST_ARM_START_BUDGET_MS + FM_TEST_OBSERVE_SLACK_MS,
# counting every start in its chain rather than assuming the first one lands
# before the window opens.
#
# One start is budgeted at the measured readiness budget - five times the worst
# of five cold starts - so a single unusually slow start cannot exhaust the
# window. That budget carries its own 500ms floor, which is what keeps a window
# from collapsing on a workstation where a start costs 14ms.
#
# The slack covers module load, lock checks and prompt delivery, which are per
# case rather than per start. Those are per-case process costs, so they scale
# with the machine exactly like the fork cost the per-start term is measured
# from, and the slack is derived from the same measurement rather than left
# flat: it is the additive term in every window in this file, so a literal there
# pins a floor under all of them and is the one term that would not move with
# the machine. Three cold starts, floored at the 1000ms the CI evidence in
# docs/verification/watcher-arm-test-budgets.md was collected at, so a loaded
# runner widens it and no machine narrows it below the measured configuration.
#
# A polled window and a settle sleep are NOT the same cost, and this comment
# governs both. A polled window is an upper bound on waiting: its driver stops
# the moment its event lands, so a wide window costs nothing when the case
# passes and only bounds how long a genuine failure takes to report. A settle
# sleep - setTimeout with FM_TEST_ARM_START_BUDGET_MS and no predicate, which is
# how the negative cases give an unwanted arm child time to record itself - is
# pure wall clock, paid in full on the passing path too. There are eight of
# those, so for them a wide budget does NOT cost nothing: about 3s per run of
# this file on a workstation, 13.1s at the 328ms start measured on run
# 32255813826, and 32s at the 800ms start in the 16-spinner load curve.
#
# Poll cadence is derived from the window it polls rather than left absolute.
# A fixed 10ms poll inside a derived window makes the failing path noisier the
# slower the machine gets - 590 to 1300 timer wakeups, plus a filesystem stat
# on each, on the machine whose load is the thing being measured. Dividing the
# window instead caps that at FM_TEST_OBSERVE_POLL_DIVISOR wakeups whatever the
# machine costs. That trades absolute detection granularity for granularity
# proportional to the window - one 64th of the window being measured - which
# never approaches the window itself and never widens it, since every deadline
# is computed from the window and not from the poll.
#
# The plugins never read these names; their own budgets come from
# FM_PI_ARM_READY_TIMEOUT_MS and FM_OPENCODE_ARM_READY_TIMEOUT_MS.
export FM_TEST_ARM_START_BUDGET_MS="$ARM_READY_TIMEOUT_MS"
OBSERVE_SLACK_MS=$((ARM_CHILD_START_MS * 3))
[ "$OBSERVE_SLACK_MS" -ge 1000 ] || OBSERVE_SLACK_MS=1000
export FM_TEST_OBSERVE_SLACK_MS="$OBSERVE_SLACK_MS"
export FM_TEST_OBSERVE_POLL_DIVISOR=64
# Printed for the same reason the readiness budget is: a CI log has to answer
# "what did this run derive?" without a second run to reproduce the machine.
printf '# observation slack %sms derived, poll cadence window/%s\n' \
  "$FM_TEST_OBSERVE_SLACK_MS" "$FM_TEST_OBSERVE_POLL_DIVISOR"

# Retry backoff cap for every case below that overrides the plugins' own 4000ms
# default so a re-arm attempt is not spent sitting in backoff. One name rather
# than a literal per env prefix, because fm_recovery_deadline_ms budgets one of
# these per readiness expiry: if a call site's cap and the deadline's assumption
# about it could drift apart, raising the cap would silently under-count the
# deadline and report "no wake delivery" for a recovery still on schedule.
REARM_RETRY_MAX_MS=10

# Shell-side counterparts of the two derivations above, for the one bound in
# this file that is waited on from bash rather than from a node driver.
#
# fm_observe_window_ms <chained child starts> [fixed ms]: the same window the
# drivers compute, plus any fixed cost the case knows about on top.
# fm_observe_poll_ms <window ms>: that window divided by the poll divisor.
# fm_observe_attempts <window ms> <poll ms>: iterations covering the window.
# fm_ms_to_seconds <ms>: a `sleep` argument, since bash has no ms sleep.
fm_observe_window_ms() {
  echo $(( $1 * ARM_READY_TIMEOUT_MS + OBSERVE_SLACK_MS + ${2:-0} ))
}

fm_observe_poll_ms() {
  local poll=$(( $1 / FM_TEST_OBSERVE_POLL_DIVISOR ))
  [ "$poll" -ge 1 ] || poll=1
  echo "$poll"
}

fm_observe_attempts() {
  echo $(( ($1 + $2 - 1) / $2 ))
}

fm_ms_to_seconds() {
  printf '%d.%03d\n' $(( $1 / 1000 )) $(( $1 % 1000 ))
}

# Observation deadline for the recovery cases below.
#
# Those cases can only conclude once their successor readiness budgets have
# expired, so how long their driver waits has to be a function of that budget,
# never a literal. A case that waits through N expiries cannot possibly see the
# wake before N budgets, N retirements and N backoffs have elapsed, plus the
# child starts around them. A shorter wait reports "no wake delivery" for a
# recovery that was still on schedule - which is exactly the CI false red that
# measuring the budget introduced, because a slow runner raises the budget and
# a literal 500 x 10ms wait does not move with it.
#
# These windows are polled, so they are upper bounds on waiting rather than
# sleeps: every driver stops the moment its event lands, so sizing one from the
# worst case costs nothing on the passing path and only bounds how long a
# genuine failure takes to report.
fm_recovery_deadline_ms() { # <budget expiries> <arm retire budget ms> [backoff cap ms]
  local expiries=$1 retire=$2 backoff=${3:-$REARM_RETRY_MAX_MS}
  # Per expiry: the readiness budget, the retirement budget that follows it,
  # and the retry backoff, which the plugins cap at FM_WATCH_REARM_RETRY_MAX_MS
  # however far their doubling has run - so the cap bounds this term, and it is
  # read from the same name the call sites export that cap under.
  # Plus one cold child start per attempt and for the original arm, and the
  # derived per-case slack for module load, lock checks and prompt delivery -
  # the same term the drivers add, for the same reason it is not a literal
  # there.
  echo $(( expiries * (ARM_READY_TIMEOUT_MS + retire + backoff) \
           + (expiries + 1) * ARM_CHILD_START_MS + OBSERVE_SLACK_MS ))
}

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

test_pi_extension_reports_external_healthy_watcher() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-external-healthy-root"
  home="$TMP_ROOT/pi-external-healthy-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let handler = null;
let notification = "";
let prompt = "";
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!handler) {
  console.error("Pi watch command was not registered");
  process.exit(1);
}
const result = await handler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (result !== undefined) {
  console.error(`Pi command returned a value: ${String(result)}`);
  process.exit(1);
}
if (!notification.includes("started Pi extension arm child")) {
  console.error(notification);
  process.exit(1);
}
const promptWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const promptDeadlineAt = Date.now() + promptWindowMs;
const promptPollMs = Math.ceil(promptWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!prompt && Date.now() < promptDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, promptPollMs));
}
if (!prompt.startsWith("\u2063FIRSTMATE_OP: v1 watcher: ")) {
  console.error(`untyped operational follow-up: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) {
  console.error(`missing follow-up prompt: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("external healthy watcher")) {
  console.error(prompt);
  process.exit(1);
}
if (!prompt.includes("watcher: healthy pid=1")) {
  console.error(prompt);
  process.exit(1);
}
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi extension must surface an external healthy watcher as an owned-wake failure" "$out"
  pass "Pi extension reports external healthy watcher output"
}

test_pi_tool_returns_agent_tool_result() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-tool-result-root"
  home="$TMP_ROOT/pi-tool-result-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
if (tool.label !== "Arm firstmate watcher") throw new Error(`unexpected label: ${tool.label}`);
if (tool.parameters?.type !== "object") throw new Error("tool parameters are not a TypeBox object schema");
const metadata = [tool.description, tool.promptSnippet, ...(tool.promptGuidelines ?? [])].join("\n");
if (metadata.includes("Always use this tool")) throw new Error(`broad tool-selection metadata remained visible: ${metadata}`);
if (!tool.description.includes("first required Pi watcher cycle")) throw new Error(`tool description omitted the first-cycle condition: ${tool.description}`);
if (!tool.promptSnippet.includes("ordinary re-arming is automatic")) throw new Error(`tool snippet omitted automatic continuation: ${tool.promptSnippet}`);
if (!tool.promptGuidelines.some((guideline) => guideline.includes("ordinary signal, stale, check, or heartbeat handling"))) {
  throw new Error(`tool guidelines omitted ordinary-notification prevention: ${tool.promptGuidelines}`);
}
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!Array.isArray(result.content) || result.content[0]?.type !== "text") {
  throw new Error(`invalid tool content: ${JSON.stringify(result)}`);
}
if (!result.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`unexpected tool text: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("future ordinary re-arms are automatic")) {
  throw new Error(`initial tool result omitted automatic continuation guidance: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`initial tool result omitted the repair-only condition: ${result.content[0].text}`);
}
if (result.details?.ok !== true || result.details?.message !== result.content[0].text) {
  throw new Error(`invalid tool details: ${JSON.stringify(result.details)}`);
}
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi custom tool must expose first-cycle or repair-only metadata and return Pi's AgentToolResult shape" "$out"
  pass "Pi custom tool exposes repair-only metadata and returns automatic-continuation guidance"
}

test_pi_redundant_tool_call_is_owned_noop() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-redundant-tool-root"
  home="$TMP_ROOT/pi-redundant-tool-home"
  log="$TMP_ROOT/pi-redundant-tool.log"
  stop="$TMP_ROOT/pi-redundant-tool.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const initial = await tool.execute("tool-call-first", {}, undefined, undefined, {});
if (!initial.content[0]?.text.includes("started Pi extension arm child")) {
  throw new Error(`initial call did not start the arm child: ${initial.content[0]?.text}`);
}
const redundant = await tool.execute("tool-call-redundant", {}, undefined, undefined, {});
if (!redundant.content[0]?.text.includes("Pi extension already owns an arm child; no manual re-arm needed")) {
  throw new Error(`redundant call omitted ownership-based no-op guidance: ${redundant.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`redundant call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`redundant call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
const armWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const armDeadlineAt = Date.now() + armWindowMs;
const armPollMs = Math.ceil(armWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!existsSync(process.env.FM_ARM_LOG) && Date.now() < armDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, armPollMs));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("initial arm child did not start");
await new Promise((resolve) => setTimeout(resolve, Number(process.env.FM_TEST_ARM_START_BUDGET_MS)));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`redundant call spawned ${rows.length} arm children`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi redundant tool call must remain an ownership-based no-op with repair-only guidance" "$out"
  pass "Pi redundant tool call returns ownership guidance and spawns no second child"
}

test_pi_scheduled_retry_call_is_owned_noop() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-scheduled-retry-root"
  home="$TMP_ROOT/pi-scheduled-retry-home"
  log="$TMP_ROOT/pi-scheduled-retry.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=10000 FM_WATCH_REARM_RETRY_MAX_MS=10000 node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-first", {}, undefined, undefined, {});
let redundant = null;
const retryProbeWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const retryProbeDeadlineAt = Date.now() + retryProbeWindowMs;
const retryProbePollMs = Math.ceil(retryProbeWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < retryProbeDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, retryProbePollMs));
  redundant = await tool.execute("tool-call-during-retry", {}, undefined, undefined, {});
  if (redundant.content[0]?.text.includes("scheduled continuity retry")) break;
}
if (!redundant?.content[0]?.text.includes("Pi extension already owns a scheduled continuity retry; no manual re-arm needed")) {
  throw new Error(`scheduled retry did not return ownership-based no-op guidance: ${redundant?.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`scheduled retry call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`scheduled retry call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
await new Promise((resolve) => setTimeout(resolve, Number(process.env.FM_TEST_ARM_START_BUDGET_MS)));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`scheduled retry call spawned ${rows.length} arm children`);
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi scheduled-retry call must not duplicate the extension-owned retry" "$out"
  pass "Pi scheduled retry remains extension-owned after another tool call"
}

test_pi_actionable_close_starts_single_successor_before_delivery() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-continuous-rearm-root"
  home="$TMP_ROOT/pi-continuous-rearm-home"
  log="$TMP_ROOT/pi-continuous-rearm.log"
  stop="$TMP_ROOT/pi-continuous-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveryStarted = false;
let rowsAtDelivery = 0;
let releaseDelivery = () => {};
const deliveryBlocked = new Promise((resolve) => {
  releaseDelivery = resolve;
});
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    rowsAtDelivery = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
    deliveryStarted = true;
    await deliveryBlocked;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-continuity", {}, undefined, undefined, {});
const successorWindowMs = 2 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const successorDeadlineAt = Date.now() + successorWindowMs;
const successorPollMs = Math.ceil(successorWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < successorDeadlineAt) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && deliveryStarted) break;
  await new Promise((resolve) => setTimeout(resolve, successorPollMs));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}: ${rows.join(" | ")}`);
if (!deliveryStarted) throw new Error("wake delivery did not begin");
if (rowsAtDelivery !== 2) throw new Error(`wake delivery began before successor establishment (${rowsAtDelivery} arm rows)`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor did not receive predecessor identity: ${rows[1]}`);
await new Promise((resolve) => setTimeout(resolve, Number(process.env.FM_TEST_ARM_START_BUDGET_MS)));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`delivery was confirmed before the prompt succeeded: ${stableRows.join(" | ")}`);
releaseDelivery();
const confirmWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const confirmDeadlineAt = Date.now() + confirmWindowMs;
const confirmPollMs = Math.ceil(confirmWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < confirmDeadlineAt) {
  if (readFileSync(process.env.FM_ARM_LOG, "utf8").includes("confirmed generation=fixture-generation")) break;
  await new Promise((resolve) => setTimeout(resolve, confirmPollMs));
}
const confirmedRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (confirmedRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${confirmedRows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_driver_ok "$status" "Pi actionable close must start one successor before wake delivery settles" "$out"
  pass "Pi actionable close starts one successor before wake delivery settles"
}

test_pi_hung_successor_falls_back_to_typed_wake() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-hung-successor-root"
  home="$TMP_ROOT/pi-hung-successor-home"
  log="$TMP_ROOT/pi-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WAKE_DEADLINE_MS="$(fm_recovery_deadline_ms 3 1000)" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
// -1, not 0, so "no delivery was ever observed" cannot be reported as
// "a wake arrived with an empty arm log" - two different failures.
let rowsAtPrompt = -1;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-hung-successor", {}, undefined, undefined, {});
const wakeWindowMs = Number(process.env.FM_WAKE_DEADLINE_MS);
const deadlineAt = Date.now() + wakeWindowMs;
const wakePollMs = Math.ceil(wakeWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!prompt && Date.now() < deadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, wakePollMs));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 4) throw new Error(`expected one successor plus two retries, got ${rows.length}: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(rowsAtPrompt < 0
  ? `no wake delivery was observed at all; arm log holds ${rows.length} rows`
  : `wake arrived before restoration exhausted (${rowsAtPrompt} of ${rows.length} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, Number(process.env.FM_TEST_ARM_START_BUDGET_MS)));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi must deliver the actionable wake after bounded hung-successor recovery" "$out"
  pass "Pi hung successor falls back to one typed actionable wake"
}

test_pi_unretired_successor_falls_back_without_retry() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-unretired-successor-root"
  home="$TMP_ROOT/pi-unretired-successor-home"
  log="$TMP_ROOT/pi-unretired-successor.log"
  release="$TMP_ROOT/pi-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_WAKE_DEADLINE_MS="$(fm_recovery_deadline_ms 1 20)" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let rowsAtPrompt = -1;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-unretired-successor", {}, undefined, undefined, {});
const wakeWindowMs = Number(process.env.FM_WAKE_DEADLINE_MS);
const deadlineAt = Date.now() + wakeWindowMs;
const wakePollMs = Math.ceil(wakeWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!prompt && Date.now() < deadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, wakePollMs));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`unretired arm overlapped a retry: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(rowsAtPrompt < 0
  ? `no wake delivery was observed at all; arm log holds ${rows.length} rows`
  : `wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi must fall back without overlapping an unretired successor" "$out"
  pass "Pi unretired successor falls back without an overlapping retry"
}

test_pi_late_unretired_close_resumes_supervision() {
  local kind repo home plugin log ready retired release stop out status
  for kind in actionable non-actionable; do
    repo="$TMP_ROOT/pi-late-$kind-root"
    home="$TMP_ROOT/pi-late-$kind-home"
    log="$TMP_ROOT/pi-late-$kind.log"
    ready="$TMP_ROOT/pi-late-$kind.ready"
    retired="$TMP_ROOT/pi-late-$kind.retired"
    release="$TMP_ROOT/pi-late-$kind.release"
    stop="$TMP_ROOT/pi-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    install_pi_watch_extension_fixture "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  trap 'printf "retired\\n" > "${FM_UNRETIRED_RETIRE_FILE:?}"' TERM INT
  printf 'ready\n' > "${FM_UNRETIRED_READY_FILE:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_WAKE_DEADLINE_MS="$(fm_recovery_deadline_ms 1 20)" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(message);
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  const wakeWindowMs = Number(process.env.FM_WAKE_DEADLINE_MS);
  const deadlineAt = Date.now() + wakeWindowMs;
  const wakePollMs = Math.ceil(wakeWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
  while (Date.now() < deadlineAt) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, wakePollMs));
  }
  if (predicate()) return;
  throw new Error(message);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-late-close", {}, undefined, undefined, {});
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_READY_FILE),
  "unretired successor did not enter its retirement wait",
);
await waitFor(() => prompts.length >= 1, "original fallback was not delivered");
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_RETIRE_FILE),
  "unretired successor was not asked to retire before fallback",
);
if (rows().length !== 2) throw new Error(`unretired arm overlapped before fallback: ${rows().join(" | ")}`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
const lateWindowMs = Number(process.env.FM_WAKE_DEADLINE_MS);
const lateDeadlineAt = Date.now() + lateWindowMs;
const latePollMs = Math.ceil(lateWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < lateDeadlineAt) {
  if (rows().length >= 3 && (process.env.FM_LATE_KIND !== "actionable" || prompts.some((message) => message.includes("late wake")))) break;
  await new Promise((resolve) => setTimeout(resolve, latePollMs));
}
if (rows().length !== 3) throw new Error(`late close did not restore one successor: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
    status=$?
    expect_driver_ok "$status" "Pi late $kind close must remain supervised after fallback" "$out"
  done
  pass "Pi late unretired closes resume classified supervision"
}

test_pi_empty_close_retries_instead_of_disappearing() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-empty-close-root"
  home="$TMP_ROOT/pi-empty-close-home"
  log="$TMP_ROOT/pi-empty-close.log"
  stop="$TMP_ROOT/pi-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompts = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    prompts += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-empty", {}, undefined, undefined, {});
const successorWindowMs = 2 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const successorDeadlineAt = Date.now() + successorWindowMs;
const successorPollMs = Math.ceil(successorWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < successorDeadlineAt) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2) break;
  await new Promise((resolve) => setTimeout(resolve, successorPollMs));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_driver_ok "$status" "Pi clean empty close must trigger a bounded continuity retry" "$out"
  pass "Pi clean empty close triggers a bounded continuity retry"
}

test_pi_established_empty_close_honors_retry_limit() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-established-empty-close-root"
  home="$TMP_ROOT/pi-established-empty-close-home"
  log="$TMP_ROOT/pi-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-established-empty", {}, undefined, undefined, {});
const retryWindowMs = 3 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const retryDeadlineAt = Date.now() + retryWindowMs;
const retryPollMs = Math.ceil(retryWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!prompt && Date.now() < retryDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, retryPollMs));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi established clean closes must honor the continuity retry limit" "$out"
  pass "Pi established clean closes stop at the configured retry limit"
}

test_pi_actionable_close_rechecks_session_lock() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-close-lock-root"
  home="$TMP_ROOT/pi-close-lock-home"
  log="$TMP_ROOT/pi-close-lock.log"
  release="$TMP_ROOT/pi-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-lock-close", {}, undefined, undefined, {});
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  const lockLossWindowMs = 2 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
    + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
  const lockLossDeadlineAt = Date.now() + lockLossWindowMs;
  const lockLossPollMs = Math.ceil(lockLossWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
  while (!prompt.includes("no longer owns the lock") && Date.now() < lockLossDeadlineAt) {
    await new Promise((resolve) => setTimeout(resolve, lockLossPollMs));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
}
EOF
  )
  status=$?
  expect_driver_ok "$status" "Pi close handler must verify session-lock ownership before successor launch" "$out"
  pass "Pi close handler verifies session-lock ownership before successor launch"
}

test_pi_arm_distinguishes_session_lock_ownership() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-lock-ownership-root"
  home="$TMP_ROOT/pi-lock-ownership-home"
  log="$TMP_ROOT/pi-lock-ownership.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");

const lock = `${process.env.FM_HOME}/state/.lock`;
const callArm = () => tool.execute("tool-call-lock", {}, undefined, undefined, {});
const assertMissingLock = (result, label) => {
  if (result.details?.ok !== false) throw new Error(`${label} unexpectedly armed: ${JSON.stringify(result.details)}`);
  if (!result.details.message.includes("no live session holds the lock")) {
    throw new Error(`${label} missing no-live-session guidance: ${result.details.message}`);
  }
  if (!result.details.message.includes("bin/fm-session-start.sh") || !result.details.message.includes("re-arm")) {
    throw new Error(`${label} missing reclaim and re-arm guidance: ${result.details.message}`);
  }
  if (result.details.message.includes("held by another firstmate session")) {
    throw new Error(`${label} was misreported as a live other holder: ${result.details.message}`);
  }
};

if (existsSync(lock)) unlinkSync(lock);
assertMissingLock(await callArm(), "absent lock");
writeFileSync(lock, "999999\n");
assertMissingLock(await callArm(), "dead lock holder");

const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  const liveOther = await callArm();
  if (liveOther.details?.ok !== false) throw new Error(`live other holder unexpectedly armed: ${JSON.stringify(liveOther.details)}`);
  if (liveOther.details.message !== "watcher: read-only - session lock is held by another firstmate session") {
    throw new Error(`unexpected live-other response: ${liveOther.details.message}`);
  }
} finally {
  other.kill("SIGTERM");
}

if (existsSync(process.env.FM_ARM_LOG)) throw new Error("watcher arm ran without lock ownership");
writeFileSync(lock, `${process.pid}\n`);
const owned = await callArm();
if (owned.details?.ok !== true || !owned.details.message.includes("started Pi extension arm child")) {
  throw new Error(`owned lock did not arm: ${JSON.stringify(owned.details)}`);
}
const armWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const armDeadlineAt = Date.now() + armWindowMs;
const armPollMs = Math.ceil(armWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!existsSync(process.env.FM_ARM_LOG) && Date.now() < armDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, armPollMs));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("owned lock did not run the watcher arm");
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi watcher arm must distinguish owned, live-other, and missing or dead session locks" "$out"
  pass "Pi watcher arm distinguishes all session lock ownership states"
}

test_pi_session_transition_generation_owner() {
  local repo home plugin child_pid_file arm_log out status
  repo="$TMP_ROOT/pi-session-transition-root"
  home="$TMP_ROOT/pi-session-transition-home"
  child_pid_file="$TMP_ROOT/pi-session-transition-child.pid"
  arm_log="$TMP_ROOT/pi-session-transition-arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
printf '%s\n' "$$" > "${FM_CHILD_PID_FILE:?}"
printf 'arm pid=%s\n' "$$" >> "${FM_ARM_LOG:?}"
trap 'exit 0' TERM INT
while :; do sleep 0.2; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CHILD_PID_FILE="$child_pid_file" FM_ARM_LOG="$arm_log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  let tool = null;
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async () => {},
    events: { on() {} },
  };
  return { pi, handlers, getTool: () => tool };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(pred, label, starts = 1) {
  const wakeWindowMs = starts * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
    + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
  const deadlineAt = Date.now() + wakeWindowMs;
  const wakePollMs = Math.ceil(wakeWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
  while (Date.now() < deadlineAt) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, wakePollMs));
  }
  if (pred()) return;
  throw new Error(`timeout waiting for ${label}`);
}

function liveArmPids() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split(/\n/)
    .filter(Boolean)
    .map((line) => {
      const match = /pid=(\d+)/.exec(line);
      return match ? match[1] : "";
    })
    .filter(Boolean)
    .filter(pidAlive);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);

const startup = makePi();
mod.default(startup.pi);
await startup.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
const first = await startup.getTool().execute("startup", {}, undefined, undefined, {});
if (!first.details?.ok || !String(first.details.message).includes("started Pi extension arm child")) {
  throw new Error(`startup arm failed: ${JSON.stringify(first.details)}`);
}
await waitFor(() => existsSync(process.env.FM_CHILD_PID_FILE), "startup child");
const startupChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
if (!pidAlive(startupChild)) throw new Error("startup child was not alive");
const staleTool = startup.getTool();

async function replaceSession(previous, reason) {
  const previousChild = existsSync(process.env.FM_CHILD_PID_FILE)
    ? readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim()
    : "";
  await previous.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason }, {});
  if (previousChild) {
    await waitFor(() => !pidAlive(previousChild), `${reason} previous child exit`);
  }
  const next = makePi();
  mod.default(next.pi);
  await next.handlers.get("session_start")?.({
    type: "session_start",
    reason,
    previousSessionFile: `/tmp/previous-${reason}.jsonl`,
  }, {});
  const armed = await next.getTool().execute(`arm-${reason}`, {}, undefined, undefined, {});
  if (!armed.details?.ok) {
    throw new Error(`${reason} replacement arm failed: ${JSON.stringify(armed.details)}`);
  }
  if (String(armed.details.message).includes("shutting down")) {
    throw new Error(`${reason} replacement still refused with shutting-down latch`);
  }
  await waitFor(() => {
    if (!existsSync(process.env.FM_CHILD_PID_FILE)) return false;
    const child = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
    return child && child !== previousChild && pidAlive(child);
  }, `${reason} replacement child`);
  const live = liveArmPids();
  if (live.length !== 1) {
    throw new Error(`${reason} expected exactly one live arm child, got ${live.join(",") || "(none)"}`);
  }
  return next;
}

let current = await replaceSession(startup, "new");
current = await replaceSession(current, "resume");
current = await replaceSession(current, "fork");

// Same bound instance: ordinary shutdown then session_start without a fresh factory.
const sameInstanceChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
await current.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
const sameInstanceArm = await current.getTool().execute("same-instance", {}, undefined, undefined, {});
if (!sameInstanceArm.details?.ok || String(sameInstanceArm.details.message).includes("shutting down")) {
  throw new Error(`same-instance replacement arm failed: ${JSON.stringify(sameInstanceArm.details)}`);
}
await waitFor(() => {
  if (!existsSync(process.env.FM_CHILD_PID_FILE)) return false;
  const child = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
  return child !== sameInstanceChild && pidAlive(child);
}, "same-instance replacement child");
await waitFor(() => !pidAlive(sameInstanceChild), "same-instance previous child exit");
if (liveArmPids().length !== 1) {
  throw new Error(`same-instance expected one live arm child, got ${liveArmPids().join(",")}`);
}

// Stale prior-generation callback must not stop, rearm, or clear the active generation.
const activeChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
const stale = await staleTool.execute("stale-prior-generation", {}, undefined, undefined, {});
if (stale.details?.ok !== false || !String(stale.details.message).includes("shutting down")) {
  throw new Error(`stale prior generation did not refuse: ${JSON.stringify(stale.details)}`);
}
if (!pidAlive(activeChild)) throw new Error("active generation child died after stale callback");
if (pidAlive(startupChild)) throw new Error("startup generation child was resurrected");
if (liveArmPids().length !== 1 || liveArmPids()[0] !== activeChild) {
  throw new Error(`stale callback mutated live arm set: ${liveArmPids().join(",")}`);
}
const redundant = await current.getTool().execute("redundant", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`active generation lost single-flight ownership: ${JSON.stringify(redundant.details)}`);
}

// Repeated transitions keep exactly one live cycle and never revive the refusal.
for (const reason of ["resume", "fork", "new", "resume"]) {
  current = await replaceSession(current, reason);
}

// Real terminal shutdown still blocks late rearming.
const finalChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
await waitFor(() => !pidAlive(finalChild), "terminal shutdown child exit");
const quitArm = await current.getTool().execute("after-quit", {}, undefined, undefined, {});
if (quitArm.details?.ok !== false || quitArm.details.message !== "watcher: not armed - Pi session is shutting down") {
  throw new Error(`terminal quit must keep the shutting-down refusal: ${JSON.stringify(quitArm.details)}`);
}
if (liveArmPids().length !== 0) {
  throw new Error(`terminal quit left live arm children: ${liveArmPids().join(",")}`);
}
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi session transitions must rearm through an explicit generation owner" "$out"
  pass "Pi session transitions use a generation owner across /new /resume /fork, stale callbacks, and quit"
}

test_pi_process_exit_cleanup_listener_lifecycle() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-exit-listener-root"
  home="$TMP_ROOT/pi-exit-listener-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async () => {},
};
const before = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("Pi extension did not install exactly one process-exit fallback");
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("session_shutdown removed the process-lifetime exit fallback");
}
await handlers.get("session_start")?.({ type: "session_start" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("replacement activation duplicated the process-exit fallback");
}
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi cleanup fallback listener must remain singular across session replacement" "$out"
  pass "Pi process-exit cleanup listener remains singular across session replacement"
}

test_pi_process_exit_cleanup_stops_arm_child() {
  local repo home plugin cleanup_log pid_file out status pid i
  local cleanup_window_ms cleanup_poll_ms cleanup_attempts cleanup_poll_s
  repo="$TMP_ROOT/pi-process-exit-root"
  home="$TMP_ROOT/pi-process-exit-home"
  cleanup_log="$TMP_ROOT/pi-process-exit-cleaned"
  pid_file="$TMP_ROOT/pi-process-exit-child.pid"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "%s\n" "$$" >> "$FM_CLEANUP_LOG"; exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-exit", {}, undefined, undefined, {});
const childWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const childDeadlineAt = Date.now() + childWindowMs;
const childPollMs = Math.ceil(childWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!existsSync(process.env.FM_CHILD_PID_FILE) && Date.now() < childDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, childPollMs));
}
if (!existsSync(process.env.FM_CHILD_PID_FILE)) throw new Error("arm child did not start");
const firstChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
await handlers.get("session_start")?.({ type: "session_start" }, {});
await tool.execute("tool-call-replacement", {}, undefined, undefined, {});
const replacementWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const replacementDeadlineAt = Date.now() + replacementWindowMs;
const replacementPollMs = Math.ceil(replacementWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < replacementDeadlineAt) {
  const currentChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
  if (currentChild !== firstChild) break;
  await new Promise((resolve) => setTimeout(resolve, replacementPollMs));
}
if (readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim() === firstChild) {
  throw new Error("replacement arm child did not start");
}
process.exit(0);
EOF
)
  status=$?
  expect_driver_ok "$status" "Pi process exit must run the watcher cleanup fallback" "$out"
  pid=$(cat "$pid_file")
  # Wall-clock bound on a child-process wait, so it is derived like every other
  # bound of that class in this file rather than left a literal - not because it
  # had failed. The fixture body is `while :; do sleep 1; done`, so the TERM
  # trap is deferred by at most one `sleep 1` plus the arm child's own start:
  # about 1.8s at an 800ms fork cost, against the literal 250 x 20ms = 5s this
  # replaces, which is roughly 2.8x and had not been observed reaching a false
  # red. The literal is the problem regardless, because 1s of it is fixed and
  # the rest moves with the machine while 5000 does not.
  cleanup_window_ms=$(fm_observe_window_ms 1 1000)
  cleanup_poll_ms=$(fm_observe_poll_ms "$cleanup_window_ms")
  cleanup_attempts=$(fm_observe_attempts "$cleanup_window_ms" "$cleanup_poll_ms")
  cleanup_poll_s=$(fm_ms_to_seconds "$cleanup_poll_ms")
  i=0
  while [ "$i" -lt "$cleanup_attempts" ] && ! grep -qx "$pid" "$cleanup_log" 2>/dev/null; do
    sleep "$cleanup_poll_s"
    i=$((i + 1))
  done
  grep -qx "$pid" "$cleanup_log" 2>/dev/null || fail "Pi process-exit fallback did not deliver TERM to the replacement arm child"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_opencode_plugin_package_boundary_is_explicit_esm() {
  local fixture plugin out status
  fixture="$TMP_ROOT/opencode-esm-boundary/.opencode"
  plugin="$fixture/plugins/fm-primary-watch-arm.js"
  mkdir -p "$fixture/plugins/lib"
  printf '%s\n' '{"dependencies":{}}' > "$fixture/package.json"
  cp "$ROOT/.opencode/plugins/package.json" "$fixture/plugins/package.json"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$fixture/plugins/lib/fm-operational-input.js"
  out=$(PLUGIN="$plugin" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
await import(pathToFileURL(process.env.PLUGIN).href);
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode plugin must import beneath an explicit ESM package boundary" "$out"
  pass "OpenCode plugins have an explicit ESM boundary even under a typeless parent package"
}

test_opencode_primary_watch_plugin_uses_effective_state_home() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-state-root"
  home="$TMP_ROOT/opencode-effective-state-home"
  log="$TMP_ROOT/opencode-effective-state.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s root=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const armWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const armDeadlineAt = Date.now() + armWindowMs;
const armPollMs = Math.ceil(armWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!existsSync(process.env.FM_ARM_LOG) && Date.now() < armDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, armPollMs));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
const expectedRoot = realpathSync(process.env.WORKTREE);
if (!text.includes(`home=${process.env.FM_HOME}`) || !text.includes(`root=${expectedRoot}`)) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode watch plugin must use FM_HOME state outside the repo root" "$out"
  pass "OpenCode watcher plugin uses the effective FM_HOME state"
}

test_opencode_primary_watch_plugin_sources_effective_config() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-config-root"
  home="$TMP_ROOT/opencode-effective-config-home"
  log="$TMP_ROOT/opencode-effective-config.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  printf 'export FM_POLL=7\n' > "$home/config/x-mode.env"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'poll=%s\n' "${FM_POLL:-missing}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const armWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const armDeadlineAt = Date.now() + armWindowMs;
const armPollMs = Math.ceil(armWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!existsSync(process.env.FM_ARM_LOG) && Date.now() < armDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, armPollMs));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
if (!text.includes("poll=7")) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode watch plugin must source FM_HOME config outside the repo root" "$out"
  pass "OpenCode watcher plugin sources the effective config"
}

test_opencode_primary_watch_plugin_requires_session_lock() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-lock-root"
  home="$TMP_ROOT/opencode-lock-home"
  log="$TMP_ROOT/opencode-lock.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "999999\n");
await hooks.event(event);
// The event hook starts the arm decision without awaiting it, and refusing an
// unowned lock walks the parent-pid chain with up to eight `ps` spawns, so any
// fixed pause here is a bet on process-start cost. Settle the decision
// instead: the coordinator coalesces onto the same in-flight evaluation and
// resolves when it does, so the owned-lock event below starts from a finished
// verdict rather than inheriting this refusal.
const refusal = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (refusal !== "read-only") {
  console.error(`an unowned session lock did not refuse the arm: ${refusal}`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm ran without owning the session lock");
  process.exit(1);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
const armWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const armDeadlineAt = Date.now() + armWindowMs;
const armPollMs = Math.ceil(armWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!existsSync(process.env.FM_ARM_LOG) && Date.now() < armDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, armPollMs));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run after the session lock matched");
  process.exit(1);
}
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode watch plugin must arm only when this session owns the fleet lock" "$out"
  pass "OpenCode watcher plugin requires session lock ownership"
}

test_opencode_watch_arm_coordinator_respects_primary_scope() {
  local plugin base repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  base="$TMP_ROOT/opencode-coordinator-base"
  repo="$TMP_ROOT/opencode-coordinator-wt"
  home="$TMP_ROOT/opencode-coordinator-home"
  log="$TMP_ROOT/opencode-coordinator.log"
  fm_git_worktree "$base" "$repo" fm/opencode-coordinator
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
await new Promise((resolve) => setTimeout(resolve, Number(process.env.FM_TEST_ARM_START_BUDGET_MS)));
if (status !== "not-primary") {
  console.error(`expected not-primary, got ${status}`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("coordinator armed from a linked worktree");
  process.exit(1);
}
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode watch coordinator must keep primary scope checks in the shared arm path" "$out"
  pass "OpenCode watcher coordinator respects primary scope"
}

test_opencode_primary_watch_plugin_rearms_after_wake() {
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-rearm-root"
  home="$TMP_ROOT/opencode-rearm-home"
  log="$TMP_ROOT/opencode-rearm.log"
  stop="$TMP_ROOT/opencode-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
let rowsAtPrompt = 0;
let releasePrompt = () => {};
const promptBlocked = new Promise((resolve) => {
  releasePrompt = resolve;
});
const client = {
  session: {
    promptAsync: async () => {
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
      prompts += 1;
      await promptBlocked;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
const successorWindowMs = 2 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const successorDeadlineAt = Date.now() + successorWindowMs;
const successorPollMs = Math.ceil(successorWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < successorDeadlineAt) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && prompts >= 1) break;
  await new Promise((resolve) => setTimeout(resolve, successorPollMs));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}: ${rows.join(" | ")}`);
if (prompts !== 1) throw new Error(`expected one blocked wake prompt, got ${prompts}`);
if (rowsAtPrompt !== 2) throw new Error(`wake prompt began before successor establishment (${rowsAtPrompt} arm rows)`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor did not receive predecessor identity: ${rows[1]}`);
await new Promise((resolve) => setTimeout(resolve, Number(process.env.FM_TEST_ARM_START_BUDGET_MS)));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`delivery was confirmed before the prompt succeeded: ${stableRows.join(" | ")}`);
releasePrompt();
const confirmWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const confirmDeadlineAt = Date.now() + confirmWindowMs;
const confirmPollMs = Math.ceil(confirmWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < confirmDeadlineAt) {
  if (readFileSync(process.env.FM_ARM_LOG, "utf8").includes("confirmed generation=fixture-generation")) break;
  await new Promise((resolve) => setTimeout(resolve, confirmPollMs));
}
const confirmedRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (confirmedRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${confirmedRows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
  )
  status=$?
  expect_driver_ok "$status" "OpenCode watch plugin must start one successor before wake prompt delivery settles" "$out"
  pass "OpenCode watcher plugin starts one successor before wake prompt delivery settles"
}

test_opencode_pre_ready_actionable_close_preserves_its_successor() {
  local plugin repo home log release retired stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-pre-ready-actionable-root"
  home="$TMP_ROOT/opencode-pre-ready-actionable-home"
  log="$TMP_ROOT/opencode-pre-ready-actionable.log"
  release="$TMP_ROOT/opencode-pre-ready-actionable.release"
  retired="$TMP_ROOT/opencode-pre-ready-actionable.retired"
  stop="$TMP_ROOT/opencode-pre-ready-actionable.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  printf 'signal: pre-ready successor wake\n'
  trap 'printf "retired\\n" > "${FM_PRE_READY_RETIRED_FILE:?}"; exit 0' TERM INT
  while [ ! -e "$FM_PRE_READY_RELEASE_FILE" ]; do sleep 0.02; done
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_PRE_READY_RELEASE_FILE="$release" FM_PRE_READY_RETIRED_FILE="$retired" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const preReadyWindowMs = 2 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const preReadyDeadlineAt = Date.now() + preReadyWindowMs;
const preReadyPollMs = Math.ceil(preReadyWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < preReadyDeadlineAt) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && prompts.some((message) => message.includes("original wake"))) break;
  await new Promise((resolve) => setTimeout(resolve, preReadyPollMs));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`pre-ready successor was replaced before its close: ${rows.join(" | ")}`);
if (!prompts.some((message) => message.includes("original wake"))) throw new Error(`original actionable wake was not delivered: ${prompts.join(" | ")}`);
await new Promise((resolve) => setTimeout(resolve, Number(process.env.FM_TEST_ARM_START_BUDGET_MS)));
if (existsSync(process.env.FM_PRE_READY_RETIRED_FILE)) throw new Error("pre-ready actionable successor was retired before its close");
writeFileSync(process.env.FM_PRE_READY_RELEASE_FILE, "release\n");
const preReadySuccessorWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const preReadySuccessorDeadlineAt = Date.now() + preReadySuccessorWindowMs;
const preReadySuccessorPollMs = Math.ceil(preReadySuccessorWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < preReadySuccessorDeadlineAt) {
  const successorRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (successorRows.length >= 3 && prompts.some((message) => message.includes("pre-ready successor wake"))) break;
  await new Promise((resolve) => setTimeout(resolve, preReadySuccessorPollMs));
}
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 3) throw new Error(`pre-ready close did not create exactly one successor: ${stableRows.join(" | ")}`);
if (!prompts.some((message) => message.includes("pre-ready successor wake"))) throw new Error(`pre-ready actionable wake was not delivered: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode must retire the pre-ready arm, not its actionable successor" "$out"
  pass "OpenCode pre-ready actionable close preserves its successor"
}

test_opencode_hung_successor_falls_back_to_typed_wake() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-hung-successor-root"
  home="$TMP_ROOT/opencode-hung-successor-home"
  log="$TMP_ROOT/opencode-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_WAKE_DEADLINE_MS="$(fm_recovery_deadline_ms 3 1000)" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
// -1, not 0, so "no delivery was ever observed" cannot be reported as
// "a wake arrived with an empty arm log" - two different failures.
let rowsAtPrompt = -1;
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const wakeWindowMs = Number(process.env.FM_WAKE_DEADLINE_MS);
const deadlineAt = Date.now() + wakeWindowMs;
const wakePollMs = Math.ceil(wakeWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!prompt && Date.now() < deadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, wakePollMs));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 4) throw new Error(`expected one successor plus two retries, got ${rows.length}: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(rowsAtPrompt < 0
  ? `no wake delivery was observed at all; arm log holds ${rows.length} rows`
  : `wake arrived before restoration exhausted (${rowsAtPrompt} of ${rows.length} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, Number(process.env.FM_TEST_ARM_START_BUDGET_MS)));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode must deliver the actionable wake after bounded hung-successor recovery" "$out"
  pass "OpenCode hung successor falls back to one typed actionable wake"
}

test_opencode_unretired_successor_falls_back_without_retry() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-unretired-successor-root"
  home="$TMP_ROOT/opencode-unretired-successor-home"
  log="$TMP_ROOT/opencode-unretired-successor.log"
  release="$TMP_ROOT/opencode-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_WAKE_DEADLINE_MS="$(fm_recovery_deadline_ms 1 20)" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
let rowsAtPrompt = -1;
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const wakeWindowMs = Number(process.env.FM_WAKE_DEADLINE_MS);
const deadlineAt = Date.now() + wakeWindowMs;
const wakePollMs = Math.ceil(wakeWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!prompt && Date.now() < deadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, wakePollMs));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`unretired arm overlapped a retry: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(rowsAtPrompt < 0
  ? `no wake delivery was observed at all; arm log holds ${rows.length} rows`
  : `wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode must fall back without overlapping an unretired successor" "$out"
  pass "OpenCode unretired successor falls back without an overlapping retry"
}

test_opencode_late_unretired_close_resumes_supervision() {
  local kind plugin repo home log ready retired release stop out status
  for kind in actionable non-actionable; do
    plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
    repo="$TMP_ROOT/opencode-late-$kind-root"
    home="$TMP_ROOT/opencode-late-$kind-home"
    log="$TMP_ROOT/opencode-late-$kind.log"
    ready="$TMP_ROOT/opencode-late-$kind.ready"
    retired="$TMP_ROOT/opencode-late-$kind.retired"
    release="$TMP_ROOT/opencode-late-$kind.release"
    stop="$TMP_ROOT/opencode-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    git init -q "$repo"
    : > "$repo/AGENTS.md"
    : > "$home/state/task.meta"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  trap 'printf "retired\\n" > "${FM_UNRETIRED_RETIRE_FILE:?}"' TERM INT
  printf 'ready\n' > "${FM_UNRETIRED_READY_FILE:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_WAKE_DEADLINE_MS="$(fm_recovery_deadline_ms 1 20)" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  const wakeWindowMs = Number(process.env.FM_WAKE_DEADLINE_MS);
  const deadlineAt = Date.now() + wakeWindowMs;
  const wakePollMs = Math.ceil(wakeWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
  while (Date.now() < deadlineAt) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, wakePollMs));
  }
  if (predicate()) return;
  throw new Error(message);
}
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_READY_FILE),
  "unretired successor did not enter its retirement wait",
);
await waitFor(() => prompts.length >= 1, "original fallback was not delivered");
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_RETIRE_FILE),
  "unretired successor was not asked to retire before fallback",
);
if (rows().length !== 2) throw new Error(`unretired arm overlapped before fallback: ${rows().join(" | ")}`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
const lateWindowMs = Number(process.env.FM_WAKE_DEADLINE_MS);
const lateDeadlineAt = Date.now() + lateWindowMs;
const latePollMs = Math.ceil(lateWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < lateDeadlineAt) {
  if (rows().length >= 3 && (process.env.FM_LATE_KIND !== "actionable" || prompts.some((message) => message.includes("late wake")))) break;
  await new Promise((resolve) => setTimeout(resolve, latePollMs));
}
if (rows().length !== 3) throw new Error(`late close did not restore one successor: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
    status=$?
    expect_driver_ok "$status" "OpenCode late $kind close must remain supervised after fallback" "$out"
  done
  pass "OpenCode late unretired closes resume classified supervision"
}

test_opencode_empty_close_retries_instead_of_disappearing() {
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-empty-close-root"
  home="$TMP_ROOT/opencode-empty-close-home"
  log="$TMP_ROOT/opencode-empty-close.log"
  stop="$TMP_ROOT/opencode-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const successorWindowMs = 2 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const successorDeadlineAt = Date.now() + successorWindowMs;
const successorPollMs = Math.ceil(successorWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (Date.now() < successorDeadlineAt) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2) break;
  await new Promise((resolve) => setTimeout(resolve, successorPollMs));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode clean empty close must trigger a bounded continuity retry" "$out"
  pass "OpenCode clean empty close triggers a bounded continuity retry"
}

test_opencode_established_empty_close_honors_retry_limit() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-established-empty-close-root"
  home="$TMP_ROOT/opencode-established-empty-close-home"
  log="$TMP_ROOT/opencode-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS="$REARM_RETRY_MAX_MS" FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const retryWindowMs = 3 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const retryDeadlineAt = Date.now() + retryWindowMs;
const retryPollMs = Math.ceil(retryWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!prompt && Date.now() < retryDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, retryPollMs));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode established clean closes must honor the continuity retry limit" "$out"
  pass "OpenCode established clean closes stop at the configured retry limit"
}

test_opencode_actionable_close_rechecks_session_lock() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-close-lock-root"
  home="$TMP_ROOT/opencode-close-lock-home"
  log="$TMP_ROOT/opencode-close-lock.log"
  release="$TMP_ROOT/opencode-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const eventPromise = hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const armWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const armDeadlineAt = Date.now() + armWindowMs;
const armPollMs = Math.ceil(armWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!existsSync(process.env.FM_ARM_LOG) && Date.now() < armDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, armPollMs));
}
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  await eventPromise;
  const lockLossWindowMs = 2 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
    + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
  const lockLossDeadlineAt = Date.now() + lockLossWindowMs;
  const lockLossPollMs = Math.ceil(lockLossWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
  while (!prompt.includes("no longer owns the lock") && Date.now() < lockLossDeadlineAt) {
    await new Promise((resolve) => setTimeout(resolve, lockLossPollMs));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
}
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode close handler must verify session-lock ownership before successor launch" "$out"
  pass "OpenCode close handler verifies session-lock ownership before successor launch"
}

test_opencode_watch_arm_coordinates_with_turnend_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-coordinate-root"
  home="$TMP_ROOT/opencode-coordinate-home"
  log="$TMP_ROOT/opencode-coordinate-arm.log"
  guard_log="$TMP_ROOT/opencode-coordinate-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard should not run\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const armWindowMs = 1 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const armDeadlineAt = Date.now() + armWindowMs;
const armPollMs = Math.ceil(armWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!existsSync(process.env.FM_ARM_LOG) && Date.now() < armDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, armPollMs));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard ran before the watch arm could establish supervision");
  process.exit(1);
}
if (promptBody) {
  console.error(`unexpected prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode turn-end guard must let the auto-arm plugin establish supervision first" "$out"
  pass "OpenCode watcher plugin coordinates with the turn-end guard"
}

test_opencode_healthy_arm_output_does_not_suppress_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-external-healthy-root"
  home="$TMP_ROOT/opencode-external-healthy-home"
  log="$TMP_ROOT/opencode-external-healthy-arm.log"
  guard_log="$TMP_ROOT/opencode-external-healthy-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard ran after external healthy watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const guardWindowMs = 2 * Number(process.env.FM_TEST_ARM_START_BUDGET_MS)
  + Number(process.env.FM_TEST_OBSERVE_SLACK_MS);
const guardDeadlineAt = Date.now() + guardWindowMs;
const guardPollMs = Math.ceil(guardWindowMs / Number(process.env.FM_TEST_OBSERVE_POLL_DIVISOR));
while (!existsSync(process.env.FM_GUARD_LOG) && Date.now() < guardDeadlineAt) {
  await new Promise((resolve) => setTimeout(resolve, guardPollMs));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (!readFileSync(process.env.FM_ARM_LOG, "utf8").includes("args=--restart")) {
  console.error("watch arm was not asked to restart into an owned child");
  process.exit(1);
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard was suppressed by an external healthy watcher");
  process.exit(1);
}
if (!promptBody.includes("TURN WOULD END BLIND")) {
  console.error(`missing blind-turn prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_driver_ok "$status" "OpenCode watch plugin must not treat external healthy output as an owned arm" "$out"
  pass "OpenCode healthy arm output does not suppress the turn-end guard"
}

# Fault injection for the one stdin write each turn-end guard makes.
#
# Both guards hand their stop-hook payload to the child with
# `child.stdin.end(...)`. A guard that exits before draining that pipe makes the
# write fail with EPIPE, and the error arrives on the stdin stream rather than on
# the ChildProcess, so `child.on("error")` never sees it and node escalates it to
# an unhandled error that kills the host session.
#
# The payload is a fixed 26 bytes, which fits the pipe buffer, so the real race
# cannot be lost on demand: the parent's first write attempt lands microseconds
# after the fork and almost always beats the child's exit. Repeating the case
# until it loses is what the workstation campaign did, at 7 failures in 200 runs
# - too weak to protect a one-line listener.
#
# So the refusal is injected where the kernel would raise it. A loader hook
# redirects `node:child_process` to a shim that spawns the real guard - real
# argv, real exit code, real stderr - and replaces only that child's stdin with
# a stream whose first write fails EPIPE. Everything the guard concludes still
# travels the real path; the single question under test is what each site does
# with a refused write.
install_refused_stdin_write_shim() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/cp-shim.mjs" <<'JS'
export * from "node:child_process";
import { spawn as spawnReal } from "node:child_process";
import { writeFileSync } from "node:fs";
import { Writable } from "node:stream";

const target = process.env.FM_REFUSED_STDIN_TARGET || "";

export function spawn(command, args, options) {
  const child = spawnReal(command, args, options);
  if (!target || !String(command).endsWith(target)) return child;
  child.stdin?.destroy();
  child.stdin = new Writable({
    write(_chunk, _encoding, done) {
      done(Object.assign(new Error("write EPIPE"), { code: "EPIPE", syscall: "write" }));
    },
  });
  // Recorded at the assignment itself, because every other signal a driver can
  // read is identical whether or not the swap happened: the real guard is
  // spawned either way, writes its 26 bytes into a real pipe successfully, and
  // still exits 2. Without this marker a shim that silently stopped matching
  // would leave the whole case green with the listener deleted.
  writeFileSync(process.env.FM_REFUSED_STDIN_MARKER, `${command}\n`);
  return child;
}
JS
  cat > "$dir/cp-hooks.mjs" <<'JS'
import { pathToFileURL } from "node:url";

const shim = pathToFileURL(process.env.FM_CHILD_PROCESS_SHIM).href;

export async function resolve(specifier, context, next) {
  if (specifier === "node:child_process" && context.parentURL !== shim) {
    return { url: shim, shortCircuit: true };
  }
  return next(specifier, context);
}
JS
}

test_opencode_turnend_guard_survives_a_refused_stdin_write() {
  local guard_plugin repo home shim guard_log swap_marker out status
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-guard-refused-stdin-root"
  home="$TMP_ROOT/opencode-guard-refused-stdin-home"
  shim="$TMP_ROOT/opencode-guard-refused-stdin-shim"
  guard_log="$TMP_ROOT/opencode-guard-refused-stdin.log"
  swap_marker="$TMP_ROOT/opencode-guard-refused-stdin.swap"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  install_refused_stdin_write_shim "$shim"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
# Both guards prepend their own "TURN WOULD END BLIND - supervision is off. "
# prose before appending this stream, so anything resembling that sentence
# would be found in the prompt whether or not the child's stderr arrived.
printf 'guard-stderr-marker-4f2a\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_GUARD_LOG="$guard_log" \
    FM_CHILD_PROCESS_SHIM="$shim/cp-shim.mjs" FM_CP_HOOKS="$shim/cp-hooks.mjs" \
    FM_REFUSED_STDIN_TARGET=bin/fm-turnend-guard.sh FM_REFUSED_STDIN_MARKER="$swap_marker" \
    node --input-type=module 2>&1 <<'EOF'
import { register } from "node:module";
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

register(pathToFileURL(process.env.FM_CP_HOOKS).href);
const mod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!existsSync(process.env.FM_REFUSED_STDIN_MARKER)) {
  throw new Error("no stdin write was ever refused: the shim did not replace the guard child's stdin");
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  throw new Error("the real guard never ran, so no stdin write was refused");
}
if (!promptBody.includes("TURN WOULD END BLIND")) {
  throw new Error(`a refused stdin write lost the guard's blocking verdict: ${promptBody}`);
}
if (!promptBody.includes("guard-stderr-marker-4f2a")) {
  throw new Error(`a refused stdin write lost the guard's own stderr: ${promptBody}`);
}
EOF
)
  status=$?
  # An unguarded write escapes as an unhandled stream error that takes the host
  # session down, so the driver surviving at all is half the assertion.
  case $out in
    *EPIPE*|*"Unhandled 'error' event"*)
      fail "OpenCode turn-end guard let a refused stdin write escape: $out" ;;
  esac
  expect_driver_ok "$status" "OpenCode turn-end guard must survive a refused stdin write and still deliver its verdict" "$out"
  pass "OpenCode turn-end guard reports its verdict when the stdin write is refused"
}

test_pi_turnend_guard_survives_a_refused_stdin_write() {
  local ext repo home shim guard_log swap_marker out status
  ext="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  repo="$TMP_ROOT/pi-guard-refused-stdin-root"
  home="$TMP_ROOT/pi-guard-refused-stdin-home"
  shim="$TMP_ROOT/pi-guard-refused-stdin-shim"
  guard_log="$TMP_ROOT/pi-guard-refused-stdin.log"
  swap_marker="$TMP_ROOT/pi-guard-refused-stdin.swap"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state" "$home/config"
  cp "$ext" "$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  install_refused_stdin_write_shim "$shim"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
# Both guards prepend their own "TURN WOULD END BLIND - supervision is off. "
# prose before appending this stream, so anything resembling that sentence
# would be found in the prompt whether or not the child's stderr arrived.
printf 'guard-stderr-marker-4f2a\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(EXTENSION="$repo/.pi/extensions/fm-primary-turnend-guard.ts" FM_HOME="$home" FM_GUARD_LOG="$guard_log" \
    FM_CHILD_PROCESS_SHIM="$shim/cp-shim.mjs" FM_CP_HOOKS="$shim/cp-hooks.mjs" \
    FM_REFUSED_STDIN_TARGET=bin/fm-turnend-guard.sh FM_REFUSED_STDIN_MARKER="$swap_marker" \
    node --input-type=module 2>&1 <<'EOF'
import { register } from "node:module";
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

register(pathToFileURL(process.env.FM_CP_HOOKS).href);
const mod = await import(pathToFileURL(process.env.EXTENSION).href);
const handlers = new Map();
let message = "";
const pi = {
  on(name, handler) {
    handlers.set(name, handler);
  },
  sendMessage() {},
  sendUserMessage: async (content) => {
    message += content;
  },
};
mod.default(pi);
const settled = handlers.get("agent_settled");
if (!settled) throw new Error("the extension registered no agent_settled handler");
await settled({ type: "agent_settled" });
if (!existsSync(process.env.FM_REFUSED_STDIN_MARKER)) {
  throw new Error("no stdin write was ever refused: the shim did not replace the guard child's stdin");
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  throw new Error("the real guard never ran, so no stdin write was refused");
}
if (!message.includes("TURN WOULD END BLIND")) {
  throw new Error(`a refused stdin write lost the guard's blocking verdict: ${message}`);
}
if (!message.includes("guard-stderr-marker-4f2a")) {
  throw new Error(`a refused stdin write lost the guard's own stderr: ${message}`);
}
EOF
)
  status=$?
  case $out in
    *EPIPE*|*"Unhandled 'error' event"*)
      fail "Pi turn-end guard let a refused stdin write escape: $out" ;;
  esac
  expect_driver_ok "$status" "Pi turn-end guard must survive a refused stdin write and still deliver its verdict" "$out"
  pass "Pi turn-end guard reports its verdict when the stdin write is refused"
}

test_pi_extension_reports_external_healthy_watcher
test_pi_tool_returns_agent_tool_result
test_pi_redundant_tool_call_is_owned_noop
test_pi_scheduled_retry_call_is_owned_noop
test_pi_actionable_close_starts_single_successor_before_delivery
test_pi_hung_successor_falls_back_to_typed_wake
test_pi_unretired_successor_falls_back_without_retry
test_pi_late_unretired_close_resumes_supervision
test_pi_empty_close_retries_instead_of_disappearing
test_pi_established_empty_close_honors_retry_limit
test_pi_actionable_close_rechecks_session_lock
test_pi_arm_distinguishes_session_lock_ownership
test_pi_session_transition_generation_owner
test_pi_process_exit_cleanup_listener_lifecycle
test_pi_process_exit_cleanup_stops_arm_child
test_opencode_plugin_package_boundary_is_explicit_esm
test_opencode_primary_watch_plugin_uses_effective_state_home
test_opencode_primary_watch_plugin_sources_effective_config
test_opencode_primary_watch_plugin_requires_session_lock
test_opencode_watch_arm_coordinator_respects_primary_scope
test_opencode_primary_watch_plugin_rearms_after_wake
test_opencode_pre_ready_actionable_close_preserves_its_successor
test_opencode_hung_successor_falls_back_to_typed_wake
test_opencode_unretired_successor_falls_back_without_retry
test_opencode_late_unretired_close_resumes_supervision
test_opencode_empty_close_retries_instead_of_disappearing
test_opencode_established_empty_close_honors_retry_limit
test_opencode_actionable_close_rechecks_session_lock
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
test_opencode_turnend_guard_survives_a_refused_stdin_write
test_pi_turnend_guard_survives_a_refused_stdin_write
