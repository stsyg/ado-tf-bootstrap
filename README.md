# Azure DevOps + Terraform Project Bootstrap

**Set up a new Terraform project on Azure in minutes: answer a few questions and get remote state, passwordless pipelines, self-hosted build agents and approvals - already wired together.**

## Overview

This kit is a simplified, general-purpose take on the bootstrap in the
[Azure Landing Zones Terraform accelerator](https://github.com/Azure/alz-terraform-accelerator) (its Terraform
modules live in [accelerator-bootstrap-modules](https://github.com/Azure/accelerator-bootstrap-modules)). The idea
- one run that builds the state storage, the identities and the Azure DevOps project and pipelines a Terraform
deployment needs - comes from there. Here it is cut down to serve **any** project that uses Azure DevOps and
Terraform, with nothing about Azure Landing Zones in it. It is an independent community project, not part of
the accelerator and not supported by Microsoft.

Starting a Terraform project on Azure means the same hand-built groundwork every time: somewhere safe to
keep the state, identities the pipelines can use without a secret, agents that can reach private
resources, and a repository and pipelines that plan on every pull request and apply only after approval.
This kit does that groundwork for you, once per project, from a PowerShell script and a Terraform root.

You run one script and answer questions (project name, region, subscription, Azure DevOps organization,
approvers, tags, agent size and cost). It writes the variables file from your answers, shows the plan, and
- when you type `apply` - builds:

- **In Azure:** a private, versioned Terraform state account; separate read-only *plan* and read-write
  *apply* managed identities that sign in to Azure DevOps by OIDC (workload identity federation - no
  client secret exists); role assignments on the scopes you name; and, optionally, self-hosted Azure
  DevOps agents on Container Instances in a private network (registry, private endpoints, private DNS,
  NAT gateway).
- **In Azure DevOps:** the project, a main repository with a starter Terraform layout, a shared
  pipeline-templates repository, branch policies, a CI pipeline (plan on every pull request) and a CD
  pipeline (plan, then apply only if the plan has changes and an approver agrees), environments, service
  connections with approval, branch-control, lock and required-template checks, a variable group, an
  approvers group and an agent pool.
- **Every resource tagged** to your organization's standard, up to Azure's limit of 15 tags, including a
  `repository` tag filled in for you.

The pipelines skip the apply when there is nothing to change, show the plan as a summary card on the run,
and never apply from a workstation. It is generic: no Azure Landing Zones or other framework is involved,
and nothing in it is specific to one organization. It is a **foundation**, not your infrastructure: what the
project's Terraform builds afterwards is yours, changed by pull request through the two pipelines.

```pwsh
.\New-ProjectBootstrap.ps1
```

Run it again for the next project; run it again for the same project to change an answer. To use it in a
project - clone, copy into the project's folder, bootstrap - go to
[Use it for a project](#use-it-for-a-project-clone-copy-bootstrap). Everything it builds is listed under
[What it builds](#what-it-builds).

## Use it for a project: clone, copy, bootstrap

This repository is the **kit**, not a project. Each project gets **its own copy** of the kit inside the
project's own repository, so the project tracks the version it was built with, and keeps its own answers
and state next to it.

**1. Clone the kit once** (anywhere; pull it again before each new project to get the latest):

```pwsh
git clone https://github.com/stsyg/ado-tf-bootstrap.git C:\repo\ado-tf-bootstrap
```

**2. Copy it into the project's folder** - a `bootstrap\project-bootstrap` folder in the project's repository
(the name `project-bootstrap` matters: the script's "another laptop" instructions use it). Leave out `.git`,
and any `output` and `.terraform` folders:

```pwsh
robocopy C:\repo\ado-tf-bootstrap C:\repo\<project>\bootstrap\project-bootstrap /E /XD .git output .terraform
```

The kit's own `.gitignore` keeps `output\` (the answers, the variables, the bootstrap's state) and
`.terraform\` out of the project's git; commit the rest, so the project records which kit built it.

**3. Set the organization's tag standard** (once per organization, optional): edit `tag-defaults.psd1` - the
tags every project must carry and their defaults. Or skip it and answer the tag questions.

**4. Bootstrap.** Meet the prerequisites below (Azure CLI signed in, Terraform, an Azure DevOps token for
exactly your organization), then, from the copied folder:

```pwsh
cd C:\repo\<project>\bootstrap\project-bootstrap
az login
$env:TF_VAR_azure_devops_personal_access_token = Read-Host 'Azure DevOps personal access token' -MaskInput
$env:TF_VAR_azure_devops_agent_pat = Read-Host 'Agent registration token (Agent Pools read and manage only)' -MaskInput
.\New-ProjectBootstrap.ps1          # asks, shows the plan, applies when you type 'apply'
.\Test-ProjectBootstrap.ps1 -OutputPath .\output\<project>-<environment>   # read-only check, all PASS
```

Prefer to answer in a file: copy `answers.example.psd1` to `answers.psd1`, fill it in, and run
`.\New-ProjectBootstrap.ps1 -AnswersFile .\answers.psd1`. A run that stops half-way is resumed by running the
same command with the same `-OutputPath` (see "Running it").

**5. What you have afterwards.** The Azure and Azure DevOps objects below; the bootstrap's own state in
`output\<project>-<environment>\` on this laptop; and, as the last step, the kit, the answers and the
**encrypted** state on the branch `bootstrap` of the project's new main repository in Azure DevOps. Keep the
passphrase in your password manager. On another laptop: "Another laptop" below. The project's Terraform then
lives in the main repository's `main` branch and is changed by pull request through the two pipelines.

**Updating the kit** later: pull the kit repository, run step 2 again over the same folder (`output\` is left
alone), review the diff in the project's git, and run `-Mode Plan` before applying.

**One project, one copy, one output folder.** Never share an output folder between projects, and never run
two applies against the same state at once.

## What it builds

### In Azure

| Resource | Purpose |
| --- | --- |
| Resource group - state | Holds the Terraform remote backend. |
| Storage account + blob container `tfstate` | The state. Shared-key access off, TLS 1.2, no anonymous access, blob versioning and soft delete (recovery), no public network access when private networking is on. The container is created through the Resource Manager, so it works from a workstation even when the account is private. |
| Resource group - identity | Holds the deployment identities. |
| User-assigned managed identity - **plan** | Runs `terraform plan`. Read-only on the targets. |
| User-assigned managed identity - **apply** | Runs `terraform apply`. A separate identity, so a pull request's plan can never write. |
| Federated identity credentials | One per identity: Azure DevOps signs in with its own token, exchanged for the identity's - **no client secret exists**. |
| RBAC role assignments | Plan: `Reader` (configurable); apply: `Contributor` (configurable), on every target subscription and management group you name. On the state container: apply `Storage Blob Data Contributor`; plan `Storage Blob Data Reader` (or Contributor with `plan_can_write_state`). |
| Resource providers | Registered in the bootstrap subscription before the resources that need them. |
| Container registry (ACR) | Builds the agent image from a Dockerfile in git (an ACR task), and serves it. SKU is your choice (`container_registry_sku`): Basic, Standard or Premium; only Premium has a private endpoint. Auto: Premium with private networking, Basic without. |
| Container instances (ACI) | The self-hosted agents (2 by default), pulling the image with their own identity (`AcrPull`). |
| Virtual network, two subnets, two network security groups | One subnet delegated to container instances, one for private endpoints. Each is **created with its network security group** (and the NAT gateway / route table) in one request, because a policy that denies a subnet without a group refuses the usual create-then-attach. Subnets have no default outbound access. |
| Private endpoints (storage, registry) + private DNS zones | Private connectivity to the state and the registry. |
| NAT gateway + public IP | One fixed outbound address for the agents. **Optional** (`use_nat_gateway`): where policy denies public IP addresses, leave it out and give `agent_route_table_id` (for example a route to the hub firewall). |

Without self-hosted agents the registry, instances, network, endpoints and NAT gateway are not created;
the state account then has a public endpoint (still Azure AD sign-in only) for the Microsoft-hosted agents.

### In Azure DevOps

| Object | Purpose |
| --- | --- |
| Project | Created, or an existing one used as it is. |
| Repository - main (name from your answer) | `README.md`, `.gitignore`, `.editorconfig`, `terraform.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `terraform.tfvars` (written from your answers), `modules/`, `docs/` (getting started, operations), `.pipelines/ci.yaml` and `cd.yaml`. |
| Repository - pipeline templates | The shared pipeline logic and its README. |
| Branch policies | `main` of both repositories: pull request only, squash merge only; main repository also: CI must pass, and (with more than one approver) a reviewer other than the last pusher. |
| Pipeline `01 <name> Continuous Integration` | Format check, `init`, `validate`, then a plan; blocks the merge if it fails. |
| Pipeline `02 <name> Continuous Delivery` | Plan on `main`; apply only if the plan has changes and the approvers say so. |
| Environments - plan, apply | One per identity. |
| Variable group - backend | The three names the pipelines need to find the state. No secrets. |
| Service connections - plan, apply | Workload identity federation to the two identities. |
| Service connection checks | Apply: **approval** by the approvers group, and **branch control** (only from `main`). Both: **exclusive lock** (one run at a time), **required template** (a pipeline that does not extend the templates repository's templates cannot sign in to Azure). |
| Approvers group + membership | The people you named. |
| Agent pool (+ queue for the project) | Where the container instances register. |

The pipelines are the proven part of the accelerator pattern, with ALZ left out: **no apply when the
plan has no changes** (an approver is never asked about an empty plan), the **plan as a card** on the run
summary (counts, destructive actions first, output changes, drift, files changed, full redacted plan),
the saved plan file is what gets applied, **state-lock handling** that never releases an apply lock on
its own (when plans take the lock), and queued applies. Details: the templates repository's README, which the bootstrap commits
([content/templates-repo/README.md](content/templates-repo/README.md)).

## Before you run it

| You need | Why |
| --- | --- |
| PowerShell 7 (`pwsh`) | The scripts. |
| Terraform 1.10 or later on the PATH | Runs the bootstrap. |
| Azure CLI, signed in (`az login`) | Terraform's Azure sign-in, and the subscription and region lookups. |
| **Owner** (or Contributor + User Access Administrator) on the bootstrap subscription, and permission to assign roles on every target scope | The bootstrap creates role assignments. |
| An Azure DevOps organization connected to the same Microsoft Entra tenant, and **Project Collection Administrator** (or equivalent rights to create projects, agent pools, groups and service connections) | Everything in the second table. |
| A personal access token for you - scopes: Project and Team (read, write, manage); Code (full); Build (read and execute); Release (read, write, execute); Service Connections (read, query, manage); Environment (read and manage); Variable Groups (read, create, manage); Agent Pools (read and manage); Graph (read and manage); Identity (read); Security (manage) | The `azuredevops` provider. Set it as `TF_VAR_azure_devops_personal_access_token` or paste it when asked; it is never written to a file. |
| A **second** token, scope **Agent Pools (read and manage)** only - when you use self-hosted agents | The agent containers register with it. Set `TF_VAR_azure_devops_agent_pat` or paste it. It is kept, as a sensitive value, in the bootstrap state and in the container group: give it nothing else. |

## If the plan says "not authorized to access Azure DevOps Organization"

That is Azure DevOps answering 401: it does not accept the personal access token. The script now checks the token before it starts and says why it refuses it - usually the token expired or was revoked (the default life is short), was created for a different organization (the token's *Organization* box) or under a different Microsoft Entra tenant, or `TF_VAR_azure_devops_personal_access_token` still holds an old value. Create a new token for exactly that organization, set the variable, and run again; Terraform resumes from the state. (A token Azure DevOps does not accept is answered with 203 and a sign-in page, not an error, so a plain REST call used to pass it.)

## The questions

| Answer (variable) | Default | What it does |
| --- | --- | --- |
| `project_name` | - | 2-12 characters; in every Azure name. |
| `environment_name` | `prd` | 1-4 characters; in every name. |
| `azure_location`, `location_short` | `canadacentral`, from the region | Region of everything; short code in names. |
| `instance_number` | `001` | Lets a second copy sit beside the first. |
| `tags` | the organization's standard: `organizationName` (the Azure DevOps organization), `environment` (the environment code), `managedBy` (`Terraform`), `appContact` (whoever runs this) | On every Azure resource - see Tags below. One question per required tag, then "additional tags". |
| `required_tag_names` | from `tag-defaults.psd1` | The tags every project must give a value; Terraform refuses to run without them. |
| `bootstrap_subscription_id` | your current subscription | Holds everything; the service connections are created for it. |
| `target_subscription_ids`, `target_management_group_ids` | the bootstrap subscription | Where the plan and apply identities get their roles - the scopes the project's Terraform manages. |
| `plan_role_definition_name`, `apply_role_definition_name` | `Reader`, `Contributor` | Use `Owner` for apply if the project's Terraform assigns roles. |
| `plan_can_write_state` | no | No: plans read the state (`-lock=false`). Yes: plans take the lock - and a pull request's plan code can write the state. See Security notes. |
| `storage_account_replication_type` | `ZRS` (`LRS` where the region has no zones - looked up) | State redundancy. |
| `azure_devops_organization_url` | - | A name or a URL. |
| `azure_devops_project_name`, `azure_devops_create_project` | the project name, yes | New or existing project. |
| `repository_name` | `<project>-infra` | The main repository. |
| `templates_repository_name` | `<repository>-templates` | The templates repository. |
| `pipeline_display_name` | the project name, capitalised | `01 <name> Continuous Integration` / `02 <name> Continuous Delivery`. |
| `approvers` | you | Sign-in addresses; blank = no approval on the apply. **Lab: one is enough. Production: two or more** - the file says so in a comment. |
| `approver_entra_group_ids` | none | Object IDs of Entra **security** groups whose members approve; membership is then managed in Entra with no re-run. A mail-only distribution list is not accepted by Azure DevOps - use a security group. Find the ID: `az ad group show --group <name> --query id -o tsv`. |
| `create_branch_policies` | yes | Protect `main`. |
| `terraform_cli_version` | `latest` | What the pipelines install by default. |
| `use_self_hosted_agents`, `use_private_networking` | yes, yes | The agent and network pieces. |
| `use_nat_gateway` | yes | A NAT gateway and a public IP for the agents' outbound traffic. **No** where policy denies public IPs (see "When policy says no"). |
| `agent_route_table_id` | none | An existing route table (same subscription and region) for the agent subnet, e.g. 0.0.0.0/0 to a hub firewall. Required when `use_nat_gateway` is no. |
| `container_registry_sku` | auto | `Basic` / `Standard` / `Premium` (see Cost). Auto = Premium with private networking, Basic without. |
| `agent_container_instance_count`, `agent_container_cpu`, `agent_container_memory` | 2, 2, 4 | What the agents cost: about $80/month per instance at the defaults. |
| network ranges | `10.0.0.0/24` in three parts | Only with private networking. |

Anything else in [terraform/variables.tf](terraform/variables.tf) - container sizes, the agent image and its
tag, soft-delete days, and `names`, which overrides **any** generated name - can be put in the answers
file. [answers.example.psd1](answers.example.psd1) shows the shape.

## Running it

```pwsh
.\New-ProjectBootstrap.ps1                                 # asks, then asks what to do next
.\New-ProjectBootstrap.ps1 -Mode Plan                      # also signs in, init, plan - creates nothing
.\New-ProjectBootstrap.ps1 -AnswersFile .\answers.psd1 -Mode Plan -NonInteractive
.\New-ProjectBootstrap.ps1 -OutputPath .\output\payments-prd -Mode Apply   # same answers, apply
.\Test-ProjectBootstrap.ps1 -OutputPath .\output\payments-prd              # read-only check
.\New-ProjectBootstrap.ps1 -Mode Backup -OutputPath .\output\payments-prd  # store the kit and state in the repository again (no questions)
```

Everything it writes is in `-OutputPath` (default `.\output\<project>-<environment>`, which `.gitignore`
skips): `bootstrap.tfvars` (readable, editable), `answers.json` (the defaults of the next run; no
secrets), `bootstrap.tfstate` (**keep it** - it is what changes or removes what was built), `outputs.json`.

**Re-running.** The same `-OutputPath` starts from its earlier answers. Changing an answer and applying
changes Azure and Azure DevOps to match. What a re-run does **not** do is overwrite the starter files once
they are in the repository: after the first apply the repositories belong to the team, and edits made
through pull requests are left alone.

**Order of events at the first apply.** Resource providers, resource groups, state storage, identities;
the Azure DevOps project, repositories (starter files committed `[skip ci]`), environments, service
connections and their checks, federated credentials; the registry builds the agent image; the container
instances start and register. The agents appear in the pool a few minutes after the apply ends.

**Keeping it - another laptop.** The last step of a successful apply stores the kit, the answers, the outputs and the **state** in the project's own main repository, on the branch `bootstrap` (see "Another laptop" below). `-SkipRepositoryBackup` leaves it out.

**Removing it.** From the output folder's state: set `TF_DATA_DIR` to `<OutputPath>\.terraform`,
the two token variables, and run
`terraform -chdir=<kit>\terraform destroy -var-file=<OutputPath>\bootstrap.tfvars`. The project's own state
container and everything its Terraform created are **not** reversed by this: destroy those first, through
the project's pipeline (`terraform_action: destroy`).

## When policy says no

An organization's Azure Policy can refuse what the bootstrap creates. In a subscription under a landing-zone management group the bootstrap was refused twice (the activity log names no policy; the assignments on the management groups do):

| Refusal (`RequestDisallowedByPolicy`) | Policy | What the kit does |
| --- | --- | --- |
| The NAT gateway's **public IP** | *Deny the creation of public IP* | **Either** keep the NAT gateway and waive that one assignment on the bootstrap's own network resource group - `public_ip_deny_policy_assignment_id` (the assignment's resource ID) and `policy_exemption_expires_on` (an exemption must end) make the bootstrap create the exemption itself; it needs Owner or Resource Policy Contributor there, and is not created if one by hand already exists. **Or** `use_nat_gateway = false`: no public IP, no NAT gateway. The agent subnet then needs `agent_route_table_id` (a route to the hub firewall, say) and the virtual network a peering to that hub, which whoever runs the hub creates. The bootstrap **refuses to run** when private agents would have no way out. |
| Each **subnet** | *Subnets should have a Network Security Group* | Subnets are written through the Resource Manager with their network security group in the same request, always. |

To see what applies to a subscription: its management-group chain (`resourcecontainers`, `managementGroupAncestorsChain`, in Azure Resource Graph), then `az policy assignment list --scope /providers/Microsoft.Management/managementGroups/<id>` for each group.

## Another laptop

After a successful apply the script stores, on the branch **`bootstrap`** of the project's main repository: the kit (this folder), and `output\<project>-<environment>\` with `bootstrap.tfvars`, `answers.json`, `outputs.json` and the **state**. It is a branch of its own, not `main`: `main` is protected (pull request, a passing CI run) and holds the project's Terraform; the pipelines run from `main` only, so a push to `bootstrap` starts nothing.

**The state is encrypted.** It holds the agent registration token in the clear, and a repository is read by many more people than the one who ran the bootstrap. The state is stored as `bootstrap.tfstate.enc` - AES-256-GCM with a key derived from a passphrase (PBKDF2-SHA256, 600,000 rounds) - and a person who does not know the passphrase cannot read it. The script asks for the passphrase (12+ characters, twice) **before** the apply, so nobody has to be at the keyboard when it ends; unattended, set `BOOTSTRAP_STATE_PASSPHRASE`. Keep it in your password manager: **without it the stored state cannot be read.** `-UnencryptedState` stores the state as it is - only where everyone who can read the repository may see every secret in it.

On the new laptop (PowerShell 7, git, Terraform and the Azure CLI installed):

```pwsh
git clone --branch bootstrap <the repository's URL> project-bootstrap
cd project-bootstrap
.\Restore-ProjectBootstrap.ps1          # asks for the passphrase; writes output\<name>\bootstrap.tfstate (git ignores it)
az login
$env:TF_VAR_azure_devops_personal_access_token = '<your token>'
$env:TF_VAR_azure_devops_agent_pat = '<the agent token>'
.\New-ProjectBootstrap.ps1 -OutputPath .\output\<name> -Mode Plan     # the earlier answers; no changes = the state matches
```

A change made there and applied stores the new state on the branch again (a later publish builds on whatever is there; it never rewrites history). If the store fails after a good apply (no git, a token without Code write) the bootstrap is still done; run `-Mode Backup -OutputPath ...` once it is fixed. The token needs **Code (read & write)**, which the token scopes above already include.

## Names and their limits

Every name follows `<type>-<project>-<environment>-<region code>-<instance>[-<role>]`
(`rg-payments-prd-cac-001-state`, `id-payments-prd-cac-001-apply`), except where Azure forbids hyphens or
needs global uniqueness: the storage account and registry are `st`/`acr` + project + environment + six hex
characters of a hash of subscription and name (stable across plans). Before anything is created, every
name is checked against its limit from Microsoft Learn's *Naming rules and restrictions for Azure
resources* (storage account 3-24 lowercase alphanumerics; registry 5-50 alphanumerics; container group
1-63; resource group 1-90; managed identity 3-128; federated credential 3-120 per Entra's federated-credential
considerations; virtual network and private endpoint 2-64; subnet and public IP 1-80). **The NAT gateway's
limit is not on that page**; the same 1-80 rule as the other `Microsoft.Network` names is applied and
Azure has the last word. A name that breaks a rule fails the plan, naming the rule.

## Security notes

- No secret is ever written by design. The tokens live in the process environment for the run. Two
  honest exceptions, both local to the output folder: the plan file Terraform saves between plan and
  apply holds the sensitive values in clear text, so the script deletes it whichever way the run ends;
  and the bootstrap's **state** holds the agent token (sensitive, but not encrypted). The bootstrap's
  state is local because the state account it creates may accept no public traffic. Treat the output
  folder as a secret store, back it up, and give the agent token no scope but Agent Pools.
- Plan and apply are different identities, and **a pull request's Terraform runs as the plan
  identity**. That is why the plan identity is `Reader` on the targets and, by default
  (`plan_can_write_state = false`), only `Storage Blob Data Reader` on the state container: the plan
  runs with `-lock=false`, and code in a pull request can read the state but not overwrite or delete it.
  Answer *yes* to `plan_can_write_state` and plans take the state lock (and a stale plan lock is
  released automatically) - but then a pull request's plan code can write the state.
- The plan connection has no approval; the apply connection has one, an exclusive lock, and a **branch
  control** check: it can be used only from `main`, and only while `main` is protected, so queueing the
  CD pipeline on another branch applies nothing.
- A service connection can only be used by a pipeline that extends the templates repository's template:
  changing a pipeline's own YAML cannot skip the approval or reach Azure another way. **It can,
  however, change what the CI run does.** A pull request that replaces `.pipelines/ci.yaml` with a job
  that signs in to nothing still "passes" the build-validation policy. What stops that is review: with
  more than one approver (or an Entra approver group), every pull request - this file included - needs a
  reviewer other than its last pusher. With one approver (fine for a lab) there is no reviewer, and that
  person is the whole control.
- Protect the templates repository's `main` (the bootstrap does): a change there changes every run.
- The CD `module` artifact holds the saved plan file, which can contain sensitive values in clear text
  (the redacted text plan is published separately). Anyone who can read the run can download it. Narrow
  who can read the project's pipelines and set a short artifact retention; a stronger fix (apply
  re-plans and compares, so no plan file is published at all) is described in the next section.
- Only the **apply** step receives the job's access token, to refresh the federated sign-in during a long
  apply; it runs code that was merged to `main` and approved. The plan and CI steps never see it,
  because they run a pull request's code.
- Terraform plan runs repository code. In CI that is the pull request's code, running as a
  **read-only** identity.

## Limits of this version

- Azure public cloud and Azure DevOps Services (not Server). The private DNS zone names
  (`privatelink.blob.core.windows.net`, `privatelink.azurecr.io`) are the public-cloud ones.
- **Not yet proven live.** Everything that can be proven without credentials is tested (below): names,
  roles, scopes, checks, authorisations, rendered files, the pipeline templates' parameters, the plan
  renderer, the lock decision, the question flow, and the Azure resource schemas against the real
  providers. The first run against a real organization and subscription - and
  `Test-ProjectBootstrap.ps1` against it, whose Azure DevOps and Azure calls have so far only been
  syntax-checked - is the proof still owed; do it in a lab, and expect to adjust.
- If a first apply stops part-way (a dropped connection, an expired token, a refused push while the
  starter files are written), run `-Mode Apply` again: Terraform resumes from the state.
- The registry task builds the agent image from a public GitHub repository
  (`agent_container_image_repository`), so the agents' NAT address needs outbound access to it.
- The ACR task identity uses a preview API (`2025-05-01-preview`) to let tasks through a closed registry;
  without private networking it is not used.
- Role assignments need time to propagate. The agent containers are created after the registry
  roles and the network, but Azure may still refuse the first image pull or the first build; run
  `-Mode Apply` again and it completes.
- ID token refresh (a federated sign-in renewed during a long operation) is on for the **apply** step
  only, and falls back to the single token on an agent that does not offer the service connection's ID.
  CI and the plan keep the single token on purpose (they run a pull request's code): a plan that runs
  longer than the access token lives fails and is run again.

## Cost, rough

Monthly, pay-as-you-go list prices from the Azure Retail Prices API for Canada Central (2026-11-19);
check the Azure pricing calculator for your region and agreement. **Everything below is a question of
the script and a commented line of `bootstrap.tfvars`**: change the answer (or the line) and re-run.
The script prints this estimate for your answers before it writes anything.

| Choice (variable) | What it costs | What you give up |
| --- | --- | --- |
| Agent instances (`agent_container_instance_count`, `agent_container_cpu`, `agent_container_memory`) | vCPU $0.0446/h + memory $0.00487/GB-h, per second: **~$80/month per instance at 2 vCPU / 4 GB**, $40 at 1 / 2 | Fewer instances: pipelines queue for a free agent. Smaller: slower plans, out-of-memory on big providers. Lab: 1 instance. |
| Registry `Basic` (`container_registry_sku`) | ~$5/month ($0.17/day). 10 GiB, 2 webhooks | No private endpoint. Plenty for one agent image. |
| Registry `Standard` | ~$20/month ($0.667/day). 100 GiB, 10 webhooks | No private endpoint. More storage and throughput than Basic - rarely needed here. |
| Registry `Premium` | ~$51/month ($1.67/day). 500 GiB, 500 webhooks | **The only SKU with a private endpoint**, zone redundancy, geo-replication, content trust. |
| Registry left empty (auto) | Premium with private networking, Basic without | |
| NAT gateway's public IP (Standard) | ~$4/month ($0.005/h) | Part of `use_private_networking`. |
| NAT gateway, private endpoints, private DNS zones, storage, bandwidth | per hour and per GB; not priced here - see the pricing calculator | `use_private_networking = false` removes them (and the state account then has a public endpoint, Entra sign-in only). |
| Without self-hosted agents | the state storage account only: cents | Microsoft-hosted agents, no private network at all. |

A **Basic or Standard registry with private networking** keeps the registry's endpoint public (Entra
sign-in required, admin user off) and reached through the NAT gateway, while the state storage account
stays private: it saves about $45/month and is the sensible lab setting.

## The saved plan in the CD artifact - options

`terraform show -json` and a saved `tfplan` carry sensitive values in clear text; only the text plan
(`terraform show`) is redacted. The apply stage needs the exact plan, so today it travels as the `module`
artifact. From weakest to strongest:

1. **Narrow access and short retention** (what the kit does today): only the people who run and approve
   the pipelines can read runs of this project; keep run and artifact retention short (Project settings >
   Pipelines > Settings).
2. **Keep secrets out of the plan.** Prefer Key Vault references and managed identities to passing a
   secret through a Terraform variable or a resource argument, so the plan has nothing worth stealing.
3. **Re-plan in the apply stage instead of handing the plan over.** The plan stage publishes only the
   redacted text plan (already a card and an artifact); after approval the apply stage re-runs
   `terraform plan`, compares its redacted text with the approved one, **stops if they differ** (drift
   or a new commit since approval), and otherwise applies that fresh plan. No clear-text plan file is
   ever published, and a run applies exactly what was shown. Cost: one more plan (a minute or two) and a
   run that fails when something changed between approval and apply - which is arguably the point.
4. **Encrypt the plan file in the plan job** with a one-off key kept in a secret pipeline variable or
   Key Vault, and decrypt it only in the apply job. More moving parts than option 3 for the same effect.

Option 3 is the one to add; it is not in this version because it changes the pipeline's behaviour and
should be proven in the lab pipeline first.

## Proving a change to this kit

```pwsh
.\tests\Run-Tests.ps1
```

Stages the kit in a scratch folder and runs, with no credentials and nothing created anywhere: `terraform fmt
-check`, `init`, `validate`, and `terraform test` against mock providers (`tests\bootstrap.tftest.hcl`); the
syntax of every script; and four PowerShell tests - the plan summary renderer and the state-lock decision
(both lifted out of the pipeline YAML verbatim, so the thing tested is the thing that ships), the YAML and
template-parameter contract, and the question script (answers in, tfvars out, validated by Terraform
itself, including a stdin-driven interactive run). Exits 0 only if all pass.

## Tags

Every Azure resource the bootstrap creates that takes tags carries the same set (resource groups,
storage account, identities, registry and its build task, container instances, network, NAT gateway, IP,
private endpoints, private DNS zones). Azure resources do not inherit tags from a resource group, so each
one is tagged itself; Azure DevOps objects have no tags. The same tags go into the new repository's
`terraform.tfvars`, for the project's own Terraform to pass on as `tags = local.tags`.

- **The organization's standard** lives in [tag-defaults.psd1](tag-defaults.psd1): which tags are required
  and what each defaults to. The script asks for each required tag - `organizationName`, `environment`,
  `managedBy`, `appContact` as shipped - with the default shown, then for **additional tags**
  (`key=value,key=value`). Change the file once and every project follows; a project can change any value
  when asked, or in its answers file (`tags = @{ ... }`), and may add tags but not drop a required one.
  `-TagDefaultsFile` points at another standard.
- **Defaults** may use `{environment_name}`, `{azure_devops_organization}`, `{project_name}` and
  `{azure_devops_user_email}` - the sign-in address of whoever runs the script: the owner of the
  Azure DevOps token in `TF_VAR_azure_devops_personal_access_token` (or `AZDO_PERSONAL_ACCESS_TOKEN`) when
  it is already set (asked of Azure DevOps's `connectionData`; not yet proven against a real organization),
  otherwise the account signed in to the Azure CLI. `{token|text}` takes `text` when there is no value.
- **`repository` is automatic**: `dev.azure.com/<organization>/<project>/<main repository>` - where the
  project is bootstrapped (a space in the project name is `%20`). It is added by Terraform, so it is always
  true even if the file is edited, and shown in a comment in `bootstrap.tfvars`. Put a `repository` line in
  `tags` to use another value.
- **At most 15 tags**, the automatic `repository` tag included. Azure's general limit is 50, but Azure
  Private DNS zones - two of which the bootstrap creates - take no more than 15 (Learn: *Use tags to
  organize your Azure resources*). Checked in the script (and asked again when interactive), in the variable
  validation, and at plan time.
- **Names** start with a letter and hold letters, digits, `_` and `-`, at most 128 characters (the storage
  account's limit; Azure DNS zones accept no spaces, parentheses or special characters). **Values** are at
  most 256 characters. Tags are plain text: never a secret.

## Layout

| Path | What it is |
| --- | --- |
| `New-ProjectBootstrap.ps1` | The questions, the tfvars, and the terraform run. |
| `Test-ProjectBootstrap.ps1` | Read-only verification: PASS / FAIL / OFF BY DECISION / BLOCKED per check. |
| `Restore-ProjectBootstrap.ps1` | On a new laptop, inside a clone of the `bootstrap` branch: decrypts the stored state. |
| `lib/BootstrapBackup.ps1` | Encryption of the state and the push to the `bootstrap` branch (used by both scripts). |
| `answers.example.psd1` | Every answer in one file. |
| `tag-defaults.psd1` | The organization's tag standard: required tags and their defaults. |
| `terraform/` | The bootstrap itself: `azure.tf`, `azure_agents.tf`, `devops.tf`, `naming.tf`, `locals.tf`, `variables.tf`, `outputs.tf`. |
| `content/main-repo/` | What the main repository starts with (`*.tftpl` are rendered with your answers). |
| `content/templates-repo/` | The pipeline templates repository, committed as it is. |
| `tests/` | The tests above and their mocks. |

## Licence, support and responsibility

MIT - see [LICENSE](LICENSE). The design is modelled on the Azure Landing Zones accelerator's bootstrap and
pipeline templates (both MIT-licensed, github.com/Azure), without Azure Landing Zones in it. This is a
community kit, not a Microsoft product, and comes with no support or warranty. It creates identities,
role assignments, networks and pipelines: **read the plan before you type pply**, try it first in a lab
subscription, and check the cost estimate it prints. Never put a token, a password or a state file in an
issue or a pull request.
