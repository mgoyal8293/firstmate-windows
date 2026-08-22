#!/usr/bin/env bash
# Reproduce the audit's friction metric.
#
# Method (as stated in data/winfm-tool-substitution-audit/report.md section 3):
#   git diff --numstat <merge-base>..<rev>, counting ADDED lines only in paths
#   that EXIST at the merge-base. A file the port created never conflicts on an
#   upstream intake, so it is not friction.
set -eu
BASE=${1:-d023c451}
REV=${2:-HEAD}
files=0; added=0; deleted=0
while IFS=$'\t' read -r a d p; do
  case "$a" in -) continue ;; esac
  git cat-file -e "$BASE:$p" 2>/dev/null || continue   # new file => zero friction
  files=$((files + 1)); added=$((added + a)); deleted=$((deleted + d))
done < <(git diff --numstat "$BASE".."$REV")
printf '%s\t%s files\t%s added (friction)\t%s deleted\n' "$REV" "$files" "$added" "$deleted"
