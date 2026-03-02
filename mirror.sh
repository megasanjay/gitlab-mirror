#!/usr/bin/env bash
set -euo pipefail

# GitHub -> GitLab mirror backup script.
# - Lists all repos for a GitHub owner/org using the GitHub API (paginated).
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
MIRROR_SLEEP_SECS="${MIRROR_SLEEP_SECS:-2}"

# Optional comma-separated list of repo names to skip entirely
# (applies to both mirroring and cleanup).
SKIP_REPOS="${SKIP_REPOS:-}"

# Optional prefix added to every GitLab project name (display only, not path).
# Defaults to an underscore.
MIRROR_EMOJI_PREFIX=${MIRROR_EMOJI_PREFIX:-"_"}

# Optional prefix added to the GitLab project path when the GitHub repo
# name does not start with a valid GitLab path character (letter or digit).
# GitLab requires path to NOT start with '-', '_', or '.'; so this prefix must start with a letter or digit.
# Defaults to "glm" (GitLab mirror).
GITLAB_PATH_PREFIX=${GITLAB_PATH_PREFIX:-"glm"}

# Tokens (required, enforced below):
# - GitHub: used for API (repo list) and cloning via https
# - GitLab: used to create repos via API and push via https
: "${GH_TOKEN:?Set GH_TOKEN (GitHub token with read access)}"
: "${GITLAB_TOKEN:?Set GITLAB_TOKEN (GitLab token with api+write_repository)}"

# GitLab URL (self-managed? change this)
GITLAB_API="https://gitlab.com/api/v4"
GITLAB_HOST="gitlab.com"

should_skip_repo() {
  local repo="$1"

  if [[ -z "${SKIP_REPOS:-}" ]]; then
    return 1
  fi

  local IFS=','
  local entry
  read -ra _skip_array <<<"$SKIP_REPOS"

  for entry in "${_skip_array[@]}"; do
    # Strip all whitespace from the entry for robustness.
    entry="${entry//[[:space:]]/}"
    if [[ -z "$entry" ]]; then
      continue
    fi
    if [[ "$repo" == "$entry" ]]; then
      return 0
    fi
  done

  return 1
}

mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"

echo "Fetching repo list from GitHub owner: $GITHUB_OWNER ..."
# Use GitHub API with pagination (org or user). GH_TOKEN is required.
GITHUB_API="https://api.github.com"
repos_json="[]"
# Try org first; if 404, treat as user.
page=1
while :; do
  # Try organization repos endpoint first.
  page_resp="$(curl -s -w "\n%{http_code}" \
    --header "Authorization: Bearer $GH_TOKEN" \
    --header "Accept: application/vnd.github+json" \
    "$GITHUB_API/orgs/$GITHUB_OWNER/repos?per_page=100&page=$page&type=owner")"
  http_code="${page_resp##*$'\n'}"
  page_body="${page_resp%$'\n'*}"
  if [[ "$http_code" != "200" && "$http_code" != "404" ]]; then
    echo "ERROR: GitHub API returned HTTP $http_code for org $GITHUB_OWNER"
    echo "$page_body" | jq -r '.message // .' 2>/dev/null || echo "$page_body"
    exit 1
  fi
  if [[ "$http_code" == "404" && "$page" == "1" ]]; then
    # Not an org; use user repos endpoint.
    page=1
    while :; do
      page_resp="$(curl -s -w "\n%{http_code}" \
        --header "Authorization: Bearer $GH_TOKEN" \
        --header "Accept: application/vnd.github+json" \
        "$GITHUB_API/users/$GITHUB_OWNER/repos?per_page=100&page=$page&type=owner")"
      http_code="${page_resp##*$'\n'}"
      page_body="${page_resp%$'\n'*}"
      if [[ "$page" == "1" && "$http_code" != "200" ]]; then
        echo "ERROR: GitHub API returned HTTP $http_code for user $GITHUB_OWNER"
        echo "$page_body" | jq -r '.message // .' 2>/dev/null || echo "$page_body"
        exit 1
      fi
      if [[ "$(echo "$page_body" | jq 'length')" -eq 0 ]]; then
        break
      fi
      repos_json="$(jq -s '.[0] + .[1]' <(printf '%s\n' "$repos_json") <(printf '%s\n' "$page_body"))"
      ((page++))
    done
    break
  fi
  if [[ "$(echo "$page_body" | jq 'length')" -eq 0 ]]; then
    break
  fi
  repos_json="$(jq -s '.[0] + .[1]' <(printf '%s\n' "$repos_json") <(printf '%s\n' "$page_body"))"
  ((page++))
done
# name and visibility (API: .visibility or .private -> PUBLIC/PRIVATE)
repo_meta="$(echo "$repos_json" | jq -r '.[] | [.name, ((.visibility // (if .private then "private" else "public" end)) | ascii_upcase)] | @tsv')"

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
  if should_skip_repo "$repo"; then
    echo
    echo "=== $repo ==="
    echo "Skipping (listed in SKIP_REPOS)."
    continue
  fi

  echo
  echo "=== $repo ==="
  echo "GitHub visibility: $gh_visibility"

  gitlab_visibility="private"
  if [[ "$gh_visibility" == "PUBLIC" ]]; then
    gitlab_visibility="public"
  fi
  echo "Desired GitLab visibility: $gitlab_visibility"

  # Derive the GitLab project path. GitLab path must not start with '-', '_', or '.'.
  # Prefix with GITLAB_PATH_PREFIX (must start with letter/digit) when needed.
  gitlab_path="$repo"
  if [[ ! "$repo" =~ ^[[:alnum:]] ]]; then
    gitlab_path="${GITLAB_PATH_PREFIX}${repo}"
  fi

  # Check if project exists on GitLab (by full path "<namespace>/<gitlab_path>").
  encoded_path="$(
    PATH_PART="$GITLAB_NAMESPACE/$gitlab_path" python3 - <<'PY'
import urllib.parse, os
print(urllib.parse.quote(os.environ["PATH_PART"], safe=""))
PY
  )"
  exists_code="$(curl -s -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_API/projects/$encoded_path")"

  if [[ "$exists_code" != "200" ]]; then
    echo "GitLab project missing -> creating $GITLAB_NAMESPACE/$gitlab_path"
    echo "Creating GitLab project with visibility: $gitlab_visibility"

    # Only add the mirror prefix to the project name if the original repo
    # starts with a non-alphanumeric character. Otherwise, keep the name
    # exactly the same as the GitHub repo.
    project_name="$repo"
    if [[ ! "$repo" =~ ^[[:alnum:]] ]]; then
      project_name="${MIRROR_EMOJI_PREFIX}${repo}"
    fi

    echo "GitLab API request: POST $GITLAB_API/projects name='$project_name' path='$gitlab_path' namespace_id='$ns_id' visibility='$gitlab_visibility'"
    curl -sf --request POST \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      --data-urlencode "name=$project_name" \
      --data "path=$gitlab_path&namespace_id=$ns_id&visibility=$gitlab_visibility" \
      "$GITLAB_API/projects" >/dev/null
  else
    echo "GitLab project exists, checking visibility..."
    project_json="$(curl -sf --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "$GITLAB_API/projects/$encoded_path")"
    current_visibility="$(echo "$project_json" | jq -r '.visibility')"
    current_name="$(echo "$project_json" | jq -r '.name')"
    echo "Current GitLab visibility: $current_visibility"
    echo "Current GitLab name: $current_name"

    needs_visibility_update=0
    needs_name_update=0

    if [[ "$current_visibility" != "$gitlab_visibility" ]]; then
      needs_visibility_update=1
    fi

    desired_name="$repo"
    if [[ ! "$repo" =~ ^[[:alnum:]] ]]; then
      desired_name="${MIRROR_EMOJI_PREFIX}${repo}"
    fi
    if [[ "$current_name" != "$desired_name" ]]; then
      needs_name_update=1
    fi

    if [[ "$needs_visibility_update" -eq 1 || "$needs_name_update" -eq 1 ]]; then
      echo "Updating GitLab project metadata..."
      curl -sf --request PUT \
        --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        $( [[ "$needs_name_update" -eq 1 ]] && printf '%s' --data-urlencode "name=$desired_name" ) \
        $( [[ "$needs_visibility_update" -eq 1 ]] && printf '%s' --data "visibility=$gitlab_visibility" ) \
        "$GITLAB_API/projects/$encoded_path" >/dev/null
    else
      echo "GitLab visibility and name already match desired."
    fi
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
  git -C "$repo.git" push --mirror "https://oauth2:$GITLAB_TOKEN@$GITLAB_HOST/$GITLAB_NAMESPACE/$gitlab_path.git"

  # Optional throttle between repositories.
  if [[ "$MIRROR_SLEEP_SECS" != "0" ]]; then
    echo "Sleeping for $MIRROR_SLEEP_SECS seconds before next repo..."
    sleep "$MIRROR_SLEEP_SECS"
  fi
done <<< "$repo_meta"

echo
echo "Scanning for GitLab projects in $GITLAB_NAMESPACE that no longer exist on GitHub..."

# Build a simple newline-separated list of GitHub repo names for membership checks.
github_repos="$(echo "$repo_meta" | cut -f1)"

# Build the corresponding list of expected GitLab project paths for those repos,
# using the same mapping rule as in the main mirroring loop.
github_gitlab_paths=""
while IFS= read -r gh_repo; do
  [[ -z "$gh_repo" ]] && continue
  gl_path="$gh_repo"
  if [[ ! "$gh_repo" =~ ^[[:alnum:]] ]]; then
    gl_path="${GITLAB_PATH_PREFIX}${gh_repo}"
  fi
  github_gitlab_paths+="$gl_path"$'\n'
done <<< "$github_repos"

# Collect GitLab projects in this namespace with a single request (assumes <= 100 projects).
echo "Fetching GitLab projects list for namespace ID $ns_id..."
gitlab_projects_file="$(mktemp)"
if ! curl -sS --fail \
      --connect-timeout 10 --max-time 60 --retry 5 --retry-all-errors --retry-delay 1 \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "$GITLAB_API/projects?namespace_id=$ns_id&per_page=100&simple=true" \
      > "$gitlab_projects_file"; then
  echo "ERROR: Failed to fetch GitLab projects list (curl error)."
  rm -f "$gitlab_projects_file"
  exit 1
fi
echo "Successfully fetched GitLab projects list, parsing with jq..."

gitlab_project_names="$(jq -r '.[].path' "$gitlab_projects_file")"
echo "Parsed GitLab project names:"
echo "$gitlab_project_names"
rm -f "$gitlab_projects_file"

while IFS= read -r gl_repo; do
  [[ -z "$gl_repo" ]] && continue

  if should_skip_repo "$gl_repo"; then
    echo "Skipping cleanup for $gl_repo (listed in SKIP_REPOS)."
    continue
  fi

  if grep -Fxq "$gl_repo" <<<"$github_gitlab_paths"; then
    continue
  fi

  # Only manage GitLab projects that also have a local mirror directory.
  # Reconstruct the local directory name (original GitHub repo name) from the
  # GitLab project path when we prefixed it (path = GITLAB_PATH_PREFIX + repo).
  local_repo_name="$gl_repo"
  if [[ "$gl_repo" == "$GITLAB_PATH_PREFIX"* ]]; then
    local_repo_name="${gl_repo#$GITLAB_PATH_PREFIX}"
  fi

  if [[ ! -d "$local_repo_name.git" ]]; then
    echo "GitLab project '$GITLAB_NAMESPACE/$gl_repo' has no matching GitHub repo, but no local mirror directory was found; leaving it untouched."
    continue
  fi

  echo "Deleting GitLab project '$GITLAB_NAMESPACE/$gl_repo' (no matching GitHub repo) and its local mirror..."

  encoded_gl_path="$(
    PATH_PART="$GITLAB_NAMESPACE/$gl_repo" python3 - <<'PY'
import urllib.parse, os
print(urllib.parse.quote(os.environ["PATH_PART"], safe=""))
PY
  )"

  if ! curl -sf --request DELETE \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_API/projects/$encoded_gl_path" >/dev/null; then
    echo "WARNING: Failed to delete GitLab project $GITLAB_NAMESPACE/$gl_repo"
  fi

  rm -rf "$local_repo_name.git"
done <<< "$gitlab_project_names"

echo
echo "All done. Local mirrors stored in: $BACKUP_DIR"