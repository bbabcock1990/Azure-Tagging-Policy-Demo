// =========================================================================
// Azure Tagging Policy Demo - Resource Group Tagging Standard (MG scope)
// -------------------------------------------------------------------------
// Self-contained. No external JSON files required.
//
// Always deploys:
//   1. Custom policy definition - demo-require-rg-tag       (deny on missing tag, single-tag)
//   2. Custom policy definition - demo-inherit-tag-from-rg  (modify; propagation, single-tag)
//   3. Initiative                - demo-rg-tagging-standard (N deny refs + N inherit refs)
//   4. Policy assignment         - demo-rg-tagging-standard (system-assigned identity)
//   5. Role assignment           - Tag Contributor for the standard assignment's identity
//
// Additionally, when `tagDefaults` is supplied (non-empty):
//   6. Custom policy definition - demo-set-default-rg-tags  (multi-tag modify; one operation per default)
//   7. Initiative                - demo-rg-tagging-defaults (single `default-rg-tags` reference)
//   8. Policy assignment         - demo-rg-tagging-defaults (DoNotEnforce; system-assigned identity)
//   9. Role assignment           - Tag Contributor for the defaults assignment's identity
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

@description('Optional map of tag name -> default value used to back-fill missing tags on existing RGs via a remediation task. IMPORTANT: to make remediation work end-to-end, this map should include EVERY tag listed in tagsToEnforce — otherwise the deny rule will reject the remediation PATCH because some required tags will still be missing post-PATCH. Leave empty ({}) to skip the defaults assignment entirely. The Modify policy uses operation \'add\', which is a no-op on tags that already exist (existing non-empty values are preserved).')
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

@description('Effect for the consolidated set-defaults-on-RG policy. modify auto-applies all configured defaults during remediation; audit only reports; disabled skips.')
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

// -------- Policy definition: set default values for ALL configured RG tags in ONE PATCH --------
// Why this is consolidated into a single multi-operation Modify policy (instead of N single-tag
// policies bundled in the initiative):
//
//   The companion deny policy (require-<TagName>) rejects any write to an RG that leaves
//   ANY required tag missing or empty. The remediation engine PATCHes RGs to apply Modify
//   operations. If we had N single-tag default policies, each PATCH would add only ONE tag,
//   leaving the other required tags still missing — the deny rule would reject every such
//   PATCH (HTTP 403 Forbidden, "missing required tag X").
//
//   By emitting ALL default-tag operations in a single Modify policy, one remediation PATCH
//   adds all missing default tags atomically. Post-PATCH the RG has every required tag
//   present, the deny re-evaluation passes, and the remediation succeeds.
//
// Why operation \'add\' (not \'addOrReplace\'):
//   \'add\' is a no-op when the tag already exists, so we never clobber tag values an owner
//   has set intentionally. The trade-off: tags present with empty string values are not
//   remediated (operation conditions don\'t support field(), per the Modify effect docs,
//   so we can\'t selectively addOrReplace only the empty ones without overwriting valid
//   neighbors). Manual fix-up is required for empty-string tags — they\'re an edge case;
//   missing-tag remediation is the 99% scenario.

var defaultMissingChecks = [for item in items(tagDefaults): {
  field: 'tags[\'${item.key}\']'
  exists: 'false'
}]

var defaultAddOperations = [for item in items(tagDefaults): {
  operation: 'add'
  field: 'tags[\'${item.key}\']'
  value: item.value
}]

resource defaultDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = if (!empty(tagDefaults)) {
  name: 'demo-set-default-rg-tags'
  properties: {
    displayName: '${organizationName} - Set default values for missing RG tags (multi-tag)'
    description: 'When a resource group is missing any of the configured default tags, adds them ALL in a SINGLE PATCH. The single-PATCH design is required so the companion deny rule (which checks for ALL required tags) does not block the remediation engine. Uses operation \'add\', so existing non-empty tag values are preserved — only truly missing tags are populated.'
    policyType: 'Custom'
    mode: 'All'
    metadata: {
      category: 'Tags'
      version: '2.0.0'
      source: 'azure-tagging-policy-demo'
      owner: '${organizationName} Cloud Governance'
    }
    parameters: {
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'modify auto-applies the defaults during remediation; audit only reports; disabled skips.'
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
            anyOf: defaultMissingChecks
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
          operations: defaultAddOperations
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

// Single reference into the consolidated multi-tag default policy. The defaults initiative
// has exactly one policy reference (`default-rg-tags`), and remediation tasks target this
// reference ID. One task patches every missing default tag on every non-compliant RG.
var defaultPolicyRefs = !empty(tagDefaults) ? [
  {
    policyDefinitionReferenceId: 'default-rg-tags'
    #disable-next-line BCP318
    policyDefinitionId: defaultDef.id
    parameters: {
      effect: {
        value: defaultEffect
      }
    }
  }
] : []

// Validation: when tagDefaults is non-empty, it must cover every tag in tagsToEnforce.
// Otherwise the remediation PATCH will be rejected by the deny rule because some required
// tags will still be missing post-PATCH. We emit this as a deploy-time output so a
// misconfiguration is loud and discoverable.
var _missingDefaultsForRequiredTags = empty(tagDefaults) ? [] : filter(tagsToEnforce, t => !contains(tagDefaults, t))
var _missingDefaultsList = join(_missingDefaultsForRequiredTags, ', ')

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
    description: 'Provides remediation back-fill for existing RGs missing required tags. enforcementMode=DoNotEnforce so new RG creates are NOT silently auto-tagged — the deny on the main assignment still rejects them. Run a single remediation task against the `default-rg-tags` reference to back-fill every missing default tag on every non-compliant RG in one PATCH.'
    policyDefinitionId: initiativeDefaults.id
    enforcementMode: 'DoNotEnforce'
  }
}

// -------- Role assignment for Modify remediation (main assignment) --------
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

// -------- Role assignment for the defaults (remediation) assignment --------

module tagContributorRADefaults 'modules/tagContributorRoleAssignment.mg.bicep' = if (!empty(tagDefaults)) {
  name: 'tagContributorRoleAssignmentDefaults'
  params: {
    #disable-next-line BCP318
    principalId: assignmentDefaults.identity.principalId
  }
}

// -------- Outputs --------

output requireDefId          string = requireDef.id
output inheritDefId          string = inheritDef.id
#disable-next-line BCP318
output defaultDefId          string = !empty(tagDefaults) ? defaultDef.id : ''
output initiativeId          string = initiative.id
output assignmentId          string = assignment.id
output assignmentPrincipal   string = assignment.identity.principalId
output defaultsInitiativeId  string = !empty(tagDefaults) ? initiativeDefaults.id : ''
output defaultsAssignmentId  string = !empty(tagDefaults) ? assignmentDefaults.id : ''
output defaultsCoverageStatus string = empty(tagDefaults)
  ? 'OK: tagDefaults not supplied — defaults assignment skipped.'
  : empty(_missingDefaultsForRequiredTags)
    ? 'OK: tagDefaults covers every tag in tagsToEnforce — remediation will succeed.'
    : 'WARNING: tagDefaults does NOT cover every tag in tagsToEnforce. Remediation tasks will FAIL because the deny rule will reject the PATCH when these tags remain missing post-remediation: ${_missingDefaultsList}. Add defaults for these tags and redeploy.'
