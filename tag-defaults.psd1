# The organization's tag standard, read by New-ProjectBootstrap.ps1 - the one place that says which
# tags every project carries and what each one defaults to. A project may change any value when it is
# asked (or in its answers file) and may add tags; it may not drop a required tag.
#
# {tokens} in a default are filled from the answers already given:
#   {environment_name}              the environment code (prd, tst, lab ...)
#   {azure_devops_organization}     the Azure DevOps organization name (contoso)
#   {project_name}                  the project name
#   {azure_devops_user_email}       the sign-in address of whoever runs the bootstrap: the owner of the
#                                   personal access token in TF_VAR_azure_devops_personal_access_token
#                                   (or AZDO_PERSONAL_ACCESS_TOKEN) when it is set, else the account signed
#                                   in to the Azure CLI
# {token|text} takes text when the token has no value (no token set, not signed in). An empty default
# means the person must type a value.
#
# Limits that apply to the whole set (Learn: Use tags to organize your Azure resources): at most 15
# tags in all - the automatic 'repository' tag included - because Azure Private DNS zones take no more
# than 15; names start with a letter and hold letters, digits, '_' and '-'; a value is at most 256
# characters. Tags are plain text: never a secret.
#
# The 'repository' tag is not listed: it is filled in automatically with
# dev.azure.com/<organization>/<project>/<main repository> - where the project is bootstrapped.
@{
  RequiredTags = @(
    @{ Name = 'organizationName'; Default = '{azure_devops_organization}'; Help = 'The organization the resources belong to.' }
    @{ Name = 'environment'; Default = '{environment_name}'; Help = 'The environment, as the organization writes it (prd, tst, Production ...).' }
    @{ Name = 'managedBy'; Default = 'Terraform'; Help = 'What manages the resources.' }
    @{ Name = 'appContact'; Default = '{azure_devops_user_email|example@domain.com}'; Help = 'Who to contact about the application: a team mailbox, not a person. Suggested: the person running this.' }
  )

  # Tags every project gets in addition, name = value. None by default.
  AdditionalTags = @{}
}
