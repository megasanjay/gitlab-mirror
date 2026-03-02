#!/usr/bin/env bash
set -euo pipefail

# DANGER: This script permanently deletes GitLab projects.
# It is intentionally interactive and refuses to run without
# an explicit confirmation step.
#
# It operates **only** within a single GitLab namespace
# (group/user/subgroup), configured via GITLAB_NAMESPACE.

# Load environment variables from a local .env file in the script directory, if present.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck source=/dev/null
  set -a
  . "$SCRIPT_DIR/.env"
  set +a
fi

# ===== CONFIG =====
# GitLab namespace to operate on, e.g. "yourname" or "yourgroup/subgroup"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-YOUR_GITLAB_NAMESPACE}"

# Optional comma-separated list of project paths to skip (relative to the namespace),
# e.g. "keep-this,important-repo,subgroup/keep-this-too".
SKIP_REPOS="${SKIP_REPOS:-}"

# GitLab API/token. Token must have api + delete_repository permissions.
: "${GITLAB_TOKEN:?Set GITLAB_TOKEN (GitLab token with api+delete_repository)}"

# GitLab URL (self-managed? change this)
GITLAB_API="${GITLAB_API:-https://gitlab.com/api/v4}"

should_skip_repo() {
  local repo="$1"

  if [[ -z "${SKIP_REPOS:-}" ]]; then
    return 1
  fi

  local IFS=','
  local entry
  read -ra _skip_array <<<"$SKIP_REPOS"

  for entry in "${_skip_array[@]}"; do
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

if [[ -z "$GITLAB_NAMESPACE" || "$GITLAB_NAMESPACE" == "YOUR_GITLAB_NAMESPACE" ]]; then
  echo "ERROR: GITLAB_NAMESPACE is not set to a real namespace."
  echo "Set GITLAB_NAMESPACE in your environment or .env file first."
  exit 1
fi

echo "Resolving GitLab namespace ID for: $GITLAB_NAMESPACE ..."
ns_search="$(curl -sf --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_API/namespaces?search=$(python3 - <<'PY'
import urllib.parse, os
print(urllib.parse.quote(os.environ["GITLAB_NAMESPACE"]))
PY
)")"

ns_id="$(echo "$ns_search" | jq -r --arg p "$GITLAB_NAMESPACE" '
  map(select(.full_path==$p))[0].id
')"

if [[ "$ns_id" == "null" || -z "$ns_id" ]]; then
  echo "ERROR: Could not find GitLab namespace full_path=$GITLAB_NAMESPACE"
  exit 1
fi

echo "GitLab namespace id: $ns_id"
echo
echo "Fetching projects in namespace '$GITLAB_NAMESPACE'..."

projects_json="[]"
page=1
while :; do
  resp_headers="$(mktemp)"
  page_json="$(
    curl -sS --fail \
      --connect-timeout 10 --max-time 60 --retry 5 --retry-all-errors --retry-delay 1 \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      -D "$resp_headers" \
      "$GITLAB_API/projects?namespace_id=$ns_id&per_page=100&page=$page&simple=true"
  )"

  if [[ "$(echo "$page_json" | jq -r 'type')" != "array" ]]; then
    echo "ERROR: Expected array from GitLab projects API, got:"
    echo "$page_json" | jq .
    rm -f "$resp_headers"
    exit 1
  fi

  projects_json="$(jq -s '.[0] + .[1]' \
    <(printf '%s\n' "$projects_json") \
    <(printf '%s\n' "$page_json"))"

  next_page="$(awk -F': ' 'tolower($1)=="x-next-page"{gsub("\r","",$2); print $2}' "$resp_headers")"
  rm -f "$resp_headers"

  if [[ -z "$next_page" ]]; then
    break
  fi
  page="$next_page"
done

project_count="$(echo "$projects_json" | jq 'length')"

if [[ "$project_count" -eq 0 ]]; then
  echo "No projects found in namespace '$GITLAB_NAMESPACE'. Nothing to delete."
  exit 0
fi

echo "Found $project_count project(s) in namespace '$GITLAB_NAMESPACE':"
echo
echo "$projects_json" | jq -r '.[] | "\(.id)\t\(.path_with_namespace)"'
echo
echo "WARNING: All of the above projects will be permanently deleted from GitLab."
echo "This cannot be undone."
echo
read -r -p "Type EXACTLY 'DELETE' to confirm deletion of ALL these projects: " confirm

if [[ "$confirm" != "DELETE" ]]; then
  echo "Confirmation did not match 'DELETE'. Aborting."
  exit 1
fi

echo
echo "Proceeding with deletion of $project_count project(s) in '$GITLAB_NAMESPACE'..."

echo "$projects_json" | jq -r '.[] | "\(.id)\t\(.path_with_namespace)"' | while IFS=$'\t' read -r proj_id full_path; do
  if should_skip_repo "${full_path#"$GITLAB_NAMESPACE/"}"; then
    echo "Skipping $full_path (listed in SKIP_REPOS)."
    continue
  fi

  echo "Deleting project $full_path (id=$proj_id)..."
  if ! curl -sf --request DELETE \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_API/projects/$proj_id" >/dev/null; then
    echo "WARNING: Failed to delete GitLab project $full_path (id=$proj_id)"
  fi
done

echo
echo "Done. All non-skipped projects in namespace '$GITLAB_NAMESPACE' have been processed."

