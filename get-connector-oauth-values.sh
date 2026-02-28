#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./get-connector-oauth-values.sh \
#     --connector-app-name "Text Utilities Copilot Connector" \
#     [--env-file ".azure/<env>/.env"] \
#     [--tenant-id "<tenant-guid>"] \
#     [--api-app-client-id "<api-app-client-id-guid>"] \
#     [--redirect-uri "<redirect-uri-from-connector-ui>"] \
#     [--secret-years 2]
#
# Notes:
# - Requires az CLI login and permissions to create app registrations.
# - If --redirect-uri is omitted, add it after first Save in connector UI.

CONNECTOR_APP_NAME=""
ENV_FILE=""
TENANT_ID=""
API_APP_CLIENT_ID=""
REDIRECT_URI=""
SECRET_YEARS="2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --connector-app-name) CONNECTOR_APP_NAME="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --tenant-id) TENANT_ID="$2"; shift 2 ;;
    --api-app-client-id) API_APP_CLIENT_ID="$2"; shift 2 ;;
    --redirect-uri) REDIRECT_URI="$2"; shift 2 ;;
    --secret-years) SECRET_YEARS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$CONNECTOR_APP_NAME" ]]; then
  echo "Missing required: --connector-app-name" >&2
  exit 1
fi

# Auto-discover azd env file if not explicitly provided.
if [[ -z "$ENV_FILE" ]]; then
  CANDIDATE="$(ls -1 .azure/*/.env 2>/dev/null | head -n1 || true)"
  if [[ -n "$CANDIDATE" ]]; then
    ENV_FILE="$CANDIDATE"
  fi
fi

if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

TENANT_ID="${TENANT_ID:-${AZURE_TENANT_ID:-}}"
API_APP_CLIENT_ID="${API_APP_CLIENT_ID:-${ENTRA_API_APP_CLIENT_ID:-}}"

if [[ -z "$TENANT_ID" || -z "$API_APP_CLIENT_ID" ]]; then
  cat >&2 <<EOF
Could not resolve tenant/api app IDs.
Provide one of:
  --env-file .azure/<env>/.env
or explicitly:
  --tenant-id <guid> --api-app-client-id <guid>
EOF
  exit 1
fi

az account show >/dev/null 2>&1 || {
  echo "Not logged in. Run: az login" >&2
  exit 1
}

CONNECTOR_CLIENT_ID="$(az ad app list --display-name "$CONNECTOR_APP_NAME" --query "[0].appId" -o tsv || true)"

if [[ -z "$CONNECTOR_CLIENT_ID" ]]; then
  CONNECTOR_CLIENT_ID="$(az ad app create \
    --display-name "$CONNECTOR_APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)"
fi

# Persist connector app ID in azd env so postprovision.sh includes it in EasyAuth.
if command -v azd >/dev/null 2>&1; then
  azd env set ENTRA_CONNECTOR_APP_CLIENT_ID "$CONNECTOR_CLIENT_ID" 2>/dev/null || true
fi

if [[ -n "$REDIRECT_URI" ]]; then
  # Preserve existing web redirect URIs and append the new one if needed.
  EXISTING_REDIRECT_URIS="$(az ad app show --id "$CONNECTOR_CLIENT_ID" --query "web.redirectUris" -o tsv 2>/dev/null || true)"

  REDIRECT_URI_ARGS=()
  if [[ -n "$EXISTING_REDIRECT_URIS" ]]; then
    while IFS= read -r uri; do
      [[ -n "$uri" ]] && REDIRECT_URI_ARGS+=("$uri")
    done <<< "$EXISTING_REDIRECT_URIS"
  fi

  URI_ALREADY_PRESENT="false"
  for uri in "${REDIRECT_URI_ARGS[@]:-}"; do
    if [[ "$uri" == "$REDIRECT_URI" ]]; then
      URI_ALREADY_PRESENT="true"
      break
    fi
  done

  if [[ "$URI_ALREADY_PRESENT" != "true" ]]; then
    REDIRECT_URI_ARGS+=("$REDIRECT_URI")
  fi

  az ad app update --id "$CONNECTOR_CLIENT_ID" --web-redirect-uris "${REDIRECT_URI_ARGS[@]}" >/dev/null
fi

# Entra does not allow reading existing secret values; create a new one.
CONNECTOR_CLIENT_SECRET="$(az ad app credential reset \
  --id "$CONNECTOR_CLIENT_ID" \
  --append \
  --display-name "copilot-studio-connector" \
  --years "$SECRET_YEARS" \
  --query password -o tsv)"

SCOPE_ID="$(az ad app show --id "$API_APP_CLIENT_ID" \
  --query "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]" -o tsv)"

if [[ -z "$SCOPE_ID" || "$SCOPE_ID" == "None" ]]; then
  echo "Could not find scope 'access_as_user' on API app $API_APP_CLIENT_ID" >&2
  exit 1
fi

az ad app permission add \
  --id "$CONNECTOR_CLIENT_ID" \
  --api "$API_APP_CLIENT_ID" \
  --api-permissions "${SCOPE_ID}=Scope" >/dev/null 2>&1 || true

if ! az ad app permission admin-consent --id "$CONNECTOR_CLIENT_ID" >/dev/null 2>&1; then
  ADMIN_CONSENT_STATUS="FAILED_OR_REQUIRES_ADMIN"
else
  ADMIN_CONSENT_STATUS="GRANTED"
fi

AUTH_URL="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/authorize"
TOKEN_URL="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"
REFRESH_URL="$TOKEN_URL"
SCOPE="api://${API_APP_CLIENT_ID}/access_as_user"

cat <<EOF
Populate your Copilot Studio connector form with:

Identity Provider: Generic OAuth 2
Client ID:         ${CONNECTOR_CLIENT_ID}
Client secret:     ${CONNECTOR_CLIENT_SECRET}
Authorization URL: ${AUTH_URL}
Token URL:         ${TOKEN_URL}
Refresh URL:       ${REFRESH_URL}
Scope:             ${SCOPE}

Extra info:
Tenant ID:         ${TENANT_ID}
API App Client ID: ${API_APP_CLIENT_ID}
Admin consent:     ${ADMIN_CONSENT_STATUS}

Reminder:
- In connector UI, click Save once to generate Redirect URL.
- If you did not pass --redirect-uri, rerun this script with:
  --redirect-uri "<that generated redirect URL>"
EOF