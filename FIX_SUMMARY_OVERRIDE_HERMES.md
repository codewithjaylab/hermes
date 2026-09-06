# FIX SUMMARY — Override `hermes` with the GSM launchers (Windows + Linux)

Date: 2026-09-06 (rev 2)
Scope: Make the `hermes` command resolve to the repo GSM launchers so API
keys are fetched from Google Secret Manager before the real CLI runs.

Canonical launchers (per user decision, rev 2):
- cmd.exe        -> `C:\workspace\hermes\scripts\hermes-gsm-modify-antigravity.cmd`
- PowerShell     -> same `hermes-gsm-modify-antigravity.cmd`
- git-bash       -> `C:\workspace\hermes\scripts\hermes-gsm-git-bash-win-deepseek.sh`
- Linux (Ubuntu) -> `$HOME/workspace/hermes/scripts/hermes-gsm-ubuntu.sh`

---

## 1. Problem

- The repo with the Hermes GSM launchers lives at `C:\workspace\hermes`
  (NOT `$HOME/workspace/hermes` — that path does not exist on this Windows
  host; `$HOME` is `C:\Users\e4dev`).
- Typing `hermes` resolved to the raw CLI
  (`C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\hermes.exe`),
  so API keys were never loaded from Google Secret Manager.
- The old `~/.bashrc` only had a broken alias:
  `alias hermes2='/c/workspace/hermes/scripts/hermes-gsm.sh'`
  (that file no longer exists).

## 2. Launcher scripts (C:\workspace\hermes\scripts)

| Script | Platform | Notes |
|--------|----------|-------|
| `hermes-gsm-modify-antigravity.cmd` | cmd.exe (also used from PowerShell) | Native cmd launcher. Reads `gsm-secrets.conf` from its own dir, fetches secrets via `gcloud secrets versions access latest`, then checks `netstat` for a Headroom proxy on port **8787**; if present sets `DEEPSEEK_BASE_URL=http://localhost:8787/v1` and `GEMINI_BASE_URL=http://localhost:8787/v1beta` (token saving). Launches `hermes.exe %*`. |
| `hermes-gsm-git-bash-win-deepseek.sh` | Windows git-bash | Bash wrapper. Uses `gcloud auth login` user creds (NOT ADC); trims CR/whitespace and validates secret names from CRLF-safe `gsm-secrets.conf`; `exec`s hermes.exe. |
| `hermes-gsm-git-bash-win.sh` | Windows git-bash | Same family, uses ADC instead of user creds. |
| `hermes-gsm-ubuntu.sh` | Linux/Ubuntu | Bash wrapper for Linux; locates hermes via `command -v hermes`; uses ADC; supports gcloud auto-logout. |
| `hermes-gsm-gcloud-logout.sh` | helper | Revokes gcloud sessions after a delay (see repo README). |

All launchers read one secret name per line from `gsm-secrets.conf` (`#` for
comments), fetch each from GSM and export/`set` them in the child process.

## 3. Files created / modified

| File | Purpose |
|------|---------|
| `C:\Users\e4dev\bin\hermes.cmd` (CRLF) | cmd.exe override. Thin forwarder: `call "C:\workspace\hermes\scripts\hermes-gsm-modify-antigravity.cmd" %*` then `exit /b %ERRORLEVEL%`. `C:\Users\e4dev\bin` is already FIRST on the Windows PATH, so this beats the venv `hermes.exe`. Kept as a forwarder (not a copy) so the repo script stays the single source of truth. |
| `C:\Users\e4dev\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` | PowerShell 5.1 override: `function hermes { & 'C:\workspace\hermes\scripts\hermes-gsm-modify-antigravity.cmd' @args }` plus `$env:HERMES`. Functions take precedence over external commands in PowerShell. |
| `~/.bashrc` (`C:\Users\e4dev\.bashrc`) | Appended (with user consent) the HERMES export + `hermes` alias pointing to the deepseek bash wrapper. The old broken `hermes2` line is still at the top (harmless; can be deleted). |
| Windows env var `HERMES` | Set via `setx` to `C:\workspace\hermes` (persistent, user scope; convenience for other tools). |

## 4. Commands used

### 4.1 cmd override — forwarder `C:\Users\e4dev\bin\hermes.cmd`

Must be CRLF (LF-only .cmd files can misbehave with blocks/labels):

```bat
@echo off
call "C:\workspace\hermes\scripts\hermes-gsm-modify-antigravity.cmd" %*
exit /b %ERRORLEVEL%
```

(The file was written with CRLF line endings preserved; verify with
`file C:\Users\e4dev\bin\hermes.cmd` -> "DOS batch file ... with CRLF line
terminators". If it ever comes back as LF-only, convert:

```bash
awk 'BEGIN{ORS="\r\n"}{print}' /c/Users/e4dev/bin/hermes.cmd > /tmp/h.cmd && mv /tmp/h.cmd /c/Users/e4dev/bin/hermes.cmd
```)

### 4.2 PowerShell profile

File `C:\Users\e4dev\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`:

```powershell
$env:HERMES = 'C:\workspace\hermes'

function hermes {
    & 'C:\workspace\hermes\scripts\hermes-gsm-modify-antigravity.cmd' @args
}
```

IMPORTANT: Windows blocks profile loading until the execution policy allows
it (error: "cannot be loaded because running scripts is disabled"). Fix once:

```powershell
powershell -NoProfile -Command "Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force"
```

Note: env vars `set` inside a .cmd live only in that cmd child process — fine
here because `hermes.exe` is launched inside it.

### 4.3 Persistent HERMES env var

```bash
cmd //c "setx HERMES C:\workspace\hermes"
```

Only affects NEW processes. The shims define HERMES locally anyway; this is a
convenience for other tools.

### 4.4 git-bash alias (~/.bashrc) — done, appended with consent

```bash
export HERMES="/c/workspace/hermes"
alias hermes='$HERMES/scripts/hermes-gsm-git-bash-win-deepseek.sh'
```

IMPORTANT bash pitfalls:
- Aliases are ONLY expanded in interactive shells (or after
  `shopt -s expand_aliases`). Testing inside `bash -lc '...'` shows the raw
  command unless `expand_aliases` is on — a test artifact, not a config bug.
- An alias expands only when it is the FIRST word of a command. Wrapping it
  (`timeout 60 hermes ...`) silently bypasses it and runs the PATH binary.
- `~/.bash_profile` (Git for Windows) already sources `~/.bashrc`, so login
  shells pick it up automatically.
- Launcher scripts are already executable (`-rwxr-xr-x`).

### 4.5 Linux snippet (Ubuntu machine, ~/.bashrc)

```bash
export HERMES="$HOME/workspace/hermes"
alias hermes='$HERMES/scripts/hermes-gsm-ubuntu.sh'
```

Verify the checkout path first: `ls ~/workspace/hermes/scripts/`. On Linux
use `hermes-gsm-ubuntu.sh` (ADC-based); there is no `-deepseek` variant.

## 5. Verification (all passed)

```bash
# cmd: shim must resolve BEFORE the venv hermes.exe
cmd //c "where hermes"
# -> C:\Users\e4dev\bin\hermes.cmd
# -> C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\hermes.exe

# git-bash: alias is active in an interactive shell
bash -ic 'type hermes'
# -> hermes is aliased to `$HERMES/scripts/hermes-gsm-git-bash-win-deepseek.sh'

# PowerShell: profile loads, hermes is a function
powershell -Command "Get-Command hermes | Select-Object Name,CommandType"

# E2E smoke test — `--version` fetches secrets and exits; spends NO tokens
timeout 90 cmd //c "hermes --version"
timeout 90 powershell -Command "hermes --version"
timeout 90 bash -ic 'hermes --version'
```

Expected output — cmd/PowerShell (antigravity launcher):

```
[hermes-gsm] Fetching secrets from C:\workspace\hermes\scripts\gsm-secrets.conf...
[hermes-gsm]   OK DEEPSEEK_API_KEY loaded
[hermes-gsm]   OK SUDO_PASSWORD loaded
[hermes-gsm] Launching Hermes...
[hermes-gsm] Headroom proxy not detected on port 8787. Direct connection will be used.
Hermes Agent v0.16.0 (2026.6.5) · ...
```

Expected output — git-bash (deepseek wrapper):

```
[hermes-gsm] Fetching secrets from Google Secret Manager...
[hermes-gsm]   OK DEEPSEEK_API_KEY loaded
[hermes-gsm]   OK SUDO_PASSWORD loaded
[hermes-gsm] Launching Hermes...
Hermes Agent v0.16.0 (2026.6.5) · ...
```

If the Headroom proxy is running on 8787, the antigravity launcher prints
"proxy detected ... Routing requests through proxy to save tokens." instead.

## 6. Key facts / comments

1. Path mismatch: on this Windows box the repo is `C:\workspace\hermes`, so
   `HERMES` there is NOT `$HOME/workspace/hermes`. The `$HOME` form is only
   valid on the Linux machine.
2. The venv CLI is still reachable by full path:
   `C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\hermes.exe`
3. New terminals required after any profile/env change (setx, PS profile,
   .bashrc) — already-open windows keep the old environment.
4. ~/.bashrc writes require explicit user consent (protected file); the
   append was approved interactively.
5. PowerShell 5.1 is the only PS installed (no pwsh) — the profile lives in
   `Documents\WindowsPowerShell`. If pwsh is added later, mirror the
   function into `Documents\PowerShell\Microsoft.PowerShell_profile.ps1`.
6. Smoke-test with `hermes --version` — it never starts a session or spends
   model tokens.
