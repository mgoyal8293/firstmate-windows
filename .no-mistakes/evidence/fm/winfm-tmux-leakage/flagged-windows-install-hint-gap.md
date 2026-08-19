# Known gap flagged in the PR body, reproduced (site a13)

On Windows the bootstrap's "no Windows package" arm covers tmux|zellij|cmux, so `orca`
still gets a brew hint on a host that cannot have brew. This is main's own code (a13
landed independently in PR #3) and is deliberately not re-added here - flagged only.

```
### bin/fm-bootstrap.sh missing-tool install hints, as an operator sees them on Windows
# (uname -s forced to MINGW64_NT-10.0-26200 via the FM_PLATFORM_UNAME_OVERRIDE seam)

  MISSING: node     (install: winget install OpenJS.NodeJS  # or scoop install nodejs)
  MISSING: git      (install: winget install Git.Git  # or scoop install git)
  MISSING: gh       (install: winget install GitHub.cli  # or scoop install gh)
  MISSING: curl     (install: winget install cURL.cURL  # or scoop install curl)
  MISSING: jq       (install: winget install jqlang.jq  # or scoop install jq)
  MISSING: tmux     (install: no Windows package; set config/backend to conpty instead (docs/conpty-backend.md))
  MISSING: zellij   (install: no Windows package; set config/backend to conpty instead (docs/conpty-backend.md))
  MISSING: cmux     (install: no Windows package; set config/backend to conpty instead (docs/conpty-backend.md))
  MISSING: orca     (install: brew install orca  # or the platform's package manager)
```
