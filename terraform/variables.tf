variable "project_name" {
  description = "Name of the project, used as prefix for all resources."
  type        = string
  default     = "outline-demo"
}

variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "eks_node_instance_type" {
  description = "EC2 instance type for EKS managed node group."
  type        = string
  default     = "m5.xlarge"
}

variable "eks_node_count" {
  description = "Desired number of EKS worker nodes."
  type        = number
  default     = 3
}

variable "db_instance_class" {
  description = "RDS instance class for PostgreSQL."
  type        = string
  default     = "db.r6g.large"
}

variable "redis_node_type" {
  description = "ElastiCache node type for Redis."
  type        = string
  default     = "cache.r6g.large"
}

variable "opensearch_instance_type" {
  description = "Instance type for OpenSearch domain."
  type        = string
  default     = "t3.medium.search"
}

variable "opensearch_instance_count" {
  description = "Number of OpenSearch instances."
  type        = number
  default     = 2
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "production"
}

variable "grafana_admin_password" {
  description = "Admin password for Grafana dashboard."
  type        = string
  sensitive   = true
  default     = "admin"
}

variable "opensearch_master_password" {
  description = "Master user password for OpenSearch domain."
  type        = string
  sensitive   = true
  default     = "Admin1234!"
}

variable "db_password" {
  description = "RDS master user password for outline_admin."
  type        = string
  sensitive   = true
}

variable "grafana_host" {
  description = "Hostname for Grafana ingress."
  type        = string
  default     = "grafana.devops-agent.xyz"
}

variable "feishu_webhook_url" {
  description = "Feishu incoming webhook URL for notifications."
  type        = string
  sensitive   = true
  default     = "https://feishu-hook-outline.devops-agent.xyz"
}

variable "feishu_chat_id" {
  description = "Feishu group chat_id for Bot notifications."
  type        = string
  default     = "oc_4f6e21f5de2f46ca95374cd485a39105"
}

variable "feishu_app_id" {
  description = "Feishu app ID for the bot."
  type        = string
  default     = ""
}

variable "feishu_app_secret" {
  description = "Feishu app secret for the bot."
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_token" {
  description = "GitHub personal access token for issue management."
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format."
  type        = string
  default     = "JoeShi/devops-agent-demo-tickets"
}

variable "devops_agent_space_id" {
  description = "AWS DevOps Agent Space ID (stored in Secrets Manager, used by feishu-bot pod)."
  type        = string
  default     = ""
}

variable "devops_agent_role_arn" {
  description = "IAM role ARN of DevOps Agent (Primary Cloud Source), used for EKS access entry."
  type        = string
  default     = ""
}

# --- CDN / Domain ---

variable "outline_domain" {
  description = "Custom domain name for Outline (e.g. outline.devops-agent.xyz)."
  type        = string
  default     = "outline.devops-agent.xyz"
}

variable "route53_zone_name" {
  description = "Route53 hosted zone name (e.g. devops-agent.xyz)."
  type        = string
  default     = "devops-agent.xyz"
}

variable "alb_dns_name" {
  description = "ALB DNS name from K8s ingress (set after first kubectl apply)."
  type        = string
  default     = ""
}

variable "grafana_alb_dns_name" {
  description = "DNS name of the Grafana ALB."
  type        = string
  default     = ""
}

# --- Amazon Federate OIDC ---

variable "federate_enabled" {
  description = "Enable Amazon Federate as OIDC identity provider in Cognito."
  type        = bool
  default     = false
}

variable "federate_client_id" {
  description = "Amazon Federate OIDC client ID."
  type        = string
  default     = ""
}

variable "federate_client_secret" {
  description = "Amazon Federate OIDC client secret."
  type        = string
  sensitive   = true
  default     = ""
}

variable "federate_issuer_url" {
  description = "Amazon Federate OIDC issuer URL."
  type        = string
  default     = ""
}