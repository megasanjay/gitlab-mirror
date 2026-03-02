#!/usr/bin/env python3
"""
GitHub -> GitLab mirror backup script (Python version).

- Lists all repos for a GitHub owner/org using the GitHub API (paginated).
- Ensures a matching project exists in the target GitLab namespace.
- Uses `git clone --mirror` / `git push --mirror` so all refs (branches, tags, remote-tracking refs) are copied.
- Safe to run repeatedly and suitable for scheduling.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Set, Tuple

from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


def load_dotenv(dotenv_path: Path) -> None:
    """
    Minimal .env loader.

    - Supports lines of the form KEY=VALUE
    - Ignores comments and blank lines
    - Removes surrounding single/double quotes from VALUE
    - Overrides existing environment variables, similar to `set -a; . .env`
    """
    if not dotenv_path.is_file():
        return

    for raw_line in dotenv_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        # Strip surrounding quotes if present
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]

        if key:
            os.environ[key] = value


def env_required(name: str, message: str) -> str:
    val = os.environ.get(name)
    if not val:
        print(f"ERROR: {message}", file=sys.stderr)
        sys.exit(1)
    return val


def should_skip_repo(repo: str, skip_repos: Set[str]) -> bool:
    return repo in skip_repos


def parse_skip_repos(raw: str) -> Set[str]:
    if not raw:
        return set()
    entries: List[str] = []
    for part in raw.split(","):
        cleaned = "".join(part.split())
        if cleaned:
            entries.append(cleaned)
    return set(entries)


def http_get(url: str, headers: Dict[str, str], timeout: int = 60) -> Tuple[int, str]:
    req = Request(url, headers=headers)
    try:
        with urlopen(req, timeout=timeout) as resp:
            status = resp.getcode()
            body = resp.read().decode("utf-8", errors="replace")
            return status, body
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        return e.code, body
    except URLError as e:
        print(f"ERROR: Network error while requesting {url}: {e}", file=sys.stderr)
        sys.exit(1)


def http_get_json(
    url: str, headers: Dict[str, str], timeout: int = 60
) -> Tuple[int, object]:
    status, body = http_get(url, headers=headers, timeout=timeout)
    if not body:
        return status, None
    try:
        return status, json.loads(body)
    except json.JSONDecodeError:
        print(f"ERROR: Failed to parse JSON response from {url}", file=sys.stderr)
        print(body, file=sys.stderr)
        sys.exit(1)


def run_git(args: Sequence[str], cwd: Path) -> None:
    try:
        subprocess.run(
            ["git", *args],
            cwd=str(cwd),
            check=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"ERROR: git command failed: git {' '.join(args)}", file=sys.stderr)
        sys.exit(e.returncode)


def github_list_repos(owner: str, token: str) -> List[Dict[str, object]]:
    """
    Return a list of GitHub repo objects for the given owner (org or user).
    Mirrors the Bash logic:
    - Try org endpoint first.
    - If 404 on first page, fall back to user endpoint.
    """
    api_base = "https://api.github.com"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "gitlab-mirror-python",
    }

    repos: List[Dict[str, object]] = []

    # Try organization endpoint first
    page = 1
    while True:
        url = f"{api_base}/orgs/{owner}/repos?per_page=100&page={page}&type=owner"
        status, body = http_get(url, headers=headers)

        if status not in (200, 404):
            print(
                f"ERROR: GitHub API returned HTTP {status} for org {owner}",
                file=sys.stderr,
            )
            print(body, file=sys.stderr)
            sys.exit(1)

        if status == 404 and page == 1:
            # Not an org; treat as user
            repos = []
            page = 1
            while True:
                url = f"{api_base}/users/{owner}/repos?per_page=100&page={page}&type=owner"
                status_user, body_user = http_get(url, headers=headers)
                if page == 1 and status_user != 200:
                    print(
                        f"ERROR: GitHub API returned HTTP {status_user} for user {owner}",
                        file=sys.stderr,
                    )
                    print(body_user, file=sys.stderr)
                    sys.exit(1)

                if status_user != 200:
                    print(
                        f"ERROR: GitHub API returned HTTP {status_user} while paging user repos",
                        file=sys.stderr,
                    )
                    print(body_user, file=sys.stderr)
                    sys.exit(1)

                page_json = json.loads(body_user) if body_user else []
                if len(page_json) == 0:
                    break
                repos.extend(page_json)
                page += 1
            break

        if status != 200:
            print(
                f"ERROR: GitHub API returned HTTP {status} while paging org repos",
                file=sys.stderr,
            )
            print(body, file=sys.stderr)
            sys.exit(1)

        page_json = json.loads(body) if body else []
        if len(page_json) == 0:
            break
        repos.extend(page_json)
        page += 1

    return repos


def github_repo_meta(repos: Iterable[Dict[str, object]]) -> List[Tuple[str, str]]:
    """
    Produce (name, VISIBILITY) tuples where VISIBILITY is PUBLIC/PRIVATE,
    matching the Bash jq logic.
    """
    result: List[Tuple[str, str]] = []
    for repo in repos:
        name = str(repo.get("name", ""))
        visibility = repo.get("visibility")
        if visibility:
            vis_str = str(visibility).upper()
        else:
            is_private = bool(repo.get("private"))
            vis_str = "PRIVATE" if is_private else "PUBLIC"
        result.append((name, vis_str))
    return result


def gitlab_get_namespace_id(gitlab_api: str, token: str, namespace: str) -> int:
    print(f"Resolving GitLab namespace ID for: {namespace} ...")
    encoded_ns = quote(namespace)
    url = f"{gitlab_api}/namespaces?search={encoded_ns}"
    headers = {"PRIVATE-TOKEN": token}
    status, data = http_get_json(url, headers=headers)

    if status != 200 or not isinstance(data, list):
        print(
            f"ERROR: Failed to resolve GitLab namespace. HTTP {status}",
            file=sys.stderr,
        )
        sys.exit(1)

    ns_id = None
    for item in data:
        if isinstance(item, dict) and item.get("full_path") == namespace:
            ns_id = item.get("id")
            break

    if ns_id is None:
        print(
            f"ERROR: Could not find GitLab namespace full_path={namespace}",
            file=sys.stderr,
        )
        print(
            "Create it in GitLab first (group/subgroup) and try again.", file=sys.stderr
        )
        sys.exit(1)

    print(f"GitLab namespace id: {ns_id}")
    return int(ns_id)


def gitlab_project_exists(
    gitlab_api: str, token: str, full_path: str
) -> Tuple[bool, Dict[str, object]]:
    headers = {"PRIVATE-TOKEN": token}
    encoded_path = quote(full_path, safe="")
    url = f"{gitlab_api}/projects/{encoded_path}"
    status, data = http_get_json(url, headers=headers)
    if status == 200 and isinstance(data, dict):
        return True, data
    return False, {}


def gitlab_create_project(
    gitlab_api: str,
    token: str,
    name: str,
    path: str,
    ns_id: int,
    visibility: str,
) -> None:
    print(
        f"GitLab project missing -> creating {path} (visibility={visibility})",
    )
    headers = {"PRIVATE-TOKEN": token}
    url = f"{gitlab_api}/projects"
    data = {
        "name": name,
        "path": path,
        "namespace_id": str(ns_id),
        "visibility": visibility,
    }
    req = Request(
        url,
        headers=headers,
        data=("&".join(f"{k}={quote(v)}" for k, v in data.items())).encode("utf-8"),
    )
    try:
        with urlopen(req, timeout=60) as resp:
            if resp.getcode() not in (200, 201):
                print(
                    f"ERROR: Failed to create GitLab project, HTTP {resp.getcode()}",
                    file=sys.stderr,
                )
                sys.exit(1)
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(
            f"ERROR: GitLab API returned HTTP {e.code} while creating project",
            file=sys.stderr,
        )
        print(body, file=sys.stderr)
        sys.exit(1)


def gitlab_update_project(
    gitlab_api: str,
    token: str,
    full_path: str,
    name: str = None,
    visibility: str = None,
) -> None:
    headers = {"PRIVATE-TOKEN": token}
    encoded_path = quote(full_path, safe="")
    url = f"{gitlab_api}/projects/{encoded_path}"

    params: Dict[str, str] = {}
    if name is not None:
        params["name"] = name
    if visibility is not None:
        params["visibility"] = visibility

    if not params:
        return

    data = "&".join(f"{k}={quote(v)}" for k, v in params.items()).encode("utf-8")
    req = Request(url, headers=headers, data=data, method="PUT")
    try:
        with urlopen(req, timeout=60) as resp:
            if resp.getcode() not in (200, 201):
                print(
                    f"ERROR: Failed to update GitLab project, HTTP {resp.getcode()}",
                    file=sys.stderr,
                )
                sys.exit(1)
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(
            f"ERROR: GitLab API returned HTTP {e.code} while updating project",
            file=sys.stderr,
        )
        print(body, file=sys.stderr)
        sys.exit(1)


def gitlab_delete_project(gitlab_api: str, token: str, full_path: str) -> None:
    headers = {"PRIVATE-TOKEN": token}
    encoded_path = quote(full_path, safe="")
    url = f"{gitlab_api}/projects/{encoded_path}"
    req = Request(url, headers=headers, method="DELETE")
    try:
        with urlopen(req, timeout=60) as resp:
            if resp.getcode() not in (200, 202, 204):
                print(
                    f"WARNING: Failed to delete GitLab project {full_path}, HTTP {resp.getcode()}",
                    file=sys.stderr,
                )
    except HTTPError as e:
        print(
            f"WARNING: Failed to delete GitLab project {full_path}, HTTP {e.code}",
            file=sys.stderr,
        )


def gitlab_list_projects_for_namespace(
    gitlab_api: str, token: str, ns_id: int
) -> List[Dict[str, object]]:
    """
    Return projects for a namespace, handling both group and user namespaces.
    For user namespaces, this follows the GitLab workflow:
    1) GET /namespaces/:id to discover kind and path (username)
    2) If kind == "user", resolve username -> user id via /users?username=
    3) List projects via /users/:id/projects
    For group namespaces, use /groups/:id/projects.
    For other namespaces, fall back to /projects?namespace_id=.
    """
    headers = {"PRIVATE-TOKEN": token}

    # Step 1: inspect the namespace to determine its kind and path/username
    ns_url = f"{gitlab_api}/namespaces/{ns_id}"
    status, ns_data = http_get_json(ns_url, headers=headers)
    if status != 200 or not isinstance(ns_data, dict):
        print("ERROR: Failed to fetch GitLab namespace info.", file=sys.stderr)
        sys.exit(1)

    kind = str(ns_data.get("kind", ""))
    path = str(ns_data.get("path", ""))

    # Step 2/3: user namespace -> resolve user id, then list user's projects
    if kind == "user":
        if not path:
            print(
                "ERROR: GitLab user namespace is missing path/username.",
                file=sys.stderr,
            )
            sys.exit(1)

        users_url = f"{gitlab_api}/users?username={quote(path)}"
        status_user, users_data = http_get_json(users_url, headers=headers)
        if status_user != 200 or not isinstance(users_data, list) or not users_data:
            print(
                "ERROR: Failed to resolve GitLab user from namespace path.",
                file=sys.stderr,
            )
            sys.exit(1)

        user_id = users_data[0].get("id")
        if user_id is None:
            print("ERROR: GitLab user object missing id.", file=sys.stderr)
            sys.exit(1)

        projects_url = f"{gitlab_api}/users/{user_id}/projects?per_page=100"
        status_proj, projects_data = http_get_json(projects_url, headers=headers)
        if status_proj != 200 or not isinstance(projects_data, list):
            print(
                "ERROR: Failed to fetch GitLab projects list for user.",
                file=sys.stderr,
            )
            sys.exit(1)

        return projects_data

    # Group namespaces should be listed via /groups/:id/projects
    if kind == "group":
        group_id = ns_data.get("id")
        if group_id is None:
            print("ERROR: GitLab group namespace missing id.", file=sys.stderr)
            sys.exit(1)

        projects_url = f"{gitlab_api}/groups/{group_id}/projects?per_page=100"
        status_proj, projects_data = http_get_json(projects_url, headers=headers)
        if status_proj != 200 or not isinstance(projects_data, list):
            print(
                "ERROR: Failed to fetch GitLab projects list for group.",
                file=sys.stderr,
            )
            sys.exit(1)

        return projects_data

    # Other namespaces (if any) use the namespace_id filter
    projects_url = (
        f"{gitlab_api}/projects?namespace_id={ns_id}&per_page=100&simple=true"
    )
    status_proj, projects_data = http_get_json(projects_url, headers=headers)
    if status_proj != 200 or not isinstance(projects_data, list):
        print("ERROR: Failed to fetch GitLab projects list.", file=sys.stderr)
        sys.exit(1)

    return projects_data


def main(argv: Sequence[str]) -> int:
    script_dir = Path(__file__).resolve().parent
    load_dotenv(script_dir / ".env")

    # ===== CONFIG =====
    github_owner = os.environ.get("GITHUB_OWNER", "YOUR_GITHUB_USERNAME_OR_ORG")
    gitlab_namespace = os.environ.get("GITLAB_NAMESPACE", "YOUR_GITLAB_NAMESPACE")

    backup_dir = Path(
        os.environ.get("BACKUP_DIR", str(Path.home() / "git-mirror-backups"))
    )

    mirror_sleep_secs_raw = os.environ.get("MIRROR_SLEEP_SECS", "2")
    try:
        mirror_sleep_secs = float(mirror_sleep_secs_raw)
    except ValueError:
        mirror_sleep_secs = 2.0

    skip_repos_raw = os.environ.get("SKIP_REPOS", "")
    skip_repos = parse_skip_repos(skip_repos_raw)

    mirror_emoji_prefix = os.environ.get("MIRROR_EMOJI_PREFIX", "_")
    gitlab_path_prefix = os.environ.get("GITLAB_PATH_PREFIX", "glm")

    gh_token = env_required("GH_TOKEN", "Set GH_TOKEN (GitHub token with read access)")
    gitlab_token = env_required(
        "GITLAB_TOKEN",
        "Set GITLAB_TOKEN (GitLab token with api+write_repository)",
    )

    gitlab_api = os.environ.get("GITLAB_API", "https://gitlab.com/api/v4")
    gitlab_host = os.environ.get("GITLAB_HOST", "gitlab.com")

    # CLI flags
    skip_mirror = False
    for arg in argv[1:]:
        if arg == "--cleanup-only":
            skip_mirror = True
        else:
            print(f"Unknown argument: {arg}", file=sys.stderr)
            print(f"Usage: {argv[0]} [--cleanup-only]", file=sys.stderr)
            return 1

    # Prepare backup directory
    backup_dir.mkdir(parents=True, exist_ok=True)
    os.chdir(str(backup_dir))

    print(f"Fetching repo list from GitHub owner: {github_owner} ...")
    repos = github_list_repos(github_owner, gh_token)
    repo_meta = github_repo_meta(repos)

    ns_id = gitlab_get_namespace_id(gitlab_api, gitlab_token, gitlab_namespace)

    if not skip_mirror:
        print(f"Starting mirror of {len(repo_meta)} repos...")

        for repo, gh_visibility in repo_meta:
            if should_skip_repo(repo, skip_repos):
                print()
                print(f"=== {repo} ===")
                print("Skipping (listed in SKIP_REPOS).")
                continue

            print()
            print(f"=== {repo} ===")
            print(f"GitHub visibility: {gh_visibility}")

            gitlab_visibility = "public" if gh_visibility == "PUBLIC" else "private"
            print(f"Desired GitLab visibility: {gitlab_visibility}")

            # Derive GitLab project path
            gitlab_path = repo
            if not gitlab_path[:1].isalnum():
                gitlab_path = f"{gitlab_path_prefix}{repo}"

            full_path = f"{gitlab_namespace}/{gitlab_path}"
            exists, project_json = gitlab_project_exists(
                gitlab_api, gitlab_token, full_path
            )

            if not exists:
                project_name = repo
                if not repo[:1].isalnum():
                    project_name = f"{mirror_emoji_prefix}{repo}"
                print(
                    f"GitLab project missing -> creating {gitlab_namespace}/{gitlab_path}",
                )
                print(
                    f"Creating GitLab project with visibility: {gitlab_visibility}",
                )
                gitlab_create_project(
                    gitlab_api,
                    gitlab_token,
                    name=project_name,
                    path=gitlab_path,
                    ns_id=ns_id,
                    visibility=gitlab_visibility,
                )
            else:
                current_visibility = str(project_json.get("visibility"))
                current_name = str(project_json.get("name"))
                print(f"Current GitLab visibility: {current_visibility}")
                print(f"Current GitLab name: {current_name}")

                needs_visibility_update = current_visibility != gitlab_visibility

                desired_name = repo
                if not repo[:1].isalnum():
                    desired_name = f"{mirror_emoji_prefix}{repo}"
                needs_name_update = current_name != desired_name

                if needs_visibility_update or needs_name_update:
                    print("Updating GitLab project metadata...")
                    gitlab_update_project(
                        gitlab_api,
                        gitlab_token,
                        full_path,
                        name=desired_name if needs_name_update else None,
                        visibility=(
                            gitlab_visibility if needs_visibility_update else None
                        ),
                    )
                else:
                    print("GitLab visibility and name already match desired.")

            # Mirror clone/fetch
            mirror_dir = backup_dir / f"{repo}.git"
            if not mirror_dir.is_dir():
                print("Cloning mirror from GitHub...")
                clone_url = f"https://{gh_token}@github.com/{github_owner}/{repo}.git"
                try:
                    subprocess.run(
                        ["git", "clone", "--mirror", clone_url, str(mirror_dir)],
                        check=True,
                    )
                except subprocess.CalledProcessError as e:
                    print("ERROR: git clone --mirror failed", file=sys.stderr)
                    return e.returncode
            else:
                print("Fetching updates from GitHub...")
                clone_url = f"https://{gh_token}@github.com/{github_owner}/{repo}.git"
                try:
                    subprocess.run(
                        [
                            "git",
                            "-C",
                            str(mirror_dir),
                            "remote",
                            "set-url",
                            "origin",
                            clone_url,
                        ],
                        check=True,
                    )
                    subprocess.run(
                        ["git", "-C", str(mirror_dir), "fetch", "-p", "origin"],
                        check=True,
                    )
                except subprocess.CalledProcessError as e:
                    print("ERROR: git fetch failed", file=sys.stderr)
                    return e.returncode

            # Push mirror to GitLab
            print("Pushing mirror to GitLab...")
            gitlab_url = f"https://oauth2:{gitlab_token}@{gitlab_host}/{gitlab_namespace}/{gitlab_path}.git"
            try:
                subprocess.run(
                    ["git", "-C", str(mirror_dir), "push", "--mirror", gitlab_url],
                    check=True,
                )
            except subprocess.CalledProcessError as e:
                print("ERROR: git push --mirror failed", file=sys.stderr)
                return e.returncode

            # Optional throttle
            if mirror_sleep_secs != 0:
                print(f"Sleeping for {mirror_sleep_secs} seconds before next repo...")
                time.sleep(mirror_sleep_secs)
    else:
        print("Skipping mirroring phase (running cleanup only due to --cleanup-only).")

    # ===== CLEANUP PHASE =====
    print()
    print(
        f"Scanning for GitLab projects in {gitlab_namespace} that no longer exist on GitHub..."
    )

    github_repos = [name for name, _ in repo_meta]

    # Build expected GitLab project paths based on mapping rule
    github_gitlab_paths: Set[str] = set()
    for gh_repo in github_repos:
        if not gh_repo:
            continue
        gl_path = gh_repo
        if not gh_repo[:1].isalnum():
            gl_path = f"{gitlab_path_prefix}{gh_repo}"
        github_gitlab_paths.add(gl_path)

    # Collect GitLab projects in this namespace (single request, assumes <= 100 projects)
    print(f"Fetching GitLab projects list for namespace ID {ns_id}...")
    data = gitlab_list_projects_for_namespace(gitlab_api, gitlab_token, ns_id)

    gitlab_project_names: List[str] = []
    for item in data:
        if isinstance(item, dict) and "path" in item:
            gitlab_project_names.append(str(item["path"]))

    print("Parsed GitLab project names:")
    for name in gitlab_project_names:
        print(name)

    for gl_repo in gitlab_project_names:
        if not gl_repo:
            continue

        if should_skip_repo(gl_repo, skip_repos):
            print(f"Skipping cleanup for {gl_repo} (listed in SKIP_REPOS).")
            continue

        if gl_repo in github_gitlab_paths:
            continue

        # Reconstruct local repo name from GitLab project path when prefix was added
        local_repo_name = gl_repo
        if gl_repo.startswith(gitlab_path_prefix):
            local_repo_name = gl_repo[len(gitlab_path_prefix) :]

        mirror_dir = backup_dir / f"{local_repo_name}.git"
        if not mirror_dir.is_dir():
            print(
                f"GitLab project '{gitlab_namespace}/{gl_repo}' has no matching GitHub repo, "
                "but no local mirror directory was found; leaving it untouched."
            )
            continue

        print(
            f"Deleting GitLab project '{gitlab_namespace}/{gl_repo}' "
            f"(no matching GitHub repo) and its local mirror..."
        )

        full_path = f"{gitlab_namespace}/{gl_repo}"
        gitlab_delete_project(gitlab_api, gitlab_token, full_path)

        try:
            shutil.rmtree(mirror_dir)
        except OSError as e:
            print(
                f"WARNING: Failed to delete local mirror directory {mirror_dir}: {e}",
                file=sys.stderr,
            )

    print()
    print(f"All done. Local mirrors stored in: {backup_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
