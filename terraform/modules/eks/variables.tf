variable "project_name" {
  description = "Project name prefix for resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where EKS cluster is deployed."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS cluster and nodes."
  type        = list(string)
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes."
  type        = string
}

variable "node_count" {
  description = "Desired number of worker nodes."
  type        = number
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "devops_agent_role_arn" {
  description = "IAM role ARN of the DevOps Agent (Primary Cloud Source) for EKS access entry."
  type        = string
  default     = ""
}
