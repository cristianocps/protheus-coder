// Subscription-scope entrypoint used by azd.
// Creates a resource group and delegates resources to resources.bicep.
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment; used to derive resource names.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Anthropic API key used by `claude mcp serve`.')
@secure()
param anthropicApiKey string

@description('Static API key that Copilot Studio sends as the X-API-Key header.')
@secure()
param mcpApiKey string

@description('Azure DevOps organization slug (after dev.azure.com/).')
param azdoOrg string

@description('Azure DevOps read-only PAT (Code: Read) used to clone repos.')
@secure()
param azdoPat string

@description('Container image. Overridden by azd deploy after build/push.')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

var abbrevRg = 'rg-${environmentName}'
var tags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: abbrevRg
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    anthropicApiKey: anthropicApiKey
    mcpApiKey: mcpApiKey
    azdoOrg: azdoOrg
    azdoPat: azdoPat
    containerImage: containerImage
  }
}

output AZURE_LOCATION string = location
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.registryLoginServer
output SERVICE_PROTHEUS_CODER_ENDPOINT string = resources.outputs.mcpEndpoint
output SERVICE_PROTHEUS_CODER_NAME string = resources.outputs.containerAppName
