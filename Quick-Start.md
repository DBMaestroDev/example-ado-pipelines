# Quick Start

Minimal implementation steps for the **state-based** and **ad-hoc** release workflows.

## 1. Values to substitute

| Item | Value used in this guide |
|---|---|
| Azure DevOps organization | `dbmsc` |
| Azure DevOps project | `Example` |
| DBmaestro project name | `Example-ADO` |
| Self-hosted agent pool | `dbmaestro-windows` |
| GitHub org hosting `example-ado-pipelines` and `example-ado-source-control` | *your own GitHub org* |
| Gate approvers | `approver1@dbmaestro.com`, `approver2@dbmaestro.com` |

## 2. Prerequisites checklist

- [ ] `example-ado-pipelines` copied (e.g. forked) into **your own** GitHub org.
- [ ] A source-control repo created in that same org for **each individual DBmaestro project** (playing the role of `example-ado-source-control`) — every DBmaestro project needs its own copy of this repo, since a commit there drives that project's own release chain.
- [ ] GitHub service connection "GitHub using Azure Pipelines app", connected to **your own** GitHub org (hosting your `example-ado-pipelines` and `example-ado-source-control` copies). Since both repos live in that same org, this one connection also covers the `adoPipelines` cross-repo resource entry in both wrapper files — no separate connection needed.
- [ ] Self-hosted **Windows** agent registered in the `dbmaestro-windows` pool.
- [ ] PowerShell 7+ (`pwsh`) installed on the agent; restart the agent service after installing.
- [ ] Java installed on the agent, on PATH; restart the agent service after installing.

## 3. Install PowerShell 7 on the agent

```powershell
winget install --id Microsoft.PowerShell
```

Or download the MSI from https://aka.ms/PSWindows. Restart the Azure Pipelines agent service afterward — a service started before the install won't see the new `pwsh` on PATH.

## 4. Create the ADO pipeline definitions

1. Pipelines → New Pipeline → GitHub → select **your own** `example-ado-source-control` repo.
2. Point it at `state-based-workflow.yml`. Save.
3. Repeat for `ad-hoc-workflow.yml` (same repo, same connection) — creates a second, separate pipeline definition.
4. **Customize the `extends: parameters:` block in both thin wrapper YAMLs** (`example-ado-source-control/state-based-workflow.yml` and `example-ado-source-control/ad-hoc-workflow.yml`) for **your** organization and **this** DBmaestro project — none of the values in section 1's table are shared defaults, they're this guide's own example deployment:
   - `dBmaestroProjectName` → this DBmaestro project's name.
   - `runnerPool` → your agent pool.
   - `packageName` (ad-hoc wrapper only) — no default; supplied per-run when manually queuing the pipeline for an already-built package.

   Every additional DBmaestro project's own source-control repo needs this same customization done again for its own wrapper files — these values aren't reusable across projects even within the same org.

## 5. Configure DBmaestro pipeline variables

Set these as Variables directly on both the `state-based-workflow.yml` and `ad-hoc-workflow.yml` pipelines (or once in a shared Variable Group — Pipelines → Library → Variable groups — linked to both) — their inline `java -jar` calls reference these variables directly, with no downstream pipeline in between:

- [ ] `DBMAESTRO_SERVER` — your DBmaestro server address, format `host:port` (e.g. `dop.dbmaestro.local:8017`), not a URL.
- [ ] `DBMAESTRO_ACCESS_TOKEN_FILE_PATH` — path to the file containing the access token.

## 6. Create the five approval-gate environments

For each of `Release-Source-pre-approval`, `UAT_Env_1-pre-approval`, `Pre_Prod_Env_1-pre-approval`, `Prod_Env_1-pre-approval`, `Prod_Env_1-review-package`:

1. Pipelines → Environments → New environment.
2. Name it exactly as listed above. Resource: **None**.
3. Create → "⋮" → **Approvals and checks** → Add check → **Approvals**.
4. Add the approver(s) and save.

`ad-hoc-workflow.yml` only uses the four pre-approval gates. `state-based-workflow.yml` uses all five — it reuses the same four pre-approval environments, plus its own `Prod_Env_1-review-package` gate before the final upgrade.

> **Different names?** Override `releaseSourcePreApprovalEnvironment`/`uatEnv1PreApprovalEnvironment`/`preProdEnv1PreApprovalEnvironment`/`prodEnv1PreApprovalEnvironment`/`prodEnv1ReviewPackageEnvironment` in the wrapper YAML's `extends: parameters:` block — no template edit needed.
>
> **More gates?** (e.g. an extra environment ahead of Prod_Env_1) That does require editing `azure-devops/templates/state-based-workflow.template.yml`/`ad-hoc-workflow.template.yml` directly — add a new stage, wire its `dependsOn`, and add a parameter for its environment name. This affects every DBmaestro project's source-control repo that extends the template.

| Environment | Approver |
|---|---|
| `Release-Source-pre-approval` | approver1@dbmaestro.com |
| `UAT_Env_1-pre-approval` | approver1@dbmaestro.com |
| `Pre_Prod_Env_1-pre-approval` | approver2@dbmaestro.com |
| `Prod_Env_1-pre-approval` | approver2@dbmaestro.com |
| `Prod_Env_1-review-package` | approver2@dbmaestro.com |

### 6a. First-run resource authorization

The first time a run reaches each environment, open it in the ADO UI and click **Permit** (optionally "Permit for all pipelines"). Expect this once per (pipeline, environment) pair — up to 9 prompts total (4 for `ad-hoc-workflow.yml`, 5 for `state-based-workflow.yml`).

## 7. Done

Push a commit to `example-ado-source-control` to trigger the state-based flow (pushes that only touch a root-level pipeline YAML don't trigger it). To run the ad-hoc flow, manually queue the `ad-hoc-workflow.yml` pipeline and supply `packageName` for an already-built package (or let the DBmaestro DOP hook queue it for you — see `ad-hoc-workflow.md`).
