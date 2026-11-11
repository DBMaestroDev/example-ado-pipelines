# GitHub Commit to Prod_Env_1: Full Release Workflow

*Setup runbook — example-ado-source-control → Release Source → UAT_Env_1 → Pre_Prod_Env_1 → Prod_Env_1, with approval gates and failure notification*

## 1. Goal

On every commit to the `example-ado-source-control` GitHub repository (main branch, excluding pushes that only touch a root-level pipeline YAML), automatically build and upgrade each environment in turn — Release Source, UAT_Env_1, Pre_Prod_Env_1, then Prod_Env_1 — behind a manual pre-approval gate per environment, plus one extra "review the built package" gate in front of Prod_Env_1's final upgrade. This is the **state-based** workflow: each environment gets its own package, built by diffing the triggering commit against that environment's own current live state (not one shared package reused everywhere).

There's a second, separate workflow for **ad-hoc** packages: unlike the flow above, it isn't triggered by a git push at all, and it doesn't build anything. A DBmaestro DOP hook script queues it directly — after a precheck task completes, the hook inspects the package's `TypeId` and, only when that identifies the package as Ad-hoc, queues `ad-hoc-workflow.yml` with the already-built package's name. It just upgrades every environment with that package, inline, behind the same four pre-approval gates as the state-based workflow reuses — see `ad-hoc-workflow.md` section 3.

`example-ado-source-control` isn't a one-off — it's the pattern for the repo **every individual DBmaestro project** needs one of. Each DBmaestro project gets its own copy of this repo (same two wrapper files, its own parameter values), so a commit to that project's own repo drives that project's own release chain independently of any other project's. `example-ado-pipelines` (this repo) hosts one-time setup (this file) plus the shared pipeline logic reused by every one of those project repos. The chains themselves — stages, parameters, troubleshooting specific to each — are documented separately:

- [`state-based-workflow.md`](./state-based-workflow.md) — the push-triggered, per-environment-build flow described above.
- [`ad-hoc-workflow.md`](./ad-hoc-workflow.md) — the DOP-hook-triggered, inline-upgrade ad-hoc flow.

## 2. Prerequisites

> **A note on specific values below:** this guide documents one real deployment, so it names concrete values throughout (an org, a project, a pool name, and so on). None of these are requirements of the design — they're just what this instance happens to use. Your organization/project names will differ. Substitute your own values throughout; the table below is the full list of what to swap.

| Item | Value used in this guide |
|---|---|
| Azure DevOps organization | `dbmsc` |
| Azure DevOps project (where the two pipelines live) | `Example` |
| DBmaestro project name (`dBmaestroProjectName` orchestrator parameter — DBmaestro's own internal project concept, unrelated to the ADO project above) | `Example-ADO` |
| DBmaestro source environment the state-based workflow builds every package from | `Dev_Env_1` — hardcoded in `azure-devops/templates/state-based-workflow.template.yml`, not a parameter |
| Self-hosted agent pool | `dbmaestro-windows` |
| GitHub org hosting `example-ado-pipelines` and `example-ado-source-control` (**your own** org — this guide's example deployment happens to use `DBMaestroDev`, but yours won't) | *your GitHub org* |
| Failure-notification distribution list | `devops@dbmaestro.com` |
| Gate approvers | `approver1@dbmaestro.com`, `approver2@dbmaestro.com` |

- GitHub service connection **"GitHub using Azure Pipelines app"**, connected to the GitHub org that hosts **your** `example-ado-pipelines` and `example-ado-source-control`. Since both of your repos live in the same org, this one connection also serves as the `endpoint:` for the `adoPipelines` resource entry in both wrapper YAML files (`state-based-workflow.yml` and `ad-hoc-workflow.yml`) — no separate connection needed. If your connection is scoped per-repository rather than org-wide, it needs explicit access to both repos; otherwise register a second connection and update the relevant `endpoint:` value to match.
- A registered self-hosted **Windows** agent in the **`dbmaestro-windows`** pool, with **PowerShell 7+ (`pwsh`)** installed. Both workflows' jobs run on this one pool (`pool: dbmaestro-windows`, or the `runnerPool` template parameter, which defaults to `'DBMaestro'` in `state-based-workflow.yml`'s template but is explicitly overridden to `'dbmaestro-windows'` by both wrapper files). **PowerShell 7+ is a hard requirement, not a fallback-able one:** every step in both templates uses `pwsh:` rather than `bash:`, since Windows agents have no `bash` on PATH by default, and `powershell:` (Windows PowerShell 5.1) isn't a substitute for the inline `java -jar` calls either — they're written as `pwsh:` steps directly, so PowerShell 7+ must actually be installed. If `pwsh` is missing from an agent, install PowerShell 7+ (`winget install --id Microsoft.PowerShell` or the MSI from https://aka.ms/PSWindows) and **restart the Azure Pipelines agent service** afterward — a service started before the install won't see the new PATH.
- **Java installed on the `dbmaestro-windows` agent(s), with `java` on PATH.** Every inline step in both templates (`CustomBuild`, `RunPackageAsAdHoc`/`Upgrade`) shells out to `java -jar "$agentJarPath" ...` to run the DBmaestro CLI agent (`DBmaestroAgent.jar`). If Java isn't installed, or is installed but not on the PATH the agent service sees, every one of these steps fails immediately with something like `'java' is not recognized as an internal or external command` (or the equivalent `The term 'java' is not recognized...` in PowerShell). Remember to **restart the Azure Pipelines agent service** after installing Java — a service started before the install won't pick up the new PATH.
- **Azure CLI (`az`) is *not* needed on the `dbmaestro-windows` agent.** Neither workflow queues another pipeline or calls `az` from its own jobs — both run every stage inline within the one pipeline. The only place `az` is still required is wherever the DBmaestro DOP hook script itself runs (see `ad-hoc-workflow.md` section 4) — that's a separate machine/context from the ADO agent pool.
- **Pipeline variables on both `state-based-workflow.yml` and `ad-hoc-workflow.yml`** (set as Variables on each pipeline, or once in a shared Variable Group under Pipelines → Library, referenced by both) — their inline `java -jar` steps reference these variables directly, with no downstream pipeline in between:
  - `DBMAESTRO_SERVER` — the DBmaestro server address, passed as `-Server` to every inline `java -jar` call. Format is `host:port`, e.g. `dop.dbmaestro.local:8017` — not a URL (no `http(s)://`).
  - Authentication — both workflows' inline calls pass `-AccessTokenFilePath "$(DBMAESTRO_ACCESS_TOKEN_FILE_PATH)"`, so set `DBMAESTRO_ACCESS_TOKEN_FILE_PATH` on both pipelines to the path of the file containing the access token. If you'd rather authenticate with a username/password instead, both templates need editing — swap the `-AccessTokenFilePath` flag on every inline call for whatever flags `DBmaestroAgent.jar` expects for that mode, then set `DBMAESTRO_USER`/`DBMAESTRO_PASSWORD` (mark the latter **secret**) as pipeline variables and reference them there instead. This is a YAML change, not just a variable-setting one.
  - `agentJarPath` (a parameter on both pipelines) already defaults to `C:\Program Files (x86)\DBmaestro\DOP Server\Agent\DBmaestroAgent.jar`, the DBmaestro CLI JAR's standard install location — so by default both workflows use the JAR already on the agent. Override the parameter in a wrapper's `extends: parameters:` block if yours lives elsewhere.

## 3. Two release workflows, one shared template repo

Both `state-based-workflow.yml` and `ad-hoc-workflow.yml` follow the same shape: a thin wrapper file living in `example-ado-source-control`, which `extends:` a template holding the actual multi-stage pipeline, stored once in this `example-ado-pipelines` repo under `azure-devops/templates/`. `state-based-workflow.yml` needs its wrapper there because Azure DevOps only self-triggers off YAML committed in the triggering repo; `ad-hoc-workflow.yml` isn't self-triggered at all (it's `trigger: none`, queued manually or by a DBmaestro DOP hook instead — see `ad-hoc-workflow.md` section 4) but still needs its pipeline *definition* registered from a file living in one of its repos, same as any ADO pipeline:

- [`azure-devops/templates/state-based-workflow.template.yml`](./azure-devops/templates/state-based-workflow.template.yml) — extended by `example-ado-source-control/state-based-workflow.yml`.
- [`azure-devops/templates/ad-hoc-workflow.template.yml`](./azure-devops/templates/ad-hoc-workflow.template.yml) — extended by `example-ado-source-control/ad-hoc-workflow.yml`.

The point of this split: each DBmaestro project's own `example-ado-source-control`-pattern repo only needs an equally thin trigger file of its own (same shape, its own parameter values) — not a copy of the whole pipeline. Any future fix to either chain happens once, in its template, rather than being re-applied across every project's source-control repo.

Full stage-by-stage detail, parameters, and workflow-specific troubleshooting live in [`state-based-workflow.md`](./state-based-workflow.md) and [`ad-hoc-workflow.md`](./ad-hoc-workflow.md).

### 3a. Everything runs inline — no queued downstream pipeline, no polling

Earlier versions of this repo split building and upgrading across separate, independently-queued pipeline definitions, which meant an orchestrator had to queue a downstream run and then somehow wait on it — awkward on an ADO organization with only **1 self-hosted parallel job**, since a job that polls a queued run in a loop would hold the only available slot for the whole wait.

Both current workflows avoid that problem entirely by not queuing anything: every stage — build, approval gate, upgrade — runs as part of the *same* pipeline run, either as an inline `pwsh:` step calling `java -jar DBmaestroAgent.jar` directly, or as a `deployment` job gated on an Environment's Approval check. Approval checks cost nothing while pending (no agent, no slot), so a single parallel job is enough to run a whole multi-environment chain: the agent is only occupied for the seconds an inline build/upgrade step actually takes, and sits idle (using no slot) while a gate waits on a human.

One consequence worth knowing: because every stage lives in one pipeline run, a failed build or upgrade step fails its own stage directly (non-zero exit code), and everything depending on it is skipped automatically — there's no separate "did the thing I just queued actually succeed?" check for an approver to do by hand.

## 4. Create the ADO pipeline definitions

*(Already done if you set up an earlier version of this pipeline — this step only applies the first time, or if you need to recreate one after moving repos.)*

1. Go to Pipelines → New Pipeline.
2. Choose GitHub, then select the DBMaestroDev / example-ado-source-control repository (using the existing "GitHub using Azure Pipelines app" connection).
3. Point it at `state-based-workflow.yml`.
4. Save.

Repeat the same steps for `ad-hoc-workflow.yml` (same repository, same connection) to create the second pipeline definition — it's a different pipeline definition from the first, since each YAML file gets its own definition when pointed to from Pipelines → New Pipeline. Unlike `state-based-workflow.yml`, this one is never triggered by a push — see section 5 for granting the DBmaestro DOP hook the rights it needs to queue it instead, and `ad-hoc-workflow.md` section 4 for how the hook decides when to do so.

`example-ado-pipelines` itself never gets a pipeline definition — it holds shared templates (`azure-devops/templates/`), which are only reached via `extends:`.

## 5. Grant the DOP hook permission to queue the ad-hoc pipeline

Only `ad-hoc-workflow.yml` is ever queued programmatically (by the DBmaestro DOP hook script, via `az pipelines run --parameters "packageName=..."` — see `ad-hoc-workflow.md` section 4); `state-based-workflow.yml` is self-triggered by a push and is never queued this way. The identity behind the hook's PAT (configured as `$PAT`/`$ADOOrganization` in `hooks/paradigm-hook_adhoc_test.ps1`) needs explicit permission to queue `ad-hoc-workflow.yml` with custom parameters — without it, the queue attempt fails with a `TF215106` access-denied error:

1. Open the `ad-hoc-workflow.yml` pipeline in the ADO UI.
2. Open the "⋮" (more actions) menu → **Security**.
3. Find (or add) the DOP hook's own identity.
4. Set **Queue builds** to **Allow**.
5. Set **Edit queue build configuration** to **Allow** (needed because the caller overrides the `packageName` parameter at queue time).
6. Save.

> This can instead be granted once at the project level (Project Settings → Pipelines → Settings/Security) to cover all pipelines.

## 6. Create the five approval-gate environments

`state-based-workflow.yml` uses five gates: a pre-approval gate per environment across Release Source, UAT_Env_1, Pre_Prod_Env_1, and Prod_Env_1, plus one extra "review package" gate in front of Prod_Env_1's final upgrade. `ad-hoc-workflow.yml` only uses four — just the pre-approval gate for each of those same environments (it has no review/post-approval stage at all; see `ad-hoc-workflow.md` section 1) — reusing the same four `<Env>-pre-approval` environments rather than provisioning its own. Create all five regardless, since `state-based-workflow.yml` needs the review-package one too:

1. Go to Pipelines → Environments → New environment.
2. Name it exactly as referenced in the YAML: `Release-Source-pre-approval`, `UAT_Env_1-pre-approval`, `Pre_Prod_Env_1-pre-approval`, `Prod_Env_1-pre-approval`, or `Prod_Env_1-review-package`.
3. Resource: choose **None** — these environments exist only to host an approval check, not to represent an actual deployment target.
4. Create. Then open the environment → "⋮" → **Approvals and checks** → Add check → **Approvals**.
5. Add the approver(s) for that gate and save.

> **Renaming these environments** doesn't require touching either template: `state-based-workflow.yml` has `releaseSourcePreApprovalEnvironment`, `uatEnv1PreApprovalEnvironment`, `preProdEnv1PreApprovalEnvironment`, `prodEnv1PreApprovalEnvironment`, and `prodEnv1ReviewPackageEnvironment`; `ad-hoc-workflow.yml` has just the four `*PreApprovalEnvironment` parameters. All are template parameters (each defaulting to the names above) — just override them in the wrapper YAML's `extends: parameters:` block to whatever names you created your environments with.
>
> **Adding more gates** (e.g. an additional environment ahead of Prod_Env_1) is different — the number and sequence of stages is hardcoded in `azure-devops/templates/state-based-workflow.template.yml`/`ad-hoc-workflow.template.yml`, not driven by parameters. That requires actually editing the template: add a new stage modeled on the existing pre-approval/build/upgrade pattern, wire its `dependsOn` into the chain, and add a corresponding environment parameter for its name. Since the template is shared by every DBmaestro project's source-control repo, this change affects all of them at once.

Suggested approver assignment once fully rolled out:

| Environment | Approver |
|---|---|
| `Release-Source-pre-approval` | approver1@dbmaestro.com |
| `UAT_Env_1-pre-approval` | approver1@dbmaestro.com |
| `Pre_Prod_Env_1-pre-approval` | approver2@dbmaestro.com |
| `Prod_Env_1-pre-approval` | approver2@dbmaestro.com |
| `Prod_Env_1-review-package` (state-based-workflow.yml only) | approver2@dbmaestro.com |

For initial testing, all five environments were instead assigned the same single approver so the whole chain could be validated end to end before splitting responsibilities between two reviewers as shown above.

### 6a. First-run resource authorization (separate from the approval check)

The first time either workflow's run actually reaches each environment, Azure DevOps pauses with a banner like:

```
This pipeline needs permission to access a resource before this run can continue to UAT_Env_1 - Pre-Approval Gate
This pipeline needs permission to access a resource before this run can continue to Prod_Env_1 - Review Package Gate
```

This is a **one-time authorization per (pipeline, environment) pair**, distinct from the Approval check configured above — it exists because a YAML pipeline isn't automatically allowed to use any environment resource it references, even ones with no approval check at all. Expect to see this once for each environment the first time each workflow runs end to end: up to five prompts the first time `state-based-workflow.yml` runs (all five gates), and up to four the first time `ad-hoc-workflow.yml` runs (just the four pre-approval gates it actually uses) — nine total across both workflows.

To resolve it:

1. Open the run in the ADO UI — it'll show a **"View"** / **"Permission"** prompt on the waiting stage.
2. Click **Permit** (a project Administrator or someone with **Manage** permission on that environment can do this; approving the check itself is not enough).
3. Optionally check **"Permit for all pipelines"** while permitting, or pre-authorize it ahead of time via the environment → "⋮" → **Security** → grant the pipeline access — either avoids hitting this prompt again on future runs of the same pipeline.

Until it's permitted, the stage sits waiting on this authorization screen and never even reaches the Approval check — so if a gate seems stuck, check for this prompt before assuming the Approval check itself is misconfigured.

## 7. Failure notifications

Azure DevOps' built-in notification subscriptions email a distribution list whenever a pipeline run fails — no SMTP or pipeline code involved.

1. Project Settings (`Example` project) → Notifications → New subscription (project/shared subscriptions section; requires Project Administrator rights).
2. Category: **Build**. Template: **"A build completes."**
3. Filter: **Definition name** = the name you gave the `state-based-workflow.yml` pipeline definition (section 4).
4. Filter: **Status** = `Failed`.
5. Deliver to → **Custom email address** → `devops@dbmaestro.com`.
6. Save.

Repeat with **Definition name** set to the `ad-hoc-workflow.yml` pipeline definition if you also want failure emails for the ad-hoc flow. Since both workflows run every build/upgrade step inline and fail their own stage on a non-zero exit code, a single subscription per pipeline definition is enough — there's no separate downstream pipeline whose failures could otherwise go unnoticed.

## 8. Friendly run names

By default, Azure DevOps run names show a generic build number like `#20260727.2` alongside whatever the latest commit message happens to be — not necessarily anything meaningful. `ad-hoc-workflow.yml` sets a custom build number format so each run in the ADO UI immediately shows what it's upgrading:

- `example-ado-source-control/ad-hoc-workflow.yml`: `name: 'Package-${{ parameters.packageName }} ($(Date:yyyyMMdd)$(Rev:.r))'` → e.g. `Package-9cf7a43-Release-Source (20260827.2)`.

`state-based-workflow.yml` doesn't currently override its run name — each environment's package name (visible inside the run's own logs/variables) already follows the `<7-char-commit>-<TargetEnvName>` pattern described in `state-based-workflow.md`, e.g. `50f5aac-Release-Source`.

Azure DevOps build numbers reject `"`, `/`, `:`, `<`, `>`, `\`, `|`, `?`, `@`, and `*` — use a dash or space instead of a colon if you add a custom `name:` format of your own.

## 9. Troubleshooting

General setup issues, common to both workflows. For issues specific to one workflow's own stages — package naming, `stageDependencies`/`dependsOn` expression syntax, and so on — see the Troubleshooting section in [`state-based-workflow.md`](./state-based-workflow.md) or [`ad-hoc-workflow.md`](./ad-hoc-workflow.md).

| Symptom | Fix |
|---|---|
| `##[error]No hosted parallelism has been purchased or granted` | This org has 0 Microsoft-hosted parallel jobs. Don't switch pools to a `vmImage` — use the self-hosted `dbmaestro-windows` pool already configured everywhere (section 3a explains why one parallel job is enough for either workflow). |
| `##[error]Unable to locate executable file: 'bash'` | The agent is Windows and has no bash on PATH. Every step in both templates uses `pwsh:` instead of `bash:` for exactly this reason — if you still see this, a step somewhere is still using `bash:`. `powershell:` (Windows PowerShell 5.1) is not a substitute — PowerShell 7+ must actually be installed (section 2). |
| `##[error]'pwsh' task detected. This task requires PowerShell version >= 6 and PowerShell not found on specified path` (or agent errors resolving `pwsh`) | PowerShell 7+ isn't installed on the agent, or the agent service was never restarted after installing it — see section 2. |
| `java : The term 'java' is not recognized as the name of a cmdlet, function, script file, or operable program.` | Java isn't installed on the agent, or isn't on the PATH the agent service sees (or the agent service was never restarted after installing it) — see section 2. Every inline `CustomBuild`/`Upgrade` step needs `java` to run `DBmaestroAgent.jar`. |
| Build number generation fails with "contains invalid character(s)" mentioning `:` | A custom `name:` format included a literal colon (e.g. `Package: X`). Build numbers can't contain `"`, `/`, `:`, `<`, `>`, `\`, `|`, `?`, `@`, or `*` — use a dash or space instead (see section 8). |
| `TF215106: ... needs Queue builds permissions ...` when the DOP hook queues `ad-hoc-workflow.yml` | Grant Queue builds = Allow to the DOP hook's own identity (the account behind its PAT) on the `ad-hoc-workflow.yml` pipeline's Security panel — not any other identity, since only that pipeline is ever queued programmatically (see section 5). |
| `TF215106: ... needs Edit queue build configuration permissions ...` | Grant Edit queue build configuration = Allow to the same identity on the same Security panel. |
| Stage stays "Waiting" indefinitely at a gate | Expected — that's the approval check. Open the run in the ADO UI and approve/reject the pending environment check. If no one is ever prompted, confirm the Approval check is actually attached to that environment (section 6). |
| `This pipeline needs permission to access a resource before this run can continue to <environment>` | One-time resource authorization, separate from the Approval check — see section 6a. Someone with Manage permission on that environment must click **Permit** (optionally "for all pipelines") before the stage will even reach the Approval check. Expect this once per (pipeline, environment) pair on first use. |
| The build or upgrade step failed and you need to retry with a fix | For `state-based-workflow.yml`: push a new commit with the fix — this triggers a brand-new run starting from Init, with a fresh build against the corrected commit. Then **cancel the original failed run** so it doesn't linger as an incomplete/failed run in the Runs list. For `ad-hoc-workflow.yml`: get DOP to re-run its precheck task against the corrected package so the DOP hook queues a fresh run; cancel the original failed run the same way. Don't try to fix and resume an existing failed run in place, in either case. |
| `extends` template not found, or a parameter is rejected as unexpected | The `adoPipelines` resource in the thin wrapper file doesn't resolve (check the service connection note in section 2), or a parameter name/spelling in the wrapper's `extends: parameters:` block doesn't match what the corresponding template under `azure-devops/templates/` actually declares. |
| This pipeline never gets queued by DOP at all | Check the DOP hook script's own log (`hooks/logs/`) — confirm DOP invoked it and the package's `TypeId` was 2 (Ad-hoc). Any other `TypeId` is expected to be skipped by design — see `ad-hoc-workflow.md` section 4. |
