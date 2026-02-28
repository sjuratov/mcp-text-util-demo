# MCP Text Utilities Server

A lightweight [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server providing text utility tools. Designed for Azure deployment with minimal cost — no LLM calls, pure Python.

## Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| **generate_uuid** | Generates a new UUID v4 | _(none)_ |
| **hash_text** | SHA-256 hash of text | `text: str` |
| **base64_encode** | Base64-encode text | `text: str` |
| **base64_decode** | Base64-decode text | `text: str` |
| **word_count** | Count words & characters | `text: str` |

## Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) package manager

## Quick Start

### Install dependencies

```bash
uv sync
```

### Run locally (stdio transport)

The default transport is `stdio`, which is the standard way to connect MCP clients (Claude Desktop, VS Code Copilot, Cursor, etc.) to the server.

```bash
uv run python -m server
```

The server reads JSON-RPC messages from stdin and writes responses to stdout.

### Configure an MCP client

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

### Run as HTTP server (SSE transport)

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

### Test with curl

```bash
# Connect to SSE endpoint (keep this open in one terminal)
curl -N http://localhost:8000/sse

# In the response you'll see: event: endpoint / data: /messages/?session_id=<id>
# Use that session_id to send a tools/list request
curl -X POST "http://localhost:8000/messages/?session_id=<id>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

### Use MCP Inspector (local and remote)

The [MCP Inspector](https://github.com/modelcontextprotocol/inspector) is useful for interactively testing server capabilities, tools, and requests.

Install/run Inspector with `npx`:

```bash
npx @modelcontextprotocol/inspector
```

By default, Inspector opens a local web UI (usually `http://127.0.0.1:6274`).

#### Connect to local server (stdio)

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

#### Connect to remote/local HTTP server (SSE)

1. Start this server in SSE mode (or use your deployed endpoint):

```bash
MCP_TRANSPORT=sse uv run python -m server
```

2. In MCP Inspector, choose transport `sse`.
3. Set URL to:

```text
http://localhost:8000/sse
```

4. If the endpoint is protected (for example Azure EasyAuth), add an `Authorization` header:

```text
Authorization: Bearer <token>
```

5. Click **Connect**, then test `tools/list` and tool calls from the Inspector UI.

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

### Connect a remote MCP client to Azure

After `azd up`, the `SERVICE_AGENT_URI` output contains the public URL (e.g. `https://ca-agent-xxxx.azurecontainerapps.io`).

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

To acquire a token for the EasyAuth-protected endpoint:

```bash
az account get-access-token --resource api://<ENTRA_API_APP_CLIENT_ID> --query accessToken -o tsv
```

### Observability

The server sends OpenTelemetry events to Application Insights automatically when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set (injected by the Container App environment). After deploying, open the Application Insights resource in Azure Portal to see:
- **Live Metrics** — real-time request stream
- **Transaction search** — individual MCP requests
- **Application Map** — dependency visualization

### Tear down

```bash
azd down
```

## Cost

- **Azure Container Apps (Consumption):** Scales to zero — free when idle. Free tier: 2M requests/month, 180K vCPU-seconds.
- **No LLM/AI service costs** — all logic is pure Python.

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
