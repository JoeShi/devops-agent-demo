variable "opensearch_endpoint" {
  description = "OpenSearch domain endpoint for log storage."
  type        = string
}

variable "grafana_admin_password" {
  description = "Admin password for Grafana."
  type        = string
  sensitive   = true
}

variable "grafana_host" {
  description = "Hostname for Grafana ingress."
  type        = string
  default     = "grafana.example.com"
}

variable "eks_cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "grafana_oauth_enabled" {
  description = "Enable Cognito OAuth for Grafana."
  type        = bool
  default     = false
}

variable "grafana_oauth_client_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "grafana_oauth_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "grafana_oauth_auth_url" {
  type    = string
  default = ""
}

variable "grafana_oauth_token_url" {
  type    = string
  default = ""
}

variable "grafana_oauth_api_url" {
  type    = string
  default = ""
}

variable "grafana_root_url" {
  type    = string
  default = ""
}

variable "grafana_certificate_arn" {
  description = "ACM certificate ARN for Grafana ALB Ingress."
  type        = string
  default     = ""
}

variable "alertmanager_sns_topic_arn" {
  description = "SNS topic ARN for Alertmanager to publish alerts."
  type        = string
  default     = ""
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider for IRSA."
  type        = string
  default     = ""
}

variable "oidc_issuer_host" {
  description = "EKS OIDC issuer hostname without https://."
  type        = string
  default     = ""
}

variable "opensearch_master_password" {
  description = "Master user password for OpenSearch (used for Grafana datasource basic auth)."
  type        = string
  sensitive   = true
}

variable "opensearch_domain_arn" {
  description = "ARN of the OpenSearch domain for Fluent Bit IAM policy."
  type        = string
}