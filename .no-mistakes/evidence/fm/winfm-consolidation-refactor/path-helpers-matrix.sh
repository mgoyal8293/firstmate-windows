#!/usr/bin/env bash
# fm_lock_same_path, now owned by bin/fm-path-lib.sh and reached through
# bin/fm-wake-lib.sh. This is what decides whether fm_lock_try_create's readlink
# validation matches: on Git for Windows /tmp is a mount alias for the Windows
# temp directory, so a native symlink reads back in a spelling that is not the
# one it was created with. A wrong DIFFERENT here means no lock is ever acquired
# and every lock wait spins forever.
set -u
ROOT=$1
TOP=$(mktemp -d "${TMPDIR:-/tmp}/fm-path-XXXXXX"); trap 'rm -rf "$TOP"' EXIT
mkdir -p "$TOP/stub"
cat > "$TOP/stub/cygpath" <<'STUB'
#!/usr/bin/env bash
# Stand-in for the MSYS mount table: /tmp and C:/Users/me/AppData/Local/Temp are
# the same location, and cygpath -m renders both to the mixed Windows spelling.
p=${!#}
case "$p" in
  /tmp*)  printf 'C:/Users/me/AppData/Local/Temp%s\n' "${p#/tmp}" ;;
  /c/*)   printf 'C:%s\n' "${p#/c}" ;;
  *)      printf '%s\n' "$p" ;;
esac
STUB
chmod +x "$TOP/stub/cygpath"

ask() {  # <uname> <with-cygpath> <a> <b>
  local p=$PATH
  [ "$2" = 1 ] && p="$TOP/stub:$PATH"
  PATH="$p" FM_PROC_UNAME_S=$1 FM_PLATFORM_UNAME_OVERRIDE=$1 \
    "$BASH" -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_same_path "$2" "$3" && echo SAME || echo DIFFERENT' \
    _ "$ROOT" "$3" "$4"
}

row() { printf '%-58s : %s\n' "$1" "$2"; }
echo "### fm_lock_same_path"
row "MSYS mount alias: /tmp/fm-x vs /c/Users/me/.../Temp/fm-x" \
  "$(ask MINGW64_NT-10.0-26200 1 /tmp/fm-x /c/Users/me/AppData/Local/Temp/fm-x)"
row "same spelling twice" \
  "$(ask MINGW64_NT-10.0-26200 1 /tmp/fm-x /tmp/fm-x)"
row "two genuinely different paths" \
  "$(ask MINGW64_NT-10.0-26200 1 /tmp/fm-x /tmp/fm-y)"
row "no cygpath: the strict compare stays the only verdict" \
  "$(ask MINGW64_NT-10.0-26200 0 /tmp/fm-x /c/Users/me/AppData/Local/Temp/fm-x)"
row "empty argument is never a match" \
  "$(ask MINGW64_NT-10.0-26200 1 '' /tmp/fm-x)"
