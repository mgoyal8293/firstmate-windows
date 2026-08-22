# Windows Python capability-probe verification

Repeatable evidence that firstmate resolves a Python 3 that actually runs, on a box whose `python3` resolves on PATH and then refuses to run.
The probe itself and its candidate order are owned by [`../../bin/fm-python-lib.sh`](../../bin/fm-python-lib.sh); the Windows lane story is owned by [`../fm-test-windows-lane.md`](../fm-test-windows-lane.md) and the port's fixed-here list by [`../windows.md`](../windows.md).
This page records evidence only.

Date: 2026-08-22.
Comparison base: `main` at `54a8125`.
Windows box: Windows 11 build 10.0.26200, Git Bash MINGW64_NT-10.0-26200, bash 5.2.37, git 2.50.1.windows.1.
Linux box: WSL2, bash 5.2.21, CPython 3.12.

## What the interpreters on that box actually do

Every fact below came from one hidden batched PowerShell invocation (`-NoProfile -NonInteractive -WindowStyle Hidden`) driving Git Bash, so the measurement cost one console creation rather than one per probe.
A `powershell.exe` launched from WSL always creates a console; hiding the window is the most those flags can do, and that limit is not fixed here.

```console
$ command -v python3
/c/Users/johns/AppData/Local/Microsoft/WindowsApps/python3
$ ls -l /c/Users/johns/AppData/Local/Microsoft/WindowsApps/python3
lrwxrwxrwx 121 ... -> /c/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.29.290.0_x64__8wekyb3d8bbwe/AppInstallerPythonRedirector.exe
$ python3 -c 'import sys; print("PYOK", sys.version_info[0], sys.version_info[1])'
Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut from Settings > Apps > Advanced app settings > App execution aliases.
rc=49
$ python -c 'import sys; print("PYOK", sys.version_info[0], sys.version_info[1])'
PYOK 3 12
rc=0
$ py -3 -c 'import sys; print("PYOK", sys.version_info[0], sys.version_info[1])'
PYOK 3 12
rc=0
```

`python3` is a 121-byte redirector present on every stock Windows 10 and 11 install whether or not Python is.
`python` and `py -3` are the same real CPython 3.12.
`py -3` is therefore not the only real interpreter on this box, but it is kept as a candidate because some Windows installs register the launcher and no bare interpreter, and because expressing it at all forces the resolved answer to be an argv array rather than a single word.

## What the probe resolves, on the box

```console
$ bash -c '. bin/fm-python-lib.sh; fm_python3 && echo "resolved: $FM_PYTHON3"; "${FM_PYTHON3_CMD[@]}" -V'
resolved: python
Python 3.12.10
```

## The gate that could not run

`bin/fm-doc-audience-check.sh` is mandated by [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) and by the `firstmate-coding-guidelines` skill, and before this change it was a bare `exec python3 -`.

```console
# before, at 54a8125, on the Windows box
$ bash bin/fm-doc-audience-check.sh
Python was not found; run without arguments to install from the Microsoft Store, ...
rc=49

# after, same box, same command
$ bash bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=72 local_links=278
rc=0
```

## The suite already ran before this change

Worth stating precisely, because the finding that motivated this work said the Windows suite ran zero tests.
That was true at `6579148` and is no longer true: the runner gained its own executing probe at `54a8125`, and on the Windows box at that commit it reports assertions.

```console
$ bash bin/fm-test-run.sh tests/fm-lint.test.sh tests/fm-classify-decision-key.test.sh
FM_TEST_SUMMARY total=2 failed=1 skipped_gate=0 duration_ms=97829
```

So this change closes the remaining call sites and removes the duplicate probe; it does not restore the suite, which was already running.
Making that suite green, and making it fast enough to run, remain separate work.

## Falsifiability

`tests/fm-python-lib.test.sh` fences seven distinct protections.
Each was removed in turn and the run re-executed; each removal produced exactly one failure, and restoring it returned the file to green.
The whole fixture is a shim that prints the Store advert and exits 49, so every case reproduces on Linux.

| Protection removed | Failure it produced |
|---|---|
| the probe executes each candidate (reverted to `command -v python3`) | `not ok - a resolvable-but-broken python3 was accepted as an interpreter: 'python3'` |
| the probe asserts major version >= 3 (payload reduced to `-c 'pass'`) | `not ok - a Python 2 was accepted, but every payload here needs Python 3: 'python'` |
| the candidate list expresses a multi-word command (`py -3` collapsed to `py`) | `not ok - the probe should have resolved the multi-word launcher 'py -3', got 'REFUSED'` |
| `bin/fm-doc-audience-check.sh` routed through the probe (back to `exec python3 -`) | `not ok - the documentation gate still dies with the Store stub's own exit 49` |
| `bin/fm-ensure-agents-md.sh` routed through the probe (back to `command -v python3` plus `return $?`) | `not ok - a correct CLAUDE.md pointer was rejected behind a stubbed python3 (rc=1)` |
| `bin/fm-ensure-agents-md.sh`'s undeterminable verdict (tri-state collapsed to `return 1`) | `not ok - an unanswerable pointer question was reported as a conflict` |
| `bin/fm-kimi-turnend-hook.sh` routed through the probe (back to `command -v python3`) | `not ok - the Kimi hook still dies with the Store stub's own exit 49` |

## Green runs

```console
# Linux
$ bash tests/fm-python-lib.test.sh | wc -l
10

# Windows box, through the runner, twice
$ bash bin/fm-test-run.sh tests/fm-python-lib.test.sh
FM_TEST_END ... tests/fm-python-lib.test.sh exit=0 duration_ms=11512 gate_skip=false
FM_TEST_END ... tests/fm-python-lib.test.sh exit=0 duration_ms=11129 gate_skip=false
```

Eight of the ten cases run on Windows.
The two CLAUDE.md pointer cases report a `note:` and stage nothing there, because a stock Windows checkout cannot create a real symlink and `ln -s` copies the target instead - which is also why the defect they fence is latent on Windows until `core.symlinks` is enabled.
That measured 11512 ms is the Windows lane weight hint recorded for this script in `bin/fm-test-run.sh`.
