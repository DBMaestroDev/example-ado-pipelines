# GitHub Commit to Production: Full Release Workflow

*Setup runbook — example-ado-source-control → Build → Integration → Production, with approval gates and failure notification*

## 1. Goal

On every commit to the `example-ado-source-control` GitHub repository, automatically: build a DBmaestro package, gate on manual approval, upgrade the integration environment, gate on manual confirmation, gate on manual approval again, upgrade the production environment, and gate on a final manual confirmation. Values are parsed from the commit message rather than entered by hand.

There's a second, separate workflow for **ad-hoc** package builds: commits that only touch the `ad-hoc/` folder skip all of this — no TaskID convention, no approval gates, no environment upgrade — and instead just build whatever changed via git-diff detection, then go through the same approval-gated upgrade environments, except its Integration and Production legs run as two independent gates opened in parallel rather than one fixed sequence — see `ad-hoc-workflow.md` section 3.

`example-ado-source-control` isn't a one-off — it's the pattern for the repo **every individual DBmaestro project** needs one of. Each DBmaestro project gets its own copy of this repo (same two wrapper files, its own parameter values), so a commit to that project's own repo drives that project's own release chain independently of any other project's. `example-ado-pipelines` (this repo) hosts one-time setup (this file) plus the shared pipeline logic reused by every one of those project repos. The chains themselves — stages, parameters, troubleshooting specific to each — are documented separately:

- [`source-control-workflow.md`](./source-control-workflow.md) — the TaskID-driven flow described above.
- [`ad-hoc-workflow.md`](./ad-hoc-workflow.md) — the git-diff-driven ad-hoc flow.

## 2. Prerequisites

> **A note on specific values below:** this guide documents one real deployment, so it names concrete values throughout (an org, a project, pipeline definition IDs, a pool name, and so on). None of these are requirements of the design — they're just what this instance happens to use. Your organization/project names will differ, and **pipeline definition IDs in particular are assigned automatically by Azure DevOps** the first time each pipeline is created (step 6) — you can't choose or predict them in advance. Substitute your own values throughout; the table below is the full list of what to swap.

| Item | Value used in this guide |
|---|---|
| Azure DevOps organization | `dbmsc` |
| Azure DevOps project (where the build/upgrade pipelines live) | `Example` |
| DBmaestro project name (`dBmaestroProjectName` orchestrator parameter, passed as `projectName` to the downstream pipelines — a separate, unrelated concept, see naming heads-up below) | `Example-ADO` |
| Build pipeline (source-control flow) | "Build and Precheck Package - Source Control", definition ID **59** |
| Upgrade pipeline (shared by both flows) | "Upgrade Environment", definition ID **60** |
| Ad-hoc build pipeline | "Build with Git Change Detection", definition ID **62** |
| Ad-hoc-triggering folder | `ad-hoc/` |
| Self-hosted agent pool | `dbmaestro-windows` |
| GitHub org hosting `dbmaestro-cicd` (DBmaestro's templates repo — fixed, not yours to change) | `DBMaestroDev` |
| GitHub org hosting `example-ado-pipelines` and `example-ado-source-control` (**your own** org — this guide's example deployment happens to also use `DBMaestroDev`, but yours won't) | *your GitHub org* |
| `dbmaestro-cicd` service connection name | `dbmaestro-cicd` |
| Failure-notification distribution list | `devops@dbmaestro.com` |
| Gate approvers | `approver1@dbmaestro.com`, `approver2@dbmaestro.com` |

- GitHub service connection **"GitHub using Azure Pipelines app"**, connected to the GitHub org that hosts **your** `example-ado-pipelines` and `example-ado-source-control` (not `DBMaestroDev` — that org is only for `dbmaestro-cicd`). Since both of your repos live in the same org, this one connection can also serve as the `endpoint:` for the `adoPipelines`/`exampleAdoSourceControl` resource entries in the wrapper/pipeline YAML — no separate connection needed for that. If your connection is scoped per-repository rather than org-wide, it needs explicit access to both repos; otherwise register a second connection and update the relevant `endpoint:` value to match.
- Pipeline **"Build and Precheck Package - Source Control"** — org `dbmsc`, project `Example`, definition ID **59**. `packageName` has no default, so it's always required. `tasksList` technically has a default (`'none'`), but the pipeline's own validation step fails the run if `buildType` is left at its default (`'Specific Tasks'`) and `tasksList` is `'none'`/empty — so in practice both `packageName` and `tasksList` must be supplied. The source-control workflow sets both to the extracted TaskID, and also explicitly passes `projectName` (from its own `dBmaestroProjectName` parameter) rather than relying on this pipeline's `'Example-ADO'` default.
- Pipeline **"Upgrade Environment"** — org `dbmsc`, project `Example`, definition ID **60**. All of its parameters (`targetEnvironment`, `packageNames`, `tagName`, `projectName`, `agentJarPath`, `runnerPool`) have defaults; both workflows explicitly set `targetEnvironment`, `packageNames`, `projectName` (from their own `dBmaestroProjectName` parameter), and `runnerPool`. `targetEnvironment` only accepts `'Integration'` or `'Production'` (case-sensitive, `'qa'` was dropped) — the orchestrator must pass those exact strings.
- Pipeline **"Build with Git Change Detection"** (`build-git-changes.yml`) — org `dbmsc`, project `Example`, definition ID **62**. Used by the ad-hoc flow only — see `ad-hoc-workflow.md`. Accepts an optional `packageNames` parameter that, when set, skips its own git-diff detection (the ad-hoc workflow passes this in directly, having already detected changes itself). The ad-hoc workflow also explicitly passes `projectName` (from its own `dBmaestroProjectName` parameter) rather than relying on this pipeline's `'Example-ADO'` default.
- A GitHub service connection named exactly **`dbmaestro-cicd`**, authorized in this project and pointed at `DBMaestroDev/dbmaestro-cicd`. `build-source-control.yml`, `upgrade-environment.yml`, and `build-git-changes.yml` all declare this as a `resources.repositories` entry (`endpoint: dbmaestro-cicd`) so they can check out DBmaestro's reusable pipeline templates. Without this exact-named, authorized connection, they fail immediately with `Repository dbmaestro-cicd references endpoint dbmaestro-cicd which does not exist or is not authorized for use` — see section 4.
- A registered self-hosted **Windows** agent in the **`dbmaestro-windows`** pool, with **PowerShell 7+ (`pwsh`)** installed. All pipelines run on this one pool — the orchestrators' jobs directly (`pool: dbmaestro-windows`, or the `runnerPool` template parameter), and pipelines 59/60/62 via their own `runnerPool` parameter, which defaults to `'dbmaestro-windows'` and is also explicitly passed by both orchestrators. **PowerShell 7+ is a hard requirement, not a fallback-able one:** every Windows-path step in the `dbmaestro-cicd` templates (`build-from-source`, `precheck-package`, `create-package`, `detect-packages`, `tag-package`, `get-cli-jar`, `upgrade-environment`) hardcodes `pwsh: true` on its `PowerShell@2` task — that's baked into the shared templates, not something either orchestrator's own YAML controls, so it can't be worked around by switching to `powershell:` (Windows PowerShell 5.1). If `pwsh` is missing from an agent, install PowerShell 7+ (`winget install --id Microsoft.PowerShell` or the MSI from https://aka.ms/PSWindows) and **restart the Azure Pipelines agent service** afterward — the same PATH-caching gotcha covered for Azure CLI in section 4a applies here too.
- The DBmaestro template calls in all three downstream pipelines are set to `useWindows: true`.
- **Azure CLI (`az`) installed on the `dbmaestro-windows` agent(s).** Both orchestrators' "Queue" steps call `az pipelines run` directly, and `az extension add --name azure-devops` runs automatically on each invocation — but the base `az` executable itself must already be present. See section 4a if it isn't.
- **Java installed on the `dbmaestro-windows` agent(s), with `java` on PATH.** The DBmaestro templates (`build-from-source`, `precheck-package`, `create-package`, `tag-package`) all shell out to `java -jar "$agentJarPath" ...` to run the DBmaestro CLI agent (`DBmaestroAgent.jar`). If Java isn't installed, or is installed but not on the PATH the agent service sees, every one of these steps fails immediately with something like `'java' is not recognized as an internal or external command` (or the equivalent `The term 'java' is not recognized...` in PowerShell). As with Azure CLI (section 4a), remember to **restart the Azure Pipelines agent service** after installing Java — a service started before the install won't pick up the new PATH.
- **Pipeline variables on `build-source-control.yml`, `upgrade-environment.yml`, and `build-git-changes.yml`** (set as Variables on each of the three pipelines, or once in a shared Variable Group under Pipelines → Library, referenced by all three):
  - `DBMAESTRO_SERVER` — the DBmaestro server address, passed as `server:` to every DBmaestro template call in all three pipelines. Format is `host:port`, e.g. `dop.dbmaestro.local:8017` — not a URL (no `http(s)://`).
  - `CLI_VERSION` — controls which version of the DBmaestro CLI JAR (`DBmaestroAgent.jar`) gets downloaded, passed as `version:`. **If the agent already has the JAR pre-installed, `CLI_VERSION` isn't required** — leave it empty to skip the download — but you must then set `agentJarPath` (a parameter on all three pipelines, default `$(Pipeline.Workspace)/DBmaestroAgent.jar`) to the JAR's actual absolute path on that agent; the default path only resolves correctly when `CLI_VERSION` drove the download into that same per-run workspace location.
  - Authentication — this repo's YAML wires up **OIDC-style access-token auth** by default, via `accessTokenFilePath: $(DBMAESTRO_ACCESS_TOKEN_FILE_PATH)` passed to every DBmaestro template call:
    - **Using OIDC:** set `DBMAESTRO_ACCESS_TOKEN_FILE_PATH` to the path of the file containing the access token.
    - **Not using OIDC:** the three pipelines need editing — swap `accessTokenFilePath` for whatever username/password parameters the `dbmaestro-cicd` templates (`build-from-source`, `precheck-package`, `create-package`, `tag-package`, `upgrade-environment`, `build-multiple-packages`) actually expose for that mode, then set `DBMAESTRO_USER` and `DBMAESTRO_PASSWORD` (mark the latter **secret**) as pipeline variables and reference them there instead. This is a YAML change, not just a variable-setting one.
  - `useSsl` — hardcoded per DBmaestro template call, not a pipeline variable. `build-source-control.yml` and `upgrade-environment.yml` default it to `'False'`; `build-git-changes.yml` defaults it to `'True'`. If your DBmaestro server's actual SSL setting doesn't match a given pipeline's hardcoded value, edit that `useSsl:` line directly in the YAML.

> **Naming heads-up:** there are two different "project" concepts in play, and they currently have different values. Both orchestrators' `targetADOProject` parameter (the actual **Azure DevOps** project pipelines 59/60/62 live in) is `'Example'`. Both orchestrators' `dBmaestroProjectName` parameter is passed through to `build-source-control.yml`/`upgrade-environment.yml`/`build-git-changes.yml` as their `projectName` parameter (DBmaestro's own internal project concept, unrelated to ADO) and is set to `'Example-ADO'`. The `targetADOOrganization`/`targetADOProject`/`dBmaestroProjectName` names were chosen specifically to keep these apart — worth double-checking the values are supposed to differ before assuming it's a typo.

## 3. Two release workflows, one shared template repo

Both `source-control-workflow.yml` and `ad-hoc-workflow.yml` follow the same shape: a thin trigger file living in `example-ado-source-control` (required, since Azure DevOps only self-triggers off YAML committed in the triggering repo), which `extends:` a template holding the actual multi-stage pipeline, stored once in this `example-ado-pipelines` repo under `azure-devops/templates/`:

- [`azure-devops/templates/source-control-workflow.yml`](./azure-devops/templates/source-control-workflow.yml) — extended by `example-ado-source-control/source-control-workflow.yml`.
- [`azure-devops/templates/ad-hoc-workflow.yml`](./azure-devops/templates/ad-hoc-workflow.yml) — extended by `example-ado-source-control/ad-hoc-workflow.yml`.

The point of this split: each DBmaestro project's own `example-ado-source-control`-pattern repo only needs an equally thin trigger file of its own (same shape, its own parameter values) — not a copy of the whole pipeline. Any future fix to either chain happens once, in its template, rather than being re-applied across every project's source-control repo.

Full stage-by-stage detail, parameters, and workflow-specific troubleshooting live in [`source-control-workflow.md`](./source-control-workflow.md) and [`ad-hoc-workflow.md`](./ad-hoc-workflow.md).

### 3a. Fire-and-forget design (applies to both workflows)

This ADO organization has exactly **1 self-hosted parallel job** and **0 granted Microsoft-hosted parallel jobs** (confirmed by an explicit CI error when a Microsoft-hosted pool was tried: *"No hosted parallelism has been purchased or granted"*). A job that queues a downstream pipeline and then polls it in a loop until completion would hold the only available slot for the entire wait, so the downstream pipeline could never start — a permanent deadlock.

The fix, used throughout both templates: every "Queue" step just queues the downstream pipeline and exits immediately, releasing the slot so the downstream run can actually use it. Environment approval checks cost nothing while pending (no agent, no slot), which is what makes this safe with only one parallel job — the queued pipeline runs during the time a human is looking at the next gate.

This means there is **no automatic pass/fail check** built into either orchestrator. That responsibility falls to whoever approves the next gate:

- Before approving, check that the pipeline just queued actually succeeded (the Runs list, or the failure-notification email — section 8). Each "Queue" step prints the exact URL to check.
- If it failed, **reject** the gate instead of approving it, to stop the workflow rather than letting it continue against a broken build/upgrade.

The original poll-until-complete logic is kept commented out directly under each "Queue" step in both templates, so it's a quick uncomment if this org ever gets a second parallel job.

## 4. Add the dbmaestro-cicd service connection

`build-source-control.yml`, `upgrade-environment.yml`, and `build-git-changes.yml` all reference a second repository resource to pull in DBmaestro's reusable templates:

```yaml
resources:
  repositories:
    - repository: dbmaestro-cicd
      type: github
      name: DBMaestroDev/dbmaestro-cicd
      endpoint: dbmaestro-cicd  # must match the service connection name exactly
      ref: refs/tags/v1
```

That `endpoint: dbmaestro-cicd` value must match the **name** of an actual GitHub service connection in this ADO project — it's a separate authorization from whatever connection is used for the source repo, even if that connection could technically also reach `DBMaestroDev/dbmaestro-cicd`. If no connection with that exact name exists (or it isn't authorized), these pipelines fail immediately with:

```
ERROR: Repository dbmaestro-cicd references endpoint dbmaestro-cicd which does not exist or is not authorized for use
```

To fix it:

1. Project Settings → Service connections → New service connection → GitHub.
2. Authenticate (GitHub App "Azure Pipelines" is consistent with the rest of this setup). If using the GitHub App and it's installed with repo-scoped (not org-wide) access, add `dbmaestro-cicd` to its repository access list on the GitHub side first: GitHub → Settings → Applications → Azure Pipelines → Configure → Repository access.
3. Name the connection **exactly** `dbmaestro-cicd` (or, if you'd rather use a different name, edit the `endpoint:` value in `build-source-control.yml`, `upgrade-environment.yml`, and `build-git-changes.yml` to match whatever you name it instead). Double check the exact spelling — a one-character typo (e.g. a missing letter) produces this same "does not exist" error even though a similarly-named connection exists.
4. Check "Grant access permission to all pipelines" (or leave it unchecked and explicitly authorize pipelines 59/60/62 afterward via the connection's Security tab).
5. Save, then re-run the pipeline.

### 4a. Install Azure CLI on the agent

Both orchestrators' "Queue" steps shell out to `az pipelines run` directly, so the `dbmaestro-windows` agent needs the base Azure CLI installed (the `azure-devops` extension is added automatically by the pipeline itself on each run — no separate step needed for that). Without it, every "Queue" step fails immediately with:

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

## 5. Create the ADO pipeline definitions

*(Already done if you set up an earlier version of this pipeline — this step only applies the first time, or if you need to recreate one after moving repos.)*

1. Go to Pipelines → New Pipeline.
2. Choose GitHub, then select the DBMaestroDev / example-ado-source-control repository (using the existing "GitHub using Azure Pipelines app" connection).
3. Point it at `source-control-workflow.yml`.
4. Save.

This creates the source-control orchestrator pipeline in the same `dbmsc`/`Example` project as pipelines 59 and 60.

Repeat the same steps for `ad-hoc-workflow.yml` (same repository, same connection) to create the second, separate trigger pipeline — it's a different pipeline definition from the first, since each YAML file gets its own definition when pointed to from Pipelines → New Pipeline.

`example-ado-pipelines` itself never gets a pipeline definition — it holds shared templates (`azure-devops/templates/`) and the downstream pipeline definitions (59/60/62's YAML), none of which are self-triggered; they're only reached via `extends:` or queued via `az pipelines run`.

## 6. Grant permissions to queue the build and upgrade pipelines (59, 60, and 62 in this example)

The orchestrators run as the project's build service identity (e.g. `Example Build Service (dbmsc)` — the exact name follows the pattern `<project> Build Service (<org>)`), which needs explicit rights on every pipeline they queue with custom parameters. Without this, runs fail with `TF215106` access-denied errors.

Repeat for **each** of pipeline 59 (Build and Precheck Package - Source Control), pipeline 60 (Upgrade Environment), and pipeline 62 (Build with Git Change Detection) — every pipeline either orchestrator queues via `az pipelines run` needs this, regardless of which orchestrator queues it:

1. Open the pipeline in the ADO UI.
2. Open the "⋮" (more actions) menu → **Security**.
3. Find (or add) the project's Build Service identity.
4. Set **Queue builds** to **Allow**.
5. Set **Edit queue build configuration** to **Allow** (needed because the workflow overrides parameters at queue time).
6. Save.

> Both permissions can instead be granted once at the project level (Project Settings → Pipelines → Settings/Security) to cover all pipelines rather than doing this three times.

## 7. Create the four approval-gate environments

Both workflows share the same four gates. For each, create an Azure DevOps Environment and attach a manual Approval check:

1. Go to Pipelines → Environments → New environment.
2. Name it exactly as referenced in the YAML: `Integration-pre-approval`, `Integration-post-approval`, `Production-pre-approval`, or `Production-post-approval`.
3. Resource: choose **None** — these environments exist only to host an approval check, not to represent an actual deployment target.
4. Create. Then open the environment → "⋮" → **Approvals and checks** → Add check → **Approvals**.
5. Add the approver(s) for that gate and save.

> **Renaming these environments** doesn't require touching either template: `integrationPreApprovalEnvironment`, `integrationPostApprovalEnvironment`, `productionPreApprovalEnvironment`, and `productionPostApprovalEnvironment` are template parameters (each defaulting to the names above) — just override them in the wrapper YAML's `extends: parameters:` block to whatever names you created your environments with.
>
> **Adding more gates** (e.g. a QA environment ahead of Integration) is different — the number and sequence of stages is hardcoded in `azure-devops/templates/source-control-workflow.yml`/`ad-hoc-workflow.yml`, not driven by parameters. That requires actually editing the template: add a new stage modeled on the existing pre-approval/upgrade/post-approval trio, wire its `dependsOn` into the chain, and add a corresponding environment parameter for its name. Since the template is shared by every DBmaestro project's source-control repo, this change affects all of them at once.

Suggested approver assignment once fully rolled out:

| Environment | Approver |
|---|---|
| `Integration-pre-approval` | approver1@dbmaestro.com |
| `Integration-post-approval` | approver1@dbmaestro.com |
| `Production-pre-approval` | approver2@dbmaestro.com |
| `Production-post-approval` | approver2@dbmaestro.com |

For initial testing, all four environments were instead assigned the same single approver so the whole chain could be validated end to end before splitting responsibilities between two reviewers as shown above.

Since neither workflow verifies success automatically (section 4a), whoever approves each gate should confirm the previous run actually succeeded first — the "Queue" steps print the run's URL to check.

### 7a. First-run resource authorization (separate from the approval check)

The first time either orchestrator's run actually reaches each environment, Azure DevOps pauses with a banner like:

```
This pipeline needs permission to access a resource before this run can continue to Integration - Post-Approval Gate
This pipeline needs permission to access a resource before this run can continue to Production - Pre-Approval Gate
```

This is a **one-time authorization per (pipeline, environment) pair**, distinct from the Approval check configured above — it exists because a YAML pipeline isn't automatically allowed to use any environment resource it references, even ones with no approval check at all. Expect to see this once for each of the four environments the first time each orchestrator runs end to end — that's up to eight prompts total across both workflows the first time each is exercised, not four.

To resolve it:

1. Open the run in the ADO UI — it'll show a **"View"** / **"Permission"** prompt on the waiting stage.
2. Click **Permit** (a project Administrator or someone with **Manage** permission on that environment can do this; approving the check itself is not enough).
3. Optionally check **"Permit for all pipelines"** while permitting, or pre-authorize it ahead of time via the environment → "⋮" → **Security** → grant the pipeline access — either avoids hitting this prompt again on future runs of the same pipeline.

Until it's permitted, the stage sits waiting on this authorization screen and never even reaches the Approval check — so if a gate seems stuck, check for this prompt before assuming the Approval check itself is misconfigured.

## 8. Failure notifications (build pipeline — 59 in this example)

Azure DevOps' built-in notification subscriptions email a distribution list whenever pipeline 59 fails — no SMTP or pipeline code involved.

1. Project Settings (`Example` project) → Notifications → New subscription (project/shared subscriptions section; requires Project Administrator rights).
2. Category: **Build**. Template: **"A build completes."**
3. Filter: **Definition name** = `Build and Precheck Package - Source Control`.
4. Filter: **Status** = `Failed`.
5. Deliver to → **Custom email address** → `devops@dbmaestro.com`.
6. Save.

Consider adding equivalent subscriptions filtered to `Upgrade Environment` (definition 60) and `Build with Git Change Detection` (definition 62), both with Status = Failed, so upgrade and ad-hoc build failures reach the same distribution list too. This matters more now that gates rely on a human noticing failures rather than the orchestrator stopping automatically.

## 9. Friendly run names for the build and upgrade pipelines (59 and 60 in this example)

By default, Azure DevOps run names show a generic build number like `#20260727.2` alongside whatever the latest commit message happens to be on that pipeline's own source repo — not necessarily anything meaningful. Both target pipelines set a custom build number format so each run in the ADO UI immediately shows what it's building:

- `build-source-control.yml`: `name: 'TaskID-${{ parameters.packageName }} ($(Date:yyyyMMdd)$(Rev:.r))'` → e.g. `TaskID-TASK-42 (20260727.2)`
- `upgrade-environment.yml`: `name: '${{ parameters.targetEnvironment }} - TaskID-${{ parameters.packageNames }} ($(Date:yyyyMMdd)$(Rev:.r))'` → e.g. `Integration - TaskID-TASK-42 (20260727.2)`

Note the dash (`TaskID-`) rather than a colon: Azure DevOps build numbers reject `"`, `/`, `:`, `<`, `>`, `\`, `|`, `?`, `@`, and `*`, and a colon in an earlier version of this format caused every run to fail with "contains invalid character(s)." This is purely cosmetic otherwise — it doesn't change any pipeline behavior, only how each run is labeled in the Runs list.

## 10. Troubleshooting

General setup issues, common to both workflows. For issues specific to one workflow's own stages — TaskID extraction, git-diff detection, `stageDependencies`/`dependencies` expression syntax, and so on — see the Troubleshooting section in [`source-control-workflow.md`](./source-control-workflow.md) or [`ad-hoc-workflow.md`](./ad-hoc-workflow.md).

| Symptom | Fix |
|---|---|
| `ERROR: Repository dbmaestro-cicd references endpoint dbmaestro-cicd which does not exist or is not authorized for use` | The `dbmaestro-cicd` GitHub service connection doesn't exist in this project (or isn't authorized), or its name doesn't exactly match the `endpoint:` value (check for typos) — see section 4. |
| `##[error]No hosted parallelism has been purchased or granted` | This org has 0 Microsoft-hosted parallel jobs. Don't switch pools to a `vmImage` — use the self-hosted `dbmaestro-windows` pool already configured everywhere, and rely on the fire-and-forget design (section 3a). |
| `##[error]Unable to locate executable file: 'bash'` | The agent is Windows and has no bash on PATH. All steps in these pipelines use `pwsh:` instead of `bash:` for exactly this reason — if you still see this, a step somewhere is still using `bash:`. `powershell:` (Windows PowerShell 5.1) is not a substitute here: the `dbmaestro-cicd` templates hardcode `pwsh: true`, so PowerShell 7+ must actually be installed (section 2) — see also the next row. |
| `##[error]'pwsh' task detected. This task requires PowerShell version >= 6 and PowerShell not found on specified path` (or agent errors resolving `pwsh`) | PowerShell 7+ isn't installed on the agent, or the agent service was never restarted after installing it. This isn't optional/fallback-able — every Windows-path step in the `dbmaestro-cicd` templates hardcodes `pwsh: true` — see section 2. |
| `az : The term 'az' is not recognized as the name of a cmdlet, function, script file, or operable program.` | Azure CLI isn't installed on the agent (or the agent service was never restarted after installing it) — see section 4a. |
| `java : The term 'java' is not recognized as the name of a cmdlet, function, script file, or operable program.` | Java isn't installed on the agent, or isn't on the PATH the agent service sees (or the agent service was never restarted after installing it) — see section 2. Every DBmaestro template step (`build-from-source`, `precheck-package`, `create-package`, `tag-package`) needs `java` to run `DBmaestroAgent.jar`. |
| Build number generation fails with "contains invalid character(s)" mentioning `:` | A custom `name:` format included a literal colon (e.g. `TaskID: X`). Build numbers can't contain `"`, `/`, `:`, `<`, `>`, `\`, `|`, `?`, `@`, or `*` — use a dash or space instead (see section 9). |
| `TF215106: ... needs Queue builds permissions for build pipeline 59/60/62 ...` | Grant Queue builds = Allow to the project's Build Service identity on that pipeline's Security panel (see section 6). |
| `TF215106: ... needs Edit queue build configuration permissions ...` | Grant Edit queue build configuration = Allow to the same identity on the same Security panel. |
| Stage stays "Waiting" indefinitely at a gate | Expected — that's the approval check. Open the run in the ADO UI and approve/reject the pending environment check. If no one is ever prompted, confirm the Approval check is actually attached to that environment (section 7). |
| `This pipeline needs permission to access a resource before this run can continue to <environment>` | One-time resource authorization, separate from the Approval check — see section 7a. Someone with Manage permission on that environment must click **Permit** (optionally "for all pipelines") before the stage will even reach the Approval check. Expect this once per (pipeline, environment) pair on first use. |
| A gate was approved but the downstream run actually failed | Fire-and-forget means nothing catches this automatically (section 3a) — the approver needs to check the run before approving. Consider re-enabling the commented-out polling code in the relevant template if/when a second parallel job becomes available. |
| The precheck step (or another build/upgrade step) failed and you need to retry with a fix | Push a new commit with the fix — this triggers a brand-new orchestrator run (a new pipeline instance) starting from Build, with a fresh precheck against the corrected package. Then **cancel the original failed run** so it doesn't linger as an incomplete/failed run in the Runs list. Don't try to fix and resume the existing failed run in place. |
| `extends` template not found, or a parameter is rejected as unexpected | The `adoPipelines` resource in the thin trigger file doesn't resolve (check the service connection note in section 2), or a parameter name/spelling in the trigger file's `extends: parameters:` block doesn't match what the corresponding template under `azure-devops/templates/` actually declares. |

