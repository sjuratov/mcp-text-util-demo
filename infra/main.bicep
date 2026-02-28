targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

// Monitoring: Log Analytics Workspace + Application Insights
module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.0' = {
  name: 'monitoring'
  scope: rg
  params: {
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    location: location
    tags: tags
  }
}

// Container Apps Stack: ACR (Basic) + Container Apps Environment (Consumption)
module containerApps 'br/public:avm/ptn/azd/container-apps-stack:0.1.0' = {
  name: 'container-apps-stack'
  scope: rg
  params: {
    containerAppsEnvironmentName: '${abbrs.appManagedEnvironments}${resourceToken}'
    containerRegistryName: '${abbrs.containerRegistryRegistries}${resourceToken}'
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    appInsightsConnectionString: monitoring.outputs.applicationInsightsConnectionString
    acrSku: 'Basic'
    location: location
    acrAdminUserEnabled: true
    zoneRedundant: false
    tags: tags
  }
}

// Managed identity for the agent container app (used for ACR pull)
module agentIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'agent-identity'
  scope: rg
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}agent-${resourceToken}'
    location: location
  }
}

// Container App: the A2A Text Utilities Agent
module agent 'br/public:avm/ptn/azd/acr-container-app:0.2.0' = {
  name: 'agent-container-app'
  scope: rg
  params: {
    name: '${abbrs.appContainerApps}agent-${resourceToken}'
    tags: union(tags, { 'azd-service-name': 'agent' })
    location: location
    containerAppsEnvironmentName: containerApps.outputs.environmentName
    containerRegistryName: containerApps.outputs.registryName
    identityType: 'UserAssigned'
    identityName: agentIdentity.outputs.name
    userAssignedIdentityResourceId: agentIdentity.outputs.resourceId
    principalId: agentIdentity.outputs.principalId
    containerName: 'main'
    targetPort: 8000
    ingressEnabled: true
    external: true
    containerMinReplicas: 0
    containerMaxReplicas: 1
    containerCpuCoreCount: '0.25'
    containerMemory: '0.5Gi'
    env: [
      {
        name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
        value: monitoring.outputs.applicationInsightsConnectionString
      }
    ]
  }
}

// Outputs for azd
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerApps.outputs.registryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = containerApps.outputs.registryName
output AZURE_CONTAINER_ENVIRONMENT_NAME string = containerApps.outputs.environmentName
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.applicationInsightsConnectionString
output AZURE_LOCATION string = location
output SERVICE_AGENT_NAME string = agent.outputs.name
output SERVICE_AGENT_URI string = agent.outputs.uri
