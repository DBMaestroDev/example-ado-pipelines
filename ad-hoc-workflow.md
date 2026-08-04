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
- **Approval gates are reused, not duplicated.** The same four environments (`Integration-pre-approval`, etc.) back both workflows' gates — same approvers, same "is it OK to touch Integration/Production" decision either way. Split them into separate environments later if ad-hoc and TaskID-based releases ever need independently tracked approvals; nothing about the current design blocks that.

## 2. Architecture: a thin trigger file, and a shared template

Same reasoning as `source-control-workflow.yml` (see that doc's section 2): Azure DevOps requires the trigger YAML to live in the repo it triggers from, so a thin file has to exist in every source-control repo, but the actual chain lives once in this `example-ado-pipelines` repo:

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
    targetOrganization: 'https://dev.azure.com/dbmsc'
    targetProject: 'Example'
    adHocBuildPipelineId: '62'   # this repo's "Build with Git Change Detection" pipeline
    upgradePipelineId: '60'      # shared "Upgrade Environment" pipeline
    runnerPool: 'dbmaestro-windows'
```

Unlike `source-control-workflow.yml`'s wrapper, this one also needs the `dbmaestro-cicd` resource declared at the root level — the template's Build stage checks that repo out directly to run its own detection step (see below), and `resources.repositories` entries used anywhere in an `extends:` chain must be declared in the root file, not the template.

**Setup note:** as with `source-control-workflow.yml`, the `adoPipelines` resource reuses the same `DBMaestroDev` GitHub service connection already authorized for `example-ado-source-control`. If that connection is scoped per-repository, it needs to be granted access to `example-ado-pipelines` too, or a second connection registered with the `endpoint:` value updated to match.

## 3. Stage-by-stage walkthrough

1. **Build** — checks out `self` and `dbmaestro-cicd`, resolves where `self` actually landed (see below), detects changed packages via git-diff, and queues the "Build with Git Change Detection" pipeline (fire-and-forget), passing the detected package names directly.
2. **Integration pre-approval gate** — Environment `Integration-pre-approval`. Skipped entirely if detection found nothing to build (see section 5).
3. **Upgrade (Integration)** — queues "Upgrade Environment" with `targetEnvironment=Integration` and the detected package names (fire-and-forget).
4. **Integration post-approval gate** — Environment `Integration-post-approval`.
5. **Production pre-approval gate** — Environment `Production-pre-approval`.
6. **Upgrade (Production)** — queues "Upgrade Environment" again with `targetEnvironment=Production` (fire-and-forget).
7. **Production post-approval gate** — Environment `Production-post-approval`. Final confirmation; workflow ends here.

Gates 2–7 follow the exact same pattern, fire-and-forget rationale, and manual-approval-check setup as `source-control-workflow.yml` — see that doc and `README.md`'s "Fire-and-forget design" section for the full explanation; it isn't repeated here.

### Resolving where `self` actually checked out

The Build job checks out two repos (`self` and `dbmaestro-cicd`), which pushes `self` out of the job's root directory into a subfolder of `$(Build.SourcesDirectory)` named after its actual repository name — not the `checkout:` alias. Since this template is meant to be reused by more than one source-control repo, each with a different repository name, that subfolder name can't be hardcoded. It's resolved at runtime instead:

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

If a push touches `ad-hoc/*` but git-diff finds no actual package changes (e.g. a file that matches the path filter but sits outside any package's own folder), the Integration pre-approval stage — and everything that depends on it — is skipped rather than running an approval gate and upgrade chain for nothing:

```yaml
condition: and(succeeded(), eq(dependencies.Build.outputs['Build.detectPackages.has_packages'], 'true'))
```

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
5. Confirm the Integration pre-approval gate becomes pending (not skipped) — approve it.
6. Confirm the Upgrade (Integration) stage queues "Upgrade Environment" with the detected package names; check that run succeeded.
7. Approve the remaining three gates in order (Integration post-approval, Production pre-approval, Production post-approval), confirming the Production upgrade run succeeds before the final approval.

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| Integration pre-approval gate (or everything after it) is skipped even though a package was clearly detected and built | The stage `condition:` is using `stageDependencies` instead of `dependencies` — see section 5's syntax table. Check the run's "Condition evaluation" panel on the skipped stage; `Expanded: and(True, eq(Null, 'true')))` is the signature of this exact bug. |
| "No packages detected" even though a file under `ad-hoc/` genuinely changed | Confirm `packagesFolder` matches between this workflow's parameters and however the change is laid out in the repo (default `'ad-hoc'`) — `detect-packages.ps1`/`.sh` match changed files as `"<packagesFolder>/<packageName>/..."`, so a mismatch here silently finds nothing. |
| `Set-Location : Cannot find path '...'` in the Build stage | The dynamically-resolved `selfSourcesPath` (section 3) didn't compute correctly — confirm `$(Build.Repository.Name)` for this repo is genuinely `Org/Repo` shaped, and that both `checkout: self` and `checkout: dbmaestro-cicd` are present (the nested-checkout-folder behavior only applies once 2+ repos are checked out in the job). |
| The build pipeline (62) tried to build a package literally named `None` | The `$pkgNames` empty-string guard (section 4) is missing or was removed from the Build stage's queue step — `packages_list` is the literal string `"None"` when nothing was detected, and must not be forwarded as-is. |
| `extends` template not found, or parameters rejected as unexpected | The `adoPipelines` resource doesn't resolve, or a parameter name/spelling in the wrapper's `extends: parameters:` block doesn't match what `azure-devops/templates/ad-hoc-workflow.yml` declares — compare the two side by side (section 2). |

For setup issues not specific to this workflow (missing service connections, PowerShell/Java/Azure CLI on the agent, environment permissions, notification subscriptions), see the Troubleshooting section in `README.md`.
