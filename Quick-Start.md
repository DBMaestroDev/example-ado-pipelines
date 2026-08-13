# Quick Start

Minimal implementation steps. See [`README.md`](./README.md) for full explanations, troubleshooting, and rationale.

## 1. Values to substitute

| Item | Value used in this guide |
|---|---|
| Azure DevOps organization | `dbmsc` |
| Azure DevOps project | `Example` |
| DBmaestro project name | `Example-ADO` |
| Build pipeline (source-control flow) | "Build and Precheck Package - Source Control", definition ID **59** |
| Upgrade pipeline (shared) | "Upgrade Environment", definition ID **60** |
| Ad-hoc build pipeline | "Build with Git Change Detection", definition ID **62** |
| Ad-hoc-triggering folder | `ad-hoc/` |
| Self-hosted agent pool | `dbmaestro-windows` |
| GitHub org hosting `dbmaestro-cicd` (fixed, not yours to change) | `DBMaestroDev` |
| GitHub org hosting `example-ado-pipelines` and `example-ado-source-control` | *your own GitHub org* |
| `dbmaestro-cicd` service connection name | `dbmaestro-cicd` |
| Failure-notification distribution list | `devops@dbmaestro.com` |
| Gate approvers | `approver1@dbmaestro.com`, `approver2@dbmaestro.com` |

## 2. Prerequisites checklist

- [ ] `example-ado-pipelines` copied (e.g. forked) into **your own** GitHub org. Only `dbmaestro-cicd` stays in the `DBMaestroDev` org — this copy is yours.
- [ ] A source-control repo created in that same org for **each individual DBmaestro project** (playing the role of `example-ado-source-control`) — every DBmaestro project needs its own copy of this repo, since a commit there drives that project's own release chain.
- [ ] GitHub service connection "GitHub using Azure Pipelines app", connected to **your own** GitHub org (hosting your `example-ado-pipelines` and `example-ado-source-control` copies). Since both repos live in that same org, this one connection also covers the `adoPipelines`/`sourceControlRepository` cross-repo resource entries — no separate connection needed.
- [ ] GitHub service connection named exactly `dbmaestro-cicd`, authorized against `DBMaestroDev/dbmaestro-cicd`.
- [ ] Self-hosted **Windows** agent registered in the `dbmaestro-windows` pool.
- [ ] PowerShell 7+ (`pwsh`) installed on the agent; restart the agent service after installing.
- [ ] Azure CLI (`az`) installed on the agent; restart the agent service after installing.
- [ ] Java installed on the agent, on PATH; restart the agent service after installing.

## 3. Add the dbmaestro-cicd service connection

1. Project Settings → Service connections → New service connection → GitHub.
2. Authenticate with the GitHub App "Azure Pipelines". If repo-scoped, add `dbmaestro-cicd` to its repository access list first.
3. Name the connection exactly `dbmaestro-cicd`.
4. Check "Grant access permission to all pipelines" (or authorize the build, upgrade, and ad-hoc build pipelines individually afterward).
5. Save.

## 4. Install PowerShell 7 on the agent

```powershell
winget install --id Microsoft.PowerShell
```

Or download the MSI from https://aka.ms/PSWindows. Restart the Azure Pipelines agent service afterward — a service started before the install won't see the new `pwsh` on PATH.

## 5. Install Azure CLI on the agent

```powershell
# MSI installer
Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
Remove-Item .\AzureCLI.msi

# or winget
winget install -e --id Microsoft.AzureCLI
```

Restart the Azure Pipelines agent service afterward.

## 6. Create the build and upgrade pipeline definitions

These are the downstream pipelines the orchestrators queue via `az pipelines run` — they need their own ADO pipeline definitions before anything can be queued against them.

1. Pipelines → New Pipeline → GitHub → select **your own** `example-ado-pipelines` repo.
2. Point it at `build-source-control.yml`. Save. Rename it "Build and Precheck Package - Source Control" (Pipelines → the pipeline → "⋮" → Rename/move) so it matches the rest of this guide.
3. Repeat for `upgrade-environment.yml` → rename to "Upgrade Environment".
4. Repeat for `build-git-changes.yml` → rename to "Build with Git Change Detection".
5. Note each one's definition ID (shown in the pipeline's URL or the Pipelines list) — you'll need them wherever this guide says "59", "60", or "62".

## 7. Configure DBmaestro pipeline variables

Set these as Variables on each of the three pipelines from step 6 (or once in a shared Variable Group — Pipelines → Library → Variable groups — linked to all three):

- [ ] `DBMAESTRO_SERVER` — your DBmaestro server address, format `host:port` (e.g. `dop.dbmaestro.local:8017`), not a URL.
- [ ] `DBMAESTRO_ACCESS_TOKEN_FILE_PATH` — path to the file containing the access token.
- [ ] `useSsl` — not a variable, hardcoded per YAML file: `'False'` by default in `build-source-control.yml`/`upgrade-environment.yml` anb `build-git-changes.yml`. Edit the `useSsl:` line directly if using SSL for the agent. 

## 8. Create the ADO pipeline definitions for the orchestrators

1. Pipelines → New Pipeline → GitHub → select **your own** `example-ado-source-control` repo.
2. Point it at `source-control-workflow.yml`. Save.
3. Repeat for `ad-hoc-workflow.yml` (same repo, same connection) — creates a second, separate pipeline definition.
4. **Customize the `extends: parameters:` block in both thin wrapper YAMLs** (`example-ado-source-control/source-control-workflow.yml` and `example-ado-source-control/ad-hoc-workflow.yml`) for **your** organization and **this** DBmaestro project — none of the values in section 1's table are shared defaults, they're this guide's own example deployment:
   - `targetADOOrganization` / `targetADOProject` → your Azure DevOps org/project.
   - `dBmaestroProjectName` → this DBmaestro project's name.
   - `buildPipelineId` / `upgradePipelineId` / `adHocBuildPipelineId` → the definition IDs noted in step 6.
   - `runnerPool` → your agent pool.
   - `sourceRepoName` / `sourceRepoEndpoint` / `sourceRepoRef` (ad-hoc wrapper only) → your `example-ado-source-control` copy's `org/repo`, service connection name, and branch ref. These are forwarded through to `build-git-changes.yml`'s own `resources.repositories` entry, so it checks out and detects changes against your repo instead of this guide's example.

   Every additional DBmaestro project's own source-control repo needs this same customization done again for its own wrapper files — these values aren't reusable across projects even within the same org.

## 9. Grant queue permissions

Repeat for the "Build and Precheck Package - Source Control", "Upgrade Environment", and "Build with Git Change Detection" pipelines:

1. Open the pipeline → "⋮" → **Security**.
2. Find (or add) the project's Build Service identity (`<project> Build Service (<org>)`).
3. Set **Queue builds** → Allow.
4. Set **Edit queue build configuration** → Allow.
5. Save.

(Or grant both once at the project level: Project Settings → Pipelines → Settings/Security.)

## 10. Create the eight approval-gate environments

For each of `Release-Source-pre-approval`, `Release-Source-post-approval`, `UAT_Env_1-pre-approval`, `UAT_Env_1-post-approval`, `Pre_Prod_Env_1-pre-approval`, `Pre_Prod_Env_1-post-approval`, `Prod_Env_1-pre-approval`, `Prod_Env_1-post-approval`:

1. Pipelines → Environments → New environment.
2. Name it exactly as listed above. Resource: **None**.
3. Create → "⋮" → **Approvals and checks** → Add check → **Approvals**.
4. Add the approver(s) and save.

> **Different names?** Override `releaseSourcePreApprovalEnvironment`/`releaseSourcePostApprovalEnvironment`/`uatEnv1PreApprovalEnvironment`/`uatEnv1PostApprovalEnvironment`/`preProdEnv1PreApprovalEnvironment`/`preProdEnv1PostApprovalEnvironment`/`prodEnv1PreApprovalEnvironment`/`prodEnv1PostApprovalEnvironment` in the wrapper YAML's `extends: parameters:` block — no template edit needed.
>
> **More gates?** (e.g. an extra environment ahead of Prod_Env_1) That does require editing `azure-devops/templates/source-control-workflow.yml`/`ad-hoc-workflow.yml` directly — add a new stage, wire its `dependsOn`, and add a parameter for its environment name. This affects every DBmaestro project's source-control repo that extends the template.

| Environment | Approver |
|---|---|
| `Release-Source-pre-approval` | approver1@dbmaestro.com |
| `Release-Source-post-approval` | approver1@dbmaestro.com |
| `UAT_Env_1-pre-approval` | approver1@dbmaestro.com |
| `UAT_Env_1-post-approval` | approver1@dbmaestro.com |
| `Pre_Prod_Env_1-pre-approval` | approver2@dbmaestro.com |
| `Pre_Prod_Env_1-post-approval` | approver2@dbmaestro.com |
| `Prod_Env_1-pre-approval` | approver2@dbmaestro.com |
| `Prod_Env_1-post-approval` | approver2@dbmaestro.com |

### 10a. First-run resource authorization

The first time a run reaches each environment, open it in the ADO UI and click **Permit** (optionally "Permit for all pipelines"). Expect this once per (pipeline, environment) pair — up to 16 prompts total across both workflows.

## 11. Failure notifications

1. Project Settings → Notifications → New subscription.
2. Category: **Build**. Template: "A build completes."
3. Filter: Definition name = `Build and Precheck Package - Source Control`.
4. Filter: Status = `Failed`.
5. Deliver to → Custom email address → `devops@dbmaestro.com`.
6. Save.

Repeat for `Upgrade Environment` and `Build with Git Change Detection`.

## 12. Done

Push a commit to `example-ado-source-control` with a commit message like `v1.0.1; TaskID: V1.0.1` to trigger the source-control flow, or touch a file under `ad-hoc/` to trigger the ad-hoc flow.
