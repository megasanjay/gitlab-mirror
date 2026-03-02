#!/usr/bin/env bash
set -euo pipefail

# Basic requirements / sanity check script for the GitHub -> GitLab mirror.
# - Verifies required tools are installed.
# - Loads .env (same as mirror.sh) and checks required environment variables.
# - Performs lightweight API checks against GitHub and GitLab.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env from repo root if present so GH_TOKEN / GITLAB_TOKEN / GITHUB_OWNER / GITLAB_NAMESPACE are available.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck source=/dev/null
  set -a
  . "$SCRIPT_DIR/.env"
  set +a
fi

echo "Checking required tools..."
required_tools=(git curl jq python3)
missing=()
for t in "${required_tools[@]}"; do
  if ! command -v "$t" >/dev/null 2>&1; then
    missing+=("$t")
  fi
done

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt-get"
  elif command -v brew >/dev/null 2>&1; then
    echo "brew"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  else
    echo ""
  fi
}

if ((${#missing[@]})); then
  echo "Missing required tools: ${missing[*]}"
  PKG_MANAGER="$(detect_pkg_manager)"

  if [[ -z "$PKG_MANAGER" ]]; then
    echo "ERROR: No supported package manager detected (apt, brew, dnf, yum, pacman)."
    echo "Install the missing tools manually and re-run this check."
    exit 1
  fi

  echo "Attempting to install missing tools using: $PKG_MANAGER"

  case "$PKG_MANAGER" in
    apt-get)
      sudo apt-get update
      sudo apt-get install -y "${missing[@]}"
      ;;
    brew)
      brew install "${missing[@]}"
      ;;
    dnf)
      sudo dnf install -y "${missing[@]}"
      ;;
    yum)
      sudo yum install -y "${missing[@]}"
      ;;
    pacman)
      sudo pacman -Sy --noconfirm "${missing[@]}"
      ;;
  esac

  # Re-check after attempted installation.
  missing_after=()
  for t in "${required_tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      missing_after+=("$t")
    fi
  done

  if ((${#missing_after[@]})); then
    echo "ERROR: Some tools are still missing after attempted installation: ${missing_after[*]}"
    echo "Install these manually according to the README and re-run this check."
    exit 1
  fi
fi

echo "All required tools are installed."

echo
echo "Checking required environment variables..."

# Mirror script defaults (kept in sync with mirror.sh).
GITHUB_OWNER="${GITHUB_OWNER:-YOUR_GITHUB_USERNAME_OR_ORG}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-YOUR_GITLAB_NAMESPACE}"

: "${GH_TOKEN:?GH_TOKEN is not set (set it in .env or your shell)}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is not set (set it in .env or your shell)}"

if [[ "$GITHUB_OWNER" == "YOUR_GITHUB_USERNAME_OR_ORG" ]]; then
  echo "WARNING: GITHUB_OWNER is still the placeholder value."
  echo "Set GITHUB_OWNER in .env or in mirror.sh to your GitHub user/org."
fi

if [[ "$GITLAB_NAMESPACE" == "YOUR_GITLAB_NAMESPACE" ]]; then
  echo "WARNING: GITLAB_NAMESPACE is still the placeholder value."
  echo "Set GITLAB_NAMESPACE in .env or in mirror.sh to your GitLab namespace."
fi

echo "Environment variables present."

echo
echo "Verifying GitHub access for owner: $GITHUB_OWNER ..."
GITHUB_API="${GITHUB_API:-https://api.github.com}"

# Try organization endpoint first; if that 404s, fall back to user.
resp="$(curl -s -w '\n%{http_code}' \
  --header "Authorization: Bearer $GH_TOKEN" \
  --header "Accept: application/vnd.github+json" \
  "$GITHUB_API/orgs/$GITHUB_OWNER/repos?per_page=1&page=1&type=all")"
http_code="${resp##*$'\n'}"
body="${resp%$'\n'*}"

if [[ "$http_code" == "404" ]]; then
  resp="$(curl -s -w '\n%{http_code}' \
    --header "Authorization: Bearer $GH_TOKEN" \
    --header "Accept: application/vnd.github+json" \
    "$GITHUB_API/users/$GITHUB_OWNER/repos?per_page=1&page=1&type=all")"
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
fi

if [[ "$http_code" != "200" ]]; then
  echo "ERROR: Unable to list GitHub repos for owner '$GITHUB_OWNER' (HTTP $http_code)."
  echo "$body" | jq -r '.message // .' 2>/dev/null || echo "$body"
  echo "Check that GITHUB_OWNER is correct and that GH_TOKEN has access."
  exit 1
fi
echo "GitHub access looks OK."

echo
echo "Verifying GitLab access for namespace: $GITLAB_NAMESPACE ..."
GITLAB_API="${GITLAB_API:-https://gitlab.com/api/v4}"

ns_search="$(curl -sf --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_API/namespaces?search=$(python3 - <<'PY'
import urllib.parse,os
print(urllib.parse.quote(os.environ.get("GITLAB_NAMESPACE",""), safe=""))
PY
)")"

ns_id="$(echo "$ns_search" | jq -r --arg p "$GITLAB_NAMESPACE" '
  map(select(.full_path==$p))[0].id
')"

if [[ -z "${ns_id:-}" || "$ns_id" == "null" ]]; then
  echo "ERROR: Could not resolve GitLab namespace full_path='$GITLAB_NAMESPACE'."
  echo "Make sure the namespace exists and that GITLAB_TOKEN has api access."
  exit 1
fi

echo "GitLab namespace resolved successfully (id: $ns_id)."

echo
echo "All checks passed. You are ready to run ./mirror.sh"

