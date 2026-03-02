# GitHub -> GitLab mirror backup

**Purpose**: mirror all repositories from a GitHub user or organization into a GitLab namespace using `git clone --mirror` and `git push --mirror`. This gives you a faithful git-level backup of:

- **All branches**
- **All tags**
- **All refs (remote-tracking refs, etc.)**

The script is designed to be **idempotent** (safe to re-run) and easy to schedule (cron, systemd timer, Task Scheduler, etc.).

---

## What this script does

- **Lists GitHub repositories**: uses the GitHub REST API (with your `GH_TOKEN`) to list all repos for a given owner/org.
- **Ensures GitLab projects exist**: uses the GitLab API to create any missing projects in a target namespace.
- **Maintains local bare mirrors**: keeps a local `--mirror` clone per repo in a backup directory.
- **Pushes mirrors to GitLab**: pushes all refs from GitHub to GitLab with `git push --mirror`.

This is a **git backup**, not a full GitHub clone. It does **not** copy issues, pull requests, actions, or other metadata.

---

## Requirements

- **Environment capable of running Python 3**
  - Linux, macOS, WSL, or Windows with Python 3 installed.
- **Installed tools**
  - `git`
  - `python3`
  - (Optional) `bash` if you use the `mirror.sh` wrapper; `curl` and `jq` are only needed for `check_requirements.sh`.
- **GitHub token (`GH_TOKEN`)**
  - Classic PAT: `repo` scope is sufficient.
  - Fine-grained PAT: grant **read access** to the repos you want to mirror.
- **GitLab token (`GITLAB_TOKEN`)**
  - Scopes:
    - `api` (for creating projects and listing namespaces/groups/users)
    - `write_repository` (for pushing)
  - Defaults to `gitlab.com`. For self-managed GitLab, set `GITLAB_API` and `GITLAB_HOST` in your environment or `.env`.

Private repositories are supported as long as the tokens have access.

---

## Configuration

The main script is **`mirror.py`**. You can put configuration in a **`.env`** file in the same directory (loaded automatically) or set environment variables before running. The **`mirror.sh`** script is a thin wrapper that runs `mirror.py` and forwards arguments.

- **`GITHUB_OWNER`**: GitHub user or organization whose repos you want to mirror.
  - Example: `your-github-username` or `your-org`.
- **`GITLAB_NAMESPACE`**: GitLab namespace that will contain the mirrored projects. Namespaces cover both **users** and **groups** (username or group path).
  - Example for a user: `alice`.
  - Example for a group: `mygroup` or `mygroup/subgroup`.
  - This namespace must already exist in GitLab. The script resolves it and uses the correct API to list projects for cleanup (see below).
- **`BACKUP_DIR`** (optional): local directory for the bare mirror clones.
  - Defaults to `"$HOME/git-mirror-backups"` if not set.
- **`MIRROR_SLEEP_SECS`** (optional): delay in seconds between processing each repo.
  - Defaults to `2`. Set to `0` for no delay, or a small value (e.g. `1`–`3`) to be gentle on API/rate limits.
- **`SKIP_REPOS`** (optional): comma-separated list of repo names to ignore for both mirroring and cleanup.
  - Example: `SKIP_REPOS="legacy-repo,experimental-sandbox,do-not-touch"`.
  - Repos listed here will not be mirrored, and any matching GitLab projects will be left untouched by the cleanup step.
- **`GITLAB_API`** (optional): GitLab API base URL. Defaults to `https://gitlab.com/api/v4`.
- **`GITLAB_HOST`** (optional): GitLab host for git URLs. Defaults to `gitlab.com`.
- **`GITLAB_PATH_PREFIX`** (optional): prefix used for GitLab project paths when the repo name does not start with an alphanumeric. Defaults to `glm`.
- **`MIRROR_EMOJI_PREFIX`** (optional): prefix used for GitLab project names in the same case. Defaults to `_`.

Required tokens (must be set in `.env` or as environment variables):

- **`GH_TOKEN`**: GitHub PAT with read access to all repos you want to mirror.
- **`GITLAB_TOKEN`**: GitLab PAT with `api` + `write_repository`.

---

## How to use

1. **Clone this repo** to a machine that can run on a schedule.
2. **Configure the script**:
   - Create a `.env` file in the repo directory (or export variables in your shell). At minimum set:
     - `GITHUB_OWNER="your-github-owner-or-org"`
     - `GITLAB_NAMESPACE="your-gitlab-namespace"` (user path or group path)
   - Optionally set `BACKUP_DIR`, `MIRROR_SLEEP_SECS`, `SKIP_REPOS`, etc.
3. **Set tokens** in `.env` or export them:

```bash
export GH_TOKEN="github_pat_..."
export GITLAB_TOKEN="glpat-..."
```

4. **Run the script** from the repo directory:

```bash
./mirror.sh
```

or directly:

```bash
python3 mirror.py
```

To run **only the cleanup phase** (no mirroring):

```bash
python3 mirror.py --cleanup-only
```

On first run it will:

- Discover all repos under `GITHUB_OWNER`.
- Create missing projects under `GITLAB_NAMESPACE`.
- Create bare mirror clones in `BACKUP_DIR`.
- Push all refs to the corresponding GitLab projects.

Subsequent runs will:

- `fetch` updates from GitHub into the existing mirrors.
- `push --mirror` changes to GitLab.

After the mirror step, the script runs a **cleanup phase**:

- It fetches the GitLab namespace (e.g. `GET /namespaces/:id`) to determine whether it is a **user** or a **group**.
- It then lists projects using the appropriate API:
  - **User namespace**: resolves username → user id (`/users?username=...`), then lists projects with `/users/:id/projects`.
  - **Group namespace**: lists projects with `/groups/:id/projects`.
- It compares that list to the current GitHub repo list.
- For any GitLab project that:
  - **Does not** have a matching GitHub repo name,
  - **Does** have a local mirror directory (`<name>.git` in `BACKUP_DIR`),
  - **Is not** listed in `SKIP_REPOS`,
  it deletes the GitLab project and removes the corresponding local mirror directory.

You can run only this cleanup step with `python3 mirror.py --cleanup-only` (no mirroring).

---

## Validating your setup

You can run a quick sanity check before the first mirror run:

```bash
chmod +x check_requirements.sh
./check_requirements.sh
```

This will:

- Ensure required tools (`git`, `curl`, `jq`, `python3`) are installed.
- Load `.env` (if present) and check that `GH_TOKEN` and `GITLAB_TOKEN` are set.
- Warn if `GITHUB_OWNER` / `GITLAB_NAMESPACE` are still placeholder values.
- Confirm that:
  - The GitHub REST API can list repos for `GITHUB_OWNER` using `GH_TOKEN`.
  - The GitLab API can resolve the configured `GITLAB_NAMESPACE` (user or group).

If required tools are missing and a supported package manager is available (`apt-get`, `brew`, `dnf`, `yum`, or `pacman`), `check_requirements.sh` will attempt to install them for you. If it cannot, it will tell you exactly which tools need to be installed manually.

If this script exits successfully, `mirror.sh` should be ready to run.

---

## Private repositories

**Yes, private repos are supported.** The key is that your tokens must have access:

- **GitHub side**
  - `GH_TOKEN` must see the private repos you care about. Any repo visible to that token via the GitHub REST API will be mirrored.

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

   # if you cloned the repo to /root/gitlab-mirror
   30 3 * * * cd /root/gitlab-mirror && /usr/bin/env bash mirror.sh >> /root/gitlab-mirror/mirror.log 2>&1
   ```

   Cron timing format:
   - `minute hour day-of-month month day-of-week`
   - Example variations:
     - Every day at 2am: `0 2 * * *`
     - Every 6 hours: `0 */6 * * *`
     - Every Sunday at 4am: `0 4 * * 0`

4. **Test the exact command cron will run**:

   ```bash
   . $HOME/.env && cd /path/to/gitlab-mirror && /usr/bin/env bash mirror.sh

   # if you cloned the repo to /root/gitlab-mirror
   cd /root/gitlab-mirror && /usr/bin/env bash mirror.sh
   ```

---

### Windows

- Use **Task Scheduler** and run the script via:
  - WSL (recommended), or
  - Git Bash
- Point the task to a small wrapper script that sets `GH_TOKEN`, `GITLAB_TOKEN`, and then calls `bash mirror.sh`.

---

## Customizing for your setup

- **Different GitLab host**: set `GITLAB_API` and `GITLAB_HOST` in your `.env` or environment (e.g. `GITLAB_API=https://git.example.com/api/v4`, `GITLAB_HOST=git.example.com`).
- **Include/exclude certain repos**:
  - All repositories returned by the GitHub REST API for `GITHUB_OWNER` (user or org) are mirrored.
  - Use `SKIP_REPOS` to exclude specific repo names from mirroring and cleanup.
  - For more selective mirroring (e.g. skip forks or archived repos), you would need to change the Python logic in `mirror.py`.

This script is intended as a straightforward, repeatable way to mirror many GitHub repositories (dozens or more) into GitLab with minimal manual clicking.
