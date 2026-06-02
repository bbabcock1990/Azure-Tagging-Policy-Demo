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

@description('Tags that must be present on every resource group. Each tag is enforced (deny on missing) and propagated to child resources (modify). Required — see README for the per-customer override example.')
@minLength(1)
param tagsToEnforce array

@description('Optional map of tag name -> default value. Tags listed here become remediable: existing RGs missing the tag will have it added with the given value via a Modify policy + remediation task. Tags in tagsToEnforce but not in this map are deny-only. Tags listed here that are not in tagsToEnforce are still defaulted but are not enforced by the deny rule.')
param tagDefaults object = {}

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

@description('Effect for the per-tag set-default-on-RG policy. modify auto-applies the default value when remediated; audit only reports.')
@allowed([
  'modify'
  'audit'
  'disabled'
])
param defaultEffect string = 'modify'

@description('Region used to host the assignment\'s system-assigned managed identity.')
param assignmentLocation string = 'eastus2'

@description('Organization or customer name shown in every policy / initiative / assignment display string and in the non-compliance message. Required — see README for the per-customer override example.')
@minLength(1)
param organizationName string

// -------- Policy definition: deny when a single named tag is missing on the RG --------

resource requireDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'demo-require-rg-tag'
  properties: {
    displayName: '${organizationName} - Require a specified tag on resource groups'
    description: 'Denies the creation or update of a resource group unless the specified tag is present with a non-empty value.'
    policyType: 'Custom'
    mode: 'All'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-tagging-policy-demo'
      owner: '${organizationName} Cloud Governance'
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
    displayName: '${organizationName} - Inherit a tag from the resource group if missing'
    description: 'Adds the specified tag with its value from the parent resource group when a resource is missing this tag. Can be combined with a remediation task to back-fill existing resources.'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-tagging-policy-demo'
      owner: '${organizationName} Cloud Governance'
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

// -------- Policy definition: set a default value on the RG when a tag is missing --------

resource defaultDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'demo-set-default-rg-tag'
  properties: {
    displayName: '${organizationName} - Set a default value for a tag on resource groups'
    description: 'If the specified tag is missing or empty on a resource group, adds it with the supplied default value. This is the remediable counterpart to the deny rule — run a remediation task to back-fill RGs that existed before the policy was assigned.'
    policyType: 'Custom'
    mode: 'All'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-tagging-policy-demo'
      owner: '${organizationName} Cloud Governance'
    }
    parameters: {
      tagName: {
        type: 'String'
        metadata: {
          displayName: 'Tag Name'
          description: 'Name of the tag to default on the resource group.'
        }
      }
      tagValue: {
        type: 'String'
        metadata: {
          displayName: 'Tag Value'
          description: 'Default value applied to the tag when the RG is missing it.'
        }
      }
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'modify auto-applies the default during remediation; audit only reports.'
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
        details: {
          roleDefinitionIds: [
            '/providers/microsoft.authorization/roleDefinitions/4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
          ]
          conflictEffect: 'audit'
          operations: [
            {
              operation: 'addOrReplace'
              field: '[concat(\'tags[\', parameters(\'tagName\'), \']\')]'
              value: '[parameters(\'tagValue\')]'
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

var defaultPolicyRefs = [for item in items(tagDefaults): {
  policyDefinitionReferenceId: 'default-${item.key}'
  policyDefinitionId: defaultDef.id
  parameters: {
    tagName: {
      value: item.key
    }
    tagValue: {
      value: item.value
    }
    effect: {
      value: defaultEffect
    }
  }
}]

resource initiative 'Microsoft.Authorization/policySetDefinitions@2023-04-01' = {
  name: 'demo-rg-tagging-standard'
  properties: {
    displayName: '${organizationName} - Resource Group Tagging Standard'
    description: 'Enforces required RG tags (deny on create/update without them) AND propagates tags from RG to child resources at create-time.'
    policyType: 'Custom'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-tagging-policy-demo'
      owner: '${organizationName} Cloud Governance'
    }
    policyDefinitions: concat(denyPolicyRefs, inheritPolicyRefs)
  }
}

// -------- Initiative (defaults — only created when tagDefaults is supplied) --------
// Kept as a SEPARATE initiative + assignment so the deny effect from the main
// initiative is always the one that fires on RG create/update. If we bundled
// the default-* refs alongside deny, Azure Policy effect precedence (Modify
// runs BEFORE Deny) would silently inject the default tag on create, bypassing
// the deny rule. By isolating defaults in a DoNotEnforce assignment, the modify
// effect skips request-time mutation while still producing compliance findings
// and supporting remediation tasks against existing non-compliant RGs.

resource initiativeDefaults 'Microsoft.Authorization/policySetDefinitions@2023-04-01' = if (!empty(tagDefaults)) {
  name: 'demo-rg-tagging-defaults'
  properties: {
    displayName: '${organizationName} - RG Tagging Defaults (Remediation Only)'
    description: 'Companion initiative to the Resource Group Tagging Standard. Holds the per-tag default-set Modify policies that back-fill missing tags on existing RGs via remediation tasks. Assigned with enforcementMode=DoNotEnforce so it does NOT mutate new RG creates — the deny enforcement on the main assignment always wins for new RGs.'
    policyType: 'Custom'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-tagging-policy-demo'
      owner: '${organizationName} Cloud Governance'
    }
    policyDefinitions: defaultPolicyRefs
  }
}

// -------- Assignment (enforcement) --------

var tagListForMessage = join(tagsToEnforce, ', ')

resource assignment 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'demo-rg-tagging-standard'
  location: assignmentLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: '${organizationName} - RG Tagging Standard (Assignment)'
    description: 'Enforces the ${organizationName} RG Tagging Standard initiative.'
    policyDefinitionId: initiative.id
    enforcementMode: 'Default'
    nonComplianceMessages: [for tagName in tagsToEnforce: {
      message: '${organizationName} Governance: This resource group is missing the required tag \'${tagName}\'. Every RG must carry these tags with non-empty values: ${tagListForMessage}. Add the missing tag(s) and retry. Child resources will inherit these tags automatically.'
      policyDefinitionReferenceId: 'require-${tagName}'
    }]
  }
}

// -------- Assignment (remediation defaults — DoNotEnforce) --------

resource assignmentDefaults 'Microsoft.Authorization/policyAssignments@2023-04-01' = if (!empty(tagDefaults)) {
  name: 'demo-rg-tagging-defaults'
  location: assignmentLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: '${organizationName} - RG Tagging Defaults (Remediation Only)'
    description: 'Provides remediation back-fill for existing RGs missing required tags. enforcementMode=DoNotEnforce so new RG creates are NOT silently auto-tagged — the deny on the main assignment still rejects them. Run remediation tasks against each default-<TagName> reference to back-fill existing RGs.'
    policyDefinitionId: initiativeDefaults.id
    enforcementMode: 'DoNotEnforce'
  }
}

// -------- Role assignment for Modify remediation (main assignment) --------

module tagContributorRA 'modules/tagContributorRoleAssignment.sub.bicep' = {
  name: 'tagContributorRoleAssignment'
  params: {
    principalId: assignment.identity.principalId
  }
}

// -------- Role assignment for the defaults (remediation) assignment --------

module tagContributorRADefaults 'modules/tagContributorRoleAssignment.sub.bicep' = if (!empty(tagDefaults)) {
  name: 'tagContributorRoleAssignmentDefaults'
  params: {
    #disable-next-line BCP318
    principalId: assignmentDefaults.identity.principalId
  }
}

// -------- Outputs --------

output requireDefId          string = requireDef.id
output inheritDefId          string = inheritDef.id
output defaultDefId          string = defaultDef.id
output initiativeId          string = initiative.id
output assignmentId          string = assignment.id
output assignmentPrincipal   string = assignment.identity.principalId
output defaultsInitiativeId  string = !empty(tagDefaults) ? initiativeDefaults.id : ''
output defaultsAssignmentId  string = !empty(tagDefaults) ? assignmentDefaults.id : ''
