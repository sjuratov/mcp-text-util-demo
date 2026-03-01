// Registers an existing MCP server as a Streamable-HTTP MCP API in an existing APIM instance.
// Usage:
//   az deployment group create \
//     --resource-group <rg> \
//     --template-file apim/mcp-api.bicep \
//     --parameters apimServiceName=<apim-name> \
//                  mcpBackendUrl=<full-mcp-endpoint-url> \
//                  mcpPath=<apim-path-segment>

@description('Name of the existing Azure API Management service.')
param apimServiceName string

@description('Full URL of the MCP server endpoint, e.g. https://host/mcp.')
param mcpBackendUrl string

@description('Path segment used in the APIM gateway URL, e.g. "text-utils" yields <gateway>/text-utils/mcp.')
param mcpPath string = 'text-utils'

@description('Microsoft Entra tenant ID used to build OpenID discovery URL in APIM policy.')
param tenantId string

@description('Client ID (application ID) of the Entra API app used as JWT audience in APIM policy.')
param apiAppClientId string

var policyTemplate = loadTextContent('policy.xml')
var policyXml = replace(replace(policyTemplate, '__TENANT_ID__', tenantId), '__API_APP_CLIENT_ID__', apiAppClientId)

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource mcpBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: '${mcpPath}-mcp-backend'
  properties: {
    protocol: 'http'
    url: mcpBackendUrl
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    type: 'Single'
  }
}

resource mcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: '${mcpPath}-mcp-server'
  properties: {
    displayName: '${mcpPath} MCP Server'
    description: '${mcpPath} MCP Server exposed via Azure API Management'
    type: 'mcp'
    subscriptionRequired: false
    backendId: mcpBackend.name
    path: '${mcpPath}/mcp'
    protocols: [
      'https'
    ]
    mcpProperties: {
      transportType: 'streamable'
    }
    authenticationSettings: {
      oAuth2AuthenticationSettings: []
      openidAuthenticationSettings: []
    }
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'subscription-key'
    }
    isCurrent: true
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2021-12-01-preview' = {
  parent: mcpApi
  name: 'policy'
  properties: {
    value: policyXml
    format: 'rawxml'
  }
}

output apimGatewayUrl string = apim.properties.gatewayUrl
output mcpApiPath string = mcpApi.properties.path
