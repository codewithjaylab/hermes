# Hermes — zsh Alias in ~/.zshrc (outside the repo)

Documentation of how the `hermes` → `hermes-gsm-ubuntu.sh` alias was set up in the user's shell config, and why that change lives outside this repository.

## Context

- The repository only tracks the scripts and docs under `hermes-sdkjqg/hermes/` (e.g. `scripts/hermes-gsm-ubuntu.sh`, `scripts/gsm-secrets.conf`, this README).
- `~/.zshrc` is **personal shell configuration**, not part of the repo — it is never committed or pushed. Versioning it would require a separate dotfiles repo, which is out of scope here.
- Result: the alias change is machine-local; anyone cloning this repo gets the scripts but must add the alias themselves (the exact line is in this doc).

## What we achieved

Every interactive `hermes` command in zsh now runs the GSM wrapper first:

```
hermes                  →  fetches API keys from Google Secret Manager
                            then execs the real Hermes binary
```

## How it was done (step by step)

1. **Reviewed the wrapper script** — read `scripts/hermes-gsm-ubuntu.sh`:
   - Locates the real binary: `command -v hermes` (fallback list of install paths).
   - Reads secret names from `gsm-secrets.conf` (same directory).
   - Fetches each secret: `gcloud secrets versions access latest --secret=<name>`.
   - Exports them as env vars (e.g. `DEEPSEEK_API_KEY`).
   - Launches with `exec "$HERMES_EXE" "$@"`.
   - Confirmed it is executable (`-rwxrwxr-x`).

2. **Read the current shell config** — `~/.zshrc` to find the existing structure (Aliases block, oh-my-zsh, p10k).

3. **Applied a targeted edit** — the `patch` tool replaced the existing `# Aliases` block to add one line:

   ```diff
   # Aliases
   alias fd=fdfind
   +# Hermes: override 'hermes' to fetch API keys from Google Secret Manager first
   +alias hermes='/home/sdkjqg/workspace/hermes-sdkjqg/hermes/scripts/hermes-gsm-ubuntu.sh'
   ```

   (Used `patch` instead of `sed`/manual editing — a find-and-replace on the unique `# Aliases` block, so no accidental damage to the rest of the file.)

4. **Verified the alias loads** — ran an interactive zsh check:

   ```bash
   zsh -ic 'alias hermes'
   # → hermes=/home/sdkjqg/workspace/hermes-sdkjqg/hermes/scripts/hermes-gsm-ubuntu.sh
   ```

5. **Activated it** — the alias takes effect in new terminals automatically; for the current session: `source ~/.zshrc`.

## Why there is no recursion

The alias only expands in the **interactive zsh shell**. When `hermes` runs, it executes the wrapper as a separate **bash** process, where zsh aliases don't exist — so inside the script `command -v hermes` finds the real binary on `PATH` (`/home/sdkjqg/workspace/Hermes-Agent/venv/bin/hermes`), never the script itself.

## Expected launch output

```
[hermes-gsm] Fetching secrets from Google Secret Manager...
[hermes-gsm]   OK DEEPSEEK_API_KEY loaded
[hermes-gsm] Launching Hermes...
```

## Reproduce on another machine

```bash
# 1. Clone the repo
git clone https://github.com/codewithjaylab/hermes.git
cd hermes/scripts

# 2. Ensure the script is executable
chmod +x hermes-gsm-ubuntu.sh

# 3. Configure secrets (one name per line, # for comments)
cp gsm-secrets.conf.example gsm-secrets.conf   # or edit gsm-secrets.conf

# 4. Add the alias to your shell config (zsh shown; bash users use ~/.bashrc)
echo "alias hermes='$PWD/hermes-gsm-ubuntu.sh'" >> ~/.zshrc
source ~/.zshrc
```

Prerequisites: `gcloud` SDK on `PATH` + `gcloud auth application-default login`, secrets in GSM, `Secret Manager Secret Accessor` role.

## Revert

```bash
# Remove the alias line, then reload
sed -i '/alias hermes=.*hermes-gsm-ubuntu.sh/d' ~/.zshrc
source ~/.zshrc
```

## Checklist

- [x] Alias line added to `~/.zshrc`
- [x] Verified with `zsh -ic 'alias hermes'`
- [x] Documented in the repo (this file) so the setup is reproducible
- [x] Alias itself intentionally NOT in git — personal shell config
