#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./copilot-studio-config.sh [options]

Creates/updates a Copilot Studio OAuth client app and prints values for the
"Connect Agent2Agent" OAuth 2.0 form.

Options:
  --env <name>                Azure Developer CLI environment name (uses .azure/<name>/.env)
  --app-name <name>           Entra app display name for Copilot Studio client
  --redirect-uri <uri>        Redirect URI to add/update on the Copilot Studio app
  --skip-secret-reset         Do not rotate/create a new client secret
  -h, --help                  Show help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

ENV_NAME="${AZURE_ENV_NAME:-}"
COPILOT_APP_NAME=""
REDIRECT_URI=""
SKIP_SECRET_RESET="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_NAME="${2:-}"
      shift 2
      ;;
    --app-name)
      COPILOT_APP_NAME="${2:-}"
      shift 2
      ;;
    --redirect-uri)
      REDIRECT_URI="${2:-}"
      shift 2
      ;;
    --skip-secret-reset)
      SKIP_SECRET_RESET="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required." >&2
  exit 1
fi

if [[ -z "${ENV_NAME}" ]]; then
  FIRST_ENV_FILE="$(find "${REPO_ROOT}/.azure" -mindepth 2 -maxdepth 2 -name ".env" | head -n 1 || true)"
  if [[ -n "${FIRST_ENV_FILE}" ]]; then
    ENV_NAME="$(basename "$(dirname "${FIRST_ENV_FILE}")")"
  fi
fi

if [[ -n "${ENV_NAME}" ]]; then
  ENV_FILE="${REPO_ROOT}/.azure/${ENV_NAME}/.env"
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
  fi
fi

API_APP_ID="${ENTRA_API_APP_CLIENT_ID:-${ENTRA_APP_CLIENT_ID:-}}"
TENANT_ID="${AZURE_TENANT_ID:-}"

if [[ -z "${TENANT_ID}" ]]; then
  TENANT_ID="$(az account show --query tenantId -o tsv)"
fi

if [[ -z "${API_APP_ID}" ]]; then
  echo "Missing API app ID. Run 'azd up' first, or set ENTRA_API_APP_CLIENT_ID." >&2
  exit 1
fi

if [[ -z "${COPILOT_APP_NAME}" ]]; then
  SUFFIX="${ENV_NAME:-local}"
  COPILOT_APP_NAME="a2a-text-utilities-copilotstudio-${SUFFIX}"
fi

COPILOT_APP_ID="$(az ad app list --display-name "${COPILOT_APP_NAME}" --query "[0].appId" -o tsv 2>/dev/null || true)"
if [[ -z "${COPILOT_APP_ID}" ]]; then
  COPILOT_APP_ID="$(az ad app create --display-name "${COPILOT_APP_NAME}" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
fi

DEFAULT_REDIRECT_URI="https://localhost/auth/callback"
if [[ -n "${REDIRECT_URI}" ]]; then
  az ad app update --id "${COPILOT_APP_ID}" --web-redirect-uris "${REDIRECT_URI}" >/dev/null
else
  EXISTING_REDIRECTS="$(az ad app show --id "${COPILOT_APP_ID}" --query "web.redirectUris" -o tsv 2>/dev/null || true)"
  if [[ -z "${EXISTING_REDIRECTS}" ]]; then
    az ad app update --id "${COPILOT_APP_ID}" --web-redirect-uris "${DEFAULT_REDIRECT_URI}" >/dev/null
  fi
fi

SCOPE_ID="$(az ad app show --id "${API_APP_ID}" --query "api.oauth2PermissionScopes[?value=='access_as_user'] | [0].id" -o tsv)"
if [[ -z "${SCOPE_ID}" ]]; then
  echo "API app '${API_APP_ID}' does not expose scope 'access_as_user'. Run azd postprovision first." >&2
  exit 1
fi

az ad sp create --id "${API_APP_ID}" >/dev/null 2>&1 || true
az ad sp create --id "${COPILOT_APP_ID}" >/dev/null 2>&1 || true
az ad app permission add --id "${COPILOT_APP_ID}" --api "${API_APP_ID}" --api-permissions "${SCOPE_ID}=Scope" >/dev/null 2>&1 || true
az ad app permission grant --id "${COPILOT_APP_ID}" --api "${API_APP_ID}" --scope "access_as_user" >/dev/null 2>&1 || true

CLIENT_SECRET=""
if [[ "${SKIP_SECRET_RESET}" == "false" ]]; then
  CLIENT_SECRET="$(az ad app credential reset --id "${COPILOT_APP_ID}" --append --display-name "copilot-studio-$(date +%Y%m%d%H%M%S)" --years 1 --query password -o tsv)"
fi

AUTH_URL="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/authorize"
TOKEN_URL="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"
SCOPES="api://${API_APP_ID}/access_as_user offline_access openid profile"

echo
echo "Copilot Studio OAuth form values"
echo "================================"
echo "Authentication: OAuth 2.0"
echo "Client ID: ${COPILOT_APP_ID}"
if [[ -n "${CLIENT_SECRET}" ]]; then
  echo "Client secret: ${CLIENT_SECRET}"
else
  echo "Client secret: <not rotated; existing secret remains>"
fi
echo "Authorization URL: ${AUTH_URL}"
echo "Token URL template: ${TOKEN_URL}"
echo "Refresh URL: ${TOKEN_URL}"
echo "Scopes: ${SCOPES}"
echo
echo "Tenant ID: ${TENANT_ID}"
echo "API App ID (resource): ${API_APP_ID}"
echo "Copilot Studio App Name: ${COPILOT_APP_NAME}"
echo
echo "After Copilot Studio generates Redirect URL, update app with:"
echo "./copilot-studio-config.sh --env ${ENV_NAME:-<your-env>} --redirect-uri '<PASTE_REDIRECT_URL>' --skip-secret-reset"
