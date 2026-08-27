#!/usr/bin/env bash
# End-to-end reproduction of the wedge this fix removes, driven through the real
# end-user CLI surface: bin/fm-lock.sh, which acquires the per-home firstmate
# session lock and reaches fm_lock_acquire_wait at bin/fm-lock.sh:115.
#
# Simulates a Git-for-Windows host whose %TEMP% carries an 8.3 SHORT component,
# using the same stub technique tests/fm-windows-portability.test.sh states for
# itself ("SIMULATING the capability that is missing rather than needing that
# platform"):
#   * the short component is a REAL directory, not a symlink, because an NTFS
#     8.3 name is not one - `cd .. && pwd -P` cannot see through it, which is
#     why fm_lock_abs_path leaves the short spelling in place and cygpath is the
#     only thing that can answer at all
#   * readlink answers with the canonical LONG spelling of a stored target, the
#     way MSYS resolves a native symlink back through its mount table
#   * cygpath renders each spelling as given for -m, and expands the short
#     component only when asked with -l
set -u
REPO=$1
ROOT=/tmp/fm-hang-repro
LONG=fmlockdemo-verylongdirname-1234
rm -rf "$ROOT"; mkdir -p "$ROOT/bin"

cat > "$ROOT/bin/readlink" <<'SH'
#!/usr/bin/env bash
out=$(/usr/bin/readlink "$@") || exit $?
printf '%s\n' "${out//FMLOCK~1/fmlockdemo-verylongdirname-1234}"
SH
cat > "$ROOT/bin/cygpath" <<'SH'
#!/usr/bin/env bash
expand=
for a in "$@"; do [ "$a" = "-l" ] && expand=1; done
p=${!#}
[ -n "$expand" ] && p=${p//FMLOCK~1/fmlockdemo-verylongdirname-1234}
printf 'C:%s\n' "$p"
SH
chmod +x "$ROOT/bin/readlink" "$ROOT/bin/cygpath"

# The caller's spelling is the SHORT one, exactly as %TEMP% hands it over.
STATE="$ROOT/FMLOCK~1/home/state"
mkdir -p "$STATE"

echo "The two spellings this host hands the lock layer:"
echo "  short (what the caller has): $STATE"
echo "  long  (what readlink says):  ${STATE//FMLOCK~1/$LONG}"
echo
echo "\$ readlink of a lock link stored at the short spelling"
ln -s "$STATE/probe.owner" "$ROOT/probe.lock"
echo "  ln -s stored: $STATE/probe.owner"
echo "  readlink    : $(PATH="$ROOT/bin:$PATH" readlink "$ROOT/probe.lock")"
echo "  -> the strict string compare in fm_lock_points_to_owner cannot match,"
echo "     so the whole verdict falls to fm_lock_same_path."
rm -f "$ROOT/probe.lock"
echo
echo "\$ cygpath, both spellings:"
printf '  -m    short: %s\n' "$(PATH="$ROOT/bin:$PATH" cygpath -m -- "$STATE")"
printf '  -m    long : %s\n' "$(PATH="$ROOT/bin:$PATH" cygpath -m -- "${STATE//FMLOCK~1/$LONG}")"
printf '  -m -l short: %s\n' "$(PATH="$ROOT/bin:$PATH" cygpath -m -l -- "$STATE")"
printf '  -m -l long : %s\n' "$(PATH="$ROOT/bin:$PATH" cygpath -m -l -- "${STATE//FMLOCK~1/$LONG}")"

run_case() {  # <label>
  echo
  echo "=============================================================="
  echo "$1"
  echo "=============================================================="
  rm -rf "$ROOT/FMLOCK~1"; mkdir -p "$STATE"
  echo "\$ timeout 25 fm-lock.sh      # FM_STATE_OVERRIDE=<short spelling>/state"
  local t0 t1 rc=0 out
  t0=$(date +%s)
  out=$(PATH="$ROOT/bin:$PATH" FM_HOME="$ROOT/FMLOCK~1/home" FM_STATE_OVERRIDE="$STATE" \
    timeout 25 bash "$REPO/bin/fm-lock.sh" 2>&1) || rc=$?
  t1=$(date +%s)
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ "$rc" = 124 ]; then
    echo "  *** NOTHING PRINTED. Still spinning after $((t1-t0))s; killed by timeout. ***"
    echo "  *** fm_lock_acquire_wait never returns - firstmate wedges, silently. ***"
  else
    echo "  exit=$rc after $((t1-t0))s"
  fi
  printf '  session lock on disk: '
  if [ -f "$STATE/.lock" ]; then echo "present, records pid $(cat "$STATE/.lock")"; else echo '<never created>'; fi
  return 0
}

cp "$REPO/bin/fm-path-lib.sh" "$ROOT/fm-path-lib.sh.shipped"
trap 'cp "$ROOT/fm-path-lib.sh.shipped" "$REPO/bin/fm-path-lib.sh"' EXIT

# --- BEFORE: the fix removed --------------------------------------------------
sed -i 's/cygpath -m -l -- "\$a"/cygpath -m -- "$a"/; s/cygpath -m -l -- "\$b"/cygpath -m -- "$b"/' \
  "$REPO/bin/fm-path-lib.sh"
echo
echo "fm_lock_same_path resolver in bin/fm-path-lib.sh: $(grep -o 'cygpath -m[^|]*-- "\$a"' "$REPO/bin/fm-path-lib.sh")"
run_case "BEFORE - resolved with 'cygpath -m', no -l (the pre-fix code)"

# --- AFTER: the shipped fix ---------------------------------------------------
cp "$ROOT/fm-path-lib.sh.shipped" "$REPO/bin/fm-path-lib.sh"
echo
echo "fm_lock_same_path resolver in bin/fm-path-lib.sh: $(grep -o 'cygpath -m[^|]*-- "\$a"' "$REPO/bin/fm-path-lib.sh")"
run_case "AFTER - resolved with 'cygpath -m -l' (the shipped fix)"
