#!/usr/bin/env bash
# Boots the Protheus Coder MCP server.
#
# Flow (no sync job — repos are fetched on demand by the orchestrator):
#   1. Prepare the persistent /workspace cache and drop CLAUDE.md memory.
#   2. Start the FastMCP server (server.main) as a Streamable HTTP endpoint on
#      127.0.0.1:8000/mcp. It fronts the Claude Agent SDK with a small set of
#      read-only, high-level tools.
#   3. Start Caddy on :8080, which validates the API key and reverse-proxies
#      to the gateway. Caddy runs in the foreground as PID 1's child.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
GATEWAY_PORT="${GATEWAY_PORT:-8000}"
PUBLIC_PORT="${PUBLIC_PORT:-8080}"

log() { echo "[entrypoint] $*"; }

# --- 1. Workspace preparation -------------------------------------------------
mkdir -p "${WORKSPACE}" "${WORKSPACE}/.status"

# Seed project memory used by Claude Code (only if not already present so an
# operator can customize it on the persistent volume).
if [[ ! -f "${WORKSPACE}/CLAUDE.md" ]]; then
    cp /app/config/workspace-CLAUDE.md "${WORKSPACE}/CLAUDE.md"
    log "Seeded ${WORKSPACE}/CLAUDE.md"
fi

# Configure git to read the Azure DevOps PAT non-interactively when present.
if [[ -n "${AZDO_PAT:-}" ]]; then
    git config --global credential.helper store >/dev/null 2>&1 || true
fi

# --- 2. Gateway (FastMCP server -> Streamable HTTP) ---------------------------
# The server package lives in /app; each ask_codebase call sets the agent's cwd
# to the target repo explicitly, so the server's own cwd is irrelevant.
cd /app
export PYTHONPATH="/app:${PYTHONPATH:-}"

# The FastMCP app binds 127.0.0.1:${GATEWAY_PORT}; only Caddy's port is published
# through the Container Apps ingress, so the gateway stays private.
log "Starting FastMCP server on ${GATEWAY_HOST:-127.0.0.1}:${GATEWAY_PORT}/mcp"
python3 -m server.main &
GATEWAY_PID=$!

# Propagate gateway crash to the container so Container Apps restarts it.
trap 'log "Shutting down"; kill "${GATEWAY_PID}" 2>/dev/null || true' TERM INT

# --- 3. Public proxy with API-key validation ----------------------------------
export GATEWAY_PORT PUBLIC_PORT
log "Starting Caddy on :${PUBLIC_PORT} (API-key gate -> gateway)"
exec caddy run --config /app/proxy/Caddyfile --adapter caddyfile
