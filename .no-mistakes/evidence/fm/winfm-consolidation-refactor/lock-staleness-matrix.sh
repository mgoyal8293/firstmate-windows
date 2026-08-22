#!/usr/bin/env bash
# The git-lock staleness proof (bin/fm-lock-lib.sh) across the /proc substitute
# that bin/fm-lock-proc-lib.sh now owns. This is the decision fm-teardown.sh and
# fm-fleet-sync.sh act on: "0/stale" means the abandoned index.lock or
# packed-refs.lock is removed, anything else means it is left in place.
#
# lsof is hidden from PATH in every row, which is the Git for Windows condition.
set -u
ROOT=$1
TOP=$(mktemp -d "${TMPDIR:-/tmp}/fm-stale-XXXXXX")
NOLSOF="$TOP/nolsof"; mkdir -p "$NOLSOF"
for t in bash cat sed grep ls stat date readlink dirname basename rm mkdir tr uname sleep touch printf wc head tail cut awk mktemp env; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$NOLSOF/$t"
done
trap 'rm -rf "$TOP"' EXIT

ask() {  # <uname> <label> <holder:yes|no>
  local uname=$1 label=$2 holder=$3 d lock rc holderpid=
  d=$(mktemp -d "$TOP/case-XXXXXX"); lock="$d/index.lock"; : > "$lock"
  touch -d '10 minutes ago' "$lock"
  if [ "$holder" = yes ]; then
    # A live process holding the lock file open on an fd, exactly as git does.
    bash -c 'exec 9<"$1"; while [ ! -e "$1.go" ]; do sleep 0.05; done' _ "$lock" &
    holderpid=$!
    sleep 0.4
  fi
  rc=$(PATH="$NOLSOF" FM_PROC_UNAME_S=$uname FM_PLATFORM_UNAME_OVERRIDE=$uname \
    "$BASH" -c '. "$1/bin/fm-lock-lib.sh"; fm_lock_is_provably_stale "$2" "$3" 60; echo $?' \
    _ "$ROOT" "$lock" "$d" 2>/dev/null)
  [ -n "$holderpid" ] && { : > "$lock.go"; wait "$holderpid" 2>/dev/null; }
  if [ "$rc" = 0 ]; then printf '%-62s | PROVABLY STALE (caller removes it)\n' "$label"
  else printf '%-62s | not provable (caller leaves it in place)\n' "$label"; fi
}

echo "### git-lock staleness with no lsof on PATH"
ask MINGW64_NT-10.0-26200 "Windows, abandoned lock, no live holder"      no
ask MINGW64_NT-10.0-26200 "Windows, a live process holds the lock open"  yes
ask Linux                 "POSIX host, abandoned lock (lsof missing)"    no
ask Linux                 "POSIX host, a live process holds it open"     yes
