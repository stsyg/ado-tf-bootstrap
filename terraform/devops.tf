locals {
  project_id = var.azure_devops_create_project ? azuredevops_project.main[0].id : data.azuredevops_project.main[0].id

  environments = {
    (local.plan_key)  = local.names.environment_plan
    (local.apply_key) = local.names.environment_apply
  }

  service_connections = {
    (local.plan_key)  = local.names.service_connection_plan
    (local.apply_key) = local.names.service_connection_apply
  }

  # Which environments and service connections each pipeline may use. A pipeline is refused any
  # resource it is not authorised for, so this is also the list of what a pipeline can reach.
  pipelines = {
    ci = {
      name        = local.ci_pipeline_name
      file        = local.ci_pipeline_file
      keys        = [local.plan_key]
      description = "Validates a change to the infrastructure code: format, validate and a plan, with the plan summarised in the run."
    }
    cd = {
      name        = local.cd_pipeline_name
      file        = local.cd_pipeline_file
      keys        = [local.plan_key, local.apply_key]
      description = "Plans, and after approval applies, the infrastructure code on main. An apply is skipped when the plan has no changes."
    }
  }

  pipeline_resources = {
    for pair in flatten([
      for pipeline_key, pipeline in local.pipelines : [
        for resource_key in pipeline.keys : {
          key          = "${pipeline_key}-${resource_key}"
          pipeline_key = pipeline_key
          resource_key = resource_key
        }
      ]
    ]) : pair.key => pair
  }

  approver_descriptors = toset(flatten([for approver in data.azuredevops_users.approvers : [for user in approver.users : user.descriptor]]))

  # One named person approves their own change (there is nobody else); a group is taken to hold
  # several, so it turns the reviewer rule on - a pull request then needs someone other than its pusher.
  has_approvers     = length(var.approvers) + length(var.approver_entra_group_ids) > 0
  several_approvers = length(var.approvers) > 1 || length(var.approver_entra_group_ids) > 0
}

# ---------------------------------------------------------------- project

resource "azuredevops_project" "main" {
  count              = var.azure_devops_create_project ? 1 : 0
  name               = var.azure_devops_project_name
  visibility         = "private"
  version_control    = "Git"
  work_item_template = "Agile"
  description        = "Infrastructure as code for ${var.project_name}: pipelines, repositories and the connections to Azure. Created by project-bootstrap."
}

data "azuredevops_project" "main" {
  count = var.azure_devops_create_project ? 0 : 1
  name  = var.azure_devops_project_name
}

# ---------------------------------------------------------------- agent pool

resource "azuredevops_agent_pool" "agents" {
  count          = var.use_self_hosted_agents ? 1 : 0
  name           = local.names.agent_pool
  auto_provision = false
  auto_update    = true
}

resource "azuredevops_agent_queue" "agents" {
  count         = var.use_self_hosted_agents ? 1 : 0
  project_id    = local.project_id
  agent_pool_id = azuredevops_agent_pool.agents[0].id
}

# ---------------------------------------------------------------- environments, variable group

resource "azuredevops_environment" "pipeline" {
  for_each   = local.environments
  name       = each.value
  project_id = local.project_id
}

# What every pipeline run reads to find the state: the names, not secrets.
resource "azuredevops_variable_group" "backend" {
  project_id   = local.project_id
  name         = local.names.variable_group
  description  = "Terraform backend of ${var.project_name}. Managed by project-bootstrap."
  allow_access = true

  variable {
    name  = "BACKEND_AZURE_RESOURCE_GROUP_NAME"
    value = azurerm_resource_group.state.name
  }

  variable {
    name  = "BACKEND_AZURE_STORAGE_ACCOUNT_NAME"
    value = azurerm_storage_account.state.name
  }

  variable {
    name  = "BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME"
    value = azapi_resource.state_container.name
  }
}

# ---------------------------------------------------------------- approvers

resource "azuredevops_group" "approvers" {
  scope        = local.project_id
  display_name = local.names.approvers_group
  description  = "Approves a Terraform apply for ${var.project_name}."
}

data "azuredevops_users" "approvers" {
  for_each       = toset(var.approvers)
  principal_name = each.key

  lifecycle {
    postcondition {
      condition     = length(self.users) > 0
      error_message = "No Azure DevOps user found for ${each.key}. Check the sign-in address, and that the person has been added to the organization."
    }
  }
}

resource "azuredevops_group_membership" "approvers" {
  group   = azuredevops_group.approvers.descriptor
  members = setunion(local.approver_descriptors, [for group in azuredevops_group.approver_entra : group.descriptor])
}

# Microsoft Entra security groups (a team's group, the "DL" of the people who may approve) added to the
# approvers group by their object ID. Membership is then kept in Entra, not here.
resource "azuredevops_group" "approver_entra" {
  for_each  = toset(var.approver_entra_group_ids)
  origin_id = each.key
}

# ---------------------------------------------------------------- service connections and their checks

resource "azuredevops_serviceendpoint_azurerm" "pipeline" {
  for_each                               = local.service_connections
  project_id                             = local.project_id
  service_endpoint_name                  = each.value
  description                            = "Managed by project-bootstrap. Signs in as ${azurerm_user_assigned_identity.pipeline[each.key].name} by workload identity federation: no secret."
  service_endpoint_authentication_scheme = "WorkloadIdentityFederation"
  azurerm_spn_tenantid                   = data.azurerm_client_config.current.tenant_id
  azurerm_subscription_id                = var.bootstrap_subscription_id
  azurerm_subscription_name              = data.azurerm_subscription.bootstrap.display_name

  credentials {
    serviceprincipalid = azurerm_user_assigned_identity.pipeline[each.key].client_id
  }
}

# Nothing applies without a named person saying so.
resource "azuredevops_check_approval" "apply" {
  count                = local.has_approvers ? 1 : 0
  project_id           = local.project_id
  target_resource_id   = azuredevops_serviceendpoint_azurerm.pipeline[local.apply_key].id
  target_resource_type = "endpoint"

  requester_can_approve = !local.several_approvers
  approvers             = [azuredevops_group.approvers.origin_id]
  timeout               = 43200

  depends_on = [azuredevops_group_membership.approvers]
}

# One run at a time per connection, so two runs never plan or apply against the same state at once.
resource "azuredevops_check_exclusive_lock" "pipeline" {
  for_each             = local.service_connections
  project_id           = local.project_id
  target_resource_id   = azuredevops_serviceendpoint_azurerm.pipeline[each.key].id
  target_resource_type = "endpoint"
  timeout              = 43200
}

# A pipeline may use a connection only when it extends a template from the templates repository's
# main branch: editing a pipeline's own YAML cannot bypass the plan summary, the lock handling or
# the skipped apply. The plan connection serves CI and CD; the apply connection serves CD only.
resource "azuredevops_check_required_template" "pipeline" {
  for_each             = local.service_connections
  project_id           = local.project_id
  target_resource_id   = azuredevops_serviceendpoint_azurerm.pipeline[each.key].id
  target_resource_type = "endpoint"

  dynamic "required_template" {
    for_each = each.key == local.apply_key ? [local.cd_template_path] : [local.ci_template_path, local.cd_template_path]
    content {
      repository_type = "azuregit"
      repository_name = "${var.azure_devops_project_name}/${local.templates_repository_name}"
      repository_ref  = local.default_branch
      template_path   = required_template.value
    }
  }

  depends_on = [azuredevops_git_repository_file.templates]
}

# The apply connection is usable only from main, and (with branch policies on) only while main is
# protected. Without this, a person who may queue the CD pipeline could pick another branch in the
# run dialog and apply code nobody reviewed - the pipeline's trigger limits automatic runs only.
resource "azuredevops_check_branch_control" "apply" {
  project_id               = local.project_id
  display_name             = "Apply only from main"
  target_resource_id       = azuredevops_serviceendpoint_azurerm.pipeline[local.apply_key].id
  target_resource_type     = "endpoint"
  allowed_branches         = local.default_branch
  verify_branch_protection = var.create_branch_policies
  timeout                  = 1440

  depends_on = [azuredevops_branch_policy_merge_types.main]
}

# ---------------------------------------------------------------- repositories

resource "azuredevops_git_repository" "main" {
  project_id     = local.project_id
  name           = var.repository_name
  default_branch = local.default_branch

  initialization {
    init_type = "Clean"
  }

  depends_on = [azuredevops_environment.pipeline]
}

resource "azuredevops_git_repository" "templates" {
  project_id     = local.project_id
  name           = local.templates_repository_name
  default_branch = local.default_branch

  initialization {
    init_type = "Clean"
  }
}

# The starting content goes straight to main with [skip ci], before the branch policies exist.
# overwrite_on_create means a re-run puts a changed starter file back only when the file is new to
# Terraform; once a file is in the state, edits made through pull requests are left alone.
resource "azuredevops_git_repository_file" "main" {
  for_each            = local.main_repository_files
  repository_id       = azuredevops_git_repository.main.id
  file                = each.key
  content             = each.value
  branch              = local.default_branch
  commit_message      = "Add ${each.key} [skip ci]"
  overwrite_on_create = true

  lifecycle {
    ignore_changes = [content, commit_message]
  }
}

resource "azuredevops_git_repository_file" "templates" {
  for_each            = local.templates_repository_files
  repository_id       = azuredevops_git_repository.templates.id
  file                = each.key
  content             = each.value
  branch              = local.default_branch
  commit_message      = "Add ${each.key} [skip ci]"
  overwrite_on_create = true

  lifecycle {
    ignore_changes = [content, commit_message]
  }
}

# ---------------------------------------------------------------- branch policies

locals {
  protected_repositories = {
    main      = azuredevops_git_repository.main
    templates = azuredevops_git_repository.templates
  }
}

resource "azuredevops_branch_policy_min_reviewers" "main" {
  for_each   = local.protected_repositories
  project_id = local.project_id
  # With a single approver there is nobody else to review, so the rule would lock that person out.
  enabled  = var.create_branch_policies && local.several_approvers
  blocking = true

  settings {
    reviewer_count                         = 1
    submitter_can_vote                     = false
    last_pusher_cannot_approve             = true
    allow_completion_with_rejects_or_waits = false
    on_push_reset_approved_votes           = true

    scope {
      repository_id  = each.value.id
      repository_ref = local.default_branch
      match_type     = "Exact"
    }
  }

  depends_on = [azuredevops_git_repository_file.main, azuredevops_git_repository_file.templates]
}

resource "azuredevops_branch_policy_merge_types" "main" {
  for_each   = local.protected_repositories
  project_id = local.project_id
  enabled    = var.create_branch_policies
  blocking   = true

  settings {
    allow_squash                  = true
    allow_rebase_and_fast_forward = false
    allow_basic_no_fast_forward   = false
    allow_rebase_with_merge       = false

    scope {
      repository_id  = each.value.id
      repository_ref = local.default_branch
      match_type     = "Exact"
    }
  }

  depends_on = [azuredevops_git_repository_file.main, azuredevops_git_repository_file.templates]
}

# A pull request into main cannot complete until the CI pipeline has passed on its latest commit.
resource "azuredevops_branch_policy_build_validation" "ci" {
  project_id = local.project_id
  enabled    = var.create_branch_policies
  blocking   = true

  settings {
    display_name        = "Terraform validation and plan"
    build_definition_id = azuredevops_build_definition.pipeline["ci"].id
    valid_duration      = 720

    scope {
      repository_id  = azuredevops_git_repository.main.id
      repository_ref = local.default_branch
      match_type     = "Exact"
    }
  }

  depends_on = [azuredevops_git_repository_file.main]
}

# ---------------------------------------------------------------- pipelines

resource "azuredevops_build_definition" "pipeline" {
  for_each   = local.pipelines
  project_id = local.project_id
  name       = each.value.name
  path       = "\\"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = azuredevops_git_repository.main.id
    branch_name = local.default_branch
    yml_path    = azuredevops_git_repository_file.main[each.value.file].file
  }

  depends_on = [azuredevops_git_repository_file.templates]
}

# A pipeline is refused an environment, a connection or a pool until it is authorised for it.
resource "azuredevops_pipeline_authorization" "environment" {
  for_each    = local.pipeline_resources
  project_id  = local.project_id
  resource_id = azuredevops_environment.pipeline[each.value.resource_key].id
  type        = "environment"
  pipeline_id = azuredevops_build_definition.pipeline[each.value.pipeline_key].id
}

resource "azuredevops_pipeline_authorization" "service_connection" {
  for_each    = local.pipeline_resources
  project_id  = local.project_id
  resource_id = azuredevops_serviceendpoint_azurerm.pipeline[each.value.resource_key].id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.pipeline[each.value.pipeline_key].id
}

resource "azuredevops_pipeline_authorization" "agent_pool" {
  for_each    = var.use_self_hosted_agents ? local.pipelines : {}
  project_id  = local.project_id
  resource_id = azuredevops_agent_queue.agents[0].id
  type        = "queue"
  pipeline_id = azuredevops_build_definition.pipeline[each.key].id
}

# The templates repository is a resource of the pipelines (resources.repositories). Where the
# organization protects access to repositories in YAML pipelines, a pipeline stops at the first run
# until someone permits it; this permits it up front.
resource "azuredevops_pipeline_authorization" "templates_repository" {
  for_each   = local.pipelines
  project_id = local.project_id
  # The provider adds the project ID itself for a repository (<project>.<repository>).
  resource_id = azuredevops_git_repository.templates.id
  type        = "repository"
  pipeline_id = azuredevops_build_definition.pipeline[each.key].id
}
