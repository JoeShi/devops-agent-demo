variable "project_name" {
  description = "Project name prefix for resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "List of availability zones."
  type        = list(string)
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}
