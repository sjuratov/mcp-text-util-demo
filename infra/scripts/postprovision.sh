#!/usr/bin/env bash
set -euo pipefail

RG="rg-${AZURE_ENV_NAME}"
SUBSCRIPTION_ID=$(az account show --query "id" -o tsv)
TENANT_ID=$(az account show --query "tenantId" -o tsv)
IMAGE_TAG="${AZURE_ENV_NAME}"
IMAGE_NAME="mcp-text-utilities:${IMAGE_TAG}"
API_APP_NAME="mcp-text-utilities-api-${AZURE_ENV_NAME}"
CLIENT_APP_NAME="mcp-text-utilities-client-${AZURE_ENV_NAME}"

echo "Ensuring Entra API app registration: ${API_APP_NAME}"
API_APP_ID=$(az ad app list --display-name "${API_APP_NAME}" --query "[0].appId" -o tsv 2>/dev/null || true)
if [ -z "${API_APP_ID}" ]; then
  API_APP_ID=$(az ad app create --display-name "${API_APP_NAME}" --sign-in-audience AzureADMyOrg --query "appId" -o tsv)
fi
API_OBJECT_ID=$(az ad app show --id "${API_APP_ID}" --query "id" -o tsv)
SCOPE_ID=$(az ad app show --id "${API_APP_ID}" --query "api.oauth2PermissionScopes[?value=='access_as_user'] | [0].id" -o tsv)
if [ -z "${SCOPE_ID}" ]; then
  SCOPE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
fi
az ad app update --id "${API_APP_ID}" --identifier-uris "api://${API_APP_ID}"
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/applications/${API_OBJECT_ID}" \
  --headers "Content-Type=application/json" \
  --body "{\"api\":{\"requestedAccessTokenVersion\":2,\"oauth2PermissionScopes\":[{\"id\":\"${SCOPE_ID}\",\"adminConsentDescription\":\"Access the MCP Text Utilities Server\",\"adminConsentDisplayName\":\"Access MCP Server\",\"userConsentDescription\":\"Allow this app to access the MCP Text Utilities Server on your behalf\",\"userConsentDisplayName\":\"Access MCP Server\",\"isEnabled\":true,\"type\":\"User\",\"value\":\"access_as_user\"}]}}"
az ad sp create --id "${API_APP_ID}" >/dev/null 2>&1 || true

echo "Ensuring Entra client app registration: ${CLIENT_APP_NAME}"
CLIENT_APP_ID=$(az ad app list --display-name "${CLIENT_APP_NAME}" --query "[0].appId" -o tsv 2>/dev/null || true)
if [ -z "${CLIENT_APP_ID}" ]; then
  CLIENT_APP_ID=$(az ad app create --display-name "${CLIENT_APP_NAME}" --sign-in-audience AzureADMyOrg --query "appId" -o tsv)
fi
CLIENT_OBJECT_ID=$(az ad app show --id "${CLIENT_APP_ID}" --query "id" -o tsv)
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/applications/${CLIENT_OBJECT_ID}" \
  --headers "Content-Type=application/json" \
  --body "{\"isFallbackPublicClient\":true,\"publicClient\":{\"redirectUris\":[\"http://localhost\"]},\"requiredResourceAccess\":[{\"resourceAppId\":\"${API_APP_ID}\",\"resourceAccess\":[{\"id\":\"${SCOPE_ID}\",\"type\":\"Scope\"}]}]}"
az ad sp create --id "${CLIENT_APP_ID}" >/dev/null 2>&1 || true
az ad app permission add --id "${CLIENT_APP_ID}" --api "${API_APP_ID}" --api-permissions "${SCOPE_ID}=Scope" >/dev/null 2>&1 || true
az ad app permission grant --id "${CLIENT_APP_ID}" --api "${API_APP_ID}" --scope "access_as_user" >/dev/null 2>&1 || true

azd env set ENTRA_API_APP_CLIENT_ID "${API_APP_ID}"
azd env set ENTRA_CLIENT_APP_CLIENT_ID "${CLIENT_APP_ID}"
azd env set ENTRA_APP_CLIENT_ID "${API_APP_ID}"
azd env set AZURE_TENANT_ID "${TENANT_ID}"

echo "Configuring EasyAuth on container app: ${SERVICE_AGENT_NAME}"
az containerapp auth microsoft update \
  --name "${SERVICE_AGENT_NAME}" \
  --resource-group "${RG}" \
  --client-id "${API_APP_ID}" \
  --issuer "https://login.microsoftonline.com/${TENANT_ID}/v2.0" \
  --allowed-audiences "${API_APP_ID}"
AUTH_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.App/containerApps/${SERVICE_AGENT_NAME}/authConfigs/current?api-version=2024-03-01"
AUTH_BODY=$(cat <<JSON
{"properties":{"platform":{"enabled":true},"globalValidation":{"unauthenticatedClientAction":"Return401"},"identityProviders":{"azureActiveDirectory":{"isAutoProvisioned":false,"registration":{"clientId":"${API_APP_ID}","openIdIssuer":"https://login.microsoftonline.com/${TENANT_ID}/v2.0"},"validation":{"allowedAudiences":["${API_APP_ID}","api://${API_APP_ID}"],"defaultAuthorizationPolicy":{"allowedApplications":["${CLIENT_APP_ID}"]}}}},"login":{"preserveUrlFragmentsForLogins":false},"encryptionSettings":{}}}
JSON
)
az rest --method PUT --url "${AUTH_URL}" --headers "Content-Type=application/json" --body "${AUTH_BODY}" >/dev/null

echo "Building image in ACR: ${AZURE_CONTAINER_REGISTRY_NAME}/${IMAGE_NAME}"
az acr build --registry "${AZURE_CONTAINER_REGISTRY_NAME}" --image "${IMAGE_NAME}" .
echo "Updating container app: ${SERVICE_AGENT_NAME}"
az containerapp update --name "${SERVICE_AGENT_NAME}" --resource-group "${RG}" --image "${AZURE_CONTAINER_REGISTRY_ENDPOINT}/${IMAGE_NAME}"

echo "Done. MCP Server URL: ${SERVICE_AGENT_URI}"
echo "SSE endpoint:         ${SERVICE_AGENT_URI}/sse"
echo "Entra API App ID: ${API_APP_ID}"
echo "Entra Client App ID: ${CLIENT_APP_ID}"
