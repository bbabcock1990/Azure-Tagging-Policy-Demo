// =========================================================================
// Azure Tagging Policy Demo - Resource Group Tagging Standard (MG scope)
// -------------------------------------------------------------------------
// Self-contained. No external JSON files required.
//
// Deploys:
//   1. Custom policy definition - demo-require-rg-tag       (deny on missing tag, single-tag)
//   2. Custom policy definition - demo-inherit-tag-from-rg  (modify; propagation, single-tag)
//   3. Initiative                - demo-rg-tagging-standard (N deny refs + N inherit refs)
//   4. Policy assignment         - demo-rg-tagging-standard (system-assigned identity)
//   5. Role assignment           - Tag Contributor for the identity at MG scope
//
// Why the deny policy is single-tag and looped:
//   Azure Policy does NOT allow runtime functions like current() inside field().
//   The cleanest, fully-supported pattern (mirroring Microsoft's built-ins) is to
//   define a single-tag deny policy and reference it once per required tag in the
//   initiative.
//
// Caller permissions required at the target MG:
//   - Resource Policy Contributor (or Owner)
//   - User Access Administrator (or Owner) for the role assignment
//
// Deploy:
//   az deployment mg create \
//     --name tagging-demo \
//     --management-group-id <your-management-group-id> \
//     --location eastus2 \
//     --template-file main.bicep
// =========================================================================

targetScope = 'managementGroup'

// -------- Parameters --------

@description('Tags that must be present on every resource group. Each tag is enforced (deny on missing) and propagated to child resources (modify). Required — see README for the per-customer override example.')
@minLength(1)
param tagsToEnforce array

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
    displayName: '${organizationName} - Resource Group Tagging Standard'
    description: 'Enforces required RG tags AND propagates them to children.'
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

// -------- Assignment --------

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

// -------- Role assignment for Modify remediation --------
// Tag Contributor (4a9ae827-6dc8-4573-8ac7-8239d42aa03f).
// Delegated to a module so the role-assignment NAME can be computed from the
// managed-identity principalId (a runtime value, lifted to a static module
// param). principalType: 'ServicePrincipal' avoids the Entra-propagation
// race that can otherwise fail the role assignment when the identity was
// just created.

module tagContributorRA 'modules/tagContributorRoleAssignment.mg.bicep' = {
  name: 'tagContributorRoleAssignment'
  params: {
    principalId: assignment.identity.principalId
  }
}

// -------- Outputs --------

output requireDefId         string = requireDef.id
output inheritDefId         string = inheritDef.id
output initiativeId         string = initiative.id
output assignmentId         string = assignment.id
output assignmentPrincipal  string = assignment.identity.principalId
