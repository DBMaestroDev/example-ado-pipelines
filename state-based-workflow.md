# State-Based Workflow

*Deep dive on `state-based-workflow.yml` — the push-triggered, approval-gated release chain that builds a fresh package for each environment. See `README.md` for prerequisites and one-time ADO setup shared with [`ad-hoc-workflow.yml`](./ad-hoc-workflow.md).*

## 1. What "state-based" means here

This workflow builds via DBmaestro's *state-based* `CustomBuild` mode: each package is produced by diffing the triggering commit against the **current live state** of the specific environment it's headed to — not by reusing one package across every environment. Because Release Source, UAT_Env_1, Pre_Prod_Env_1, and Prod_Env_1 can each be at a different live state, this means **N independent build-then-upgrade cycles, one per environment**, each producing its own package named `<7-char short commit hash>-<TargetEnvName>` (e.g. `50f5aac-Release-Source`) — every package from one run shares the same commit hash, but they are not the same package.

**Trigger: every push to `main` in `example-ado-source-control`**, except a push that only touches a root-level pipeline YAML file (`/*.yml` is excluded from the trigger's `paths:`, so changes to the pipeline definitions themselves don't kick off a release run).

## 2. Architecture: a thin trigger file, and a shared template

Azure DevOps only self-triggers off YAML committed in the triggering repo, so a thin wrapper has to live in `example-ado-source-control`, while the actual multi-stage chain lives once in this `example-ado-pipelines` repo:

- **`example-ado-source-control/state-based-workflow.yml`** — the thin wrapper. [View it](./example-ado-source-control/state-based-workflow.yml).
- **`example-ado-pipelines/azure-devops/templates/state-based-workflow.template.yml`** — the real pipeline. [View it](./azure-devops/templates/state-based-workflow.template.yml).

```yaml
# example-ado-source-control/state-based-workflow.yml (abridged)
trigger:
  branches:
    include:
      - main
  paths:
    exclude:
      - /*.yml   # root-level pipeline definitions - changes to the pipeline
                 # code itself shouldn't trigger a release run

resources:
  repositories:
    - repository: adoPipelines
      type: github
      name: DBMaestroDev/example-ado-pipelines
      endpoint: 'DBMaestroDev'
      ref: refs/heads/main

extends:
  template: azure-devops/templates/state-based-workflow.template.yml@adoPipelines
  parameters:
    dBmaestroProjectName: 'Example-ADO'
    runnerPool: 'dbmaestro-windows'
```

**Setup note:** `DBMaestroDev` above is just this guide's own example deployment — in your setup, both `example-ado-pipelines` and `example-ado-source-control` live in **your own** GitHub org. The `adoPipelines` resource can reuse the same GitHub service connection already required for `example-ado-source-control`, provided that connection is scoped to `example-ado-pipelines` too.

Every additional DBmaestro project's own source-control repo needs an equally thin copy of this wrapper (same shape, its own `dBmaestroProjectName`/`runnerPool` values) — not a copy of the whole template.

## 3. Stage-by-stage walkthrough

The chain is a single sequential run: `Init` resolves the commit hash once, then each environment gets its own pre-approval → build → upgrade trio, chained one after another, with Prod_Env_1 getting an extra review gate before its final upgrade:

1. **Init — Resolve Commit Hash.** Checks out `self` with `fetchDepth: 0` and runs `git rev-parse --short=7 HEAD`, publishing the result as an output variable (`resolve.commitHash`) that every later Build stage reads via `stageDependencies.Init.Init.outputs[...]`.
2. **Release Source leg:**
   - **Release Source - Pre-Approval Gate** — Environment `Release-Source-pre-approval`.
   - **Release Source - Build Package** — runs `java -jar DBmaestroAgent.jar -CustomBuild -SourceProjectName "<dBmaestroProjectName>" -SourceEnvName "Dev_Env_1" -TargetProjectName "<dBmaestroProjectName>" -TargetEnvName "Release Source" -SourceVersionType "Specific Commit" -TargetVersionType "Live Version" -CreatePackage True -PackageName "<hash>-Release-Source" -AdditionalInformation "<hash>" ...` inline, publishing the package name as an output variable.
   - **Upgrade - Release Source** — runs `java -jar DBmaestroAgent.jar -RunPackageAsAdHoc -ProjectName "<dBmaestroProjectName>" -EnvName "Release Source" -PackageName "<hash>-Release-Source" -ScriptType "Upgrade" -RunPackage True ...` inline.
3. **UAT_Env_1 leg** — same three-stage shape: pre-approval gate (`UAT_Env_1-pre-approval`) → build (`-TargetEnvName "UAT_Env_1"`) → upgrade.
4. **Pre_Prod_Env_1 leg** — same shape again: pre-approval gate (`Pre_Prod_Env_1-pre-approval`) → build (`-TargetEnvName "Pre_Prod_Env_1"`) → upgrade.
5. **Prod_Env_1 leg — four stages, not three:**
   - **Prod_Env_1 - Pre-Approval Gate** — Environment `Prod_Env_1-pre-approval`.
   - **Prod_Env_1 - Build Package** — same `CustomBuild` shape as the other legs (`-TargetEnvName "Prod_Env_1"`).
   - **Prod_Env_1 - Review Package Gate** — Environment `Prod_Env_1-review-package`. A second, separate manual gate specific to Prod_Env_1: after the package is built, someone reviews it before the final upgrade is allowed to run.
   - **Upgrade - Prod_Env_1 (Finalize)** — same `-RunPackageAsAdHoc`/`Upgrade` shape as the other legs, gated on both the review-package approval and the earlier build stage.

Unlike the ad-hoc workflow's four independent legs, this chain is **strictly sequential** — each stage's `dependsOn` points at the stage immediately before it (with `Init` also listed as a dependency of every Build stage, purely so its `stageDependencies.Init...` output variable resolves; it doesn't change execution order, since `Init` already runs first). There is no `dependsOn: []` anywhere in this template — that pattern is specific to `ad-hoc-workflow.yml`'s four parallel legs (see `ad-hoc-workflow.md` section 3).

Every `Build*` job's `-SourceEnvName` is hardcoded to `"Dev_Env_1"` — every environment's package is built by diffing the triggering commit against `Dev_Env_1`'s live state, not against the environment being targeted. If your DBmaestro project doesn't have an environment named `Dev_Env_1`, every Build stage fails; either create one or edit the `-SourceEnvName` value directly in the template (this affects every project's source-control repo that extends it).

Because everything — build, gate, upgrade — runs inline as part of the one pipeline run, a failed build or upgrade step fails its own stage immediately (non-zero exit code), and every stage depending on it is skipped automatically. There's no separate queued pipeline whose pass/fail an approver needs to check by hand before approving the next gate (see `README.md` section 3a).

## 4. Test

1. Push a commit to `main` in `example-ado-source-control` (not touching only a root-level `.yml` file) and confirm a new `state-based-workflow.yml` run starts.
2. Confirm the `Init` stage resolves a 7-character commit hash matching the pushed commit.
3. Approve the **Release Source pre-approval** gate and confirm the Release Source build produces a package named `<hash>-Release-Source`, then confirm the upgrade step succeeds.
4. Confirm the run then waits on **UAT_Env_1 pre-approval** — not before, since this workflow is strictly sequential.
5. Repeat approvals through UAT_Env_1 and Pre_Prod_Env_1.
6. At Prod_Env_1, confirm the run pauses twice: first at **Prod_Env_1 pre-approval** (before the build), then again at **Prod_Env_1 review-package** (after the build, before the upgrade) — approving the first should not skip the second.
7. Confirm the final **Upgrade - Prod_Env_1 (Finalize)** stage succeeds and the run completes.

## 5. Troubleshooting

For general setup issues (missing service connections, PowerShell/Java on the agent, environment permissions, notification subscriptions), see the Troubleshooting section in `README.md`.

| Symptom | Fix |
|---|---|
| Every Build stage fails immediately | Confirm the DBmaestro project actually has a `Dev_Env_1` environment — every `Build*` job's `-SourceEnvName` is hardcoded to `"Dev_Env_1"` (section 3), it's not a parameter. |
| `stageDependencies.Init.Init.outputs['resolve.commitHash']` resolves empty, or a Build stage can't find the commit hash | Confirm the `Init` stage is listed in the failing Build stage's `dependsOn` (it must be, alongside the preceding pre-approval stage) — the `Init` job/step names (`Init`/`resolve`) must match exactly what the `stageDependencies` expression references. |
| A later leg's Upgrade step runs against an unexpectedly old/wrong package | Each `Upgrade*` stage reads its package name from its own leg's Build stage output (`stageDependencies.Build<Env>.Build<Env>.outputs['build.packageName']`) — confirm the Build stage it depends on actually ran (and succeeded) in the same run, not a prior one. |
| The Prod_Env_1 upgrade runs without a package review ever happening | Confirm `UpgradeProdEnv1`'s `dependsOn` in `azure-devops/templates/state-based-workflow.template.yml` still lists `ProdEnv1ReviewPackageApproval` — if that stage were ever removed from the dependency list, the upgrade would only wait on the build. |
| Legs appear to run out of order, or a later environment's gate opens before an earlier one's upgrade finished | This workflow is intentionally strictly sequential (no `dependsOn: []` anywhere) — if you see a gate open early, check that stage's `dependsOn` in the template rather than assuming a parallel-legs design like `ad-hoc-workflow.yml`'s. |
| `java : The term 'java' is not recognized...` | Java isn't installed on the agent, or isn't on the PATH the agent service sees — every inline `CustomBuild`/`Upgrade` step needs `java` to run `DBmaestroAgent.jar`. See `README.md` section 2. |
| `extends` template not found, or a parameter is rejected as unexpected | The `adoPipelines` resource doesn't resolve, or a parameter name/spelling in the wrapper's `extends: parameters:` block doesn't match what `azure-devops/templates/state-based-workflow.template.yml` declares — compare the two side by side (section 2). |
