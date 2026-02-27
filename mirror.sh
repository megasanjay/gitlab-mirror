#!/usr/bin/env bash
set -euo pipefail

# GitHub -> GitLab mirror backup script.
# - Lists all repos for a GitHub owner/org using the GitHub CLI (`gh`).
# - Ensures a matching project exists in the target GitLab namespace.
# - Uses `git clone --mirror` / `git push --mirror` so all refs (branches, tags, remote-tracking refs) are copied.
# - Safe to run repeatedly and suitable for scheduling (cron, systemd timer, Task Scheduler, etc.).

# Load environment variables from a local .env file in the script directory, if present.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck source=/dev/null
  set -a
  . "$SCRIPT_DIR/.env"
  set +a
fi

# ===== CONFIG =====
GITHUB_OWNER="${GITHUB_OWNER:-YOUR_GITHUB_USERNAME_OR_ORG}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-YOUR_GITLAB_NAMESPACE}"   # e.g. "yourname" or "yourgroup/subgroup"

# Local path where bare mirror clones are stored.
# Can be overridden via the BACKUP_DIR environment variable.
BACKUP_DIR="${BACKUP_DIR:-$HOME/git-mirror-backups}"

# Optional delay between processing each repo (seconds), to avoid hitting API/rate limits.
# Override with MIRROR_SLEEP_SECS=<n> in your environment if needed.
MIRROR_SLEEP_SECS="${MIRROR_SLEEP_SECS:-10}"

# Tokens (required, enforced below):
# - GitHub: gh CLI handles auth for listing; cloning via https below uses GH_TOKEN (recommended)
# - GitLab: used to create repos via API and push via https
: "${GH_TOKEN:?Set GH_TOKEN (GitHub token with read access)}"
: "${GITLAB_TOKEN:?Set GITLAB_TOKEN (GitLab token with api+write_repository)}"

# GitLab URL (self-managed? change this)
GITLAB_API="https://gitlab.com/api/v4"
GITLAB_HOST="gitlab.com"

mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"

echo "Fetching repo list from GitHub owner: $GITHUB_OWNER ..."
# Ask GitHub CLI for up to 1000 repos owned by/under $GITHUB_OWNER.
repos_json="$(gh repo list "$GITHUB_OWNER" --limit 1000 --json name,sshUrl,visibility,isFork)"
repo_meta="$(echo "$repos_json" | jq -r '.[] | [.name, .visibility] | @tsv')"

# Find GitLab namespace ID (needed for project creation). This must match full_path exactly.
echo "Resolving GitLab namespace ID for: $GITLAB_NAMESPACE ..."
ns_search="$(curl -sf --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_API/namespaces?search=$(python3 - <<'PY'
import urllib.parse,os
print(urllib.parse.quote(os.environ["GITLAB_NAMESPACE"]))
PY
)")"

ns_id="$(echo "$ns_search" | jq -r --arg p "$GITLAB_NAMESPACE" '
  map(select(.full_path==$p))[0].id
')"

if [[ "$ns_id" == "null" || -z "$ns_id" ]]; then
  echo "ERROR: Could not find GitLab namespace full_path=$GITLAB_NAMESPACE"
  echo "Create it in GitLab first (group/subgroup) and try again."
  exit 1
fi

echo "GitLab namespace id: $ns_id"
echo "Starting mirror of $(echo "$repo_meta" | wc -l | tr -d ' ') repos..."

while IFS=$'\t' read -r repo gh_visibility; do
  echo
  echo "=== $repo ==="

  # Check if project exists on GitLab (by full path "<namespace>/<repo>").
  encoded_path="$(
    PATH_PART="$GITLAB_NAMESPACE/$repo" python3 - <<'PY'
import urllib.parse, os
print(urllib.parse.quote(os.environ["PATH_PART"], safe=""))
PY
  )"
  exists_code="$(curl -s -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_API/projects/$encoded_path")"

  if [[ "$exists_code" != "200" ]]; then
    echo "GitLab project missing -> creating $GITLAB_NAMESPACE/$repo"
    gitlab_visibility="private"
    if [[ "$gh_visibility" == "public" ]]; then
      gitlab_visibility="public"
    fi
    curl -sf --request POST \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      --data "name=$repo&namespace_id=$ns_id&visibility=$gitlab_visibility" \
      "$GITLAB_API/projects" >/dev/null
  else
    echo "GitLab project exists."
  fi

  # Mirror clone/fetch
  if [[ ! -d "$repo.git" ]]; then
    echo "Cloning mirror from GitHub..."
    git clone --mirror "https://$GH_TOKEN@github.com/$GITHUB_OWNER/$repo.git" "$repo.git"
  else
    echo "Fetching updates from GitHub..."
    git -C "$repo.git" remote set-url origin "https://$GH_TOKEN@github.com/$GITHUB_OWNER/$repo.git"
    git -C "$repo.git" fetch -p origin
  fi

  # Push mirror to GitLab (branches, tags, and all refs).
  echo "Pushing mirror to GitLab..."
  git -C "$repo.git" push --mirror "https://oauth2:$GITLAB_TOKEN@$GITLAB_HOST/$GITLAB_NAMESPACE/$repo.git"

  # Optional throttle between repositories.
  if [[ "$MIRROR_SLEEP_SECS" != "0" ]]; then
    echo "Sleeping for $MIRROR_SLEEP_SECS seconds before next repo..."
    sleep "$MIRROR_SLEEP_SECS"
  fi
done <<< "$repo_meta"

echo
echo "All done. Local mirrors stored in: $BACKUP_DIR"