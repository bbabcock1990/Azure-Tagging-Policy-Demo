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
| Policy definition | `demo-set-default-rg-tags` *(only if `tagDefaults` is supplied)* | Multi-tag **modify** on the RG itself. Bakes one operation per key in `tagDefaults` so a single PATCH adds every missing default tag atomically (see [Remediating existing resources](#remediating-existing-resources) for the why). Uses operation `add`, so existing non-empty tag values are NEVER overwritten. |
| Initiative | `demo-rg-tagging-standard` | Bundles all `require-*` and `inherit-*` references. Enforces deny + propagation at request time. |
| Initiative | `demo-rg-tagging-defaults` *(only if `tagDefaults` is supplied)* | Contains exactly ONE reference (`default-rg-tags`) to the multi-tag defaults policy. Used for remediation only. |
| Assignment | `demo-rg-tagging-standard` (`enforcementMode: Default`) | System-assigned identity. Per-ref non-compliance messages on each `require-*`. |
| Assignment | `demo-rg-tagging-defaults` (`enforcementMode: DoNotEnforce`) *(only if `tagDefaults` is supplied)* | System-assigned identity. Does NOT mutate request-time — deny on the main assignment still wins. Run ONE remediation task against the `default-rg-tags` reference to back-fill missing tags on existing RGs. |
| Role assignment | Tag Contributor at the target scope | Granted to each assignment's managed identity so `modify` remediation can write tags. |

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

You can deploy this two ways:

1. **From your local machine** with the Azure CLI installed — run the commands in the [CLI examples below](#management-group-scope-recommended).
2. **From the Azure Portal Cloud Shell** — nothing to install locally, the Azure CLI and Bicep are already there. Follow the [Cloud Shell walk-through](#deploy-via-azure-cloud-shell-portal-walk-through).

If you're going local:

```powershell
# Sign in
az login

# Make sure Bicep is installed / up to date
az bicep upgrade
```

### Deploy via Azure Cloud Shell (Portal walk-through)

If you'd rather not install anything locally, the Azure Portal ships a browser-based shell with `az` and Bicep already on the PATH. Here's the full path from "I have a portal login" to "policy is deployed and a remediation task is running."

#### 1. Open Cloud Shell

1. Sign in to <https://portal.azure.com>.
2. Click the **`>_`** Cloud Shell icon in the top-right toolbar (next to the search bar / bell), **or** browse straight to <https://shell.azure.com>.
3. When prompted, pick **Bash** (recommended — the rest of this walk-through uses bash quoting). You can switch later with `pwsh` / `bash`.
4. First-run only: Cloud Shell asks you to create a small storage account for your `$HOME`. Pick any subscription and accept the defaults — it costs cents/month and persists your files across sessions.

#### 2. Confirm tools

The CLI and Bicep are already installed. Verify and refresh if needed:

```bash
az version                 # azure-cli should be present
az bicep version           # bicep should be present; if not:
az bicep install           # one-time install (Cloud Shell is read-only for some paths but this works in $HOME)
```

#### 3. Pull the repo into Cloud Shell

You have two options. Pick whichever is easier:

**Option A — `git clone` directly into your Cloud Shell `$HOME`** (recommended; lets you `git pull` updates later):

```bash
git clone https://github.com/bbabcock1990/Azure-Tagging-Policy-Demo.git
cd Azure-Tagging-Policy-Demo
ls
# main.bicep  main.sub.bicep  modules/  README.md  LICENSE
```

**Option B — upload the files via the Cloud Shell toolbar:**

1. In Cloud Shell, click the **upload/download** icon (the page-with-arrow icon in the toolbar) → **Upload**.
2. Upload `main.bicep` (or `main.sub.bicep`) **and** the entire `modules/` folder. The Cloud Shell uploader takes one file at a time, so for `modules/` zip it locally first, upload the zip, then `unzip modules.zip` in Cloud Shell.
3. `cd` into whichever directory you uploaded the files into.

> Cloud Shell's `$HOME` is mounted from your file-share storage account, so anything you upload or clone stays put across browser sessions.

#### 4. Pick your target scope and grab its ID

This template is designed for management-group scope. List the MGs you have access to:

```bash
az account management-group list -o table
# Name             DisplayName       Id
# ---------------  ----------------  ------------------------------------------------------------
# mg-demo-group    Demo Group        /providers/Microsoft.Management/managementGroups/mg-demo-group
# tenant-root      Tenant Root       /providers/Microsoft.Management/managementGroups/<tenant-id>
```

The `--management-group-id` flag on the deploy command takes the short **Name** (left column), e.g. `mg-demo-group` — not the full resource ID.

If you'd rather scope to a single subscription, list them with `az account list -o table` and copy the `SubscriptionId` for the [Subscription-scope command](#subscription-scope) instead.

#### 5. Make sure you're targeting the right tenant / subscription

```bash
az account show -o table
# If wrong, switch:
az account set --subscription "<subscription-name-or-id>"
```

(Cloud Shell uses the subscription tied to your file-share by default — that may not be where you want to deploy.)

#### 6. Run the deployment

Replace `mg-demo-group`, `organizationName`, and the tag lists with your values. **In bash inside Cloud Shell, single-quote the JSON literally — don't escape the double quotes.** (PowerShell would need `\"…\"`; bash doesn't.)

```bash
az deployment mg create \
  --name tagging-demo \
  --management-group-id mg-demo-group \
  --location eastus2 \
  --template-file main.bicep \
  --parameters organizationName='Acme Corp' \
               tagsToEnforce='["Environment","CostCenter","Owner","Application"]' \
               tagDefaults='{"Environment":"unknown","CostCenter":"CC-0000","Owner":"unassigned@example.com","Application":"unassigned"}'
```

The first deploy takes ~30-60 seconds. You'll see a JSON blob with `"provisioningState": "Succeeded"` at the end.

> **Preview-first?** Replace `create` with `what-if` to see exactly which definitions, initiatives, assignments, and role assignments will be created/changed before you commit.

#### 7. Verify the deployment outputs

```bash
# Coverage check — must say OK, otherwise remediation will 403
az deployment mg show \
  --name tagging-demo \
  --query "properties.outputs.defaultsCoverageStatus.value" -o tsv
# OK: tagDefaults covers every tag in tagsToEnforce — remediation will succeed.

# See every output the template emitted (initiative ID, assignment ID, principal ID, etc.)
az deployment mg show \
  --name tagging-demo \
  --query "properties.outputs" -o json
```

If `defaultsCoverageStatus` prints a `WARNING:` line, add the missing tag(s) to `tagDefaults` and redeploy before running remediation.

#### 8. Smoke-test the deny rule

```bash
# Should be DENIED with one message per missing tag
az group create -n rg-tagging-demo-bad -l eastus2

# Should SUCCEED — child resources will inherit these tags via Modify
az group create -n rg-tagging-demo-good -l eastus2 \
  --tags Environment=dev CostCenter=CC-1234 Owner=cloudops@example.com Application=Billing-API
```

The deny error appears inline in the Cloud Shell output — copy/paste the message into your demo if you want to show what the end-user sees.

#### 9. Back-fill existing RGs with one remediation task

```bash
az policy remediation create \
  --name remediate-default-rg-tags \
  --management-group mg-demo-group \
  --policy-assignment demo-rg-tagging-defaults \
  --definition-reference-id default-rg-tags \
  --resource-discovery-mode ExistingNonCompliant

# Watch progress
az policy remediation show \
  --name remediate-default-rg-tags \
  --management-group mg-demo-group \
  --query "{state:provisioningState, deployments:deploymentStatus}" -o json
```

`Succeeded` with a non-zero `successfulDeployments` count means existing non-compliant RGs picked up every default tag in a single PATCH. (See [Remediating existing resources](#remediating-existing-resources) for the design rationale.)

#### 10. Tear it down when the demo is over

Jump to the [Cleanup](#cleanup) section — every command runs in the same Cloud Shell session.

> **Cloud Shell session tips:**
> - Cloud Shell idles out after ~20 minutes of inactivity. Your files persist; you just lose any unsaved shell state.
> - Use the **font-size** / **paste-as-plain-text** controls in the toolbar if your demo screen is being projected.
> - The **download** option in the upload/download menu can pull the compiled `main.json` (after `az bicep build -f main.bicep`) back to your laptop if you need to attach it to a change ticket.

### Required parameters

Two parameters are **required** on every deploy — there are no defaults:

| Name | Type | Purpose |
| --- | --- | --- |
| `organizationName` | string | Used in every policy / initiative / assignment display name, description, metadata owner, and non-compliance message. Sets the prefix the user sees in the Azure portal (e.g. `Acme Corp - RG Tagging Standard (Assignment)`). |
| `tagsToEnforce` | array | List of tag *names* that must be present (non-empty) on every RG. Each tag also gets a `Modify` rule that copies it down to child resources. |

### Optional parameter — remediation defaults

| Name | Type | Purpose |
| --- | --- | --- |
| `tagDefaults` | object | Map of tag name → default value used to back-fill existing RGs that are missing required tags. Supply one entry **per tag in `tagsToEnforce`** (see [Remediating existing resources](#remediating-existing-resources) for why coverage matters). Leave empty (`{}`) to skip the defaults assignment entirely — the deny rule still flags non-compliant RGs but you'll have to add tags manually. The defaults policy uses operation `add`, so existing non-empty tag values are NEVER overwritten. |

> **Why this matters:** Pure `deny` policies cannot be remediated — Azure Policy only supports remediation for `modify` and `deployIfNotExists` effects. So an existing RG that was created before the policy was assigned shows up as non-compliant with no **Create Remediation Task** button available. `tagDefaults` adds a sibling multi-tag `modify` policy (`default-rg-tags`) in a separate `DoNotEnforce` assignment so you can back-fill those RGs in a single PATCH per RG.

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

The policy pack creates **three kinds** of compliance findings against your existing estate:

| Finding | Source | Assignment | Remediable? | What to do |
| --- | --- | --- | --- | --- |
| RG is missing a required tag | `require-<TagName>` (deny) | `demo-rg-tagging-standard` | ❌ No (deny effect) | Either edit the RG by hand to add the tag, **or** supply `tagDefaults` at deploy time and run the single `default-rg-tags` remediation task (see below). |
| Child resource is missing a tag the RG has | `inherit-<TagName>` (modify) | `demo-rg-tagging-standard` | ✅ Yes | Run a remediation task against the `inherit-<TagName>` reference. |
| RG is missing one or more tags listed in `tagDefaults` | `default-rg-tags` (multi-tag modify) | `demo-rg-tagging-defaults` *(separate)* | ✅ Yes | Run **ONE** remediation task against `default-rg-tags` — the single PATCH adds **every** missing default tag at once. |

> The `default-*` policy lives in a **separate** assignment (`demo-rg-tagging-defaults`) with `enforcementMode: DoNotEnforce`. See [How defaults and deny coexist](#how-defaults-and-deny-coexist) below for why.

### ⚠️ `tagDefaults` must cover EVERY tag in `tagsToEnforce`

If you supply `tagDefaults` for only some of the tags in `tagsToEnforce`, **remediation will fail** with `403 Forbidden`. The Modify PATCH adds only the tags you defaulted; the deny rule then re-evaluates the post-PATCH RG, sees the other required tags still missing, and rejects the entire PATCH.

The Bicep template emits a `defaultsCoverageStatus` output that flags this misconfiguration loudly:

```bash
az deployment mg show --name <deployment-name> --query "properties.outputs.defaultsCoverageStatus.value" -o tsv
# OK: tagDefaults covers every tag in tagsToEnforce — remediation will succeed.
# (or a WARNING listing the missing default values)
```

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

> Every key in `tagsToEnforce` should have a matching entry in `tagDefaults` (same names, your choice of values). Extra keys in `tagDefaults` not in `tagsToEnforce` are also fine — they're tagged but not enforced.

### Trigger the remediation task — ONE task patches ALL missing tags

**Portal (easiest):**

1. **Policy → Remediation → Create remediation task**
2. Pick the **`demo-rg-tagging-defaults`** assignment (NOT the `-standard` one — defaults live in their own assignment)
3. Choose the **`default-rg-tags`** reference (there is only one — it's the multi-tag policy)
4. Scope to the management group or subscription you want to back-fill
5. Run it. The single PATCH on each non-compliant RG adds every missing default tag at once.

**CLI:**

```bash
# Back-fill all default tags on every non-compliant RG under the MG (one task does it all)
az policy remediation create \
  --name remediate-default-rg-tags \
  --management-group mg-demo-group \
  --policy-assignment demo-rg-tagging-defaults \
  --definition-reference-id default-rg-tags \
  --resource-discovery-mode ExistingNonCompliant

# Watch progress
az policy remediation show \
  --name remediate-default-rg-tags \
  --management-group mg-demo-group
```

`--resource-discovery-mode ExistingNonCompliant` only touches resources already evaluated as non-compliant (fast). Use `ReEvaluateCompliance` if you suspect the compliance picture is stale.

### Why one multi-tag policy (not N single-tag policies)

The companion deny rule blocks any write to an RG that leaves **any** required tag missing. The remediation engine PATCHes RGs to apply Modify operations. If we had N single-tag default policies, each remediation PATCH would add only ONE tag — leaving the other required tags still missing — and the deny rule would reject every such PATCH with `403 Forbidden, missing required tag X`. We hit exactly this failure mode in an earlier iteration and consolidated.

A single multi-operation Modify policy sidesteps this: one PATCH adds every missing default tag atomically. Post-PATCH the RG has every required tag, the deny re-evaluation passes, and remediation succeeds.

The trade-off: the policy uses operation `add` (not `addOrReplace`), so it's a no-op when the tag already exists — existing non-empty values are never clobbered. The flip side is that **tags present with an empty-string value** are not remediated by this design (Azure Policy doesn't allow `field()` in operation conditions, so we can't selectively `addOrReplace` only the empty ones without overwriting valid neighbors). Empty-string tags are an edge case in practice; manual fix-up is required if you hit them.

### How defaults and deny coexist

Azure Policy evaluates effects in this order at **request time**: `Disabled → Append/Modify → Audit → Deny`. If we bundled the default-`*` modify into the same assignment as `require-*` deny, the modify would fire first and silently inject the default tag into a brand-new RG-create request — **the deny would never reject it**. That defeats the whole point of the deny.

To prevent that, the `default-rg-tags` policy lives in a **separate assignment** (`demo-rg-tagging-defaults`) with **`enforcementMode: 'DoNotEnforce'`**:

| Scenario | What happens |
| --- | --- |
| `az group create` with no tags | Main assignment's deny fires and rejects the request. The defaults assignment's modify is **skipped** (DoNotEnforce). The user sees the rejection message and must supply tags themselves. |
| Existing RG missing the tag | Both assignments mark it non-compliant. Manual remediation task against `default-rg-tags` (on the defaults assignment) back-fills every missing default in a single PATCH — DoNotEnforce does NOT block remediation tasks, only request-time enforcement. |

This is the only way to get "deny wins on create, but I can still remediate existing RGs" — Azure Policy doesn't expose per-reference enforcement overrides, so two assignments are required.

## Cleanup

```bash
MG=<your-management-group-id>

# Delete the assignments first (releases their managed identities)
az policy assignment delete --name demo-rg-tagging-standard \
  --scope /providers/Microsoft.Management/managementGroups/$MG
az policy assignment delete --name demo-rg-tagging-defaults \
  --scope /providers/Microsoft.Management/managementGroups/$MG

# Then the initiatives
az policy set-definition delete --name demo-rg-tagging-standard \
  --management-group $MG
az policy set-definition delete --name demo-rg-tagging-defaults \
  --management-group $MG

# Then the policy definitions
az policy definition delete --name demo-require-rg-tag \
  --management-group $MG
az policy definition delete --name demo-inherit-tag-from-rg \
  --management-group $MG
az policy definition delete --name demo-set-default-rg-tags \
  --management-group $MG

# If you previously deployed an older single-tag default policy named
# 'demo-set-default-rg-tag' (singular), delete it manually — newer deploys
# do not reference it and Bicep will not remove orphaned resources.
az policy definition delete --name demo-set-default-rg-tag \
  --management-group $MG 2>/dev/null || true
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
- **Modify mode is `Indexed`**, so non-taggable / proxy resource types are not evaluated. This matches Microsoft's own "Inherit tag from RG" built-in policies. The `demo-set-default-rg-tags` definition uses mode `All` because RGs themselves are not in the indexed scope.
- **Deny policies cannot be remediated.** That's why `tagDefaults` exists — it adds a sibling multi-tag `modify` policy so existing non-compliant RGs can be back-filled. See [Remediating existing resources](#remediating-existing-resources).
- **Modify-before-Deny precedence.** This is the reason `default-rg-tags` lives in a separate `DoNotEnforce` assignment, not bundled with the deny initiative. Bundling them would let modify silently auto-tag new RGs and bypass the deny rule. See [How defaults and deny coexist](#how-defaults-and-deny-coexist).
- **Deny rule blocks remediation PATCHes too.** If you deploy `tagDefaults` for only some of `tagsToEnforce`, remediation will fail with `403 Forbidden, missing required tag X` because the deny rule re-evaluates after the PATCH and sees other required tags still missing. The single multi-tag defaults policy + the deploy-time `defaultsCoverageStatus` output guard against this — make sure `tagDefaults` covers every tag in `tagsToEnforce`.
- **Empty-string tag values are not remediated.** The defaults policy uses operation `add` (not `addOrReplace`) so existing non-empty values are never overwritten — but `add` is also a no-op when the tag exists with an empty value. Manual fix-up is required for RGs with `Tag=""`. Operation-level conditions in Azure Policy can't use `field()`, so there's no way to selectively `addOrReplace` only the empty-valued tags without risking overwriting neighbors.
- **Initiative param passthrough** (`[parameters('x')]` inside a policy ref) is fragile when authored from Bicep — the value gets baked at deploy time. This template intentionally bakes effects at deploy time and does not expose initiative-level effect parameters. To change effects, redeploy with different parameter values.

## License

MIT. See [LICENSE](./LICENSE).
