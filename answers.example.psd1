# Answers for New-ProjectBootstrap.ps1 -AnswersFile .\answers.psd1 [-NonInteractive]
# Keys are the variable names in terraform\variables.tf. Anything left out is asked (or, with
# -NonInteractive, takes its default). No secrets here: the two Azure DevOps tokens come from
# TF_VAR_azure_devops_personal_access_token and TF_VAR_azure_devops_agent_pat.
@{
  # The project
  project_name     = 'payments'
  environment_name = 'prd'
  azure_location   = 'canadacentral'
  location_short   = 'cac'
  instance_number  = '001'
  # Required by tag-defaults.psd1: organizationName, environment, managedBy, appContact. Add what you like,
  # up to 15 tags in all. The 'repository' tag (dev.azure.com/<org>/<project>/<repository>) is added for you.
  tags = @{
    organizationName = 'Contoso'
    environment      = 'prd'
    managedBy        = 'Terraform'
    appContact       = 'platform-team@contoso.com'
    costCentre       = '1234'
  }

  # Azure
  bootstrap_subscription_id        = '00000000-0000-0000-0000-000000000000'
  target_subscription_ids          = @('00000000-0000-0000-0000-000000000000')
  target_management_group_ids      = @()
  plan_role_definition_name        = 'Reader'
  apply_role_definition_name       = 'Contributor'
  plan_can_write_state             = $false
  storage_account_replication_type = 'ZRS'

  # Azure DevOps
  azure_devops_organization_url = 'https://dev.azure.com/contoso'
  azure_devops_project_name     = 'Payments Platform'
  azure_devops_create_project   = $true
  repository_name               = 'payments-infra'
  templates_repository_name     = 'payments-infra-templates'
  pipeline_display_name         = 'Payments Infra'
  approvers                     = @('first.approver@contoso.com', 'second.approver@contoso.com')
  # Or, instead of (or as well as) named people, Entra SECURITY groups by object ID:
  # approver_entra_group_ids    = @('00000000-0000-0000-0000-000000000000')
  # Lab: one approver is enough - approvers = @('me@contoso.com')
  create_branch_policies        = $true
  terraform_cli_version         = 'latest'

  # Self-hosted agents, their network and what they cost
  use_self_hosted_agents                    = $true
  use_private_networking                    = $true
  container_registry_sku                    = ''     # '' = Premium with private networking, Basic without; or 'Basic' | 'Standard' | 'Premium'
  use_nat_gateway                           = $true  # $false where policy denies public IPs - then set agent_route_table_id
  agent_route_table_id                      = ''     # e.g. /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Network/routeTables/<name>
  agent_container_instance_count            = 2      # ~$80/month each at 2 vCPU / 4 GB
  agent_container_cpu                       = 2
  agent_container_memory                    = 4
  virtual_network_address_space             = '10.0.0.0/24'
  subnet_address_prefix_container_instances = '10.0.0.0/26'
  subnet_address_prefix_private_endpoints   = '10.0.0.64/28'

  # Anything else in variables.tf can be set here too, for example:
  # agent_container_image_tag        = '57a937f'
  # storage_account_blob_soft_delete_retention_days = 14
  # names = @{ storage_account = 'stpaymentsprd0001' }
}
