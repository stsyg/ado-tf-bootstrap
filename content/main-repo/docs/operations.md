# Operations

## Stop a bad apply

An apply is held for approval on the **apply** service connection. Reject the approval and the run
ends; nothing changed. Once an apply has started, cancelling it can leave the state locked - see
"A run left the state locked".

## A run left the state locked

Only an apply takes the state lock by default (plans read the state without locking), so only an
interrupted apply can leave one behind - and the pipeline will not release it for you: an interrupted
apply may have left the state incomplete. Read the failed run's log first. If the state is sound, run
`terraform force-unlock <lock id>` with the ID in the error, signed in as someone who may write the
state. If the bootstrap was run with `plan_can_write_state = true`, plans take the lock too, and the
pipeline releases a stale *plan* lock by itself; for an apply lock it stops and names the lock: add the
variable `STATE_LOCK_RELEASE_ID` to the project's variable group with that ID, run the pipeline once,
and **delete the variable again**. Details: the templates repository's README, "State lock".

## Recover an earlier state

The state blob is versioned and soft-deleted (unless the bootstrap was run with those turned off).
In the Azure portal open the storage account, the `tfstate` container, the blob, **Versions**, and
promote the version you want. Do it while no pipeline is running.

## Change who approves

Re-run the bootstrap with the new list of `approvers` (sign-in addresses) and/or `approver_entra_group_ids`
(object IDs of Entra **security** groups: add the group once, then manage who is in it in Entra, with no
re-run). The group's membership is managed by the bootstrap, so a member added by hand in Azure DevOps
is removed again by its next run. The approval check on the apply service connection names the
group, so membership is all that has to change.

## Manage another Azure scope

The plan and apply identities hold their roles only on the scopes the bootstrap was given. To manage
another subscription or management group, re-run the bootstrap with it added to the target scopes,
then add a provider alias for it in `providers.tf`. Do not hand-assign roles to the identities: the
next bootstrap run would not know about them.

## Rotate the agent token

The self-hosted agents register with a personal access token that is stored in the bootstrap's own
state. Create a new token (scope **Agent Pools: Read & manage**) and re-run the bootstrap with it;
the container instances are replaced and register again.

## Change the Terraform or provider version

Pipelines run the Terraform CLI version set as the default in `ci.yaml` and `cd.yaml`
(`terraform_cli_version`), and a run can override it when queued. Provider versions are in
`terraform.tf`; commit the matching `.terraform.lock.hcl`.
