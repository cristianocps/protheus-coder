"""Deterministic, non-LLM helpers backing the MCP tools.

These wrap the existing shell scripts and code indexers (plugadvpl / codegraph)
so the orchestrator gets fast, cheap, reproducible answers for repo management
and symbol lookups. No Claude calls happen here.
"""
from __future__ import annotations

import json
import os
import subprocess
from typing import Any

from . import config

# Supported search kinds mapped to the index CLI that serves them. plugadvpl is
# the AdvPL/TLPP index (SQLite + FTS5 + call graph); codegraph covers other
# languages. Each entry is a builder that returns the argv for the query.
_PLUGADVPL_KINDS = {"find", "grep", "arch", "callers", "callees", "tables"}
_CODEGRAPH_KINDS = {"search", "context"}
SEARCH_KINDS = sorted(_PLUGADVPL_KINDS | _CODEGRAPH_KINDS)


def _run(argv: list[str], env: dict[str, str] | None = None) -> dict[str, Any]:
    """Run a subprocess and capture its result in a JSON-friendly dict."""
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=config.SUBPROCESS_TIMEOUT,
            env=env if env is not None else os.environ.copy(),
            check=False,
        )
    except FileNotFoundError as exc:
        return {"ok": False, "error": f"command not found: {argv[0]} ({exc})"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"timed out after {config.SUBPROCESS_TIMEOUT}s"}
    return {
        "ok": proc.returncode == 0,
        "exit_code": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def read_status(project: str, repo: str) -> dict[str, Any]:
    """Return the fetch/index status for a repo (same JSON get-repo.sh writes)."""
    config.sanitize("project", project)
    config.sanitize("repo", repo)
    path = config.status_file(project, repo)
    if path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            return {
                "project": project,
                "repo": repo,
                "state": "error",
                "message": f"could not read status file: {exc}",
            }
    return {
        "project": project,
        "repo": repo,
        "state": "absent",
        "message": f"not fetched yet; call sync_repo({project!r}, {repo!r})",
    }


def list_repos() -> dict[str, Any]:
    """List repositories already present in the workspace cache with their state."""
    repos: list[dict[str, Any]] = []
    if config.STATUS_DIR.is_dir():
        for path in sorted(config.STATUS_DIR.glob("*.json")):
            try:
                repos.append(json.loads(path.read_text(encoding="utf-8")))
            except (OSError, json.JSONDecodeError):
                continue
    return {"count": len(repos), "repos": repos}


def sync_repo(project: str, repo: str, force_reindex: bool = False) -> dict[str, Any]:
    """Clone/pull + index a repo on demand (background), returning current state.

    Delegates to get-repo.sh --background: the clone/index runs detached so this
    call returns quickly, and the orchestrator polls repo_status until 'ready'.
    """
    config.sanitize("project", project)
    config.sanitize("repo", repo)
    argv = ["get-repo.sh", project, repo, "--background"]
    if force_reindex:
        argv.append("--force-reindex")
    # get-repo.sh needs AZDO_ORG/AZDO_PAT to clone; pass the full process env.
    result = _run(argv, env=os.environ.copy())
    result["status"] = read_status(project, repo)
    return result


def search_code(
    project: str, repo: str, query: str, kind: str = "grep"
) -> dict[str, Any]:
    """Query the code indices deterministically (no LLM).

    ``kind`` selects the index/operation:
      - plugadvpl (AdvPL/TLPP): find, grep, arch, callers, callees, tables
      - codegraph (other languages): search, context
    """
    config.sanitize("project", project)
    config.sanitize("repo", repo)
    if kind not in SEARCH_KINDS:
        return {
            "ok": False,
            "error": f"unknown kind {kind!r}; expected one of {SEARCH_KINDS}",
        }

    dest = config.repo_dir(project, repo)
    if not (dest / ".git").is_dir():
        return {
            "ok": False,
            "error": f"repo not present; call sync_repo({project!r}, {repo!r}) first",
        }

    if kind in _PLUGADVPL_KINDS:
        argv = ["plugadvpl", kind, query, "--root", str(dest)]
    else:  # codegraph
        argv = ["codegraph", kind, query, "--dir", str(dest)]

    result = _run(argv, env=os.environ.copy())
    result["kind"] = kind
    result["query"] = query
    return result
