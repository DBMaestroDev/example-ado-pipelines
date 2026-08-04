# GitHub Commit to Production: Full Release Workflow

*Setup runbook — example-ado-source-control → Build → Integration → Production, with approval gates and failure notification*

## 1. Goal

On every commit to the `example-ado-source-control` GitHub repository, automatically: build a DBmaestro package, gate on manual approval, upgrade the integration environment, gate on manual confirmation, gate on manual approval again, upgrade the production environment, and gate on a final manual confirmation. Values are parsed from the commit message rather than entered by hand.

There's a second, separate workflow covered later in this guide (section 14) for **ad-hoc** package builds: commits that only touch the `ad-hoc/` folder skip all of this — no TaskID convention, no approval gates, no environment upgrade — and instead just build whatever changed via git-diff detection.

## 2. Why a direct trigger doesn't work

Azure Pipelines' repository resource trigger (`resources.repositories[].trigger`) only fires for Azure Repos Git repositories, never for GitHub (or Bitbucket) resources — a structural limitation independent of the service connection or auth method used.

The workaround is a pipeline whose own source repository is `example-ado-source-control`. Because it's the pipeline's self repo, GitHub push triggers work natively (the existing "GitHub using Azure Pipelines app" service connection manages the webhook automatically). This pipeline reads the triggering commit, extracts parameters, and orchestrates the rest of the workflow by queuing the other pipelines via the Azure DevOps CLI/REST API.

## 3. Prerequisites

> **A note on specific values below:** this guide documents one real deployment, so it names concrete values throughout (an org, a project, two pipeline definition IDs, a pool name, and so on). None of these are requirements of the design — they're just what this instance happens to use. Your organization/project names will differ, and **pipeline definition IDs in particular are assigned automatically by Azure DevOps** the first time each pipeline is created (step 8) — you can't choose or predict them in advance. Substitute your own values throughout; the table below is the full list of what to swap.

| Item | Value used in this guide |
|---|---|
| Azure DevOps organization | `dbmsc` |
| Azure DevOps project (where the build/upgrade pipelines live) | `Example` |
| DBmaestro project name (`projectName` parameter — a separate, unrelated concept, see naming heads-up below) | `Example-ADO` |
| Build pipeline | "Build and Precheck Package - Source Control", definition ID **59** |
| Upgrade pipeline | "Upgrade Environment", definition ID **60** |
| Ad-hoc build pipeline (section 14) | "Build with Git Change Detection", definition ID **62** |
| Ad-hoc-triggering folder | `ad-hoc/` |
| Self-hosted agent pool | `dbmaestro-windows` |
| GitHub org (source repos + `dbmaestro-cicd` templates) | `DBMaestroDev` |
| `dbmaestro-cicd` service connection name | `dbmaestro-cicd` |
| Failure-notification distribution list | `devops@dbmaestro.com` |
| Gate approvers | `approver1@dbmaestro.com`, `approver2@dbmaestro.com` |

- GitHub service connection **"GitHub using Azure Pipelines app"**, connected to the DBMaestroDev GitHub org.
- Pipeline **"Build and Precheck Package - Source Control"** — org `dbmsc`, project `Example`, definition ID **59**. `packageName` has no default, so it's always required. `tasksList` technically has a default (`'none'`), but the pipeline's own validation step fails the run if `buildType` is left at its default (`'Specific Tasks'`) and `tasksList` is `'none'`/empty — so in practice both `packageName` and `tasksList` must be supplied. This workflow sets both to the extracted TaskID.
- Pipeline **"Upgrade Environment"** — org `dbmsc`, project `Example`, definition ID **60**. All of its parameters (`targetEnvironment`, `packageNames`, `tagName`, `projectName`, `agentJarPath`, `runnerPool`) have defaults; the workflow explicitly sets `targetEnvironment`, `packageNames`, and `runnerPool`. `targetEnvironment` only accepts `'Integration'` or `'Production'` (case-sensitive, `'qa'` was dropped) — the orchestrator must pass those exact strings.
- Pipeline **"Build with Git Change Detection"** (`build-git-changes.yml`) — org `dbmsc`, project `Example`, definition ID **62**. Unrelated to the TaskID flow above — see section 14. All of its parameters already have defaults tuned for this setup (`packagesFolder: 'ad-hoc'`, `baseBranch: 'main'`), so it can be queued with no required overrides.
- A GitHub service connection named exactly **`dbmaestro-cicd`**, authorized in this project and pointed at `DBMaestroDev/dbmaestro-cicd`. Both `build-source-control.yml` and `upgrade-environment.yml` declare this as a second `resources.repositories` entry (`endpoint: dbmaestro-cicd`) so they can check out DBmaestro's reusable pipeline templates. Without this exact-named, authorized connection, both pipelines fail immediately with `Repository dbmaestro-cicd references endpoint dbmaestro-cicd which does not exist or is not authorized for use` — see section 7.
- A registered self-hosted **Windows** agent in the **`dbmaestro-windows`** pool, with **PowerShell 7+ (`pwsh`)** installed. All three pipelines run on this one pool now — the orchestrator's jobs directly (`pool: dbmaestro-windows`), and pipelines 59/60 via their `runnerPool` parameter, which defaults to `'dbmaestro-windows'` and is also explicitly passed by the orchestrator (`downstreamRunnerPool` variable). **PowerShell 7+ is a hard requirement, not a fallback-able one:** every Windows-path step in the `dbmaestro-cicd` templates (`build-from-source`, `precheck-package`, `create-package`, `detect-packages`, `tag-package`, `get-cli-jar`, `upgrade-environment`) hardcodes `pwsh: true` on its `PowerShell@2` task — that's baked into the shared templates, not something this workflow's own YAML controls, so it can't be worked around by switching the orchestrator's own steps to `powershell:` (Windows PowerShell 5.1). If `pwsh` is missing from an agent, install PowerShell 7+ (`winget install --id Microsoft.PowerShell` or the MSI from https://aka.ms/PSWindows) and **restart the Azure Pipelines agent service** afterward — the same PATH-caching gotcha covered for Azure CLI in section 7a applies here too.
- The DBmaestro template calls in both pipelines are set to `useWindows: true`.
- **Azure CLI (`az`) installed on the `dbmaestro-windows` agent(s).** The orchestrator's "Queue" steps call `az pipelines run`/`az pipelines runs show` directly, and `az extension add --name azure-devops` runs automatically on each invocation — but the base `az` executable itself must already be present. See section 7a if it isn't.
- **Java installed on the `dbmaestro-windows` agent(s), with `java` on PATH.** The DBmaestro templates (`build-from-source`, `precheck-package`, `create-package`, `tag-package`) all shell out to `java -jar "$agentJarPath" ...` to run the DBmaestro CLI agent (`DBmaestroAgent.jar`). If Java isn't installed, or is installed but not on the PATH the agent service sees, every one of these steps fails immediately with something like `'java' is not recognized as an internal or external command` (or the equivalent `The term 'java' is not recognized...` in PowerShell). As with Azure CLI (section 7a), remember to **restart the Azure Pipelines agent service** after installing Java — a service started before the install won't pick up the new PATH.

> **Naming heads-up:** there are two different "project" concepts in play, and they currently have different values. The orchestrator's `targetProject` variable (the actual **Azure DevOps** project pipelines 59/60 live in) is `'Example'`. The `projectName` parameter inside `build-source-control.yml`/`upgrade-environment.yml` (DBmaestro's own internal project concept, unrelated to ADO) defaults to `'Example-ADO'`. Worth double-checking these are supposed to differ before assuming it's a typo.

## 4. Commit message convention

Commits on `example-ado-source-control` must follow this format:

```
<version>; TaskID: <value>

Example:  v1.0.1; TaskID: V1.0.1
```

This format is generated automatically by the **DBmaestro Source Control** application — it isn't something you type by hand. The only thing required on your end is to specify the **TaskID** value in the tool at commit time; DBmaestro Source Control then builds the full commit message (version plus `TaskID:` segment) for you. If a commit is ever made outside that tool, or the TaskID field is left blank, the message won't match this format and the Build stage's extraction step will fail with "Could not find 'TaskID: <value>' ..." (see section 15).

The value after `TaskID:` is extracted once, in the Build stage, and reused as `packageName` for the build and as `packageNames` for both the integration and production upgrades.

## 5. Workflow architecture

The orchestrator pipeline (`source-control-workflow.yml`, living in `example-ado-source-control`) runs seven stages in sequence, each depending on the previous one:

1. **Build** — extracts the TaskID and queues pipeline 59 (fire-and-forget — see section 5a).
2. **Integration pre-approval gate** — Environment `Integration-pre-approval`. Pauses until an approver signs off.
3. **Upgrade (Integration)** — queues pipeline 60 with `targetEnvironment=Integration` (fire-and-forget).
4. **Integration post-approval gate** — Environment `Integration-post-approval`. Confirms the integration upgrade before moving on.
5. **Production pre-approval gate** — Environment `Production-pre-approval`. Pauses until an approver signs off on going to production.
6. **Upgrade (Production)** — queues pipeline 60 with `targetEnvironment=Production` (fire-and-forget).
7. **Production post-approval gate** — Environment `Production-post-approval`. Final confirmation; workflow ends here.

Each gate is a separate Azure DevOps Environment with a manual Approval check configured in the ADO UI, not in code — so who approves any single gate can change later without touching this file.

The `UpgradeIntegration` and `UpgradeProduction` stages each list **two** entries in `dependsOn` (their approval gate, and `Build`), not just the gate. This is required, not redundant: Azure DevOps' `stageDependencies` output-variable expressions only resolve for stages that are *explicitly* listed in `dependsOn` — even a stage that's already an indirect ancestor (through the gate) won't be visible otherwise. Without `Build` listed explicitly, `stageDependencies.Build.Build.outputs['extract.packageName']` silently resolves to nothing, which surfaces downstream as `packageNames' parameter is not a valid String`. Execution order is unaffected either way, since `Build` already has to finish before the gate stage runs.

This pipeline's trigger explicitly **excludes** `ad-hoc/*` (`paths: exclude: [ad-hoc/*]`) so it stays mutually exclusive with the ad-hoc workflow (section 14): without that exclusion, a commit that only touches `ad-hoc/` would also trigger this workflow and fail immediately at TaskID extraction, since ad-hoc commits don't follow the `<version>; TaskID: <value>` convention.

### 5a. Why "fire-and-forget" instead of "queue and wait"

This ADO organization has exactly **1 self-hosted parallel job** and **0 granted Microsoft-hosted parallel jobs** (confirmed by an explicit CI error when a Microsoft-hosted pool was tried: *"No hosted parallelism has been purchased or granted"*). A job that queues a downstream pipeline and then polls it in a loop until completion would hold the only available slot for the entire wait, so the downstream pipeline could never start — a permanent deadlock.

The fix: every "Queue" step just queues the downstream pipeline and exits immediately, releasing the slot so the downstream run can actually use it. Environment approval checks cost nothing while pending (no agent, no slot), which is what makes this safe with only one parallel job — the queued pipeline runs during the time a human is looking at the next gate.

This means there is **no automatic pass/fail check** built into the orchestrator anymore. That responsibility now falls to whoever approves the next gate:

- Before approving, check that the pipeline just queued actually succeeded (the Runs list, or the failure-notification email — section 11). Each "Queue" step prints the exact URL to check.
- If it failed, **reject** the gate instead of approving it, to stop the workflow rather than letting it continue against a broken build/upgrade.

The original poll-until-complete logic is kept commented out directly under each "Queue" step in the YAML (see section 6), so it's a quick uncomment if this org ever gets a second parallel job.

## 6. Pipeline file (`source-control-workflow.yml` in `example-ado-source-control`)

The orchestrator's full YAML is kept as a local reference copy in this repo rather than duplicated inline here, so it can't drift out of sync with the README:

[`example-ado-source-control/source-control-workflow.yml`](./example-ado-source-control/source-control-workflow.yml)

The live version that Azure DevOps actually runs lives in the `example-ado-source-control` GitHub repo — this local copy exists purely so the full pipeline is easy to review alongside this runbook; keep the two in sync when either changes.

## 7. Add the dbmaestro-cicd service connection

Both `build-source-control.yml` and `upgrade-environment.yml` reference a second repository resource to pull in DBmaestro's reusable templates:

```yaml
resources:
  repositories:
    - repository: dbmaestro-cicd
      type: github
      name: DBMaestroDev/dbmaestro-cicd
      endpoint: dbmaestro-cicd  # must match the service connection name exactly
      ref: refs/tags/v1
```

That `endpoint: dbmaestro-cicd` value must match the **name** of an actual GitHub service connection in this ADO project — it's a separate authorization from whatever connection is used for the source repo, even if that connection could technically also reach `DBMaestroDev/dbmaestro-cicd`. If no connection with that exact name exists (or it isn't authorized), both pipelines fail immediately with:

```
ERROR: Repository dbmaestro-cicd references endpoint dbmaestro-cicd which does not exist or is not authorized for use
```

To fix it:

1. Project Settings → Service connections → New service connection → GitHub.
2. Authenticate (GitHub App "Azure Pipelines" is consistent with the rest of this setup). If using the GitHub App and it's installed with repo-scoped (not org-wide) access, add `dbmaestro-cicd` to its repository access list on the GitHub side first: GitHub → Settings → Applications → Azure Pipelines → Configure → Repository access.
3. Name the connection **exactly** `dbmaestro-cicd` (or, if you'd rather use a different name, edit the `endpoint:` value in both `build-source-control.yml` and `upgrade-environment.yml` to match whatever you name it instead). Double check the exact spelling — a one-character typo (e.g. a missing letter) produces this same "does not exist" error even though a similarly-named connection exists.
4. Check "Grant access permission to all pipelines" (or leave it unchecked and explicitly authorize pipelines 59/60 afterward via the connection's Security tab).
5. Save, then re-run the pipeline.

## 7a. Install Azure CLI on the agent

The orchestrator's "Queue" steps shell out to `az pipelines run` and `az pipelines runs show` directly, so the `dbmaestro-windows` agent needs the base Azure CLI installed (the `azure-devops` extension is added automatically by the pipeline itself on each run — no separate step needed for that). Without it, every "Queue" step fails immediately with:

```
az : The term 'az' is not recognized as the name of a cmdlet, function, script file, or operable program.
```

To install it on the agent machine:

```powershell
# Option 1: MSI installer, silently
Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
Remove-Item .\AzureCLI.msi

# Option 2: winget
winget install -e --id Microsoft.AzureCLI
```

Then **restart the Azure Pipelines agent service** (or reboot the machine). Windows services capture `PATH` at the time they start, so the agent won't see the newly-installed `az` executable until it's restarted — running `az --version` in a fresh terminal isn't enough to confirm the agent itself can see it.

## 8. Create the ADO pipeline definition

*(Already done if you set up an earlier version of this pipeline — this step only applies the first time, or if you need to recreate it after moving repos.)*

1. Go to Pipelines → New Pipeline.
2. Choose GitHub, then select the DBMaestroDev / example-ado-source-control repository (using the existing "GitHub using Azure Pipelines app" connection).
3. Point it at `source-control-workflow.yml`.
4. Save.

This creates the orchestrator pipeline in the same `dbmsc`/`Example` project as pipelines 59 and 60.

Repeat the same steps for `ad-hoc-workflow.yml` (same repository, same connection) to create the second, separate trigger pipeline that the ad-hoc workflow needs (section 14) — it's a different pipeline definition from this one, since each YAML file gets its own definition when pointed to from Pipelines → New Pipeline.

## 9. Grant permissions to queue the build and upgrade pipelines (59 and 60 in this example)

The orchestrator runs as the project's build service identity (e.g. `Example Build Service (dbmsc)` — the exact name follows the pattern `<project> Build Service (<org>)`), which needs explicit rights on both target pipelines to queue them with custom parameters. Without this, runs fail with `TF215106` access-denied errors.

Repeat for **each** of pipeline 59 (Build and Precheck Package - Source Control), pipeline 60 (Upgrade Environment), and pipeline 62 (Build with Git Change Detection, section 14) — every pipeline any orchestrator queues via `az pipelines run` needs this, regardless of which orchestrator queues it:

1. Open the pipeline in the ADO UI.
2. Open the "⋮" (more actions) menu → **Security**.
3. Find (or add) the project's Build Service identity.
4. Set **Queue builds** to **Allow**.
5. Set **Edit queue build configuration** to **Allow** (needed because the workflow overrides parameters at queue time).
6. Save.

> Both permissions can instead be granted once at the project level (Project Settings → Pipelines → Settings/Security) to cover all pipelines rather than doing this twice.

## 10. Create the four approval-gate environments

For each of the four gates, create an Azure DevOps Environment and attach a manual Approval check:

1. Go to Pipelines → Environments → New environment.
2. Name it exactly as referenced in the YAML: `Integration-pre-approval`, `Integration-post-approval`, `Production-pre-approval`, or `Production-post-approval`.
3. Resource: choose **None** — these environments exist only to host an approval check, not to represent an actual deployment target.
4. Create. Then open the environment → "⋮" → **Approvals and checks** → Add check → **Approvals**.
5. Add the approver(s) for that gate and save.

Suggested approver assignment once fully rolled out:

| Environment | Approver |
|---|---|
| `Integration-pre-approval` | approver1@dbmaestro.com |
| `Integration-post-approval` | approver1@dbmaestro.com |
| `Production-pre-approval` | approver2@dbmaestro.com |
| `Production-post-approval` | approver2@dbmaestro.com |

For initial testing, all four environments were instead assigned the same single approver so the whole chain could be validated end to end before splitting responsibilities between two reviewers as shown above.

Since the workflow no longer verifies success automatically (section 5a), whoever approves each gate should confirm the previous run actually succeeded first — the "Queue" steps print the run's URL to check.

### 10a. First-run resource authorization (separate from the approval check)

The first time the orchestrator run actually reaches each environment, Azure DevOps pauses with a banner like:

```
This pipeline needs permission to access a resource before this run can continue to Integration - Post-Approval Gate
This pipeline needs permission to access a resource before this run can continue to Production - Pre-Approval Gate
```

This is a **one-time authorization per (pipeline, environment) pair**, distinct from the Approval check configured above — it exists because a YAML pipeline isn't automatically allowed to use any environment resource it references, even ones with no approval check at all. Expect to see this once for each of the four environments the first time the orchestrator runs end to end (not just the two shown above).

To resolve it:

1. Open the run in the ADO UI — it'll show a **"View"** / **"Permission"** prompt on the waiting stage.
2. Click **Permit** (a project Administrator or someone with **Manage** permission on that environment can do this; approving the check itself is not enough).
3. Optionally check **"Permit for all pipelines"** while permitting, or pre-authorize it ahead of time via the environment → "⋮" → **Security** → grant the pipeline access — either avoids hitting this prompt again on future runs of the same pipeline.

Until it's permitted, the stage sits waiting on this authorization screen and never even reaches the Approval check — so if a gate seems stuck, check for this prompt before assuming the Approval check itself is misconfigured.

## 11. Failure notifications (build pipeline — 59 in this example)

Azure DevOps' built-in notification subscriptions email a distribution list whenever pipeline 59 fails — no SMTP or pipeline code involved.

1. Project Settings (`Example` project) → Notifications → New subscription (project/shared subscriptions section; requires Project Administrator rights).
2. Category: **Build**. Template: **"A build completes."**
3. Filter: **Definition name** = `Build and Precheck Package - Source Control`.
4. Filter: **Status** = `Failed`.
5. Deliver to → **Custom email address** → `devops@dbmaestro.com`.
6. Save.

Consider adding an equivalent subscription filtered to `Upgrade Environment` (definition 60) with Status = Failed, so integration/production upgrade failures reach the same distribution list. This matters more now that gates rely on a human noticing failures rather than the orchestrator stopping automatically.

## 12. Test

1. Using DBmaestro Source Control application, commit to `example-ado-source-control` with a message such as: `v1.0.2; TaskID: TASK-42`
2. Confirm the orchestrator starts, the Build stage extracts `TASK-42`, and pipeline 59 is queued.
3. Check pipeline 59's run and confirm it succeeded before proceeding.
4. At the Integration pre-approval gate, approve the pending check in the ADO UI (Pipelines → the run → the pending environment approval).
5. Confirm the Upgrade (Integration) stage queues pipeline 60 with `targetEnvironment=Integration` and `packageNames=TASK-42`; check that run succeeded.
6. Approve the Integration post-approval gate.
7. Approve the Production pre-approval gate.
8. Confirm the Upgrade (Production) stage queues pipeline 60 with `targetEnvironment=Production` and `packageNames=TASK-42`; check that run succeeded.
9. Approve the Production post-approval gate and confirm the run completes successfully.

## 13. Friendly run names for the build and upgrade pipelines (59 and 60 in this example)

By default, Azure DevOps run names show a generic build number like `#20260727.2` alongside whatever the latest commit message happens to be on that pipeline's own source repo — not necessarily anything meaningful. Both target pipelines set a custom build number format so each run in the ADO UI immediately shows what it's building:

- `build-source-control.yml`: `name: 'TaskID-${{ parameters.packageName }} ($(Date:yyyyMMdd)$(Rev:.r))'` → e.g. `TaskID-TASK-42 (20260727.2)`
- `upgrade-environment.yml`: `name: '${{ parameters.targetEnvironment }} - TaskID-${{ parameters.packageNames }} ($(Date:yyyyMMdd)$(Rev:.r))'` → e.g. `Integration - TaskID-TASK-42 (20260727.2)`

Note the dash (`TaskID-`) rather than a colon: Azure DevOps build numbers reject `"`, `/`, `:`, `<`, `>`, `\`, `|`, `?`, `@`, and `*`, and a colon in an earlier version of this format caused every run to fail with "contains invalid character(s)." This is purely cosmetic otherwise — it doesn't change any pipeline behavior, only how each run is labeled in the Runs list.

## 14. Ad-hoc workflow (build-only, git-diff based)

A second, independent trigger pipeline — `ad-hoc-workflow.yml`, also living in `example-ado-source-control` — handles a different case: packages that don't go through the TaskID/approval-gate/upgrade flow at all, just a build whenever something under `ad-hoc/` changes.

[`example-ado-source-control/ad-hoc-workflow.yml`](./example-ado-source-control/ad-hoc-workflow.yml)

Why this is separate from the main workflow rather than a mode of it:

- **Different trigger scope.** It fires only on pushes touching `ad-hoc/*` (`trigger: paths: include: [ad-hoc/*]`), while the main workflow explicitly excludes that same path (section 5) — the two are mutually exclusive by design, so a single commit never triggers both.
- **No TaskID extraction.** The target pipeline, **"Build with Git Change Detection"** (`build-git-changes.yml`, definition ID 62), detects which packages changed by diffing against its `baseBranch` parameter (default `'main'`) rather than reading anything out of the commit message. Ad-hoc commits don't need to follow the `<version>; TaskID: <value>` convention from section 4.
- **No gates, no upgrade chain.** This is intentionally build-only. A push under `ad-hoc/` queues pipeline 62 (fire-and-forget, same rationale as section 5a — this org's 1-parallel-job limit applies here too) and the workflow ends there. Add approval gates and an upgrade stage later if ad-hoc packages ever need the same promotion path as the main release workflow — nothing about the current design blocks that.
- **No required parameter overrides.** Every parameter on pipeline 62 already has a default that fits this setup (`packagesFolder: 'ad-hoc'`, `projectName: 'Example-ADO'`, `baseBranch: 'main'`), so the "Queue" step only needs to pass `runnerPool` explicitly, for consistency with the rest of this guide.

### Test

1. Commit a change to a file under `ad-hoc/` in `example-ado-source-control` (any message — no TaskID convention needed).
2. Confirm `ad-hoc-workflow.yml` triggers and its Build stage queues pipeline 62 — check the printed run URL.
3. Confirm the main `source-control-workflow.yml` orchestrator did **not** also trigger from the same commit (the path exclusion from section 5).
4. Check pipeline 62's run and confirm it detected and built the changed package(s).

## 15. Troubleshooting

| Symptom | Fix |
|---|---|
| `ERROR: Repository dbmaestro-cicd references endpoint dbmaestro-cicd which does not exist or is not authorized for use` | The `dbmaestro-cicd` GitHub service connection doesn't exist in this project (or isn't authorized), or its name doesn't exactly match the `endpoint:` value (check for typos) — see step 7. |
| `##[error]No hosted parallelism has been purchased or granted` | This org has 0 Microsoft-hosted parallel jobs. Don't switch pools to a `vmImage` — use the self-hosted `dbmaestro-windows` pool already configured everywhere, and rely on the fire-and-forget design (section 5a). |
| `##[error]Unable to locate executable file: 'bash'` | The agent is Windows and has no bash on PATH. All steps in these three files use `pwsh:` instead of `bash:` for exactly this reason — if you still see this, a step somewhere is still using `bash:`. `powershell:` (Windows PowerShell 5.1) is not a substitute here: the `dbmaestro-cicd` templates hardcode `pwsh: true`, so PowerShell 7+ must actually be installed (section 3) — see also the next row. |
| `##[error]'pwsh' task detected. This task requires PowerShell version >= 6 and PowerShell not found on specified path` (or agent errors resolving `pwsh`) | PowerShell 7+ isn't installed on the agent, or the agent service was never restarted after installing it. This isn't optional/fallback-able — every Windows-path step in the `dbmaestro-cicd` templates hardcodes `pwsh: true` — see section 3. |
| `az : The term 'az' is not recognized as the name of a cmdlet, function, script file, or operable program.` | Azure CLI isn't installed on the agent (or the agent service was never restarted after installing it) — see section 7a. |
| `java : The term 'java' is not recognized as the name of a cmdlet, function, script file, or operable program.` | Java isn't installed on the agent, or isn't on the PATH the agent service sees (or the agent service was never restarted after installing it) — see section 3. Every DBmaestro template step (`build-from-source`, `precheck-package`, `create-package`, `tag-package`) needs `java` to run `DBmaestroAgent.jar`. |
| Build number generation fails with "contains invalid character(s)" mentioning `:` | A custom `name:` format included a literal colon (e.g. `TaskID: X`). Build numbers can't contain `"`, `/`, `:`, `<`, `>`, `\`, `|`, `?`, `@`, or `*` — use a dash or space instead (see section 13). |
| `TF215106: ... needs Queue builds permissions for build pipeline 59/60 ...` | Grant Queue builds = Allow to the project's Build Service identity on that pipeline's Security panel (see step 9). |
| `TF215106: ... needs Edit queue build configuration permissions ...` | Grant Edit queue build configuration = Allow to the same identity on the same Security panel. |
| Stage stays "Waiting" indefinitely at a gate | Expected — that's the approval check. Open the run in the ADO UI and approve/reject the pending environment check. If no one is ever prompted, confirm the Approval check is actually attached to that environment (step 10). |
| `This pipeline needs permission to access a resource before this run can continue to <environment>` | One-time resource authorization, separate from the Approval check — see section 10a. Someone with Manage permission on that environment must click **Permit** (optionally "for all pipelines") before the stage will even reach the Approval check. Expect this once per environment on first use. |
| A gate was approved but the downstream run actually failed | Fire-and-forget means nothing catches this automatically (section 5a) — the approver needs to check the run before approving. Consider re-enabling the commented-out polling code (section 6) if/when a second parallel job becomes available. |
| The precheck step (or another build/upgrade step) failed and you need to retry with a fix | Push a new commit with the fix — this triggers a brand-new orchestrator run (a new pipeline instance) starting from Build, with a fresh precheck against the corrected package. Then **cancel the original failed run** so it doesn't linger as an incomplete/failed run in the Runs list. Don't try to fix and resume the existing failed run in place. |
| `ERROR: The 'packageNames' parameter is not a valid String` (or `packageName`) when queuing pipeline 59/60 | Most likely `stageDependencies.Build.Build.outputs['extract.packageName']` didn't resolve. Confirm: (1) the Build stage's extraction step is literally named `extract` (the `name:` field) and sets the variable with `isOutput=true`; (2) the consuming stage (`UpgradeIntegration`/`UpgradeProduction`) explicitly lists `Build` in its `dependsOn`, not just its approval-gate stage — see section 5. |
| Build/Upgrade step fails with "Could not find 'TaskID: <value>' ..." | The commit message didn't match the required `<version>; TaskID: <value>` format — amend the commit message and re-push. |
| A commit touching `ad-hoc/` triggered both `ad-hoc-workflow.yml` **and** the main `source-control-workflow.yml`, and the latter failed at TaskID extraction | The main workflow's `paths: exclude: [ad-hoc/*]` (section 5) is missing, misconfigured, or the commit touched files both inside and outside `ad-hoc/` in the same push (path filters trigger on the whole push, not per-file) — see section 14. |
| A commit under `ad-hoc/` didn't trigger anything | Confirm the `ad-hoc-workflow.yml` pipeline definition actually exists in ADO (section 8) and that the push landed on `main` — the trigger only watches that branch. |
