# GitHub -> GitLab mirror backup

**Purpose**: mirror all repositories from a GitHub user or organization into a GitLab namespace using `git clone --mirror` and `git push --mirror`. This gives you a faithful git-level backup of:

- **All branches**
- **All tags**
- **All refs (remote-tracking refs, etc.)**

The script is designed to be **idempotent** (safe to re-run) and easy to schedule (cron, systemd timer, Task Scheduler, etc.).

---

## What this script does

- **Lists GitHub repositories**: uses the GitHub CLI (`gh`) to list all repos for a given owner/org.
- **Ensures GitLab projects exist**: uses the GitLab API to create any missing projects in a target namespace.
- **Maintains local bare mirrors**: keeps a local `--mirror` clone per repo in a backup directory.
- **Pushes mirrors to GitLab**: pushes all refs from GitHub to GitLab with `git push --mirror`.

This is a **git backup**, not a full GitHub clone. It does **not** copy issues, pull requests, actions, or other metadata.

---

## Requirements

- **Environment capable of running Bash**
  - Linux, macOS, WSL, or Git Bash on Windows.
- **Installed tools**
  - `git`
  - `bash`
  - `curl`
  - `jq`
  - `python3`
  - GitHub CLI: `gh`
- **GitHub authentication**
  - Run `gh auth login` and ensure `gh repo list` works.
- **GitHub token (`GH_TOKEN`)**
  - Classic PAT: `repo` scope is sufficient.
  - Fine-grained PAT: grant **read access** to the repos you want to mirror.
- **GitLab token (`GITLAB_TOKEN`)**
  - Scopes:
    - `api` (for creating projects)
    - `write_repository` (for pushing)
  - Defaults to `gitlab.com`. For self-managed GitLab, adjust `GITLAB_API` and `GITLAB_HOST` in `mirror.sh`.

Private repositories are supported as long as the tokens have access.

---

## Configuration

Edit `mirror.sh` or set these environment variables before running:

- **`GITHUB_OWNER`**: GitHub user or organization whose repos you want to mirror.
  - Example: `your-github-username` or `your-org`.
- **`GITLAB_NAMESPACE`**: GitLab namespace (group / subgroup / user) that will contain the mirrored projects.
  - Example: `yourname` or `yourgroup/subgroup`.
  - This namespace must already exist in GitLab.
- **`BACKUP_DIR`** (optional): local directory for the bare mirror clones.
  - Defaults to `"$HOME/git-mirror-backups"` if not set.
- **`MIRROR_SLEEP_SECS`** (optional): delay in seconds between processing each repo.
  - Defaults to `0` (no delay). Set to a small value (for example `1`–`3`) if you want to be extra gentle on API/rate limits.

Required tokens (must be set as environment variables):

- **`GH_TOKEN`**: GitHub PAT with read access to all repos you want to mirror.
- **`GITLAB_TOKEN`**: GitLab PAT with `api` + `write_repository`.

---

## How to use

1. **Clone this repo (or copy `mirror.sh`)** to a machine that can run on a schedule.
2. **Configure the script**:
   - Either edit the top of `mirror.sh`:
     - Set `GITHUB_OWNER="your-github-owner-or-org"`.
     - Set `GITLAB_NAMESPACE="your-gitlab-namespace"`.
   - Optionally set `BACKUP_DIR` if you do not want the default.
3. **Export tokens in your shell**:

```bash
export GH_TOKEN="github_pat_..."
export GITLAB_TOKEN="glpat-..."
```

4. **Run the script** from the repo directory:

```bash
bash mirror.sh
```

or (if executable):

```bash
./mirror.sh
```

On first run it will:

- Discover all repos under `GITHUB_OWNER`.
- Create missing projects under `GITLAB_NAMESPACE`.
- Create bare mirror clones in `BACKUP_DIR`.
- Push all refs to the corresponding GitLab projects.

Subsequent runs will:

- `fetch` updates from GitHub into the existing mirrors.
- `push --mirror` changes to GitLab.

---

## Validating your setup

You can run a quick sanity check before the first mirror run:

```bash
chmod +x check_requirements.sh
./check_requirements.sh
```

This will:

- Ensure required tools (`git`, `curl`, `jq`, `python3`, `gh`) are installed.
- Load `.env` (if present) and check that `GH_TOKEN` and `GITLAB_TOKEN` are set.
- Warn if `GITHUB_OWNER` / `GITLAB_NAMESPACE` are still placeholder values.
- Confirm that:
  - GitHub CLI can list repos for `GITHUB_OWNER`.
  - GitLab API can resolve the configured `GITLAB_NAMESPACE`.

If required tools are missing and a supported package manager is available (`apt-get`, `brew`, `dnf`, `yum`, or `pacman`), `check_requirements.sh` will attempt to install them for you. If it cannot, it will tell you exactly which tools need to be installed manually.

If this script exits successfully, `mirror.sh` should be ready to run.

---

## Private repositories

**Yes, private repos are supported.** The key is that your tokens must have access:

- **GitHub side**
  - `GH_TOKEN` must see the private repos you care about.
  - Quick check:

    ```bash
    gh repo list "$GITHUB_OWNER" --visibility private
    ```

    If a private repo shows up here, the script will mirror it.

- **GitLab side**
  - `GITLAB_TOKEN` must be allowed to create projects in `GITLAB_NAMESPACE` and push to them.
  - New projects are created with the **same visibility** as on GitHub (`public`/`private`).

What gets mirrored for private repos is identical to public ones: all branches, tags, and refs.

---

## What is and is not backed up

- **Backed up**
  - Commit history
  - Branches
  - Tags
  - Other git refs stored in the repo

- **Not backed up**
  - Issues
  - Pull / merge requests
  - GitHub Actions workflows, runs, or artifacts
  - Release assets
  - Wikis (unless they are separate git repos and you mirror those too)

If you also want to back up wikis or other git-based extras, you can extend the script to include those repositories.

---

## Running on a schedule

You can run this manually whenever you want, or schedule it.

---

### Linux / macOS: cron

1. **Make the script executable** (once):

   ```bash
   chmod +x /path/to/gitlab-mirror/mirror.sh
   ```

2. **Store tokens in a dedicated env file**:

   ```bash
   cat > ~/.gitlab_mirror_env <<'EOF'
   export GH_TOKEN="github_pat_..."
   export GITLAB_TOKEN="glpat-..."
   EOF

   chmod 600 ~/.gitlab_mirror_env
   ```

3. **Add a daily cron job**:

   ```bash
   crontab -e
   ```

   Example: run every day at 3:30am:

   ```bash
   30 3 * * * . $HOME/.gitlab_mirror_env && cd /path/to/gitlab-mirror && /usr/bin/env bash mirror.sh >> $HOME/gitlab-mirror.log 2>&1
   ```

   Cron timing format:
   - `minute hour day-of-month month day-of-week`
   - Example variations:
     - Every day at 2am: `0 2 * * *`
     - Every 6 hours: `0 */6 * * *`
     - Every Sunday at 4am: `0 4 * * 0`

4. **Test the exact command cron will run**:

   ```bash
   . $HOME/.gitlab_mirror_env && cd /path/to/gitlab-mirror && /usr/bin/env bash mirror.sh
   ```

---

### Windows

- Use **Task Scheduler** and run the script via:
  - WSL (recommended), or
  - Git Bash
- Point the task to a small wrapper script that sets `GH_TOKEN`, `GITLAB_TOKEN`, and then calls `bash mirror.sh`.

---

## Customizing for your setup

- **Different GitLab host**: change `GITLAB_API` and `GITLAB_HOST` at the top of `mirror.sh`.
- **Include/exclude certain repos**:
  - Currently, all repos listed by `gh repo list "$GITHUB_OWNER"` are mirrored.
  - You can filter `repos_json` with `jq` (for example, skip forks or archived repos) if you want a more selective mirror.

This script is intended as a straightforward, repeatable way to mirror many GitHub repositories (dozens or more) into GitLab with minimal manual clicking.
