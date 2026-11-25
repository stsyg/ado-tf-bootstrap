# Pipeline templates

The shared Terraform pipeline logic for the project's infrastructure repository. A pipeline there
does not contain steps of its own: it `extends` one of the two templates here. The service
connections that sign in to Azure carry a **required template** check naming these files, so a
pipeline that does not extend them cannot reach Azure at all, and changing a pipeline's own YAML
cannot skip the plan summary, the state-lock handling or the approval.

| File | Used by | What it does |
| --- | --- | --- |
| `.pipelines/ci-template.yaml` | `01 ... Continuous Integration` | Format check, `init`, `validate`, then a **plan** against the real state with the read-only plan identity. Runs on every pull request into `main` and blocks the merge when it fails. |
| `.pipelines/cd-template.yaml` | `02 ... Continuous Delivery` | On `main`: plan, then - **only if the plan has changes**, and after the approval check on the apply service connection - apply **that same plan file** with the apply identity. |
| `.pipelines/helpers/terraform-installer.yaml` | both | Installs the requested Terraform CLI version (`latest` or a version number). |
| `.pipelines/helpers/terraform-init.yaml` | both | Signs in through the service connection (workload identity federation, no secret) and initialises the `azurerm` backend with `use_azuread_auth`. |
| `.pipelines/helpers/terraform-plan.yaml` | both | The state-lock check, then `terraform plan -detailed-exitcode`; sets `planHasChanges`. |
| `.pipelines/helpers/terraform-plan-summary.yaml` | both | Renders the plan as a card on the run's **Extensions** tab and publishes the redacted plan. |
| `.pipelines/helpers/terraform-apply.yaml` | CD | `terraform apply` of the saved plan file. |

## What a run does that a plain `terraform` pipeline does not

- **No apply without changes.** The CD apply stage's condition reads `planHasChanges`. An empty plan
  never asks an approver for anything. Anything other than a clean "no changes" counts as changes, so
  an exit code nobody foresaw can never skip an apply.
- **The plan is a card, not a log.** The run's summary shows the counts (add / change / replace /
  destroy), leads with replacements and destroys, lists output-only changes (which still make an
  apply necessary), lists objects changed outside Terraform, the files in the change, and the full
  redacted plan. It reads only addresses, types and actions from the plan JSON - never a value - and
  deletes the JSON before the job ends.
- **The plan that was approved is the plan that is applied.** The plan stage publishes the module and
  its `tfplan`; the apply stage downloads them instead of checking `main` out again. The saved plan
  can hold sensitive values in clear text: keep read access to the project's pipelines narrow.
- **State locks are handled, carefully.** See below.
- **Applies queue.** The apply stage uses `lockBehavior: sequential` and the service connections have
  an exclusive-lock check, so two runs never apply at once and a waiting run is queued, not cancelled.

## Parameters

Both templates take the names the bootstrap created; none has a default, so a missing name fails the
run at once. `ci.yaml` and `cd.yaml` in the main repository pass them.

| Parameter | Templates | Meaning |
| --- | --- | --- |
| `variable_group_name` | both | The variable group holding `BACKEND_AZURE_RESOURCE_GROUP_NAME`, `BACKEND_AZURE_STORAGE_ACCOUNT_NAME`, `BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME`. |
| `plan_environment_name`, `apply_environment_name` | both / CD | Pipeline environments of the plan and apply stages. |
| `plan_service_connection_name`, `apply_service_connection_name` | both / CD | Service connections of the plan and apply identities. |
| `agent_pool_name` | both | Self-hosted pool; empty runs on a Microsoft-hosted `ubuntu-latest` agent. |
| `root_module_folder_relative_path` | both | Folder with the root module; `.` by default. |
| `terraform_cli_version` | both | `latest` or a version such as `1.14.9`. |
| `state_file_name` | both | State blob name; `terraform.tfstate` by default. Use another name for a second root module in the same container. |
| `state_lock_timeout` | both | How long plan and apply wait for a lock held by another run; `30m`. |
| `plan_takes_state_lock` | both | `false` (default): the plan identity only reads the state, so plan runs with `-lock=false` and the lock check below is skipped. `true`: the plan identity may write the state, plan takes the lock, and the check runs first. The pipelines the bootstrap writes pass the value it was given. Apply always locks. |
| `terraform_action` | CD | `apply` or `destroy`. |
| `security_scan` | CI | Checkov through the *Microsoft Security DevOps* extension (must be installed in the organization). Warn only. Off by default. |

## State lock

Terraform locks the state by leasing its blob. A run that is cancelled, or loses its agent, can leave
the lease behind and every later run then waits for it. Before each plan - **when plans take the lock
(`plan_takes_state_lock: true`)** - the pipeline looks at the lease and decides. With the default, plans
read the state without locking, so only an interrupted *apply* can leave a lock, and the pipeline never
releases one: follow the last row below by hand (`terraform force-unlock <lock id>`, after reading the
failed run's log).

| Situation | Decision |
| --- | --- |
| Not locked | Carry on. |
| Locked, and another run of this repository is in progress (or that cannot be read) | Wait for it (`-lock-timeout`). |
| Locked, nothing else is running, and the lock is a **plan** lock | Release it. A plan writes no state, so this is safe. |
| Locked, nothing else is running, and the lock is an **apply** lock | **Stop with an error.** An interrupted apply may have left the state incomplete; a person must look at the last run's log first. |
| Leased with no Terraform lock record | **Stop with an error.** |

To release a lock the pipeline would not: read the failed run's log, then add the variable
`STATE_LOCK_RELEASE_ID` to the project's variable group with the lock ID the error message names (or
`break-lease` for a lease with no record), run the pipeline once, and **delete the variable again**.

## Changing a template

Both repositories' `main` branches are protected: a change is a pull request, squash-merged. The
service connections' required-template check points at `main` of this repository, so a change takes
effect for the next run of every pipeline as soon as it merges - treat it like a change to the
pipeline of every project that uses it. The renderer in `terraform-plan-summary.yaml` and the lock
decision in `terraform-plan.yaml` sit between `>>> ... BEGIN` / `<<< ... END` markers so they can be
lifted out and tested; keep the markers.
