// =========================================================================
// Azure Tagging Policy Demo - Resource Group Tagging Standard (sub scope)
// -------------------------------------------------------------------------
// Self-contained. Identical resource graph to main.bicep but at subscription
// scope. Prefer main.bicep when possible (it propagates to every sub beneath
// the management group).
//
// Deploy:
//   az deployment sub create \
//     --name tagging-demo \
//     --subscription <subscriptionId> \
//     --location eastus2 \
//     --template-file main.sub.bicep
// =========================================================================

targetScope = 'subscription'

// -------- Parameters --------

@description('Tags that must be present on every resource group. Each tag is enforced (deny on missing) and propagated to child resources (modify).')
param tagsToEnforce array = [
  'Environment'
  'CostCenter'
  'Owner'
  'Application'
]

@description('Effect for the deny-on-missing-tag policy. Use deny in production, audit for a soft rollout.')
@allowed([
  'deny'
  'audit'
  'disabled'
])
param denyEffect string = 'deny'

@description('Effect for the per-tag inherit-from-RG policy. modify auto-applies; audit only reports.')
@allowed([
  'modify'
  'audit'
  'disabled'
])
param inheritEffect string = 'modify'

@description('Region used to host the assignment\'s system-assigned managed identity.')
param assignmentLocation string = 'eastus2'

// -------- Policy definition: deny when a single named tag is missing on the RG --------

resource requireDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'demo-require-rg-tag'
  properties: {
    displayName: 'Require a specified tag on resource groups'
    description: 'Denies the creation or update of a resource group unless the specified tag is present with a non-empty value.'
    policyType: 'Custom'
    mode: 'All'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-tagging-policy-demo'
    }
    parameters: {
      tagName: {
        type: 'String'
        metadata: {
          displayName: 'Tag Name'
          description: 'Name of the tag that must be present on every resource group.'
        }
      }
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'deny, audit, or disabled.'
        }
        allowedValues: [
          'deny'
          'audit'
          'disabled'
        ]
        defaultValue: 'deny'
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Resources/subscriptions/resourceGroups'
          }
          {
            anyOf: [
              {
                field: '[concat(\'tags[\', parameters(\'tagName\'), \']\')]'
                exists: 'false'
              }
              {
                field: '[concat(\'tags[\', parameters(\'tagName\'), \']\')]'
                equals: ''
              }
            ]
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}

// -------- Policy definition: inherit a single named tag from the parent RG --------

resource inheritDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'demo-inherit-tag-from-rg'
  properties: {
    displayName: 'Inherit a tag from the resource group if missing'
    description: 'Adds the specified tag with its value from the parent resource group when a resource is missing this tag. Can be combined with a remediation task to back-fill existing resources.'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-tagging-policy-demo'
    }
    parameters: {
      tagName: {
        type: 'String'
        metadata: {
          displayName: 'Tag Name'
          description: 'Name of the tag to inherit from the resource group, e.g. Environment.'
        }
      }
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'modify auto-applies missing tags; audit only reports.'
        }
        allowedValues: [
          'modify'
          'audit'
          'disabled'
        ]
        defaultValue: 'modify'
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: '[concat(\'tags[\', parameters(\'tagName\'), \']\')]'
            exists: 'false'
          }
          {
            value: '[empty(resourceGroup().tags[parameters(\'tagName\')])]'
            equals: 'false'
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          roleDefinitionIds: [
            '/providers/microsoft.authorization/roleDefinitions/4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
          ]
          operations: [
            {
              operation: 'add'
              field: '[concat(\'tags[\', parameters(\'tagName\'), \']\')]'
              value: '[resourceGroup().tags[parameters(\'tagName\')]]'
            }
          ]
        }
      }
    }
  }
}

// -------- Initiative --------

var denyPolicyRefs = [for tagName in tagsToEnforce: {
  policyDefinitionReferenceId: 'require-${tagName}'
  policyDefinitionId: requireDef.id
  parameters: {
    tagName: {
      value: tagName
    }
    effect: {
      value: denyEffect
    }
  }
}]

var inheritPolicyRefs = [for tagName in tagsToEnforce: {
  policyDefinitionReferenceId: 'inherit-${tagName}'
  policyDefinitionId: inheritDef.id
  parameters: {
    tagName: {
      value: tagName
    }
    effect: {
      value: inheritEffect
    }
  }
}]

resource initiative 'Microsoft.Authorization/policySetDefinitions@2023-04-01' = {
  name: 'demo-rg-tagging-standard'
  properties: {
    displayName: 'Resource Group Tagging Standard (Demo)'
    description: 'Enforces required RG tags AND propagates them to children.'
    policyType: 'Custom'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-tagging-policy-demo'
    }
    policyDefinitions: concat(denyPolicyRefs, inheritPolicyRefs)
  }
}

// -------- Assignment --------

var tagListForMessage = join(tagsToEnforce, ', ')

resource assignment 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'demo-rg-tagging-standard'
  location: assignmentLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Resource Group Tagging Standard (Demo) - Assignment'
    description: 'Enforces the Resource Group Tagging Standard (Demo) initiative.'
    policyDefinitionId: initiative.id
    enforcementMode: 'Default'
    nonComplianceMessages: [for tagName in tagsToEnforce: {
      message: 'This resource group is missing the required tag \'${tagName}\'. Every RG must carry these tags with non-empty values: ${tagListForMessage}. Add the missing tag(s) and retry. Child resources will inherit these tags automatically.'
      policyDefinitionReferenceId: 'require-${tagName}'
    }]
  }
}

// -------- Role assignment for Modify remediation --------

var tagContributorRoleDefId = tenantResourceId('Microsoft.Authorization/roleDefinitions', '4a9ae827-6dc8-4573-8ac7-8239d42aa03f')

resource tagContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, assignment.id, tagContributorRoleDefId)
  properties: {
    roleDefinitionId: tagContributorRoleDefId
    principalId: assignment.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// -------- Outputs --------

output requireDefId         string = requireDef.id
output inheritDefId         string = inheritDef.id
output initiativeId         string = initiative.id
output assignmentId         string = assignment.id
output assignmentPrincipal  string = assignment.identity.principalId
