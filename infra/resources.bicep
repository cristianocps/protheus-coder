// Resource-group-scope resources for Protheus Coder.
@description('azd environment name.')
param environmentName string
param location string
param tags object

@secure()
param anthropicApiKey string
param claudeModel string = ''
@secure()
param mcpApiKey string
param azdoOrg string
@secure()
param azdoPat string
param containerImage string

var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, environmentName))
var prefix = 'pc'

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-log-${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------------------
// Identity + container registry (azd builds and pushes here)
// ---------------------------------------------------------------------------
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id-${resourceToken}'
  location: location
  tags: tags
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: '${prefix}acr${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, acrPullRoleId)
  scope: registry
  properties: {
    principalId: identity.properties.principalId
    roleDefinitionId: acrPullRoleId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Persistent workspace cache (Azure Files)
// ---------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${prefix}st${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource workspaceShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'workspace'
  properties: {
    // Large enough for many cloned repos + indices.
    shareQuota: 100
    enabledProtocols: 'SMB'
  }
}

// ---------------------------------------------------------------------------
// Container Apps environment + Azure Files storage link
// ---------------------------------------------------------------------------
resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}-env-${resourceToken}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: containerEnv
  name: 'workspace'
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: workspaceShare.name
      accessMode: 'ReadWrite'
    }
  }
}

// ---------------------------------------------------------------------------
// Container App
// ---------------------------------------------------------------------------
resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-app-${resourceToken}'
  location: location
  tags: union(tags, {
    'azd-service-name': 'protheus-coder'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: registry.properties.loginServer
          identity: identity.id
        }
      ]
      secrets: [
        {
          name: 'anthropic-api-key'
          value: anthropicApiKey
        }
        {
          name: 'mcp-api-key'
          value: mcpApiKey
        }
        {
          name: 'azdo-pat'
          value: azdoPat
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'protheus-coder'
          image: containerImage
          resources: {
            cpu: json('1.0')
            memory: '2.0Gi'
          }
          env: [
            {
              name: 'ANTHROPIC_API_KEY'
              secretRef: 'anthropic-api-key'
            }
            {
              name: 'MCP_API_KEY'
              secretRef: 'mcp-api-key'
            }
            {
              name: 'AZDO_PAT'
              secretRef: 'azdo-pat'
            }
            {
              name: 'AZDO_ORG'
              value: azdoOrg
            }
            {
              name: 'PUBLIC_PORT'
              value: '8080'
            }
            {
              name: 'GATEWAY_PORT'
              value: '8000'
            }
            {
              name: 'CLAUDE_MODEL'
              value: claudeModel
            }
          ]
          volumeMounts: [
            {
              volumeName: 'workspace'
              mountPath: '/workspace'
            }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 8080
              }
              initialDelaySeconds: 20
              periodSeconds: 30
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'workspace'
          storageType: 'AzureFile'
          storageName: envStorage.name
        }
      ]
      scale: {
        // Keep one warm instance so the persistent cache stays hot and MCP
        // sessions are not load-balanced across replicas.
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output registryLoginServer string = registry.properties.loginServer
output containerAppName string = containerApp.name
output mcpEndpoint string = 'https://${containerApp.properties.configuration.ingress.fqdn}/mcp'
