# Ad-Hoc Workflow

*Deep dive on `ad-hoc-workflow.yml` — the DBmaestro-DOP-hook-triggered, approval-gated upgrade chain for packages of the Ad-hoc type. Split out from `README.md` so this workflow's architecture, stages, and troubleshooting live in one place; see `README.md` for prerequisites and one-time ADO setup shared with [`source-control-workflow.yml`](./source-control-workflow.md).*

## 1. What this is for, and how it differs from the main workflow

Ad-hoc packages don't go through the TaskID/commit-message flow that `source-control-workflow.yml` builds around, and — unlike that workflow — this one doesn't build anything either: by the time it runs, the package already exists. `ad-hoc-workflow.yml` takes that already-built package's name as its one required input and upgrades every environment with it, behind the same approval gates used elsewhere in this repo.

**Trigger: a DBmaestro DOP hook, not a git push.** This pipeline is `trigger: none` in Azure DevOps — nothing about pushing to `example-ado-source-control` starts it. It's queued externally instead, by a DBmaestro DOP hook script (see `hooks/paradigm-hook_adhoc_test.ps1`, invoked via `hooks/paradigm-hook.bat`):

1. DOP runs a **precheck task** against a package as part of its own build/promotion flow.
2. On completion, DOP invokes the hook script, passing it a JSON document describing that package (project name, package name/version, policies, event, step, and — critically — the package's `TypeId`).
3. The hook script reads `TypeId` off the package. **Only when `TypeId` identifies the package as Ad-hoc** does it queue this pipeline, via `az pipelines run ... --parameters "packageName=<package name>"` — passing the package name straight through as this workflow's `packageName` runtime parameter. Any other package type is left alone; the script logs `Package type is not adhoc. Won't trigger ADO pipeline` and this pipeline is never queued for it.

   **`--parameters`, not `--variables`:** `packageName` is declared as a run-time `parameters:` entry on the wrapper (section 2), not a pipeline variable — `az pipelines run` treats the two as distinct concepts with distinct flags, and passing it via `--variables` (e.g. as some earlier, unrelated build variable like `BuildPipeline.packagename`) fails to queue the run at all, with an error like `Could not queue the build because there were validation errors or warnings.`

Because the trigger is conditional on package type and happens outside ADO entirely, there's no YAML `trigger:`/`paths:` filter to look at for "when does this run" the way there is for `source-control-workflow.yml` — the answer lives in the hook script's `TypeId` check.

The other differences from `source-control-workflow.yml` all follow from there being no TaskID and no build step here:

- **No commit message convention, no build stage.** The package this workflow upgrades already exists by the time DOP's hook queues this pipeline — there is nothing for this workflow to build or detect.
- **Package name comes from the hook's DOP payload, not a parameter you type by hand.** The `packageName` value the hook script extracts and forwards *is* this pipeline's `packageName` parameter — anywhere `source-control-workflow.yml` uses an extracted TaskID as `packageName`, this workflow uses what the hook passed via `--parameters packageName=...`.
- **Approval gates are reused, not duplicated.** The same eight environments (`Release-Source-pre-approval`, `UAT_Env_1-pre-approval`, etc. — one pre/post pair per environment across Release Source, UAT_Env_1, Pre_Prod_Env_1, and Prod_Env_1) back both workflows' gates — same approvers, same "is it OK to touch this environment" decision either way. Split them into separate environments later if ad-hoc and TaskID-based releases ever need independently tracked approvals; nothing about the current design blocks that.
- **Upgrades run inline, not via a queued downstream pipeline.** Each `Upgrade*` stage calls `DBmaestroAgent.jar -Upgrade` directly on the runner and waits for it to finish, so its own exit code gates the stage — see `state-based-workflow.yml` for the same inline-command pattern used there.

## 2. Architecture: a thin trigger file, and a shared template

Same reasoning as `source-control-workflow.yml` (see that doc's section 2): even though this pipeline is queued externally rather than self-triggered by a push, Azure DevOps still requires a pipeline's own YAML definition to be registered from a file living in one of its repos — so a thin file exists per source-control repo, while the actual chain lives once in this `example-ado-pipelines` repo:

- **`example-ado-source-control/ad-hoc-workflow.yml`** — the thin wrapper. [View it](./example-ado-source-control/ad-hoc-workflow.yml).
- **`example-ado-pipelines/azure-devops/templates/ad-hoc-workflow.yml`** — the real pipeline. [View it](./azure-devops/templates/ad-hoc-workflow.yml).

```yaml
# example-ado-source-control/ad-hoc-workflow.yml (abridged)
trigger: none

parameters:
  - name: packageName
    displayName: 'Name of the already-built package to upgrade across all environments'
    type: string

resources:
  repositories:
    - repository: adoPipelines
      type: github
      name: DBMaestroDev/example-ado-pipelines
      endpoint: 'DBMaestroDev'
      ref: refs/heads/main

extends:
  template: azure-devops/templates/ad-hoc-workflow.yml@adoPipelines
  parameters:
    packageName: ${{ parameters.packageName }}
    dBmaestroProjectName: 'Example-ADO'
    runnerPool: 'dbmaestro-windows'
```

The root-level `parameters:` block is what makes `packageName` a run-time input: it shows up as an editable field in ADO's "Run pipeline" dialog, and — same value — is exactly what the DOP hook script supplies via `az pipelines run --parameters "packageName=<value>"` when it queues this pipeline for you. `${{ parameters.packageName }}` in the `extends:` block forwards whatever value the run was queued with straight down into the template's own `packageName` parameter.

**Setup note:** as with `source-control-workflow.yml`, `DBMaestroDev` above is just this guide's own example deployment — in your setup, both `example-ado-pipelines` and `example-ado-source-control` live in **your own** GitHub org. The `adoPipelines` resource can reuse the same GitHub service connection already required for `example-ado-source-control`, provided that connection is scoped to `example-ado-pipelines` too.

## 3. Stage-by-stage walkthrough

The chain splits into **four fully independent legs** — one per environment (Release Source, UAT_Env_1, Pre_Prod_Env_1, Prod_Env_1) — all open from the start of the run, rather than any of them waiting on another. Each leg is its own pre-approval → Upgrade → post-approval trio:

- **Release Source leg:**
  1. **Release Source pre-approval gate** — Environment `Release-Source-pre-approval`.
  2. **Upgrade (Release Source)** — runs `java -jar DBmaestroAgent.jar -Upgrade -ProjectName "<dBmaestroProjectName>" -EnvName "Release Source" -PackageName "<packageName>" ...` inline on the runner.
  3. **Release Source post-approval gate** — Environment `Release-Source-post-approval`.
- **UAT_Env_1 leg:**
  1. **UAT_Env_1 pre-approval gate** — Environment `UAT_Env_1-pre-approval`.
  2. **Upgrade (UAT_Env_1)** — inline `-Upgrade -EnvName "UAT_Env_1"` call.
  3. **UAT_Env_1 post-approval gate** — Environment `UAT_Env_1-post-approval`.
- **Pre_Prod_Env_1 leg:**
  1. **Pre_Prod_Env_1 pre-approval gate** — Environment `Pre_Prod_Env_1-pre-approval`.
  2. **Upgrade (Pre_Prod_Env_1)** — inline `-Upgrade -EnvName "Pre_Prod_Env_1"` call.
  3. **Pre_Prod_Env_1 post-approval gate** — Environment `Pre_Prod_Env_1-post-approval`.
- **Prod_Env_1 leg:**
  1. **Prod_Env_1 pre-approval gate** — Environment `Prod_Env_1-pre-approval`.
  2. **Upgrade (Prod_Env_1)** — inline `-Upgrade -EnvName "Prod_Env_1"` call.
  3. **Prod_Env_1 post-approval gate** — Environment `Prod_Env_1-post-approval`.

All four legs' pre-approval gates are pending as soon as the run starts — there's nothing upstream of any of them to wait on, and no `dependsOn` between any two legs. Approving only one environment's gate runs only that environment's trio; approving several runs each of them concurrently, in any combination or order. Nothing enforces promoting through environments in a particular sequence — that ordering, if you want one, is a human process decision (approve Release Source, confirm it, *then* approve UAT_Env_1, and so on), not something the pipeline itself gates.

> **Implementation note — this requires an explicit `dependsOn: []` on each leg's pre-approval stage, not just omitting `dependsOn`.** Azure DevOps stages with no `dependsOn` at all default to depending on the *immediately preceding stage in the YAML file* — not "no dependency." Omitting it here would silently chain every leg behind whichever one is listed first, making the whole pipeline run strictly sequentially in the ADO UI (this was hit and fixed via a live run — the stage graph showed every stage left-to-right in file order instead of four parallel legs). Only `ReleaseSourcePreApproval`, being the first stage in the file, doesn't need this — it has no preceding stage to implicitly inherit.

Every `Upgrade*` job runs the same inline-command shape:

```powershell
java -jar "<agentJarPath>" -Upgrade `
  -ProjectName "<dBmaestroProjectName>" `
  -EnvName "<Environment Name>" `
  -PackageName "<packageName>" `
  -Server "$(DBMAESTRO_SERVER)" `
  -AccessTokenFilePath "$(DBMAESTRO_ACCESS_TOKEN_FILE_PATH)"
```

with `-EnvName` set to `"Release Source"`, `"UAT_Env_1"`, `"Pre_Prod_Env_1"`, or `"Prod_Env_1"` for the respective stage. It runs on the runner directly and waits for it to finish, so a non-zero exit code fails that stage (and its own leg's post-approval gate) immediately — no separate pipeline is queued, and there's nothing to poll for.

Each leg's own approval gates follow the exact same manual-approval-check setup as `source-control-workflow.yml` — see that doc and `README.md` for the general Environment/Approval-check setup; it isn't repeated here.

### 3a. Closing out a run that only deploys some environments

Because all four legs are independent, a run where you only ever wanted, say, the Release Source leg will still have the other three environments' pre-approval gates sitting there, pending, indefinitely. This isn't a bug to fix in the YAML — it's inherent to how Azure DevOps evaluates multi-stage pipelines: a stage only becomes eligible to run once *every* stage it depends on has reached a terminal state (Succeeded, Failed, Skipped, or Rejected), and "awaiting manual approval" isn't terminal. There is no `condition:`/`dependsOn:` construct that lets the overall run finish while a sibling gate is neither approved, rejected, nor timed out — so every unused leg's gate has to be resolved one way or another before the run itself can close.

Three ways to resolve it, none of which require a YAML change:

1. **Reject the gate.** Whoever is deciding just rejects the unused environment's pre-approval check in the ADO UI, right after approving the one they actually want. Immediate, no setup required.
2. **Configure a timeout on that Environment's approval check.** Environments → the environment in question → "⋮" → Approvals and checks → edit the Approval check's timeout (e.g. 1 hour instead of the default). An un-acted-on gate then auto-rejects on its own instead of waiting indefinitely — useful if leaving a leg permanently unresolved becomes a recurring pattern rather than a one-off.
3. **Cancel the whole run.** A blunter option if neither of the above fits — stops everything, including the leg that already succeeded, rather than resolving just the unused gate.

**Caveat that applies to options 1 and 2 either way:** a rejected or timed-out approval counts as a *stage failure* in Azure DevOps' multi-stage YAML pipelines — there's no "partially succeeded" run outcome here. So a run where the Release Source leg deployed successfully and one or more of the other three legs' gates were deliberately rejected will still show up in the Runs list, and in failure-notification emails (`README.md` section 9), as **Failed** overall. Anyone reviewing run status or failure notifications for this pipeline needs to check *which* stage(s) actually failed before assuming something broke — a rejected/unused leg looks identical, at the run-result level, to a genuine failure.

No decision has been made yet on which of these three to standardize on; for now, resolve it however fits the situation.

## 4. The DBmaestro DOP hook: how `TypeId` decides whether this pipeline runs

`hooks/paradigm-hook_adhoc_test.ps1` (invoked by `hooks/paradigm-hook.bat`) is what DOP actually calls after a precheck task completes. It:

1. Reads the JSON document DOP passes it (the path is `%~1`/`$args[0]`), pulling out the project name (`FlowDetails.name`), package name (`Versions[].Package.versionString`), and — the field this whole decision hinges on — `Versions[].Package.TypeId`.
2. Sets a flag when it finds `TypeId -eq 2` — DOP's Ad-hoc package type. If that flag isn't set, it logs `Package type is not adhoc. Won't trigger ADO pipeline` and stops there — it never even logs into Azure DevOps for a non-Ad-hoc package.
3. **Only if the Ad-hoc flag was set** does it log into Azure DevOps (`az devops login`, using the `$PAT`/`$ADOOrganization` configuration values at the top of the script) and then queue this pipeline:
   ```powershell
   az pipelines run --name $adhocPipelineName --branch "main" `
     --org "https://dev.azure.com/$ADOOrganization" --project $ADOProject `
     --parameters "packageName=$DOP_PackageName"
   ```
   Any package whose `TypeId` isn't 2 is left alone — the hook script does nothing further for it (a separate, non-ad-hoc pipeline may still pick it up elsewhere, per your DOP configuration; that's outside this workflow's scope).

**`--parameters`, not `--variables`:** this workflow's `packageName` is a run-time template parameter (section 2's `extends:` block), not a pipeline variable — the two aren't interchangeable in `az pipelines run`. Passing it as a variable instead (e.g. under some other name like `BuildPipeline.packagename`) queues the run against a parameter the pipeline was never told to expect, and `az` rejects it with `ERROR: Could not queue the build because there were validation errors or warnings.` before the run even starts. There is deliberately no detection or validation of the package inside `ad-hoc-workflow.yml` itself beyond that: by the time this pipeline is queued, DOP and the hook script have already decided both *that* an upgrade should happen and *which* package it's for.

## 5. Test

1. Trigger (or simulate) a DOP precheck completion for a package whose `TypeId` is 2 (Ad-hoc), so the hook script fires.
2. Confirm the hook script's log (`hooks/logs/paradigm-hook_adhoc_test.log` by default — see section 4) shows `Is adhoc Package` and a successful `az pipelines run` call.
3. Confirm `ad-hoc-workflow.yml` starts in ADO with the expected `packageName` (visible on the run's parameters).
4. Confirm **all four** pre-approval gates (Release Source, UAT_Env_1, Pre_Prod_Env_1, Prod_Env_1) are pending at the same time as soon as the run starts — this is the "four legs open in parallel" behavior, and the thing the `dependsOn: []` fix (section 3) exists to guarantee. If instead they appear one at a time, left-to-right, as each prior stage finishes, that's the missing-`dependsOn: []` regression — check every leg's pre-approval stage in the template.
5. Approve only the Release Source pre-approval gate first, and confirm the other three legs stay pending/untouched (their Upgrade and post-approval stages haven't started) while the Release Source leg proceeds.
6. Confirm the Upgrade (Release Source) stage's inline `java -jar ... -Upgrade` call succeeds, then approve Release Source post-approval.
7. Approve each of the remaining three legs' pre-approval gates (together or one at a time, in any order) and confirm each one's Upgrade → post-approval pattern runs independently of the others.
8. Separately, confirm a package with `TypeId` other than 2 does **not** cause the hook script to queue this pipeline at all.

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| This pipeline never queues even though a precheck task ran | Check the hook script's own log first (`hooks/logs/`) — confirm DOP actually invoked it and that the package's `TypeId` was 2. A non-Ad-hoc package is expected to be skipped; anything else, check `$PAT`/`$ADOOrganization` and the `az devops login` step at the top of the hook script. |
| Hook script logs a successful `az pipelines run`, but nothing shows up in ADO | Confirm `$adhocPipelineName`, `--org`, and `--project` in the hook script match this pipeline's actual name/org/project in ADO exactly — a mismatch fails the `az pipelines run` call itself, which the script does check for (`$LASTEXITCODE`), but double-check the logged output for the specific error. |
| `ERROR: Could not queue the build because there were validation errors or warnings.` | The hook script passed `packageName` via `--variables` instead of `--parameters` (or under the wrong name) — `packageName` is a run-time template parameter, not a pipeline variable; see section 4's `--parameters`/`--variables` note. Confirm the hook script's `az pipelines run` call uses `--parameters "packageName=$DOP_PackageName"` exactly. |
| The pipeline runs but upgrades the wrong package (or an empty one) | Check the `packageName=$DOP_PackageName` value in the hook script's `az pipelines run --parameters` call against `Versions[].Package.versionString` in the DOP JSON payload it read — and confirm the wrapper's `extends: parameters: packageName: ${{ parameters.packageName }}` line (section 2) wasn't changed to something else. |
| `extends` template not found, or parameters rejected as unexpected | The `adoPipelines` resource doesn't resolve, or a parameter name/spelling in the wrapper's `extends: parameters:` block doesn't match what `azure-devops/templates/ad-hoc-workflow.yml` declares — compare the two side by side (section 2). |
| `java : The term 'java' is not recognized...` | Java isn't installed on the agent, or isn't on the PATH the agent service sees — every inline `-Upgrade` step needs `java` to run `DBmaestroAgent.jar`. See `README.md` section 2. |
| The four legs run strictly left-to-right in the ADO stage graph instead of opening in parallel | A `dependsOn: []` is missing from one of `UatEnv1PreApproval`, `PreProdEnv1PreApproval`, or `ProdEnv1PreApproval` in `azure-devops/templates/ad-hoc-workflow.yml`. Azure DevOps stages default to depending on the *previous stage in the YAML file* when `dependsOn` is omitted entirely — it does not default to "no dependency" — see the implementation note in section 3. |

For setup issues not specific to this workflow (missing service connections, PowerShell/Java/Azure CLI on the agent, environment permissions, notification subscriptions), see the Troubleshooting section in `README.md`.
