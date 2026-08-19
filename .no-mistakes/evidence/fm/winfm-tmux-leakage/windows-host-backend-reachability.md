# Windows-shaped host: the fleet's own scripts now reach the backend instead of tmux

Host setup for both runs below: the home's config/backend is conpty, and the only
`tmux` on PATH is an audit shim that records the invocation and exits 127 - i.e. the
Windows situation, where tmux is not installed at all.

## 1. Operator sends to an ad hoc endpoint  (inventory site a10, bin/fm-send.sh)

```
### tree: BASE   home session provider: conpty (config/backend)   tmux on host: absent (audit shim, exit 127)

$ fm-send.sh sess:agent 'status?'
  error: explicit target 'sess:agent' is not a live tmux endpoint (tried meta=/tmp/winfm-e2e/run-BASE/home/state/sess:agent.meta; metadata window/terminal lookup; backend=tmux). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified.
  [exit 1]

tmux commands issued by non-adapter scripts during that run:
  tmux display-message -p -t sess:agent #{pane_id}

### tree: TARGET   home session provider: conpty (config/backend)   tmux on host: absent (audit shim, exit 127)

$ fm-send.sh sess:agent 'status?'
  error: explicit target 'sess:agent' is not a live conpty endpoint (tried meta=/tmp/winfm-e2e/run-TARGET/home/state/sess:agent.meta; metadata window/terminal lookup; backend=conpty). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified.
  [exit 1]

tmux commands issued by non-adapter scripts during that run:
  (none)
```

Before, the operator on a Windows home is told the endpoint is not a live *tmux*
endpoint - a backend that home does not run and that host does not have - and the
script really does shell out to tmux to decide that. After, the probe is addressed to
the home's own conpty backend and no tmux command is issued.

## 2. Away-mode supervisor tick discovers a live endpoint  (site a1, bin/fm-supervise-daemon.sh)

A task with torn metadata (backend recorded, `window=` never written) is still live on
the home's conpty session provider and has declared a pause. Only the native Windows
node client is substituted here (a documented adapter seam); the real conpty adapter
shell code runs.

```
### tree: BASE   home session provider: conpty   tmux on host: absent (audit shim, exit 127)
# live conpty session directory: fm-firstmate-804fcb36-t7
# state/t7.meta (torn - no window= handle):
    backend=conpty
    kind=ship
    harness=pi
# state/t7.status:
    paused: holding for the upstream tool release

$ <supervisor tick> window_for_task t7
  NOT FOUND - the supervisor cannot locate the live agent

$ <supervisor tick> housekeeping
  state/ after the tick:
    .subsuper-last-scan
  => the declared pause was NEVER seen: no .subsuper-paused-t7 marker

tmux commands issued by non-adapter scripts during that tick:
  tmux list-windows -a -F #{session_name}:#{window_name}
  tmux list-windows -a -F #{session_name}:#{window_name}

### tree: TARGET   home session provider: conpty   tmux on host: absent (audit shim, exit 127)
# live conpty session directory: fm-firstmate-c3f6a460-t7
# state/t7.meta (torn - no window= handle):
    backend=conpty
    kind=ship
    harness=pi
# state/t7.status:
    paused: holding for the upstream tool release

$ <supervisor tick> window_for_task t7
  found endpoint: fm-firstmate-c3f6a460-t7 t7

$ <supervisor tick> housekeeping
  state/ after the tick:
    .subsuper-last-scan
    .subsuper-paused-t7
  => the declared pause was recorded under the task's own key (.subsuper-paused-t7)

tmux commands issued by non-adapter scripts during that tick:
  (none)
```

Before, the daemon's no-metadata fallback ran a raw `tmux list-windows -a` regardless
of backend, found nothing on a Windows host, and the task's declared pause was never
reconciled. After, the endpoint is found through the backend interface and the pause
marker is persisted under the task's own key, with zero tmux calls.
