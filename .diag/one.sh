#!/usr/bin/env bash
# Throwaway diagnostic runner: execute ONE case from a watcher-suite file.
# Usage: .diag/one.sh <source-test-file> <test-function-name>
# The single-case file is generated into tests/ at run time so it resolves
# tests/lib.sh exactly like the real suite and always runs the tracked bytes.
set -u
src=$1
first=$(grep -n '^test_pi_extension_reports_external_healthy_watcher$' "$src" | cut -d: -f1)
tmp=$(mktemp tests/diag-one-XXXXXX.test.sh)
head -n $((first - 1)) "$src" > "$tmp"
printf '%s\n' "$2" >> "$tmp"
bash "$tmp"
rc=$?
rm -f "$tmp"
exit $rc
