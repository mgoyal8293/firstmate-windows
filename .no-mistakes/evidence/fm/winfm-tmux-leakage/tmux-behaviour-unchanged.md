# Hard constraint: behaviour on tmux is unchanged

## 1. Operator-level send against a REAL tmux 3.4 server

A real tmux server on a private socket runs a pane that appends every submitted line to
a file. The same `fm-send.sh <id> "<message>"` is run from the base commit's tree and
from this branch's tree.

```
### tree: BASE   host: real tmux 3.4 on a private socket
# state/e2e1.meta records window=sess:fm-e2e1; the pane appends each submitted line to a file

$ fm-send.sh e2e1 'captain: report your bearings'
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ●  WATCHER DOWN - SUPERVISION IS OFF
  ●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
  ●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
  ●  This is a supervision warning only; the requested message WILL still be sent.
  ●  watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  error: text not submitted to sess:fm-e2e1 (delivery unconfirmed; verdict=unknown; tried meta=/tmp/winfm-e2e/tsend-BASE/home/state/e2e1.meta; backend=from-meta)
  [exit 1]

line actually received by the live tmux pane:
  captain: report your bearings

### tree: TARGET   host: real tmux 3.4 on a private socket
# state/e2e1.meta records window=sess:fm-e2e1; the pane appends each submitted line to a file

$ fm-send.sh e2e1 'captain: report your bearings'
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ●  WATCHER DOWN - SUPERVISION IS OFF
  ●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
  ●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
  ●  This is a supervision warning only; the requested message WILL still be sent.
  ●  watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  error: text not submitted to sess:fm-e2e1 (delivery unconfirmed; verdict=unknown; tried meta=/tmp/winfm-e2e/tsend-TARGET/home/state/e2e1.meta; backend=from-meta)
  [exit 1]

line actually received by the live tmux pane:
  captain: report your bearings
```

Byte-identical operator-visible output and the identical line delivered to the live
pane. (The non-zero exit is the same on both trees: a plain `cat` pane is not an agent
composer, so submit acknowledgement cannot be proven either way.)

## 2. Adapter/dispatcher equivalence with the raw tmux commands they replaced

`tests/fm-backend-tmux-smoke.test.sh` is the one suite that talks to a real tmux server.
Its new cases assert EQUIVALENCE with the raw command rather than a fixed verdict, so
they cannot silently encode this tmux build's own target-resolution behaviour.

```
@1
ok - real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate
ok - real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter
ok - real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps
ok - real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one
ok - real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name
ok - real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist
ok - real tmux: fm_backend_tmux_target_exists and the fm_backend_target_exists dispatcher return the raw pane_id probe's verdict for a live window, an unknown window, an unknown session, and an empty target
ok - real tmux: the equivalence is not vacuous - a live window reads as present
ok - real tmux: fm_backend_tmux_leader_pid and the fm_backend_leader_pid dispatcher return the raw '#{pane_pid}' read, and it names a live process
ok - real tmux: fm_backend_tmux_list_live and the fm_backend_list_task_windows dispatcher reproduce the raw list-windows|grep ':fm-' pipeline exactly, including its non-task-window exclusion
ok - real tmux: fm_backend_tmux_list_live prints the shared '<target>\t<label>' shape every other adapter's list_live prints
ok - real tmux: the fm_backend_list_task_windows dispatcher preserves the adapter's '<target>\t<label>' pair verbatim
ok - real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing
```

## 3. Metadata compatibility contract (site a11)

The persisted `state/<id>.meta` an operator's home actually ends up holding, for the
same spawn command on both platforms:

```
### the same spawn command on two platforms; --backend tmux both times

$ uname -s => Linux   (POSIX host)
  persisted state/posixhome1.meta:
    window=firstmate:fm-posixhome1
    harness=claude
    kind=ship
    -> no backend= line: the absent-value default (tmux) is what reads it back
  read back by fm_backend_of_meta: tmux

$ uname -s => MINGW64_NT-10.0-26200   (Windows host, via FM_PLATFORM_UNAME_OVERRIDE)
  persisted state/winhome1.meta:
    window=firstmate:fm-winhome1
    harness=claude
    kind=ship
    backend=tmux
    -> backend= IS recorded explicitly
  read back by fm_backend_of_meta: tmux

# Both read back as tmux. The POSIX meta is byte-identical to what every
# existing home already wrote, so no metadata on disk is reinterpreted.
```

The POSIX meta is unchanged - still no `backend=` line - so every meta an existing
POSIX home already wrote on disk keeps reading back as tmux. Only the Windows arm was
added; `fm_backend_of_meta`, the single owner of the absent-value default, is untouched.
