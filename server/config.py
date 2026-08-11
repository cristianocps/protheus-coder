"""Runtime configuration derived from the environment.

Everything is env-driven so the same image behaves correctly in local
development (docker compose) and in Azure Container Apps.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

# Root of the persistent cache of cloned repositories and their indices. Mounted
# as a volume in production; a plain directory locally.
WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))

# Where get-repo.sh writes per-repo fetch/index status as JSON.
STATUS_DIR = WORKSPACE / ".status"

# Loopback port the FastMCP app listens on. Caddy (public :PUBLIC_PORT) validates
# the API key and reverse-proxies /mcp here, so the gateway never binds a public
# interface itself.
GATEWAY_HOST = os.environ.get("GATEWAY_HOST", "127.0.0.1")
GATEWAY_PORT = int(os.environ.get("GATEWAY_PORT", "8000"))
MCP_PATH = os.environ.get("MCP_PATH", "/mcp")

# Claude model used by ask_codebase. Left unset means "SDK default"; operators
# can pin a cheaper/faster model (e.g. a Haiku-class id) via CLAUDE_MODEL.
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL") or None

# Hard cap on the agent loop for a single ask_codebase call. The single most
# important guardrail against a runaway loop in an unattended run.
ASK_MAX_TURNS = int(os.environ.get("ASK_MAX_TURNS", "30"))

# Wall-clock budget (seconds) for deterministic subprocess helpers such as
# get-repo.sh (in --background mode it returns quickly) and the index queries.
SUBPROCESS_TIMEOUT = int(os.environ.get("SUBPROCESS_TIMEOUT", "120"))

# Environment variables that must never reach the code-reading agent's tool
# execution context (its Bash tool, subprocesses, etc.). The server process
# still needs AZDO_PAT to clone via get-repo.sh, but the agent does not.
SENSITIVE_ENV_KEYS = ("AZDO_PAT", "MCP_API_KEY")

# Only simple, filesystem-safe names are accepted from the orchestrator. This
# mirrors the sanitize() guard inside get-repo.sh and blocks path traversal.
_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


class InvalidName(ValueError):
    """Raised when a project/repo name fails the safe-name check."""


def sanitize(kind: str, value: str) -> str:
    """Return ``value`` if it is a safe name, otherwise raise ``InvalidName``."""
    if not value or not _NAME_RE.match(value):
        raise InvalidName(f"invalid {kind} name: {value!r}")
    return value


def repo_key(project: str, repo: str) -> str:
    return f"{project}__{repo}"


def repo_dir(project: str, repo: str) -> Path:
    return WORKSPACE / project / repo


def status_file(project: str, repo: str) -> Path:
    return STATUS_DIR / f"{repo_key(project, repo)}.json"


def agent_env() -> dict[str, str]:
    """A copy of the process environment with secrets stripped.

    Used as the tool-execution environment for the Claude Agent SDK so the
    read-only code agent never sees the Azure DevOps PAT or the public API key.
    """
    env = {k: v for k, v in os.environ.items() if k not in SENSITIVE_ENV_KEYS}
    return env
