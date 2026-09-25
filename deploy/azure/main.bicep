targetScope = 'resourceGroup'

@description('Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Unique Azure Public IP DNS label. This becomes <label>.<region>.cloudapp.azure.com.')
@minLength(3)
@maxLength(40)
param dnsLabel string

@description('Unique Azure Public IP DNS label for the Agentgateway management UI.')
@minLength(3)
@maxLength(40)
param uiDnsLabel string

@description('Linux VM administrator username used only for break-glass access.')
param vmAdminUsername string = 'azureadmin'

@description('Break-glass SSH public key. The NSG does not expose port 22.')
param vmAdminSshPublicKey string

@secure()
@description('Open WebUI Entra application client secret.')
param webuiClientSecret string

@secure()
@description('Persistent Open WebUI session and OAuth encryption secret.')
param webuiSecretKey string

@secure()
@description('Agentgateway UI Entra application client secret.')
param agentgatewayUiClientSecret string

@secure()
@description('Persistent Agentgateway OIDC cookie encryption secret.')
param agentgatewayUiCookieSecret string

@description('VM SKU for the Compose host.')
param vmSize string = 'Standard_B2s'

@description('Azure OpenAI deployment name used as the upstream model identifier.')
param modelDeploymentName string = 'gpt-4.1-mini'

@description('Azure OpenAI model name.')
param modelName string = 'gpt-4.1-mini'

@description('Pinned Azure OpenAI model version.')
param modelVersion string = '2025-04-14'

@description('Regional Azure OpenAI deployment SKU. Keep Standard for regional processing.')
param modelSkuName string = 'Standard'

@description('Azure OpenAI capacity in thousands of tokens per minute.')
@minValue(1)
param modelCapacity int = 10

var safePrefix = toLower(dnsLabel)
var uniqueSuffix = uniqueString(subscription().id, resourceGroup().id, safePrefix)
var publicIpName = '${safePrefix}-pip'
var uiPublicIpName = '${toLower(uiDnsLabel)}-pip'
var loadBalancerName = '${safePrefix}-lb'
var loadBalancerFrontendName = 'public-frontend'
var loadBalancerUiFrontendName = 'ui-frontend'
var loadBalancerBackendPoolName = 'compose-vm'
var loadBalancerUiBackendPoolName = 'compose-vm-ui'
var loadBalancerProbeName = 'http-probe'
var networkSecurityGroupName = '${safePrefix}-nsg'
var virtualNetworkName = '${safePrefix}-vnet'
var subnetName = 'default'
var networkInterfaceName = '${safePrefix}-nic'
var vmName = '${safePrefix}-vm'
var keyVaultName = take('kv${uniqueSuffix}', 24)
var openAiAccountName = take('aoai${uniqueSuffix}', 64)
var cloudInit = loadTextContent('cloud-init.yaml')
var commonTags = {
  Application: 'demo-llm-oauth'
  Environment: 'POC'
  Owner: 'aifabriken-dev'
  Purpose: 'Entra OAuth protected LLM proof of concept'
  ManagedBy: 'GitHub Actions and Bicep'
  Repository: 'https://github.com/riksbanken/demo-llm-oauth'
  RB_ApplicationName: 'Development Services'
  RB_Creator: 'Johan.Carlin@riksbank.se'
  RB_Environment: 'Utv'
  RB_FO: 'Analysis'
  RB_Owner: 'Johan.Carlin@riksbank.se'
  RB_StartDate: '2026-09-22'
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  tags: union(commonTags, {
    Description: 'Stable public HTTPS endpoint and Azure OpenAI egress allowlist address'
  })
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: safePrefix
    }
  }
}

resource uiPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: uiPublicIpName
  location: location
  tags: union(commonTags, {
    Description: 'Public hostname for the SSO-protected Agentgateway management UI'
  })
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: toLower(uiDnsLabel)
    }
  }
}

resource loadBalancer 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: loadBalancerName
  location: location
  tags: union(commonTags, {
    Description: 'Public HTTPS entry point and explicit outbound SNAT for the private Compose VM'
  })
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: loadBalancerFrontendName
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
      {
        name: loadBalancerUiFrontendName
        properties: {
          publicIPAddress: {
            id: uiPublicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: loadBalancerBackendPoolName
      }
      {
        name: loadBalancerUiBackendPoolName
      }
    ]
    probes: [
      {
        name: loadBalancerProbeName
        properties: {
          protocol: 'Tcp'
          port: 80
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'http'
        properties: {
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, loadBalancerFrontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, loadBalancerBackendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, loadBalancerProbeName)
          }
          disableOutboundSnat: true
          enableFloatingIP: false
          enableTcpReset: true
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
        }
      }
      {
        name: 'https'
        properties: {
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, loadBalancerFrontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, loadBalancerBackendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, loadBalancerProbeName)
          }
          disableOutboundSnat: true
          enableFloatingIP: false
          enableTcpReset: true
          idleTimeoutInMinutes: 30
          loadDistribution: 'Default'
        }
      }
      {
        name: 'ui-http'
        properties: {
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, loadBalancerUiFrontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, loadBalancerUiBackendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, loadBalancerProbeName)
          }
          disableOutboundSnat: true
          enableFloatingIP: false
          enableTcpReset: true
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
        }
      }
      {
        name: 'ui-https'
        properties: {
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, loadBalancerUiFrontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, loadBalancerUiBackendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, loadBalancerProbeName)
          }
          disableOutboundSnat: true
          enableFloatingIP: false
          enableTcpReset: true
          idleTimeoutInMinutes: 30
          loadDistribution: 'Default'
        }
      }
    ]
    outboundRules: [
      {
        name: 'internet-egress'
        properties: {
          protocol: 'All'
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, loadBalancerBackendPoolName)
          }
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, loadBalancerFrontendName)
            }
          ]
          allocatedOutboundPorts: 1024
          idleTimeoutInMinutes: 15
          enableTcpReset: true
        }
      }
    ]
  }
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: networkSecurityGroupName
  location: location
  tags: union(commonTags, {
    Description: 'Limits public ingress to HTTP and HTTPS for the POC web endpoint'
  })
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTP'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-HTTPS'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-Load-Balancer-Probe'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  tags: union(commonTags, {
    Description: 'Private network for the Docker Compose VM'
  })
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.42.0.0/24'
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
    ]
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: networkInterfaceName
  location: location
  tags: union(commonTags, {
    Description: 'Connects the private Compose VM to the Standard Load Balancer backend pool'
  })
  dependsOn: [
    loadBalancer
  ]
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, subnetName)
          }
          loadBalancerBackendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, loadBalancerBackendPoolName)
            }
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, loadBalancerUiBackendPoolName)
            }
          ]
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  tags: union(commonTags, {
    Description: 'Runs Open WebUI, Agentgateway, and Caddy using Docker Compose'
  })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        diskSizeGB: 64
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: vmAdminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        patchSettings: {
          assessmentMode: 'AutomaticByPlatform'
          patchMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            bypassPlatformSafetyChecksOnUserSchedule: false
            rebootSetting: 'IfRequired'
          }
        }
        ssh: {
          publicKeys: [
            {
              path: '/home/${vmAdminUsername}/.ssh/authorized_keys'
              keyData: vmAdminSshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            primary: true
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: union(commonTags, {
    Description: 'Stores Open WebUI, Agentgateway UI, and Azure OpenAI secrets read by the VM managed identity'
  })
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: [
      {
        tenantId: tenant().tenantId
        objectId: vm.identity.principalId
        permissions: {
          secrets: [
            'get'
          ]
        }
      }
    ]
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource openAiAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: openAiAccountName
  location: location
  tags: union(commonTags, {
    Description: 'Regional Azure OpenAI endpoint providing the POC chat model'
  })
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: openAiAccountName
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      ipRules: [
        {
          value: publicIp.properties.ipAddress
        }
      ]
      virtualNetworkRules: []
    }
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAiAccount
  name: modelDeploymentName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource webuiClientSecretResource 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'webui-client-secret'
  properties: {
    value: webuiClientSecret
  }
}

resource webuiSecretKeyResource 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'webui-secret-key'
  properties: {
    value: webuiSecretKey
  }
}

resource agentgatewayUiClientSecretResource 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'agentgateway-ui-client-secret'
  properties: {
    value: agentgatewayUiClientSecret
  }
}

resource agentgatewayUiCookieSecretResource 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'agentgateway-ui-cookie-secret'
  properties: {
    value: agentgatewayUiCookieSecret
  }
}

resource azureOpenAiKeyResource 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'azure-openai-api-key'
  properties: {
    value: openAiAccount.listKeys().key1
  }
}

output vmName string = vm.name
output publicIpAddress string = publicIp.properties.ipAddress
output publicHostname string = publicIp.properties.dnsSettings.fqdn
output publicUrl string = 'https://${publicIp.properties.dnsSettings.fqdn}'
output uiPublicIpAddress string = uiPublicIp.properties.ipAddress
output uiPublicHostname string = uiPublicIp.properties.dnsSettings.fqdn
output uiPublicUrl string = 'https://${uiPublicIp.properties.dnsSettings.fqdn}'
output keyVaultName string = keyVault.name
output openAiAccountName string = openAiAccount.name
output openAiEndpoint string = openAiAccount.properties.endpoint
output modelDeploymentName string = modelDeployment.name
