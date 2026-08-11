# Protheus Coder

Servidor **MCP do Claude Code** exposto como **Streamable HTTP** para agentes do
**Microsoft Copilot Studio**, com o objetivo de entender e responder dúvidas
sobre o código de projetos **Protheus (AdvPL / TLPP)** hospedados no **Azure
DevOps**.

O orquestrador do Copilot Studio chama diretamente as ferramentas do Claude Code
(`Read`, `Grep`, `Glob`, `Bash`, ...). Os repositórios são clonados e indexados
**sob demanda** — não há job de sincronização. Uma chave de leitura (PAT do Azure
DevOps) fica montada como secret no container, e o volume persistente `/workspace`
funciona como cache: cada repositório paga o custo de clone/indexação uma única
vez.

## Arquitetura

```
Teams / Web Chat
      │
      ▼
Copilot Studio (orquestração generativa)
      ├── Conector custom  ──► Azure Container Apps ─► Caddy (:8080, valida X-API-Key)
      │                                                    └─► supergateway (:8000 /mcp)
      │                                                           └─► claude mcp serve
      │                                                                  ├─ Bash: get-repo.sh (clone/pull + index)
      │                                                                  └─ Read/Grep/Glob no /workspace (cache)
      └── MCP remoto Azure DevOps (mcp.dev.azure.com/{org}) para listar projetos/repos
```

Componentes:

| Camada | Tecnologia |
| --- | --- |
| Raciocínio sobre código | Modelo do Copilot Studio (orquestrador) usando as ferramentas do Claude Code |
| Ferramentas de código | `claude mcp serve` (Claude Code CLI) |
| Transporte HTTP | [supergateway](https://github.com/supercorp-ai/supergateway) (stdio → Streamable HTTP) |
| Autenticação do endpoint | Caddy validando header `X-API-Key` |
| Índice AdvPL/TLPP | [plugadvpl](https://github.com/JoniPraia/plugadvpl) (SQLite + FTS5 + call graph) |
| Índice outras linguagens | [CodeGraph](https://codegraph.codes/) |
| Hospedagem | Azure Container Apps (ingress HTTPS + Azure Files) |
| Listagem de projetos/repos | MCP remoto do Azure DevOps (`https://mcp.dev.azure.com/{org}`) |

## Estrutura do repositório

```
Dockerfile                     # imagem única: Node + Python + Caddy + tooling
entrypoint.sh                  # sobe supergateway + Caddy (sem sync na inicialização)
docker-compose.yml             # execução/teste local
proxy/Caddyfile                # gate de API key + reverse proxy do /mcp
config/claude-settings.json    # permissões do Claude Code (somente leitura)
config/workspace-CLAUDE.md     # memória do projeto (fluxo get-repo -> índices)
scripts/get-repo.sh            # fetch + index idempotente e sob demanda
scripts/repo-status.sh         # estado do fetch/index (para o modo background)
connector/claude-code-mcp.yaml # OpenAPI do conector custom do Copilot Studio
infra/                         # Bicep para Azure Container Apps (azd)
azure.yaml                     # definição do projeto azd
```

## Variáveis de ambiente

| Variável | Descrição |
| --- | --- |
| `ANTHROPIC_API_KEY` | Chave usada por `claude mcp serve`. |
| `MCP_API_KEY` | Chave estática exigida no header `X-API-Key` (gerar com `openssl rand -hex 32`). |
| `AZDO_ORG` | Slug da organização do Azure DevOps (parte após `dev.azure.com/`). |
| `AZDO_PAT` | PAT **somente leitura** (escopo Code: Read) — a "chave privada" para clonar repos. |
| `PUBLIC_PORT` | Porta pública servida pelo Caddy (default `8080`). |
| `GATEWAY_PORT` | Porta interna do supergateway (default `8000`). |

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
e adicione o header `X-API-Key` com o valor de `MCP_API_KEY`. Você deve conseguir
listar as ferramentas do Claude Code e executar, por exemplo, um `Bash` chamando
`get-repo.sh <projeto> <repo>` seguido de consultas `plugadvpl`.

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

### 1. Ferramenta principal — conector custom (Claude Code MCP)

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
Você ajuda a entender código de projetos Protheus (AdvPL/TLPP).
1. Use o MCP do Azure DevOps para identificar o projeto e o repositório.
2. Garanta o repositório localmente chamando, via Bash, get-repo.sh <projeto> <repo>.
   Para repositórios grandes, use get-repo.sh <projeto> <repo> --background e
   acompanhe com repo-status.sh até state == "ready".
3. Consulte os índices (plugadvpl find/arch/callers/callees/tables/grep e
   codegraph) antes de ler arquivos crus.
4. Aprofunde com Read/Grep/Glob apenas nos trechos indicados. Cite arquivo e linha.
Você tem acesso somente leitura.
```

## Limitações conhecidas

- **Raciocínio no orquestrador**: nesta arquitetura o Claude Code entra como
  provedor de ferramentas; quem raciocina é o modelo do Copilot Studio. Se a
  qualidade não bastar, a evolução é expor uma ferramenta de alto nível que rode
  Claude em modo headless.
- **CodeGraph não parseia AdvPL** (não há gramática tree-sitter). A inteligência
  AdvPL/TLPP vem do plugadvpl; o CodeGraph cobre eventuais fontes em outras
  linguagens.
- **Cold start por repositório**: a primeira pergunta sobre um repo grande dispara
  clone + indexação e pode esbarrar no timeout de ~2 min do conector do Power
  Platform. Use `get-repo.sh --background` e/ou pré-aqueça repositórios grandes uma
  vez pelo console do Container App (`az containerapp exec`).
- **Sessões MCP com estado** exigem uma única réplica (`minReplicas = maxReplicas
  = 1`), o que também mantém o cache do `/workspace` quente.

## Segurança

- Segredos (`ANTHROPIC_API_KEY`, `AZDO_PAT`, `MCP_API_KEY`) vivem como secrets do
  Container App, nunca na imagem. Para produção, considere referenciá-los via Key
  Vault.
- O PAT nunca é persistido na working tree do git (`get-repo.sh` reescreve a URL do
  `origin` sem o token após clonar/atualizar).
- O Claude Code roda com permissões restritas ([`config/claude-settings.json`](config/claude-settings.json)):
  ferramentas de leitura + uma allowlist de comandos Bash; `Write`/`Edit` e
  comandos destrutivos são negados.
