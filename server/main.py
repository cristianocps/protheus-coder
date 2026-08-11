"""FastMCP application: the public MCP surface for Copilot Studio.

Exposes a small set of high-level tools over Streamable HTTP. Caddy sits in
front and validates the X-API-Key header before proxying to this loopback app.

Run with:  python -m server.main
"""
from __future__ import annotations

from typing import Any

from fastmcp import FastMCP

from . import agent, config, tools

mcp: FastMCP = FastMCP(
    name="Protheus Coder",
    instructions=(
        "Ferramentas de alto nível para entender código de repositórios do Azure "
        "DevOps (Protheus/AdvPL e outras linguagens). Fluxo típico: liste com "
        "list_repos, garanta o cache com sync_repo + repo_status (até "
        "state == 'ready'), use search_code para buscas determinísticas e "
        "ask_codebase para perguntas em linguagem natural com citações."
    ),
)


@mcp.tool
def list_repos() -> dict[str, Any]:
    """Lista os repositórios já presentes no cache do workspace e o estado do índice.

    A descoberta de novos projetos/repositórios continua sendo feita pelo MCP
    remoto do Azure DevOps; esta ferramenta mostra apenas o que já foi buscado.
    """
    return tools.list_repos()


@mcp.tool
def repo_status(project: str, repo: str) -> dict[str, Any]:
    """Retorna o estado de fetch/index de um repositório.

    Estados possíveis: absent, queued, cloning, pulling, indexing, busy, ready,
    error. Use antes de ask_codebase para garantir state == 'ready'.
    """
    return tools.read_status(project, repo)


@mcp.tool
def sync_repo(
    project: str, repo: str, force_reindex: bool = False
) -> dict[str, Any]:
    """Clona/atualiza e indexa um repositório sob demanda (em segundo plano).

    Retorna imediatamente com o estado atual; acompanhe com repo_status até
    state == 'ready'. Use force_reindex=True para reconstruir os índices.
    """
    return tools.sync_repo(project, repo, force_reindex=force_reindex)


@mcp.tool
def search_code(
    project: str, repo: str, query: str, kind: str = "grep"
) -> dict[str, Any]:
    """Busca determinística nos índices de código (sem LLM), com arquivo:linha.

    kind:
      - plugadvpl (AdvPL/TLPP): find, grep, arch, callers, callees, tables
      - codegraph (outras linguagens): search, context
    """
    return tools.search_code(project, repo, query, kind=kind)


@mcp.tool
async def ask_codebase(
    project: str, repo: str, question: str, session_id: str | None = None
) -> dict[str, Any]:
    """Responde uma pergunta em linguagem natural sobre o código de um repositório.

    Roda uma sessão headless e SOMENTE LEITURA do Claude com escopo travado no
    repositório. Retorna a resposta (com citações arquivo:linha), o session_id
    (reenvie-o para continuar o mesmo raciocínio em um follow-up), além de custo
    e número de turnos. Requer o repositório já sincronizado (repo_status ==
    'ready'); caso contrário, chame sync_repo antes.
    """
    return await agent.ask(project, repo, question, session_id=session_id)


def main() -> None:
    mcp.run(
        transport="http",
        host=config.GATEWAY_HOST,
        port=config.GATEWAY_PORT,
        path=config.MCP_PATH,
        stateless_http=True,
    )


if __name__ == "__main__":
    main()
