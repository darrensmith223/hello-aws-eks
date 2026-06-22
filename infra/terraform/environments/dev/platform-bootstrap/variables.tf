variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "name" {
  type    = string
  default = "practice-eks-dev"
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

variable "gitops_repo_url" {
  description = "Git repository URL containing ArgoCD platform manifests."
  type        = string
}
