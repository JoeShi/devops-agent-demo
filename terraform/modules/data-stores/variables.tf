variable "project_name" {
  description = "Project name prefix for resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for security groups."
  type        = string
}

variable "data_subnet_ids" {
  description = "Subnet IDs for data stores."
  type        = list(string)
}

variable "eks_node_sg_id" {
  description = "Security group ID of EKS nodes for ingress rules."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type."
  type        = string
}

variable "opensearch_instance_type" {
  description = "OpenSearch instance type."
  type        = string
}

variable "opensearch_instance_count" {
  description = "Number of OpenSearch instances."
  type        = number
}

variable "opensearch_master_password" {
  description = "Master user password for OpenSearch."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "RDS master user password."
  type        = string
  sensitive   = true
}