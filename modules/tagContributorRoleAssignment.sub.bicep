// =========================================================================
// Tag Contributor role assignment at subscription scope.
// (Subscription-scope twin of tagContributorRoleAssignment.mg.bicep.)
// =========================================================================

targetScope = 'subscription'

@description('principalId of the assignment\'s system-assigned managed identity.')
param principalId string

var tagContributorRoleDefId = tenantResourceId('Microsoft.Authorization/roleDefinitions', '4a9ae827-6dc8-4573-8ac7-8239d42aa03f')

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, tagContributorRoleDefId)
  properties: {
    roleDefinitionId: tagContributorRoleDefId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
