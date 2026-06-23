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

variable "state_bucket" {
  description = "S3 bucket name holding Terraform remote state. Must match the value in backend.hcl."
  type        = string
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Helm chart version for the AWS Load Balancer Controller."
  type        = string
  default     = "1.14.0"
}

variable "external_dns_chart_version" {
  description = "Helm chart version for ExternalDNS."
  type        = string
  default     = "1.21.1"
}

variable "argocd_chart_version" {
  description = "Helm chart version for ArgoCD."
  type        = string
  default     = "7.8.26"
}

variable "external_secrets_chart_version" {
  description = "Helm chart version for External Secrets Operator."
  type        = string
  default     = "0.14.4"
}
