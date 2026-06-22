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

variable "domain_name" {
  description = "Base DNS domain for this environment."
  type        = string
}

variable "gitops_repo_url" {
  description = "Git repository URL containing ArgoCD platform manifests."
  type        = string
}
