// =========================================================================
// Tag Contributor role assignment at management-group scope.
//
// This module exists so the policy-assignment's runtime principalId can be
// passed in as a static module parameter and used to compute a deterministic
// (but principal-specific) role-assignment name. That sidesteps Bicep BCP120
// and prevents the RoleAssignmentUpdateNotPermitted error you'd otherwise
// hit when the policy assignment is deleted and recreated with a fresh
// managed-identity principalId.
// =========================================================================

targetScope = 'managementGroup'

@description('principalId of the assignment\'s system-assigned managed identity.')
param principalId string

var tagContributorRoleDefId = tenantResourceId('Microsoft.Authorization/roleDefinitions', '4a9ae827-6dc8-4573-8ac7-8239d42aa03f')

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, principalId, tagContributorRoleDefId)
  properties: {
    roleDefinitionId: tagContributorRoleDefId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
