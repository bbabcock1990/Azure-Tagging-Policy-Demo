# Azure Tagging Policy Demo

A self-contained, demonstration Azure Policy pack that:

1. **Denies** any resource-group create/update missing one or more required tags (or where a required tag has an empty value).
2. **Propagates** each required tag down to every resource inside the RG using the `modify` effect, so child resources automatically inherit whatever tag set you choose to enforce.
3. Returns **per-tag custom error messages** at deployment time that name exactly which tag is missing.

Designed as a starter / teaching example. Bicep-first. No external files required — everything is inlined. The customer/organization name and the list of required tags are both supplied at deploy time — there are no hard-coded defaults baked into the template.

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
| Policy definition | `demo-require-rg-tag` | Single-tag **deny**. Referenced once per tag in `tagsToEnforce`. Not remediable. |
| Policy definition | `demo-inherit-tag-from-rg` | Single-tag **modify** on child resources. Referenced once per tag in `tagsToEnforce`. Remediable. |
| Policy definition | `demo-set-default-rg-tag` | Single-tag **modify** on the RG itself. Referenced once per key in `tagDefaults` (optional). Remediable — use this to back-fill RGs that existed before the policy was assigned. |
| Initiative | `demo-rg-tagging-standard` | Bundles all `require-*`, `inherit-*`, and `default-*` references. |
| Assignment | `demo-rg-tagging-standard` | System-assigned identity. Per-ref non-compliance messages. |
| Role assignment | Tag Contributor at the target scope | Granted to the assignment's managed identity so `modify` remediation can write tags. |

## Sample tag schema

`tagsToEnforce` is a required parameter — you must supply your own list per deploy. The table below is a suggested starter set you can paste into the `--parameters` flag and edit:

| Tag | Example | Purpose |
| --- | --- | --- |
| `Environment` | `prod`, `nonprod`, `dev`, `test` | Lifecycle / blast radius |
| `CostCenter` | `CC-1234` | Finance allocation |
| `Owner` | `cloudops@example.com` | Accountability / paging |
| `Application` | `Billing-API` | Workload mapping |

See [Deploy → Required parameters](#required-parameters) for how to pass this list.

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

### Optional parameter — remediation defaults

| Name | Type | Purpose |
| --- | --- | --- |
| `tagDefaults` | object | Map of tag name → default value. Any tag listed here becomes **remediable**: existing RGs missing that tag can be back-filled with the supplied value via a remediation task. Tags omitted from `tagDefaults` are deny-only (existing non-compliant RGs are flagged but you cannot remediate them automatically). |

> **Why this matters:** Pure `deny` policies cannot be remediated — Azure Policy only supports remediation for `modify` and `deployIfNotExists` effects. So an existing RG that was created before the policy was assigned shows up as non-compliant with no **Create Remediation Task** button available. `tagDefaults` adds a sibling `modify` rule per tag so you can back-fill those RGs.

### Management-group scope (recommended)

**Bash / zsh / Cloud Shell:**

```bash
az deployment mg create \
  --name tagging-demo \
  --management-group-id <your-management-group-id> \
  --location eastus2 \
  --template-file main.bicep \
  --parameters organizationName='Acme Corp' \
               tagsToEnforce='["Environment","CostCenter","Owner","Application"]'
```

**PowerShell (Windows / pwsh):**

```powershell
az deployment mg create `
  --name tagging-demo `
  --management-group-id <your-management-group-id> `
  --location eastus2 `
  --template-file main.bicep `
  --parameters organizationName='Acme Corp' `
               tagsToEnforce='[\"Environment\",\"CostCenter\",\"Owner\",\"Application\"]'
```

> **Shell escaping matters.** In bash the JSON inside single quotes goes through literally, so `"..."` is fine. In PowerShell the parser still touches `"`, so you must escape them as `\"`. Mixing the two is the most common cause of `Failed to parse string as JSON`.

### Subscription scope

**Bash:**

```bash
az deployment sub create \
  --name tagging-demo \
  --subscription <subscriptionId> \
  --location eastus2 \
  --template-file main.sub.bicep \
  --parameters organizationName='Acme Corp' \
               tagsToEnforce='["Environment","CostCenter","Owner","Application"]'
```

**PowerShell:**

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

**Bash:**

```bash
az deployment mg what-if \
  --management-group-id <your-management-group-id> \
  --location eastus2 \
  --template-file main.bicep \
  --parameters organizationName='Acme Corp' \
               tagsToEnforce='["Environment","CostCenter","Owner"]'
```

**PowerShell:**

```powershell
az deployment mg what-if `
  --management-group-id <your-management-group-id> `
  --location eastus2 `
  --template-file main.bicep `
  --parameters organizationName='Acme Corp' `
               tagsToEnforce='[\"Environment\",\"CostCenter\",\"Owner\"]'
```

### Parameters file alternative (shell-agnostic)

If the quoting gymnastics get painful, drop the values into `params.json` and reference it instead — this works identically in bash, PowerShell, and the Azure portal:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "organizationName": { "value": "Acme Corp" },
    "tagsToEnforce":    { "value": ["Environment", "CostCenter", "Owner", "Application"] }
  }
}
```

```bash
az deployment mg create \
  --name tagging-demo \
  --management-group-id <your-management-group-id> \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @params.json
```

## Customize

### Different required tags

Pass any list of tag names. Both the deny rules and the inherit rules are generated from the same array, so the two sides never drift out of sync:

**Bash:**

```bash
az deployment mg create \
  --name tagging-demo \
  --management-group-id <your-management-group-id> \
  --location eastus2 \
  --template-file main.bicep \
  --parameters organizationName='Acme Corp' \
               tagsToEnforce='["Environment","CostCenter","Owner","Application","DataClassification"]'
```

**PowerShell:**

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

**Bash:**

```bash
az deployment mg create \
  --name tagging-demo \
  --management-group-id <your-management-group-id> \
  --location eastus2 \
  --template-file main.bicep \
  --parameters organizationName='Acme Corp' \
               tagsToEnforce='["Environment","CostCenter","Owner"]'
```

**PowerShell:**

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

**Bash:**

```bash
az deployment mg create \
  --name tagging-demo \
  --management-group-id <your-management-group-id> \
  --location eastus2 \
  --template-file main.bicep \
  --parameters organizationName='Acme Corp' \
               tagsToEnforce='["Environment","CostCenter","Owner"]' \
               denyEffect=audit inheritEffect=audit
```

**PowerShell:**

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
# Should be DENIED — one per-tag error message for each tag in tagsToEnforce
az group create -n rg-tagging-demo-bad -l eastus2

# Should SUCCEED. Any resource created inside will inherit these tags via Modify.
# Tag set below assumes you deployed with tagsToEnforce=["Environment","CostCenter","Owner","Application"].
az group create -n rg-tagging-demo-good -l eastus2 `
  --tags Environment=dev CostCenter=CC-1234 Owner=cloudops@example.com Application=Billing-API
```

## Non-compliance message UX

The assignment attaches one message per `require-<TagName>` reference. If a user creates an RG missing every tag in `tagsToEnforce`, they see one distinct message per missing tag. If only one tag is missing, they see one message naming that specific tag.

Example (when `Environment` is missing, deployed with `organizationName='Acme Corp'` and `tagsToEnforce=["Environment","CostCenter","Owner","Application"]`):

> Acme Corp Governance: This resource group is missing the required tag 'Environment'. Every RG must carry these tags with non-empty values: Environment, CostCenter, Owner, Application. Add the missing tag(s) and retry. Child resources will inherit these tags automatically.

## Remediating existing resources

The policy pack creates **two kinds** of compliance findings against your existing estate:

| Finding | Source | Remediable? | What to do |
| --- | --- | --- | --- |
| RG is missing required tag | `require-<TagName>` (deny) | ❌ No (deny effect) | Either edit the RG by hand to add the tag, **or** also supply `tagDefaults` at deploy time and run a remediation task against the matching `default-<TagName>` reference. |
| Child resource is missing a tag the RG has | `inherit-<TagName>` (modify) | ✅ Yes | Run a remediation task against the `inherit-<TagName>` reference. |
| RG is missing a tag listed in `tagDefaults` | `default-<TagName>` (modify) | ✅ Yes | Run a remediation task against the `default-<TagName>` reference — the RG will be tagged with the value you supplied in `tagDefaults`. |

### Deploy with defaults to back-fill existing RGs

```bash
az deployment mg create \
  --name tagging-demo \
  --management-group-id <your-management-group-id> \
  --location eastus2 \
  --template-file main.bicep \
  --parameters organizationName='Acme Corp' \
               tagsToEnforce='["Environment","CostCenter","Owner","Application"]' \
               tagDefaults='{"Environment":"unknown","CostCenter":"CC-0000","Owner":"unassigned@example.com","Application":"unassigned"}'
```

> Only the keys present in `tagDefaults` get a `default-*` reference in the initiative. Keys can be a subset of `tagsToEnforce` if you only want to back-fill some of the required tags.

### Trigger the remediation task

**Portal (easiest):**

1. **Policy → Remediation → Create remediation task**
2. Pick the `demo-rg-tagging-standard` assignment
3. Choose a `default-<TagName>` reference (e.g. `default-Environment`)
4. Scope to the management group or subscription you want to back-fill
5. Repeat per tag (and per `inherit-<TagName>` reference if you also want child-resource back-fill)

**CLI:**

```bash
# Back-fill the 'Environment' tag on every non-compliant RG under the MG
az policy remediation create \
  --name remediate-default-Environment \
  --management-group mg-demo-group \
  --policy-assignment demo-rg-tagging-standard \
  --definition-reference-id default-Environment \
  --resource-discovery-mode ExistingNonCompliant

# Watch progress
az policy remediation show \
  --name remediate-default-Environment \
  --management-group mg-demo-group
```

`--resource-discovery-mode ExistingNonCompliant` only touches resources already evaluated as non-compliant (fast). Use `ReEvaluateCompliance` if you suspect the compliance picture is stale.

### Heads-up on Modify + RG-level deny interaction

When you deploy with both `require-<TagName>` (deny) and `default-<TagName>` (modify) for the same tag:

- **Create / update** of an RG without the tag still gets **denied** at the request layer — modify doesn't pre-empt deny, the deny condition matches first. So users see the rejection message and have to provide the tag themselves on new RGs.
- **Existing** RGs missing the tag stay marked non-compliant, but a remediation task against the `default-*` reference will silently add the default value (no deny happens during a policy-triggered modify operation).

This is the intended Azure Policy behavior — your standards stay enforced at create-time, while back-fill of legacy RGs is opt-in via `tagDefaults`.

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
az policy definition delete --name demo-set-default-rg-tag `
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
- **Modify mode is `Indexed`**, so non-taggable / proxy resource types are not evaluated. This matches Microsoft's own "Inherit tag from RG" built-in policies. The `demo-set-default-rg-tag` definition uses mode `All` because RGs themselves are not in the indexed scope.
- **Deny policies cannot be remediated.** That's why `tagDefaults` exists — it adds a sibling `modify` policy per tag so existing non-compliant RGs can be back-filled. See [Remediating existing resources](#remediating-existing-resources).
- **Initiative param passthrough** (`[parameters('x')]` inside a policy ref) is fragile when authored from Bicep — the value gets baked at deploy time. This template intentionally bakes effects at deploy time and does not expose initiative-level effect parameters. To change effects, redeploy with different parameter values.

## License

MIT. See [LICENSE](./LICENSE).
