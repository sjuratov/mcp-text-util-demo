# A2A Text Utilities Agent

A lightweight [A2A (Agent-to-Agent)](https://google.github.io/A2A/) demo agent providing text utility skills. Designed for Azure deployment with minimal cost — no LLM calls, pure Python.

## Skills

| Skill | Description | Example |
|-------|-------------|---------|
| **Generate UUID** | Creates a new UUID v4 | `generate a uuid` |
| **Hash Text** | SHA-256 hash | `hash: hello world` |
| **Base64 Encode** | Base64-encode text | `base64 encode: hello` |
| **Base64 Decode** | Base64-decode text | `base64 decode: aGVsbG8=` |
| **Word Count** | Count words & characters | `word count: some text here` |

## Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) package manager

## Quick Start

### Install dependencies

```bash
uv sync
```

### Run the A2A server

```bash
uv run python -m server
```

The server starts at `http://localhost:8000`. The agent card is available at:
- `GET /.well-known/agent-card.json`

The card URL field is sourced from `AGENT_PUBLIC_BASE_URL` (defaults to `http://localhost:8000`), so cloud deployments can advertise the public HTTPS endpoint.
For Copilot Studio browser-based discovery, CORS allows `https://copilotstudio.microsoft.com` and `https://copilotstudio.preview.microsoft.com` by default (override with `CORS_ALLOW_ORIGINS`).

### Run the CLI client

The client supports **LLM-based intent detection** via Azure OpenAI so users can type natural language instead of structured commands. Configure it by copying the example `.env`:

```bash
cp client/.env.example client/.env
```

Edit `client/.env` with your Azure OpenAI settings:

```env
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com
AZURE_OPENAI_MODEL=gpt-4o-mini
AZURE_OPENAI_API_VERSION=2024-12-01-preview
A2A_AGENT_URL=http://localhost:8000
# For Azure EasyAuth-protected endpoint:
# A2A_AGENT_API_APP_ID=<api app id>
# A2A_AGENT_CLIENT_APP_ID=<client app id>
# AZURE_TENANT_ID=<tenant id>
```

Client auth behavior:
- **Local server (`localhost`)**: no token is sent
- **Azure EasyAuth endpoint**: token is acquired via Entra ID (`InteractiveBrowserCredential`) when `A2A_AGENT_API_APP_ID` is set

> **Without `.env`**: intent detection is disabled and messages are sent as-is (keyword matching still works).

In a second terminal:

```bash
uv run python -m client
```

Or connect to a remote agent:

```bash
uv run python -m client http://your-agent-url:8000
```

### Test with curl

```bash
# Get agent card
curl http://localhost:8000/.well-known/agent-card.json

# Send a message
curl -X POST http://localhost:8000/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"generate a uuid"}],"messageId":"test-1"}}}'
```

## Deploy to Azure

This project uses [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/) for one-command provisioning and deployment. The container image is built remotely by Azure Container Registry (no local Docker required).

### Prerequisites

- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) installed
- An Azure subscription

### Deploy

```bash
azd auth login
azd up
```

`azd up` will:
1. **Provision** all Azure resources (Resource Group, ACR, Container Apps Environment, Log Analytics, App Insights, Container App)
2. **Configure authentication** (two Entra app registrations: API app + client app, EasyAuth on Container App)
3. **Store auth outputs** in `.azure/<env>/.env` (`ENTRA_API_APP_CLIENT_ID`, `ENTRA_CLIENT_APP_CLIENT_ID`, `AZURE_TENANT_ID`)
4. **Build** the Docker image remotely via ACR Tasks
5. **Deploy** the container app with the built image

### What gets created

| Resource | SKU | Purpose | Cost |
|----------|-----|---------|------|
| Resource Group | — | Container for all resources | Free |
| Log Analytics Workspace | Pay-per-GB | Required by Container Apps Environment | ~$0 at demo volume |
| Application Insights | — | Observability (traces, requests, errors) | Free tier |
| Container Registry | Basic | Stores Docker images (ACR build) | ~$5/month |
| Container Apps Environment | Consumption | Hosting runtime | Free (scales to zero) |
| Container App | 0.25 vCPU / 0.5 Gi | The A2A agent (0→1 replicas) | Free at demo volume |

### Observability

The agent sends OpenTelemetry events to Application Insights automatically. After deploying, open the Application Insights resource in Azure Portal to see:
- **Live Metrics** — real-time request stream
- **Transaction search** — individual A2A requests
- **Application Map** — dependency visualization

### Publish via APIM

1. Import the Container App endpoint into API Management
2. Set the backend URL to the Container App's FQDN
3. Add an API operation for `POST /` (JSON-RPC endpoint)
4. Add an API operation for `GET /.well-known/agent-card.json` (agent discovery)

## EasyAuth + Client configuration

After `azd up`, copy these values from `.azure/<env>/.env` into `client/.env`:
- `A2A_AGENT_URL=$SERVICE_AGENT_URI`
- `A2A_AGENT_API_APP_ID=$ENTRA_API_APP_CLIENT_ID`
- `A2A_AGENT_CLIENT_APP_ID=$ENTRA_CLIENT_APP_CLIENT_ID`
- `AZURE_TENANT_ID=$AZURE_TENANT_ID`

> `ENTRA_APP_CLIENT_ID` is kept for backward compatibility; prefer `ENTRA_API_APP_CLIENT_ID`.
>
> EasyAuth is configured to keep the JSON-RPC endpoint protected while allowing anonymous access to `GET /.well-known/agent-card.json` for agent discovery tools (for example Copilot Studio).

### Copilot Studio Agent2Agent OAuth form

Use the helper script to create/update a dedicated Copilot Studio client app registration and print copy/paste values for the OAuth form:

```bash
./copilot-studio-config.sh --env <your-azd-env>
```

When Copilot Studio shows the generated Redirect URL, run:

```bash
./copilot-studio-config.sh --env <your-azd-env> --redirect-uri "<redirect-url>" --skip-secret-reset
```

### Tear down

```bash
azd down
```

## Cost

- **Azure Container Apps (Consumption):** Scales to zero — free when idle. Free tier: 2M requests/month, 180K vCPU-seconds.
- **No LLM/AI service costs** — all logic is pure Python.
- **APIM (Consumption tier):** First 1M calls/month free.

## Project Structure

```
├── azure.yaml           # azd project definition
├── pyproject.toml       # Project config & dependencies
├── infra/
│   ├── main.bicep       # Azure resources (AVM modules)
│   ├── main.parameters.json
│   ├── abbreviations.json
│   └── scripts/         # postprovision hooks (Entra apps, EasyAuth, ACR build/deploy)
├── server/
│   ├── __main__.py      # Server entry point (uvicorn + OpenTelemetry)
│   ├── agent.py         # AgentExecutor implementation
│   └── skills.py        # Skill functions & routing
├── client/
│   ├── __main__.py      # Interactive CLI client
│   ├── intent.py        # Azure OpenAI intent detection
│   ├── .env.example     # Example configuration
│   └── .env             # Your local config (git-ignored)
├── Dockerfile           # Container image (built by ACR)
└── README.md
```
