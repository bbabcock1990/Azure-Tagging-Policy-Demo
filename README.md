# Azure Tagging Policy Demo

A self-contained, demonstration Azure Policy pack that:

1. **Denies** any resource-group create/update missing one or more required tags (or where a required tag has an empty value).
2. **Propagates** each required tag down to every resource inside the RG using the `modify` effect, so child resources automatically inherit `Environment`, `CostCenter`, `Owner`, `Application` (configurable).
3. Returns **per-tag custom error messages** at deployment time that name exactly which tag is missing.

Designed as a starter / teaching example. Bicep-first. No external files required — everything is inlined.

## Files

| File | Purpose |
| --- | --- |
| `main.bicep` | **Recommended.** End-to-end deployment at **management-group** scope. |
| `main.sub.bicep` | End-to-end deployment at **subscription** scope. Identical resource graph. |
| `modules/tagContributorRoleAssignment.mg.bicep` | Sub-module used by `main.bicep`. Creates the Tag Contributor role assignment for the policy assignment's managed identity at MG scope. |
| `modules/tagContributorRoleAssignment.sub.bicep` | Sub-module used by `main.sub.bicep`. Same idea, subscription scope. |
| `README.md` | This file. |
| `LICENSE` | MIT license. |

> Copy the **entire folder** (including `modules/`) to your dev box — `main.bicep` references the sub-module at deploy time.

## What gets deployed

| Resource | Name | Notes |
| --- | --- | --- |
| Policy definition | `demo-require-rg-tag` | Single-tag deny. Referenced N times in the initiative (one per required tag). |
| Policy definition | `demo-inherit-tag-from-rg` | Single-tag `modify`. Referenced N times in the initiative. |
| Initiative | `demo-rg-tagging-standard` | Bundles all `require-*` and `inherit-*` references. |
| Assignment | `demo-rg-tagging-standard` | System-assigned identity. Per-ref non-compliance messages. |
| Role assignment | Tag Contributor at the target scope | Granted to the assignment's managed identity so `modify` remediation can write tags. |

## Required tags (defaults)

| Tag | Example | Purpose |
| --- | --- | --- |
| `Environment` | `prod`, `nonprod`, `dev`, `test` | Lifecycle / blast radius |
| `CostCenter` | `CC-1234` | Finance allocation |
| `Owner` | `cloudops@example.com` | Accountability / paging |
| `Application` | `Billing-API` | Workload mapping |

Override the tag list at deploy time via the `tagsToEnforce` parameter (see below).

## Why single-tag policies + a looped initiative?

Azure Policy does **not** allow runtime functions like `current()` inside `field()`. The cleanest, fully supported pattern (mirroring Microsoft's built-ins) is to define one **single-tag** deny policy and one **single-tag** inherit policy, then reference each once per required tag inside the initiative. The Bicep handles the looping for you.

## Permissions to deploy

At the target scope you need:

- `Resource Policy Contributor` (or `Owner`) — to create the definitions and the assignment.
- `User Access Administrator` (or `Owner`) — so the assignment's system-assigned managed identity can be granted **Tag Contributor**, which `modify` policies need to write tags.

## Deploy

### Prerequisites

```powershell
# Sign in
az login

# Make sure Bicep is installed
az bicep upgrade
```

### Required parameters

Two parameters are **required** on every deploy — there are no defaults:

| Name | Type | Purpose |
| --- | --- | --- |
| `organizationName` | string | Used in every policy / initiative / assignment display name, description, metadata owner, and non-compliance message. Sets the prefix the user sees in the Azure portal (e.g. `Acme Corp - RG Tagging Standard (Assignment)`). |
| `tagsToEnforce` | array | List of tag *names* that must be present (non-empty) on every RG. Each tag also gets a `Modify` rule that copies it down to child resources. |

### Management-group scope (recommended)

```powershell
az deployment mg create `
  --name tagging-demo `
  --management-group-id <your-management-group-id> `
  --location eastus2 `
  --template-file main.bicep `
  --parameters organizationName='Acme Corp' `
               tagsToEnforce='[\"Environment\",\"CostCenter\",\"Owner\",\"Application\"]'
```

### Subscription scope

```powershell
az deployment sub create `
  --name tagging-demo `
  --subscription <subscriptionId> `
  --location eastus2 `
  --template-file main.sub.bicep `
  --parameters organizationName='Acme Corp' `
               tagsToEnforce='[\"Environment\",\"CostCenter\",\"Owner\",\"Application\"]'
```

### What-if (preview before deploying)

```powershell
az deployment mg what-if `
  --management-group-id <your-management-group-id> `
  --location eastus2 `
  --template-file main.bicep `
  --parameters organizationName='Acme Corp' `
               tagsToEnforce='[\"Environment\",\"CostCenter\",\"Owner\"]'
```

## Customize

### Different required tags

Pass any list of tag names. Both the deny rules and the inherit rules are generated from the same array, so the two sides never drift out of sync:

```powershell
az deployment mg create `
  --name tagging-demo `
  --management-group-id <your-management-group-id> `
  --location eastus2 `
  --template-file main.bicep `
  --parameters organizationName='Acme Corp' `
               tagsToEnforce='[\"Environment\",\"CostCenter\",\"Owner\",\"Application\",\"DataClassification\"]'
```

### Rebrand for a specific organization

`organizationName` flows into every visible string. Override it per customer so e.g. the assignment shows up as `"Acme Corp - RG Tagging Standard (Assignment)"` and the deny message reads `"Acme Corp Governance: This resource group is missing the required tag 'Environment'..."`:

```powershell
az deployment mg create `
  --name tagging-demo `
  --management-group-id <your-management-group-id> `
  --location eastus2 `
  --template-file main.bicep `
  --parameters organizationName='Acme Corp' `
               tagsToEnforce='[\"Environment\",\"CostCenter\",\"Owner\"]'
```

### Soft rollout (audit, not deny)

```powershell
az deployment mg create `
  --name tagging-demo `
  --management-group-id <your-management-group-id> `
  --location eastus2 `
  --template-file main.bicep `
  --parameters organizationName='Acme Corp' `
               tagsToEnforce='[\"Environment\",\"CostCenter\",\"Owner\"]' `
               denyEffect=audit inheritEffect=audit
```

Recommended rollout path:

1. Deploy with `denyEffect=audit` and `inheritEffect=audit` to a non-prod MG.
2. Wait 1-2 weeks. Review the Policy compliance blade. Fix any noisy RGs.
3. Redeploy with `denyEffect=deny` and `inheritEffect=modify`.
4. Trigger a **remediation task** for each `inherit-<TagName>` reference so existing child resources pick up the RG tags (Portal → Policy → Remediation).
5. Promote up the management-group hierarchy (nonprod → prod).

## Test

```powershell
# Should be DENIED (4 per-tag error messages — one for each missing tag)
az group create -n rg-tagging-demo-bad -l eastus2

# Should SUCCEED. Any resource created inside will inherit these tags via Modify.
az group create -n rg-tagging-demo-good -l eastus2 `
  --tags Environment=dev CostCenter=CC-1234 Owner=cloudops@example.com Application=Billing-API
```

## Non-compliance message UX

The assignment attaches one message per `require-<TagName>` reference. If a user creates an RG missing all four tags, they see four distinct messages — one for each missing tag. If only one tag is missing, they see one message naming that specific tag.

Example (when `Environment` is missing):

> This resource group is missing the required tag 'Environment'. Every RG must carry these tags with non-empty values: Environment, CostCenter, Owner, Application. Add the missing tag(s) and retry. Child resources will inherit these tags automatically.

## Remediating existing resources

The `modify` effect auto-applies to **new** child resources. To back-fill existing child resources:

1. Portal → **Policy** → **Remediation**.
2. Find the `demo-rg-tagging-standard` assignment.
3. Create one remediation task per `inherit-<TagName>` reference (one each for Environment, CostCenter, Owner, Application by default).

## Cleanup

```powershell
# Delete the assignment first (releases the managed identity)
az policy assignment delete --name demo-rg-tagging-standard `
  --scope /providers/Microsoft.Management/managementGroups/<your-management-group-id>

# Then the initiative
az policy set-definition delete --name demo-rg-tagging-standard `
  --management-group <your-management-group-id>

# Then the policy definitions
az policy definition delete --name demo-require-rg-tag `
  --management-group <your-management-group-id>
az policy definition delete --name demo-inherit-tag-from-rg `
  --management-group <your-management-group-id>
```

## Known gotchas

- **Empty tag values** are now rejected by the deny rule (`exists:false` OR `equals:''`), so `--tags Environment=` no longer bypasses the policy.
- **`modify` requires Tag Contributor** on the assignment's identity. This template grants it automatically. The role-assignment name is derived from the managed-identity `principalId` (lifted via a Bicep module), so if you delete and recreate the policy assignment, a **new** role assignment is created and the old one is left orphaned. Clean up orphans periodically:
  ```powershell
  az role assignment list `
    --scope /providers/Microsoft.Management/managementGroups/<your-mg-id> `
    --role "Tag Contributor" `
    --query "[?principalId!='<current-pid>'].id" -o tsv | `
    ForEach-Object { az role assignment delete --ids $_ }
  ```
- **Modify mode is `Indexed`**, so non-taggable / proxy resource types are not evaluated. This matches Microsoft's own "Inherit tag from RG" built-in policies.
- **Initiative param passthrough** (`[parameters('x')]` inside a policy ref) is fragile when authored from Bicep — the value gets baked at deploy time. This template intentionally bakes effects at deploy time and does not expose initiative-level effect parameters. To change effects, redeploy with different parameter values.

## License

MIT. See [LICENSE](./LICENSE).
