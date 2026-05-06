variable "feishu_webhook_url" {
  description = "Feishu incoming webhook URL for notifications (used by feishu-notifier Lambda)."
  type        = string
  sensitive   = true
}

variable "feishu_app_id" {
  description = "Feishu app ID for the bot (stored in Secrets Manager, referenced by EKS pod)."
  type        = string
}

variable "feishu_app_secret" {
  description = "Feishu app secret for the bot (stored in Secrets Manager, referenced by EKS pod)."
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "GitHub personal access token."
  type        = string
  sensitive   = true
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format."
  type        = string
}

variable "devops_agent_space_id" {
  description = "AWS DevOps Agent Space ID (stored in Secrets Manager, referenced by EKS pod)."
  type        = string
  default     = ""
}

variable "eks_cluster_name" {
  description = "EKS cluster name, used for IRSA role naming."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider (for IRSA trust policy)."
  type        = string
}

variable "oidc_issuer_host" {
  description = "EKS OIDC issuer hostname without https:// (for IRSA conditions)."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS records."
  type        = string
}

# --- Grafana DevOps Agent capability ---

variable "grafana_url" {
  description = "Full HTTPS URL of the Grafana instance for AWS DevOps Agent integration."
  type        = string
  default     = ""
}

variable "grafana_service_name" {
  description = "Logical name for the Grafana service registration in AWS DevOps Agent (alphanumeric, hyphens, underscores)."
  type        = string
  default     = "outline-grafana"
}

variable "grafana_sa_token_secret_arn" {
  description = "ARN of the Secrets Manager secret that contains the Grafana service account access token."
  type        = string
  default     = ""
}

# --- Private connection (VPC Lattice) ---

variable "private_connection_name" {
  description = "Name of the DevOps Agent private connection for VPC-internal resources."
  type        = string
  default     = "outline-vpc-private"
}

variable "vpc_id" {
  description = "VPC ID for the private connection."
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the private connection ENIs (at least 2 AZs recommended)."
  type        = list(string)
  default     = []
}

variable "grafana_alb_dns_name" {
  description = "Internal DNS name of the Grafana ALB (used as hostAddress for private connection)."
  type        = string
  default     = ""
}


variable "feishu_chat_id" {
  description = "Feishu group chat_id for Bot notifications."
  type        = string
}

# --- GitHub Issues → DevOps Agent investigation ---

variable "github_tickets_repo" {
  description = "GitHub tickets repository in owner/repo format (e.g. JoeShi/devops-agent-demo-tickets)."
  type        = string
  default     = "JoeShi/devops-agent-demo-tickets"
}

variable "github_tickets_repo_owner" {
  description = "GitHub owner of the tickets repository (user or org)."
  type        = string
  default     = "JoeShi"
}

variable "github_tickets_repo_name" {
  description = "GitHub repository name of the tickets repository."
  type        = string
  default     = "devops-agent-demo-tickets"
}

variable "enable_private_connection" {
  description = "Whether to create the DevOps Agent private connection (VPC Lattice). Set to false for first-time deploy when vpc_id is not yet known."
  type        = bool
  default     = true
}

variable "enable_grafana_registration" {
  description = "Whether to register Grafana with DevOps Agent. Set to true only after Grafana is deployed and SA token is populated."
  type        = bool
  default     = true
}
