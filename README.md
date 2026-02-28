# MCP Text Utilities Server

A lightweight [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server providing text utility tools. Designed for Azure deployment with minimal cost — no LLM calls, pure Python.

## Table of Contents

- [MCP Text Utilities Server](#mcp-text-utilities-server)
  - [Table of Contents](#table-of-contents)
  - [Quick Setup](#quick-setup)
    - [Prerequisites](#prerequisites)
    - [Install dependencies](#install-dependencies)
  - [Run locally (stdio)](#run-locally-stdio)
    - [Test locally using MCP Inspector (stdio)](#test-locally-using-mcp-inspector-stdio)
  - [Run locally (SSE) without auth](#run-locally-sse-without-auth)
    - [Test locally using MCP Inspector (SSE without auth)](#test-locally-using-mcp-inspector-sse-without-auth)
    - [Test locally using curl (SSE without auth)](#test-locally-using-curl-sse-without-auth)
  - [Deploy to Azure](#deploy-to-azure)
    - [Prerequisites](#prerequisites-1)
    - [Deploy](#deploy)
    - [What gets created](#what-gets-created)
  - [Run remotely in Azure (SSE) with EasyAuth](#run-remotely-in-azure-sse-with-easyauth)
    - [Test from local machine using curl (Azure EasyAuth)](#test-from-local-machine-using-curl-azure-easyauth)
    - [Test from local machine using MCP Inspector (Azure EasyAuth)](#test-from-local-machine-using-mcp-inspector-azure-easyauth)
  - [Run remotely in Azure (SSE) with EasyAuth and behind APIM (using subscription key)](#run-remotely-in-azure-sse-with-easyauth-and-behind-apim-using-subscription-key)
    - [Test from local machine using curl (Azure EasyAuth + APIM subscription key)](#test-from-local-machine-using-curl-azure-easyauth--apim-subscription-key)
    - [Test from local machine using MCP Inspector (Azure EasyAuth + APIM subscription key)](#test-from-local-machine-using-mcp-inspector-azure-easyauth--apim-subscription-key)
  - [Configure MCP clients (Claude and VS Code)](#configure-mcp-clients-claude-and-vs-code)
    - [Local stdio configuration](#local-stdio-configuration)
    - [Remote Azure SSE configuration (EasyAuth)](#remote-azure-sse-configuration-easyauth)
  - [Tools](#tools)
  - [Environment Variables](#environment-variables)
  - [Project Structure](#project-structure)
  - [Cost](#cost)
  - [Observability](#observability)
  - [Tear down](#tear-down)

## Quick Setup

### Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) package manager

### Install dependencies

```bash
uv sync
```

## Run locally (stdio)

The default transport is `stdio`, which is the standard way to connect MCP clients (Claude Desktop, VS Code Copilot, Cursor, etc.) to the server.

```bash
uv run python -m server
```

The server reads JSON-RPC messages from stdin and writes responses to stdout.

### Test locally using MCP Inspector (stdio)

The [MCP Inspector](https://github.com/modelcontextprotocol/inspector) is useful for interactively testing server capabilities, tools, and requests.

Start Inspector with either command:

```bash
npx @modelcontextprotocol/inspector

# Alternative if installed globally
mcp-inspector
```

By default, Inspector opens a local web UI (usually `http://127.0.0.1:6274`).

1. Start the server in stdio mode:

```bash
uv run python -m server
```

2. In MCP Inspector, choose transport `stdio`.
3. Set command to `uv`.
4. Set args to:

```text
run --project /path/to/mcp-text-util-demo python -m server
```

5. Click **Connect**, then run `tools/list` and invoke tools such as `generate_uuid` or `hash_text`.

## Run locally (SSE) without auth

For remote or containerized deployments, use the SSE (Server-Sent Events) HTTP transport:

```bash
MCP_TRANSPORT=sse uv run python -m server
```

The server starts at `http://localhost:8000` with:
- `GET /sse` — SSE connection endpoint (MCP clients connect here)
- `POST /messages/` — message posting endpoint

Override host/port via environment variables:

```bash
HOST=0.0.0.0 PORT=8000 MCP_TRANSPORT=sse uv run python -m server
```

### Test locally using MCP Inspector (SSE without auth)

1. Start this server in SSE mode:

```bash
MCP_TRANSPORT=sse uv run python -m server
```

2. In MCP Inspector, choose transport `sse`.
3. Set URL to:

```text
http://localhost:8000/sse
```

4. For non-protected endpoints, click **Connect**.

### Test locally using curl (SSE without auth)

```bash
# Connect to SSE endpoint (keep this open in one terminal)
curl -N http://localhost:8000/sse

# In the response you'll see: event: endpoint / data: /messages/?session_id=<id>
# Use that session_id to send a tools/list request
curl -X POST "http://localhost:8000/messages/?session_id=<id>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
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
5. **Deploy** the container app with `MCP_TRANSPORT=sse` for HTTP access

### What gets created

| Resource | SKU | Purpose | Cost |
|----------|-----|---------|------|
| Resource Group | — | Container for all resources | Free |
| Log Analytics Workspace | Pay-per-GB | Required by Container Apps Environment | ~$0 at demo volume |
| Application Insights | — | Observability (traces, requests, errors) | Free tier |
| Container Registry | Basic | Stores Docker images (ACR build) | ~$5/month |
| Container Apps Environment | Consumption | Hosting runtime | Free (scales to zero) |
| Container App | 0.25 vCPU / 0.5 Gi | The MCP server (0→1 replicas) | Free at demo volume |

## Run remotely in Azure (SSE) with EasyAuth

After `azd up`, the `SERVICE_AGENT_URI` output contains the public URL (e.g. `https://ca-agent-xxxx.azurecontainerapps.io`).

### Test from local machine using curl (Azure EasyAuth)

When deployed to Azure with EasyAuth enabled, anonymous requests are rejected.

```bash
# Expect HTTP/2 401 without a bearer token
curl -i -N "https://<your-container-app-domain>/sse"
```

Acquire and export a token with device flow:

```bash
AZD_ENV_FILE=".azure/mcp-text-util-demo/.env"
set -a
source "$AZD_ENV_FILE"
set +a

export TOKEN="$(
uv run python - <<'PY'
import os
import sys
import msal

tenant_id = os.environ["AZURE_TENANT_ID"]
client_id = os.environ["ENTRA_CLIENT_APP_CLIENT_ID"]
scopes = [f"api://{os.environ['ENTRA_API_APP_CLIENT_ID']}/access_as_user"]

app = msal.PublicClientApplication(
    client_id,
    authority=f"https://login.microsoftonline.com/{tenant_id}",
)
accounts = app.get_accounts()
result = app.acquire_token_silent(scopes, account=accounts[0]) if accounts else None

if not result:
  flow = app.initiate_device_flow(scopes=scopes)
  print(flow["message"], file=sys.stderr, flush=True)
  result = app.acquire_token_by_device_flow(flow)

if "access_token" not in result:
  print(result, file=sys.stderr)
  raise SystemExit(1)

print(result["access_token"], end="")
PY
 )"

echo "TOKEN set (${#TOKEN} chars)"
```

Use that token to connect to SSE:

```bash
curl -i -N \
  -H "Authorization: Bearer $TOKEN" \
  "$SERVICE_AGENT_URI/sse"
```

Expected success output starts with:

```text
HTTP/2 200
event: endpoint
data: /messages/?session_id=<id>
```

Token formatting requirements:
- Value must be exactly `Bearer eyJ...`
- Single line only
- No quotes around the token value
- No trailing `%`

### Test from local machine using MCP Inspector (Azure EasyAuth)

Use these exact settings when connecting to the deployed Azure Container App.

1. Start Inspector:

```bash
mcp-inspector
```

Open the exact URL printed by Inspector (it includes `?MCP_PROXY_AUTH_TOKEN=...`).

2. In Inspector set:
- `Transport Type`: `SSE`
- `Connection Type`: `Via Proxy`
- `URL`: `https://<your-container-app-domain>/sse`

3. Under `Authentication` -> `Custom Headers`, enable a single header:

```text
Authorization: Bearer eyJ...
```

Header value requirements:
- Single line only
- No surrounding quotes
- No trailing `%`

4. Leave `OAuth 2.0 Flow` fields empty (`Client ID`, `Scope`, etc.).

5. Click **Connect**, then test `tools/list` and tool calls from the Inspector UI.

## Run remotely in Azure (SSE) with EasyAuth and behind APIM (using subscription key)

When APIM fronts your Container App, use the APIM endpoint instead of the direct Container App URL.

Set these variables:

```bash
# Example: https://<apim-name>.azure-api.net/mcp-text-util-demo
export APIM_MCP_BASE_URL="https://<apim-name>.azure-api.net/<mcp-api-suffix>"

# APIM subscription key (APIM -> Subscriptions)
export APIM_SUBSCRIPTION_KEY="<your-subscription-key>"

# If your APIM API suffix maps to app root
export APIM_SSE_URL="$APIM_MCP_BASE_URL"
```

### Test from local machine using curl (Azure EasyAuth + APIM subscription key)

For secured APIM + EasyAuth, send both headers:
- `Authorization: Bearer <token>`
- `Ocp-Apim-Subscription-Key: <key>`

1. Validate that keyless access is blocked (expected `401` or `403` when subscription is required):

```bash
curl -i -N \
  -H "Authorization: Bearer $TOKEN" \
  "$APIM_SSE_URL"
```

2. Connect with bearer token + subscription key:

```bash
curl -i -N \
  -H "Authorization: Bearer $TOKEN" \
  -H "Ocp-Apim-Subscription-Key: $APIM_SUBSCRIPTION_KEY" \
  "$APIM_SSE_URL"
```

Expected success output starts with:

```text
HTTP/2 200
event: endpoint
data: /messages/?session_id=<id>
```

3. Use the returned `session_id` to call `tools/list` via APIM:

```bash
curl -X POST "$APIM_MCP_BASE_URL/messages/?session_id=<id>" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Ocp-Apim-Subscription-Key: $APIM_SUBSCRIPTION_KEY" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

### Test from local machine using MCP Inspector (Azure EasyAuth + APIM subscription key)

1. Start Inspector:

```bash
mcp-inspector
```

2. In Inspector set:
- `Transport Type`: `SSE`
- `Connection Type`: `Via Proxy`
- `URL`: `$APIM_SSE_URL`

3. Under `Authentication` -> `Custom Headers`, add:

```text
Authorization: Bearer eyJ...
Ocp-Apim-Subscription-Key: <your-subscription-key>
```

4. Click **Connect**, then run `tools/list` and invoke tools.

Notes:
- If APIM `Subscription required` is disabled, you can omit `Ocp-Apim-Subscription-Key`.
- If you get `401/403`, verify the API is attached to the expected Product and the key belongs to a valid subscription scope.

## Configure MCP clients (Claude and VS Code)

### Local stdio configuration

**Claude Desktop** — add to `~/.config/claude/claude_desktop_config.json` (macOS/Linux) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "text-utilities": {
      "command": "uv",
      "args": ["run", "--project", "/path/to/mcp-text-util-demo", "python", "-m", "server"]
    }
  }
}
```

**VS Code** — add to `.vscode/mcp.json` in your workspace:

```json
{
  "servers": {
    "text-utilities": {
      "type": "stdio",
      "command": "uv",
      "args": ["run", "--project", "/path/to/mcp-text-util-demo", "python", "-m", "server"]
    }
  }
}
```

### Remote Azure SSE configuration (EasyAuth)

**VS Code** — add to `.vscode/mcp.json`:

```json
{
  "servers": {
    "text-utilities-azure": {
      "type": "sse",
      "url": "https://ca-agent-xxxx.azurecontainerapps.io/sse",
      "headers": {
        "Authorization": "Bearer <token>"
      }
    }
  }
}
```

To acquire a token for the EasyAuth-protected endpoint in this project, use the generated Entra client app and API scope (`access_as_user`):

```bash
AZD_ENV_FILE=".azure/mcp-text-util-demo/.env"
set -a
source "$AZD_ENV_FILE"
set +a

export TOKEN="$(
uv run python - <<'PY'
import os
import sys
import msal

tenant_id = os.environ["AZURE_TENANT_ID"]
client_id = os.environ["ENTRA_CLIENT_APP_CLIENT_ID"]
scopes = [f"api://{os.environ['ENTRA_API_APP_CLIENT_ID']}/access_as_user"]

app = msal.PublicClientApplication(
  client_id,
  authority=f"https://login.microsoftonline.com/{tenant_id}",
)
accounts = app.get_accounts()
result = app.acquire_token_silent(scopes, account=accounts[0]) if accounts else None

if not result:
  flow = app.initiate_device_flow(scopes=scopes)
  print(flow["message"], file=sys.stderr, flush=True)
  result = app.acquire_token_by_device_flow(flow)

if "access_token" not in result:
  print(result, file=sys.stderr)
  raise SystemExit(1)

print(result["access_token"], end="")
PY
 )"

echo "TOKEN set (${#TOKEN} chars)"
```

Then paste it in Inspector as:

```text
Authorization: Bearer eyJ...
```

## Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| **generate_uuid** | Generates a new UUID v4 | _(none)_ |
| **hash_text** | SHA-256 hash of text | `text: str` |
| **base64_encode** | Base64-encode text | `text: str` |
| **base64_decode** | Base64-decode text | `text: str` |
| **word_count** | Count words & characters | `text: str` |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_TRANSPORT` | `stdio` | Transport mode: `stdio` (local) or `sse` (HTTP) |
| `HOST` | `0.0.0.0` | Bind host (HTTP mode only) |
| `PORT` | `8000` | Bind port (HTTP mode only) |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | _(unset)_ | Enables Azure Monitor telemetry |

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
│   ├── __main__.py      # MCP server entry point (FastMCP + OpenTelemetry)
│   └── skills.py        # Tool implementation functions
├── Dockerfile           # Container image (built by ACR)
└── README.md
```

## Cost

- **Azure Container Apps (Consumption):** Scales to zero — free when idle. Free tier: 2M requests/month, 180K vCPU-seconds.
- **No LLM/AI service costs** — all logic is pure Python.

## Observability

The server sends OpenTelemetry events to Application Insights automatically when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set (injected by the Container App environment). After deploying, open the Application Insights resource in Azure Portal to see:
- **Live Metrics** — real-time request stream
- **Transaction search** — individual MCP requests
- **Application Map** — dependency visualization

## Tear down

```bash
azd down
```
