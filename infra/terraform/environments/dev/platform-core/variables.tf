variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "name" {
  description = "Base name for project resources."
  type        = string
  default     = "practice-eks-dev"
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Helm chart version for the AWS Load Balancer Controller."
  type        = string
  default     = "1.14.0"
}

variable "domain_name" {
  description = "Base DNS domain for this environment."
  type        = string
}
