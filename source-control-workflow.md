# Source-Control Workflow

*Deep dive on `source-control-workflow.yml` — the TaskID-driven Build → Integration → Production release chain. Split out from `README.md` so the workflow's architecture, stages, and troubleshooting live in one place; see `README.md` for prerequisites and one-time ADO setup (service connections, permissions, environments, notifications) shared across both this workflow and the ad-hoc workflow.*

## 1. What triggers it, and what doesn't

`source-control-workflow.yml` fires on every push to `example-ado-source-control`'s `main` branch, **except** pushes that only touch the `ad-hoc/` folder — those are excluded here and handled instead by [`ad-hoc-workflow.yml`](./ad-hoc-workflow.md):

```yaml
trigger:
  branches:
    include:
      - main
  paths:
    exclude:
      - ad-hoc/*
```

Without that exclusion, an ad-hoc-only commit would also trigger this workflow and fail immediately at TaskID extraction (step 3 below) — ad-hoc commits don't follow the TaskID convention this workflow depends on. The two workflows are mutually exclusive by design; a single push never triggers both.

## 2. Architecture: a thin trigger file, and a shared template

Azure DevOps requires a self-triggered pipeline's YAML to live in the same repo whose pushes trigger it — there's no way around that. But the actual release logic doesn't need to live there too, and with more than one source-control repo potentially sharing this same chain, it shouldn't: copy-pasting the full 7-stage pipeline into every source-control repo would mean re-fixing the same bug in N places every time.

So the logic is split across two files:

- **`example-ado-source-control/source-control-workflow.yml`** — the thin trigger file. Just `trigger`, a `resources.repositories` entry pointing back at this `example-ado-pipelines` repo, and an `extends:` block passing a handful of parameters. [View it](./example-ado-source-control/source-control-workflow.yml).
- **`example-ado-pipelines/azure-devops/templates/source-control-workflow.yml`** — the real pipeline: all 7 stages, extracted once. [View it](./azure-devops/templates/source-control-workflow.yml).

If a second source-control repo ever needs this same chain, it gets an equally thin copy of the wrapper file (same shape, its own parameter values) — not a copy of the whole chain. Any future fix to the chain itself happens once, in the template.

```yaml
# example-ado-source-control/source-control-workflow.yml (abridged)
resources:
  repositories:
    - repository: adoPipelines
      type: github
      name: DBMaestroDev/example-ado-pipelines
      endpoint: 'DBMaestroDev'
      ref: refs/heads/main

extends:
  template: azure-devops/templates/source-control-workflow.yml@adoPipelines
  parameters:
    targetOrganization: 'https://dev.azure.com/dbmsc'
    targetProject: 'Example'
    buildPipelineId: '59'    # this repo's "Build and Precheck Package - Source Control" pipeline
    upgradePipelineId: '60'  # shared "Upgrade Environment" pipeline
    runnerPool: 'dbmaestro-windows'
```

**Setup note:** the `adoPipelines` resource above reuses the same `DBMaestroDev` GitHub service connection already authorized for `example-ado-source-control` (see `README.md` section 3). If that connection is scoped per-repository rather than org-wide, it also needs to be granted access to `example-ado-pipelines`, or a second connection registered and the `endpoint:` value updated to match.

## 3. Commit message convention

Commits on `example-ado-source-control` (outside `ad-hoc/`) must follow this format:

```
<version>; TaskID: <value>

Example:  v1.0.1; TaskID: V1.0.1
```

This format is generated automatically by the **DBmaestro Source Control** application — it isn't something you type by hand. The only thing required on your end is to specify the **TaskID** value in the tool at commit time; DBmaestro Source Control then builds the full commit message (version plus `TaskID:` segment) for you. If a commit is ever made outside that tool, or the TaskID field is left blank, the message won't match this format and the Build stage's extraction step fails with `Could not find 'TaskID: <value>' ...` (see Troubleshooting below).

The value after `TaskID:` is extracted once, in the Build stage, and reused as `packageName` for the build and as `packageNames` for both the integration and production upgrades.

## 4. Stage-by-stage walkthrough

The template runs seven stages in sequence, each depending on the previous one:

1. **Build** — checks out `self` (`fetchDepth: 1`), extracts the TaskID from the triggering commit message, and queues the per-repo "Build and Precheck Package - Source Control" pipeline (fire-and-forget — see "Fire-and-forget design" in `README.md`).
2. **Integration pre-approval gate** — Environment `Integration-pre-approval`. Pauses until an approver signs off.
3. **Upgrade (Integration)** — queues the shared "Upgrade Environment" pipeline with `targetEnvironment=Integration` and `packageNames=<TaskID>` (fire-and-forget).
4. **Integration post-approval gate** — Environment `Integration-post-approval`. Confirms the integration upgrade before moving on.
5. **Production pre-approval gate** — Environment `Production-pre-approval`. Pauses until an approver signs off on going to production.
6. **Upgrade (Production)** — queues "Upgrade Environment" again with `targetEnvironment=Production` (fire-and-forget).
7. **Production post-approval gate** — Environment `Production-post-approval`. Final confirmation; workflow ends here.

Each gate is a separate Azure DevOps Environment with a manual Approval check configured in the ADO UI, not in code — so who approves any single gate can change later without touching the template.

### Passing the TaskID across stages

The `UpgradeIntegration` and `UpgradeProduction` stages each need the TaskID extracted back in `Build`, two stages earlier. That's done with a job-level runtime expression:

```yaml
variables:
  packageName: $[ stageDependencies.Build.Build.outputs['extract.packageName'] ]
```

Two things have to line up for this to resolve:

- The extraction step in `Build` must literally be named `extract` (the step's `name:` field) and set the variable with `isOutput=true`.
- The consuming stage must explicitly list `Build` in its own `dependsOn` — not just its approval-gate stage. Azure DevOps' `stageDependencies` output-variable expressions only resolve for stages that are *explicitly* listed in `dependsOn`, even when `Build` is already an indirect ancestor through the gate stage. Execution order is unaffected either way, since `Build` already has to finish before the gate stage runs — this is purely about making the output visible to the expression.

This exact `stageDependencies.<Stage>.<Job>.outputs['<Step>.<Var>']` syntax is only valid inside a **job's `variables:` block** (a runtime `$[ ]` expression). It is *not* the right syntax for a **stage's own `condition:`** field — see the ad-hoc workflow doc's Troubleshooting section for the syntax that context actually needs, and why the two look similar enough to mix up.

## 5. Pipeline files

- Thin wrapper (lives in, and triggers from, `example-ado-source-control`): [`example-ado-source-control/source-control-workflow.yml`](./example-ado-source-control/source-control-workflow.yml)
- Shared template (lives in `example-ado-pipelines`, holds all the real logic): [`azure-devops/templates/source-control-workflow.yml`](./azure-devops/templates/source-control-workflow.yml)

The live wrapper that Azure DevOps actually runs lives in the `example-ado-source-control` GitHub repo — the copy under `example-ado-pipelines/example-ado-source-control/` is a reference copy kept in sync so both can be reviewed from this repo; keep the two identical when either changes.

## 6. Test

1. Using the DBmaestro Source Control application, commit to `example-ado-source-control` with a message such as: `v1.0.2; TaskID: TASK-42`.
2. Confirm the orchestrator starts, the Build stage extracts `TASK-42`, and the build pipeline (59 in this deployment) is queued.
3. Check that build pipeline's run and confirm it succeeded before proceeding.
4. At the Integration pre-approval gate, approve the pending check in the ADO UI (Pipelines → the run → the pending environment approval).
5. Confirm the Upgrade (Integration) stage queues the upgrade pipeline (60) with `targetEnvironment=Integration` and `packageNames=TASK-42`; check that run succeeded.
6. Approve the Integration post-approval gate.
7. Approve the Production pre-approval gate.
8. Confirm the Upgrade (Production) stage queues the upgrade pipeline with `targetEnvironment=Production` and `packageNames=TASK-42`; check that run succeeded.
9. Approve the Production post-approval gate and confirm the run completes successfully.

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| Build/Upgrade step fails with `Could not find 'TaskID: <value>' ...` | The commit message didn't match the required `<version>; TaskID: <value>` format — amend the commit message and re-push. Commits made outside the DBmaestro Source Control application are the usual cause (section 3). |
| `ERROR: The 'packageNames' parameter is not a valid String` (or `packageName`) when queuing the build/upgrade pipeline | Most likely `stageDependencies.Build.Build.outputs['extract.packageName']` didn't resolve. Confirm: (1) the Build stage's extraction step is literally named `extract`; (2) the consuming stage (`UpgradeIntegration`/`UpgradeProduction`) explicitly lists `Build` in its `dependsOn`, not just its approval-gate stage — see section 4. |
| A commit touching `ad-hoc/` triggered both `ad-hoc-workflow.yml` **and** this workflow, and this one failed at TaskID extraction | This workflow's `paths: exclude: [ad-hoc/*]` (section 1) is missing, misconfigured, or the commit touched files both inside and outside `ad-hoc/` in the same push (path filters trigger on the whole push, not per-file). |
| `extends` template not found, or parameters rejected as unexpected | The `adoPipelines` resource in the thin wrapper doesn't resolve, or a parameter name/spelling in the wrapper's `extends: parameters:` block doesn't match what `azure-devops/templates/source-control-workflow.yml` actually declares — compare the two side by side (section 2). |
| Pipeline fails immediately with a GitHub authorization error referencing the `adoPipelines` repository | The service connection named in the wrapper's `adoPipelines` resource isn't scoped to reach `example-ado-pipelines` — see the setup note in section 2. |

For setup issues not specific to this workflow (missing service connections, PowerShell/Java/Azure CLI on the agent, environment permissions, notification subscriptions), see the Troubleshooting section in `README.md`.
