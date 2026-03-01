#!/usr/bin/env bash
set -euo pipefail

# Deploy APIM MCP API for an existing MCP backend.
#
# Usage:
#   ./apim/deploy-apim-mcp.sh \
#     --apim-service-name <apim-name> \
#     --resource-group <resource-group> \
#     [--env-file .azure/<env>/.env] \
#     [--mcp-backend-url https://<container-app>/mcp] \
#     [--mcp-path text-utils] \
#     [--tenant-id <tenant-guid>] \
#     [--api-app-client-id <app-guid>] \
#     [--deployment-name mcp-apim]

APIM_SERVICE_NAME=""
RESOURCE_GROUP=""
ENV_FILE=""
MCP_BACKEND_URL=""
MCP_PATH="text-utils"
TENANT_ID=""
API_APP_CLIENT_ID=""
DEPLOYMENT_NAME="mcp-apim"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Deploy APIM MCP API for this project.

Required:
  --apim-service-name    Existing API Management service name.
  --resource-group       Resource group containing APIM.

Optional:
  --env-file             Path to .env (defaults to first .azure/*/.env).
  --mcp-backend-url      Full backend MCP URL (defaults to SERVICE_AGENT_URI + /mcp from env).
  --mcp-path             APIM path segment (default: text-utils).
  --tenant-id            Entra tenant ID (defaults to AZURE_TENANT_ID from env).
  --api-app-client-id    API app client ID (defaults to ENTRA_API_APP_CLIENT_ID from env).
  --deployment-name      ARM deployment name (default: mcp-apim).

Example:
  ./apim/deploy-apim-mcp.sh \
    --apim-service-name apim-demo \
    --resource-group rg-demo
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apim-service-name)
      APIM_SERVICE_NAME="$2"
      shift 2
      ;;
    --resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --mcp-backend-url)
      MCP_BACKEND_URL="$2"
      shift 2
      ;;
    --mcp-path)
      MCP_PATH="$2"
      shift 2
      ;;
    --tenant-id)
      TENANT_ID="$2"
      shift 2
      ;;
    --api-app-client-id)
      API_APP_CLIENT_ID="$2"
      shift 2
      ;;
    --deployment-name)
      DEPLOYMENT_NAME="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ENV_FILE" ]]; then
  ENV_FILE="$(ls -1 "$REPO_ROOT"/.azure/*/.env 2>/dev/null | head -n1 || true)"
fi

if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

TENANT_ID="${TENANT_ID:-${AZURE_TENANT_ID:-}}"
API_APP_CLIENT_ID="${API_APP_CLIENT_ID:-${ENTRA_API_APP_CLIENT_ID:-}}"

if [[ -z "$MCP_BACKEND_URL" ]]; then
  SERVICE_AGENT_URI="${SERVICE_AGENT_URI:-}"
  if [[ -n "$SERVICE_AGENT_URI" ]]; then
    MCP_BACKEND_URL="${SERVICE_AGENT_URI%/}/mcp"
  fi
fi

if [[ -z "$APIM_SERVICE_NAME" ]]; then
  echo "Missing required argument: --apim-service-name" >&2
  exit 1
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Missing required argument: --resource-group" >&2
  exit 1
fi

if [[ -z "$MCP_BACKEND_URL" ]]; then
  echo "Could not resolve MCP backend URL. Provide --mcp-backend-url or set SERVICE_AGENT_URI in env." >&2
  exit 1
fi

if [[ -z "$TENANT_ID" ]]; then
  echo "Could not resolve tenant ID. Provide --tenant-id or set AZURE_TENANT_ID in env." >&2
  exit 1
fi

if [[ -z "$API_APP_CLIENT_ID" ]]; then
  echo "Could not resolve API app client ID. Provide --api-app-client-id or set ENTRA_API_APP_CLIENT_ID in env." >&2
  exit 1
fi

az account show >/dev/null 2>&1 || {
  echo "Not logged in. Run: az login" >&2
  exit 1
}

BICEP_FILE="$SCRIPT_DIR/mcp-api.bicep"

if [[ ! -f "$BICEP_FILE" ]]; then
  echo "Cannot find Bicep file: $BICEP_FILE" >&2
  exit 1
fi

echo "Deploying APIM MCP API..."
echo "  APIM service:      $APIM_SERVICE_NAME"
echo "  Resource group:    $RESOURCE_GROUP"
echo "  Backend URL:       $MCP_BACKEND_URL"
echo "  APIM path:         $MCP_PATH"
echo "  Tenant ID:         $TENANT_ID"
echo "  API app client ID: $API_APP_CLIENT_ID"

az deployment group create \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$BICEP_FILE" \
  --parameters apimServiceName="$APIM_SERVICE_NAME" \
  --parameters mcpBackendUrl="$MCP_BACKEND_URL" \
  --parameters mcpPath="$MCP_PATH" \
  --parameters tenantId="$TENANT_ID" \
  --parameters apiAppClientId="$API_APP_CLIENT_ID" \
  -o table

echo "Deployment completed."
