variable "subscription_id" {
  description = "Subscription the azurerm provider works in. The service connections of the pipelines are signed in to the same one."
  type        = string
}

variable "project" {
  description = "Short name of the project, for names and tags."
  type        = string
}

variable "environment" {
  description = "Environment code, for names and tags."
  type        = string
}

variable "location" {
  description = "Azure region new resources are created in."
  type        = string
}

variable "tags" {
  description = "Tags every resource this configuration creates must carry: pass them as tags = local.tags. The same tags, with the same values, the bootstrap put on the resources it created."
  type        = map(string)
  default     = {}
}
