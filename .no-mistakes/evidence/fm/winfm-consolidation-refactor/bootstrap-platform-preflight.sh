#!/usr/bin/env bash
# End-user transcript for the two symlink preflight detectors, as the operator
# meets them: the PLATFORM lines bin/fm-bootstrap.sh prints at session start.
#
#   detect_symlink_capability     - the fleet's locks are symlinks; a home whose
#                                   state/ cannot make one would spin forever.
#   detect_repo_symlink_checkout  - .claude/skills checked out as a plain file
#                                   (Git for Windows core.symlinks=false) means
#                                   the harness silently loads no project skills.
set -u
ROOT=$1
TOP=$(mktemp -d "${TMPDIR:-/tmp}/fm-preflight-XXXXXX")
trap 'chmod -R u+w "$TOP" 2>/dev/null; rm -rf "$TOP"' EXIT

mkhome() { local h="$TOP/$1"; mkdir -p "$h/state" "$h/data"; printf '%s\n' "$h"; }
mkroot() { local r="$TOP/$1"; mkdir -p "$r/.claude" "$r/.agents/skills" "$r/bin"; printf '%s\n' "$r"; }
run() {  # <home> <root>
  timeout 180 env FM_HOME="$1" FM_ROOT_OVERRIDE="$2" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null \
    | grep '^PLATFORM:' | sed "s#$TOP#<tmp>#g"
}

h=$(mkhome healthy); r=$(mkroot healthy-root); ln -s ../.agents/skills "$r/.claude/skills"
o=$(run "$h" "$r"); printf 'healthy home + real skills symlink:\n%s\n\n' "${o:+$(printf '%s' "$o" | sed 's/^/  /')}${o:-  (no PLATFORM line - silent = all good)}"

h=$(mkhome nolinks); r=$(mkroot nolinks-root); ln -s ../.agents/skills "$r/.claude/skills"
chmod 0500 "$h/state"
printf 'state/ cannot create a symlink:\n%s\n\n' "$(run "$h" "$r" | sed 's/^/  /')"
chmod 0700 "$h/state"

h=$(mkhome plainfile); r=$(mkroot plainfile-root)
printf '../.agents/skills\n' > "$r/.claude/skills"
printf '.claude/skills checked out as a plain file:\n%s\n' "$(run "$h" "$r" | sed 's/^/  /')"
