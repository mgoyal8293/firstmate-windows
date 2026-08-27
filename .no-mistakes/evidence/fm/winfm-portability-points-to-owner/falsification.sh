#!/usr/bin/env bash
# Proves the new guard in tests/fm-windows-portability.test.sh falsifies: remove
# the fix, show it failing; restore it, show it passing. Also removes the
# protection in the OPPOSITE direction (an over-widening resolver) and in the
# fixture itself, so the guard is shown to catch all three ways it could rot.
set -u
REPO=$1
BAK=/tmp/fm-falsify; rm -rf "$BAK"; mkdir -p "$BAK"
cp "$REPO/bin/fm-path-lib.sh" "$BAK/path.shipped"
cp "$REPO/tests/fm-windows-portability.test.sh" "$BAK/test.shipped"
restore() {
  cp "$BAK/path.shipped" "$REPO/bin/fm-path-lib.sh"
  cp "$BAK/test.shipped" "$REPO/tests/fm-windows-portability.test.sh"
}
trap restore EXIT

run() {  # <label>
  echo
  echo "--------------------------------------------------------------"
  echo "$1"
  echo "--------------------------------------------------------------"
  echo "\$ bash tests/fm-windows-portability.test.sh"
  local rc=0 out
  out=$(bash "$REPO/tests/fm-windows-portability.test.sh" 2>&1) || rc=$?
  printf '%s\n' "$out" | grep -E '^(not ok|ok - fm_lock_same_path)' \
    || echo '  <no same-path line>'
  echo "  suite exit=$rc   cases passed=$(printf '%s\n' "$out" | grep -c '^ok -')"
}

restore
run "SHIPPED - the fix and the guard as they land"

restore
sed -i 's/cygpath -m -l -- "\$a"/cygpath -m -- "$a"/; s/cygpath -m -l -- "\$b"/cygpath -m -- "$b"/' \
  "$REPO/bin/fm-path-lib.sh"
echo; echo "[protection removed] fm_lock_same_path now resolves with: $(grep -o 'cygpath -m[^|]*-- "\$a"' "$REPO/bin/fm-path-lib.sh")"
run "FIX REMOVED - '-l' dropped from both cygpath calls"

restore
python3 - "$REPO/bin/fm-path-lib.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old='  [ "$wa" = "$wb" ]\n'
assert old in s
open(p,'w').write(s.replace(old,'  [ "${wa%.owner.*}" = "${wb%.owner.*}" ]\n'))
PY
echo; echo "[protection removed] the compare now ignores the owner suffix - an OVER-WIDENING resolver"
run "OVER-WIDENED - the resolver made sloppier instead of correct"

restore
sed -i 's|^\[ -n "\$expand" \] && p=\${p//SHORTDIR~1/shortdir-with-a-long-name}$|p=${p//SHORTDIR~1/shortdir-with-a-long-name}|' \
  "$REPO/tests/fm-windows-portability.test.sh"
echo; echo "[protection removed] the 8.3 stub now expands with or without -l, so the case could pass for the wrong reason"
run "FIXTURE MADE VACUOUS - the guard's own anti-vacuity assertion"

restore
run "RESTORED - back to the shipped fix and guard"
