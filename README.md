# Protheus Coder

Servidor **MCP próprio** (FastMCP + **Claude Agent SDK**) exposto como
**Streamable HTTP** para agentes do **Microsoft Copilot Studio**, com o objetivo
de entender e responder dúvidas sobre o código de projetos **Protheus (AdvPL /
TLPP)** e outras linguagens hospedados no **Azure DevOps**.

Em vez de expor as ferramentas cruas do Claude Code (`Read`, `Grep`, `Bash`, ...)
diretamente ao orquestrador, o servidor publica um **contrato pequeno e
auditável** de ferramentas de alto nível. O raciocínio sobre código acontece
**dentro do container**, numa sessão headless e **somente leitura** do Claude
(via `claude-agent-sdk`, o novo nome do claude-code-sdk), com escopo travado no
repositório.

Os repositórios são clonados e indexados **sob demanda** — não há job de
sincronização. Uma chave de leitura (PAT do Azure DevOps) fica montada como
secret no container, e o volume persistente `/workspace` funciona como cache:
cada repositório paga o custo de clone/indexação uma única vez.

## Arquitetura

```
Teams / Web Chat
      │
      ▼
Copilot Studio (orquestração generativa)
      ├── Conector custom  ──► Azure Container Apps ─► Caddy (:8080, valida X-API-Key)
      │                                                    └─► FastMCP (:8000 /mcp)
      │                                                           ├─ list_repos / repo_status
      │                                                           ├─ sync_repo ─► get-repo.sh (clone/pull + index)
      │                                                           ├─ search_code ─► plugadvpl / codegraph
      │                                                           └─ ask_codebase ─► claude-agent-sdk
      │                                                                  (read-only, cwd = repo, índices)
      └── MCP remoto Azure DevOps (mcp.dev.azure.com/{org}) para listar projetos/repos
```

O raciocínio deixa de depender do orquestrador: `ask_codebase` roda o loop do
Claude internamente, o que melhora a qualidade das respostas e mantém a
superfície de ferramentas exposta pequena e governável.

Componentes:

| Camada | Tecnologia |
| --- | --- |
| Contrato de ferramentas (MCP) | [FastMCP](https://gofastmcp.com/) (Streamable HTTP, stateless) |
| Raciocínio sobre código | [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview) headless (somente leitura) |
| Harness do agente | Claude Code CLI (`@anthropic-ai/claude-code`) |
| Autenticação do endpoint | Caddy validando header `X-API-Key` |
| Índice AdvPL/TLPP | [plugadvpl](https://github.com/JoniPraia/plugadvpl) (SQLite + FTS5 + call graph) |
| Índice outras linguagens | [CodeGraph](https://codegraph.codes/) |
| Hospedagem | Azure Container Apps (ingress HTTPS + Azure Files) |
| Listagem de projetos/repos | MCP remoto do Azure DevOps (`https://mcp.dev.azure.com/{org}`) |

## Ferramentas expostas

| Ferramenta | Descrição |
| --- | --- |
| `list_repos()` | Lista os repositórios já em cache no `/workspace` e o estado do índice. |
| `sync_repo(project, repo, force_reindex=false)` | Clona/atualiza e indexa um repo sob demanda (em segundo plano); retorna o estado atual. |
| `repo_status(project, repo)` | Estado de fetch/index (`absent`, `queued`, `cloning`, `indexing`, `ready`, `error`, ...). |
| `search_code(project, repo, query, kind)` | Busca determinística (sem LLM) nos índices. `kind`: `find`/`grep`/`arch`/`callers`/`callees`/`tables` (plugadvpl) ou `search`/`context` (codegraph). |
| `ask_codebase(project, repo, question, session_id?)` | Pergunta em linguagem natural. Roda o Claude headless e somente leitura no repo; retorna resposta com citações `arquivo:linha`, além de `session_id` (para follow-ups), custo e turnos. Exige `repo_status == "ready"`. |

A descoberta de novos projetos/repositórios continua sendo feita pelo **MCP
remoto do Azure DevOps**; `list_repos` mostra apenas o que já foi buscado.

## Estrutura do repositório

```
Dockerfile                     # imagem única: Node + Python + Caddy + tooling
entrypoint.sh                  # sobe o servidor FastMCP + Caddy (sem sync na inicialização)
docker-compose.yml             # execução/teste local
server/                        # servidor MCP (FastMCP + Claude Agent SDK)
  main.py                      # app FastMCP e registro das ferramentas
  tools.py                     # helpers determinísticos (repos + search_code)
  agent.py                     # wrapper do claude-agent-sdk (ask_codebase, read-only)
  config.py                    # configuração via ambiente
  requirements.txt             # fastmcp + claude-agent-sdk
proxy/Caddyfile                # gate de API key + reverse proxy do /mcp
config/claude-settings.json    # permissões do Claude Code (defesa em profundidade)
config/workspace-CLAUDE.md     # memória do projeto (índices -> Read/Grep/Glob)
scripts/get-repo.sh            # fetch + index idempotente e sob demanda
scripts/repo-status.sh         # estado do fetch/index (para o modo background)
connector/claude-code-mcp.yaml # OpenAPI do conector custom do Copilot Studio
infra/                         # Bicep para Azure Container Apps (azd)
azure.yaml                     # definição do projeto azd
```

## Variáveis de ambiente

| Variável | Descrição |
| --- | --- |
| `ANTHROPIC_API_KEY` | Chave usada pelo Claude Agent SDK (`ask_codebase`). |
| `MCP_API_KEY` | Chave estática exigida no header `X-API-Key` (gerar com `openssl rand -hex 32`). |
| `AZDO_ORG` | Slug da organização do Azure DevOps (parte após `dev.azure.com/`). |
| `AZDO_PAT` | PAT **somente leitura** (escopo Code: Read) — a "chave privada" para clonar repos. |
| `CLAUDE_MODEL` | Opcional. Fixa um modelo Claude mais barato/rápido para `ask_codebase` (vazio = default do SDK). |
| `ASK_MAX_TURNS` | Opcional. Teto de turnos do loop do agente por chamada (default `30`). |
| `PUBLIC_PORT` | Porta pública servida pelo Caddy (default `8080`). |
| `GATEWAY_PORT` | Porta interna do servidor FastMCP (default `8000`). |

> `AZDO_PAT` e `MCP_API_KEY` são removidos do ambiente de execução do agente do
> `ask_codebase` — a sessão headless somente leitura nunca vê esses segredos.

## Execução local

```bash
cp .env.example .env      # preencha ANTHROPIC_API_KEY, MCP_API_KEY, AZDO_ORG, AZDO_PAT
docker compose up --build
```

O endpoint MCP fica em `http://localhost:8080/mcp` (header `X-API-Key: <MCP_API_KEY>`).
O healthcheck fica em `http://localhost:8080/healthz`.

### Validar com o MCP Inspector

```bash
npx @modelcontextprotocol/inspector
```

No Inspector escolha **Transport: Streamable HTTP**, URL `http://localhost:8080/mcp`
e adicione o header `X-API-Key` com o valor de `MCP_API_KEY`. Você deve listar as
cinco ferramentas (`list_repos`, `sync_repo`, `repo_status`, `search_code`,
`ask_codebase`) e executar, por exemplo:

1. `sync_repo` com um projeto/repo de teste e depois `repo_status` até
   `state == "ready"`.
2. `search_code` para uma busca determinística (ex.: `kind = "grep"`).
3. `ask_codebase` com uma pergunta; guarde o `session_id` retornado e reenvie-o
   numa segunda chamada para continuar o mesmo raciocínio (follow-up).

## Deploy no Azure (azd)

Pré-requisitos: [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
e Docker.

```bash
azd auth login
azd env new protheus-coder

azd env set ANTHROPIC_API_KEY "sk-ant-..."
azd env set MCP_API_KEY "$(openssl rand -hex 32)"
azd env set AZDO_ORG "contoso"
azd env set AZDO_PAT "<PAT read-only>"
# opcional: fixar um modelo mais barato/rápido para ask_codebase
# azd env set CLAUDE_MODEL "<claude-model-id>"

azd up   # provisiona infra + build/push da imagem + deploy
```

Ao final, `azd` imprime `SERVICE_PROTHEUS_CODER_ENDPOINT`, algo como
`https://pc-app-xxxx.<region>.azurecontainerapps.io/mcp`. Guarde essa URL e a
`MCP_API_KEY` para configurar o Copilot Studio.

A infraestrutura provisiona: Log Analytics, Container Registry, identidade
gerenciada (AcrPull), Storage Account + Azure File Share (`workspace`), Container
Apps Environment e o Container App com ingress HTTPS externo na porta 8080, volume
persistente em `/workspace` e os secrets injetados.

## Integração com o Copilot Studio

### 1. Ferramenta principal — conector custom (Protheus Coder MCP)

1. No [Power Apps](https://make.powerapps.com) → **Custom connectors** → **New
   custom connector** → **Import an OpenAPI file** e selecione
   [`connector/claude-code-mcp.yaml`](connector/claude-code-mcp.yaml).
2. Na aba **General**: **Scheme** `HTTPS`, **Host** = FQDN do Container App (a URL
   do `SERVICE_PROTHEUS_CODER_ENDPOINT` sem `https://` e sem `/mcp`).
3. Na aba **Security**: **API Key**, **Parameter name** `X-API-Key`, **Location**
   `Header`. O valor é fornecido na criação da conexão.
4. **Create connector**.
5. No Copilot Studio, abra o agente (com **orquestração generativa** habilitada) →
   **Tools** → **Add a tool** → **Model Context Protocol** → selecione o conector
   criado. Crie a conexão informando a `MCP_API_KEY` e confirme o status
   **Connected**.

> O transporte **Streamable HTTP** é exigido pelo Copilot Studio (SSE foi
> descontinuado em agosto/2025). O connector já declara
> `x-ms-agentic-protocol: mcp-streamable-1.0`.

### 2. Listagem de projetos/repositórios — MCP remoto do Azure DevOps

No mesmo agente, adicione outra ferramenta MCP apontando para o endpoint hospedado
pela Microsoft:

- **Server URL**: `https://mcp.dev.azure.com/{org}` (troque `{org}` pela sua org)
- O Copilot Studio é um cliente suportado; a conexão pede login do usuário, que
  precisa ter acesso à organização no Azure DevOps.

Ferramentas úteis: `core_list_projects`, `repo_repository (list)`,
`repo_file (list_directory / get_content)`.

### 3. Instruções sugeridas para o agente

```
Você ajuda a entender código de projetos Protheus (AdvPL/TLPP) e outras linguagens.
1. Use o MCP do Azure DevOps para identificar o projeto e o repositório.
2. Garanta o repositório em cache: chame sync_repo(project, repo) e acompanhe com
   repo_status(project, repo) até state == "ready" (pode levar minutos em repos
   grandes; sincronize antes de perguntar).
3. Para buscas pontuais e determinísticas (símbolos, callers, tabelas), use
   search_code(project, repo, query, kind).
4. Para dúvidas em linguagem natural, use ask_codebase(project, repo, question).
   Guarde o session_id retornado e reenvie-o em perguntas de acompanhamento para
   manter o contexto. As respostas já citam arquivo e linha.
Você tem acesso somente leitura ao código.
```

## Limitações conhecidas

- **CodeGraph não parseia AdvPL** (não há gramática tree-sitter). A inteligência
  AdvPL/TLPP vem do plugadvpl; o CodeGraph cobre eventuais fontes em outras
  linguagens.
- **Cold start por repositório**: a primeira sincronização de um repo grande
  dispara clone + indexação e roda em segundo plano. Chame `sync_repo` e aguarde
  `repo_status == "ready"` **antes** de `ask_codebase`, senão a pergunta é
  recusada. Repositórios muito grandes podem ser pré-aquecidos pelo console do
  Container App (`az containerapp exec`).
- **`ask_codebase` é síncrono**: uma pergunta que exija muita exploração pode se
  aproximar do timeout de ~2 min do conector do Power Platform. Prefira
  `search_code` para buscas pontuais e mantenha as perguntas específicas; o teto
  de turnos é configurável via `ASK_MAX_TURNS`.
- **Sessões de agente locais**: o `session_id` do `ask_codebase` é persistido em
  `CLAUDE_CONFIG_DIR` (não no volume `/workspace`). Combinado com o cache de
  repositórios, isso mantém a recomendação de uma única réplica
  (`minReplicas = maxReplicas = 1`), o que também mantém o `/workspace` quente.

## Segurança

- Segredos (`ANTHROPIC_API_KEY`, `AZDO_PAT`, `MCP_API_KEY`) vivem como secrets do
  Container App, nunca na imagem. Para produção, considere referenciá-los via Key
  Vault.
- O PAT nunca é persistido na working tree do git (`get-repo.sh` reescreve a URL do
  `origin` sem o token após clonar/atualizar).
- **Controle de ações em duas camadas.** O controle primário é por chamada, no
  `ClaudeAgentOptions` de [`server/agent.py`](server/agent.py): `allowed_tools`
  (leitura + índices + git somente leitura), `disallowed_tools`
  (`Write`/`Edit`/`WebFetch`/...) e `permission_mode="dontAsk"`, que **nega por
  padrão** (fail closed) tudo o que não estiver na allowlist — apropriado para um
  serviço headless sem humano para aprovar prompts. Como defesa em profundidade,
  o Claude Code também carrega [`config/claude-settings.json`](config/claude-settings.json)
  (mesmos denies). O `cwd` do agente é travado no diretório do repositório.
- **Segredos fora do agente**: `AZDO_PAT` e `MCP_API_KEY` são removidos do
  ambiente de execução do agente do `ask_codebase` (ver `agent_env()` em
  [`server/config.py`](server/config.py)).
- **Evolução para escrita (futuro)**: quando `ask_codebase` evoluir para propor
  ajustes de código, o desenho previsto isola as edições em um git worktree
  dedicado e nunca faz push direto — abrindo Pull Request via API do Azure DevOps
  com um PAT de escopo de escrita separado.
