"""Claude Agent SDK wrapper for the ask_codebase tool.

This is where the reasoning happens: instead of handing Copilot Studio the raw
Claude Code tools, we run a headless, read-only Claude session *inside* the
container, scoped to a single repository. The permission posture is expressed in
code: an allowlist of read-only tools, a hard-deny list, and permission_mode
"dontAsk" (fail closed — deny anything not pre-approved), rather than relying
solely on on-disk settings.
"""
from __future__ import annotations

from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    SystemMessage,
    TextBlock,
    query,
)

from . import config, tools

# Auto-approved tools: read-only file access plus the index/query CLIs and a few
# safe, read-only git subcommands. Bash is only ever allowed for these prefixes.
ALLOWED_TOOLS = [
    "Read",
    "Grep",
    "Glob",
    "Bash(plugadvpl:*)",
    "Bash(codegraph:*)",
    "Bash(git log:*)",
    "Bash(git show:*)",
    "Bash(git diff:*)",
    "Bash(git status:*)",
    "Bash(git branch:*)",
    "Bash(ls:*)",
    "Bash(cat:*)",
    "Bash(head:*)",
    "Bash(tail:*)",
    "Bash(wc:*)",
    "Bash(find:*)",
]

# Hard denials. Deny rules win over any permissive mode.
DISALLOWED_TOOLS = [
    "Write",
    "Edit",
    "MultiEdit",
    "NotebookEdit",
    "WebFetch",
    "WebSearch",
]

# Appended on top of the Claude Code system prompt preset.
SYSTEM_PROMPT_APPEND = """
Você é um assistente somente leitura que responde dúvidas sobre o código de
projetos Protheus (AdvPL/TLPP) e outras linguagens. Regras:

- Acesso SOMENTE LEITURA. Nunca edite, crie, compile ou faça commit de nada.
- Consulte os índices ANTES de ler arquivos crus:
  - AdvPL/TLPP: `plugadvpl find|arch|callers|callees|tables|grep <termo> --root <repo>`
  - Outras linguagens: `codegraph search|context <termo> --dir <repo>`
  Aprofunde com Read/Grep/Glob apenas nos trechos que os índices apontarem.
- SEMPRE cite arquivo e linha (ex.: `src/foo.prw:123`) ao explicar código.
- AdvPL usa aliases de tabela como `SA1->A1_COD`; trate `A1_COD` como um token.
- Responda em português, de forma objetiva e fundamentada no código do repositório.
""".strip()


def _build_options(project: str, repo: str, session_id: str | None) -> ClaudeAgentOptions:
    options = ClaudeAgentOptions(
        system_prompt={
            "type": "preset",
            "preset": "claude_code",
            "append": SYSTEM_PROMPT_APPEND,
        },
        allowed_tools=ALLOWED_TOOLS,
        disallowed_tools=DISALLOWED_TOOLS,
        # Fail closed: 'dontAsk' denies anything not pre-approved by the allow
        # rules (there is no human to prompt in this headless service). Together
        # with disallowed_tools (hard deny) this is the read-only guardrail.
        permission_mode="dontAsk",
        cwd=str(config.repo_dir(project, repo)),
        max_turns=config.ASK_MAX_TURNS,
        # Load user settings (defense-in-depth deny rules) + project memory
        # (workspace CLAUDE.md) so on-disk policy still applies.
        setting_sources=["user", "project"],
        # Strip AZDO_PAT / MCP_API_KEY from the agent's tool-execution env.
        env=config.agent_env(),
    )
    if config.CLAUDE_MODEL:
        options.model = config.CLAUDE_MODEL
    if session_id:
        options.resume = session_id
    return options


async def ask(
    project: str, repo: str, question: str, session_id: str | None = None
) -> dict[str, Any]:
    """Answer a natural-language question about a repository.

    Returns the answer text, the SDK ``session_id`` (pass it back to continue the
    same reasoning in a follow-up), the run cost and turn count. Refuses if the
    repo has not been fetched/indexed yet.
    """
    config.sanitize("project", project)
    config.sanitize("repo", repo)

    if not session_id:
        status = tools.read_status(project, repo)
        if status.get("state") != "ready":
            return {
                "ok": False,
                "error": (
                    f"repo is not ready (state={status.get('state')!r}); call "
                    f"sync_repo({project!r}, {repo!r}) and poll repo_status until "
                    "state == 'ready'"
                ),
                "status": status,
            }

    options = _build_options(project, repo, session_id)

    new_session_id: str | None = session_id
    text_chunks: list[str] = []
    final: ResultMessage | None = None

    async for message in query(prompt=question, options=options):
        if isinstance(message, SystemMessage) and message.subtype == "init":
            new_session_id = message.data.get("session_id", new_session_id)
        elif isinstance(message, AssistantMessage):
            for block in message.content:
                if isinstance(block, TextBlock):
                    text_chunks.append(block.text)
        elif isinstance(message, ResultMessage):
            final = message

    # Prefer the SDK's final result text; fall back to concatenated assistant text.
    answer = ""
    if final is not None and getattr(final, "result", None):
        answer = final.result
    if not answer:
        answer = "".join(text_chunks).strip()

    return {
        "ok": True,
        "answer": answer,
        "session_id": new_session_id,
        "cost_usd": getattr(final, "total_cost_usd", None),
        "num_turns": getattr(final, "num_turns", None),
    }
