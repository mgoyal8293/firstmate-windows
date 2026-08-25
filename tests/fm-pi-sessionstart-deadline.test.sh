#!/usr/bin/env bash
# tests/fm-pi-sessionstart-deadline.test.sh - the Pi transport must tell the
# session start that NOTHING kills it on a clock.
#
# WHY THIS IS ITS OWN SUITE. bin/fm-session-start-bound-lib.sh clamps the startup
# bound under the shortest REGISTERED session-start hook timeout whenever a kill
# deadline is established or cannot be ruled out. Pi arms no deadline at all:
# .pi/extensions/fm-primary-turnend-guard.ts spawns bin/fm-sessionstart-run.sh
# with no timeout option, no AbortSignal, no setTimeout and no child.kill, it
# truncates on BYTES at 512 KiB, and it resolves on `close`. So a Pi session was
# being clamped by a ceiling derived entirely from the Claude, Codex and Cursor
# registrations - harnesses that are not running - and, on truncation, told a kill
# second that does not exist there and pointed at registrations that could not buy
# it a second.
#
# The library half of that fix is mutation-proven in
# tests/fm-session-start-hook-nesting.test.sh. This suite covers the half that
# makes it fire in production: the extension actually declaring `none` at its own
# spawn site. Delete that one property and every Pi session start silently goes
# back to being clamped by a deadline that does not bind it.
#
# WHAT IS ASSERTED, AND WHY IT IS NOT A SOURCE GREP. Nothing here reads the
# extension's text. The real extension module is loaded, its real default export
# is called with a Pi-shaped stub, its real session_start handler is invoked, and
# the wrapper it spawns is replaced by a stub that reports the ENVIRONMENT IT WAS
# ACTUALLY GIVEN. The assertion is on that environment, so a refactor that moves
# the declaration still passes and a deleted declaration still fails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Node is the real consumer here, so its absence is a genuine skip. A node that
# runs but hands the child the wrong environment is NOT a skip - that is the
# defect this suite exists to catch, and it fails below.
command -v node >/dev/null 2>&1 || {
  printf 'note: node is not installed, so the Pi spawn environment is UNVERIFIED here\n' >&2
  pass "pi session-start deadline: SKIPPED - node is not available to load the extension"
  exit 0
}

PI_TMP_ROOT=$(fm_test_tmproot fm-pi-sessionstart-deadline)

# The extension resolves its own root as ../.. from its directory, so the fixture
# mirrors that shape: a throwaway root whose bin/ is the real bin/ except for the
# one wrapper, which is replaced by a recorder.
world="$PI_TMP_ROOT/world"
mkdir -p "$world/root/.pi/extensions/lib" "$world/root/bin" "$world/state"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$world/root/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$world/root/.pi/extensions/lib/"
for f in "$ROOT"/bin/*.sh; do
  ln -s "$f" "$world/root/bin/$(basename "$f")"
done
# The recorder stands in for the digest and reports only what it was handed.
rm -f "$world/root/bin/fm-sessionstart-run.sh"
cat > "$world/root/bin/fm-sessionstart-run.sh" <<'SH'
#!/bin/sh
printf 'FM_SESSION_START_HOOK_DEADLINE=[%s]\n' "${FM_SESSION_START_HOOK_DEADLINE:-<unset>}"
SH
chmod +x "$world/root/bin/fm-sessionstart-run.sh"

# The driver is the Pi side of the contract: it calls the extension's real
# default export with a stub that captures the registered session_start handler
# and whatever the extension injects, then fires the event Pi fires on /clear.
cat > "$world/drive.mjs" <<'JS'
const mod = await import(process.argv[2]);
let handler;
const pi = {
  on: (event, fn) => {
    if (event === "session_start") handler = fn;
  },
  sendMessage: (message) => {
    process.stdout.write(String(message.content) + "\n");
  },
};
mod.default(pi);
if (typeof handler !== "function") {
  console.error("the extension registered no session_start handler");
  process.exit(3);
}
await handler({ reason: "new" }, {});
JS

test_the_pi_transport_declares_that_no_deadline_binds() {
  local out rc
  out=$(FM_STATE_OVERRIDE="$world/state" node "$world/drive.mjs" \
    "$world/root/.pi/extensions/fm-primary-turnend-guard.ts" 2>&1)
  rc=$?

  # A node that cannot load the TypeScript extension at all is an unavailable
  # toolchain, not a defect in the declaration. Anything else is a real failure.
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qiE 'unknown file extension|strip-types|ERR_UNKNOWN_FILE_EXTENSION'; then
    printf 'note: this node cannot load a TypeScript extension, so the Pi spawn environment is UNVERIFIED here\n' >&2
    pass "pi session-start deadline: SKIPPED - this node build cannot load the .ts extension"
    return
  fi
  [ "$rc" -eq 0 ] \
    || fail "the Pi extension's session_start handler did not run to completion (rc ${rc}): $out"

  # The premise: the extension really did reach the wrapper. Without this a
  # silently swallowed spawn would leave the assertion below vacuous.
  case "$out" in
    *FM_SESSION_START_HOOK_DEADLINE=*) : ;;
    *) fail "the extension injected nothing from the session-start wrapper, so the spawn environment was never observed; got: $out" ;;
  esac

  # THE GUARD. Pi arms no kill deadline, so the digest it spawns must be told so
  # positively - otherwise the library treats it as bounded and clamps it under
  # registrations belonging to harnesses that are not running.
  case "$out" in
    *'FM_SESSION_START_HOOK_DEADLINE=[none]'*) : ;;
    *) fail "the Pi extension spawned the session start WITHOUT declaring that no kill deadline binds it, so that digest is clamped by the Claude, Codex and Cursor registrations and told a kill second that does not exist under Pi; the wrapper was handed: $out" ;;
  esac

  pass "pi session-start deadline: the extension declares 'none' to the digest it spawns, so a Pi session start is not clamped by another harness's registration"
}

test_the_pi_transport_declares_that_no_deadline_binds
