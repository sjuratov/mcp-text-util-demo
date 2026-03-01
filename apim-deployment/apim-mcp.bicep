// Publishes the MCP Text Utilities server on an existing Azure API Management service.
//
// Resources created:
//   • Three Named Values  (mcp-backend-url, mcp-tenant-id, mcp-app-id)
//   • An HTTP API        (path = apiPath parameter)
//   • Three operations   (POST /mcp, GET /sse, POST /messages/)
//   • An API-level policy (loaded from ./apim-policy.xml)
//
// All parameters except the four required ones have sensible defaults.
//
// Usage (from within the apim-deployment/ directory):
//   az deployment group create \
//     --resource-group <rg> \
//     --template-file apim-mcp.bicep \
//     --parameters apimServiceName=<name> mcpServerUrl=<url> \
//                  tenantId=<tid> entraApiAppClientId=<appid>

targetScope = 'resourceGroup'

// ── Required parameters ──────────────────────────────────────────────────────

@description('Name of the existing Azure API Management service.')
param apimServiceName string

@description('Full HTTPS URL of the deployed MCP Container App (e.g. https://ca-agent-xxxx.azurecontainerapps.io).')
param mcpServerUrl string

@description('Azure AD tenant ID used for JWT validation.')
param tenantId string

@description('Entra API app registration client ID (becomes the JWT audience: api://<id>).')
param entraApiAppClientId string

// ── Optional parameters ───────────────────────────────────────────────────────

@description('Unique API identifier within the APIM service.')
param apiName string = 'mcp-text-utils-demo'

@description('Human-readable display name shown in the developer portal.')
param apiDisplayName string = 'MCP Text Utilities'

@description('URL path suffix for the API (e.g. "mcp-text-utils-demo" → https://<apim>.azure-api.net/mcp-text-utils-demo).')
param apiPath string = 'mcp-text-utils-demo'

@description('Short description shown in the developer portal.')
param apiDescription string = 'MCP Text Utilities Server — text utility tools via the Model Context Protocol.'

@description('When true, callers must supply an Ocp-Apim-Subscription-Key header.')
param subscriptionRequired bool = true

// ── Existing APIM service ─────────────────────────────────────────────────────

resource apim 'Microsoft.ApiManagement/service@2022-08-01' existing = {
  name: apimServiceName
}

// ── Named Values (referenced in apim-policy.xml as {{name}}) ─────────────────

resource nvBackendUrl 'Microsoft.ApiManagement/service/namedValues@2022-08-01' = {
  parent: apim
  name: 'mcp-backend-url'
  properties: {
    displayName: 'mcp-backend-url'
    value: mcpServerUrl
    secret: false
    tags: ['mcp']
  }
}

resource nvTenantId 'Microsoft.ApiManagement/service/namedValues@2022-08-01' = {
  parent: apim
  name: 'mcp-tenant-id'
  properties: {
    displayName: 'mcp-tenant-id'
    value: tenantId
    secret: false
    tags: ['mcp']
  }
}

resource nvAppId 'Microsoft.ApiManagement/service/namedValues@2022-08-01' = {
  parent: apim
  name: 'mcp-app-id'
  properties: {
    displayName: 'mcp-app-id'
    value: entraApiAppClientId
    secret: false
    tags: ['mcp']
  }
}

// ── API definition ────────────────────────────────────────────────────────────

resource mcpApi 'Microsoft.ApiManagement/service/apis@2022-08-01' = {
  parent: apim
  name: apiName
  properties: {
    displayName: apiDisplayName
    description: apiDescription
    path: apiPath
    protocols: ['https']
    subscriptionRequired: subscriptionRequired
    type: 'http'
  }
  dependsOn: [nvBackendUrl, nvTenantId, nvAppId]
}

// ── Operations ────────────────────────────────────────────────────────────────

// MCP streamable-HTTP transport (Copilot Studio, MCP clients)
resource opMcp 'Microsoft.ApiManagement/service/apis/operations@2022-08-01' = {
  parent: mcpApi
  name: 'mcp-post'
  properties: {
    displayName: 'MCP Endpoint'
    method: 'POST'
    urlTemplate: '/mcp'
    description: 'MCP streamable-HTTP endpoint (x-ms-agentic-protocol: mcp-streamable-1.0).'
    responses: [{statusCode: 200, description: 'Success'}]
  }
}

// SSE transport — connection endpoint
resource opSse 'Microsoft.ApiManagement/service/apis/operations@2022-08-01' = {
  parent: mcpApi
  name: 'sse-get'
  properties: {
    displayName: 'SSE Connection'
    method: 'GET'
    urlTemplate: '/sse'
    description: 'Server-Sent Events connection endpoint for MCP SSE transport.'
    responses: [{statusCode: 200, description: 'Success'}]
  }
}

// SSE transport — message posting endpoint
resource opMessages 'Microsoft.ApiManagement/service/apis/operations@2022-08-01' = {
  parent: mcpApi
  name: 'messages-post'
  properties: {
    displayName: 'SSE Messages'
    method: 'POST'
    urlTemplate: '/messages/'
    description: 'Message posting endpoint for MCP SSE transport.'
    responses: [{statusCode: 200, description: 'Success'}]
  }
}

// ── API policy (JWT validation + backend routing) ─────────────────────────────

resource mcpPolicy 'Microsoft.ApiManagement/service/apis/policies@2022-08-01' = {
  parent: mcpApi
  name: 'policy'
  properties: {
    value: loadTextContent('./apim-policy.xml')
    format: 'xml'
  }
  dependsOn: [nvBackendUrl, nvTenantId, nvAppId]
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output apimGatewayUrl string = apim.properties.gatewayUrl
output mcpApiUrl string = '${apim.properties.gatewayUrl}/${apiPath}'
output mcpEndpointUrl string = '${apim.properties.gatewayUrl}/${apiPath}/mcp'
output sseEndpointUrl string = '${apim.properties.gatewayUrl}/${apiPath}/sse'
