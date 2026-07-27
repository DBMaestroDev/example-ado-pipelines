# GitHub Commit to Production: Full Release Workflow

*Setup runbook — sc-paradigm1 → Build → Integration → Production, with approval gates and failure notification*

## 1. Goal

On every commit to the `sc-paradigm1` GitHub repository, automatically: build a DBmaestro package, gate on manual approval, upgrade the integration environment, gate on manual confirmation, gate on manual approval again, upgrade the production environment, and gate on a final manual confirmation. Values are parsed from the commit message rather than entered by hand.

## 2. Why a direct trigger doesn't work

Azure Pipelines' repository resource trigger (`resources.repositories[].trigger`) only fires for Azure Repos Git repositories, never for GitHub (or Bitbucket) resources — a structural limitation independent of the service connection or auth method used.

The workaround is a pipeline whose own source repository is `sc-paradigm1`. Because it's the pipeline's self repo, GitHub push triggers work natively (the existing "GitHub using Azure Pipelines app" service connection manages the webhook automatically). This pipeline reads the triggering commit, extracts parameters, and orchestrates the rest of the workflow by queuing the other pipelines via the Azure DevOps CLI/REST API and waiting on their results.

## 3. Prerequisites

- GitHub service connection **"GitHub using Azure Pipelines app"**, connected to the DBMaestroDev GitHub org.
- Pipeline **"Paradigm - Build with Source Control"** — `dbmsc/poc`, definition ID **53**. Its only required parameter (no default) is `packageName`.
- Pipeline **"Paradigm - Upgrade Environment"** — `dbmsc/poc`, definition ID **54**. All of its parameters (`targetEnvironment`, `packageNames`, `tagName`, `projectName`, `agentJarPath`, `runnerPool`) have defaults; the workflow explicitly sets `targetEnvironment` and `packageNames`.

## 4. Commit message convention

Commits on `sc-paradigm1` must follow this format:

```
<version>; TaskID: <value>

Example:  v1.0.1; TaskID: V1.0.1
```

The value after `TaskID:` is extracted once, in the Build stage, and reused as `packageName` for the build and as `packageNames` for both the integration and production upgrades.

## 5. Workflow architecture

The pipeline ("Paradigm - Source Control", definition ID **55**, living in `sc-paradigm1`) runs seven stages in sequence, each depending on the previous one:

1. **Build** — extracts the TaskID, queues pipeline 53, and waits for it to finish. Fails the whole run if the build doesn't succeed.
2. **Integration pre-approval gate** — Environment `integration-pre-approval`. Pauses until an approver signs off.
3. **Upgrade (integration)** — queues pipeline 54 with `targetEnvironment=integration`, waits for it to finish.
4. **Integration post-approval gate** — Environment `integration-post-approval`. Confirms the integration upgrade before moving on.
5. **Production pre-approval gate** — Environment `production-pre-approval`. Pauses until an approver signs off on going to production.
6. **Upgrade (production)** — queues pipeline 54 with `targetEnvironment=production`, waits for it to finish.
7. **Production post-approval gate** — Environment `production-post-approval`. Final confirmation; workflow ends here.

Each gate is a separate Azure DevOps Environment with a manual Approval check configured in the ADO UI, not in code — so who approves any single gate can change later without touching this file.

## 6. Pipeline file (`azure-pipelines.yml` in `sc-paradigm1`)

```yaml
# Full release workflow: triggered by every push to sc-paradigm1.
#
# 1. Build   - extracts TaskID from the commit message, queues and waits for
#              "Paradigm - Build with Source Control" (pipeline 53).
# 2. Gate    - Integration pre-approval  (Environment: integration-pre-approval)
# 3. Upgrade - queues and waits for "Paradigm - Upgrade Environment" (pipeline 54)
#              targeting the 'integration' environment.
# 4. Gate    - Integration post-approval (Environment: integration-post-approval)
# 5. Gate    - Production pre-approval   (Environment: production-pre-approval)
# 6. Upgrade - queues and waits for pipeline 54 targeting 'production'.
# 7. Gate    - Production post-approval  (Environment: production-post-approval) - finalizes.
#
# Each gate is a separate Azure DevOps Environment with a manual Approval check
# configured in the ADO UI (Pipelines -> Environments). Swapping the approver
# for any single gate never requires touching this file.
#
# Commit message format expected: "<version>; TaskID: <value>"
#   e.g. "v1.0.1; TaskID: V1.0.1"

trigger:
  branches:
    include:
      - main

variables:
  targetOrganization: 'https://dev.azure.com/dbmsc'
  targetProject: 'poc'
  buildPipelineId: '53'     # Paradigm - Build with Source Control
  upgradePipelineId: '54'   # Paradigm - Upgrade Environment

stages:
  # ------------------------------------------------------------------
  - stage: Build
    displayName: 'Build Package from Commit'
    jobs:
      - job: Build
        pool: NicolasHosted
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
                --parameters packageName="$(packageName)" buildType="Specific Tasks" tasksList="$(packageName)" tags="" \
                --query id -o tsv)
              echo "Queued build run: $runId"

              while true; do
                state=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query state -o tsv)
                [ "$state" == "completed" ] && break
                sleep 15
              done

              result=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query result -o tsv)
              echo "Build run result: $result"
              if [ "$result" != "succeeded" ]; then
                echo "##vso[task.logissue type=error]Build failed (result=$result). See run $runId in pipeline $(buildPipelineId)."
                exit 1
              fi
            displayName: 'Queue and wait: Build with Source Control'
            env:
              SYSTEM_ACCESSTOKEN: $(System.AccessToken)

  # ------------------------------------------------------------------
  - stage: IntegrationPreApproval
    displayName: 'Integration - Pre-Approval Gate'
    dependsOn: Build
    condition: succeeded()
    jobs:
      - deployment: IntegrationPreApprovalGate
        displayName: 'Await integration pre-approval'
        environment: 'integration-pre-approval'
        pool: NicolasHosted
        strategy:
          runOnce:
            deploy:
              steps:
                - bash: echo "Integration pre-approval granted - proceeding to upgrade."
                  displayName: 'Gate passed'

  # ------------------------------------------------------------------
  - stage: UpgradeIntegration
    displayName: 'Upgrade - integration'
    dependsOn: IntegrationPreApproval
    condition: succeeded()
    variables:
      packageName: $[ stageDependencies.Build.Build.outputs['extract.packageName'] ]
    jobs:
      - job: UpgradeIntegration
        pool: NicolasHosted
        steps:
          - bash: |
              set -e
              az extension add --name azure-devops --only-show-errors
              echo "$SYSTEM_ACCESSTOKEN" | az devops login --organization "$(targetOrganization)"

              runId=$(az pipelines run \
                --organization "$(targetOrganization)" \
                --project "$(targetProject)" \
                --id "$(upgradePipelineId)" \
                --parameters targetEnvironment="integration" packageNames="$(packageName)" \
                --query id -o tsv)
              echo "Queued upgrade run: $runId"

              while true; do
                state=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query state -o tsv)
                [ "$state" == "completed" ] && break
                sleep 15
              done

              result=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query result -o tsv)
              echo "Upgrade run result: $result"
              if [ "$result" != "succeeded" ]; then
                echo "##vso[task.logissue type=error]Integration upgrade failed (result=$result). See run $runId in pipeline $(upgradePipelineId)."
                exit 1
              fi
            displayName: 'Queue and wait: Upgrade Environment (integration)'
            env:
              SYSTEM_ACCESSTOKEN: $(System.AccessToken)

  # ------------------------------------------------------------------
  - stage: IntegrationPostApproval
    displayName: 'Integration - Post-Approval Gate'
    dependsOn: UpgradeIntegration
    condition: succeeded()
    jobs:
      - deployment: IntegrationPostApprovalGate
        displayName: 'Confirm integration upgrade'
        environment: 'integration-post-approval'
        pool: NicolasHosted
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
        displayName: 'Await production pre-approval'
        environment: 'production-pre-approval'
        pool: NicolasHosted
        strategy:
          runOnce:
            deploy:
              steps:
                - bash: echo "Production pre-approval granted - proceeding to upgrade."
                  displayName: 'Gate passed'

  # ------------------------------------------------------------------
  - stage: UpgradeProduction
    displayName: 'Upgrade - production'
    dependsOn: ProductionPreApproval
    condition: succeeded()
    variables:
      packageName: $[ stageDependencies.Build.Build.outputs['extract.packageName'] ]
    jobs:
      - job: UpgradeProduction
        pool: NicolasHosted
        steps:
          - bash: |
              set -e
              az extension add --name azure-devops --only-show-errors
              echo "$SYSTEM_ACCESSTOKEN" | az devops login --organization "$(targetOrganization)"

              runId=$(az pipelines run \
                --organization "$(targetOrganization)" \
                --project "$(targetProject)" \
                --id "$(upgradePipelineId)" \
                --parameters targetEnvironment="production" packageNames="$(packageName)" \
                --query id -o tsv)
              echo "Queued upgrade run: $runId"

              while true; do
                state=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query state -o tsv)
                [ "$state" == "completed" ] && break
                sleep 15
              done

              result=$(az pipelines runs show --organization "$(targetOrganization)" --project "$(targetProject)" --id "$runId" --query result -o tsv)
              echo "Upgrade run result: $result"
              if [ "$result" != "succeeded" ]; then
                echo "##vso[task.logissue type=error]Production upgrade failed (result=$result). See run $runId in pipeline $(upgradePipelineId)."
                exit 1
              fi
            displayName: 'Queue and wait: Upgrade Environment (production)'
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
        environment: 'production-post-approval'
        pool: NicolasHosted
        strategy:
          runOnce:
            deploy:
              steps:
                - bash: echo "Production upgrade confirmed. Workflow complete."
                  displayName: 'Gate passed'
```

## 7. Create the ADO pipeline definition

*(Already done if you set up the earlier build-trigger version of this pipeline — this step only applies the first time.)*

1. Go to Pipelines → New Pipeline.
2. Choose GitHub, then select the DBMaestroDev / sc-paradigm1 repository (using the existing "GitHub using Azure Pipelines app" connection).
3. Point it at `azure-pipelines.yml`.
4. Save.

This is pipeline "Paradigm - Source Control," definition ID **55**, in the same `dbmsc/poc` project as pipelines 53 and 54.

## 8. Grant permissions to queue pipelines 53 and 54

Pipeline 55 runs as the project's build service identity (`poc Build Service (dbmsc)`), which needs explicit rights on both target pipelines to queue them with custom parameters. Without this, runs fail with `TF215106` access-denied errors.

Repeat for **each** of pipeline 53 (Paradigm - Build with Source Control) and pipeline 54 (Paradigm - Upgrade Environment):

1. Open the pipeline in the ADO UI.
2. Open the "⋮" (more actions) menu → **Security**.
3. Find (or add) the identity `poc Build Service (dbmsc)`.
4. Set **Queue builds** to **Allow**.
5. Set **Edit queue build configuration** to **Allow** (needed because the workflow overrides parameters at queue time).
6. Save.

> Both permissions can instead be granted once at the project level (Project Settings → Pipelines → Settings/Security) to cover all pipelines rather than doing this twice.

## 9. Create the four approval-gate environments

For each of the four gates, create an Azure DevOps Environment and attach a manual Approval check:

1. Go to Pipelines → Environments → New environment.
2. Name it exactly as referenced in the YAML: `integration-pre-approval`, `integration-post-approval`, `production-pre-approval`, or `production-post-approval`.
3. Resource: choose **None** — these environments exist only to host an approval check, not to represent an actual deployment target.
4. Create. Then open the environment → "⋮" → **Approvals and checks** → Add check → **Approvals**.
5. Add the approver(s) for that gate and save.

Suggested approver assignment once fully rolled out:

| Environment | Approver |
|---|---|
| `integration-pre-approval` | approver1@dbmaestro.com |
| `integration-post-approval` | approver1@dbmaestro.com |
| `production-pre-approval` | approver2@dbmaestro.com |
| `production-post-approval` | approver2@dbmaestro.com |

For initial testing, all four environments were instead assigned the same single approver so the whole chain could be validated end to end before splitting responsibilities between two reviewers as shown above.

## 10. Failure notifications (pipeline 53)

Azure DevOps' built-in notification subscriptions email a distribution list whenever pipeline 53 fails — no SMTP or pipeline code involved.

1. Project Settings (`poc` project) → Notifications → New subscription (project/shared subscriptions section; requires Project Administrator rights).
2. Category: **Build**. Template: **"A build completes."**
3. Filter: **Definition name** = `Paradigm - Build with Source Control`.
4. Filter: **Status** = `Failed`.
5. Deliver to → **Custom email address** → `devops@dbmaestro.com`.
6. Save.

Consider adding an equivalent subscription filtered to `Paradigm - Upgrade Environment` (definition 54) with Status = Failed, so integration/production upgrade failures reach the same distribution list.

## 11. Test

1. Push a commit to `sc-paradigm1` with a message such as: `v1.0.2; TaskID: TASK-42`
2. Confirm pipeline 55 starts, the Build stage extracts `TASK-42`, and pipeline 53 runs and succeeds.
3. At the Integration pre-approval gate, approve the pending check in the ADO UI (Pipelines → the run → the pending environment approval).
4. Confirm the Upgrade (integration) stage queues pipeline 54 with `targetEnvironment=integration` and `packageNames=TASK-42`, and that it succeeds.
5. Approve the Integration post-approval gate.
6. Approve the Production pre-approval gate.
7. Confirm the Upgrade (production) stage queues pipeline 54 with `targetEnvironment=production` and `packageNames=TASK-42`, and that it succeeds.
8. Approve the Production post-approval gate and confirm the run completes successfully.

## 12. Friendly run names for pipelines 53 and 54

By default, Azure DevOps run names show a generic build number like `#20260727.2` alongside whatever the latest commit message happens to be on that pipeline's own source repo — not necessarily anything meaningful. Both target pipelines now set a custom build number format so each run in the ADO UI immediately shows what it's building:

- `build-source-control.yml`: `name: '${{ parameters.packageName }}_$(Date:yyyyMMdd)$(Rev:.r)'` → e.g. `TASK-42_20260727.2`
- `upgrade-environment.yml`: `name: '${{ parameters.targetEnvironment }}_${{ parameters.packageNames }}_$(Date:yyyyMMdd)$(Rev:.r)'` → e.g. `integration_TASK-42_20260727.2`

This is purely cosmetic — it doesn't change any pipeline behavior, only how each run is labeled in the Runs list.

## 13. Troubleshooting

| Symptom | Fix |
|---|---|
| `TF215106: ... needs Queue builds permissions for build pipeline 53/54 ...` | Grant Queue builds = Allow to `poc Build Service (dbmsc)` on that pipeline's Security panel (see step 8). |
| `TF215106: ... needs Edit queue build configuration permissions ...` | Grant Edit queue build configuration = Allow to the same identity on the same Security panel. |
| Stage stays "Waiting" indefinitely at a gate | Expected — that's the approval check. Open the run in the ADO UI and approve/reject the pending environment check. If no one is ever prompted, confirm the Approval check is actually attached to that environment (step 9). |
| `bash: line N: packageName: command not found` and `ERROR: The 'packageName' parameter is not a valid String` when queuing pipeline 53 | The extract step only set `packageName` with `isOutput=true`. That flag alone doesn't reliably resolve via `$(packageName)` macro syntax in a later step of the *same* job — ADO leaves the literal text unexpanded and bash then tries to run it as a command substitution. Fix: also set the variable as a plain (non-output) variable in the same step, in addition to the isOutput=true one (see the `extract` step in section 6 — both lines are required). |
| Upgrade stage fails immediately with an empty `packageNames` | The `stageDependencies` expression couldn't resolve `extract.packageName` — confirm the Build stage's extraction step is literally named `extract` (the `name:` field) and that it actually set the variable with `isOutput=true`. |
| Relay/Build step fails with "Could not find 'TaskID: <value>' ..." | The commit message didn't match the required `<version>; TaskID: <value>` format — amend the commit message and re-push. |
