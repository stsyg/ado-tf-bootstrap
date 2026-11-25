# Every value here is written to bootstrap.tfvars by New-ProjectBootstrap.ps1 from the answers to
# its questions, except the two tokens, which only ever travel in TF_VAR_* environment variables.

# ---------------------------------------------------------------- the project

variable "project_name" {
  description = "Short name of the project: lowercase letters, digits and hyphens, 2-12 characters, starting with a letter. It is part of every Azure name and of the storage account and registry names, whose limits are the tightest."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.project_name)) && !can(regex("--|-$", var.project_name))
    error_message = "project_name must be 2-12 characters: lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "environment_name" {
  description = "Short environment code in the names, for example prd, tst or lab: 1-4 lowercase letters or digits."
  type        = string
  default     = "prd"

  validation {
    condition     = can(regex("^[a-z0-9]{1,4}$", var.environment_name))
    error_message = "environment_name must be 1-4 lowercase letters or digits."
  }
}

variable "azure_location" {
  description = "Azure region of every resource the bootstrap creates, for example canadacentral."
  type        = string
}

variable "location_short" {
  description = "Short region code in the names, for example cac for canadacentral: 2-5 lowercase letters or digits."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,5}$", var.location_short))
    error_message = "location_short must be 2-5 lowercase letters or digits."
  }
}

variable "instance_number" {
  description = "Three-digit instance number at the end of the names, so a second copy of the same project can sit beside the first."
  type        = string
  default     = "001"

  validation {
    condition     = can(regex("^[0-9]{3}$", var.instance_number))
    error_message = "instance_number must be three digits, for example 001."
  }
}

variable "tags" {
  description = <<-EOT
    Tags put on every Azure resource the bootstrap creates (and handed to the project's own Terraform in
    its terraform.tfvars). A 'repository' tag - dev.azure.com/<organization>/<project>/<repository> of the
    main repository - is added automatically unless a tag of that name is given here. Limits (Learn: Use
    tags to organize your Azure resources): at most 15 tags in all, because Azure Private DNS zones - which
    this creates - take no more than 15 (other resources take 50); a name is at most 128 characters (the
    storage account's limit; 512 elsewhere), starts with a letter and holds only letters, digits, '_' and
    '-' (Azure DNS zones accept no spaces, parentheses or special characters in a name; no name may contain
    < > % & \ ? /); a value is at most 256 characters. Tags are plain text: never put a secret in one.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for name, value in var.tags : can(regex("^[A-Za-z][A-Za-z0-9_-]{0,127}$", name))])
    error_message = "A tag name must start with a letter and hold only letters, digits, '_' and '-', at most 128 characters."
  }

  validation {
    condition     = alltrue([for name, value in var.tags : length(value) <= 256])
    error_message = "A tag value is at most 256 characters."
  }

  validation {
    condition     = length(var.tags) <= 15
    error_message = "At most 15 tags (Azure Private DNS zones take no more than 15). The automatic 'repository' tag counts: with 15 given, one must be the repository tag itself."
  }
}

variable "required_tag_names" {
  description = "Tags every project must carry, with a non-empty value, before anything is created. The organization's standard; a project may add tags but not drop these."
  type        = list(string)
  default     = ["organizationName", "environment", "managedBy", "appContact"]
}

# ---------------------------------------------------------------- Azure

variable "bootstrap_subscription_id" {
  description = "Subscription that holds everything the bootstrap creates, and the one the plan and apply service connections are created for."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.bootstrap_subscription_id))
    error_message = "bootstrap_subscription_id must be a subscription GUID."
  }
}

variable "target_subscription_ids" {
  description = "Subscriptions the project's Terraform manages. The plan and apply identities get their roles on each. Empty means the bootstrap subscription only."
  type        = list(string)
  default     = []
}

variable "target_management_group_ids" {
  description = "Management group IDs the project's Terraform manages, in addition to the subscriptions. The identities get their roles on each."
  type        = list(string)
  default     = []
}

variable "plan_role_definition_name" {
  description = "Built-in Azure role the plan identity holds on every target. Read-only on purpose: a plan only reads."
  type        = string
  default     = "Reader"
}

variable "apply_role_definition_name" {
  description = "Built-in Azure role the apply identity holds on every target. Contributor cannot create role assignments; use Owner, or Contributor plus Role Based Access Control Administrator, when the project's Terraform assigns roles."
  type        = string
  default     = "Contributor"
}

variable "plan_can_write_state" {
  description = "false (default): the plan identity has Storage Blob Data Reader on the state container, and the pipelines plan with -lock=false. A pull request's Terraform runs as that identity, so it can then read the state but never overwrite or delete it. true: Storage Blob Data Contributor, so a plan takes the state's lock like an apply does (and a stale plan lock is released by the pipeline) - at the price that a pull request's plan code can write the state."
  type        = bool
  default     = false
}

variable "resource_providers" {
  description = "Resource providers registered in the bootstrap subscription before the resources that need them. Registering one that is already registered changes nothing."
  type        = list(string)
  default = [
    "Microsoft.ContainerInstance",
    "Microsoft.ContainerRegistry",
    "Microsoft.ManagedIdentity",
    "Microsoft.Network",
    "Microsoft.Storage",
  ]
}

variable "storage_account_replication_type" {
  description = "Replication of the Terraform state storage account. ZRS needs a region with availability zones; use LRS where there are none."
  type        = string
  default     = "ZRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.storage_account_replication_type)
    error_message = "storage_account_replication_type must be LRS, ZRS, GRS, RAGRS, GZRS or RAGZRS."
  }
}

variable "storage_account_blob_soft_delete_retention_days" {
  description = "Days a deleted state blob can be recovered. 0 turns blob soft delete off."
  type        = number
  default     = 7

  validation {
    condition     = var.storage_account_blob_soft_delete_retention_days >= 0 && var.storage_account_blob_soft_delete_retention_days <= 365
    error_message = "storage_account_blob_soft_delete_retention_days must be 0-365."
  }
}

variable "storage_account_container_soft_delete_retention_days" {
  description = "Days a deleted state container can be recovered. 0 turns container soft delete off."
  type        = number
  default     = 7

  validation {
    condition     = var.storage_account_container_soft_delete_retention_days >= 0 && var.storage_account_container_soft_delete_retention_days <= 365
    error_message = "storage_account_container_soft_delete_retention_days must be 0-365."
  }
}

variable "storage_account_blob_versioning_enabled" {
  description = "Keep every version of the state blob, so a bad state can be rolled back."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- self-hosted agents and networking

variable "use_self_hosted_agents" {
  description = "Run the pipelines on agents in Azure Container Instances (with a registry that builds their image) instead of Microsoft-hosted agents."
  type        = bool
  default     = true
}

variable "use_private_networking" {
  description = "Put the agents in a virtual network and reach the state storage account and the registry through private endpoints. Only has an effect with use_self_hosted_agents."
  type        = bool
  default     = true
}

variable "public_ip_deny_policy_assignment_id" {
  description = "Resource ID of the policy assignment that denies public IP addresses where this runs, for example /providers/Microsoft.Management/managementGroups/<group>/providers/Microsoft.Authorization/policyAssignments/Deny-Public-IP. When set (and use_nat_gateway is true) the bootstrap waives that one assignment on its own network resource group - nothing wider - so the NAT gateway's public IP can be created. Needs rights to write policy exemptions there. Empty: no exemption. Leave empty when an exemption for it already exists (one name can exist once)."
  type        = string
  default     = ""

  validation {
    condition     = var.public_ip_deny_policy_assignment_id == "" || can(regex("(?i)/providers/Microsoft\\.Authorization/policyAssignments/[^/]+$", var.public_ip_deny_policy_assignment_id))
    error_message = "public_ip_deny_policy_assignment_id must be a policy assignment resource ID (.../providers/Microsoft.Authorization/policyAssignments/<name>)."
  }
}

variable "policy_exemption_expires_on" {
  description = "When the exemption above expires, RFC 3339 (2027-05-24T00:00:00Z). An exemption with no end is forgotten; renew it or remove it before then. Required with public_ip_deny_policy_assignment_id."
  type        = string
  default     = ""

  validation {
    condition     = var.policy_exemption_expires_on == "" || can(formatdate("YYYY", var.policy_exemption_expires_on))
    error_message = "policy_exemption_expires_on must be an RFC 3339 timestamp such as 2027-05-24T00:00:00Z."
  }
}

variable "use_nat_gateway" {
  description = "Give the agents one fixed outbound address through a NAT gateway and a Standard public IP. false when policy denies public IP addresses (the creation fails with RequestDisallowedByPolicy): then agent_route_table_id must say how the agents reach the internet. Only used with private networking."
  type        = bool
  default     = true
}

variable "agent_route_table_id" {
  description = "Resource ID of an existing route table to attach to the agent subnet - for example one that sends 0.0.0.0/0 to a hub firewall. Must be in the bootstrap subscription and region (a route table attaches only to subnets of its own subscription and region). The virtual network then has to be peered to that hub by whoever runs it; this does not create the peering. Empty: none."
  type        = string
  default     = ""

  validation {
    condition     = var.agent_route_table_id == "" || can(regex("(?i)^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/routeTables/[^/]+$", var.agent_route_table_id))
    error_message = "agent_route_table_id must be a route table resource ID: /subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.Network/routeTables/<name>."
  }
}

variable "virtual_network_address_space" {
  description = "Address space of the virtual network. Must not overlap a network this one will be peered to."
  type        = string
  default     = "10.0.0.0/24"

  validation {
    condition     = can(cidrhost(var.virtual_network_address_space, 0))
    error_message = "virtual_network_address_space must be a CIDR range."
  }
}

variable "subnet_address_prefix_container_instances" {
  description = "Subnet of the agent container instances (delegated to Microsoft.ContainerInstance/containerGroups). Inside virtual_network_address_space."
  type        = string
  default     = "10.0.0.0/26"

  validation {
    condition     = can(cidrhost(var.subnet_address_prefix_container_instances, 0))
    error_message = "subnet_address_prefix_container_instances must be a CIDR range."
  }
}

variable "subnet_address_prefix_private_endpoints" {
  description = "Subnet of the private endpoints. Inside virtual_network_address_space, not overlapping the agent subnet."
  type        = string
  default     = "10.0.0.64/28"

  validation {
    condition     = can(cidrhost(var.subnet_address_prefix_private_endpoints, 0))
    error_message = "subnet_address_prefix_private_endpoints must be a CIDR range."
  }
}

variable "agent_container_instance_count" {
  description = "Number of agent container instances. Each runs one job at a time and is billed for every second it runs - about 2 vCPU x $0.0446/h + 4 GB x $0.00487/GB-h = $0.109/h = $80 a month each at the defaults (Canada Central, list price, 2026-11-19). 1 is enough for a lab; 2 lets a plan and an apply (or two pull requests) run side by side."
  type        = number
  default     = 2

  validation {
    condition     = var.agent_container_instance_count >= 1 && var.agent_container_instance_count <= 9
    error_message = "agent_container_instance_count must be 1-9."
  }
}

variable "agent_container_cpu" {
  description = "CPU cores of each agent container instance. Terraform is light: 1 is enough for a small project, 2 for a large plan. Billed per core-hour."
  type        = number
  default     = 2
}

variable "agent_container_memory" {
  description = "Memory, in GB, of each agent container instance. 2 is enough for a small project; large provider plans want 4 or more. Billed per GB-hour."
  type        = number
  default     = 4
}

variable "agent_container_zones" {
  description = "Availability zone of each agent instance, in order, for example [\"1\", \"2\"]. Empty for a region without zones or when zones are not wanted; instances beyond the list get no zone."
  type        = list(string)
  default     = []
}

variable "container_registry_sku" {
  description = <<-EOT
    SKU of the container registry that builds and serves the agent image. Empty (default) chooses by
    the network answer: Premium with private networking, Basic without. Differences (Learn: Azure
    Container Registry SKU features and limits): Basic - 10 GiB included, 2 webhooks, no private
    endpoint, cheapest, enough for one agent image. Standard - 100 GiB, 10 webhooks, no private
    endpoint. Premium - 500 GiB, 500 webhooks, private endpoints, geo-replication, zone redundancy,
    content trust. Only Premium can sit behind a private endpoint; with Basic or Standard in a private
    network the registry keeps a public endpoint (sign-in still required) and the agents reach it
    through the NAT gateway - the state storage account is still private.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "Basic", "Standard", "Premium"], var.container_registry_sku)
    error_message = "container_registry_sku must be empty, Basic, Standard or Premium."
  }
}

variable "container_registry_zone_redundancy_enabled" {
  description = "Zone redundancy of the container registry. Premium only, and needs a region with availability zones."
  type        = bool
  default     = false
}

variable "agent_container_image_repository" {
  description = "Git repository whose Dockerfile builds the agent image. The default is the Azure Verified Modules agent image."
  type        = string
  default     = "https://github.com/Azure/avm-container-images-cicd-agents-and-runners"
}

variable "agent_container_image_tag" {
  description = "Branch, tag or commit of agent_container_image_repository to build. Pin a commit, not a branch."
  type        = string
  default     = "57a937f"
}

variable "agent_container_image_folder" {
  description = "Folder of agent_container_image_repository that holds the Dockerfile."
  type        = string
  default     = "azure-devops-agent-aci"
}

variable "agent_container_image_dockerfile" {
  description = "Name of the Dockerfile in that folder."
  type        = string
  default     = "Dockerfile"
}

# ---------------------------------------------------------------- Azure DevOps

variable "azure_devops_organization_url" {
  description = "Organization URL, https://dev.azure.com/<organization>."
  type        = string

  validation {
    condition     = can(regex("^https://(dev\\.azure\\.com/[^/]+|[^/.]+\\.visualstudio\\.com)/?$", var.azure_devops_organization_url))
    error_message = "azure_devops_organization_url must be https://dev.azure.com/<organization> (or https://<organization>.visualstudio.com)."
  }
}

variable "azure_devops_project_name" {
  description = "Azure DevOps project that holds the repositories, pipelines, environments and service connections."
  type        = string
}

variable "azure_devops_create_project" {
  description = "true creates the project; false uses one that already exists."
  type        = bool
  default     = true
}

variable "azure_devops_personal_access_token" {
  description = "Personal access token of the person running the bootstrap. Supply it as TF_VAR_azure_devops_personal_access_token, never in a file. Scopes: Project and Team (read, write, manage), Code (full), Build (read and execute), Release (read, write, execute), Service Connections (read, query, manage), Environment (read and manage), Variable Groups (read, create, manage), Agent Pools (read and manage), Graph (read and manage), Identity (read), Security (manage)."
  type        = string
  sensitive   = true
  default     = null
}

variable "azure_devops_agent_pat" {
  description = "Personal access token the agent containers register with, scope Agent Pools (read and manage). Supply it as TF_VAR_azure_devops_agent_pat. It is stored, sensitive, in the bootstrap state and in the container group; use a separate token that can do nothing else. Needed only with use_self_hosted_agents."
  type        = string
  sensitive   = true
  default     = null
}

variable "repository_name" {
  description = "Name of the main repository: the Terraform configuration, its .tfvars and its pipeline files."
  type        = string
}

variable "templates_repository_name" {
  description = "Name of the repository of pipeline templates. Empty means <repository_name>-templates."
  type        = string
  default     = ""
}

variable "pipeline_display_name" {
  description = "The name in the pipelines' display names: 01 <name> Continuous Integration and 02 <name> Continuous Delivery."
  type        = string

  validation {
    condition     = length(trimspace(var.pipeline_display_name)) > 0 && length(var.pipeline_display_name) <= 60 && !can(regex("[\"<>|:*?\\\\/]", var.pipeline_display_name))
    error_message = "pipeline_display_name must be 1-60 characters and not contain \" < > | : * ? \\ or /."
  }
}

variable "approvers" {
  description = "User principal names (sign-in addresses) of the people who approve an apply. They become members of the approvers group and the approval check on the apply service connection. Empty leaves the apply without an approval unless approver_entra_group_ids is set. Lab: one address. Production: two or more, or a group - with one approver nobody else reviews a pull request."
  type        = list(string)
  default     = []
}

variable "approver_entra_group_ids" {
  description = "Object IDs of Microsoft Entra SECURITY groups whose members approve an apply, in addition to approvers. Each group is added to the approvers group, so a change of membership in Entra is a change of approvers - no re-run. A mail-only distribution list cannot be used: Azure DevOps takes only directory security groups (Learn: Add Active Directory / Microsoft Entra users or groups to a built-in security group). The organization must be connected to the same Entra tenant."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.approver_entra_group_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "approver_entra_group_ids must be Entra group object IDs (GUIDs), not names or mail addresses."
  }
}

variable "create_branch_policies" {
  description = "Protect main in both repositories: a pull request, a squash merge, and - in the main repository - a passing CI run and one reviewer other than the last pusher (when there is more than one approver)."
  type        = bool
  default     = true
}

variable "terraform_cli_version" {
  description = "Terraform CLI version the pipelines install by default: latest, or a version such as 1.14.9. A pipeline run can override it."
  type        = string
  default     = "latest"
}

# ---------------------------------------------------------------- names

variable "names" {
  description = "Overrides for any generated name. A name left null follows the pattern in locals.tf. Every name is checked against its Azure limit in naming.tf."
  type = object({
    resource_group_state       = optional(string)
    resource_group_identity    = optional(string)
    resource_group_agents      = optional(string)
    resource_group_network     = optional(string)
    storage_account            = optional(string)
    storage_container          = optional(string)
    identity_plan              = optional(string)
    identity_apply             = optional(string)
    identity_agent             = optional(string)
    federated_credential_plan  = optional(string)
    federated_credential_apply = optional(string)
    container_registry         = optional(string)
    container_instance_prefix  = optional(string)
    virtual_network            = optional(string)
    subnet_container_instances = optional(string)
    subnet_private_endpoints   = optional(string)
    nsg_container_instances    = optional(string)
    nsg_private_endpoints      = optional(string)
    nat_gateway                = optional(string)
    public_ip                  = optional(string)
    policy_exemption_public_ip = optional(string)
    private_endpoint_storage   = optional(string)
    private_endpoint_registry  = optional(string)
    environment_plan           = optional(string)
    environment_apply          = optional(string)
    service_connection_plan    = optional(string)
    service_connection_apply   = optional(string)
    variable_group             = optional(string)
    agent_pool                 = optional(string)
    approvers_group            = optional(string)
  })
  default = {}
}
