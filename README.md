# GitHub Commit to Production: Full Release Workflow

*Setup runbook — example-ado-source-control → Build → Integration → Production, with approval gates and failure notification*

## 1. Goal

On every commit to the `example-ado-source-control` GitHub repository, automatically: build a DBmaestro package, gate on manual approval, upgrade the integration environment, gate on manual confirmation, gate on manual approval again, upgrade the production environment, and gate on a final manual confirmation. Values are parsed from the commit message rather than entered by hand.

## 2. Why a direct trigger doesn't work

Azure Pipelines' repository resource trigger (`resources.repositories[].trigger`) only fires for Azure Repos Git repositories, never for GitHub (or Bitbucket) resources — a structural limitation independent of the service connection or auth method used.

The workaround is a pipeline whose own source repository is `example-ado-source-control`. Because it's the pipeline's self repo, GitHub push triggers work natively (the existing "GitHub using Azure Pipelines app" service connection manages the webhook automatically). This pipeline reads the triggering commit, extracts parameters, and orchestrates the rest of the workflow by queuing the other pipelines via the Azure DevOps CLI/REST API.

## 3. Prerequisites

- GitHub service connection **"GitHub using Azure Pipelines app"**, connected to the DBMaestroDev GitHub org.
- Pipeline **"Build and Precheck Package - Source Control"** — org `dbmsc`, project `Example`, definition ID **59**. `packageName` has no default, so it's always required. `tasksList` technically has a default (`'none'`), but the pipeline's own validation step fails the run if `buildType` is left at its default (`'Specific Tasks'`) and `tasksList` is `'none'`/empty — so in practice both `packageName` and `tasksList` must be supplied. This workflow sets both to the extracted TaskID.
- Pipeline **"Upgrade Environment"** — org `dbmsc`, project `Example`, definition ID **60**. All of its parameters (`targetEnvironment`, `packageNames`, `tagName`, `projectName`, `agentJarPath`, `runnerPool`) have defaults; the workflow explicitly sets `targetEnvironment` and `packageNames`. `targetEnvironment` only accepts `'Integration'` or `'Production'` (case-sensitive, `'qa'` was dropped) — the orchestrator must pass those exact strings.
- A GitHub service connection named exactly **`dbmaestro-cicd`**, authorized in this project and pointed at `DBMaestroDev/dbmaestro-cicd`. Both `build-source-control.yml` and `upgrade-environment.yml` declare this as a second `resources.repositories` entry (`endpoint: dbmaestro-cicd`) so they can check out DBmaestro's reusable pipeline templates. Without this exact-named, authorized connection, both pipelines fail immediately with `Repository dbmaestro-cicd references endpoint dbmaestro-cicd which does not exist or is not authorized for use` — see section 7.
- A registered self-hosted agent in the **`dbmaestro-windows`** pool (used directly by the orchestrator's own jobs) and one in the **`Default`** pool (used by `build-source-control.yml`/`upgrade-environment.yml` via their `runnerPool` parameter default). These are two separate pool names as currently configured — confirm whether that's intentional or whether they're meant to be the same pool before relying on this in production.

> **Naming heads-up:** there are two different "project" concepts in play, and they currently have different values. The orchestrator's `targetProject` variable (the actual **Azure DevOps** project pipelines 59/60 live in) is `'Example'`. The `projectName` parameter inside `build-source-control.yml`/`upgrade-environment.yml` (DBmaestro's own internal project concept, unrelated to ADO) defaults to `'Example-ADO'`. Worth double-checking these are supposed to differ before assuming it's a typo.

## 4. Commit message convention

Commits on `example-ado-source-control` must follow this format:

```
<version>; TaskID: <value>

Example:  v1.0.1; TaskID: V1.0.1
```

The value after `TaskID:` is extracted once, in the Build stage, and reused as `packageName` for the build and as `packageNames` for both the integration and production upgrades.

## 5. Workflow architecture

The orchestrator pipeline (`source-control-workflow.yml`, living in `example-ado-source-control`) runs seven stages in sequence, each depending on the previous one:

1. **Build** — extracts the TaskID and queues pipeline 59 (fire-and-forget — see the note on this in section 5a).
2. **Integration pre-approval gate** — Environment `Integration-pre-approval`. Pauses until an approver signs off.
3. **Upgrade (Integration)** — queues pipeline 60 with `targetEnvironment=Integration` (fire-and-forget).
4. **Integration post-approval gate** — Environment `Integration-post-approval`. Confirms the integration upgrade before moving on.
5. **Production pre-approval gate** — Environment `Production-pre-approval`. Pauses until an approver signs off on going to production.
6. **Upgrade (Production)** — queues pipeline 60 with `targetEnvironment=Production` (fire-and-forget).
7. **Production post-approval gate** — Environment `Production-post-approval`. Final confirmation; workflow ends here.

Each gate is a separate Azure DevOps Environment with a manual Approval check configured in the ADO UI, not in code — so who approves any single gate can change later without touching this file.

### 5a. Why "fire-and-forget" instead of "queue and wait"

This ADO organization has exactly **1 self-hosted parallel job** and **0 granted Microsoft-hosted parallel jobs** (confirmed by an explicit CI error when a Microsoft-hosted pool was tried: *"No hosted parallelism has been purchased or granted"*). A job that queues a downstream pipeline and then polls it in a loop until completion would hold the only available slot for the entire wait, so the downstream pipeline could never start — a permanent deadlock.

The fix: every "Queue" step just queues the downstream pipeline and exits immediately, releasing the slot so the downstream run can actually use it. Environment approval checks cost nothing while pending (no agent, no slot), which is what makes this safe with only one parallel job — the queued pipeline runs during the time a human is looking at the next gate.

This means there is **no automatic pass/fail check** built into the orchestrator anymore. That responsibility now falls to whoever approves the next gate:

- Before approving, check that the pipeline just queued actually succeeded (the Runs list, or the failure-notification email — section 11).
- If it failed, **reject** the gate instead of approving it, to stop the workflow rather than letting it continue against a broken build/upgrade.

The original poll-until-complete logic is kept commented out directly under each "Queue" step in the YAML (see section 6), so it's a quick uncomment if this org ever gets a second parallel job.

## 6. Pipeline file (`source-control-workflow.yml` in `example-ado-source-control`)

```yaml
# Full release workflow: triggered by every push to example-ado-source-control.
#
# 1. Build   - extracts TaskID from the commit message, queues (fire-and-forget)
#              "Build and Precheck Package - Source Control" (pipeline 59).
# 2. Gate    - Integration pre-approval  (Environment: Integration-pre-approval)
# 3. Upgrade - queues (fire-and-forget) "Upgrade Environment" (pipeline 60)
#              targeting the 'Integration' environment.
# 4. Gate    - Integration post-approval (Environment: Integration-post-approval)
# 5. Gate    - Production pre-approval   (Environment: Production-pre-approval)
# 6. Upgrade - queues (fire-and-forget) pipeline 60 targeting 'Production'.
# 7. Gate    - Production post-approval  (Environment: Production-post-approval) - finalizes.
#
# Each gate is a separate Azure DevOps Environment with a manual Approval check
# configured in the ADO UI (Pipelines -> Environments). Swapping the approver
# for any single gate never requires touching this file.
#
# NOTE - fire-and-forget by design, not an oversight:
# This organization has exactly 1 self-hosted parallel job and 0 granted
# Microsoft-hosted parallel jobs (confirmed via TF/CI error when we tried
# hosted pools). A job that queues a downstream pipeline and then polls it
# in a loop would hold the only available slot for the entire duration,
# so the downstream pipeline could never start - permanent deadlock.
#
# The fix: every "queue" step below only queues the downstream pipeline and
# exits immediately, releasing the slot so the downstream run can actually
# use it. There is deliberately NO automatic pass/fail check here anymore -
# that responsibility now falls to whoever approves the NEXT gate:
#   - Before approving, check that the pipeline just queued actually
#     succeeded (the Runs list, or the failure-notification email already
#     configured for pipeline 59/60).
#   - If it failed, REJECT the gate instead of approving it, to stop the
#     workflow here rather than letting it continue against a broken build.
# Approval gates themselves cost nothing while pending (no agent, no slot),
# which is what makes this safe with only one parallel job.
#
# Commit message format expected: "<version>; TaskID: <value>"
#   e.g. "v1.0.1; TaskID: V1.0.1"

trigger:
  branches:
    include:
      - main

variables:
  targetOrganization: 'https://dev.azure.com/dbmsc'
  targetProject: 'Example'
  buildPipelineId: '59'     # Build and Precheck Package - Source Control
  upgradePipelineId: '60'   # Upgrade Environment

stages:
  # ------------------------------------------------------------------
  - stage: Build
    displayName: 'Build Package from Commit'
    jobs:
      - job: Build
        pool: dbmaestro-windows
        steps:
          - checkout: self
            fetchDepth: 1

          - bash: |
              set -e
              commitMessage=$(git log -1 --format='%s')
              echo "Message: $commitMessage"

              # Extract the TaskID value: everything after "TaskID:" up to the next ';' or end of line
              taskId=$(echo "$commitMessage" | sed -n 's/.*TaskID:[[:space:]]*\([^;]*\).*/\1/p' | xargs)

              if [ -z "$taskId" ]; then
                echo "##vso[task.logissue type=error]Could not find 'TaskID: <value>' in commit message: $commitMessage"
                exit 1
              fi

              echo "TaskID resolved: $taskId"
              echo "##vso[task.setvariable variable=packageName]$taskId"
              echo "##vso[task.setvariable variable=packageName;isOutput=true]$taskId"
            name: extract
            displayName: 'Extract parameters from commit message'

          - bash: |
              set -e
              az extension add --name azure-devops --only-show-errors
              echo "$SYSTEM_ACCESSTOKEN" | az devops login --organization "$(targetOrganization)"

              runId=$(az pipelines run \
                --organization "$(targetOrganization)" \
                --project "$(targetProject)" \
                --id "$(buildPipelineId)" \
                --parameters packageName="$(packageName)" buildType="Specific Tasks" tasksList="$(packageName)" \
                --query id -o tsv)
              echo "Queued build run: $runId"
              echo "Fire-and-forget: not polling for completion (see NOTE at top of file)."
              echo "Before approving the next gate, confirm this run succeeded: $(targetOrganization)/$(targetProject)/_build/results?buildId=$runId"

              # --- Polling disabled - see NOTE at top of file. ---
              # Kept here (commented out) so it's a one-line re-enable if this
              # org ever gets a 2nd parallel job. Just uncomment and remove
              # the two echo lines above.
              #
              # while true; do
              #   state=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query state -o tsv)
              #   [ "$state" == "completed" ] && break
              #   sleep 15
              # done
              #
              # result=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query result -o tsv)
              # echo "Build run result: $result"
              # if [ "$result" != "succeeded" ]; then
              #   echo "##vso[task.logissue type=error]Build failed (result=$result). See run $runId in pipeline $(buildPipelineId)."
              #   exit 1
              # fi
            displayName: 'Queue: Build with Source Control (fire-and-forget)'
            env:
              SYSTEM_ACCESSTOKEN: $(System.AccessToken)

  # ------------------------------------------------------------------
  - stage: IntegrationPreApproval
    displayName: 'Integration - Pre-Approval Gate'
    dependsOn: Build
    condition: succeeded()
    jobs:
      - deployment: IntegrationPreApprovalGate
        displayName: 'Await Integration pre-approval'
        environment: 'Integration-pre-approval'
        pool: dbmaestro-windows
        strategy:
          runOnce:
            deploy:
              steps:
                - bash: echo "Integration pre-approval granted - proceeding to upgrade."
                  displayName: 'Gate passed'

  # ------------------------------------------------------------------
  - stage: UpgradeIntegration
    displayName: 'Upgrade - Integration'
    dependsOn: IntegrationPreApproval
    condition: succeeded()
    variables:
      packageName: $[ stageDependencies.Build.Build.outputs['extract.packageName'] ]
    jobs:
      - job: UpgradeIntegration
        pool: dbmaestro-windows
        steps:
          - bash: |
              set -e
              az extension add --name azure-devops --only-show-errors
              echo "$SYSTEM_ACCESSTOKEN" | az devops login --organization "$(targetOrganization)"

              runId=$(az pipelines run \
                --organization "$(targetOrganization)" \
                --project "$(targetProject)" \
                --id "$(upgradePipelineId)" \
                --parameters targetEnvironment="Integration" packageNames="$(packageName)" \
                --query id -o tsv)
              echo "Queued upgrade run: $runId"
              echo "Fire-and-forget: not polling for completion (see NOTE at top of file)."
              echo "Before approving the next gate, confirm this run succeeded: $(targetOrganization)/$(targetProject)/_build/results?buildId=$runId"

              # --- Polling disabled - see NOTE at top of file. ---
              # while true; do
              #   state=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query state -o tsv)
              #   [ "$state" == "completed" ] && break
              #   sleep 15
              # done
              #
              # result=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query result -o tsv)
              # echo "Upgrade run result: $result"
              # if [ "$result" != "succeeded" ]; then
              #   echo "##vso[task.logissue type=error]Integration upgrade failed (result=$result). See run $runId in pipeline $(upgradePipelineId)."
              #   exit 1
              # fi
            displayName: 'Queue: Upgrade Environment - Integration (fire-and-forget)'
            env:
              SYSTEM_ACCESSTOKEN: $(System.AccessToken)

  # ------------------------------------------------------------------
  - stage: IntegrationPostApproval
    displayName: 'Integration - Post-Approval Gate'
    dependsOn: UpgradeIntegration
    condition: succeeded()
    jobs:
      - deployment: IntegrationPostApprovalGate
        displayName: 'Confirm Integration upgrade'
        environment: 'Integration-post-approval'
        pool: dbmaestro-windows
        strategy:
          runOnce:
            deploy:
              steps:
                - bash: echo "Integration upgrade confirmed."
                  displayName: 'Gate passed'

  # ------------------------------------------------------------------
  - stage: ProductionPreApproval
    displayName: 'Production - Pre-Approval Gate'
    dependsOn: IntegrationPostApproval
    condition: succeeded()
    jobs:
      - deployment: ProductionPreApprovalGate
        displayName: 'Await Production pre-approval'
        environment: 'Production-pre-approval'
        pool: dbmaestro-windows
        strategy:
          runOnce:
            deploy:
              steps:
                - bash: echo "Production pre-approval granted - proceeding to upgrade."
                  displayName: 'Gate passed'

  # ------------------------------------------------------------------
  - stage: UpgradeProduction
    displayName: 'Upgrade - Production'
    dependsOn: ProductionPreApproval
    condition: succeeded()
    variables:
      packageName: $[ stageDependencies.Build.Build.outputs['extract.packageName'] ]
    jobs:
      - job: UpgradeProduction
        pool: dbmaestro-windows
        steps:
          - bash: |
              set -e
              az extension add --name azure-devops --only-show-errors
              echo "$SYSTEM_ACCESSTOKEN" | az devops login --organization "$(targetOrganization)"

              runId=$(az pipelines run \
                --organization "$(targetOrganization)" \
                --project "$(targetProject)" \
                --id "$(upgradePipelineId)" \
                --parameters targetEnvironment="Production" packageNames="$(packageName)" \
                --query id -o tsv)
              echo "Queued upgrade run: $runId"
              echo "Fire-and-forget: not polling for completion (see NOTE at top of file)."
              echo "Before approving the next gate, confirm this run succeeded: $(targetOrganization)/$(targetProject)/_build/results?buildId=$runId"

              # --- Polling disabled - see NOTE at top of file. ---
              # while true; do
              #   state=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query state -o tsv)
              #   [ "$state" == "completed" ] && break
              #   sleep 15
              # done
              #
              # result=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query result -o tsv)
              # echo "Upgrade run result: $result"
              # if [ "$result" != "succeeded" ]; then
              #   echo "##vso[task.logissue type=error]Production upgrade failed (result=$result). See run $runId in pipeline $(upgradePipelineId)."
              #   exit 1
              # fi
            displayName: 'Queue: Upgrade Environment - Production (fire-and-forget)'
            env:
              SYSTEM_ACCESSTOKEN: $(System.AccessToken)

  # ------------------------------------------------------------------
  - stage: ProductionPostApproval
    displayName: 'Production - Post-Approval Gate (Finalize)'
    dependsOn: UpgradeProduction
    condition: succeeded()
    jobs:
      - deployment: ProductionPostApprovalGate
        displayName: 'Finalize workflow'
        environment: 'Production-post-approval'
        pool: dbmaestro-windows
        strategy:
          runOnce:
            deploy:
              steps:
                - bash: echo "Production upgrade confirmed. Workflow complete."
                  displayName: 'Gate passed'
```

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
3. Name the connection **exactly** `dbmaestro-cicd` (or, if you'd rather use a different name, edit the `endpoint:` value in both `build-source-control.yml` and `upgrade-environment.yml` to match whatever you name it instead).
4. Check "Grant access permission to all pipelines" (or leave it unchecked and explicitly authorize pipelines 59/60 afterward via the connection's Security tab).
5. Save, then re-run the pipeline.

## 8. Create the ADO pipeline definition

*(Already done if you set up an earlier version of this pipeline — this step only applies the first time, or if you need to recreate it after moving repos.)*

1. Go to Pipelines → New Pipeline.
2. Choose GitHub, then select the DBMaestroDev / example-ado-source-control repository (using the existing "GitHub using Azure Pipelines app" connection).
3. Point it at `source-control-workflow.yml`.
4. Save.

This creates the orchestrator pipeline in the same `dbmsc`/`Example` project as pipelines 59 and 60.

## 9. Grant permissions to queue pipelines 59 and 60

The orchestrator runs as the project's build service identity (e.g. `Example Build Service (dbmsc)` — the exact name follows the pattern `<project> Build Service (<org>)`), which needs explicit rights on both target pipelines to queue them with custom parameters. Without this, runs fail with `TF215106` access-denied errors.

Repeat for **each** of pipeline 59 (Build and Precheck Package - Source Control) and pipeline 60 (Upgrade Environment):

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

## 11. Failure notifications (pipeline 59)

Azure DevOps' built-in notification subscriptions email a distribution list whenever pipeline 59 fails — no SMTP or pipeline code involved.

1. Project Settings (`Example` project) → Notifications → New subscription (project/shared subscriptions section; requires Project Administrator rights).
2. Category: **Build**. Template: **"A build completes."**
3. Filter: **Definition name** = `Build and Precheck Package - Source Control`.
4. Filter: **Status** = `Failed`.
5. Deliver to → **Custom email address** → `devops@dbmaestro.com`.
6. Save.

Consider adding an equivalent subscription filtered to `Upgrade Environment` (definition 60) with Status = Failed, so integration/production upgrade failures reach the same distribution list. This matters more now that gates rely on a human noticing failures rather than the orchestrator stopping automatically.

## 12. Test

1. Push a commit to `example-ado-source-control` with a message such as: `v1.0.2; TaskID: TASK-42`
2. Confirm the orchestrator starts, the Build stage extracts `TASK-42`, and pipeline 59 is queued.
3. Check pipeline 59's run and confirm it succeeded before proceeding.
4. At the Integration pre-approval gate, approve the pending check in the ADO UI (Pipelines → the run → the pending environment approval).
5. Confirm the Upgrade (Integration) stage queues pipeline 60 with `targetEnvironment=Integration` and `packageNames=TASK-42`; check that run succeeded.
6. Approve the Integration post-approval gate.
7. Approve the Production pre-approval gate.
8. Confirm the Upgrade (Production) stage queues pipeline 60 with `targetEnvironment=Production` and `packageNames=TASK-42`; check that run succeeded.
9. Approve the Production post-approval gate and confirm the run completes successfully.

## 13. Friendly run names for pipelines 59 and 60

By default, Azure DevOps run names show a generic build number like `#20260727.2` alongside whatever the latest commit message happens to be on that pipeline's own source repo — not necessarily anything meaningful. Both target pipelines set a custom build number format so each run in the ADO UI immediately shows what it's building:

- `build-source-control.yml`: `name: '${{ parameters.packageName }}_$(Date:yyyyMMdd)$(Rev:.r)'` → e.g. `TASK-42_20260727.2`
- `upgrade-environment.yml`: `name: '${{ parameters.targetEnvironment }}_${{ parameters.packageNames }}_$(Date:yyyyMMdd)$(Rev:.r)'` → e.g. `Integration_TASK-42_20260727.2`

This is purely cosmetic — it doesn't change any pipeline behavior, only how each run is labeled in the Runs list.

## 14. Troubleshooting

| Symptom | Fix |
|---|---|
| `ERROR: Repository dbmaestro-cicd references endpoint dbmaestro-cicd which does not exist or is not authorized for use` | The `dbmaestro-cicd` GitHub service connection doesn't exist in this project (or isn't authorized) — see step 7. |
| `##[error]No hosted parallelism has been purchased or granted` | This org has 0 Microsoft-hosted parallel jobs. Don't switch pools to a `vmImage` — use the self-hosted pools already configured (`dbmaestro-windows` for the orchestrator, `Default` for pipelines 59/60), and rely on the fire-and-forget design (section 5a). |
| `TF215106: ... needs Queue builds permissions for build pipeline 59/60 ...` | Grant Queue builds = Allow to the project's Build Service identity on that pipeline's Security panel (see step 9). |
| `TF215106: ... needs Edit queue build configuration permissions ...` | Grant Edit queue build configuration = Allow to the same identity on the same Security panel. |
| Stage stays "Waiting" indefinitely at a gate | Expected — that's the approval check. Open the run in the ADO UI and approve/reject the pending environment check. If no one is ever prompted, confirm the Approval check is actually attached to that environment (step 10). |
| A gate was approved but the downstream run actually failed | Fire-and-forget means nothing catches this automatically (section 5a) — the approver needs to check the run before approving. Consider re-enabling the commented-out polling code (section 6) if/when a second parallel job becomes available. |
| `bash: line N: packageName: command not found` and `ERROR: The 'packageName' parameter is not a valid String` when queuing pipeline 59 | The extract step only set `packageName` with `isOutput=true`. That flag alone doesn't reliably resolve via `$(packageName)` macro syntax in a later step of the *same* job — ADO leaves the literal text unexpanded and bash then tries to run it as a command substitution. Fix: also set the variable as a plain (non-output) variable in the same step, in addition to the isOutput=true one (see the `extract` step in section 6 — both lines are required). |
| Upgrade stage fails immediately with an empty `packageNames` | The `stageDependencies` expression couldn't resolve `extract.packageName` — confirm the Build stage's extraction step is literally named `extract` (the `name:` field) and that it actually set the variable with `isOutput=true`. |
| Build/Upgrade step fails with "Could not find 'TaskID: <value>' ..." | The commit message didn't match the required `<version>; TaskID: <value>` format — amend the commit message and re-push. |
