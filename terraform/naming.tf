# Every name is checked at plan time against the limit Microsoft Learn gives for its resource type
# (Naming rules and restrictions for Azure resources), so a name that Azure would refuse fails
# here, before anything is created, instead of half-way through an apply.
#
#   storage account            3-24, lowercase letters and digits, global
#   storage container          3-63, lowercase letters, digits, hyphens; starts with a letter or digit; no "--"
#   container registry         5-50, letters and digits, global
#   container group           1-63, lowercase letters, digits, hyphens; not starting or ending with a
#                              hyphen; no "--"
#   resource group             1-90, letters, digits, _ - . ( ); not ending with a period
#   user-assigned identity     3-128, letters, digits, hyphens, underscores; starts with a letter or digit
#   federated credential       3-120, letters, digits, hyphens, underscores; starts with a letter or digit
#   virtual network, private   2-64, letters, digits, _ . -; starts with a letter or digit; ends with a
#   endpoint                   letter, digit or underscore
#   subnet, public IP          1-80, same characters
#   NAT gateway                Not on Learn's naming page. The same 1-80 rule as the other Microsoft.Network
#                              names is applied; Azure has the last word.
locals {
  name_rules = {
    storage_account            = { pattern = "^[a-z0-9]{3,24}$", limit = "3-24 lowercase letters and digits" }
    storage_container          = { pattern = "^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$", limit = "3-63 lowercase letters, digits and single hyphens, not starting or ending with a hyphen" }
    container_registry         = { pattern = "^[a-zA-Z0-9]{5,50}$", limit = "5-50 letters and digits" }
    container_instance_prefix  = { pattern = "^[a-z0-9]([a-z0-9-]{0,58}[a-z0-9])?$", limit = "lowercase letters, digits and single hyphens, at most 60 characters (a two-digit number is added), not starting or ending with a hyphen" }
    resource_group_state       = { pattern = "^[-\\w._()]{1,89}[-\\w_()]$", limit = "1-90 letters, digits, _ - . ( ), not ending with a period" }
    resource_group_identity    = { pattern = "^[-\\w._()]{1,89}[-\\w_()]$", limit = "1-90 letters, digits, _ - . ( ), not ending with a period" }
    resource_group_agents      = { pattern = "^[-\\w._()]{1,89}[-\\w_()]$", limit = "1-90 letters, digits, _ - . ( ), not ending with a period" }
    resource_group_network     = { pattern = "^[-\\w._()]{1,89}[-\\w_()]$", limit = "1-90 letters, digits, _ - . ( ), not ending with a period" }
    identity_plan              = { pattern = "^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$", limit = "3-128 letters, digits, hyphens and underscores, starting with a letter or digit" }
    identity_apply             = { pattern = "^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$", limit = "3-128 letters, digits, hyphens and underscores, starting with a letter or digit" }
    identity_agent             = { pattern = "^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$", limit = "3-128 letters, digits, hyphens and underscores, starting with a letter or digit" }
    federated_credential_plan  = { pattern = "^[A-Za-z0-9][A-Za-z0-9_-]{2,119}$", limit = "3-120 letters, digits, hyphens and underscores, starting with a letter or digit" }
    federated_credential_apply = { pattern = "^[A-Za-z0-9][A-Za-z0-9_-]{2,119}$", limit = "3-120 letters, digits, hyphens and underscores, starting with a letter or digit" }
    virtual_network            = { pattern = "^[A-Za-z0-9]([A-Za-z0-9_.-]{0,62}[A-Za-z0-9_])?$", limit = "2-64 letters, digits, _ . -, starting with a letter or digit and ending with a letter, digit or underscore" }
    private_endpoint_storage   = { pattern = "^[A-Za-z0-9]([A-Za-z0-9_.-]{0,62}[A-Za-z0-9_])?$", limit = "2-64 letters, digits, _ . -, starting with a letter or digit and ending with a letter, digit or underscore" }
    private_endpoint_registry  = { pattern = "^[A-Za-z0-9]([A-Za-z0-9_.-]{0,62}[A-Za-z0-9_])?$", limit = "2-64 letters, digits, _ . -, starting with a letter or digit and ending with a letter, digit or underscore" }
    subnet_container_instances = { pattern = "^[A-Za-z0-9]([A-Za-z0-9_.-]{0,78}[A-Za-z0-9_])?$", limit = "1-80 letters, digits, _ . -, starting with a letter or digit and ending with a letter, digit or underscore" }
    subnet_private_endpoints   = { pattern = "^[A-Za-z0-9]([A-Za-z0-9_.-]{0,78}[A-Za-z0-9_])?$", limit = "1-80 letters, digits, _ . -, starting with a letter or digit and ending with a letter, digit or underscore" }
    nsg_container_instances    = { pattern = "^[A-Za-z0-9]([A-Za-z0-9_.-]{0,78}[A-Za-z0-9_])?$", limit = "1-80 letters, digits, _ . -, starting with a letter or digit and ending with a letter, digit or underscore" }
    nsg_private_endpoints      = { pattern = "^[A-Za-z0-9]([A-Za-z0-9_.-]{0,78}[A-Za-z0-9_])?$", limit = "1-80 letters, digits, _ . -, starting with a letter or digit and ending with a letter, digit or underscore" }
    public_ip                  = { pattern = "^[A-Za-z0-9]([A-Za-z0-9_.-]{0,78}[A-Za-z0-9_])?$", limit = "1-80 letters, digits, _ . -, starting with a letter or digit and ending with a letter, digit or underscore" }
    nat_gateway                = { pattern = "^[A-Za-z0-9]([A-Za-z0-9_.-]{0,78}[A-Za-z0-9_])?$", limit = "1-80 letters, digits, _ . -, starting with a letter or digit and ending with a letter, digit or underscore" }
  }

  # The single-hyphen rule of the lowercase names, which a character class cannot express.
  no_double_hyphen = ["storage_container", "container_instance_prefix"]

  name_violations = concat(
    [for key, rule in local.name_rules : "${key} '${local.names[key]}' must be ${rule.limit}." if !can(regex(rule.pattern, local.names[key]))],
    [for key in local.no_double_hyphen : "${key} '${local.names[key]}' must not contain two hyphens in a row." if can(regex("--", local.names[key]))],
  )
}

resource "terraform_data" "naming" {
  lifecycle {
    precondition {
      condition     = length(local.name_violations) == 0
      error_message = "A name is outside its Azure limit: ${join(" ", local.name_violations)} Shorten project_name, or set the name in var.names."
    }
    precondition {
      condition     = !var.use_self_hosted_agents || var.azure_devops_agent_pat != null
      error_message = "use_self_hosted_agents is true, so the agent containers need a token to register with: set TF_VAR_azure_devops_agent_pat (scope Agent Pools, read and manage)."
    }
    precondition {
      condition     = var.azure_devops_personal_access_token != null
      error_message = "Set TF_VAR_azure_devops_personal_access_token: Azure DevOps is not reached with the Azure CLI's token."
    }
    precondition {
      condition     = var.public_ip_deny_policy_assignment_id == "" || var.policy_exemption_expires_on != ""
      error_message = "public_ip_deny_policy_assignment_id creates a policy exemption, and an exemption must end: set policy_exemption_expires_on (RFC 3339, for example 2027-05-24T00:00:00Z)."
    }
    precondition {
      condition     = !local.use_private_networking || local.use_nat || var.agent_route_table_id != ""
      error_message = "The agents are in a private network with no way out: use_nat_gateway is false and agent_route_table_id is empty. Set one - a NAT gateway needs a public IP address; a route table (for example to a hub firewall) does not."
    }
    precondition {
      condition     = length(local.missing_required_tags) == 0
      error_message = "Required tag(s) missing or empty: ${join(", ", local.missing_required_tags)}. Every resource must carry ${join(", ", var.required_tag_names)} (var.required_tag_names) - give each a value in var.tags."
    }
    precondition {
      condition     = length(local.tags) <= 15
      error_message = "${length(local.tags)} tags, but Azure Private DNS zones take at most 15 (Learn: Use tags to organize your Azure resources). Remove ${length(local.tags) - 15}."
    }
    precondition {
      condition     = length(lookup(local.tag_values_by_lower_name, "repository", "")) <= 256
      error_message = "The repository tag is longer than the 256 characters of a tag value. Shorten the project or repository name."
    }
  }
}

locals {
  tag_values_by_lower_name = { for name, value in local.tags : lower(name) => value }
  missing_required_tags    = [for name in var.required_tag_names : name if trimspace(lookup(local.tag_values_by_lower_name, lower(name), "")) == ""]
}
