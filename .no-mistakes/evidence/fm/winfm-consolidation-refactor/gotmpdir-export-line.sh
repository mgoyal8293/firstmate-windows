#!/usr/bin/env bash
# The GOTMPDIR line bin/fm-spawn.sh exports into a crewmate pane, produced by
# running each head's OWN code for that region of fm-spawn.sh: the inline block
# before the move, the bin/fm-path-lib.sh call after it. MSYS translates paths in
# argv but never in the environment, so on Windows the line must carry the native
# spelling, quoted; off Windows it must stay the plain POSIX literal.
set -u
ROOT=$1
TOP=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-XXXXXX"); trap 'rm -rf "$TOP" /tmp/fm-EVID-*' EXIT
mkdir -p "$TOP/stub"
cat > "$TOP/stub/cygpath" <<'STUB'
#!/usr/bin/env bash
# Stand-in for the MSYS translator: /tmp is mounted at C:\Users\me\AppData\Local\Temp
p=${!#}
printf 'C:\\Users\\me\\AppData\\Local\\Temp%s\n' "$(printf '%s' "${p#/tmp}" | tr '/' '\\')"
STUB
chmod +x "$TOP/stub/cygpath"

# The exact region of fm-spawn.sh that computes the exported line, taken from the
# head under test and executed, not read.
region=$(awk '/^TASK_TMP="\/tmp\/fm-\$ID"$/,/^# Per-harness turn-end hook/' "$ROOT/bin/fm-spawn.sh" | sed '$d')
[ -n "$region" ] || { echo "could not locate the GOTMPDIR region in $ROOT/bin/fm-spawn.sh" >&2; exit 2; }
quoter=$(sed -n '/^shell_quote() {/,/^}/p' "$ROOT/bin/fm-spawn.sh")

emit() {  # <uname> <with-cygpath 0|1>
  local uname=$1 withcyg=$2 p=$PATH
  [ "$withcyg" = 1 ] && p="$TOP/stub:$PATH"
  PATH="$p" FM_PROC_UNAME_S=$uname FM_PLATFORM_UNAME_OVERRIDE=$uname ID=EVID-1 \
    "$BASH" -c '. "$1/bin/fm-wake-lib.sh"; eval "$2"; eval "$3"; printf "%s\n" "$GOTMPDIR_EXPORT_LINE"' \
    _ "$ROOT" "$quoter" "$region"
}

printf '%-46s : %s\n' "Windows pane (cygpath present)"  "$(emit MINGW64_NT-10.0-26200 1)"
printf '%-46s : %s\n' "Windows pane (no cygpath)"       "$(emit MINGW64_NT-10.0-26200 0)"
printf '%-46s : %s\n' "Linux pane"                      "$(emit Linux 1)"
