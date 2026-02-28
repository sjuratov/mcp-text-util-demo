$ErrorActionPreference = "Stop"

$rg = "rg-$env:AZURE_ENV_NAME"
$subscriptionId = az account show --query "id" -o tsv
$tenantId = az account show --query "tenantId" -o tsv
$imageTag = $env:AZURE_ENV_NAME
$imageName = "a2a-text-utilities:$imageTag"
$apiAppName = "a2a-text-utilities-api-$env:AZURE_ENV_NAME"
$clientAppName = "a2a-text-utilities-client-$env:AZURE_ENV_NAME"

Write-Host "Ensuring Entra API app registration: $apiAppName"
$apiAppId = az ad app list --display-name $apiAppName --query "[0].appId" -o tsv 2>$null
if (-not $apiAppId) {
    $apiAppId = az ad app create --display-name $apiAppName --sign-in-audience AzureADMyOrg --query "appId" -o tsv
}
$apiObjectId = az ad app show --id $apiAppId --query "id" -o tsv
$scopeId = az ad app show --id $apiAppId --query "api.oauth2PermissionScopes[?value=='access_as_user'] | [0].id" -o tsv
if (-not $scopeId) {
    $scopeId = [guid]::NewGuid().ToString()
}
az ad app update --id $apiAppId --identifier-uris "api://$apiAppId"
$apiBody = "{`"api`":{`"requestedAccessTokenVersion`":2,`"oauth2PermissionScopes`":[{`"id`":`"$scopeId`",`"adminConsentDescription`":`"Access the A2A Text Utilities Agent`",`"adminConsentDisplayName`":`"Access A2A Agent`",`"userConsentDescription`":`"Allow this app to access the A2A Text Utilities Agent on your behalf`",`"userConsentDisplayName`":`"Access A2A Agent`",`"isEnabled`":true,`"type`":`"User`",`"value`":`"access_as_user`"}]}}"
az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$apiObjectId" --headers "Content-Type=application/json" --body $apiBody
az ad sp create --id $apiAppId 2>$null

Write-Host "Ensuring Entra client app registration: $clientAppName"
$clientAppId = az ad app list --display-name $clientAppName --query "[0].appId" -o tsv 2>$null
if (-not $clientAppId) {
    $clientAppId = az ad app create --display-name $clientAppName --sign-in-audience AzureADMyOrg --query "appId" -o tsv
}
$clientObjectId = az ad app show --id $clientAppId --query "id" -o tsv
$clientBody = "{`"isFallbackPublicClient`":true,`"publicClient`":{`"redirectUris`":[`"http://localhost`"]},`"requiredResourceAccess`":[{`"resourceAppId`":`"$apiAppId`",`"resourceAccess`":[{`"id`":`"$scopeId`",`"type`":`"Scope`"}]}]}"
az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$clientObjectId" --headers "Content-Type=application/json" --body $clientBody
az ad sp create --id $clientAppId 2>$null
az ad app permission add --id $clientAppId --api $apiAppId --api-permissions "$scopeId=Scope" 2>$null
az ad app permission grant --id $clientAppId --api $apiAppId --scope "access_as_user" 2>$null

azd env set ENTRA_API_APP_CLIENT_ID $apiAppId
azd env set ENTRA_CLIENT_APP_CLIENT_ID $clientAppId
azd env set ENTRA_APP_CLIENT_ID $apiAppId
azd env set AZURE_TENANT_ID $tenantId

Write-Host "Configuring EasyAuth on container app: $env:SERVICE_AGENT_NAME"
az containerapp auth microsoft update `
    --name $env:SERVICE_AGENT_NAME `
    --resource-group $rg `
    --client-id $apiAppId `
    --issuer "https://login.microsoftonline.com/$tenantId/v2.0" `
    --allowed-audiences "$apiAppId"
$authUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.App/containerApps/$env:SERVICE_AGENT_NAME/authConfigs/current?api-version=2024-03-01"
$authBody = "{`"properties`":{`"platform`":{`"enabled`":true},`"globalValidation`":{`"unauthenticatedClientAction`":`"Return401`",`"excludedPaths`":[`"/.well-known/agent-card.json`"]},`"identityProviders`":{`"azureActiveDirectory`":{`"isAutoProvisioned`":false,`"registration`":{`"clientId`":`"$apiAppId`",`"openIdIssuer`":`"https://login.microsoftonline.com/$tenantId/v2.0`"},`"validation`":{`"allowedAudiences`":[`"$apiAppId`",`"api://$apiAppId`"],`"defaultAuthorizationPolicy`":{`"allowedApplications`":[`"$clientAppId`"]}}}},`"login`":{`"preserveUrlFragmentsForLogins`":false},`"encryptionSettings`":{}}}"
az rest --method PUT --url $authUrl --headers "Content-Type=application/json" --body $authBody | Out-Null

Write-Host "Building image in ACR: $env:AZURE_CONTAINER_REGISTRY_NAME/$imageName"
az acr build --registry $env:AZURE_CONTAINER_REGISTRY_NAME --image $imageName .

Write-Host "Updating container app: $env:SERVICE_AGENT_NAME"
az containerapp update --name $env:SERVICE_AGENT_NAME --resource-group $rg --image "$env:AZURE_CONTAINER_REGISTRY_ENDPOINT/$imageName" --set-env-vars "AGENT_PUBLIC_BASE_URL=$env:SERVICE_AGENT_URI"

Write-Host "Done. Agent URL: $env:SERVICE_AGENT_URI"
Write-Host "Entra API App ID: $apiAppId"
Write-Host "Entra Client App ID: $clientAppId"
