# Getting Notified When an Approval Is Needed

*Companion note to README.md — covers how approvers (approver1@dbmaestro.com, approver2@dbmaestro.com) find out when one of the eight gates (`Release-Source-pre-approval`, `Release-Source-post-approval`, `UAT_Env_1-pre-approval`, `UAT_Env_1-post-approval`, `Pre_Prod_Env_1-pre-approval`, `Pre_Prod_Env_1-post-approval`, `Prod_Env_1-pre-approval`, `Prod_Env_1-post-approval`) is waiting on them.*

There are two independent layers. They can be used together.

## 1. Automatic personal notification (default, no setup required)

Azure DevOps ships a built-in personal notification template for YAML pipelines called **"Run stage waiting for approval."** It's created automatically for anyone who has interacted with a pipeline (run it, or been added as an approver on one of its environments), and fires an email to that person the moment they're listed as an approver on a pending check.

- Delivery goes to the approver's own registered email address — no admin configuration needed.
- Each approver can verify or adjust it themselves: avatar icon (top right) → **Notifications** → **Personal notifications** → find it under the **Pipelines** category → confirm the toggle is on.
- Because approver1@dbmaestro.com and approver2@dbmaestro.com are individual accounts, this alone is usually enough to cover the eight gates in this workflow.

## 2. Project-level subscription (optional — for a shared address)

If you also want approval-pending emails to land in a shared inbox or distribution list — for example so a second person has visibility, or as a backup in case an approver's personal notification gets turned off — add a project-level subscription, the same way the build-failure notification in the main README (section 11) was set up:

1. Project Settings (`Example` project) → **Notifications** → **New subscription**.
2. Template: **"Run stage waiting for approval."**
3. Filter: **Environment name** — set to one of `Release-Source-pre-approval`, `Release-Source-post-approval`, `UAT_Env_1-pre-approval`, `UAT_Env_1-post-approval`, `Pre_Prod_Env_1-pre-approval`, `Pre_Prod_Env_1-post-approval`, `Prod_Env_1-pre-approval`, `Prod_Env_1-post-approval` if you want it scoped to a specific gate, or leave unfiltered to cover all eight.
4. Deliver to → **Custom email address** → e.g. `devops@dbmaestro.com`.
5. Save.

Repeat per gate if you want separate filtered subscriptions rather than one catch-all.

## Which to use

| Goal | Use |
|---|---|
| Each named approver gets emailed automatically | Layer 1 — already works by default, just confirm it's on |
| A shared distribution list also sees pending approvals | Layer 2 — add a project-level subscription |
| Redundancy in case a personal notification was disabled | Layer 2 |
