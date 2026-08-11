# Protheus Coder — Claude Code MCP server exposed over Streamable HTTP
# for Microsoft Copilot Studio.
#
# Layers:
#   - Node.js            -> Claude Code CLI + supergateway
#   - Python 3 + uv      -> plugadvpl (AdvPL/TLPP indexer)
#   - codegraph (npm)    -> code graph for other languages
#   - Caddy              -> API-key auth in front of the gateway
FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_NO_CACHE_DIR=1 \
    WORKSPACE=/workspace \
    CLAUDE_CONFIG_DIR=/root/.claude \
    PATH=/root/.local/bin:$PATH

# System dependencies.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        python3 \
        python3-pip \
        python3-venv \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Caddy binary (reverse proxy + API-key gate) from the official image.
COPY --from=caddy:2 /usr/bin/caddy /usr/bin/caddy

# Node tooling: Claude Code CLI + supergateway (stdio -> Streamable HTTP) + codegraph.
RUN npm install -g \
        @anthropic-ai/claude-code \
        supergateway \
        @colbymchenry/codegraph \
    && npm cache clean --force

# Python tooling: plugadvpl (AdvPL/TLPP indexer, SQLite + FTS5 + call graph).
RUN pip3 install plugadvpl

WORKDIR /app

# Application files.
COPY scripts/ /app/scripts/
COPY proxy/Caddyfile /app/proxy/Caddyfile
COPY config/claude-settings.json /root/.claude/settings.json
COPY config/workspace-CLAUDE.md /app/config/workspace-CLAUDE.md
COPY entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh /app/scripts/*.sh \
    && ln -s /app/scripts/get-repo.sh /usr/local/bin/get-repo.sh \
    && ln -s /app/scripts/repo-status.sh /usr/local/bin/repo-status.sh

# Persistent cache of cloned repos + indices (mounted as a volume in production).
VOLUME ["/workspace"]

# Public port served by Caddy (Container Apps ingress target).
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
