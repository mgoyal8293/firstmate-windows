#!/usr/bin/env bash
# Falsifiable demonstration of the fail-closed guard in bin/fm-file-mode-lib.sh.
#
# The mode predicates read a file's stored mode through fm_pr_file_mode, which
# bin/fm-pr-lib.sh owns. Splitting the predicates into their own file made
# "sourced without that owner" reachable: the capability probe would then compare
# an EMPTY reading against 644, conclude this filesystem does not enforce modes,
# and WAIVE the private-file mode assertion - a security probe failing open.
#
# The question asked below is the one the trust binding actually asks:
#   "does this 0644 file satisfy 'must be 0600'?"
# Correct answer on a mode-enforcing filesystem: NO.
set -u
ROOT=$1
ask() {  # <lib-root>
  local d; d=$(mktemp -d)
  bash -c '
    set -u
    . "$1/bin/fm-file-mode-lib.sh"
    f="$2/artifact"; : > "$f"; chmod 0644 "$f"
    if fm_pr_file_mode_is "$f" 600; then
      echo "WAIVED  - a 0644 file passes as 0600 (mode assertion dropped)"
    else
      echo "ENFORCED - a 0644 file is refused as 0600 (assertion holds)"
    fi
  ' _ "$1" "$d"
  rm -rf "$d"
}

echo "sourced ALONE, guard present (shipped):        $(ask "$ROOT")"

CTRL=$(mktemp -d); cp -r "$ROOT/bin" "$CTRL/bin"
grep -v 'command -v fm_pr_file_mode >/dev/null 2>&1 || return 0' \
  "$ROOT/bin/fm-file-mode-lib.sh" > "$CTRL/bin/fm-file-mode-lib.sh"
echo "sourced ALONE, that ONE line removed (control): $(ask "$CTRL")"
rm -rf "$CTRL"

echo
echo "production path - bin/fm-pr-lib.sh, the only sourcer, defines fm_pr_file_mode:"
bash -c '
  set -u
  . "$1/bin/fm-pr-lib.sh"
  d=$2
  f="$d/artifact"; : > "$f"; chmod 0644 "$f"
  fm_pr_file_mode_is "$f" 600 && echo "  0644 asked as 0600 -> WAIVED" || echo "  0644 asked as 0600 -> ENFORCED (refused)"
  chmod 0600 "$f"
  fm_pr_file_mode_is "$f" 600 && echo "  0600 asked as 0600 -> accepted" || echo "  0600 asked as 0600 -> REFUSED (regression)"
' _ "$ROOT" "$(mktemp -d)"
