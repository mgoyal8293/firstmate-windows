#!/usr/bin/env bash
# Manual verification of two behaviours the change records:
#   1. docs/windows.md "Teardown refuses unlanded work" - fm-teardown.sh refuses
#      a local-only task whose commit is on the branch only.
#   2. docs/conpty-backend.md "Active limits" (new bullet) - teardown retires the
#      task's own records but leaves state/conpty/<session>/ and its
#      transcript.log behind, "on any host". Run here on Linux, which is what
#      "any host" claims.
# Drives the REAL bin/fm-teardown.sh; fixture shape copied from
# tests/fm-teardown.test.sh (fake treehouse/gh/no-mistakes, fake conpty node client).
set -u
ROOT=${1:?usage: <firstmate-checkout>}
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' EXIT
SESS=fmhome1-fm-task-x1
mkdir -p "$CASE/state/conpty/$SESS" "$CASE/config" "$CASE/fakebin"

for f in treehouse gh gh-axi no-mistakes tasks-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE/fakebin/$f"; chmod +x "$CASE/fakebin/$f"
done
cat > "$CASE/fakebin/node" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  health) printf 'absent\n'; exit 1 ;;
  exists) exit 1 ;;
esac
exit 0
SH
chmod +x "$CASE/fakebin/node"

git init -q --bare "$CASE/origin.git"
git -C "$CASE/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$CASE/origin.git" "$CASE/_seed" 2>/dev/null
git -C "$CASE/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
git -C "$CASE/_seed" push -q origin main
rm -rf "$CASE/_seed"
git clone -q "$CASE/origin.git" "$CASE/project"
git -C "$CASE/project" remote set-head origin main 2>/dev/null || true
git -C "$CASE/project" worktree add -q -b fm/task-x1 "$CASE/wt" main
touch "$CASE/state/.last-watcher-beat"

# the crewmate's real commit, on the task branch only
printf 'a real one-line change\n' > "$CASE/wt/note.txt"
git -C "$CASE/wt" -c user.email=t@t -c user.name=t add note.txt
git -C "$CASE/wt" -c user.email=t@t -c user.name=t commit -q -m "fix the typo"
COMMIT=$(git -C "$CASE/wt" rev-parse --short HEAD)
# the project is local-only: drop its remote so the branch is genuinely unlanded
git -C "$CASE/project" remote remove origin

cat > "$CASE/state/task-x1.meta" <<META
window=$SESS
conpty_session=$SESS
endpoint_task_id=task-x1
backend=conpty
worktree=$CASE/wt
project=$CASE/project
harness=claude
kind=ship
mode=local-only
META
printf 'session transcript from the crewmate run\n' > "$CASE/state/conpty/$SESS/transcript.log"
printf '{"id":"%s","status":"clean"}\n' "$SESS" > "$CASE/state/conpty/$SESS/session.json"

run_teardown() {
  env PATH="$CASE/fakebin:$PATH" \
      FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$CASE/state" \
      FM_CONFIG_OVERRIDE="$CASE/config" FM_HOME="$CASE" \
      FM_GATE_REFUSE_BYPASS=1 FM_BACKEND_CONPTY_ALLOW_NON_WINDOWS=1 \
      FM_BACKEND_CONPTY_STATE="$CASE/state/conpty" \
      "$ROOT/bin/fm-teardown.sh" task-x1 "$@" 2>&1
}
show_branches() {
  printf 'project branches : %s\n' "$(git -C "$CASE/project" branch --format='%(refname:short)' | tr '\n' ' ')"
}
show_state() {
  printf 'state/task-x1.* :'
  ls "$CASE/state" 2>/dev/null | grep '^task-x1' | tr '\n' ' ' || true
  [ -n "$(ls "$CASE/state" | grep '^task-x1' || true)" ] || printf ' (none - retired)'
  printf '\nstate/conpty/   : %s\n' "$(find "$CASE/state/conpty" -mindepth 1 -printf '%P\n' 2>/dev/null | sort | tr '\n' ' ')"
}

printf -- '--- the crewmate commit %s is on fm/task-x1 only\n' "$COMMIT"
git -C "$CASE/wt" log --oneline -1

printf -- '\n--- $ fm-teardown.sh task-x1   (work not landed)\n'
run_teardown; printf '[exit code %s]\n' "$?"
show_state

show_branches

printf -- '\n--- $ git merge --ff-only fm/task-x1   (the approved local landing)\n'
git -C "$CASE/project" merge --ff-only fm/task-x1 2>&1 | tail -2

printf -- '\n--- $ fm-teardown.sh task-x1   (after landing)\n'
run_teardown; printf '[exit code %s]\n' "$?"
show_state
show_branches
