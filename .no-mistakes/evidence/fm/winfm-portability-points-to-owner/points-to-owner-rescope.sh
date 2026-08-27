#!/usr/bin/env bash
# Reproduces, on Linux, the red "points to owner" portability case the change
# re-scopes, and shows the fixture fix turning it green.
#
# Simulates the measured MINGW64 condition: the fixture root is built at the
# spelling TMPDIR carries (/c/Users/<user>/AppData/Local/Temp/...), but the /tmp
# usertemp mount aliases that prefix, so readlink answers /tmp/... - a DIFFERENT
# STRING for the same directory. The case then silently stops testing the strict
# compare and starts testing the mount table.
set -u
REPO=$1
SIM=/tmp/fm-pto-sim
rm -rf "$SIM"; mkdir -p "$SIM/bin"

LONGTEMP="$SIM/c/Users/probe/AppData/Local/Temp"
ALIAS="$SIM/tmp"
mkdir -p "$LONGTEMP"
ln -s "$LONGTEMP" "$ALIAS"     # the mount alias: one directory, two spellings

cat > "$SIM/bin/readlink" <<SH
#!$(command -v bash)
# MSYS-shaped: resolves a stored native target back through the mount table, so
# a target written under .../AppData/Local/Temp reads back under /tmp.
# Scoped to this one fixture on purpose: with the rewrite applied host-wide the
# suite stops at fm_platform_symlink_probe, which carries the identical raw
# readlink compare and is fragile the same way (reproduced separately).
out=\$(/usr/bin/readlink "\$@") || exit \$?
case "\$out" in
  *fm-lock-points-to-owner*) printf '%s\\n' "\${out/#\$FM_SIM_LONGTEMP/\$FM_SIM_ALIAS}" ;;
  *) printf '%s\\n' "\$out" ;;
esac
SH
cat > "$SIM/bin/cygpath" <<'SH'
#!/usr/bin/env bash
# Owns the mount table. Both POSIX spellings render to one Windows path, and -u
# converts back to the spelling the mount table prefers - the /tmp one.
p=${!#}
for a in "$@"; do
  [ "$a" = "-u" ] && { printf '%s\n' "${p/#C:\/Temp/$FM_SIM_ALIAS}"; exit 0; }
done
p=${p/#$FM_SIM_ALIAS/C:\/Temp}
p=${p/#$FM_SIM_LONGTEMP/C:\/Temp}
printf '%s\n' "$p"
SH
chmod +x "$SIM/bin/readlink" "$SIM/bin/cygpath"
export FM_SIM_LONGTEMP="$LONGTEMP" FM_SIM_ALIAS="$ALIAS"

echo "Simulated host, measured through the stubs themselves:"
echo "  TMPDIR                 : $LONGTEMP"
w=$(PATH="$SIM/bin:$PATH" cygpath -m -- "$LONGTEMP/fm-lock-points-to-owner.demo")
echo "  cygpath -m  of TMPDIR  : $w"
echo "  cygpath -u  of that    : $(PATH="$SIM/bin:$PATH" cygpath -u -- "$w")"
mkdir -p "$LONGTEMP/fm-lock-points-to-owner.demo"
ln -s "$LONGTEMP/fm-lock-points-to-owner.demo/owner" "$LONGTEMP/fm-lock-points-to-owner.demo/lock"
echo "  ln -s stored           : $LONGTEMP/fm-lock-points-to-owner.demo/owner"
echo "  readlink answers       : $(PATH="$SIM/bin:$PATH" readlink "$LONGTEMP/fm-lock-points-to-owner.demo/lock")"
echo "  -> readlink's answer is cygpath's round-trip, NOT the built spelling."
rm -rf "$LONGTEMP/fm-lock-points-to-owner.demo"

run_case() {  # <label>
  echo
  echo "=============================================================="
  echo "$1"
  echo "=============================================================="
  PATH="$SIM/bin:$PATH" TMPDIR="$LONGTEMP" \
    bash "$REPO/tests/fm-windows-portability.test.sh" 2>&1 \
    | grep -iE 'points.to.owner' || echo '  <the case produced no line>'
}

cp "$REPO/tests/fm-windows-portability.test.sh" "$SIM/portability.shipped"
trap 'cp "$SIM/portability.shipped" "$REPO/tests/fm-windows-portability.test.sh"' EXIT

# --- BEFORE: the fixture built at whatever spelling TMPDIR carries ------------
python3 - "$REPO/tests/fm-windows-portability.test.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old='''  dir=$(mount_canonical_dir "$dir")
  [ -d "$dir" ] || fail "fixture: the canonical spelling of the fixture root is not a directory: $dir"
'''
assert old in s, "fixture-fix lines not found"
open(p,'w').write(s.replace(old,''))
PY
run_case "BEFORE - fixture built at the TMPDIR spelling (the pre-change fixture)"

# --- AFTER: the shipped fixture fix ------------------------------------------
cp "$SIM/portability.shipped" "$REPO/tests/fm-windows-portability.test.sh"
run_case "AFTER - fixture built at the spelling this host hands back (shipped)"
