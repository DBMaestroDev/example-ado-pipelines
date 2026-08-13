# Ad-Hoc Workflow

*Deep dive on `ad-hoc-workflow.yml` — the git-diff-driven build → approval → upgrade chain for packages that don't follow the TaskID convention. Split out from `README.md` so this workflow's architecture, stages, and troubleshooting live in one place; see `README.md` for prerequisites and one-time ADO setup shared with [`source-control-workflow.yml`](./source-control-workflow.md).*

## 1. What this is for, and how it differs from the main workflow

Packages that don't go through the TaskID/commit-message flow — built straight from whatever changed under a folder in the repo — get their own trigger, `ad-hoc-workflow.yml`, rather than a mode of `source-control-workflow.yml`. It fires only on pushes touching `ad-hoc/*`:

```yaml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - ad-hoc/*
```

`source-control-workflow.yml` explicitly *excludes* that same path, so the two are mutually exclusive by design — a single push never triggers both. See [`source-control-workflow.md`](./source-control-workflow.md) for that side.

The other differences all follow from having no TaskID to read:

- **No commit message convention.** Any commit message works. Instead of extracting a value, this workflow's Build stage runs its own git-diff detection to figure out which package(s) actually changed.
- **Package names come from detection, not a parameter.** Everywhere `source-control-workflow.yml` uses the extracted TaskID as `packageName`/`packageNames`, this workflow uses whatever the detection step found.
- **Approval gates are reused, not duplicated.** The same eight environments (`Release-Source-pre-approval`, `UAT_Env_1-pre-approval`, etc. — one pre/post pair per environment across Release Source, UAT_Env_1, Pre_Prod_Env_1, and Prod_Env_1) back both workflows' gates — same approvers, same "is it OK to touch this environment" decision either way. Split them into separate environments later if ad-hoc and TaskID-based releases ever need independently tracked approvals; nothing about the current design blocks that.

## 2. Architecture: a thin trigger file, and a shared template

Same reasoning as `source-control-workflow.yml` (see that doc's section 2): Azure DevOps requires the trigger YAML to live in the repo it triggers from, so a thin file has to exist in every individual DBmaestro project's source-control repo, but the actual chain lives once in this `example-ado-pipelines` repo:

- **`example-ado-source-control/ad-hoc-workflow.yml`** — the thin trigger file. [View it](./example-ado-source-control/ad-hoc-workflow.yml).
- **`example-ado-pipelines/azure-devops/templates/ad-hoc-workflow.yml`** — the real pipeline. [View it](./azure-devops/templates/ad-hoc-workflow.yml).

```yaml
# example-ado-source-control/ad-hoc-workflow.yml (abridged)
resources:
  repositories:
    - repository: dbmaestro-cicd
      type: github
      name: DBMaestroDev/dbmaestro-cicd
      endpoint: dbmaestro-cicd
      ref: refs/heads/UseSSL_False
    - repository: adoPipelines
      type: github
      name: DBMaestroDev/example-ado-pipelines
      endpoint: 'DBMaestroDev'
      ref: refs/heads/main

extends:
  template: azure-devops/templates/ad-hoc-workflow.yml@adoPipelines
  parameters:
    packagesFolder: 'ad-hoc'
    targetADOOrganization: 'https://dev.azure.com/dbmsc'
    targetADOProject: 'Example'
    dBmaestroProjectName: 'Example-ADO'
    adHocBuildPipelineId: '62'   # this repo's "Build with Git Change Detection" pipeline
    upgradePipelineId: '60'      # shared "Upgrade Environment" pipeline
    runnerPool: 'dbmaestro-windows'
```

Unlike `source-control-workflow.yml`'s wrapper, this one also needs the `dbmaestro-cicd` resource declared at the root level — the template's Build stage checks that repo out directly to run its own detection step (see below), and `resources.repositories` entries used anywhere in an `extends:` chain must be declared in the root file, not the template.

**Setup note:** as with `source-control-workflow.yml`, `DBMaestroDev` above is just this guide's own example deployment — in your setup, both `example-ado-pipelines` and `example-ado-source-control` live in **your own** GitHub org, not `DBMaestroDev` (that org is only for `dbmaestro-cicd`). Since your two repos share one org, the `adoPipelines` resource can reuse the same GitHub service connection already required for `example-ado-source-control`'s self-trigger — no separate connection needed. If that connection is scoped per-repository, it needs to be granted access to `example-ado-pipelines` too, or a second connection registered with the `endpoint:` value updated to match.

## 3. Stage-by-stage walkthrough

1. **Build** — checks out `self` and `dbmaestro-cicd`, resolves where `self` actually landed (see below), detects changed packages via git-diff, and queues the "Build with Git Change Detection" pipeline (fire-and-forget), passing the detected package names directly.

After Build, the chain splits into two **independent** legs — Release Source, and a sequential 3-environment sub-chain covering UAT_Env_1, Pre_Prod_Env_1, and Prod_Env_1 — that both become available as soon as Build succeeds, rather than running one after the other. Environment selection happens purely through which leg's (first) pre-approval gate gets approved:

- **Release Source leg:**
  2. **Release Source pre-approval gate** — Environment `Release-Source-pre-approval`. Skipped entirely if detection found nothing to build (see section 5).
  3. **Upgrade (Release Source)** — queues "Upgrade Environment" with `targetEnvironment=Release Source` and the detected package names (fire-and-forget).
  4. **Release Source post-approval gate** — Environment `Release-Source-post-approval`.
- **UAT_Env_1 → Pre_Prod_Env_1 → Prod_Env_1 leg:** a sequential 3-environment sub-chain; each environment's own pre-approval → Upgrade → post-approval trio depends on the previous environment's post-approval gate:
  2. **UAT_Env_1 pre-approval gate** — Environment `UAT_Env_1-pre-approval`. Depends only on Build, and is skipped entirely if detection found nothing to build (same `has_packages` check as the Release Source leg — see section 5).
  3. **Upgrade (UAT_Env_1)** — queues "Upgrade Environment" with `targetEnvironment=UAT_Env_1` and the detected package names (fire-and-forget).
  4. **UAT_Env_1 post-approval gate** — Environment `UAT_Env_1-post-approval`.
  5. **Pre_Prod_Env_1 pre-approval gate** — Environment `Pre_Prod_Env_1-pre-approval`. Depends on the UAT_Env_1 post-approval gate.
  6. **Upgrade (Pre_Prod_Env_1)** — queues "Upgrade Environment" with `targetEnvironment=Pre_Prod_Env_1` and the detected package names (fire-and-forget).
  7. **Pre_Prod_Env_1 post-approval gate** — Environment `Pre_Prod_Env_1-post-approval`.
  8. **Prod_Env_1 pre-approval gate** — Environment `Prod_Env_1-pre-approval`. Depends on the Pre_Prod_Env_1 post-approval gate.
  9. **Upgrade (Prod_Env_1)** — queues "Upgrade Environment" with `targetEnvironment=Prod_Env_1` and the detected package names (fire-and-forget).
  10. **Prod_Env_1 post-approval gate** — Environment `Prod_Env_1-post-approval`. Final confirmation for that leg.

Both legs' first pre-approval gates (Release Source and UAT_Env_1) open at the same time once Build finishes. Approving only the Release Source gate runs only that leg; approving only the UAT_Env_1 gate runs the full UAT_Env_1 → Pre_Prod_Env_1 → Prod_Env_1 sub-chain in sequence (in either order relative to the other leg); approving both runs both legs concurrently. There is no `dependsOn` between the Release Source leg and the UAT_Env_1 leg.

Each leg's own gates follow the exact same pattern, fire-and-forget rationale, and manual-approval-check setup as `source-control-workflow.yml` — see that doc and `README.md`'s "Fire-and-forget design" section for the full explanation; it isn't repeated here.

### 3a. Closing out a run that only deploys one environment

Because the two legs are independent, a run where you only ever wanted, say, the Release Source leg will still have the UAT_Env_1 leg's pre-approval gate sitting there, pending, indefinitely — and, if that gate is later approved, the rest of that leg's chain through Pre_Prod_Env_1 and Prod_Env_1 pending behind it. This isn't a bug to fix in the YAML — it's inherent to how Azure DevOps evaluates multi-stage pipelines: a stage only becomes eligible to run once *every* stage it depends on has reached a terminal state (Succeeded, Failed, Skipped, or Rejected), and "awaiting manual approval" isn't terminal. There is no `condition:`/`dependsOn:` construct that lets the overall run finish while a sibling gate is neither approved, rejected, nor timed out — so an unused leg's gate has to be resolved one way or another before the run itself can close.

Three ways to resolve it, none of which require a YAML change:

1. **Reject the gate.** Whoever is deciding just rejects the unused environment's pre-approval check in the ADO UI, right after approving the one they actually want. Immediate, no setup required.
2. **Configure a timeout on that Environment's approval check.** Environments → the environment in question → "⋮" → Approvals and checks → edit the Approval check's timeout (e.g. 1 hour instead of the default). An un-acted-on gate then auto-rejects on its own instead of waiting indefinitely — useful if leaving a leg permanently unresolved becomes a recurring pattern rather than a one-off.
3. **Cancel the whole run.** A blunter option if neither of the above fits — stops everything, including the leg that already succeeded, rather than resolving just the unused gate.

**Caveat that applies to options 1 and 2 either way:** a rejected or timed-out approval counts as a *stage failure* in Azure DevOps' multi-stage YAML pipelines — there's no "partially succeeded" run outcome here. So a run where the Release Source leg deployed successfully and the UAT_Env_1 leg's gate was deliberately rejected will still show up in the Runs list, and in failure-notification emails (`README.md` section 9), as **Failed** overall. Anyone reviewing run status or failure notifications for this pipeline needs to check *which* stage actually failed before assuming something broke — a rejected/unused leg looks identical, at the run-result level, to a genuine failure.

No decision has been made yet on which of these three to standardize on; for now, resolve it however fits the situation.

### Resolving where `self` actually checked out

The Build job checks out two repos (`self` and `dbmaestro-cicd`), which pushes `self` out of the job's root directory into a subfolder of `$(Build.SourcesDirectory)` named after its actual repository name — not the `checkout:` alias. Since this template is meant to be reused by every individual DBmaestro project's own source-control repo, each with a different repository name, that subfolder name can't be hardcoded. It's resolved at runtime instead:

```powershell
$selfFolder = ("$(Build.Repository.Name)" -split '/')[-1]
$selfPath = Join-Path "$(Build.SourcesDirectory)" $selfFolder
```

`$(Build.Repository.Name)` returns `Org/Repo` for a GitHub self-repo (e.g. `DBMaestroDev/example-ado-source-control`), not just the repo name — hence the split. The result is stashed in a `selfSourcesPath` variable and passed into the `detect-packages.yml@dbmaestro-cicd` template call as `sourcesPath`.

## 4. Detection, and why the build pipeline doesn't detect twice

The Build stage's git-diff detection (via `detect-packages.yml@dbmaestro-cicd`, `detectFromPush: true`) is the same mechanism the "Build with Git Change Detection" pipeline (definition ID 62 in this deployment) would otherwise run on its own. Running it twice for the same push would be redundant, so this workflow instead passes what it already found straight through:

```powershell
$hasPackages = "$(detectPackages.has_packages)"
$pkgNames = if ($hasPackages -eq "true") { "$(detectPackages.packages_list)" } else { "" }

az pipelines run ... --parameters packageNames="$pkgNames" ...
```

`build-git-changes.yml` accepts an optional `packageNames` parameter for exactly this: when it's non-empty, that pipeline's own Detect stage is skipped entirely (a compile-time `${{ if eq(parameters.packageNames, '') }}` around the whole stage), and the passed-in names go straight to the build job. Leave `packageNames` empty (the default) when queuing that pipeline any other way — e.g. manually — and it detects changes itself exactly as before.

Note the `$pkgNames` guard above: `detect-packages.ps1`/`.sh` set `packages_list` to the literal string `"None"` when nothing was found, not an empty string. Forwarding that literally would make the build pipeline try to build a package named `"None"` — passing empty string instead lets its own `packageNames`-handling treat it as "nothing to build," which it already does gracefully.

## 5. Skipping the chain when nothing changed

If a push touches `ad-hoc/*` but git-diff finds no actual package changes (e.g. a file that matches the path filter but sits outside any package's own folder), both pre-approval stages — and everything that depends on either of them — are skipped rather than running an approval gate and upgrade chain for nothing:

```yaml
condition: and(succeeded(), eq(dependencies.Build.outputs['Build.detectPackages.has_packages'], 'true'))
```

Both `ReleaseSourcePreApproval` and `UatEnv1PreApproval` carry this exact condition independently — since the two legs don't depend on each other, the UAT_Env_1 leg can't just inherit the check transitively through the Release Source leg's stage the way it could when the chain was strictly sequential. (`PreProdEnv1PreApproval` and `ProdEnv1PreApproval`, further down the UAT_Env_1 leg's own sequential sub-chain, do inherit it transitively through their own `dependsOn`.)

### The `dependencies` vs `stageDependencies` gotcha

This condition uses a **different** expression context than the `stageDependencies.<Stage>.<Job>.outputs[...]` syntax used elsewhere in these pipelines (see `source-control-workflow.md` section 4, and the `packageNames` job variable in the Upgrade stages of this same template). The two look similar enough to reach for interchangeably, but they aren't:

| Context | Syntax |
|---|---|
| A **job's `variables:`** block (runtime `$[ ]` expression), referencing an earlier *stage's* job output | `stageDependencies.<StageName>.<JobName>.outputs['<StepName>.<VarName>']` |
| A **stage's own `condition:`** field, referencing an earlier stage's job output | `dependencies.<StageName>.outputs['<JobName>.<StepName>.<VarName>']` |

Note where the job name moves: inside the `outputs[]` key for `condition:`, but as its own path segment for `variables:`. Using the `stageDependencies` form inside a `condition:` doesn't error — it just silently resolves to `Null`, so `eq(Null, 'true')` is always `False` and the stage (and everything downstream of it) gets skipped even when the Build stage genuinely succeeded and found a package. This was hit and fixed via a live run; the ADO run's "Condition evaluation" panel on the skipped stage is what surfaced it (`Expanded: and(True, eq(Null, 'true')) / Result: False`) — that panel is the fastest way to catch this class of bug if a gate mysteriously never fires.

## 6. Test

1. Commit a change to a file under `ad-hoc/` in `example-ado-source-control` (any message — no TaskID convention needed).
2. Confirm `ad-hoc-workflow.yml` triggers, the Build stage detects the changed package(s), and the "Build with Git Change Detection" pipeline (62) is queued with those package names.
3. Confirm the main `source-control-workflow.yml` orchestrator did **not** also trigger from the same commit.
4. Check that build pipeline's run and confirm it built the expected package(s).
5. Confirm **both** the Release Source and UAT_Env_1 pre-approval gates become pending (not skipped) at the same time, right after Build finishes — this is the "both legs open in parallel" behavior.
6. Approve only the Release Source pre-approval gate first, and confirm the UAT_Env_1 leg stays pending/untouched (its Upgrade and post-approval stages, and the downstream Pre_Prod_Env_1/Prod_Env_1 stages, haven't started) while the Release Source leg proceeds.
7. Confirm the Upgrade (Release Source) stage queues "Upgrade Environment" with the detected package names; check that run succeeded, then approve Release Source post-approval.
8. Approve the UAT_Env_1 pre-approval gate, confirm Upgrade (UAT_Env_1) queues and succeeds, then approve UAT_Env_1 post-approval; repeat the same pre-approval → upgrade → post-approval pattern for Pre_Prod_Env_1 and then Prod_Env_1 to finish that leg.

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| The Release Source or UAT_Env_1 pre-approval gate (or everything after it) is skipped even though a package was clearly detected and built | The stage `condition:` is using `stageDependencies` instead of `dependencies` — see section 5's syntax table. Check the run's "Condition evaluation" panel on the skipped stage; `Expanded: and(True, eq(Null, 'true')))` is the signature of this exact bug. |
| "No packages detected" even though a file under `ad-hoc/` genuinely changed | Confirm `packagesFolder` matches between this workflow's parameters and however the change is laid out in the repo (default `'ad-hoc'`) — `detect-packages.ps1`/`.sh` match changed files as `"<packagesFolder>/<packageName>/..."`, so a mismatch here silently finds nothing. |
| `Set-Location : Cannot find path '...'` in the Build stage | The dynamically-resolved `selfSourcesPath` (section 3) didn't compute correctly — confirm `$(Build.Repository.Name)` for this repo is genuinely `Org/Repo` shaped, and that both `checkout: self` and `checkout: dbmaestro-cicd` are present (the nested-checkout-folder behavior only applies once 2+ repos are checked out in the job). |
| The build pipeline (62) tried to build a package literally named `None` | The `$pkgNames` empty-string guard (section 4) is missing or was removed from the Build stage's queue step — `packages_list` is the literal string `"None"` when nothing was detected, and must not be forwarded as-is. |
| `extends` template not found, or parameters rejected as unexpected | The `adoPipelines` resource doesn't resolve, or a parameter name/spelling in the wrapper's `extends: parameters:` block doesn't match what `azure-devops/templates/ad-hoc-workflow.yml` declares — compare the two side by side (section 2). |

For setup issues not specific to this workflow (missing service connections, PowerShell/Java/Azure CLI on the agent, environment permissions, notification subscriptions), see the Troubleshooting section in `README.md`.
