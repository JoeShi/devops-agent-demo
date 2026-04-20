variable "project_name" {
  type = string
}

variable "outline_url" {
  type = string
}

variable "grafana_url" {
  type = string
}

# Amazon Federate OIDC IdP
variable "federate_enabled" {
  type    = bool
  default = false
}

variable "federate_client_id" {
  type    = string
  default = ""
}

variable "federate_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "federate_issuer_url" {
  type    = string
  default = ""
}